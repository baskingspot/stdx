//! Base64 (RFC 4648) that moves whole vectors per instruction.
//!
//! std has a base64 codec, and it is scalar: it reads 16 bytes into a
//! `u128`, shifts the 6-bit fields out one at a time, and indexes the
//! alphabet for each character. That is roughly four instructions per
//! byte of output. The alphabet translation is a 64-entry lookup, which
//! a SIMD table permute does for 16 bytes at once; on aarch64 the
//! 3-in/4-out byte interleave that base64 needs is an addressing mode,
//! not arithmetic.
//!
//! The codec is the alphabet plus the pad character, nothing else. It is
//! a comptime parameter, so every lookup table a kernel indexes is a
//! `const` array in the binary and every `if (pad_char)` is resolved
//! before code generation. Encode writes characters and returns the slice
//! it wrote. Decode writes bytes, returns the slice it wrote, and is the
//! validation: padding and the unused trailing bits of a partial group
//! are both checked, so anything that decodes is canonical base64.
//!
//! The vector kernels are aarch64's. Another architecture gets the scalar
//! loop, which is correct and not faster than std's.
//!
//! Streaming, whitespace tolerance, and the `IgnoreDecoder` shape are not
//! here. A caller that has to skip newlines has a format problem, not a
//! codec problem.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;

/// The alphabet of [RFC 4648 section 4](https://datatracker.ietf.org/doc/html/rfc4648#section-4).
pub const standard_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".*;

/// The alphabet of [RFC 4648 section 5](https://datatracker.ietf.org/doc/html/rfc4648#section-5).
pub const url_safe_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".*;

/// Standard base64, padded: `RFC 4648` section 4.
pub const standard = Codec(standard_alphabet, '=');

/// Standard base64, unpadded: `RFC 4648` section 3.2.
pub const standard_no_pad = Codec(standard_alphabet, null);

/// URL-safe base64, padded: `RFC 4648` section 5.
pub const url_safe = Codec(url_safe_alphabet, '=');

/// URL-safe base64, unpadded: `RFC 4648` section 5 with section 3.2's
/// trailing-byte rule.
pub const url_safe_no_pad = Codec(url_safe_alphabet, null);

pub const Error = error{
    /// A byte in the input is not in the alphabet, and is not this
    /// codec's pad character.
    InvalidCharacter,
    /// The input length, the pad characters, or the unused trailing bits
    /// of a partial group are not valid for this codec.
    InvalidPadding,
    /// `dest` is too small for the decoded output.
    NoSpaceLeft,
};

