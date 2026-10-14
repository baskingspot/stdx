// rapidhash V3, Copyright (C) 2025 Nicolas De Carli, MIT (notice below).
// Ported from Nicoshev/rapidhash rapidhash.h, tag rapidhash_v3 (bc4b4ba).
// The algorithm and constants are transcribed verbatim; the structure is
// adapted to Zig (readInt reads, u128 mum, per-variant internals).

//! Rapidhash V3: a fast 64-bit non-cryptographic hash, and the explicit-seed
//! drop-in for `std.hash.Wyhash.hash`. Every read is unaligned
//! little-endian, so the output is independent of the host and reproduces
//! upstream's values.
//!
//! Three variants differ in how much memory-level parallelism the bulk loop
//! exposes: `hash` runs seven lanes over 112-byte blocks, `hashMicro` five
//! over 80, `hashNano` three over 48. A narrower variant returns exactly
//! what `hash` returns while the input fits its block size — up to 80 bytes
//! for micro, 48 for nano — so a caller trades bulk throughput for code size
//! without changing short-key hashes.
//!
//! The seed is explicit, like `std.hash.Wyhash.hash`. Upstream's no-seed
//! entry points use seed 0; pass 0 for that behavior. No seeded-by-default
//! convenience is provided.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

/// The V3 secret schedule, upstream's values verbatim. `secret[7]` feeds
/// only the final avalanche.
const secret = [8]u64{
    0x2d358dccaa6c78a5,
    0x8bb84b93962eacc9,
    0x4b33a62ed433d4a3,
    0x4d5a2da51de1aa47,
    0xa0761d6478bd642f,
    0xe7037ed1a0b428db,
    0x90ed1765281c388c,
    0xaaaaaaaaaaaaaaaa,
};

/// The halves of a 64x64 widening multiply.
const Mums = struct {
    low: u64,
    high: u64,
};

/// 64x64 -> 128 multiply, split into halves. A u64 x u64 product always
/// fits u128, so no wrapping operators are needed.
inline fn mum(a: u64, b: u64) Mums {
    const r = @as(u128, a) * @as(u128, b);
    return .{ .low = @truncate(r), .high = @truncate(r >> 64) };
}

/// Upstream's `rapid_mix`: multiply, then fold the halves together.
inline fn mix(a: u64, b: u64) u64 {
    const m = mum(a, b);
    return m.low ^ m.high;
}

/// Unaligned little-endian read. `readInt` handles the alignment; the
/// explicit endianness keeps the output host-independent.
inline fn read64(p: [*]const u8, offset: usize) u64 {
    return mem.readInt(u64, p[offset..][0..8], .little);
}

inline fn read32(p: [*]const u8, offset: usize) u32 {
    return mem.readInt(u32, p[offset..][0..4], .little);
}

/// The seed premix shared by all three variants.
inline fn premix(seed_in: u64) u64 {
    return seed_in ^ mix(seed_in ^ secret[2], secret[1]);
}

/// The `len <= 16` path's result: the possibly-seeded seed, and the two
/// accumulator halves.
const Small = struct {
    seed: u64,
    a: u64,
    b: u64,
};

/// The `len <= 16` path shared by all three variants. For `len >= 4` the
/// length folds into the seed and the reads overlap at both ends; below
/// that, the first, middle, and last bytes are packed.
inline fn smallKey(seed: u64, p: [*]const u8, len: usize) Small {
    if (len >= 4) {
        const seeded = seed ^ @as(u64, len);
        if (len >= 8) {
            return .{ .seed = seeded, .a = read64(p, 0), .b = read64(p, len - 8) };
        }
        return .{ .seed = seeded, .a = read32(p, 0), .b = read32(p, len - 4) };
    }
    if (len > 0) {
        return .{
            .seed = seed,
            .a = (@as(u64, p[0]) << 45) | p[len - 1],
            .b = p[len >> 1],
        };
    }
    return .{ .seed = seed, .a = 0, .b = 0 };
}

