const std = @import("std");
const net = @import("stdx").net;
const Ip4 = net.Ip4;

// A dual-stack listener reports an IPv4 peer as an IPv4-mapped IPv6
// address. `fromAny` gives the same `Ip4` for both spellings.
test "fromAny sees through an IPv4-mapped address" {
    const ip: Ip4 = .parseComptime("10.1.2.3");
    const native: net.IpAddress = .{ .ip4 = ip.withPort(5432) };
    const mapped: net.IpAddress = .{ .ip6 = .fromIp4(ip.withPort(5432)) };

    try std.testing.expectEqual(ip, Ip4.fromAny(native).?);
    try std.testing.expectEqual(ip, Ip4.fromAny(mapped).?);

    // A real IPv6 address has no IPv4 form.
    try std.testing.expectEqual(null, Ip4.fromAny(.{ .ip6 = .loopback(0) }));
}

test "an address and a port make a socket address" {
    const ip: Ip4 = .parseComptime("10.1.2.3");
    const socket_addr = ip.withPort(8080);
    try std.testing.expectEqual(8080, socket_addr.port);
    try std.testing.expectEqual(ip, Ip4.fromIp4(socket_addr));
}

test "fromSlice needs exactly four bytes" {
    try std.testing.expectEqual(Ip4.parseComptime("10.1.2.3"), Ip4.fromSlice(&.{ 10, 1, 2, 3 }));
    try std.testing.expectEqual(null, Ip4.fromSlice(&.{ 10, 1, 2 }));
}

test "an address formats with {f}" {
    const ip: Ip4 = .parseComptime("10.1.2.3");
    var text: [15]u8 = undefined;
    try std.testing.expectEqualStrings("10.1.2.3", try std.fmt.bufPrint(&text, "{f}", .{ip}));
}
