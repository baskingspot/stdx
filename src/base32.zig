//! Crockford base32 codec for fixed-shape machine tokens.
//!
//! std has base64 but no base32. The shape here is the fixed one: a
//! token on the wire is exactly `8 * N / 5` Crockford symbols carrying
//! `N` bytes (`N` a multiple of 5), so the token round-trips to a
//! fixed-size binary key — smaller records, fixed-size equality instead
//! of a string compare, and the decode itself is the validation:
//! anything that fails to decode is garbage, no separate check.
//!
//! Machine-generated and strictly lowercase on the wire: encode emits
//! the lowercase Crockford alphabet (32 symbols, excluding `i`, `l`,
//! `o`, `u` — unambiguous when read aloud), and decode rejects
//! everything outside it — uppercase letters and the excluded letters
//! all fail. No case folding, no `O`/`I`/`L` aliases: an alias table
//! would make two spellings one token, which is exactly what a
//! stable-token scheme must not do.
//!
//! Allocation-free, fixed-shape, MSB-first packing, no padding path at
//! all — the bit counts close by construction.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Lowercase Crockford base32 alphabet: 32 symbols, excludes `i`, `l`,
/// `o`, `u`.
const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

/// Sentinel for a byte that is not a valid Crockford symbol.
const invalid: u8 = 0xFF;

/// 256-entry decode table: symbol byte to 5-bit value, or `invalid`.
/// Lowercase-only and case-sensitive: it maps ONLY the lowercase
/// alphabet symbols and digits. Uppercase letters and the excluded
/// letters stay `invalid`, so they fail to decode. No case folding, no
/// `O`/`I`/`L` aliases.
const decode_table: [256]u8 = blk: {
    var table: [256]u8 = @splat(invalid);
    for (alphabet, 0..) |c, i| {
        table[c] = i;
    }
    break :blk table;
};

/// Symbols that encode `N` bytes: `8 * N / 5`, an integer because
/// `N` is a multiple of 5.
pub fn SymbolCount(comptime N: comptime_int) type {
    comptime {
        if (N == 0 or N % 5 != 0) {
            // 5 bits per symbol close only when the byte count is a
            // multiple of 5.
            @compileError("base32: byte count must be a positive multiple of 5");
        }
    }
    return [8 * N / 5]u8;
}

/// Decode exactly `8 * N / 5` lowercase Crockford-base32 symbols into
/// `N` bytes, MSB-first. Case-sensitive: errors on any symbol outside
/// the lowercase alphabet — uppercase and the excluded letters
/// `i`/`l`/`o`/`u` all fail. No padding: the bit counts close by
/// construction.
pub fn decode(comptime N: comptime_int, src: *const [8 * N / 5]u8) error{InvalidSymbol}![N]u8 {
    var out: [N]u8 = @splat(0);
    var acc: u16 = 0;
    var bits: u4 = 0;
    var out_index: usize = 0;
    for (src) |symbol| {
        const value = decode_table[symbol];
        if (value == invalid) return error.InvalidSymbol;
        assert(value < 32);
        // acc carries only the `bits` pending bits (masked each
        // iteration), so the shift stays well within u16 and never
        // overflows.
        acc = (acc << 5) | value;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out[out_index] = @truncate(acc >> bits);
            out_index += 1;
            acc &= (@as(u16, 1) << bits) - 1;
        }
    }
    // `8 * N` input bits packed into exactly `N` bytes, none left over.
    assert(out_index == out.len);
    assert(bits == 0);
    return out;
}

/// Encode `N` bytes into `8 * N / 5` lowercase Crockford-base32
/// symbols, MSB-first. The exact inverse of `decode`.
pub fn encode(comptime N: comptime_int, bytes: *const [N]u8) SymbolCount(N) {
    var out: SymbolCount(N) = @splat('0');
    var acc: u16 = 0;
    var bits: u4 = 0;
    var out_index: usize = 0;
    for (bytes) |byte| {
        acc = (acc << 8) | byte;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            const value: u8 = @truncate((acc >> bits) & 0x1F);
            assert(value < 32);
            out[out_index] = alphabet[value];
            out_index += 1;
        }
        // Keep only the `bits` pending low bits so acc stays within u16.
        acc &= (@as(u16, 1) << bits) - 1;
    }
    // `8 * N` bits emitted as exactly `8 * N / 5` symbols, none left
    // over.
    assert(out_index == out.len);
    assert(bits == 0);
    return out;
}

