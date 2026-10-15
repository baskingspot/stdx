const std = @import("std");
const net = @import("stdx").net;
const Ip4 = net.Ip4;
const Prefix4 = net.Prefix4;

// A prefix from config text can carry host bits. `masked` returns the
// canonical form, so two spellings of one network compare equal.
test "canonical form" {
    const written: Prefix4 = .parseComptime("10.1.2.3/20");
    try std.testing.expectEqual(Prefix4.parseComptime("10.1.0.0/20"), written.masked());
}

test "containment works on any prefix length" {
    const subnet: Prefix4 = .parseComptime("10.1.16.0/20");
    try std.testing.expect(subnet.contains(.parseComptime("10.1.31.255")));
    try std.testing.expect(!subnet.contains(.parseComptime("10.1.32.0")));
}

// Two rules that cover a common address are usually a config mistake.
test "overlap detection" {
    const a: Prefix4 = .parseComptime("10.0.0.0/8");
    const b: Prefix4 = .parseComptime("10.1.0.0/16");
    const c: Prefix4 = .parseComptime("11.0.0.0/8");
    try std.testing.expect(a.overlaps(b));
    try std.testing.expect(b.overlaps(a));
    try std.testing.expect(!a.overlaps(c));
}

test "built from parts" {
    const subnet: Prefix4 = .init(.init(.{ 10, 1, 0, 0 }), 20);
    try std.testing.expectEqual(Prefix4.parseComptime("10.1.0.0/20"), subnet);
}

// A /32 is one host. Config that accepts either spelling can tell them
// apart without comparing bits.
test "a single host" {
    try std.testing.expect(Prefix4.parseComptime("10.1.2.3/32").isSingleIp());
    try std.testing.expect(!Prefix4.parseComptime("10.1.2.0/24").isSingleIp());
}

test "an address names its own prefix" {
    const addr: Ip4 = .parseComptime("10.1.2.3");
    try std.testing.expectEqual(Prefix4.parseComptime("10.1.2.0/24"), try addr.prefix(24));
    try std.testing.expectError(error.BitsOutOfRange, addr.prefix(33));
}

test "a prefix is parsed as strictly as an address" {
    try std.testing.expectError(error.NoSlash, Prefix4.parse("10.0.0.0"));
    try std.testing.expectError(error.BitsOutOfRange, Prefix4.parse("10.0.0.0/33"));
    try std.testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/08"));
    try std.testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/"));
}

test "a prefix formats with {f}" {
    const subnet: Prefix4 = .parseComptime("10.1.0.0/20");
    var text: [18]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&text, "{f}", .{subnet});
    try std.testing.expectEqualStrings("10.1.0.0/20", formatted);
}
