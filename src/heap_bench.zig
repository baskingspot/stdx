//! The heap module's benchmarks: the gpa-backed slab, the fixed-backing
//! size-class pool, and the bump arena against std's arena and a fixed
//! buffer.

const std = @import("std");
const heap = std.heap;

const stdx = @import("stdx");
const heapx = stdx.heap;
const testingx = @import("testingx");

const Slab = heapx.SlabAllocator(.{
    .size_classes = &.{
        .{ .size = 64, .preheat = 64 },
        .{ .size = 256, .preheat = 64 },
    },
});

pub fn benchmarkSlabAllocFree(b: *testingx.B) !void {
    const gpa = heap.page_allocator;
    var slab: Slab = try .init(gpa);
    defer slab.deinit(gpa);

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const ptr = slab.alloc(gpa, 64);
        sink +%= @intFromPtr(ptr);
        slab.free(gpa, ptr, 64);
    }
}

const Pool = heapx.SizeClassPool(&.{ 64, 256, 1024 });

pub fn benchmarkSizeClassPoolCreate(b: *testingx.B) !void {
    var backing: [64 * 1024]u8 align(8) = undefined;
    var pool: Pool = .init(&backing);

    // Warm every class so the timed path uses the free lists.
    inline for (Pool.sizes) |size| {
        const block = try pool.create(size);
        pool.destroy(block);
    }

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const block = try pool.create(256);
        sink +%= block.len;
        pool.destroy(block);
    }
    pool.deinit();
}

const values_per_round = 1024;

const BumpArena = heapx.Bump(.{
    .first_chunk = 256 * 1024,
    .max_chunk = 4 * 1024 * 1024,
});

pub fn benchmarkBumpAlloc(b: *testingx.B) !void {
    var bump: BumpArena = .init(heap.page_allocator);
    defer bump.deinit();
    const arena = bump.allocator();

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        bump.reset(.retain_capacity);
        for (0..values_per_round) |index| {
            const value = try arena.create(u64);
            value.* = index;
            sink +%= value.*;
        }
    }
}

pub fn benchmarkStdArenaAlloc(b: *testingx.B) !void {
    var arena_state: heap.ArenaAllocator = .init(heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        _ = arena_state.reset(.retain_capacity);
        for (0..values_per_round) |index| {
            const value = try arena.create(u64);
            value.* = index;
            sink +%= value.*;
        }
    }
}

pub fn benchmarkFixedBufferAlloc(b: *testingx.B) !void {
    var backing: [values_per_round * @sizeOf(u64)]u8 align(@alignOf(u64)) = undefined;
    var fba: heap.FixedBufferAllocator = .init(&backing);
    const arena = fba.allocator();

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        fba.reset();
        for (0..values_per_round) |index| {
            const value = try arena.create(u64);
            value.* = index;
            sink +%= value.*;
        }
    }
}