/// The closing avalanche shared by all three variants. `i` is the length
/// threaded out of the bulk loop: the full length unless a bulk block ran,
/// in which case it is the leftover. Upstream mixes that same `i` into the
/// high half.
inline fn finalize(seed: u64, a: u64, b: u64, i: usize) u64 {
    const m = mum(a ^ secret[1], b ^ seed);
    return mix(m.low ^ secret[7], m.high ^ secret[1] ^ @as(u64, i));
}

/// The two 8-byte reads that close the long path, taken from the input's
/// last 16 bytes. After a bulk loop `i` is the remainder and can be shorter
/// than 16: `p + i` is the input's end, so `- 16` stays inside the buffer
/// even then. The remainder folds into `a`.
inline fn tail16(p: [*]const u8, i: usize) [2]u64 {
    const tail = p + i - 16;
    return .{ read64(tail, 0) ^ @as(u64, i), read64(tail, 8) };
}

/// The 7-lane, 112-byte-block internal behind `hash`.
fn hashInternal(seed_in: u64, input: []const u8) u64 {
    const len = input.len;
    var p: [*]const u8 = input.ptr;
    var i = len;
    var seed = premix(seed_in);
    var a: u64 = undefined;
    var b: u64 = undefined;

    if (len <= 16) {
        const small = smallKey(seed, p, len);
        seed = small.seed;
        a = small.a;
        b = small.b;
    } else {
        if (len > 112) {
            var see1 = seed;
            var see2 = seed;
            var see3 = seed;
            var see4 = seed;
            var see5 = seed;
            var see6 = seed;
            while (i > 112) {
                seed = mix(read64(p, 0) ^ secret[0], read64(p, 8) ^ seed);
                see1 = mix(read64(p, 16) ^ secret[1], read64(p, 24) ^ see1);
                see2 = mix(read64(p, 32) ^ secret[2], read64(p, 40) ^ see2);
                see3 = mix(read64(p, 48) ^ secret[3], read64(p, 56) ^ see3);
                see4 = mix(read64(p, 64) ^ secret[4], read64(p, 72) ^ see4);
                see5 = mix(read64(p, 80) ^ secret[5], read64(p, 88) ^ see5);
                see6 = mix(read64(p, 96) ^ secret[6], read64(p, 104) ^ see6);
                p += 112;
                i -= 112;
            }
            seed ^= see1;
            see2 ^= see3;
            see4 ^= see5;
            seed ^= see6;
            see2 ^= see4;
            seed ^= see2;
        }
        if (i > 16) {
            seed = mix(read64(p, 0) ^ secret[2], read64(p, 8) ^ seed);
            if (i > 32) {
                seed = mix(read64(p, 16) ^ secret[2], read64(p, 24) ^ seed);
                if (i > 48) {
                    seed = mix(read64(p, 32) ^ secret[1], read64(p, 40) ^ seed);
                    if (i > 64) {
                        seed = mix(read64(p, 48) ^ secret[1], read64(p, 56) ^ seed);
                        if (i > 80) {
                            seed = mix(read64(p, 64) ^ secret[2], read64(p, 72) ^ seed);
                            if (i > 96) {
                                seed = mix(read64(p, 80) ^ secret[1], read64(p, 88) ^ seed);
                            }
                        }
                    }
                }
            }
        }
        const tail = tail16(p, i);
        a = tail[0];
        b = tail[1];
    }

    return finalize(seed, a, b, i);
}

