//! Memory extensions to `std.mem`.
//!
//! Fixed-size byte values and memory scans that std leaves to hand-rolled
//! code.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const crypto = std.crypto;
const simd = std.simd;

/// A fixed-size byte array wrapper with explicit initialization and zeroing.
pub fn Array(comptime len: comptime_int) type {
    return struct {
        const Self = @This();
        pub const Data = [len]u8;

        data: Data,

        pub const empty: Self = .{ .data = undefined };
        pub const zero: Self = .{ .data = @splat(0) };

        pub inline fn init(data: Data) Self {
            return .{ .data = data };
        }

        pub inline fn secureZero(self: *Self) void {
            crypto.secureZero(u8, &self.data);
        }
    };
}

test Array {
    var secret: Array(4) = .init(.{ 1, 2, 3, 4 });
    secret.secureZero();
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &secret.data);
}

/// Return the index of the last non-zero byte in `buf`, or null if all zeros.
///
/// Fast path: if the last byte is non-zero, returns immediately.
/// SIMD path: processes `chunk_len` bytes at a time backwards, where
/// `chunk_len` is target-optimal (suggestVectorLength).
/// Scalar path: handles the remaining prefix shorter than `chunk_len`.
///
/// `buf` must be non-empty — caller is responsible for ensuring this.
pub fn lastIndexOfNonZero(buf: []const u8) ?usize {
    assert(buf.len > 0);

    var i = buf.len - 1;
    if (buf[i] != 0) return i;

    if (simd.suggestVectorLength(u8)) |block_len| {
        const Block = @Vector(block_len, u8);
        const Mask = @Int(.unsigned, block_len);

        const zero: Block = @splat(0);
        while (i >= block_len) {
            i -= block_len;
            const chunk: Block = buf[i..][0..block_len].*;
            const non_zero = chunk != zero;
            // Hand-rolled mask + clz, not `std.simd.lastTrue`: on aarch64
            // the hit path is four instructions here, while lastTrue's
            // select/iota/reduce-max lowering scalarizes through ~32 `umov`
            // lane round-trips plus stack (verified by disassembly,
            // ReleaseFast, 2026-10). Re-check if std's lowering improves.
            const mask: Mask = @bitCast(non_zero);
            if (mask != 0) return i + block_len - 1 - @clz(mask);
        }
    }

    while (i > 0) {
        i -= 1;
        if (buf[i] != 0) return i;
    }

    return null;
}

test lastIndexOfNonZero {
    const Case = struct { buf: []const u8, expected: ?usize };
    const cases = [_]Case{
        // Last byte non-zero: fast path.
        .{ .buf = &.{ 0, 0, 0, 0xab }, .expected = 3 },
        .{ .buf = &.{ 0, 0, 0, 0 }, .expected = null },
        // Single non-zero byte at start.
        .{ .buf = &.{ 0xab, 0, 0, 0 }, .expected = 0 },
        .{ .buf = &.{0xab}, .expected = 0 },
        .{ .buf = &.{0}, .expected = null },
        // 3 bytes — below any chunk_len, exercises the scalar fallback.
        .{ .buf = &.{ 0, 0xab, 0 }, .expected = 1 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, lastIndexOfNonZero(case.buf));
    }

    // Fixed inputs with literal expectations, no derivation from the
    // implementation's chunking: 256 bytes spans every SIMD width the
    // function can choose (block_len is capped at 32), with leftovers that
    // force the scalar tail. The expected index must be the same under any
    // chunking, on any target.
    const Placement = struct { index: ?usize };
    const placements = [_]Placement{
        .{ .index = 255 }, // last byte: fast path
        .{ .index = null }, // all zeros
        .{ .index = 0 }, // scalar tail, first byte
        .{ .index = 2 }, // scalar tail finds a low index
        .{ .index = 70 }, // mid-buffer: the SIMD path must find it
        .{ .index = 128 }, // aligned under every width
        .{ .index = 129 }, // one past alignment
    };
    for (placements) |case| {
        var buf: [256]u8 = @splat(0);
        if (case.index) |i| buf[i] = 0xab;
        try testing.expectEqual(case.index, lastIndexOfNonZero(&buf));
    }
}

