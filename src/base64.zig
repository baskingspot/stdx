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
//! The kernel is chosen from the target CPU at compile time, not at run
//! time: aarch64 gets NEON, x86-64 gets AVX2 or AVX-512 VBMI when the target
//! has them, and anything else gets std's codec. There is no CPUID probe and
//! no indirect call, so a build for the x86-64 baseline has no acceleration
//! and a build for `x86_64_v3` has it compiled in.
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
    /// A byte in the input is not in the alphabet. A pad character where
    /// it does not belong is reported as this error or as `InvalidPadding`
    /// depending on which path found it; both mean the input is rejected.
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
            if (comptime isa == .scalar) return fallback.encoder.encode(dest, source);

            const done = kernel.encodeBlocks(alphabet, dest.ptr, source.ptr, source.len);
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
            if (comptime isa == .scalar) return fallback.decode(dest, source);
            const out_len = try decodedLen(source);
            if (dest.len < out_len) return error.NoSpaceLeft;

            const done = try kernel.decodeBlocks(alphabet, .{
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
    };
}

/// Sentinel for a byte that is not in the alphabet.
const invalid: u8 = 0xFF;

// The kernels.
//
// The instruction set is chosen at compile time from the target CPU. There
// is no run-time dispatch and no CPUID probe: a build for a CPU without the
// features gets std's codec, and a build for one with them gets the kernel
// for that CPU compiled in. A build for the x86-64 baseline gets nothing;
// `-Dcpu=x86_64_v3` or a native build gets AVX2, and `x86_64_v4` or newer
// gets AVX-512.

const Isa = enum { scalar, neon, avx2, avx512_vbmi };

const isa: Isa = blk: {
    const arch = builtin.cpu.arch;
    if (arch == .aarch64) break :blk .neon;
    if (arch == .x86_64) {
        const features = builtin.cpu.features;
        // VBMI is what the AVX-512 kernels need: `vpermb` for both
        // directions and `vpermt2b` for the 128-entry decode table.
        const vbmi: [4]std.Target.x86.Feature = .{ .avx512f, .avx512bw, .avx512vl, .avx512vbmi };
        if (std.Target.x86.featureSetHasAll(features, vbmi)) break :blk .avx512_vbmi;
        if (std.Target.x86.featureSetHas(features, .avx2)) break :blk .avx2;
    }
    break :blk .scalar;
};

/// The block kernels. Every one of them processes whole blocks and returns
/// the source bytes it consumed, so one scalar tail serves all of them.
const kernel = switch (isa) {
    .neon => neon,
    .avx2, .avx512_vbmi => x86,
    .scalar => struct {},
};

const DecodeArgs = struct {
    dest: [*]u8,
    dest_len: usize,
    source: [*]const u8,
    len: usize,
};

const Byte16 = @Vector(16, u8);
const Byte32 = @Vector(32, u8);
const Byte64 = @Vector(64, u8);

/// One 64-byte table as four vector registers. A NEON table permute
/// addresses 64 bytes when its table is four consecutive vector registers,
/// which the register constraints pin; a plain vector operand cannot
/// promise that.
const Table = [4]Byte16;

fn table(comptime bytes: [64]u8) Table {
    var out: Table = undefined;
    for (0..4) |i| out[i] = bytes[i * 16 ..][0..16].*;
    return out;
}

/// The two halves of the 64-entry decode split. Characters below 64 index
/// the first; characters 64 and up index the second by value minus 63, so a
/// character below the split lands on entry 0 and takes its value from the
/// first table alone. Past 126 the index leaves the second table and the
/// character value passes through unchanged, which is above 63.
fn lowTable(comptime alphabet: [64]u8) [64]u8 {
    var out: [64]u8 = @splat(invalid);
    for (alphabet, 0..) |c, value| {
        if (c < 64) out[c] = @intCast(value);
    }
    return out;
}