/// The 5-lane, 80-byte-block internal behind `hashMicro`.
fn microInternal(seed_in: u64, input: []const u8) u64 {
    const len = input.len;
    var p: [*]const u8 = input.ptr;
    var i = len;
    var seed = premix(seed_in);
    var a: u64 = undefined;
    var b: u64 = undefined;

    if (len <= 16) {
        const small = smallKey(seed, p, len);
        seed = small.seed;
        a = small.a;
        b = small.b;
    } else {
        if (len > 80) {
            var see1 = seed;
            var see2 = seed;
            var see3 = seed;
            var see4 = seed;
            while (i > 80) {
                seed = mix(read64(p, 0) ^ secret[0], read64(p, 8) ^ seed);
                see1 = mix(read64(p, 16) ^ secret[1], read64(p, 24) ^ see1);
                see2 = mix(read64(p, 32) ^ secret[2], read64(p, 40) ^ see2);
                see3 = mix(read64(p, 48) ^ secret[3], read64(p, 56) ^ see3);
                see4 = mix(read64(p, 64) ^ secret[4], read64(p, 72) ^ see4);
                p += 80;
                i -= 80;
            }
            seed ^= see1;
            see2 ^= see3;
            seed ^= see4;
            seed ^= see2;
        }
        if (i > 16) {
            seed = mix(read64(p, 0) ^ secret[2], read64(p, 8) ^ seed);
            if (i > 32) {
                seed = mix(read64(p, 16) ^ secret[2], read64(p, 24) ^ seed);
                if (i > 48) {
                    seed = mix(read64(p, 32) ^ secret[1], read64(p, 40) ^ seed);
                    if (i > 64) {
                        seed = mix(read64(p, 48) ^ secret[1], read64(p, 56) ^ seed);
                    }
                }
            }
        }
        const tail = tail16(p, i);
        a = tail[0];
        b = tail[1];
    }

    return finalize(seed, a, b, i);
}

/// The 3-lane, 48-byte-block internal behind `hashNano`.
fn nanoInternal(seed_in: u64, input: []const u8) u64 {
    const len = input.len;
    var p: [*]const u8 = input.ptr;
    var i = len;
    var seed = premix(seed_in);
    var a: u64 = undefined;
    var b: u64 = undefined;

    if (len <= 16) {
        const small = smallKey(seed, p, len);
        seed = small.seed;
        a = small.a;
        b = small.b;
    } else {
        if (len > 48) {
            var see1 = seed;
            var see2 = seed;
            while (i > 48) {
                seed = mix(read64(p, 0) ^ secret[0], read64(p, 8) ^ seed);
                see1 = mix(read64(p, 16) ^ secret[1], read64(p, 24) ^ see1);
                see2 = mix(read64(p, 32) ^ secret[2], read64(p, 40) ^ see2);
                p += 48;
                i -= 48;
            }
            seed ^= see1;
            seed ^= see2;
        }
        if (i > 16) {
            seed = mix(read64(p, 0) ^ secret[2], read64(p, 8) ^ seed);
            if (i > 32) {
                seed = mix(read64(p, 16) ^ secret[2], read64(p, 24) ^ seed);
            }
        }
        const tail = tail16(p, i);
        a = tail[0];
        b = tail[1];
    }

    return finalize(seed, a, b, i);
}

/// Hash `input` with `seed`: the 7-lane general variant, a drop-in for
/// `std.hash.Wyhash.hash` with the same explicit-seed signature.
pub fn hash(seed: u64, input: []const u8) u64 {
    return hashInternal(seed, input);
}

/// Hash `input` with `seed` using the 5-lane variant. Returns exactly what
/// `hash` returns for inputs up to 80 bytes; beyond that the bulk loop
/// starts and the value diverges from `hash`.
pub fn hashMicro(seed: u64, input: []const u8) u64 {
    return microInternal(seed, input);
}

/// Hash `input` with `seed` using the 3-lane variant. Returns exactly what
/// `hash` returns for inputs up to 48 bytes; beyond that the bulk loop
/// starts and the value diverges from `hash`.
pub fn hashNano(seed: u64, input: []const u8) u64 {
    return nanoInternal(seed, input);
}

// The test inputs are prefixes of one comptime LCG stream, so inputs of
// different lengths are different strings by construction.
const test_data_len = 16 * 1024;

