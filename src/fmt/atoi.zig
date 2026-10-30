//! Plain base-10 integer parsing: `std.fmt.parseInt` without the format
//! negotiation.
//!
//! `atoi` accepts an optional sign (for signed `T` only), then decimal
//! digits; the whole string must be the number. No underscores, no base
//! prefixes, no `base` parameter. `Options` selects overflow and leading-zero
//! behavior at comptime, so each configuration compiles to its own
//! specialization with no runtime option dispatch: `atoiWith` takes the
//! options explicitly, while `atoi` and `atoiUnchecked` bake in the common
//! configurations.
//!
//! The hot path uses SWAR digit processing, transcribed from fast_float's
//! `ascii_number.h` (credit @aqrit). Types too narrow to ever hold the
//! chunk's value compile the SWAR out entirely — a `u8` tops out at 3
//! digits. For types no wider than 64 bits, overflow is detected after
//! the parse (fast_float's strategy): the accumulator wraps — defined, via
//! `*%` — and the digit count plus a 20-digit boundary check decide, so the
//! checked and unchecked loops are identical. Wider types check each
//! operation instead.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;

/// The error set for the given overflow mode. `.checked` adds `Overflow`;
/// `.unchecked` cannot return it.
///
/// - `Overflow`: the value does not fit `T`. See `Overflow.checked`.
/// - `InvalidCharacter`: the input was empty, had no digits, or contained a
///   non-digit byte.
fn Error(comptime o: Overflow) type {
    return switch (o) {
        .checked => error{ Overflow, InvalidCharacter },
        .unchecked => error{InvalidCharacter},
    };
}

/// How `atoi` treats a value that exceeds the range of `T`.
pub const Overflow = enum {
    /// Return `error.Overflow`. For a `T` no wider than 64 bits the
    /// accumulation loop is identical to `.unchecked`: overflow is detected
    /// after the parse from the digit count, not checked per operation.
    /// Wider types check each operation instead.
    checked,
    /// The caller guarantees that the value fits `T`. Overflow is not
    /// detected: the accumulation wraps (defined), and the final cast
    /// panics in Debug and ReleaseSafe, or is undefined behavior in
    /// ReleaseFast. The contract matches `@intCast`.
    unchecked,
};

/// Whether `atoi` accepts leading zeros.
pub const LeadingZeros = enum {
    /// `"042"` parses as 42, matching `std.fmt.parseInt`.
    allow,
    /// A `0` with more digits after it is `error.InvalidCharacter`. `"0"` and
    /// `"-0"` stay valid. This is the JSON grammar for integers.
    reject,
};

/// Behavior knobs for `atoi`. Both fields are comptime, so every
/// configuration is a separately compiled specialization.
// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const Options = struct {
    overflow: Overflow = .checked,
    leading_zeros: LeadingZeros = .allow,
};

// ---------------------------------------------------------------------------
// SWAR primitives, transcribed from fast_float's `ascii_number.h`
// (parse_eight_digits_unrolled, is_made_of_eight_digits_fast, and the
// 4-digit variants). An extension to eight digits of Wojciech Muła's SWAR
// digit parsing; the technique is explained at
// https://lemire.me/blog/2022/01/21/swar-explained-parsing-eight-digits/.
//
// All arithmetic is wrapping (`*%`, `+%`): the fold products deliberately
// exceed u64 and wrap their garbage cross-terms away, so plain `*` would be
// undefined behavior in safe build modes. Comptime evaluation is legal.

/// True when every byte of `chunk` is an ASCII digit.
inline fn isEightDigits(chunk: u64) bool {
    // Per byte b: (b + 0x46) sets bit 7 iff b >= 58; (b - 0x30) wraps into
    // bit 7 iff b < 48. Bit 7 clear in both terms iff b is '0'..'9'.
    const flagged = (chunk +% 0x4646464646464646) | (chunk -% 0x3030303030303030);
    return flagged & 0x8080808080808080 == 0;
}

/// Fold 8 validated ASCII digits into their value. `chunk` is the
/// little-endian load, first character in the low byte; only call this after
/// `isEightDigits` passed.
inline fn parseEightDigits(chunk: u64) u32 {
    const pair_mask: u64 = 0x000000FF000000FF;
    const pair_mul1: u64 = 0x000F424000000064; // 100 + (1000000 << 32)
    const pair_mul2: u64 = 0x0000271000000001; // 1 + (10000 << 32)
    var val = chunk -% 0x3030303030303030;
    // Each byte k becomes 10*d[k] + d[k+1]; the fold below selects the even
    // bytes, which are the digit pairs (0,1), (2,3), (4,5), (6,7).
    val = val *% 10 +% (val >> 8);
    val = ((val & pair_mask) *% pair_mul1 +% ((val >> 16) & pair_mask) *% pair_mul2) >> 32;
    return @truncate(val);
}

