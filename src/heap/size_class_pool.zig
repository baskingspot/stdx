//! A fallible byte pool over one caller-owned backing.
//!
//! `SizeClassPool(&.{ 64, 128, ... })` carves every class, its free lists, and
//! its arena metadata from the backing. A request takes the first class that
//! fits; a request above the largest class returns `error.OutOfMemory`.
//!
//! Classes never rebalance: a class that claimed backing keeps it. The pool is
//! not a general allocator and is not thread-safe. Do not copy it after
//! `init`; the pools point into the backing.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const heap = std.heap;

/// A pool of byte blocks over caller-owned storage.
///
/// The classes are a strictly increasing list of positive sizes. A request
/// uses the first class large enough, so `create(17)` takes the 64-byte class
/// in `&.{ 16, 64 }`. `live_bytes` counts the requested lengths;
/// `live_class_bytes` counts the class sizes, which is what the backing
/// actually holds.
pub fn SizeClassPool(comptime classes: []const comptime_int) type {
    comptime {
        if (classes.len == 0) @compileError("SizeClassPool needs at least one class");
        var previous: usize = 0;
        for (classes) |size| {
            if (size < 1) @compileError("SizeClassPool classes must be positive");
            if (size <= previous) @compileError("SizeClassPool classes must increase");
            previous = @intCast(size);
        }
    }

    const class_sizes = comptime blk: {
        var sizes: [classes.len]usize = undefined;
        for (classes, 0..) |size, index| sizes[index] = @intCast(size);
        break :blk sizes;
    };
    const class_count = class_sizes.len;

    const Pools = blk: {
        var types: [class_count]type = undefined;
        for (class_sizes, 0..) |size, index| {
            types[index] = heap.MemoryPool([size]u8);
        }
        break :blk @Tuple(&types);
    };

    return struct {
        const Self = @This();

        /// The class sizes, as `usize`, for a caller that sizes a backing.
        pub const sizes = class_sizes;

        backing: []u8,
        fixed: heap.FixedBufferAllocator,
        pools: Pools,
        /// Requested bytes currently live.
        live_bytes: usize,
        /// Class bytes currently assigned to live blocks.
        live_class_bytes: usize,

        /// Use `backing` as the whole storage. Every class and its metadata
        /// comes from it; nothing else is allocated.
        pub fn init(backing: []u8) Self {
            var self: Self = .{
                .backing = backing,
                .fixed = .init(backing),
                .pools = undefined,
                .live_bytes = 0,
                .live_class_bytes = 0,
            };
            inline for (&self.pools) |*pool| pool.* = .empty;
            return self;
        }

        /// Assert that every block was destroyed, then reset the pool. The
        /// backing stays with the caller and can be reused.
        ///
        /// The check is a `std.debug.assert`: it runs in Debug and ReleaseSafe
        /// and compiles out in ReleaseFast.
        pub fn deinit(self: *Self) void {
            assert(self.live_bytes == 0);
            inline for (&self.pools) |*pool| {
                pool.deinit(self.fixed.allocator());
                pool.* = .empty;
            }
            self.fixed = .init(self.backing);
            self.live_bytes = 0;
            self.live_class_bytes = 0;
        }

        /// Create a block of `size` bytes from the first class that fits.
        ///
        /// Returns `error.OutOfMemory` when the class pool has no room or the
        /// size is above the largest class. A failed create changes neither
        /// counter. `size` must be nonzero.
        pub fn create(self: *Self, size: usize) error{OutOfMemory}![]u8 {
            assert(size > 0);
            const selected = classIndex(size) orelse return error.OutOfMemory;
            inline for (&self.pools, 0..) |*pool, index| {
                if (selected == index) {
                    const block = try pool.create(self.fixed.allocator());
                    self.live_bytes += size;
                    self.live_class_bytes += class_sizes[index];
                    return block[0..size];
                }
            }
            unreachable;
        }

        /// Return a block from `create` to its class pool.
        ///
        /// Pass the slice from `create` unchanged: its length selects the
        /// class. The block's memory stays with the pool for reuse by that
        /// class.
        pub fn destroy(self: *Self, block: []u8) void {
            assert(block.len > 0);
            const selected = classIndex(block.len) orelse
                @panic("heap.SizeClassPool.destroy: block is larger than every class");
            inline for (&self.pools, 0..) |*pool, index| {
                if (selected == index) {
                    const Pool = @TypeOf(pool.*);
                    const Slot = [class_sizes[index]]u8;
                    const slot: *align(Pool.item_alignment.toByteUnits()) Slot =
                        @ptrCast(@alignCast(block.ptr));
                    pool.destroy(slot);
                    self.live_bytes -= block.len;
                    self.live_class_bytes -= class_sizes[index];
                    return;
                }
            }
            unreachable;
        }

        fn classIndex(size: usize) ?usize {
            for (class_sizes, 0..) |class_size, index| {
                if (size <= class_size) return index;
            }
            return null;
        }
    };
}

