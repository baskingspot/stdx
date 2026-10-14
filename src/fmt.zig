//! Format extensions to `std.fmt`.
//!
//! Strict decode and parse helpers where `std.fmt` is liberal: no bases, no
//! underscores, no leftover characters — and bad comptime literals are
//! compile errors, not runtime ones.

const std = @import("std");
const testing = std.testing;

const atoi_mod = @import("fmt/atoi.zig");
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