/// Whether `T` can take the vector path: integer or float elements whose bit
/// size is a power of two. Mirrors the element-type gate in
/// `mem.findScalarPos`.
fn canVectorize(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float => std.math.isPowerOfTwo(@bitSizeOf(T)),
        else => false,
    };
}

/// Return the index of the last element of `slice` equal to `value`, or null
/// if no element matches.
///
/// Semantics match `mem.findScalarLast`, which is a scalar backwards loop;
/// this function exists to add the SIMD path.
///
/// Fast path: if the last element matches, returns immediately.
/// SIMD path: compares `chunk_len` elements at a time backwards, where
/// `chunk_len` is target-optimal (suggestVectorLength).
/// Scalar path: the remaining prefix shorter than `chunk_len`, and element
/// types without vector support, delegate to `mem.findScalarLast`.
pub fn findScalarLast(comptime T: type, slice: []const T, value: T) ?usize {
    if (comptime !canVectorize(T)) return mem.findScalarLast(T, slice, value);
    if (slice.len == 0) return null;

    var i = slice.len - 1;
    if (slice[i] == value) return i;

    if (simd.suggestVectorLength(T)) |block_len| {
        const Block = @Vector(block_len, T);
        const Mask = @Int(.unsigned, block_len);

        while (i >= block_len) {
            i -= block_len;
            const chunk: Block = slice[i..][0..block_len].*;
            const matches = chunk == @as(Block, @splat(value));
            // Hand-rolled mask + clz, not `std.simd.lastTrue`: the aarch64
            // codegen evidence in `lastIndexOfNonZero` above applies here —
            // four instructions on the hit path vs lastTrue's scalarized
            // lane round-trips plus stack.
            const mask: Mask = @bitCast(matches);
            if (mask != 0) return i + block_len - 1 - @clz(mask);
        }
    }

    return mem.findScalarLast(T, slice[0..i], value);
}

