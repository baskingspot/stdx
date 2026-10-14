//! Networking extensions to `std.Io.net`.
//!
//! IPv4 addressing: a portless address and CIDR prefixes, following
//! `net.Ip4Address` and Go's `net/netip`. fd-level socket helpers live in
//! `posixx`.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Io = std.Io;
const net = Io.net;
const math = std.math;
pub const Ip4Address = net.Ip4Address;
pub const Ip6Address = net.Ip6Address;
pub const IpAddress = net.IpAddress;

const fmtx = @import("fmtx.zig");

pub const Ip4 = struct {
    bytes: [4]u8,

    pub const unspecified: Ip4 = .{ .bytes = @splat(0) };

    pub const loopback: Ip4 = .{ .bytes = .{ 127, 0, 0, 1 } };

    pub const broadcast: Ip4 = .{ .bytes = .{ 255, 255, 255, 255 } };

    pub const ParseError = Ip4Address.ParseError;

    pub fn init(octets: [4]u8) Ip4 {
        return .{ .bytes = octets };
    }

    /// Parse dotted-quad notation, with `Ip4Address.parse` semantics:
    /// hostnames and IPv6 are parse errors, and non-canonical quads (leading
    /// zeros) are too.
    pub fn parse(buf: []const u8) ParseError!Ip4 {
        const std_addr = try Ip4Address.parse(buf, 0);
        return .{ .bytes = std_addr.bytes };
    }

    /// Converts from an IPv4-mapped IPv6 address, or returns null.
    pub fn fromIp6(ip6: Ip6Address) ?Ip4 {
        return if (mem.eql(u8, ip6.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) .{
            .bytes = ip6.bytes[12..].*,
        } else null;
    }

    /// Given an `Ip4Address`, converts it to an `Ip4` stripping the port.
    pub fn fromIp4(ip4: Ip4Address) Ip4 {
        return .{ .bytes = ip4.bytes };
    }

    /// Given an `IpAddress`, converts it to an `Ip4` directly, or from an
    /// IPv4-mapped IPv6 address, or returns null.
    pub fn fromAny(addr: IpAddress) ?Ip4 {
        return switch (addr) {
            .ip4 => |ip4| .{ .bytes = ip4.bytes },
            .ip6 => |ip6| fromIp6(ip6),
        };
    }

    pub fn eql(a: Ip4, b: Ip4) bool {
        const a_int: u32 = @bitCast(a.bytes);
        const b_int: u32 = @bitCast(b.bytes);
        return a_int == b_int;
    }

    pub fn isUnspecified(self: Ip4) bool {
        return self.eql(.unspecified);
    }

    /// 127.0.0.0/8.
    pub fn isLoopback(self: Ip4) bool {
        return self.bytes[0] == 127;
    }

    /// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    pub fn isPrivate(self: Ip4) bool {
        return switch (self.bytes[0]) {
            10 => true,
            172 => (self.bytes[1] & 0xF0) == 0x10,
            192 => self.bytes[1] == 168,
            else => false,
        };
    }

    /// 224.0.0.0/4.
    pub fn isMulticast(self: Ip4) bool {
        return (self.bytes[0] & 0xF0) == 0xE0;
    }

    /// 169.254.0.0/16.
    pub fn isLinkLocalUnicast(self: Ip4) bool {
        return self.bytes[0] == 169 and self.bytes[1] == 254;
    }

    pub fn isBroadcast(self: Ip4) bool {
        return self.eql(.broadcast);
    }

    /// Matches Go netip: private and link-local addresses still count as
    /// global unicast — they are routable, just not on the public internet.
    pub fn isGlobalUnicast(self: Ip4) bool {
        return !self.isUnspecified() and !self.isLoopback() and
            !self.isBroadcast() and !self.isMulticast();
    }

    /// Dotted-quad numeric order: lexicographic octet order, endian-free.
    /// Follows the std convention of returning `math.Order`.
    pub fn order(self: Ip4, other: Ip4) math.Order {
        for (self.bytes, other.bytes) |a, b| {
            switch (math.order(a, b)) {
                .eq => continue,
                .lt => return .lt,
                .gt => return .gt,
            }
        }
        return .eq;
    }

    /// The next address in numeric order, or null past 255.255.255.255.
    pub fn next(self: Ip4) ?Ip4 {
        const value = mem.readInt(u32, &self.bytes, .big);
        if (value == math.maxInt(u32)) return null;
        var bytes: [4]u8 = undefined;
        mem.writeInt(u32, &bytes, value + 1, .big);
        return .{ .bytes = bytes };
    }

    /// The previous address in numeric order, or null before 0.0.0.0.
    pub fn prev(self: Ip4) ?Ip4 {
        const value = mem.readInt(u32, &self.bytes, .big);
        if (value == 0) return null;
        var bytes: [4]u8 = undefined;
        mem.writeInt(u32, &bytes, value - 1, .big);
        return .{ .bytes = bytes };
    }

    /// The prefix of `bits` bits with this address as its network address,
    /// masked to canonical form, like Go's `Addr.Prefix`.
    pub fn prefix(self: Ip4, bits: u8) error{BitsOutOfRange}!Prefix4 {
        if (bits > 32) return error.BitsOutOfRange;
        const p: Prefix4 = .{ .addr = self, .bits = bits };
        return p.masked();
    }

    /// Returns null unless `slice` is exactly 4 bytes, like Go's
    /// `AddrFromSlice`.
    pub fn fromSlice(slice: []const u8) ?Ip4 {
        if (slice.len != 4) return null;
        return .{ .bytes = slice[0..4].* };
    }

    pub fn withPort(self: Ip4, port: u16) Ip4Address {
        return .{ .bytes = self.bytes, .port = port };
    }

    pub fn format(self: Ip4, w: *Io.Writer) Io.Writer.Error!void {
        const o = &self.bytes;
        try w.print("{d}.{d}.{d}.{d}", .{ o[0], o[1], o[2], o[3] });
    }
};