const test_data = blk: {
    @setEvalBranchQuota(100_000);
    var data: [test_data_len]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&data) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    break :blk data;
};

/// Every length that switches a branch: the small-path reads (0, 1, 3, 4,
/// 7, 8, 16), the long-path start (17), each tail step (32, 48, 64, 80, 96,
/// 112), and the multi-block lengths (113, 128, 224, 225).
const boundary_lens = [_]usize{
    0,   1,   3,  4,  7,  8,   16,  17,
    32,  48,  64, 80, 96, 112, 113, 128,
    224, 225,
};

const seed_table = [_]u64{ 0, 1, 2, 3, 0x9e37_79b9_7f4a_7c15, 0xffff_ffff_ffff_ffff };

const seed_inputs = [_][]const u8{
    "",
    "a",
    test_data[0..16],
    test_data[0..17],
    test_data[0..113],
    test_data[0..1024],
};

// Comptime evaluation is a second interpreter over the same transcription:
// a wrong constant, an off-by-one step, or a bad u128 fold shows up as a
// mismatch against the compiled call.
test "comptime and runtime agree" {
    @setEvalBranchQuota(1_000_000);
    const lens = [_]usize{
        0,    1,             2,  3,  4,   7,   8,   16,  17,  32,
        48,   64,            80, 96, 112, 113, 128, 224, 225, 1024,
        4096, test_data_len,
    };
    const seeds = [_]u64{ 0, 0x9e37_79b9_7f4a_7c15 };
    inline for (lens) |len| {
        const input: []const u8 = test_data[0..len];
        inline for (seeds) |seed| {
            try testing.expectEqual(comptime hash(seed, input), hash(seed, input));
            try testing.expectEqual(comptime hashMicro(seed, input), hashMicro(seed, input));
            try testing.expectEqual(comptime hashNano(seed, input), hashNano(seed, input));
        }
    }
}

// The boundary strings hash without trapping, and the fixed table has no
// pairwise collisions under any variant.
test "boundary lengths hash distinctly" {
    const Test = struct {
        fn check(comptime hasher: fn (u64, []const u8) u64) !void {
            var hashes: [boundary_lens.len]u64 = undefined;
            for (boundary_lens, 0..) |len, idx| {
                hashes[idx] = hasher(0, test_data[0..len]);
            }
            for (hashes, 0..) |h1, i| {
                for (hashes[i + 1 ..]) |h2| {
                    try testing.expect(h1 != h2);
                }
            }
        }
    };
    try Test.check(hash);
    try Test.check(hashMicro);
    try Test.check(hashNano);
}

test "micro and nano agree with hash on short inputs" {
    for (boundary_lens) |len| {
        const input = test_data[0..len];
        if (len <= 80) {
            try testing.expectEqual(hash(0, input), hashMicro(0, input));
        }
        if (len <= 48) {
            try testing.expectEqual(hash(0, input), hashNano(0, input));
        }
    }
}

// The agreement above is bounded by the block size. Past it the bulk loop
// runs and the fixed strings below must differ, so the equivalence test
// cannot pass on three aliases of one function.
test "micro and nano diverge past their block sizes" {
    try testing.expect(hash(0, test_data[0..81]) != hashMicro(0, test_data[0..81]));
    try testing.expect(hash(0, test_data[0..49]) != hashNano(0, test_data[0..49]));
}

test "seed sensitivity" {
    const Test = struct {
        fn check(comptime hasher: fn (u64, []const u8) u64) !void {
            for (seed_inputs) |input| {
                var hashes: [seed_table.len]u64 = undefined;
                for (seed_table, 0..) |seed, idx| {
                    hashes[idx] = hasher(seed, input);
                }
                for (hashes, 0..) |h1, i| {
                    for (hashes[i + 1 ..]) |h2| {
                        try testing.expect(h1 != h2);
                    }
                }
            }
        }
    };
    try Test.check(hash);
    try Test.check(hashMicro);
    try Test.check(hashNano);
}
