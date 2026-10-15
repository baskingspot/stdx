const std = @import("std");
const static_map = @import("stdx").static_map;

// The table is built at compile time from a literal. It has no runtime
// initialization, and a duplicate key is a compile error.
const Opcode = static_map.Auto(u8, []const u8, .{
    .{ 0x01, "push" },
    .{ 0x02, "pop" },
    .{ 0xff, "halt" },
});

test "lookup in a comptime table" {
    try std.testing.expectEqualStrings("halt", Opcode.get(0xff).?);
    try std.testing.expectEqual(null, Opcode.get(0x03));
    try std.testing.expect(Opcode.has(0x02));
    try std.testing.expectEqual(3, Opcode.count);
}

// The keys and values keep the order of the literal.
test "iteration follows the literal" {
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0xff }, Opcode.keys);
}
