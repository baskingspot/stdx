//! Format extensions to `std.fmt`.
//!
//! Strict decode and parse helpers where `std.fmt` is liberal: one integer
//! grammar, Go's boolean spellings, no bases, no underscores. Bad comptime
//! literals are compile errors, not runtime ones.

const std = @import("std");
const testing = std.testing;

const atoi_mod = @import("fmt/atoi.zig");
const static_map = @import("static_map.zig");

pub const atoi = atoi_mod.atoi;
pub const atoiUnchecked = atoi_mod.atoiUnchecked;
pub const atoiWith = atoi_mod.atoiWith;

test {
    testing.refAllDecls(@This());
}

/// Decode the comptime hex literal `encoded`. The output length is half the
/// literal's length; a bad literal is a compile error.
pub inline fn comptimeHex(comptime encoded: []const u8) [encoded.len / 2]u8 {
    comptime {
        // Callers decode many vectors in one file, and the comptime branch
        // budget is shared across those evaluations. Scale it with the
        // literal so a TLS-sized key or signature does not run it out.
        @setEvalBranchQuota(@intCast(10_000 + encoded.len * 32));
        var out: [encoded.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, encoded) catch unreachable;
        return out;
    }
}

test comptimeHex {
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, &comptimeHex("deadbeef"));
    try testing.expectEqualSlices(u8, &.{}, &comptimeHex(""));
    try testing.expectEqualSlices(u8, &.{0xab}, &comptimeHex("ab"));
}

test "comptimeHex: repeated decodes share one budget" {
    // Callers decode many vectors in one file. Without a quota inside
    // `comptimeHex`, the shared comptime budget runs out partway through.
    inline for (0..8) |_| {
        const bytes = comptimeHex("0123456789abcdef" ** 32);
        try testing.expectEqual(@as(u8, 0xef), bytes[255]);
    }
}

test "comptimeHex: a long literal" {
    // A TLS-sized vector (a 2048-bit modulus) decodes past the default
    // comptime branch budget for `hexToBytes`.
    const bytes = comptimeHex("0123456789abcdef" ** 32);
    try testing.expectEqual(@as(usize, 256), bytes.len);
    try testing.expectEqual(@as(u8, 0x01), bytes[0]);
    try testing.expectEqual(@as(u8, 0xef), bytes[255]);
}

/// Parse a boolean with the spellings of Go's `strconv.ParseBool`: `1`, `t`,
/// `T`, `TRUE`, `true`, `True`, and the same set for false. Returns null for
/// anything else.
pub fn parseBool(raw: []const u8) ?bool {
    return static_map.String(bool, .{
        .{ "true", true },
        .{ "TRUE", true },
        .{ "True", true },
        .{ "t", true },
        .{ "T", true },
        .{ "1", true },
        .{ "false", false },
        .{ "FALSE", false },
        .{ "False", false },
        .{ "f", false },
        .{ "F", false },
        .{ "0", false },
    }).get(raw);
}

test parseBool {
    try testing.expect(parseBool("true").?);
    try testing.expect(parseBool("TRUE").?);
    try testing.expect(parseBool("True").?);
    try testing.expect(parseBool("t").?);
    try testing.expect(parseBool("T").?);
    try testing.expect(parseBool("1").?);
    try testing.expect(!parseBool("false").?);
    try testing.expect(!parseBool("FALSE").?);
    try testing.expect(!parseBool("False").?);
    try testing.expect(!parseBool("f").?);
    try testing.expect(!parseBool("F").?);
    try testing.expect(!parseBool("0").?);
    try testing.expectEqual(null, parseBool(""));
    try testing.expectEqual(null, parseBool("nope"));
    try testing.expectEqual(null, parseBool("TrUe"));
    try testing.expectEqual(null, parseBool("yes"));
}
