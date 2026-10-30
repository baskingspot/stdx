//! Comptime-generated slab allocator with configurable size classes.
//!
//! Requests use the first size class large enough to hold them. Larger requests
//! fall back to the allocator passed to `alloc`; the same allocator must be
//! passed to `free` for fallback allocations and to `deinit`.
//!
//! Built on 0.16's unmanaged memory pools: no allocator is retained, so the
//! gpa is passed to `init`, `alloc`, and `deinit`.
//!
//! This type is not thread-safe. `alloc` and `free` require the same nonzero
//! allocation size, and `free` requires the original pointer returned by
//! `alloc`. Runtime-safety builds assert that all allocations were freed before
//! `deinit`.

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const Alignment = mem.Alignment;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");

const runtime_safety = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const SizeClass = struct {
    size: usize,
    preheat: usize = 0,
};

// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const Config = struct {
    size_classes: []const SizeClass,
    alignment: Alignment = .@"1",
};

/// Generates a slab allocator for the configured size classes.
/// `queryCapacity` reports pooled arena capacity and excludes fallback allocations.
pub fn SlabAllocator(comptime config: Config) type {
    validateConfig(config);

    const class_count = config.size_classes.len;
    const fallback_index = class_count;
    const Pools = blk: {
        var pool_types: [class_count]type = undefined;
        for (config.size_classes, 0..) |size_class, index| {
            pool_types[index] = heap.memory_pool.Aligned(
                [size_class.size]u8,
                config.alignment,
            );
        }
        break :blk @Tuple(&pool_types);
    };
    const LiveCounts = if (runtime_safety) [fallback_index + 1]u64 else void;

    return struct {
        pools: Pools,
        live_counts: LiveCounts,

        pub const Ptr = [*]align(config.alignment.toByteUnits()) u8;
        const Self = @This();

        pub fn init(gpa: Allocator) Allocator.Error!Self {
            var self: Self = undefined;
            inline for (0..class_count) |index| self.pools[index] = .empty;
            self.live_counts = if (runtime_safety) @splat(0) else {};
            errdefer self.deinit(gpa);

            inline for (config.size_classes, 0..) |size_class, index| {
                if (size_class.preheat > 0) {
                    try self.pools[index].addCapacity(gpa, size_class.preheat);
                }
            }
            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (comptime runtime_safety) {
                inline for (0..fallback_index + 1) |index| {
                    assert(self.live_counts[index] == 0);
                }
            }
            inline for (0..class_count) |index| self.pools[index].deinit(gpa);
            self.* = undefined;
        }

        /// Allocates a nonzero number of bytes or panics on allocator exhaustion.
        pub fn alloc(self: *Self, gpa: Allocator, size: usize) Ptr {
            assert(size > 0);

            inline for (config.size_classes, 0..) |size_class, index| {
                if (size <= size_class.size) {
                    const slot = self.pools[index].create(gpa) catch @panic("OOM");
                    if (comptime runtime_safety) {
                        assert(self.live_counts[index] < std.math.maxInt(u64));
                        self.live_counts[index] += 1;
                    }
                    return @ptrCast(slot);
                }
            }

            const memory = gpa.alignedAlloc(u8, config.alignment, size) catch @panic("OOM");
            if (comptime runtime_safety) {
                assert(self.live_counts[fallback_index] < std.math.maxInt(u64));
                self.live_counts[fallback_index] += 1;
            }
            return memory.ptr;
        }

        /// Frees the original pointer using the same nonzero size passed to `alloc`.
        pub fn free(self: *Self, gpa: Allocator, ptr: Ptr, size: usize) void {
            assert(size > 0);

            inline for (config.size_classes, 0..) |size_class, index| {
                if (size <= size_class.size) {
                    if (comptime runtime_safety) {
                        assert(self.live_counts[index] > 0);
                        self.live_counts[index] -= 1;
                    }
                    const Pool = @TypeOf(self.pools[index]);
                    const Slot = [size_class.size]u8;
                    const slot: *align(Pool.item_alignment.toByteUnits()) Slot =
                        @ptrCast(@alignCast(ptr));
                    self.pools[index].destroy(slot);
                    return;
                }
            }

            if (comptime runtime_safety) {
                assert(self.live_counts[fallback_index] > 0);
                self.live_counts[fallback_index] -= 1;
            }
            gpa.free(ptr[0..size]);
        }

        pub fn queryCapacity(self: *const Self, gpa: Allocator) usize {
            var capacity: usize = 0;
            inline for (0..class_count) |index| {
                capacity += self.pools[index].arena_state.promote(gpa).queryCapacity();
            }
            return capacity;
        }
    };
}

fn validateConfig(comptime config: Config) void {
    if (config.size_classes.len == 0) {
        @compileError("Slab requires at least one size class");
    }

    for (config.size_classes, 0..) |size_class, index| {
        if (size_class.size == 0) {
            @compileError("Slab size classes must be nonzero");
        }
        if (index > 0) {
            if (size_class.size <= config.size_classes[index - 1].size) {
                @compileError("Slab size classes must be strictly increasing");
            }
        }
    }
}

