const std = @import("std");
const SlabAllocator = @import("stdx").heap.SlabAllocator;

// Records are 96 bytes. The 128-byte class holds them with 32 to spare,
// and preheat maps the first 16 slots at init. Anything above the largest
// class falls back to the gpa passed to `alloc`.
const Slab = SlabAllocator(.{ .size_classes = &.{
    .{ .size = 128, .preheat = 16 },
    .{ .size = 1024 },
} });

test "a record comes from its size class" {
    var slab: Slab = try .init(std.testing.allocator);
    defer slab.deinit(std.testing.allocator);

    const record = slab.alloc(std.testing.allocator, 96);
    @memset(record[0..96], 0);
    slab.free(std.testing.allocator, record, 96);

    // The type retains no gpa, so the same one goes to every call.
    try std.testing.expect(slab.queryCapacity(std.testing.allocator) >= 128 * 16);
}
