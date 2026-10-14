//! RFC 9562 UUIDs: generate (v4, v7), parse, format.
//!
//! Generation takes an `Io`: v4 draws all 128 bits from `Io.random`, v7
//! takes its timestamp from `Io.Timestamp` (`.real`) and the rest from
//! `Io.random`. v7 is ordered across milliseconds but not within one —
//! the monotonic counter of RFC 9562 §5.2 needs mutable state, which a
//! bare constructor refuses to smuggle, so callers that need same-ms
//! ordering serialize at their end.
//!
//! `parse` accepts the canonical 36-byte form, either case, and does not
//! reject unknown versions or variants: an unparseable future UUID is
//! still a UUID.

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;

const Uuid = @This();

bytes: [16]u8,

pub const nil: Uuid = .{ .bytes = @splat(0) };

pub const ParseError = error{
    /// Not exactly 36 bytes.
    InvalidLength,
    /// A hyphen is missing or misplaced.
    InvalidHyphen,
    /// A non-hex digit where one belongs.
    InvalidCharacter,
};

/// The version nibble.
pub const Version = enum(u4) {
    v1 = 1, // time + node
    v2 = 2, // dce security
    v3 = 3, // md5 name-based
    v4 = 4, // random
    v5 = 5, // sha1 name-based
    v6 = 6, // reordered time
    v7 = 7, // unix time + random
    v8 = 8, // custom
    _, // unknown — parse accepts forward versions
};

pub fn version(self: Uuid) Version {
    return @enumFromInt(self.bytes[6] >> 4);
}

/// Generate a v4 (random) UUID. Six bits are fixed: version 4, variant 10.
pub fn v4(io: Io) Uuid {
    var u: Uuid = undefined;
    io.random(&u.bytes);
    u.bytes[6] = (u.bytes[6] & 0x0f) | 0x40;
    u.bytes[8] = (u.bytes[8] & 0x3f) | 0x80;
    return u;
}

/// Generate a v7 UUID: the leading 48 bits are the Unix timestamp in
/// milliseconds, big-endian; the rest is random. Ordered across
/// milliseconds, unordered within one — see the module doc.
pub fn v7(io: Io) Uuid {
    var u: Uuid = undefined;
    io.random(&u.bytes);
    const ms: u64 = @intCast(@max(0, Io.Timestamp.now(io, .real).toMilliseconds()));
    u.bytes[0] = @truncate(ms >> 40);
    u.bytes[1] = @truncate(ms >> 32);
    u.bytes[2] = @truncate(ms >> 24);
    u.bytes[3] = @truncate(ms >> 16);
    u.bytes[4] = @truncate(ms >> 8);
    u.bytes[5] = @truncate(ms);
    u.bytes[6] = (u.bytes[6] & 0x0f) | 0x70;
    u.bytes[8] = (u.bytes[8] & 0x3f) | 0x80;
    return u;
}

/// Parse the canonical 36-byte form, either case.
pub fn parse(s: []const u8) ParseError!Uuid {
    if (s.len != 36) return error.InvalidLength;
    for ([_]usize{ 8, 13, 18, 23 }) |i| {
        if (s[i] != '-') return error.InvalidHyphen;
    }
    var u: Uuid = undefined;
    var out: usize = 0;
    for ([_][]const u8{ s[0..8], s[9..13], s[14..18], s[19..23], s[24..36] }) |group| {
        var i: usize = 0;
        while (i < group.len) : (i += 2) {
            const hi = fmt.charToDigit(group[i], 16) catch return error.InvalidCharacter;
            const lo = fmt.charToDigit(group[i + 1], 16) catch return error.InvalidCharacter;
            u.bytes[out] = (@as(u8, hi) << 4) | lo;
            out += 1;
        }
    }
    return u;
}

pub fn format(self: Uuid, w: *Io.Writer) Io.Writer.Error!void {
    const hex = fmt.bytesToHex(self.bytes, .lower);
    const groups = [_][]const u8{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] };
    for (groups, 0..) |group, i| {
        if (i != 0) try w.writeByte('-');
        try w.writeAll(group);
    }
}

pub fn eql(a: Uuid, b: Uuid) bool {
    const a_int: u128 = @bitCast(a.bytes);
    const b_int: u128 = @bitCast(b.bytes);
    return a_int == b_int;
}

test Uuid {
    const io = testing.io;

    // nil round-trips.
    try testing.expect(Uuid.nil.eql(try Uuid.parse("00000000-0000-0000-0000-000000000000")));

    // v4: fixed version/variant bits, distinct draws.
    const a = Uuid.v4(io);
    const b = Uuid.v4(io);
    try testing.expect(a.version() == .v4);
    try testing.expectEqual(@as(u8, 0x40), a.bytes[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), a.bytes[8] & 0xc0);
    try testing.expect(!a.eql(b));

    // v7: wall-aligned timestamp in the leading 48 bits, fixed bits.
    const c = Uuid.v7(io);
    try testing.expect(c.version() == .v7);
    const ts = mem.readInt(u48, c.bytes[0..6], .big);
    const now = Io.Timestamp.now(io, .real).toMilliseconds();
    try testing.expect(@abs(@as(i64, @intCast(ts)) - now) < 5_000);

    // Round trip: format then parse, either case.
    var buf: [36]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{c});
    try testing.expect(c.eql(try Uuid.parse(s)));

    var upper_buf: [36]u8 = undefined;
    for (s, &upper_buf) |ch, *dst| dst.* = std.ascii.toUpper(ch);
    try testing.expect(c.eql(try Uuid.parse(&upper_buf)));

    // RFC 9562's own v4 example round-trips.
    try testing.expectEqualStrings("f81d4fae-7dec-11d0-a765-00a0c91e6bf6", blk: {
        const ex = try Uuid.parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
        try testing.expect(ex.version() == .v1);
        var eb: [36]u8 = undefined;
        break :blk try std.fmt.bufPrint(&eb, "{f}", .{ex});
    });

    // Rejections: length, hyphen placement, non-hex digit.
    try testing.expectError(error.InvalidLength, Uuid.parse(""));
    try testing.expectError(error.InvalidLength, Uuid.parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf"));
    try testing.expectError(
        error.InvalidHyphen,
        Uuid.parse("f81d4faeX7dec-11d0-a765-00a0c91e6bf6"),
    );
    try testing.expectError(
        error.InvalidHyphen,
        Uuid.parse("f81d4fae:7dec-11d0-a765-00a0c91e6bf6"),
    );
    try testing.expectError(
        error.InvalidCharacter,
        Uuid.parse("g81d4fae-7dec-11d0-a765-00a0c91e6bf6"),
    );

    // Unknown versions parse: a future UUID is still a UUID.
    const future = try Uuid.parse("f81d4fae-7dec-91d0-a765-00a0c91e6bf6");
    try testing.expectEqual(@as(u4, 9), @intFromEnum(future.version()));
}