/// A base64 codec: 64 distinct alphabet characters and an optional pad
/// character. `standard` and the three other constants are the codecs RFC
/// 4648 defines; a caller with its own alphabet calls this directly.
pub fn Codec(comptime alphabet: [64]u8, comptime pad_char: ?u8) type {
    comptime {
        @setEvalBranchQuota(8000);
        if (pad_char) |pad| {
            for (alphabet) |c| {
                if (c == pad) @compileError("base64: the pad character is in the alphabet");
            }
        }
        for (alphabet, 0..) |c, i| {
            for (alphabet[0..i]) |earlier| {
                if (c == earlier) @compileError("base64: the alphabet repeats a character");
            }
        }
    }

    return struct {
        /// Byte to 6-bit value, or `invalid`. The pad character and every
        /// byte outside this codec's alphabet stay `invalid`.
        const decode_table: [256]u8 = blk: {
            var out: [256]u8 = @splat(invalid);
            for (alphabet, 0..) |c, i| out[c] = @intCast(i);
            break :blk out;
        };

        /// The byte count `encode` produces for `source_len` input bytes.
        pub fn encodedLen(source_len: usize) usize {
            if (comptime pad_char != null) return (source_len + 2) / 3 * 4;
            const leftover = source_len % 3;
            return source_len / 3 * 4 + (leftover * 4 + 2) / 3;
        }

        /// The largest byte count `decode` can produce for `source_len`
        /// input bytes. Padding makes the exact count smaller: use this to
        /// size a buffer in one pass, or `decodedLen` to size it exactly.
        pub fn decodedUpperBound(source_len: usize) usize {
            return source_len / 4 * 3 + (source_len % 4) * 3 / 4;
        }

        /// The exact byte count `decode` produces for `source`, or the
        /// error `decode` returns for the length alone.
        pub fn decodedLen(source: []const u8) Error!usize {
            const leftover = source.len % 4;
            if (comptime pad_char != null) {
                if (leftover != 0) return error.InvalidPadding;
            } else if (leftover == 1) {
                return error.InvalidPadding;
            }
            var len = source.len / 4 * 3 + leftover * 3 / 4;
            if (comptime pad_char != null) {
                if (source.len >= 1 and source[source.len - 1] == pad_char.?) len -= 1;
                if (source.len >= 2 and source[source.len - 2] == pad_char.?) len -= 1;
            }
            return len;
        }

        /// Encode `source` into `dest` and return the characters written.
        /// `dest.len` must be at least `encodedLen(source.len)`.
        pub fn encode(dest: []u8, source: []const u8) []const u8 {
            const out_len = encodedLen(source.len);
            assert(dest.len >= out_len);
            if (comptime !has_neon) return fallback.encoder.encode(dest, source);

            const done = aarch64.encodeBlocks(encode_table, dest.ptr, source.ptr, source.len);
            var i = done;
            var o = done / 3 * 4;
            while (i + 3 <= source.len) : (i += 3) {
                const bits = std.mem.readInt(u24, source[i..][0..3], .big);
                dest[o + 0] = alphabet[bits >> 18];
                dest[o + 1] = alphabet[(bits >> 12) & 0x3F];
                dest[o + 2] = alphabet[(bits >> 6) & 0x3F];
                dest[o + 3] = alphabet[bits & 0x3F];
                o += 4;
            }
            switch (source.len - i) {
                0 => {},
                1 => {
                    const b0 = source[i];
                    dest[o + 0] = alphabet[b0 >> 2];
                    dest[o + 1] = alphabet[(b0 & 0x03) << 4];
                    o += 2;
                },
                2 => {
                    const b0 = source[i];
                    const b1 = source[i + 1];
                    dest[o + 0] = alphabet[b0 >> 2];
                    dest[o + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
                    dest[o + 2] = alphabet[(b1 & 0x0F) << 2];
                    o += 3;
                },
                else => unreachable,
            }
            // A last group of one byte takes two pads, of two bytes one pad.
            const pad_len = out_len - o;
            assert(pad_len <= 2);
            if (comptime pad_char != null) {
                for (dest[o..out_len]) |*byte| byte.* = pad_char.?;
            } else {
                assert(pad_len == 0);
            }
            return dest[0..out_len];
        }

        /// Decode `source` into `dest` and return the bytes written.
        /// `dest.len` must be at least `decodedLen(source)`.
        ///
        /// The input must be canonical: padding in place, and the unused
        /// bits of a partial trailing group zero.
        pub fn decode(dest: []u8, source: []const u8) Error![]u8 {
            if (comptime !has_neon) return fallback.decode(dest, source);
            const out_len = try decodedLen(source);
            if (dest.len < out_len) return error.NoSpaceLeft;

            const done = try aarch64.decodeBlocks(decode_low, decode_high, .{
                .dest = dest.ptr,
                .dest_len = dest.len,
                .source = source.ptr,
                .len = source.len,
            });
            var i = done;
            var o = done / 4 * 3;

            // Everything after the vector loop is scalar: the padding, the
            // partial group, and at most one block the loop rejected.
            var end = source.len;
            var pad_len: usize = 0;
            if (comptime pad_char != null) {
                while (end > i and source[end - 1] == pad_char.? and pad_len < 2) {
                    end -= 1;
                    pad_len += 1;
                }
            }
            while (i + 4 <= end) : (i += 4) {
                // One `or` chain answers "is any of the four invalid": every
                // valid value is six bits, and the sentinel is all ones.
                const c0 = decode_table[source[i + 0]];
                const c1 = decode_table[source[i + 1]];
                const c2 = decode_table[source[i + 2]];
                const c3 = decode_table[source[i + 3]];
                if (c0 | c1 | c2 | c3 > 0x3F) return charError(source[i..][0..4]);
                dest[o + 0] = (c0 << 2) | (c1 >> 4);
                dest[o + 1] = (c1 << 4) | (c2 >> 2);
                dest[o + 2] = (c2 << 6) | c3;
                o += 3;
            }
            // A partial group carries unused low bits that canonical base64
            // leaves zero, and the pad count must match the leftover count.
            switch (end - i) {
                0 => if (pad_len != 0) return error.InvalidPadding,
                2 => {
                    const c0 = try charValue(source[i + 0]);
                    const c1 = try charValue(source[i + 1]);
                    if (c1 & 0x0F != 0 or pad_len != paddingFor(2)) return error.InvalidPadding;
                    dest[o] = (c0 << 2) | (c1 >> 4);
                    o += 1;
                },
                3 => {
                    const c0 = try charValue(source[i + 0]);
                    const c1 = try charValue(source[i + 1]);
                    const c2 = try charValue(source[i + 2]);
                    if (c2 & 0x03 != 0 or pad_len != paddingFor(3)) return error.InvalidPadding;
                    dest[o + 0] = (c0 << 2) | (c1 >> 4);
                    dest[o + 1] = (c1 << 4) | (c2 >> 2);
                    o += 2;
                },
                else => return error.InvalidPadding,
            }
            assert(o == out_len);
            return dest[0..out_len];
        }

        /// The pad count a partial group of `symbols` characters must
        /// carry: two for one byte, one for two bytes, none for a whole
        /// group.
        fn paddingFor(comptime symbols: usize) usize {
            if (comptime pad_char == null) return 0;
            return switch (symbols) {
                2 => 2,
                3 => 1,
                else => 0,
            };
        }

        /// The error for the first byte of `group` that is not in the
        /// alphabet. The fast paths reject a whole group without saying
        /// which byte, so the reason is decided here, once.
        fn charError(group: []const u8) Error {
            for (group) |c| {
                if (decode_table[c] == invalid) {
                    if (comptime pad_char != null) {
                        if (c == pad_char.?) return error.InvalidPadding;
                    }
                    return error.InvalidCharacter;
                }
            }
            unreachable;
        }

        inline fn charValue(c: u8) Error!u8 {
            const value = decode_table[c];
            if (value == invalid) {
                if (comptime pad_char != null) {
                    if (c == pad_char.?) return error.InvalidPadding;
                }
                return error.InvalidCharacter;
            }
            return value;
        }

        /// Everything but aarch64 hands the whole job to std's codec: it is
        /// the fastest scalar implementation there, and a fallback slower
        /// than the thing this module replaces is not worth writing.
        const fallback = struct {
            const encoder = std.base64.Base64Encoder.init(alphabet, pad_char);
            const decoder = std.base64.Base64Decoder.init(alphabet, pad_char);

            fn decode(dest: []u8, source: []const u8) Error![]u8 {
                const out_len = try decodedLen(source);
                if (dest.len < out_len) return error.NoSpaceLeft;
                try decoder.decode(dest[0..out_len], source);
                return dest[0..out_len];
            }
        };

        /// The 64-byte alphabet, as the vector table `tbl` permutes.
        const encode_table: Table = table(alphabet);

        /// Characters below 64: `+`, `/`, and the digits of the standard
        /// alphabet live here.
        const decode_low: Table = blk: {
            var out: [64]u8 = @splat(invalid);
            for (alphabet, 0..) |c, value| {
                if (c < 64) out[c] = @intCast(value);
            }
            break :blk table(out);
        };

        /// Characters 63 and up, indexed by the character value minus 63,
        /// so a character below the range indexes 0 and takes its value
        /// from `decode_low` alone. Past 126 the index leaves the table
        /// and the character value passes through unchanged, which is
        /// above 63 and so fails the range check.
        const decode_high: Table = blk: {
            var out: [64]u8 = @splat(invalid);
            out[0] = 0;
            for (alphabet, 0..) |c, value| {
                if (c >= 64) out[c - 63] = @intCast(value);
            }
            break :blk table(out);
        };
    };
}

/// Sentinel for a byte that is not in the alphabet.
const invalid: u8 = 0xFF;

// The kernels.
//
// The vector path is comptime-selected, so a build for another
// architecture never analyzes it and its inline assembly never reaches an
// assembler that cannot parse it. NEON is part of the aarch64 baseline, so
// there is nothing to detect at run time.

const has_neon = builtin.cpu.arch == .aarch64;

const Byte16 = @Vector(16, u8);

/// One 64-byte table as four vector registers. A table permute addresses
/// 64 bytes when its table is four consecutive vector registers, which the
/// register constraints pin; a plain vector operand cannot promise that.
const Table = [4]Byte16;

fn table(comptime bytes: [64]u8) Table {
    var out: Table = undefined;
    for (0..4) |i| out[i] = bytes[i * 16 ..][0..16].*;
    return out;
}

const aarch64 = struct {
    /// Source bytes per encode block, and characters per decode block.
    const encode_block = 48;
    const decode_block = 64;

    fn encodeBlocks(comptime enc: Table, dest: [*]u8, source: [*]const u8, len: usize) usize {
        const ones: Byte16 = @splat(0x3F);
        var i: usize = 0;
        while (i + encode_block <= len) : (i += encode_block) {
            const src = load3(source + i);
            var out: [4]Byte16 = undefined;
            out[0] = src[0] >> @splat(2);
            out[1] = ((src[1] >> @splat(4)) | (src[0] << @splat(4))) & ones;
            out[2] = ((src[2] >> @splat(6)) | (src[1] << @splat(2))) & ones;
            out[3] = src[2] & ones;
            out[0] = permute(enc, out[0]);
            out[1] = permute(enc, out[1]);
            out[2] = permute(enc, out[2]);
            out[3] = permute(enc, out[3]);
            store4(dest + i / 3 * 4, out);
        }
        return i;
    }

    /// Four blocks per iteration. The validity test ends in a vector
    /// reduction and a branch, which is dead time between one block and the
    /// next; a group of four amortizes it and lets the blocks overlap.
    const decode_unroll = 4;

    const DecodeArgs = struct {
        dest: [*]u8,
        dest_len: usize,
        source: [*]const u8,
        len: usize,
    };

    fn decodeBlocks(
        comptime low: Table,
        comptime high: Table,
        args: DecodeArgs,
    ) Error!usize {
        const dest = args.dest;
        const dest_len = args.dest_len;
        const source = args.source;
        const len = args.len;
        const group_chars = decode_unroll * decode_block;
        const group_bytes = group_chars / 4 * 3;
        var i: usize = 0;
        var o: usize = 0;
        // A group is checked after it is written, so the loop bounds itself
        // by the destination as well. A destination sized to the exact
        // decoded length leaves the last group to the scalar tail; one sized
        // to the upper bound runs to the end.
        while (i + group_chars <= len and o + group_bytes <= dest_len) : ({
            i += group_chars;
            o += group_bytes;
        }) {
            var widest: Byte16 = @splat(0);
            inline for (0..decode_unroll) |k| {
                const block_out = dest + o + k * decode_block / 4 * 3;
                const block_in = source + i + k * decode_block;
                widest = @max(widest, decodeBlock(low, high, block_out, block_in));
            }
            // The group is already written. A rejected one is left for the
            // scalar tail to redo, which is where the error is reported with
            // the right kind and position.
            if (@reduce(.Max, widest) > 63) return i;
        }
        while (i + decode_block <= len and o + decode_block / 4 * 3 <= dest_len) : ({
            i += decode_block;
            o += decode_block / 4 * 3;
        }) {
            const widest = decodeBlock(low, high, dest + o, source + i);
            if (@reduce(.Max, widest) > 63) return i;
        }
        return i;
    }

    /// One 64-character block into 48 bytes, returning the largest decoded
    /// value so the caller can tell whether any character was invalid.
    inline fn decodeBlock(
        comptime low: Table,
        comptime high: Table,
        dest: [*]u8,
        source: [*]const u8,
    ) Byte16 {
        const str = load4(source);
        var v: [4]Byte16 = undefined;
        inline for (0..4) |k| {
            // A character below 64 has its value in the low table and a
            // zero index into the high table; one at 64 or above has the
            // reverse. An invalid character gets a value above 63 from one
            // of them.
            const over = str[k] -| @as(Byte16, @splat(63));
            v[k] = permute(low, str[k]) | permuteKeep(high, over, over);
        }
        var out: [3]Byte16 = undefined;
        out[0] = (v[0] << @splat(2)) | (v[1] >> @splat(4));
        out[1] = (v[1] << @splat(4)) | (v[2] >> @splat(2));
        out[2] = (v[2] << @splat(6)) | v[3];
        store3(dest, out);
        return @max(@max(v[0], v[1]), @max(v[2], v[3]));
    }

    /// Deinterleave 48 contiguous bytes into the three residue classes
    /// modulo 3: `ld3` is the 3-in/4-out structure of base64 as an
    /// addressing mode.
    inline fn load3(p: [*]const u8) [3]Byte16 {
        var a: Byte16 = undefined;
        var b: Byte16 = undefined;
        var c: Byte16 = undefined;
        asm volatile ("ld3 {%[a].16b, %[b].16b, %[c].16b}, [%[p]]"
            : [a] "={v0}" (a),
              [b] "={v1}" (b),
              [c] "={v2}" (c),
            : [p] "r" (p),
            : .{ .memory = true });
        return .{ a, b, c };
    }

    /// Interleave four vectors into 64 contiguous bytes.
    inline fn store4(p: [*]u8, v: [4]Byte16) void {
        asm volatile ("st4 {%[a].16b, %[b].16b, %[c].16b, %[d].16b}, [%[p]]"
            :
            : [p] "r" (p),
              [a] "{v4}" (v[0]),
              [b] "{v5}" (v[1]),
              [c] "{v6}" (v[2]),
              [d] "{v7}" (v[3]),
            : .{ .memory = true });
    }

    /// Deinterleave 64 contiguous bytes into the four residue classes
    /// modulo 4.
    inline fn load4(p: [*]const u8) [4]Byte16 {
        var a: Byte16 = undefined;
        var b: Byte16 = undefined;
        var c: Byte16 = undefined;
        var d: Byte16 = undefined;
        asm volatile ("ld4 {%[a].16b, %[b].16b, %[c].16b, %[d].16b}, [%[p]]"
            : [a] "={v0}" (a),
              [b] "={v1}" (b),
              [c] "={v2}" (c),
              [d] "={v3}" (d),
            : [p] "r" (p),
            : .{ .memory = true });
        return .{ a, b, c, d };
    }

    /// Interleave three vectors into 48 contiguous bytes.
    inline fn store3(p: [*]u8, v: [3]Byte16) void {
        asm volatile ("st3 {%[a].16b, %[b].16b, %[c].16b}, [%[p]]"
            :
            : [p] "r" (p),
              [a] "{v4}" (v[0]),
              [b] "{v5}" (v[1]),
              [c] "{v6}" (v[2]),
            : .{ .memory = true });
    }

    /// Byte permute through a 64-byte table. An index past the end of the
    /// table yields zero.
    inline fn permute(t: Table, index: Byte16) Byte16 {
        var out: Byte16 = undefined;
        asm volatile ("tbl %[out].16b, {%[t0].16b, %[t1].16b, %[t2].16b, %[t3].16b}, %[index].16b"
            : [out] "=w" (out),
            : [t0] "{v20}" (t[0]),
              [t1] "{v21}" (t[1]),
              [t2] "{v22}" (t[2]),
              [t3] "{v23}" (t[3]),
              [index] "w" (index),
        );
        return out;
    }

    /// `permute`, but an index past the end of the table keeps the byte
    /// that was in `dst`.
    inline fn permuteKeep(t: Table, dst: Byte16, index: Byte16) Byte16 {
        var out: Byte16 = dst;
        asm volatile ("tbx %[out].16b, {%[t0].16b, %[t1].16b, %[t2].16b, %[t3].16b}, %[index].16b"
            : [out] "+w" (out),
            : [t0] "{v24}" (t[0]),
              [t1] "{v25}" (t[1]),
              [t2] "{v26}" (t[2]),
              [t3] "{v27}" (t[3]),
              [index] "w" (index),
        );
        return out;
    }
};

test "encode: RFC 4648 vectors" {
    const cases = [_]struct { plain: []const u8, encoded: []const u8 }{
        .{ .plain = "", .encoded = "" },
        .{ .plain = "f", .encoded = "Zg==" },
        .{ .plain = "fo", .encoded = "Zm8=" },
        .{ .plain = "foo", .encoded = "Zm9v" },
        .{ .plain = "foob", .encoded = "Zm9vYg==" },
        .{ .plain = "fooba", .encoded = "Zm9vYmE=" },
        .{ .plain = "foobar", .encoded = "Zm9vYmFy" },
    };
    var buffer: [64]u8 = undefined;
    for (cases) |case| {
        try testing.expectEqualStrings(case.encoded, standard.encode(&buffer, case.plain));
        try testing.expectEqualStrings(case.encoded, url_safe.encode(&buffer, case.plain));
        const unpadded = std.mem.trimEnd(u8, case.encoded, "=");
        try testing.expectEqualStrings(unpadded, standard_no_pad.encode(&buffer, case.plain));
        try testing.expectEqualStrings(unpadded, url_safe_no_pad.encode(&buffer, case.plain));
    }
}

test "round-trip: every length across two vector blocks" {
    var source: [256]u8 = undefined;
    var encoded: [512]u8 = undefined;
    var decoded: [256]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i *% 151 +% 7);
    for (0..source.len + 1) |len| {
        inline for (.{ standard, standard_no_pad, url_safe, url_safe_no_pad }) |codec| {
            const chars = codec.encode(&encoded, source[0..len]);
            try testing.expectEqual(codec.encodedLen(len), chars.len);
            const bytes = try codec.decode(&decoded, chars);
            try testing.expectEqualSlices(u8, source[0..len], bytes);
            try testing.expectEqual(try codec.decodedLen(chars), bytes.len);
            try testing.expect(codec.decodedUpperBound(chars.len) >= bytes.len);
        }
    }
}

