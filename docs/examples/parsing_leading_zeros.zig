const std = @import("std");
const fmtx = @import("stdx").fmt;

// The options are comptime. Each configuration compiles to its own loop.
// This one is the JSON grammar for integers: no leading zeros.
fn jsonInt(text: []const u8) !u32 {
    return fmtx.atoiWith(u32, text, .{ .leading_zeros = .reject });
}

test "leading zeros" {
    try std.testing.expectEqual(0, try jsonInt("0"));
    try std.testing.expectEqual(42, try jsonInt("42"));
    try std.testing.expectError(error.InvalidCharacter, jsonInt("042"));

    // The default allows them, like std.fmt.parseInt.
    try std.testing.expectEqual(42, try fmtx.atoi(u32, "042"));
}
