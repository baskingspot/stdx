//! CRC-32C, the Castagnoli checksum: `hash` for one buffer, and `append` to
//! continue a digest that is already stored.
//!
//! Castagnoli's polynomial is not IEEE 802.3's, the one `std.hash.Crc32`
//! computes. The reflected forms are 0x82F63B78 against 0xEDB88320, and the
//! check value of `"123456789"` separates them: `0xE306_9283` here,
//! `0xCBF4_3926` there. Castagnoli is the one the hardware implements, since
//! SSE4.2's `crc32` and ARMv8's `crc32c` are one instruction per eight bytes,
//! so the formats that checksum in bulk store it: iSCSI (RFC 3720), ext4,
//! btrfs, and the LevelDB family.
//!
//! `append` takes a finalized digest and returns one. A stored checksum seeds
//! the next fragment, and a chain of `append` calls equals one `hash` over the
//! concatenation. `0` starts a chain, and `append(digest, "")` is `digest`, so
//! a writer that appends empty fragments stays correct. No type holds state:
//! the digest is the whole of it, which is what a persisted field stores.
//!
//! `std.hash.crc.@"CRC-32/ISCSI"` is the same checksum with the opposite
//! convention. Its `crc` field holds the finalized digest in the SSE4.2
//! kernel and the raw running state in the generic one, so a stored value
//! means different things on different targets: a digest that continues a
//! chain through one kernel does not through the other. Nothing but a digest
//! crosses this module's API, so `append(hash(a), b)` is `hash(a ++ b)`
//! everywhere.
//!
//! The kernel comes from the target CPU at compile time: SSE4.2 on x86-64,
//! the ARMv8 CRC instructions on aarch64, slice-by-16 tables elsewhere. Both
//! instruction kernels run three independent chains, one per cycle of the
//! instruction's latency, and combine them with a table operator. There is no
//! run-time dispatch: a baseline build gets the table kernel, and
//! `-Dcpu=...` decides.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;

/// Castagnoli's polynomial, reflected: the form a right-shifting CRC needs.
/// IEEE 802.3's reflected polynomial, for contrast, is 0xEDB88320.
const poly: u32 = 0x82F6_3B78;

/// The running state starts at all ones, and the digest is its complement:
/// RFC 3720's conditioning, and the reason a digest is a fixed value rather
/// than an internal register.
const complement: u32 = 0xffff_ffff;

/// The CRC-32C digest of `bytes`.
pub fn hash(bytes: []const u8) u32 {
    return append(0, bytes);
}

/// The CRC-32C digest of `bytes`, continued from the digest `previous`.
///
/// `previous` is `0` for the first fragment of a message. `append(digest,
/// "")` returns `digest` unchanged, so an empty fragment costs nothing and
/// changes nothing.
pub fn append(previous: u32, bytes: []const u8) u32 {
    return fold(previous ^ complement, bytes) ^ complement;
}

/// Thread `bytes` through the raw running state. The complement lives in
/// `append`, which is what makes every kernel interchangeable: each one takes
/// and returns the unconditioned state.
fn fold(raw: u32, bytes: []const u8) u32 {
    return kernel.fold(raw, bytes);
}

/// The kernel the target gets.
const Selection = enum { table, aarch64, x86_64 };

/// The selection, from the target CPU at compile time. Both extensions are
/// optional: the x86-64 baseline does not have SSE4.2 and a baseline aarch64
/// does not have the CRC extension, so a build that names neither gets the
/// table kernel. `crc32` is the instruction's own x86 feature, which SSE4.2
/// implies.
const selection: Selection = blk: {
    if (builtin.cpu.arch == .aarch64) {
        if (std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc)) break :blk .aarch64;
    } else if (builtin.cpu.arch == .x86_64) {
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .crc32)) break :blk .x86_64;
    }
    break :blk .table;
};

/// The kernel as a namespace with `fold`, `step8`, `step4`, `step1`, and the
/// width `step8` carries the running state in.
const kernel = switch (selection) {
    .table => table,
    .aarch64 => aarch64,
    .x86_64 => x86_64,
};

