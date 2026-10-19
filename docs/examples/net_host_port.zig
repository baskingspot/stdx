const std = @import("std");
const net = @import("stdx").net;

// Config text carries the port when it has one and relies on the service
// default when it does not.
test "split a config endpoint" {
    const cases = [_]struct { text: []const u8, host: []const u8, port: u16 }{
        .{ .text = "example.com", .host = "example.com", .port = 53 },
        .{ .text = "10.0.0.1:853", .host = "10.0.0.1", .port = 853 },
        .{ .text = "[2001:db8::1]:853", .host = "2001:db8::1", .port = 853 },
    };

    for (cases) |case| {
        const endpoint = try net.HostPort.parse(case.text, 53);
        try std.testing.expectEqualStrings(case.host, endpoint.host);
        try std.testing.expectEqual(case.port, endpoint.port);
    }

    // An IPv6 host without brackets is ambiguous.
    try std.testing.expectError(error.UnbracketedIpv6, net.HostPort.parse("::1", 53));
}
