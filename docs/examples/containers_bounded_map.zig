const std = @import("std");
const bounded_array_hash_map = @import("stdx").bounded_array_hash_map;

// Keys and values live in arrays inside the value. Iteration follows
// insertion order.
const Names = bounded_array_hash_map.Auto(u32, []const u8, 2);

test "a full map refuses new keys" {
    var names: Names = .init;
    try names.put(10, "ten");
    try names.put(20, "twenty");

    // A new key does not fit.
    try std.testing.expectError(error.NoSpaceLeft, names.put(30, "thirty"));

    // An existing key still updates in place, and keeps its position.
    try names.put(10, "TEN");
    try std.testing.expectEqualStrings("TEN", names.get(10).?);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, names.keys());
}