/// The raw CRC of one byte from a zero state. Every table in this file is
/// built from it.
const byte_table: [256]u32 = blk: {
    @setEvalBranchQuota(10_000);
    var out: [256]u32 = undefined;
    for (&out, 0..) |*entry, byte| {
        var state: u32 = @intCast(byte);
        for (0..8) |_| {
            state = if (state & 1 != 0) (state >> 1) ^ poly else state >> 1;
        }
        entry.* = state;
    }
    break :blk out;
};

/// One byte of the running state. The table kernel's inner form, and the
/// definition of a zero byte's effect that the advance operator follows.
inline fn stepByte(state: u32, byte: u8) u32 {
    return byte_table[(state ^ byte) & 0xff] ^ (state >> 8);
}

/// The reference kernel: one bit at a time, straight from the polynomial.
/// Slow enough to be obviously correct, and the only kernel every target can
/// run, so the tests compare the others against it.
const bitwise = struct {
    fn fold(raw_in: u32, bytes: []const u8) u32 {
        var raw = raw_in;
        for (bytes) |byte| {
            raw ^= byte;
            for (0..8) |_| raw = if (raw & 1 != 0) (raw >> 1) ^ poly else raw >> 1;
        }
        return raw;
    }
};

/// The fallback kernel: sixteen bytes per step, sixteen tables of one
/// kilobyte each. `tables[k][x]` is the CRC of byte `x` followed by `k` zero
/// bytes, which is the recurrence that makes one step consume a whole slice:
/// the four words XOR into the state, and the sixteen lookups are independent.
const table = struct {
    const slice_count = 16;

    const tables: [slice_count][256]u32 = blk: {
        @setEvalBranchQuota(300_000);
        var out: [slice_count][256]u32 = undefined;
        out[0] = byte_table;
        for (1..slice_count) |k| {
            for (0..256) |i| {
                out[k][i] = (out[k - 1][i] >> 8) ^ byte_table[out[k - 1][i] & 0xff];
            }
        }
        break :blk out;
    };

    fn fold(raw_in: u32, bytes: []const u8) u32 {
        var raw = raw_in;
        var rest = bytes;
        while (rest.len >= slice_count) {
            const w0 = mem.readInt(u32, rest[0..4], .little);
            const w1 = mem.readInt(u32, rest[4..8], .little);
            const w2 = mem.readInt(u32, rest[8..12], .little);
            const w3 = mem.readInt(u32, rest[12..16], .little);
            raw ^= w0;
            raw = tables[15][raw & 0xff] ^ tables[14][(raw >> 8) & 0xff] ^
                tables[13][(raw >> 16) & 0xff] ^ tables[12][raw >> 24] ^
                tables[11][w1 & 0xff] ^ tables[10][(w1 >> 8) & 0xff] ^
                tables[9][(w1 >> 16) & 0xff] ^ tables[8][w1 >> 24] ^
                tables[7][w2 & 0xff] ^ tables[6][(w2 >> 8) & 0xff] ^
                tables[5][(w2 >> 16) & 0xff] ^ tables[4][w2 >> 24] ^
                tables[3][w3 & 0xff] ^ tables[2][(w3 >> 8) & 0xff] ^
                tables[1][(w3 >> 16) & 0xff] ^ tables[0][w3 >> 24];
            rest = rest[slice_count..];
        }
        for (rest) |byte| raw = stepByte(raw, byte);
        return raw;
    }
};

/// Apply a 32x32 GF(2) operator to a state: XOR the images of the set bits.
inline fn applyOperator(operator: *const [32]u32, state: u32) u32 {
    var sum: u32 = 0;
    var remaining = state;
    var bit: usize = 0;
    while (remaining != 0) : (bit += 1) {
        if (remaining & 1 != 0) sum ^= operator[bit];
        remaining >>= 1;
    }
    return sum;
}

/// `a` applied after `b`: composition of two operators.
fn compose(a: *const [32]u32, b: *const [32]u32) [32]u32 {
    var out: [32]u32 = undefined;
    for (&out, b) |*vector, basis| vector.* = applyOperator(a, basis);
    return out;
}

