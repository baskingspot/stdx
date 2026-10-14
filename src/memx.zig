//! Memory extensions to `std.mem`.
//!
//! Fixed-size byte values and memory scans that std leaves to hand-rolled
//! code.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const simdx = @import("simdx.zig");

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
            std.crypto.secureZero(u8, &self.data);
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
/// `chunk_len` is target-optimal (suggestVectorLength), defaulting to 16
/// and capped at 32.
/// Scalar path: handles the remaining prefix shorter than `chunk_len`.
///
/// `buf` must be non-empty — caller is responsible for ensuring this.
pub fn lastIndexOfNonZero(buf: []const u8) ?usize {
    assert(buf.len > 0);

    var i = buf.len - 1;
    if (buf[i] != 0) return i;

    if (simdx.suggestVectorLengthMax(u8, 32)) |block_len| {
        const Block = @Vector(block_len, u8);
        // ziglint-ignore: Z006 — @Int() builtin result is a type; ziglint only
        // recognizes std.meta.Int-style calls as type constructors.
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
