const std = @import("std");
const fmtx = @import("stdx").fmt;

// The options are comptime. Each configuration compiles to its own loop.
// This one is the JSON grammar for integers: no leading zeros, and no `+`.
fn jsonInt(text: []const u8) !i64 {
    return fmtx.atoiWith(i64, text, .{
        .leading_zeros = .reject,
        .plus_sign = .reject,
    });
}

// Bencode goes one step further: an optional `-`, then digits, and no
// negative zero.
fn bencodeInt(text: []const u8) !i64 {
    return fmtx.atoiWith(i64, text, .{
        .leading_zeros = .reject,
        .plus_sign = .reject,
        .negative_zero = .reject,
    });
}

test "the JSON integer grammar" {
    try std.testing.expectEqual(0, try jsonInt("0"));
    try std.testing.expectEqual(42, try jsonInt("42"));
    try std.testing.expectEqual(-1, try jsonInt("-1"));

    try std.testing.expectError(error.InvalidCharacter, jsonInt("+42"));
    try std.testing.expectError(error.InvalidCharacter, jsonInt("042"));

    // JSON does allow negative zero, which parses as 0.
    try std.testing.expectEqual(0, try jsonInt("-0"));

    // The default allows both, like std.fmt.parseInt.
    try std.testing.expectEqual(42, try fmtx.atoi(i64, "+042"));
}

test "the bencode integer grammar" {
    try std.testing.expectEqual(-1, try bencodeInt("-1"));
    try std.testing.expectError(error.InvalidCharacter, bencodeInt("-0"));
    try std.testing.expectError(error.InvalidCharacter, bencodeInt("+1"));
    try std.testing.expectError(error.InvalidCharacter, bencodeInt("007"));
}
