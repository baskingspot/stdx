const std = @import("std");
const fmtx = @import("stdx").fmt;

// An HTTP Content-Length header is machine-written. It has one grammar:
// decimal digits and nothing else.
fn contentLength(value: []const u8) !u64 {
    return fmtx.atoi(u64, value);
}

test "plain digits parse" {
    try std.testing.expectEqual(1024, try contentLength("1024"));
}

test "everything else is an error" {
    // The whole string must be the number.
    try std.testing.expectError(error.InvalidCharacter, contentLength("1024 "));
    try std.testing.expectError(error.InvalidCharacter, contentLength("0x400"));
    try std.testing.expectError(error.InvalidCharacter, contentLength("1_000"));
    try std.testing.expectError(error.InvalidCharacter, contentLength(""));

    // A value too large for the type is a different error.
    try std.testing.expectError(error.Overflow, contentLength("18446744073709551616"));
}

test "std.fmt.parseInt reads input that people write" {
    // std accepts underscores. That suits a config value and is wrong for a
    // header.
    try std.testing.expectEqual(1000, try std.fmt.parseInt(u64, "1_000", 10));
}
