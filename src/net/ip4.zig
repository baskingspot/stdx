//! The fast path for dotted-quad IPv4 parsing.
//!
//! Four overlapping 32-bit windows cover every octet: bytes 0..3 hold the
//! first octet and its dot, bytes 4..7 (or 0..3 when the string is 7 bytes)
//! hold the second, the last 4 bytes hold the fourth, and the third is loaded
//! once the first two dots are known. The windows load before the dots are
//! known, so the loads overlap.
//!
//! XOR with `'0'` turns digits into 0..9 and the dot into 0x1E, so the dot is
//! the only lane with bit 4 set. Dot positions fall out of `ctz`/`clz`, the
//! segments are aligned against the dots, and one SWAR pass rejects bad
//! lanes, overflow, and leading zeros. Two 64-bit multiplies fold the digits
//! into the four octets.
//!
//! Adapted from swift-endpoint's IPv4 parser (Apache-2.0); see
//! `THIRD_PARTY.md`. The leading-zero check is ours: upstream does not
//! reject `01.2.3.4`.

const std = @import("std");

/// Parses a canonical dotted quad and returns its octets in address order.
/// Returns null for anything else, so the caller keeps the std parser's
/// exact error set and error cases.
///
/// A one-off exhaustive run parsed all 2^32 canonical texts (see
/// `docs/slop/ipv4-parse.md`), so a valid address that reaches the error path
/// is a bug.
pub fn parseFast(text: []const u8) ?[4]u8 {
    const count = text.len;
    // The shortest dotted quad is "0.0.0.0"; the longest is 15 bytes.
    if (count < 7 or count > 15) return null;

    const m30: u64 = 0x3030303030303030;
    const m30_u32: u32 = 0x30303030;

    // Four windows, each loaded from a position that cannot overrun.
    const w1 = load32(text, 0);
    const window1 = w1 ^ m30_u32;
    const w2 = load32(text, (count >> 1) & 4);
    const window12 = (@as(u64, w1) | (@as(u64, w2) << 32)) ^ m30;
    const w4 = load32(text, count - 4);
    const window4 = w4 ^ m30_u32;

    // A dot's bit 4 lands in bit 8 of the next lane after `<< 4`. Masking
    // lanes 2 and 3 gives the first dot's end position: 16, 24, or 32.
    const m01: u32 = 0x01010000;
    const first_dot_end: u6 = @ctz((window1 << 4) & m01);
    const segment1 = window1 << @intCast(32 - first_dot_end);

    const after_first = window12 >> @intCast(first_dot_end);
    const second_dot_end: u6 = @ctz(@as(u32, @truncate(after_first)) << 4 & m01);
    const segment2 = @as(u32, @truncate(after_first)) << @intCast(32 - second_dot_end);

    // The third dot is the highest dot in the last window. `| 0x10` keeps
    // `clz` in range when the window holds no dot.
    const third_dot_clz: u6 = @clz((window4 & 0x00101010) | 0x10);
    const third_dot_mask: u32 = @truncate(@as(u64, 0x00000007FFFFFFFF) >> @intCast(third_dot_clz));
    const segment4 = window4 & ~third_dot_mask;

    // Segment 3's window starts wherever the last four bytes allow; align its
    // first digit to bit 0 once the first two dots are known.
    const w3_offset = count - 4 - (third_dot_clz >> 3);
    const window3 = load32(text, w3_offset) ^ m30_u32;
    const dots_end: u32 = @as(u32, first_dot_end) + @as(u32, second_dot_end);
    const extra_shift: i32 = @as(i32, @intCast(dots_end)) - @as(i32, @intCast(w3_offset << 3));
    // 0, 8, or 16 bits mean 3, 2, or 1 digits; anything else is malformed.
    if (@as(u32, @bitCast(extra_shift)) > 16) return null;
    const segment3 = window3 & (@as(u32, 0xFFFFFFFF) << @intCast(extra_shift));

    // Dot lanes become 0; padding lanes are already 0.
    const segments12 = (@as(u64, segment1) | (@as(u64, segment2) << 32)) ^ 0x1E0000001E000000;
    const segments34 = (@as(u64, segment3) | (@as(u64, segment4) << 24)) ^ 0x000000001E000000;

    // A valid digit lane is 0..9. Adding 0x7F to a dot lane (already 0) and
    // 0x76 to a digit lane leaves bit 7 clear; any other lane sets it.
    const m7f76: u64 = 0x7F7676767F767676;
    const invalid_lanes = ((segments12 +% m7f76) | segments12) |
        ((segments34 +% m7f76) | segments34);

    // Big-endian order puts each segment's hundreds digit in the byte that
    // decides whether the value exceeds 255.
    const m7dfa: u64 = 0x7DFAFA007DFAFA00;
    const overflows = (@byteSwap(segments12) +% m7dfa) | (@byteSwap(segments34) +% m7dfa);
    const invalid = (invalid_lanes & 0x8080808080808080) | (overflows & 0x8000000080000000);
    if (invalid != 0) return null;

    // Leading zero: the first digit is 0 and the next lane is a digit.
    // Segments 1-3 are followed by a dot, which is 0x1E after XOR, so it
    // fails the digit test. Segment 4 has no trailing dot inside the window.
    const first3_ok = ((window1 & 0xFF) != 0 or ((window1 >> 8) & 0xFF) > 9) and
        ((@as(u32, @truncate(after_first)) & 0xFF) != 0 or
            ((@as(u32, @truncate(after_first)) >> 8) & 0xFF) > 9) and
        (((window3 >> @intCast(extra_shift)) & 0xFF) != 0 or
            (((window3 >> @intCast(extra_shift)) >> 8) & 0xFF) > 9);
    const l4 = third_dot_clz >> 3;
    const last_ok = l4 == 1 or
        ((w4 >> @intCast(8 * (4 - l4))) & 0xFF) != '0';
    if (!first3_ok or !last_ok) return null;

    // 0x00640A01 is 100 << 16 | 10 << 8 | 1. The product puts each segment's
    // value in bits 16..23 of its 32-bit half; interleaving then packs the
    // four octets into one word.
    const values12 = segments12 *% 0x00640A01;
    const values34 = segments34 *% 0x00640A01;
    const interleaved = ((values12 >> 16) & 0x000000FF000000FF) |
        (values34 & 0x00FF000000FF0000);
    const address: u32 = @truncate(interleaved | (interleaved >> 24));
    // `address` is little-endian lanes; write them explicitly so the result
    // is [first, second, third, fourth] on a big-endian host too.
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, address, .little);
    return out;
}

inline fn load32(text: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, text[offset..][0..4], .little);
}