/// The operator that advances the raw state by `length` zero bytes, as the
/// images of the 32 basis vectors.
///
/// The CRC is linear over GF(2), so the state after `length` zero bytes is
/// the same XOR of basis images as the state itself. Building the operator
/// from the one-byte case and squaring gets any length in log2(length)
/// compositions instead of `length` steps. zlib's `crc32_combine` is the same
/// trick, and it is what lets the parallel chains below be combined without
/// recomputing anything.
fn advanceOperator(comptime length: usize) [32]u32 {
    @setEvalBranchQuota(100_000);

    // One zero byte, straight from the byte table's definition.
    var square: [32]u32 = undefined;
    for (&square, 0..) |*vector, bit| {
        const state: u32 = @as(u32, 1) << @intCast(bit);
        vector.* = byte_table[state & 0xff] ^ (state >> 8);
    }

    // Binary exponentiation: the identity starts the accumulator, and each
    // step either folds in the current power or skips it.
    var operator: [32]u32 = undefined;
    for (&operator, 0..) |*vector, bit| vector.* = @as(u32, 1) << @intCast(bit);
    var remaining = length;
    while (remaining != 0) : (remaining >>= 1) {
        if (remaining & 1 != 0) operator = compose(&operator, &square);
        const doubled = compose(&square, &square);
        square = doubled;
    }
    return operator;
}

/// The advance operator in the shape the combine uses: one 256-entry table
/// per state byte.
fn advanceTables(comptime length: usize) [4][256]u32 {
    @setEvalBranchQuota(1_000_000);
    const operator = advanceOperator(length);
    var out: [4][256]u32 = undefined;
    for (0..256) |value| {
        const byte: u32 = @intCast(value);
        out[0][value] = applyOperator(&operator, byte);
        out[1][value] = applyOperator(&operator, byte << 8);
        out[2][value] = applyOperator(&operator, byte << 16);
        out[3][value] = applyOperator(&operator, byte << 24);
    }
    return out;
}

/// The chains per pass. A `crc32` instruction takes about three cycles and
/// one is issued per cycle, so three independent chains keep the unit busy. A
/// fourth would add another table combine for no throughput.
const lane_count = 3;

/// The bytes each chain walks in one pass. The combine costs four dependent
/// table reads per lane, so a longer pass amortizes it better and a shorter
/// one spends more time on it: the benchmark row picks 192 in a sweep of 128
/// through 1024, where 192 is the fastest and 1024 is 17% slower.
const pass_bytes = 192;

/// The advance-by-`pass_bytes` operator in the shape the combine uses.
const advance_tables: [4][256]u32 = advanceTables(pass_bytes);

/// Advance the raw state by `pass_bytes` zero bytes.
inline fn advance(state: u32) u32 {
    return advance_tables[0][state & 0xff] ^
        advance_tables[1][(state >> 8) & 0xff] ^
        advance_tables[2][(state >> 16) & 0xff] ^
        advance_tables[3][state >> 24];
}

/// One pass: `lane_count` independent chains over consecutive lanes of
/// `pass_bytes`, combined where they end. `CRC(A ++ B)` is
/// `advance(crc_A) ^ crc_B` when `crc_B` starts from zero, which is what a
/// chain started from zero computes, so the lanes combine in order regardless
/// of their length.
inline fn pass(comptime Isa: type, raw: u32, p: [*]const u8) u32 {
    var lanes: [lane_count]Isa.Word = .{ raw, 0, 0 };
    for (0..pass_bytes / 8) |step| {
        inline for (0..lane_count) |lane| {
            lanes[lane] = Isa.step8(lanes[lane], p + lane * pass_bytes + step * 8);
        }
    }
    // The state's high bits stay zero in a Word wider than u32, so the
    // truncation loses nothing.
    const head = advance(@as(u32, @truncate(lanes[0]))) ^ @as(u32, @truncate(lanes[1]));
    return advance(head) ^ @as(u32, @truncate(lanes[2]));
}

/// The loop both instruction kernels share. `Isa` provides `step8`, `step4`,
/// `step1`, and the width `step8` carries: eight-byte reads never need an
/// aligned pointer, since `mem.readInt` is defined for any address. Below one
/// pass the remainder runs one chain.
fn interleaved(comptime Isa: type, raw_in: u32, bytes: []const u8) u32 {
    var raw = raw_in;
    var rest = bytes;
    while (rest.len >= lane_count * pass_bytes) {
        raw = pass(Isa, raw, rest.ptr);
        rest = rest[lane_count * pass_bytes ..];
    }
    while (rest.len >= 8) : (rest = rest[8..]) {
        raw = @as(u32, @truncate(Isa.step8(raw, rest.ptr)));
    }
    if (rest.len >= 4) {
        raw = Isa.step4(raw, rest.ptr);
        rest = rest[4..];
    }
    for (rest) |byte| raw = Isa.step1(raw, byte);
    return raw;
}

