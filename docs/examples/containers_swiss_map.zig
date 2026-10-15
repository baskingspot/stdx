const std = @import("std");
const swiss = @import("stdx").swiss;

// The one container here that grows. It allocates, so every call that can
// allocate takes the allocator, and the value does not store it.
const Counts = swiss.String(u32);

test "a resizable map takes the allocator per call" {
    const gpa = std.testing.allocator;

    var counts: Counts = .init;
    defer counts.deinit(gpa);

    // 1,000 keys is far past any fixed capacity. The map grows.
    var key_buffer: [16]u8 = undefined;
    for (0..1000) |i| {
        const key = try std.fmt.bufPrint(&key_buffer, "key-{d}", .{i});
        // The map keeps the key slice, not a copy. A stack buffer would
        // dangle, so give the map keys that outlive it.
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        try counts.put(gpa, owned, @intCast(i));
    }
    defer {
        var it = counts.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
    }

    try std.testing.expectEqual(1000, counts.count());
    try std.testing.expectEqual(42, counts.get("key-42").?);
}