/// True when every byte of `chunk` is an ASCII digit.
inline fn isFourDigits(chunk: u32) bool {
    const flagged = (chunk +% 0x46464646) | (chunk -% 0x30303030);
    return flagged & 0x80808080 == 0;
}

/// Fold 4 validated ASCII digits into their value; the little-endian load,
/// first character in the low byte. Only call after `isFourDigits` passed.
inline fn parseFourDigits(chunk: u32) u32 {
    var val = chunk -% 0x30303030;
    val = val *% 10 +% (val >> 8);
    const folded = ((val & 0x00FF00FF) *% 0x00640001) >> 16;
    return folded & 0xFFFF;
}

/// Accumulate the decimal magnitude of `digits` into a u64.
///
/// Every byte must be a digit; a non-digit returns `error.InvalidCharacter`.
/// The value wraps past 2^64 (defined, `*%`); `atoiWith` validates overflow
/// afterwards from the digit count, so no overflow check appears in the loop.
///
/// The SWAR steps are compiled in only when the type can hold the chunk's
/// value: `use_swar8` needs 8-digit capacity, `use_swar4` 4-digit capacity.
/// After a failed 8-digit check the scalar tail is bounded by 7 iterations:
/// the check failed because a non-digit sits within those 8 bytes, and the
/// tail returns when it reaches it.
fn accumulate64(
    digits: []const u8,
    comptime use_swar8: bool,
    comptime use_swar4: bool,
) error{InvalidCharacter}!u64 {
    var magnitude: u64 = 0;
    var i: usize = 0;
    if (use_swar8) {
        while (digits.len - i >= 8) {
            const chunk = mem.readInt(u64, digits[i..][0..8], .little);
            if (!isEightDigits(chunk)) break;
            magnitude = magnitude *% 100000000 +% parseEightDigits(chunk);
            i += 8;
        }
    }
    if (use_swar4 and digits.len - i >= 4) {
        const chunk = mem.readInt(u32, digits[i..][0..4], .little);
        if (isFourDigits(chunk)) {
            magnitude = magnitude *% 10000 +% parseFourDigits(chunk);
            i += 4;
        }
    }
    while (i < digits.len) : (i += 1) {
        const c = digits[i];
        if (c < '0' or c > '9') return error.InvalidCharacter;
        magnitude = magnitude *% 10 +% (c - '0');
    }
    return magnitude;
}

/// Apply the sign, range limit, and overflow contract to an exact magnitude:
/// `Magnitude` is unsigned, at least as wide as `T`, and never wrapped.
fn finish(
    comptime T: type,
    comptime Magnitude: type,
    comptime int_info: std.builtin.Type.Int,
    magnitude: Magnitude,
    negative: bool,
    comptime overflow: Overflow,
) Error(overflow)!T {
    if (int_info.signedness == .signed) {
        const limit: Magnitude = if (negative)
            @as(Magnitude, 1) << (int_info.bits - 1)
        else
            math.maxInt(T);
        // `|minInt| == maxInt + 1`: reached only when negative, since the
        // positive limit is `maxInt` itself.
        if (negative and magnitude == limit) return math.minInt(T);
        if (overflow == .checked and magnitude > limit) return error.Overflow;
        const value: T = if (overflow == .checked)
            math.cast(T, magnitude) orelse return error.Overflow
        else
            @intCast(magnitude);
        return if (negative) -value else value;
    }
    if (overflow == .checked) return math.cast(T, magnitude) orelse return error.Overflow;
    return @intCast(magnitude);
}