test "routes exact boundaries and boundary plus one" {
    const TestSlab = SlabAllocator(.{ .size_classes = &.{
        .{ .size = 16 },
        .{ .size = 64 },
    } });
    var slab: TestSlab = try .init(testing.allocator);
    defer slab.deinit(testing.allocator);

    const small = slab.alloc(testing.allocator, 1);
    slab.free(testing.allocator, small, 1);

    const small_boundary = slab.alloc(testing.allocator, 16);
    try testing.expectEqual(small, small_boundary);
    slab.free(testing.allocator, small_boundary, 16);

    const medium = slab.alloc(testing.allocator, 17);
    slab.free(testing.allocator, medium, 17);

    const medium_boundary = slab.alloc(testing.allocator, 64);
    try testing.expectEqual(medium, medium_boundary);
    slab.free(testing.allocator, medium_boundary, 64);

    var fallback_allocator: testing.FailingAllocator = .init(testing.allocator, .{});
    const fallback_gpa = fallback_allocator.allocator();
    const fallback = slab.alloc(fallback_gpa, 65);
    try testing.expectEqual(@as(usize, 1), fallback_allocator.allocations);
    slab.free(fallback_gpa, fallback, 65);
    try testing.expectEqual(@as(usize, 1), fallback_allocator.deallocations);
}

test "supports multiple size classes" {
    const TestSlab = SlabAllocator(.{ .size_classes = &.{
        .{ .size = 16 },
        .{ .size = 128 },
        .{ .size = 1024 },
    } });
    var slab: TestSlab = try .init(testing.allocator);
    defer slab.deinit(testing.allocator);

    const small = slab.alloc(testing.allocator, 16);
    const medium = slab.alloc(testing.allocator, 100);
    const large = slab.alloc(testing.allocator, 1000);

    slab.free(testing.allocator, small, 16);
    slab.free(testing.allocator, medium, 100);
    slab.free(testing.allocator, large, 1000);
}

test "honors configured alignment" {
    const TestSlab = SlabAllocator(.{
        .size_classes = &.{.{ .size = 64 }},
        .alignment = .@"16",
    });
    var slab: TestSlab = try .init(testing.allocator);
    defer slab.deinit(testing.allocator);

    const pooled = slab.alloc(testing.allocator, 10);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(pooled) % 16);
    slab.free(testing.allocator, pooled, 10);

    const fallback = slab.alloc(testing.allocator, 128);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(fallback) % 16);
    slab.free(testing.allocator, fallback, 128);
}

test "preheats pools and excludes fallback capacity" {
    const TestSlab = SlabAllocator(.{ .size_classes = &.{
        .{ .size = 32, .preheat = 4 },
        .{ .size = 256, .preheat = 2 },
    } });
    var slab: TestSlab = try .init(testing.allocator);
    defer slab.deinit(testing.allocator);

    const capacity = slab.queryCapacity(testing.allocator);
    try testing.expect(capacity > 0);

    const fallback = slab.alloc(testing.allocator, 4096);
    try testing.expectEqual(capacity, slab.queryCapacity(testing.allocator));
    slab.free(testing.allocator, fallback, 4096);
}

test "cleans up after partial preheat failure" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const TestSlab = SlabAllocator(.{ .size_classes = &.{
        .{ .size = 32, .preheat = 1 },
        .{ .size = 64, .preheat = 1 },
    } });

    try testing.expectError(error.OutOfMemory, TestSlab.init(failing.allocator()));
    try testing.expectEqual(@as(usize, 1), failing.allocations);
    try testing.expectEqual(@as(usize, 1), failing.deallocations);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "runtime-safety accounting tracks pooled and fallback allocations" {
    if (comptime runtime_safety) {
        const TestSlab = SlabAllocator(.{ .size_classes = &.{.{ .size = 8 }} });
        var slab: TestSlab = try .init(testing.allocator);
        defer slab.deinit(testing.allocator);

        const pooled = slab.alloc(testing.allocator, 8);
        const fallback = slab.alloc(testing.allocator, 9);
        try testing.expectEqual(@as(u64, 1), slab.live_counts[0]);
        try testing.expectEqual(@as(u64, 1), slab.live_counts[1]);

        slab.free(testing.allocator, pooled, 8);
        slab.free(testing.allocator, fallback, 9);
        try testing.expectEqual(@as(u64, 0), slab.live_counts[0]);
        try testing.expectEqual(@as(u64, 0), slab.live_counts[1]);
    }
}

test "does not retain a direct allocator field" {
    const TestSlab = SlabAllocator(.{ .size_classes = &.{.{ .size = 8 }} });
    inline for (@typeInfo(TestSlab).@"struct".fields) |field| {
        try testing.expect(field.type != Allocator);
    }
}

test "runtime-safety accounting has no production storage" {
    if (comptime !runtime_safety) {
        const TestSlab = SlabAllocator(.{ .size_classes = &.{.{ .size = 8 }} });
        const pools_size = @sizeOf(@FieldType(TestSlab, "pools"));
        try testing.expectEqual(pools_size, @sizeOf(TestSlab));
    }
}