test "encode and decode: agree with std" {
    var source: [1024]u8 = undefined;
    var ours: [2048]u8 = undefined;
    var theirs: [2048]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x5eed);
    for (0..64) |_| {
        const len = random.random().uintLessThan(usize, source.len + 1);
        random.random().bytes(source[0..len]);
        const input = source[0..len];
        try checkAgainstStd(standard, std.base64.standard, input, &ours, &theirs);
        try checkAgainstStd(standard_no_pad, std.base64.standard_no_pad, input, &ours, &theirs);
        try checkAgainstStd(url_safe, std.base64.url_safe, input, &ours, &theirs);
        try checkAgainstStd(url_safe_no_pad, std.base64.url_safe_no_pad, input, &ours, &theirs);
    }
}

fn checkAgainstStd(
    comptime codec: type,
    comptime theirs: std.base64.Codecs,
    source: []const u8,
    ours: []u8,
    their_buffer: []u8,
) !void {
    const their_chars = theirs.Encoder.encode(their_buffer, source);
    try testing.expectEqualSlices(u8, their_chars, codec.encode(ours, source));
    const our_bytes = try codec.decode(ours, their_chars);
    try testing.expectEqualSlices(u8, source, our_bytes);
}

test "decode: rejects what std rejects, with the same error" {
    const cases = [_][]const u8{
        "A",
        "AA",
        "AAA",
        "A..A",
        "AA=A",
        "AA/=",
        "A/==",
        "A===",
        "====",
        "AA==AA",
        "Zg=",
        "Zg===",
        "Zg==\n",
        "Z g ==",
        "Z m 9 v Y m F y ",
        "Zm9vYmFyZm9vYmFyA..A",
        "Zm9vYmFyZm9vYmFyAA=A",
        "Zm9vYmFyZm9vYmFyA/==",
        "Zm9vYmFyZm9vYmFyA===",
        "A..AZm9vYmFyZm9vYmFy",
        "Zm9vYmFyZm9vAA=A",
    };
    for (cases) |case| {
        try testing.expectEqual(stdError(case), ourError(case));
    }
}