/// Parse `buf` as a base-10 integer of type `T` with explicit `options`.
///
/// Every byte of `buf` must belong to the number (`"1234x"` is an error, not
/// `1234`). A signed `T` accepts an optional leading `+` or `-` and parses
/// `-0` as `0`; an unsigned `T` accepts digits only, like
/// `std.fmt.parseUnsigned`. `atoi` never skips whitespace.
///
/// With `.{ .overflow = .unchecked }` the caller asserts the value fits `T`;
/// see `Overflow.unchecked` for the exact contract.
///
/// Comptime adds no checking of its own. With `.checked` the digit-count
/// validation runs as usual; with `.unchecked` it does not, and only Zig's
/// own comptime rules reject a value — `@intCast` for narrow types, the
/// arithmetic for wider ones. A `u64` or `i64` magnitude that wraps and lands
/// in range is returned, at comptime exactly as at runtime.
pub fn atoiWith(
    comptime T: type,
    buf: []const u8,
    comptime options: Options,
) Error(options.overflow)!T {
    const int_info = switch (@typeInfo(T)) {
        .int => |info| info,
        else => @compileError("atoi: T must be an integer type, found " ++ @typeName(T)),
    };

    if (buf.len == 0) return error.InvalidCharacter;

    // A sign is handled only where it can be meaningful; for unsigned `T` the
    // digit loop rejects '+' and '-' as non-digits.
    var negative = false;
    var digits = buf;
    if (int_info.signedness == .signed) {
        switch (buf[0]) {
            '+' => digits = buf[1..],
            '-' => {
                negative = true;
                digits = buf[1..];
            },
            else => {},
        }
        if (digits.len == 0) return error.InvalidCharacter;
    }

    if (options.leading_zeros == .reject) {
        if (digits[0] == '0' and digits.len > 1) return error.InvalidCharacter;
    }

    // Leading zeros are stripped so the digit count is the significant
    // count; the overflow validation below depends on this (fast_float strips
    // them for the same reason). "000" reduces to "", which parses as 0.
    digits = mem.trimStart(u8, digits, "0");

    if (comptime int_info.bits <= 64) {
        const magnitude = try accumulate64(
            digits,
            math.maxInt(T) >= 10000000, // 8-digit capacity
            math.maxInt(T) >= 1000, // 4-digit capacity
        );

        if (options.overflow == .checked) {
            // The accumulator is exact while the significant length stays
            // under 20: a nonzero leading digit bounds the value below
            // 10^19 < 2^64. At 20 significant digits only a u64 can hold the
            // value at all, and the wrap is detected inside the leading
            // digit's band (fast_float's check): a 20-digit number starting
            // with '1' is below 2^64 iff the magnitude did not wrap below
            // 10^19.
            if (digits.len >= 20) {
                if (int_info.signedness == .signed or int_info.bits < 64 or digits.len > 20) {
                    return error.Overflow;
                }
                const min_twenty: u64 = 10000000000000000000; // 10^19
                const lead = digits[0] - '0';
                if (lead > 1 or (lead == 1 and magnitude < min_twenty)) return error.Overflow;
            }
        }

        return finish(T, u64, int_info, magnitude, negative, options.overflow);
    }

    // Wider than 64 bits: the magnitude legitimately exceeds 2^64, so the
    // wrap-and-count strategy does not apply and overflow is checked per
    // operation, as in `std.fmt.parseInt`.
    const Accumulator = @Int(.unsigned, int_info.bits);
    var magnitude: Accumulator = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.InvalidCharacter;
        const digit: Accumulator = c - '0';
        if (options.overflow == .checked) {
            magnitude = math.mul(Accumulator, magnitude, 10) catch return error.Overflow;
            magnitude = math.add(Accumulator, magnitude, digit) catch return error.Overflow;
        } else {
            magnitude *= 10;
            magnitude += digit;
        }
    }
    return finish(T, Accumulator, int_info, magnitude, negative, options.overflow);
}

/// `atoiWith` with default options: overflow returns `error.Overflow`, and
/// leading zeros are allowed.
pub inline fn atoi(comptime T: type, buf: []const u8) Error(.checked)!T {
    return atoiWith(T, buf, .{ .overflow = .checked });
}

/// `atoiWith` with `.{ .overflow = .unchecked }`: the caller guarantees the
/// value fits `T`. The accumulation loop is identical to `atoi` — with SWAR
/// there is nothing left to skip in the loop; only the final validation and
/// cast differ. Cannot return `error.Overflow`; `error.InvalidCharacter`
/// still applies.
pub inline fn atoiUnchecked(comptime T: type, buf: []const u8) Error(.unchecked)!T {
    return atoiWith(T, buf, .{ .overflow = .unchecked });
}