test "round-trip: encode then decode is the identity" {
    const cases = [_][10]u8{
        @splat(0),
        @splat(0xFF),
        .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
        .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    };
    for (cases) |tok| {
        const decoded = try decode(10, &encode(10, &tok));
        try testing.expectEqualSlices(u8, &tok, &decoded);
    }
}

test "known-answer vectors (hand-verified MSB-first packing)" {
    // All-zero bytes: sixteen '0'.
    try testing.expectEqualStrings("0000000000000000", &encode(10, &@splat(0)));
    // All-ones bytes: sixteen 'z' (each 5-bit group is 0b11111 == 31).
    try testing.expectEqualStrings("zzzzzzzzzzzzzzzz", &encode(10, &@splat(0xFF)));
    // Value 1 lives in the lowest 5 bits: last symbol '1'.
    const one: [10]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectEqualStrings("0000000000000001", &encode(10, &one));
    // Low byte 0x1F is the lowest 5 bits set: last symbol 'z'.
    const low31: [10]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x1F };
    try testing.expectEqualStrings("000000000000000z", &encode(10, &low31));
    // Decode side of the vectors.
    try testing.expectEqual(@as([10]u8, @splat(0)), try decode(10, &"0000000000000000".*));
    try testing.expectEqual(@as([10]u8, @splat(0xFF)), try decode(10, &"zzzzzzzzzzzzzzzz".*));
}

test "every fixed shape round-trips, including the smallest" {
    // 5 bytes: 8 symbols — the smallest shape the bit counts close on.
    const small = [_]u8{ 0xAB, 0xCD, 0xEF, 0x01, 0x23 };
    const encoded = encode(5, &small);
    try testing.expectEqual(@as(usize, 8), encoded.len);
    try testing.expectEqualSlices(u8, &small, &(try decode(5, &encoded)));
    // 15 bytes: 24 symbols.
    const wide: [15]u8 = @splat(0x5A);
    const encoded_wide = encode(15, &wide);
    try testing.expectEqual(@as(usize, 24), encoded_wide.len);
    try testing.expectEqualSlices(u8, &wide, &(try decode(15, &encoded_wide)));
}

test "case-sensitive: uppercase and excluded letters are rejected" {
    // The wire contract is strictly lowercase. Uppercase input never
    // decodes, even for symbols that are valid in lowercase.
    try testing.expectError(error.InvalidSymbol, decode(10, &"ABCDEFGHJKMNPQRS".*));
    try testing.expectError(error.InvalidSymbol, decode(10, &"ABCDEFGHIJKLMNOP".*));
    try testing.expectError(error.InvalidSymbol, decode(10, &"ZZZZZZZZZZZZZZZZ".*));
    // No Crockford aliases: uppercase O/I/L do not fold to 0/1/1.
    try testing.expectError(error.InvalidSymbol, decode(10, &"OOOOOOOOOOOOOOIL".*));
    // The excluded letters are invalid in lowercase too.
    try testing.expectError(error.InvalidSymbol, decode(10, &"iiiiiiiiiiiiiiii".*));
    try testing.expectError(error.InvalidSymbol, decode(10, &"llllllllllllllll".*));
    try testing.expectError(error.InvalidSymbol, decode(10, &"oooooooooooooooo".*));
    try testing.expectError(error.InvalidSymbol, decode(10, &"uuuuuuuuuuuuuuuu".*));
    // Punctuation is not a symbol.
    try testing.expectError(error.InvalidSymbol, decode(10, &"!000000000000000".*));
}

test {
    testing.refAllDecls(@This());
}