fn ourError(case: []const u8) ?anyerror {
    var decoded: [64]u8 = undefined;
    if (standard.decode(&decoded, case)) |_| {
        return null;
    } else |err| {
        return err;
    }
}

fn stdError(case: []const u8) ?anyerror {
    var decoded: [64]u8 = undefined;
    const len = std.base64.standard.Decoder.calcSizeForSlice(case) catch |err| {
        return err;
    };
    if (std.base64.standard.Decoder.decode(decoded[0..len], case)) |_| {
        return null;
    } else |err| {
        return err;
    }
}

test "decode: a destination that is too small" {
    var decoded: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, standard.decode(&decoded, "AAAAAAAAAAAAAAAA"));
    try testing.expectError(error.NoSpaceLeft, standard_no_pad.decode(&decoded, "AAAAAAAAAAAAAAA"));
}

test "decode: an exactly sized destination" {
    // A vector group writes 192 bytes before the group is checked, so an
    // exact-size destination must keep it inside. Padding in the last block
    // makes the exact length two bytes shorter than the group writes.
    var source: [256]u8 = @splat('A');
    source[254] = '=';
    source[255] = '=';
    var decoded: [190]u8 = undefined;
    try testing.expectEqual(@as(usize, 190), try standard.decodedLen(&source));
    try testing.expectEqual(@as(usize, 190), (try standard.decode(&decoded, &source)).len);

    // No padding: the group lands exactly on the end of the destination.
    var bare: [256]u8 = @splat('A');
    var exact: [192]u8 = undefined;
    try testing.expectEqual(@as(usize, 192), (try standard.decode(&exact, &bare)).len);

    // The same characters through the unpadded codec.
    var loose: [192]u8 = undefined;
    try testing.expectEqual(@as(usize, 192), (try standard_no_pad.decode(&loose, &bare)).len);
}

test "decode: a rejected block farthest into the input" {
    // 64 characters decode in one vector block, so an invalid character
    // just past it must still be reported.
    var source: [128]u8 = @splat('A');
    var decoded: [128]u8 = undefined;
    source[64] = '!';
    try testing.expectError(error.InvalidCharacter, standard.decode(&decoded, &source));
    // A pad in the same place is a padding error, not a character error.
    source[64] = '=';
    try testing.expectError(error.InvalidPadding, standard.decode(&decoded, &source));
}