test Ip4 {
    const addr: Ip4 = try .parse("10.1.2.3");
    try testing.expectEqual([4]u8{ 10, 1, 2, 3 }, addr.bytes);
    try testing.expectEqual(addr, Ip4.init(.{ 10, 1, 2, 3 }));
    try testing.expect(addr.eql(try .parse("10.1.2.3")));
    try testing.expect(!addr.eql(.unspecified));
    try testing.expect(Ip4.unspecified.isUnspecified());
    try testing.expect(Ip4.loopback.eql(try .parse("127.0.0.1")));

    // Parse errors mirror Ip4Address.ParseError.
    try testing.expectError(error.InvalidCharacter, Ip4.parse("host"));
    try testing.expectError(error.InvalidCharacter, Ip4.parse("::1"));
    try testing.expectError(error.Incomplete, Ip4.parse(""));
    try testing.expectError(error.NonCanonical, Ip4.parse("10.01.2.3"));

    // Conversions mirror Ip4Address: fromIp6 unwraps IPv4-mapped IPv6,
    // fromAny takes either arm of IpAddress.
    const mapped = Ip6Address.fromIp4(.{ .bytes = addr.bytes, .port = 0 });
    try testing.expect(Ip4.fromIp6(mapped).?.eql(addr));
    try testing.expect(Ip4.fromAny(.{ .ip4 = .{ .bytes = addr.bytes, .port = 0 } }).?.eql(addr));
    try testing.expect(Ip4.fromAny(.{ .ip6 = mapped }).?.eql(addr));
    try testing.expect(Ip4.fromIp6(Ip6Address.loopback(0)) == null);

    // Classification, matching Go netip semantics.
    try testing.expect(testIp("127.0.0.1").isLoopback());
    try testing.expect(!testIp("126.255.255.255").isLoopback());
    try testing.expect(testIp("10.0.0.1").isPrivate());
    try testing.expect(testIp("172.31.255.1").isPrivate());
    try testing.expect(!testIp("172.32.0.1").isPrivate());
    try testing.expect(testIp("192.168.0.1").isPrivate());
    try testing.expect(!testIp("192.169.0.1").isPrivate());
    try testing.expect(testIp("224.0.0.1").isMulticast());
    try testing.expect(testIp("239.255.255.255").isMulticast());
    try testing.expect(!testIp("240.0.0.1").isMulticast());
    try testing.expect(testIp("169.254.0.1").isLinkLocalUnicast());
    try testing.expect(!testIp("169.253.0.1").isLinkLocalUnicast());
    try testing.expect(testIp("255.255.255.255").isBroadcast());
    try testing.expect(testIp("8.8.8.8").isGlobalUnicast());
    // Private addresses are global unicast, matching Go.
    try testing.expect(testIp("10.1.2.3").isGlobalUnicast());
    try testing.expect(!testIp("127.0.0.1").isGlobalUnicast());
    try testing.expect(!Ip4.unspecified.isGlobalUnicast());

    // Ordering: lexicographic octet order is numeric order.
    try testing.expect(testIp("10.0.0.2").order(testIp("10.0.0.3")) == .lt);
    try testing.expect(testIp("10.0.0.3").order(testIp("10.0.0.2")) == .gt);
    try testing.expect(addr.order(try .parse("10.1.2.3")) == .eq);
    try testing.expect(testIp("10.0.0.255").order(testIp("10.0.1.0")) == .lt);
    try testing.expect(testIp("2.0.0.0").order(testIp("10.0.0.0")) == .lt);

    // Arithmetic.
    try testing.expectEqual(testIp("10.0.0.2"), testIp("10.0.0.1").next());
    // Octet carry.
    try testing.expectEqual(testIp("10.0.1.0"), testIp("10.0.0.255").next());
    try testing.expect(Ip4.broadcast.next() == null);
    try testing.expectEqual(testIp("10.0.0.1"), testIp("10.0.0.2").prev());
    try testing.expect(Ip4.unspecified.prev() == null);

    // fromSlice.
    try testing.expectEqual(addr, Ip4.fromSlice(&.{ 10, 1, 2, 3 }));
    try testing.expect(Ip4.fromSlice(&.{ 10, 1, 2 }) == null);

    const with_port = addr.withPort(5432);
    try testing.expectEqual([4]u8{ 10, 1, 2, 3 }, with_port.bytes);
    try testing.expectEqual(@as(u16, 5432), with_port.port);

    var buf: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{addr});
    try testing.expectEqualStrings("10.1.2.3", formatted);
}