test atoi {
    try testing.expectEqual(123, try atoi(u32, "123"));
    try testing.expectEqual(42, try atoi(u32, "042"));
    try testing.expectEqual(-123, try atoi(i32, "-123"));
    try testing.expectEqual(123, try atoi(i32, "+123"));
    try testing.expectEqual(0, try atoi(i32, "-0"));

    // Boundaries of each width.
    try testing.expectEqual(255, try atoi(u8, "255"));
    try testing.expectError(error.Overflow, atoi(u8, "256"));
    try testing.expectEqual(127, try atoi(i8, "127"));
    try testing.expectEqual(-128, try atoi(i8, "-128"));
    try testing.expectError(error.Overflow, atoi(i8, "128"));
    try testing.expectError(error.Overflow, atoi(i8, "-129"));
    try testing.expectEqual(1, try atoi(u1, "1"));
    try testing.expectEqual(math.minInt(i1), try atoi(i1, "-1"));
    try testing.expectError(error.Overflow, atoi(u1, "2"));
    try testing.expectEqual(math.minInt(i64), try atoi(i64, "-9223372036854775808"));
    try testing.expectEqual(math.maxInt(i64), try atoi(i64, "9223372036854775807"));
    try testing.expectError(error.Overflow, atoi(i64, "-9223372036854775809"));
    try testing.expectEqual(math.maxInt(u64), try atoi(u64, "18446744073709551615"));
    try testing.expectError(error.Overflow, atoi(u64, "18446744073709551616"));
    const u128_max = "340282366920938463463374607431768211455";
    try testing.expectEqual(math.maxInt(u128), try atoi(u128, u128_max));
    try testing.expectError(error.Overflow, atoi(u128, "340282366920938463463374607431768211456"));

    // The whole string must be the number.
    try testing.expectError(error.InvalidCharacter, atoi(u32, "1234x"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, "x123"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, ""));
    try testing.expectError(error.InvalidCharacter, atoi(u32, "+"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, "-"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, " 12"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, "1_2"));

    // Unsigned accepts no sign at all — not even `+1` or `-0`.
    try testing.expectError(error.InvalidCharacter, atoi(u32, "+1"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, "-1"));
    try testing.expectError(error.InvalidCharacter, atoi(u8, "-0"));

    // Non-digits inside an otherwise SWAR-eligible run.
    try testing.expectError(error.InvalidCharacter, atoi(u64, "1234x678"));
    try testing.expectError(error.InvalidCharacter, atoi(u64, "1234567x"));
    try testing.expectError(error.InvalidCharacter, atoi(u32, "12345678x01"));

    // Comptime calls work like std.fmt.parseInt, SWAR included.
    const comptime_value = comptime atoi(i16, "-32768") catch unreachable;
    try testing.expectEqual(math.minInt(i16), comptime_value);
    const comptime_swar = comptime atoi(u64, "1234567890123456789") catch unreachable;
    try testing.expectEqual(1234567890123456789, comptime_swar);
}

test "atoi leading zeros" {
    try testing.expectEqual(try atoi(u32, "123"), try atoiWith(u32, "123", .{}));
    const strict: Options = .{ .leading_zeros = .reject };
    try testing.expectEqual(0, try atoiWith(u32, "0", strict));
    try testing.expectEqual(0, try atoiWith(i32, "-0", strict));
    try testing.expectEqual(123, try atoiWith(u32, "123", strict));
    try testing.expectError(error.InvalidCharacter, atoiWith(u32, "042", strict));
    try testing.expectError(error.InvalidCharacter, atoiWith(u32, "00", strict));
    try testing.expectError(error.InvalidCharacter, atoiWith(i32, "-042", strict));
    try testing.expectError(error.InvalidCharacter, atoiWith(i64, "+007", strict));
}

test atoiUnchecked {
    try testing.expectEqual(123, try atoiUnchecked(u32, "123"));
    try testing.expectEqual(-123, try atoiUnchecked(i32, "-123"));
    try testing.expectEqual(255, try atoiUnchecked(u8, "255"));
    try testing.expectEqual(math.minInt(i8), try atoiUnchecked(i8, "-128"));
    try testing.expectEqual(math.minInt(i64), try atoiUnchecked(i64, "-9223372036854775808"));
    try testing.expectEqual(math.maxInt(u64), try atoiUnchecked(u64, "18446744073709551615"));
    try testing.expectError(error.InvalidCharacter, atoiUnchecked(u32, "1234x"));
    try testing.expectError(error.InvalidCharacter, atoiUnchecked(u32, ""));

    // Comptime `.unchecked` parses like runtime; a `T` too narrow for the
    // value fails to compile in `finish`'s `@intCast`, not in `atoiWith`.
    const comptime_value = comptime atoiUnchecked(u8, "255") catch unreachable;
    try testing.expectEqual(255, comptime_value);
}

