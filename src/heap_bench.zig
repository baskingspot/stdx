//! The heap module's benchmarks: the gpa-backed slab and the fixed-backing
//! size-class pool.

const std = @import("std");
const testingx = @import("testingx");

const stdx = @import("stdx");
const heap = stdx.heap;

const Slab = heap.SlabAllocator(.{
    .size_classes = &.{
        .{ .size = 64, .preheat = 64 },
        .{ .size = 256, .preheat = 64 },
    },
});

pub fn benchmarkSlabAllocFree(b: *testingx.B) !void {
    const gpa = std.heap.page_allocator;
    var slab = try Slab.init(gpa);
    defer slab.deinit(gpa);

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const ptr = slab.alloc(gpa, 64);
        sink +%= @intFromPtr(ptr);
        slab.free(gpa, ptr, 64);
    }
}

const Pool = heap.SizeClassPool(&.{ 64, 256, 1024 });

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