/// The ARMv8 CRC instructions. `crc32cx` folds eight bytes into the state,
/// `crc32cw` four, and `crc32cb` one. All three take the running state as a
/// 32-bit register, which the `:w` modifier names: the operand's type alone
/// leaves the register class to the allocator.
const aarch64 = struct {
    const Word = u32;

    fn fold(raw: u32, bytes: []const u8) u32 {
        return interleaved(aarch64, raw, bytes);
    }

    inline fn step8(raw: Word, p: [*]const u8) Word {
        var state = raw;
        const data = mem.readInt(u64, p[0..8], .little);
        asm volatile ("crc32cx %[state:w], %[state:w], %[data]"
            : [state] "+r" (state),
            : [data] "r" (data),
        );
        return state;
    }

    inline fn step4(raw: u32, p: [*]const u8) u32 {
        var state = raw;
        const data = mem.readInt(u32, p[0..4], .little);
        asm volatile ("crc32cw %[state:w], %[state:w], %[data:w]"
            : [state] "+r" (state),
            : [data] "r" (data),
        );
        return state;
    }

    inline fn step1(raw: u32, byte: u8) u32 {
        var state = raw;
        asm volatile ("crc32cb %[state:w], %[state:w], %[byte:w]"
            : [state] "+r" (state),
            : [byte] "r" (byte),
        );
        return state;
    }
};

/// The SSE4.2 CRC instruction. `crc32q` writes a 64-bit register, so the
/// chain carries a `u64` and the upper half stays zero; the trailing steps
/// use the 32-bit forms.
const x86_64 = struct {
    const Word = u64;

    fn fold(raw: u32, bytes: []const u8) u32 {
        return interleaved(x86_64, raw, bytes);
    }

    inline fn step8(raw: Word, p: [*]const u8) Word {
        var state = raw;
        const data = mem.readInt(u64, p[0..8], .little);
        asm volatile ("crc32q %[data], %[state]"
            : [state] "+r" (state),
            : [data] "r" (data),
        );
        return state;
    }

    inline fn step4(raw: u32, p: [*]const u8) u32 {
        var state = raw;
        const data = mem.readInt(u32, p[0..4], .little);
        asm volatile ("crc32l %[data], %[state]"
            : [state] "+r" (state),
            : [data] "r" (data),
        );
        return state;
    }

    inline fn step1(raw: u32, byte: u8) u32 {
        var state = raw;
        asm volatile ("crc32b %[byte], %[state]"
            : [state] "+r" (state),
            : [byte] "r" (byte),
        );
        return state;
    }
};

/// One kernel's digest of `bytes`, conditioned the way `hash` conditions the
/// selected one, so a test can compare two kernels' final values.
fn kernelDigest(comptime Kernel: type, bytes: []const u8) u32 {
    return Kernel.fold(complement, bytes) ^ complement;
}

// The corpus every test reads from: one comptime LCG stream, so a slice is a
// different string at every length and offset.
const corpus_len = 16 * 1024;

const corpus: [corpus_len]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var data: [corpus_len]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&data) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    break :blk data;
};

/// Every kernel this target can run agrees with `expected` on `bytes`. The
/// feature tests are `comptime` because a call to `featureSetHas` is not
/// folded by itself: without the keyword the dead branch is still analyzed,
/// and the aarch64 assembler rejects the instruction on a target that lacks
/// the extension.
fn expectKernels(expected: u32, bytes: []const u8) !void {
    try testing.expectEqual(expected, hash(bytes));
    try testing.expectEqual(expected, kernelDigest(table, bytes));
    if (comptime builtin.cpu.arch == .aarch64) {
        if (comptime std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc)) {
            try testing.expectEqual(expected, kernelDigest(aarch64, bytes));
        }
    }
    if (comptime builtin.cpu.arch == .x86_64) {
        if (comptime std.Target.x86.featureSetHas(builtin.cpu.features, .crc32)) {
            try testing.expectEqual(expected, kernelDigest(x86_64, bytes));
        }
    }
}