test findScalarLast {
    const Case = struct { slice: []const u8, value: u8, expected: ?usize };
    const cases = [_]Case{
        .{ .slice = &.{}, .value = 0xab, .expected = null },
        // Last element matches: fast path.
        .{ .slice = &.{ 0, 0, 0, 0xab }, .value = 0xab, .expected = 3 },
        // Single element.
        .{ .slice = &.{0xab}, .value = 0xab, .expected = 0 },
        .{ .slice = &.{1}, .value = 0xab, .expected = null },
        // 3 elements — below any block_len, exercises the scalar path.
        .{ .slice = &.{ 0, 0xab, 0 }, .value = 0xab, .expected = 1 },
        // Repeated matches: the last one must win.
        .{ .slice = &.{ 0xab, 0, 0xab, 0 }, .value = 0xab, .expected = 2 },
        // First element matches, without the fast path.
        .{ .slice = &.{ 0xab, 0, 0, 0 }, .value = 0xab, .expected = 0 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, findScalarLast(u8, case.slice, case.value));
        // Differential anchor: std's scalar form must agree exactly.
        try testing.expectEqual(
            mem.findScalarLast(u8, case.slice, case.value),
            findScalarLast(u8, case.slice, case.value),
        );
    }

    // Fixed inputs with literal expectations, no derivation from the
    // implementation's chunking: 256 elements span every SIMD width the
    // function can choose (block_len is capped at 32), with leftovers that
    // force the scalar prefix. The expected index must be the same under any
    // chunking, on any target.
    const Placement = struct { index: ?usize };
    const placements = [_]Placement{
        .{ .index = 255 }, // last element: fast path
        .{ .index = null }, // absent
        .{ .index = 0 }, // scalar prefix, first element
        .{ .index = 2 }, // scalar prefix finds a low index
        .{ .index = 70 }, // mid-buffer: the SIMD path must find it
        .{ .index = 128 }, // aligned under every width
        .{ .index = 129 }, // one past alignment
    };
    for (placements) |case| {
        var buf: [256]u8 = @splat(0);
        if (case.index) |i| buf[i] = 0xab;
        try testing.expectEqual(case.index, findScalarLast(u8, &buf, 0xab));
    }

    // Multiple matches: the last one must win, even when an earlier match
    // sits in an earlier block.
    var buf: [256]u8 = @splat(0);
    buf[3] = 0xab;
    buf[70] = 0xab;
    buf[200] = 0xab;
    try testing.expectEqual(@as(?usize, 200), findScalarLast(u8, &buf, 0xab));

    // 70 elements leaves a remainder below the vector loop; index 2 lands in
    // the delegated scalar prefix on this target, and the result must be
    // index 2 under any chunking.
    var short: [70]u8 = @splat(0);
    short[2] = 0xab;
    try testing.expectEqual(@as(?usize, 2), findScalarLast(u8, &short, 0xab));

    // Element types other than u8 instantiate their own vector widths.
    const words = [_]u32{ 1, 2, 3, 2, 1 };
    try testing.expectEqual(@as(?usize, 3), findScalarLast(u32, &words, 2));
    try testing.expectEqual(@as(?usize, null), findScalarLast(u32, &words, 4));
    try testing.expectEqual(
        mem.findScalarLast(u32, &words, 2),
        findScalarLast(u32, &words, 2),
    );

    const floats = [_]f32{ 1.5, 2.5, 3.5, 2.5 };
    try testing.expectEqual(@as(?usize, 3), findScalarLast(f32, &floats, 2.5));
    try testing.expectEqual(@as(?usize, null), findScalarLast(f32, &floats, 9.5));

    // u24 has a non-power-of-two bit size, fails the vector gate, and must
    // delegate to mem.findScalarLast.
    const wide = [_]u24{ 5, 6, 7, 6, 5 };
    try testing.expectEqual(@as(?usize, 3), findScalarLast(u24, &wide, 6));
    try testing.expectEqual(@as(?usize, null), findScalarLast(u24, &wide, 9));
    try testing.expectEqual(
        mem.findScalarLast(u24, &wide, 6),
        findScalarLast(u24, &wide, 6),
    );
}

/// Return the index of the first element of `slice` equal to any element of
/// `values`, or null if none match.
///
/// Semantics match `mem.findAny`, which delegates to `findAnyPos`, a
/// nested scalar loop that is O(slice.len * values.len); this function exists
/// to add the SIMD path.
///
/// SIMD path: compares `chunk_len` elements at a time forwards against every
/// value, ORs the match masks, and returns the first set lane, where
/// `chunk_len` is target-optimal (suggestVectorLength).
/// Scalar path: the remaining suffix shorter than `chunk_len`, and element
/// types without vector support, delegate to `mem.findAny`.
pub fn findAny(comptime T: type, slice: []const T, values: []const T) ?usize {
    if (comptime !canVectorize(T)) return mem.findAny(T, slice, values);
    if (slice.len == 0 or values.len == 0) return null;

    if (simd.suggestVectorLength(T)) |block_len| {
        const Block = @Vector(block_len, T);
        const Mask = @Int(.unsigned, block_len);
        const Matches = @Vector(block_len, bool);

        var i: usize = 0;
        while (i + block_len <= slice.len) : (i += block_len) {
            const chunk: Block = slice[i..][0..block_len].*;
            var matches: Matches = @splat(false);
            for (values) |v| matches |= (chunk == @as(Block, @splat(v)));
            // Hand-rolled mask + ctz, not `std.simd.firstTrue`: firstTrue has
            // the same select/iota/reduce lowering as lastTrue, whose aarch64
            // disassembly is cited in `lastIndexOfNonZero` above.
            const mask: Mask = @bitCast(matches);
            if (mask != 0) return i + @ctz(mask);
        }

        if (mem.findAny(T, slice[i..], values)) |j| return i + j;
        return null;
    }

    return mem.findAny(T, slice, values);
}

