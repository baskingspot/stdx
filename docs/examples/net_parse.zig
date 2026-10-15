const std = @import("std");
const Ip4 = @import("stdx").net.Ip4;

// An address has one canonical text form. Every other input is an error
// that names the problem.
test "parse accepts the canonical form" {
    const ip: Ip4 = try .parse("10.1.2.3");
    try std.testing.expectEqual(Ip4.init(.{ 10, 1, 2, 3 }), ip);
}

test "parse names what went wrong" {
    try std.testing.expectError(error.InvalidCharacter, Ip4.parse("example.com"));
    try std.testing.expectError(error.InvalidCharacter, Ip4.parse("::1"));
    try std.testing.expectError(error.Incomplete, Ip4.parse(""));
    try std.testing.expectError(error.NonCanonical, Ip4.parse("10.01.2.3"));
}

// A literal in code is parsed at compile time. A typo is a compile error
// that quotes the string, not a runtime failure.
test "parseComptime for literals" {
    const ip: Ip4 = .parseComptime("10.1.2.3");
    try std.testing.expectEqual(Ip4.init(.{ 10, 1, 2, 3 }), ip);
}

test "the well-known addresses are constants" {
    try std.testing.expectEqual(Ip4.parseComptime("127.0.0.1"), Ip4.loopback);
    try std.testing.expectEqual(Ip4.parseComptime("0.0.0.0"), Ip4.unspecified);
    try std.testing.expectEqual(Ip4.parseComptime("255.255.255.255"), Ip4.broadcast);
}