// RFC 3720 appendix B.4's vectors, which are the reference's own: the
// check value today's catalogue calls "123456789", 32 zero bytes, 32 0xFF
// bytes, the byte values 0x00 to 0x1F, and the same list reversed.
test "the reference vectors" {
    try testing.expectEqual(@as(u32, 0xE306_9283), hash("123456789"));

    const zeros: [32]u8 = @splat(0);
    try testing.expectEqual(@as(u32, 0x8A91_36AA), hash(&zeros));

    const ones: [32]u8 = @splat(0xFF);
    try testing.expectEqual(@as(u32, 0x62A8_AB43), hash(&ones));

    var ascending: [32]u8 = undefined;
    var descending: [32]u8 = undefined;
    for (0..32) |i| {
        ascending[i] = @intCast(i);
        descending[31 - i] = @intCast(i);
    }
    try testing.expectEqual(@as(u32, 0x46DD_794E), hash(&ascending));
    try testing.expectEqual(@as(u32, 0x113F_DB5C), hash(&descending));
}

test "the empty digest is zero and append of nothing is identity" {
    try testing.expectEqual(@as(u32, 0), hash(""));
    for ([_]usize{ 0, 1, 15, 16, 17, 128, corpus_len }) |len| {
        const digest = hash(corpus[0..len]);
        try testing.expectEqual(digest, append(digest, ""));
    }
}

// Lengths 0 through 128 at every offset inside sixteen bytes, which walks
// every tail path and both alignments: an eight-byte read, a four-byte read,
// and the byte loop land on every combination of pointer and length.
test "every kernel agrees with the bitwise reference" {
    for (0..16) |offset| {
        for (0..129) |len| {
            const bytes = corpus[offset..][0..len];
            try expectKernels(kernelDigest(bitwise, bytes), bytes);
        }
    }
}

// The bulk loop's boundaries: one lane block, a full pass, and the lengths
// where a pass leaves a remainder that only the eight-byte step sees.
test "every kernel agrees across the bulk boundaries" {
    const lengths = [_]usize{
        128,
        129,
        pass_bytes - 1,
        pass_bytes,
        pass_bytes + 1,
        lane_count * pass_bytes - 1,
        lane_count * pass_bytes,
        lane_count * pass_bytes + 1,
        2 * lane_count * pass_bytes,
        3 * lane_count * pass_bytes + 5,
        corpus_len,
    };
    for (lengths) |len| {
        const bytes = corpus[0..len];
        try expectKernels(kernelDigest(bitwise, bytes), bytes);
    }
}

// A continuation from a stored digest is the same as one pass over the
// concatenation at every split, and a zero word in the middle is a hole the
// chains cross.
test "append continues a digest" {
    const zero_word: [8]u8 = @splat(0);
    for (0..16) |offset| {
        for ([_]usize{ 0, 1, 7, 8, 15, 16, 63, 128, 129 }) |len| {
            const bytes = corpus[offset..][0..len];
            for (0..len + 1) |split| {
                const head = append(0, bytes[0..split]);
                try testing.expectEqual(hash(bytes), append(head, bytes[split..]));
            }

            var joined: [2 * 129 + 8]u8 = undefined;
            @memcpy(joined[0..len], bytes);
            @memcpy(joined[len..][0..8], &zero_word);
            @memcpy(joined[len + 8 ..][0..len], bytes);
            const with_hole = append(append(hash(bytes), &zero_word), bytes);
            try testing.expectEqual(hash(joined[0 .. len * 2 + 8]), with_hole);
        }
    }
}

test "the kernel follows the target" {
    const select = struct {
        fn expected(
            comptime arch: std.Target.Cpu.Arch,
            comptime features: std.Target.Cpu.Feature.Set,
        ) Selection {
            if (arch == .aarch64) {
                if (std.Target.aarch64.featureSetHas(features, .crc)) return .aarch64;
            } else if (arch == .x86_64) {
                if (std.Target.x86.featureSetHas(features, .crc32)) return .x86_64;
            }
            return .table;
        }
    };
    try testing.expectEqual(select.expected(builtin.cpu.arch, builtin.cpu.features), selection);
}