test SizeClassPool {
    const Pool = SizeClassPool(&.{ 16, 64, 256 });
    var backing: [4096]u8 = undefined;
    var pool: Pool = .init(&backing);
    try testing.expectEqualSlices(usize, &.{ 16, 64, 256 }, &Pool.sizes);

    // Class selection and the two counters.
    const small = try pool.create(1);
    try testing.expectEqual(@as(usize, 1), small.len);
    try testing.expectEqual(@as(usize, 1), pool.live_bytes);
    try testing.expectEqual(@as(usize, 16), pool.live_class_bytes);
    @memset(small, 0xaa);

    const mid = try pool.create(17);
    try testing.expectEqual(@as(usize, 17), mid.len);
    try testing.expectEqual(@as(usize, 18), pool.live_bytes);
    try testing.expectEqual(@as(usize, 80), pool.live_class_bytes);
    @memset(mid, 0xbb);

    const large = try pool.create(256);
    try testing.expectEqual(@as(usize, 256), large.len);
    try testing.expectEqual(@as(usize, 274), pool.live_bytes);
    try testing.expectEqual(@as(usize, 336), pool.live_class_bytes);

    // Above the largest class is a normal OOM and leaves the counters alone.
    try testing.expectError(error.OutOfMemory, pool.create(257));
    try testing.expectEqual(@as(usize, 274), pool.live_bytes);
    try testing.expectEqual(@as(usize, 336), pool.live_class_bytes);

    pool.destroy(small);
    try testing.expectEqual(@as(usize, 273), pool.live_bytes);
    try testing.expectEqual(@as(usize, 320), pool.live_class_bytes);
    pool.destroy(mid);
    pool.destroy(large);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes);
    try testing.expectEqual(@as(usize, 0), pool.live_class_bytes);

    // deinit resets the backing for another round.
    pool.deinit();
    const again = try pool.create(256);
    try testing.expectEqual(@as(usize, 256), again.len);
    pool.destroy(again);
    pool.deinit();
}

test "SizeClassPool: exhaustion leaves no partial allocation" {
    var backing: [256]u8 = undefined;
    var pool: SizeClassPool(&.{ 16, 64 }) = .init(&backing);

    var blocks: [1024][]u8 = undefined;
    var count: usize = 0;
    while (count < blocks.len) {
        blocks[count] = pool.create(16) catch break;
        count += 1;
    }
    try testing.expect(count > 0);

    const live_bytes = pool.live_bytes;
    const live_class_bytes = pool.live_class_bytes;
    try testing.expectError(error.OutOfMemory, pool.create(16));
    try testing.expectEqual(live_bytes, pool.live_bytes);
    try testing.expectEqual(live_class_bytes, pool.live_class_bytes);

    for (blocks[0..count]) |block| pool.destroy(block);
    try testing.expectEqual(@as(usize, 0), pool.live_bytes);
    try testing.expectEqual(@as(usize, 0), pool.live_class_bytes);
    pool.deinit();
}
