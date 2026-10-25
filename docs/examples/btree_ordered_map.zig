const std = @import("std");
const btree = @import("stdx").btree;

// An ordered map keeps the keys sorted. Iteration reads the keys in that
// order, and lookups go by key, not by an insertion position.
const Scores = btree.Auto(u32, u32);

test "an ordered map iterates in key order" {
    const gpa = std.testing.allocator;

    // The map grows, so every call that can allocate takes the allocator.
    var scores: Scores = .empty;
    defer scores.clearAndFree(gpa);

    // Insertion order is 30, 10, 20. Key order is 10, 20, 30.
    try scores.put(gpa, 30, 7);
    try scores.put(gpa, 10, 3);
    try scores.put(gpa, 20, 5);
    // A repeated key replaces the value and keeps its place in the order.
    try scores.put(gpa, 10, 4);

    var it = scores.iterator();
    var previous: ?u32 = null;
    var seen: usize = 0;
    while (it.next()) |entry| {
        if (previous) |key| try std.testing.expect(key < entry.key_ptr.*);
        previous = entry.key_ptr.*;
        seen += 1;
    }

    try std.testing.expectEqual(3, seen);
    try std.testing.expectEqual(4, scores.get(10).?);
    try std.testing.expectEqual(null, scores.get(15));
    try std.testing.expect(scores.remove(gpa, 30));
}

test "string keys keep their order too" {
    const gpa = std.testing.allocator;

    var files: btree.String(u32) = .empty;
    defer files.clearAndFree(gpa);

    // The map keeps the key slice, not a copy. String literals live for the
    // whole program, so they outlive the map.
    try files.put(gpa, "src/btree.zig", 40);
    try files.put(gpa, "src/btree/map.zig", 900);
    try files.put(gpa, "build.zig", 30);

    var it = files.iterator();
    try std.testing.expectEqualStrings("build.zig", it.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("src/btree.zig", it.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("src/btree/map.zig", it.next().?.key_ptr.*);
    try std.testing.expectEqual(null, it.next());

    // Start anywhere in the order: everything from "src/" upward.
    var tail = files.iteratorFrom("src/", true);
    try std.testing.expectEqualStrings("src/btree.zig", tail.next().?.key_ptr.*);
    try std.testing.expectEqualStrings("src/btree/map.zig", tail.next().?.key_ptr.*);
    try std.testing.expectEqual(null, tail.next());
}
