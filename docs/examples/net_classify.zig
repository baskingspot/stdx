const std = @import("std");
const Ip4 = @import("stdx").net.Ip4;

// Following Go's net/netip, a private or link-local address counts as
// global unicast: it is routable, just not on the public internet. Code
// that means "public" must say so.
fn isPublic(addr: Ip4) bool {
    return addr.isGlobalUnicast() and !addr.isPrivate() and !addr.isLinkLocalUnicast();
}

test "public means more than global unicast" {
    try std.testing.expect(isPublic(.parseComptime("8.8.8.8")));

    const private: Ip4 = .parseComptime("10.1.2.3");
    try std.testing.expect(private.isGlobalUnicast());
    try std.testing.expect(!isPublic(private));

    try std.testing.expect(!isPublic(.parseComptime("169.254.1.1")));
}

test "the other classes" {
    try std.testing.expect(Ip4.parseComptime("127.0.0.1").isLoopback());
    try std.testing.expect(Ip4.parseComptime("172.16.0.1").isPrivate());
    try std.testing.expect(!Ip4.parseComptime("172.32.0.1").isPrivate());
    try std.testing.expect(Ip4.broadcast.isBroadcast());
    try std.testing.expect(Ip4.unspecified.isUnspecified());
}

test "multicast and its link-local block" {
    const all_hosts: Ip4 = .parseComptime("224.0.0.1");
    try std.testing.expect(all_hosts.isMulticast());
    try std.testing.expect(all_hosts.isLinkLocalMulticast());
    try std.testing.expect(!all_hosts.isGlobalUnicast());

    // Multicast outside 224.0.0.0/24 is not link-local.
    const other: Ip4 = .parseComptime("239.1.2.3");
    try std.testing.expect(other.isMulticast());
    try std.testing.expect(!other.isLinkLocalMulticast());
}