test "SWAR digit primitives" {
    const eight = struct {
        fn load(s: *const [8]u8) u64 {
            return mem.readInt(u64, s, .little);
        }
    };
    try testing.expect(isEightDigits(eight.load("12345678")));
    try testing.expect(isEightDigits(eight.load("00000000")));
    try testing.expect(isEightDigits(eight.load("99999999")));
    try testing.expect(!isEightDigits(eight.load("1234:678")));
    try testing.expect(!isEightDigits(eight.load("1234567;")));
    try testing.expect(!isEightDigits(eight.load("/2345678")));
    try testing.expect(!isEightDigits(eight.load("1234567x")));
    try testing.expect(!isEightDigits(eight.load("123 5678")));

    try testing.expectEqual(12345678, parseEightDigits(eight.load("12345678")));
    try testing.expectEqual(0, parseEightDigits(eight.load("00000000")));
    try testing.expectEqual(1, parseEightDigits(eight.load("00000001")));
    try testing.expectEqual(10000000, parseEightDigits(eight.load("10000000")));
    try testing.expectEqual(99999999, parseEightDigits(eight.load("99999999")));
    try testing.expectEqual(87654321, parseEightDigits(eight.load("87654321")));

    const four = struct {
        fn load(s: *const [4]u8) u32 {
            return mem.readInt(u32, s, .little);
        }
    };
    // Every 4-digit value round-trips through the fold.
    var buf: [4]u8 = undefined;
    var value: u32 = 0;
    while (value < 10000) : (value += 1) {
        buf[0] = '0' + @as(u8, @intCast(value / 1000));
        buf[1] = '0' + @as(u8, @intCast((value / 100) % 10));
        buf[2] = '0' + @as(u8, @intCast((value / 10) % 10));
        buf[3] = '0' + @as(u8, @intCast(value % 10));
        const chunk = four.load(&buf);
        try testing.expect(isFourDigits(chunk));
        try testing.expectEqual(value, parseFourDigits(chunk));
    }
    try testing.expect(!isFourDigits(four.load("12x4")));
    try testing.expect(!isFourDigits(four.load(":234")));
}

test "atoi 20-digit boundary" {
    // u64's exact capacity, probed from both sides.
    try testing.expectEqual(10000000000000000000, try atoi(u64, "10000000000000000000"));
    try testing.expectEqual(18446744073709551615, try atoi(u64, "18446744073709551615"));
    try testing.expectError(error.Overflow, atoi(u64, "18446744073709551616"));
    try testing.expectError(error.Overflow, atoi(u64, "19999999999999999999"));
    try testing.expectError(error.Overflow, atoi(u64, "99999999999999999999"));
    try testing.expectError(error.Overflow, atoi(u64, "100000000000000000000"));

    // Twenty characters whose value is small: leading zeros keep the
    // accumulator exact, so these must stay valid.
    try testing.expectEqual(1, try atoi(u64, "00000000000000000001"));
    try testing.expectEqual(1, try atoi(i64, "00000000000000000001"));
    try testing.expectEqual(math.minInt(i64), try atoi(i64, "-09223372036854775808"));

    // Leading zeros do not rescue an oversized value: the significant
    // length decides (found by the differential test against std).
    try testing.expectError(error.Overflow, atoi(u64, "0567422714527692753566155"));
    try testing.expectError(error.Overflow, atoi(i64, "082701803193176084787"));
    try testing.expectError(error.Overflow, atoi(u32, "082701803193176084787"));
}

test "atoi matches std.fmt.parseInt on digit strings" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    var buf: [28]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 10000) : (iteration += 1) {
        const len = random.intRangeAtMost(usize, 1, 25);
        for (buf[0..len]) |*b| {
            b.* = '0' + random.intRangeAtMost(u8, 0, 9);
        }
        const digits = buf[0..len];

        const widths = .{ u1, u8, u16, u24, u32, u64, i8, i16, i24, i32, i64 };
        inline for (widths) |Width| {
            const expected: ?Width = std.fmt.parseInt(Width, digits, 10) catch |err| switch (err) {
                error.Overflow => null,
                else => unreachable, // pure digits cannot be invalid
            };
            if (expected) |value| {
                try testing.expectEqual(value, try atoi(Width, digits));
                try testing.expectEqual(value, try atoiUnchecked(Width, digits));
            } else {
                try testing.expectError(error.Overflow, atoi(Width, digits));
            }
        }
    }
}