fn testIp(comptime s: []const u8) Ip4 {
    return Ip4.parse(s) catch unreachable;
}

/// IPv4 CIDR prefix: an `Ip4` network address plus a prefix length in bits.
/// IPv6 prefixes are parse errors: a caller that needs dual-stack matching
/// composes two prefixes itself.
pub const Prefix4 = struct {
    addr: Ip4,
    bits: u8,

    pub const ParseError = Ip4.ParseError || error{
        /// No '/' in the input.
        NoSlash,
        /// The bits field was empty, non-canonical, or not a plain integer.
        InvalidBits,
        /// The prefix length exceeds 32.
        BitsOutOfRange,
    };

    pub fn parse(s: []const u8) ParseError!Prefix4 {
        const addr_str, const bits_str = mem.cutScalar(u8, s, '/') orelse
            return error.NoSlash;
        // Address first, like Go netip: an IPv6 string reports the address
        // error, not the bits error its /128 would produce under v4 rules.
        const addr = try Ip4.parse(addr_str);
        // Canonical CIDR bits, like Go netip: leading zeros are a parse
        // error (InvalidBits via atoi), and "/0" alone is valid. Empty bits
        // and non-digits also fail inside atoi.
        const bits = fmtx.atoiWith(u8, bits_str, .{ .leading_zeros = .reject }) catch
            return error.InvalidBits;
        if (bits > 32) return error.BitsOutOfRange;
        return .{ .addr = addr, .bits = bits };
    }

    /// Containment by octet-prefix compare: whole octets match exactly, then
    /// the leading bits of the next octet are masked. No endian conversion.
    pub fn contains(self: Prefix4, ip: Ip4) bool {
        const whole = self.bits / 8;
        const rem = self.bits % 8;
        if (whole > 0 and !mem.eql(u8, self.addr.bytes[0..whole], ip.bytes[0..whole])) {
            return false;
        }
        if (rem == 0) return true;
        // rem is 1..7 here, so the shift amount is 1..7 and fits u3.
        const mask: u8 = @as(u8, 0xFF) << @intCast(8 - rem);
        return (self.addr.bytes[whole] & mask) == (ip.bytes[whole] & mask);
    }

    /// The canonical form with host bits zeroed, like Go's `Prefix.Masked`.
    pub fn masked(self: Prefix4) Prefix4 {
        var out = self;
        const whole = self.bits / 8;
        const rem = self.bits % 8;
        if (rem == 0) {
            @memset(out.addr.bytes[whole..], 0);
        } else {
            const mask: u8 = @as(u8, 0xFF) << @intCast(8 - rem);
            out.addr.bytes[whole] &= mask;
            @memset(out.addr.bytes[whole + 1 ..], 0);
        }
        return out;
    }

    /// Whether the two prefixes cover at least one common address: one
    /// contains the other's network address.
    pub fn overlaps(self: Prefix4, other: Prefix4) bool {
        return self.contains(other.addr) or other.contains(self.addr);
    }
};