fn highTable(comptime alphabet: [64]u8) [64]u8 {
    var out: [64]u8 = @splat(invalid);
    out[0] = 0;
    for (alphabet, 0..) |c, value| {
        if (c >= 64) out[c - 63] = @intCast(value);
    }
    return out;
}

const neon = struct {
    /// Source bytes per encode block, and characters per decode block.
    const encode_block = 48;
    const decode_block = 64;

    fn encodeBlocks(comptime alphabet: [64]u8, dest: [*]u8, source: [*]const u8, len: usize) usize {
        const enc = table(alphabet);
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

    fn decodeBlocks(comptime alphabet: [64]u8, args: DecodeArgs) Error!usize {
        const low = table(lowTable(alphabet));
        const high = table(highTable(alphabet));

        const group_chars = decode_unroll * decode_block;
        const group_bytes = group_chars / 4 * 3;
        var i: usize = 0;
        var o: usize = 0;
        // A group is checked after it is written, so the loop bounds itself
        // by the destination as well. A destination sized to the exact
        // decoded length leaves the last group to the scalar tail; one sized
        // to the upper bound runs to the end.
        while (i + group_chars <= args.len and o + group_bytes <= args.dest_len) : ({
            i += group_chars;
            o += group_bytes;
        }) {
            var widest: Byte16 = @splat(0);
            inline for (0..decode_unroll) |k| {
                const block_out = args.dest + o + k * decode_block / 4 * 3;
                const block_in = args.source + i + k * decode_block;
                widest = @max(widest, decodeBlock(low, high, block_out, block_in));
            }
            // The group is already written. A rejected one is left for the
            // scalar tail to redo, which is where the error is reported with
            // the right kind and position.
            if (@reduce(.Max, widest) > 63) return i;
        }
        while (i + decode_block <= args.len and o + decode_block / 4 * 3 <= args.dest_len) : ({
            i += decode_block;
            o += decode_block / 4 * 3;
        }) {
            const widest = decodeBlock(low, high, args.dest + o, args.source + i);
            if (@reduce(.Max, widest) > 63) return i;
        }
        return i;
    }

    /// One 64-character block into 48 bytes, returning the largest decoded
    /// value so the caller can tell whether any character was invalid.
    inline fn decodeBlock(
        low: Table,
        high: Table,
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

const x86 = struct {
    /// AVX2 consumes 24 bytes from a 32-byte load; AVX-512 consumes 48 from
    /// a 64-byte load. Decode is 32 characters to 24 bytes on AVX2 and 64 to
    /// 48 on AVX-512.
    const avx2_in = 24;
    const avx2_load = 32;
    const avx2_decode_chars = 32;
    const avx2_decode_bytes = 24;
    const avx512_in = 48;
    const avx512_load = 64;
    const avx512_decode_chars = 64;
    const avx512_decode_bytes = 48;

    fn encodeBlocks(comptime alphabet: [64]u8, dest: [*]u8, source: [*]const u8, len: usize) usize {
        return switch (isa) {
            .avx512_vbmi => encodeBlocksAvx512(alphabet, dest, source, len),
            .avx2 => encodeBlocksAvx2(alphabet, dest, source, len),
            else => unreachable,
        };
    }

    fn decodeBlocks(comptime alphabet: [64]u8, args: DecodeArgs) Error!usize {
        return switch (isa) {
            .avx512_vbmi => decodeBlocksAvx512(alphabet, args),
            .avx2 => decodeBlocksAvx2(alphabet, args),
            else => unreachable,
        };
    }

    // ---- encode ---------------------------------------------------------

    /// 24 source bytes to 32 characters. Each 128-bit lane holds a 12-byte
    /// window, so the byte permute that lines the 6-bit fields up stays
    /// in-lane and is one `vpshufb`. The fields are then packed by shifting
    /// the two halves of every 32-bit word around a 16-bit multiply.
    fn encodeBlocksAvx2(
        comptime alphabet: [64]u8,
        dest: [*]u8,
        source: [*]const u8,
        len: usize,
    ) usize {
        const enc = encodeLut(alphabet);
        const hi_mask = hiMask();
        const lo_mask = loMask();
        const hi_mul: @Vector(16, u16) = @bitCast(pattern32(.{ 0x40, 0x00, 0x00, 0x04 }));
        const lo_mul: @Vector(16, u16) = @bitCast(pattern32(.{ 0x10, 0x00, 0x00, 0x01 }));

        var i: usize = 0;
        while (i + avx2_load <= len) : (i += avx2_in) {
            const raw: Byte32 = source[i..][0..avx2_load].*;
            // Lane 0 keeps bytes 0..15; lane 1 is the 32-bit word rotation
            // that gives it bytes 12..27.
            const windows = @shuffle(u8, raw, undefined, @Vector(32, i32){
                0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
                12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
            });
            const fields = @shuffle(u8, windows, undefined, @Vector(32, i32){
                1,  0,  2,  1,  4,  3,  5,  4,  7,  6,  8,  7,  10, 9,  11, 10,
                17, 16, 18, 17, 20, 19, 21, 20, 23, 22, 24, 23, 26, 25, 27, 26,
            });
            const a: @Vector(16, u16) = @bitCast(fields);
            const packed_hi = mulhiU16(a & hi_mask, hi_mul);
            const merged: Byte32 = @bitCast(packed_hi | ((a & lo_mask) *% lo_mul));
            // 0..25 takes offset 0, 26..51 takes 1, and 52..63 walk the rest.
            const above_25 = merged > @as(Byte32, @splat(25));
            const index = (merged -| @as(Byte32, @splat(51))) +%
                @select(u8, above_25, @as(Byte32, @splat(1)), @as(Byte32, @splat(0)));
            dest[i / 3 * 4 ..][0..32].* = merged +% pshufb(index, enc);
        }
        return i;
    }

    /// 48 source bytes to 64 characters in three instructions: one permute
    /// to line the 6-bit fields up, one multishift to pack them, and one
    /// permute through the alphabet.
    fn encodeBlocksAvx512(
        comptime alphabet: [64]u8,
        dest: [*]u8,
        source: [*]const u8,
        len: usize,
    ) usize {
        const perm = fieldPermute();
        const shifts = shiftsControl();
        const enc: Byte64 = alphabet;

        var i: usize = 0;
        while (i + avx512_load <= len) : (i += avx512_in) {
            const raw: Byte64 = source[i..][0..avx512_load].*;
            var out: Byte64 = undefined;
            var t: Byte64 = undefined;
            asm volatile (
                \\ vpermb %[raw], %[perm], %[t]
                \\ vpmultishiftqb %[t], %[shifts], %[t]
                \\ vpermb %[enc], %[t], %[out]
                : [out] "=v" (out),
                  [t] "=&v" (t),
                : [raw] "v" (raw),
                  [perm] "v" (perm),
                  [shifts] "v" (shifts),
                  [enc] "v" (enc),
            );
            dest[i / 3 * 4 ..][0..64].* = out;
        }
        return i;
    }

    /// The 64-byte index that reorders 48 source bytes into the 16 groups of
    /// four that `vpmultishiftqb` turns into 6-bit fields. Group k reads
    /// bytes 3k+1, 3k, 3k+2, 3k+1.
    fn fieldPermute() Byte64 {
        var out: [64]u8 = undefined;
        for (0..16) |k| {
            out[k * 4 + 0] = @intCast(3 * k + 1);
            out[k * 4 + 1] = @intCast(3 * k);
            out[k * 4 + 2] = @intCast(3 * k + 2);
            out[k * 4 + 3] = @intCast(3 * k + 1);
        }
        return out;
    }

    /// `vpmultishiftqb` control: the bit offset of each of the eight 6-bit
    /// fields inside its 64-bit lane, one byte per output byte, repeated.
    fn shiftsControl() Byte64 {
        const one: [8]u8 = .{ 10, 4, 22, 16, 42, 36, 54, 48 };
        var out: [64]u8 = undefined;
        for (0..8) |k| @memcpy(out[k * 8 ..][0..8], &one);
        return out;
    }

    /// 6-bit value to character, as a 16-entry table of offsets. The index
    /// is 0 for 0..25, 1 for 26..51, and 2..13 for 52..63: what `uqsub`
    /// against 51 and one comparison produce.
    fn encodeLut(comptime alphabet: [64]u8) Byte32 {
        var half: [16]u8 = @splat(0);
        for (0..64) |v| {
            const index = (v -| 51) + @intFromBool(v > 25);
            half[index] = alphabet[v] -% @as(u8, @intCast(v));
        }
        var out: [32]u8 = undefined;
        @memcpy(out[0..16], &half);
        @memcpy(out[16..32], &half);
        return out;
    }

    // ---- decode ---------------------------------------------------------

    fn decodeBlocksAvx2(comptime alphabet: [64]u8, args: DecodeArgs) Error!usize {
        comptime var t: DecodeTables = undefined;
        comptime {
            t = decodeTables(alphabet);
        }
        var i: usize = 0;
        var o: usize = 0;
        while (i + avx2_decode_chars <= args.len and o + avx2_decode_bytes <= args.dest_len) : ({
            i += avx2_decode_chars;
            o += avx2_decode_bytes;
        }) {
            if (!decodeBlockAvx2(t, args.dest + o, args.source + i)) return i;
        }
        return i;
    }

    fn decodeBlocksAvx512(comptime alphabet: [64]u8, args: DecodeArgs) Error!usize {
        const low = decodeTable(alphabet, 0);
        const high = decodeTable(alphabet, 64);
        const compact = compactIndex();
        var i: usize = 0;
        var o: usize = 0;
        while (i + avx512_decode_chars <= args.len and
            o + avx512_decode_bytes <= args.dest_len) : ({
            i += avx512_decode_chars;
            o += avx512_decode_bytes;
        }) {
            const chars: Byte64 = args.source[i..][0..avx512_decode_chars].*;
            // One 128-entry table lookup, then the high bit of the input
            // forced into the value so a byte above ASCII cannot alias a
            // character through the index's seventh bit.
            var v: Byte64 = low;
            asm volatile ("vpermt2b %[high], %[chars], %[v]"
                : [v] "+v" (v),
                : [high] "v" (high),
                  [chars] "v" (chars),
            );
            v |= chars & @as(Byte64, @splat(0x80));
            if (@reduce(.Max, v) > 63) return i;

            var dense: Byte64 = v;
            asm volatile (
                \\ vpmaddubsw %[k0], %[t], %[t]
                \\ vpmaddwd %[k1], %[t], %[t]
                \\ vpermb %[t], %[compact], %[t]
                : [t] "+v" (dense),
                : [k0] "v" (maddK0Wide()),
                  [k1] "v" (maddK1Wide()),
                  [compact] "v" (compact),
            );
            const bytes: [64]u8 = dense;
            args.dest[o..][0..32].* = bytes[0..32].*;
            args.dest[o + 32 ..][0..16].* = bytes[32..48].*;
        }
        return i;
    }

    /// One 32-character block into 24 bytes. Returns false if any character
    /// is outside the alphabet.
    inline fn decodeBlockAvx2(comptime t: DecodeTables, dest: [*]u8, source: [*]const u8) bool {
        const str: Byte32 = source[0..32].*;
        const lo = str & @as(Byte32, @splat(0x0F));
        const hi = @as(@Vector(16, u16), @bitCast(str)) >> @splat(4);
        const hi_nibbles: Byte32 = @bitCast(hi & @as(@Vector(16, u16), @splat(0x000F)));
        // The classifier: a low-nibble entry and a high-nibble entry that
        // share a bit means the pair is not in the alphabet.
        if (@reduce(.Or, pshufb(lo, t.lo) & pshufb(hi_nibbles, t.hi)) != 0) return false;

        var v = str +% pshufb(hi_nibbles, t.roll);
        if (comptime t.special != null) {
            v = @select(
                u8,
                str == @as(Byte32, @splat(t.special.?)),
                v +% @as(Byte32, @splat(t.special_delta)),
                v,
            );
        }
        // Four 6-bit fields to three bytes: two multiply-adds per 128-bit
        // lane, then the words gathered across the lanes.
        var dense: Byte32 = v;
        asm volatile (
            \\ vpmaddubsw %[k0], %[t], %[t]
            \\ vpmaddwd %[k1], %[t], %[t]
            \\ vpshufb %[pack], %[t], %[t]
            \\ vpermd %[t], %[lanes], %[t]
            : [t] "+v" (dense),
            : [k0] "v" (maddK0()),
              [k1] "v" (maddK1()),
              [pack] "v" (packMask()),
              [lanes] "v" (@as(Byte32, @bitCast(@Vector(8, u32){ 0, 1, 2, 4, 5, 6, 0, 0 }))),
        );
        const bytes: [32]u8 = dense;
        dest[0..16].* = bytes[0..16].*;
        dest[16..24].* = bytes[16..24].*;
        return true;
    }

    const DecodeTables = struct {
        // All fields are compile-time constants derived from the alphabet.
        lo: Byte32,
        hi: Byte32,
        roll: Byte32,
        /// The one character whose value does not follow from its high
        /// nibble's offset, and the correction for it.
        special: ?u8,
        special_delta: u8,
    };

    /// The nibble classifier and the per-nibble value offset, derived from
    /// the alphabet. Every valid (high, low) nibble pair gets a bit in the
    /// high table that the low table clears, so a shared bit means invalid.
    fn decodeTables(comptime alphabet: [64]u8) DecodeTables {
        @setEvalBranchQuota(8000);
        var lo_tab: [16]u8 = @splat(0xFF);
        var hi_tab: [16]u8 = @splat(0xFF);
        var roll: [16]u8 = @splat(0);

        var bits: u8 = 1;
        var groups: [16]bool = @splat(false);
        for (alphabet) |c| {
            const h = c >> 4;
            if (groups[h]) continue;
            groups[h] = true;
            if (bits == 0) @compileError("base64: this alphabet has too many high-nibble groups");
            hi_tab[h] = bits;
            bits <<= 1;
        }
        // Clear, for every low nibble, the bit of each high nibble that
        // does not accept it.
        for (0..16) |h| {
            if (!groups[h]) continue;
            for (0..16) |l| {
                var present = false;
                for (alphabet) |c| {
                    if (c >> 4 == h and c & 0x0F == l) present = true;
                }
                if (!present) lo_tab[l] &= ~hi_tab[h];
            }
        }
        for (lo_tab) |v| {
            if (v == 0) @compileError("base64: this alphabet has no nibble classifier");
        }

        // The offset for each high nibble is taken from that group's first
        // character. At most one character per alphabet can disagree with
        // it; that one takes an explicit correction.
        var special: ?u8 = null;
        var delta: u8 = 0;
        for (0..16) |h| {
            if (!groups[h]) continue;
            var first = true;
            for (alphabet, 0..) |c, value| {
                if (c >> 4 != h) continue;
                if (first) {
                    roll[h] = @as(u8, @intCast(value)) -% c;
                    first = false;
                } else if (c +% roll[h] != @as(u8, @intCast(value))) {
                    const d = @as(u8, @intCast(value)) -% (c +% roll[h]);
                    if (special != null and (special.? != c or delta != d)) {
                        @compileError("base64: the alphabet needs two nibble corrections");
                    }
                    special = c;
                    delta = d;
                }
            }
        }

        return .{
            .lo = repeat16(lo_tab),
            .hi = repeat16(hi_tab),
            .roll = repeat16(roll),
            .special = special,
            .special_delta = delta,
        };
    }

    /// Characters `base` to `base + 63` as an AVX-512 permute table: the
    /// 6-bit value, or 0xFF for a byte outside the alphabet.
    fn decodeTable(comptime alphabet: [64]u8, comptime base: u8) Byte64 {
        var out: [64]u8 = @splat(invalid);
        for (alphabet, 0..) |c, value| {
            if (c >= base and c - base < 64) out[c - base] = @intCast(value);
        }
        return out;
    }

    fn repeat16(comptime half: [16]u8) Byte32 {
        var out: [32]u8 = undefined;
        @memcpy(out[0..16], &half);
        @memcpy(out[16..32], &half);
        return out;
    }

    /// Where byte k of the 48 packed bytes comes from: each 32-bit word of
    /// the multiply-add output holds one 24-bit group in its low three
    /// bytes, and the group is stored least significant byte first.
    fn compactIndex() Byte64 {
        var out: [64]u8 = @splat(0);
        for (0..48) |k| out[k] = @intCast(k / 3 * 4 + (2 - k % 3));
        return out;
    }

    /// The 128-bit lane pack for the AVX2 decoder: three bytes out of each
    /// four, with the unused lanes zeroed.
    fn packMask() Byte32 {
        const lane: [16]u8 = .{ 2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 0x80, 0x80, 0x80, 0x80 };
        return repeat16(lane);
    }

    /// `vpmaddubsw`'s multiplier: 0x01400140 as two 16-bit lanes, so a pair
    /// of 6-bit fields becomes one 12-bit field.
    fn maddK0() Byte32 {
        return pattern32(.{ 0x40, 0x01, 0x40, 0x01 });
    }

    /// The same two multipliers for the 64-byte kernels.
    fn maddK0Wide() Byte64 {
        return pattern64(.{ 0x40, 0x01, 0x40, 0x01 });
    }

    fn maddK1Wide() Byte64 {
        return pattern64(.{ 0x00, 0x10, 0x01, 0x00 });
    }

    /// `vpmaddwd`'s multiplier: 0x00011000, so the two 12-bit halves of a
    /// 32-bit word become the 24-bit group.
    fn maddK1() Byte32 {
        return pattern32(.{ 0x00, 0x10, 0x01, 0x00 });
    }

    /// An eight-byte 16-bit lane mask, as the byte pattern of one 32-bit
    /// word repeated.
    fn hiMask() @Vector(16, u16) {
        return @bitCast(pattern32(.{ 0x00, 0xFC, 0xC0, 0x0F }));
    }

    /// The same for `0x003F03F0`.
    fn loMask() @Vector(16, u16) {
        return @bitCast(pattern32(.{ 0xF0, 0x03, 0x3F, 0x00 }));
    }

    fn pattern32(comptime word: [4]u8) Byte32 {
        var out: [32]u8 = undefined;
        for (0..8) |k| @memcpy(out[k * 4 ..][0..4], &word);
        return out;
    }

    fn pattern64(comptime word: [4]u8) Byte64 {
        var out: [64]u8 = undefined;
        for (0..16) |k| @memcpy(out[k * 4 ..][0..4], &word);
        return out;
    }

    fn mulhiU16(a: @Vector(16, u16), b: @Vector(16, u16)) @Vector(16, u16) {
        var out: @Vector(16, u16) = undefined;
        asm volatile ("vpmulhuw %[b], %[a], %[o]"
            : [o] "=v" (out),
            : [a] "v" (a),
              [b] "v" (b),
        );
        return out;
    }

    fn pshufb(index: Byte32, src: Byte32) Byte32 {
        var out: Byte32 = undefined;
        asm volatile ("vpshufb %[i], %[s], %[o]"
            : [o] "=v" (out),
            : [i] "v" (index),
              [s] "v" (src),
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
    // A pad this early is rejected too. Which error it carries depends on
    // the path that finds it, so the contract is only that it is rejected.
    source[64] = '=';
    if (standard.decode(&decoded, &source)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.InvalidPadding or err == error.InvalidCharacter);
    }
}

// The AVX-512 kernels cannot run on a machine without AVX-512, so their
// constants and the instruction semantics they assume are checked here: a
// portable model of `vpermb`, `vpmultishiftqb`, `vpermt2b`, and the two
// multiply-adds, against std's codec.

test "AVX-512 encode block: the permute and multishift constants" {
    var plain: [48]u8 = undefined;
    var expected: [64]u8 = undefined;
    for (0..16) |seed| {
        for (&plain, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% seed *% 11);
        const want = std.base64.standard.Encoder.encode(&expected, &plain);
        try testing.expectEqualSlices(u8, want, &modelAvx512Encode(plain));
    }
}

test "AVX-512 decode block: the table split and the pack" {
    // Exactly 48 bytes, which is one full block with no partial group.
    const plain = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL";
    var chars: [64]u8 = undefined;
    // 48 bytes encode to exactly 64 characters, so this fills the buffer.
    _ = standard.encode(&chars, plain);
    try testing.expectEqualSlices(u8, plain, &try modelAvx512Decode(chars));
}

fn modelAvx512Encode(plain: [48]u8) [64]u8 {
    const perm: [64]u8 = x86.fieldPermute();
    const shifts: [64]u8 = x86.shiftsControl();
    var raw: [64]u8 = @splat(0);
    @memcpy(raw[0..48], &plain);
    var permuted: [64]u8 = undefined;
    for (0..64) |i| permuted[i] = raw[perm[i] & 63];
    // vpmultishiftqb: byte i takes the eight bits at its control offset
    // inside the 64-bit lane that holds it.
    var fields: [64]u8 = undefined;
    for (0..8) |lane| {
        var lane_bits: u64 = 0;
        for (0..8) |j| lane_bits |= @as(u64, permuted[lane * 8 + j]) << @intCast(8 * j);
        for (0..8) |j| {
            const shift: u6 = @truncate(shifts[lane * 8 + j] & 63);
            fields[lane * 8 + j] = @truncate(lane_bits >> shift);
        }
    }
    var out: [64]u8 = undefined;
    for (0..64) |i| out[i] = standard_alphabet[fields[i] & 63];
    return out;
}

fn modelAvx512Decode(chars: [64]u8) ![48]u8 {
    const low: [64]u8 = x86.decodeTable(standard_alphabet, 0);
    const high: [64]u8 = x86.decodeTable(standard_alphabet, 64);
    const compact: [64]u8 = x86.compactIndex();
    var values: [64]u8 = undefined;
    for (chars, 0..) |c, i| {
        // vpermt2b reads the table half from index bit 6 and the entry from
        // bits 0..5; the input's own high bit is forced into the result.
        values[i] = (if (c & 0x40 != 0) high[c & 63] else low[c & 63]) | (c & 0x80);
    }
    for (values) |value| {
        if (value > 63) return error.InvalidCharacter;
    }
    // vpmaddubsw then vpmaddwd: four 6-bit fields become one 24-bit group,
    // least significant byte first, in each 32-bit lane.
    var groups: [64]u8 = @splat(0);
    for (0..16) |k| {
        const a: u24 = @as(u24, values[k * 4 + 0]) << 18;
        const b: u24 = @as(u24, values[k * 4 + 1]) << 12;
        const c: u24 = @as(u24, values[k * 4 + 2]) << 6;
        const d: u24 = values[k * 4 + 3];
        const group = a | b | c | d;
        groups[k * 4 + 0] = @truncate(group);
        groups[k * 4 + 1] = @truncate(group >> 8);
        groups[k * 4 + 2] = @truncate(group >> 16);
    }
    var out: [48]u8 = undefined;
    for (0..48) |k| out[k] = groups[compact[k]];
    return out;
}
