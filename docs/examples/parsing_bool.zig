const std = @import("std");
const fmtx = @import("stdx").fmt;

test "parse a boolean" {
    try std.testing.expectEqual(true, fmtx.parseBool("TRUE").?);
    try std.testing.expectEqual(false, fmtx.parseBool("0").?);
    try std.testing.expectEqual(null, fmtx.parseBool("yes"));
}