test findAny {
    const Case = struct { slice: []const u8, values: []const u8, expected: ?usize };
    const cases = [_]Case{
        .{ .slice = &.{}, .values = &.{1}, .expected = null },
        .{ .slice = &.{1}, .values = &.{}, .expected = null },
        .{ .slice = &.{ 1, 2, 3 }, .values = &.{3}, .expected = 2 },
        .{ .slice = &.{ 1, 2, 3 }, .values = &.{ 2, 9 }, .expected = 1 },
        .{ .slice = &.{ 1, 2, 3 }, .values = &.{ 9, 8 }, .expected = null },
        .{ .slice = &.{ 1, 2, 3 }, .values = &.{ 1, 3 }, .expected = 0 },
        // A match only on a later value in the list must still be found.
        .{ .slice = &.{ 5, 6, 7 }, .values = &.{ 0, 1, 2, 3, 4, 5 }, .expected = 0 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, findAny(u8, case.slice, case.values));
        // Differential anchor: std's scalar form must agree exactly.
        try testing.expectEqual(
            mem.findAny(u8, case.slice, case.values),
            findAny(u8, case.slice, case.values),
        );
    }

    // Fixed inputs with literal expectations, no derivation from the
    // implementation's chunking: 256 elements span every SIMD width the
    // function can choose (block_len is capped at 32). The expected index must
    // be the same under any chunking, on any target.
    const Placement = struct { index: ?usize };
    const placements = [_]Placement{
        .{ .index = 0 }, // first element
        .{ .index = null }, // absent
        .{ .index = 2 },
        .{ .index = 70 }, // mid-buffer: the SIMD path must find it
        .{ .index = 128 }, // aligned under every width
        .{ .index = 129 }, // one past alignment
        .{ .index = 255 }, // last element
    };
    for (placements) |case| {
        var buf: [256]u8 = @splat(0);
        if (case.index) |i| buf[i] = 0xab;
        // Three values exercise the per-value compare and OR accumulation.
        try testing.expectEqual(case.index, findAny(u8, &buf, &.{ 0x11, 0xab, 0x22 }));
    }

    // Multiple matches: the first one must win, regardless of value order.
    var buf: [256]u8 = @splat(0);
    buf[3] = 0x11;
    buf[70] = 0xab;
    buf[200] = 0x22;
    try testing.expectEqual(@as(?usize, 3), findAny(u8, &buf, &.{ 0x22, 0xab, 0x11 }));

    // 70 elements leaves a remainder past the vector loop; index 66 lands in
    // the delegated scalar tail on this target, and the result must be 66
    // under any chunking.
    var short: [70]u8 = @splat(0);
    short[66] = 0xab;
    try testing.expectEqual(@as(?usize, 66), findAny(u8, &short, &.{0xab}));

    // Element types other than u8 instantiate their own vector widths.
    const words = [_]u32{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(?usize, 2), findAny(u32, &words, &.{ 9, 3 }));
    try testing.expectEqual(@as(?usize, null), findAny(u32, &words, &.{ 9, 8 }));
    try testing.expectEqual(
        mem.findAny(u32, &words, &.{ 9, 3 }),
        findAny(u32, &words, &.{ 9, 3 }),
    );

    const floats = [_]f32{ 1.5, 2.5, 3.5, 2.5 };
    try testing.expectEqual(@as(?usize, 1), findAny(f32, &floats, &.{ 2.5, 9.5 }));
    try testing.expectEqual(@as(?usize, null), findAny(f32, &floats, &.{ 9.5, 8.5 }));

    // u24 has a non-power-of-two bit size, fails the vector gate, and must
    // delegate to mem.findAny.
    const wide = [_]u24{ 5, 6, 7, 8 };
    try testing.expectEqual(@as(?usize, 1), findAny(u24, &wide, &.{ 9, 6 }));
    try testing.expectEqual(@as(?usize, null), findAny(u24, &wide, &.{ 9, 10 }));
    try testing.expectEqual(
        mem.findAny(u24, &wide, &.{ 9, 6 }),
        findAny(u24, &wide, &.{ 9, 6 }),
    );
}