test Prefix4 {
    const p8: Prefix4 = try .parse("10.0.0.0/8");
    try testing.expect(p8.contains(testIp("10.255.0.1")));
    try testing.expect(!p8.contains(testIp("11.0.0.1")));

    // Non-octet-aligned prefix length: exercises the masked partial octet.
    const p20: Prefix4 = try .parse("10.1.16.0/20");
    try testing.expect(p20.contains(testIp("10.1.31.255")));
    try testing.expect(!p20.contains(testIp("10.1.32.0")));

    const p32: Prefix4 = try .parse("1.2.3.4/32");
    try testing.expect(p32.contains(testIp("1.2.3.4")));
    try testing.expect(!p32.contains(testIp("1.2.3.5")));

    const p0: Prefix4 = try .parse("0.0.0.0/0");
    try testing.expect(p0.contains(testIp("255.255.255.255")));

    try testing.expectError(error.NoSlash, Prefix4.parse("10.0.0.0"));
    try testing.expectError(error.BitsOutOfRange, Prefix4.parse("10.0.0.0/33"));
    // IPv6 is unsupported end to end: the address errors pass through.
    try testing.expectError(error.InvalidCharacter, Prefix4.parse("::1/128"));
    // "2001" overflows a u8 octet; "::1" is a non-digit: both pass
    // through from the address parser.
    try testing.expectError(error.Overflow, Prefix4.parse("2001:db8::/32"));
    try testing.expectError(error.InvalidCharacter, Prefix4.parse("bogus/8"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/"));

    // Bits parse via fmtx.atoi: signs, whitespace, and underscores are
    // rejected where std.fmt.parseInt accepted them.
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/+8"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/-8"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/ 8"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/1_6"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/256"));
    // Leading zeros in bits are non-canonical, matching Go netip; "/0" alone
    // is valid.
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/08"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("10.0.0.0/00"));
    try testing.expectError(error.InvalidBits, Prefix4.parse("0.0.0.0/032"));
    try testing.expect((try Prefix4.parse("0.0.0.0/0")).contains(testIp("255.255.255.255")));

    // masked: host bits zeroed to canonical form.
    try testing.expectEqual(
        try Prefix4.parse("10.1.0.0/20"),
        (try Prefix4.parse("10.1.2.3/20")).masked(),
    );
    try testing.expectEqual(p32, (try Prefix4.parse("1.2.3.4/32")).masked());
    try testing.expectEqual(p0, (try Prefix4.parse("255.255.255.255/0")).masked());

    // overlaps.
    try testing.expect(p8.overlaps(try Prefix4.parse("10.1.0.0/16")));
    try testing.expect((try Prefix4.parse("10.1.0.0/16")).overlaps(p8));
    try testing.expect(!p8.overlaps(try Prefix4.parse("11.0.0.0/8")));
    try testing.expect(p20.overlaps(p20));

    // addr.prefix(bits).
    const from_addr = try testIp("10.1.2.3").prefix(20);
    try testing.expectEqual(try Prefix4.parse("10.1.0.0/20"), from_addr);
    try testing.expectError(error.BitsOutOfRange, testIp("10.0.0.1").prefix(33));
}
