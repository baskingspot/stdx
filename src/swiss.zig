//! Swiss-table hash maps: the hashbrown / Abseil / Go 1.24 lineage.
//!
//! The control-byte encoding is Abseil's, for its stated reasons: `empty`
//! is `0x80` so an empty match is a sign-style test; `deleted` is `0xFE`
//! so empty and deleted are distinguishable and both sort below
//! `sentinel`; a full byte carries the H2 fingerprint in its low 7 bits
//! with the top bit clear, so full-vs-special is one bit. H2 is the
//! hash's top 7 bits and H1 its low bits (the hashbrown/Abseil
//! direction — Go's reversal exists for its extendible-hashing
//! directory, which this design does not have).
//!
//! Probes read a group of control bytes at once and match with the
//! repo's SIMD idiom: compare against a broadcast, bitcast the bool
//! vector to an integer mask, iterate the set bits with `@ctz`.
//!
//! The table mirrors its first `group_width - 1` control bytes at the
//! end, so a probe whose group spans the array end reads the wrapped
//! bytes and the mask's lane index can be taken modulo the bucket
//! count — the hashbrown/Abseil trick (their `kWidth - 1` cloned
//! bytes). `sentinel` is reserved by the encoding but never appears
//! in a `bounded` table's control bytes.

const std = @import("std");
const testing = std.testing;

const bounded = @import("swiss/bounded.zig");
pub const Custom = bounded.Custom;
pub const Auto = bounded.Auto;
pub const String = bounded.String;

/// Top bit set, all others clear: an empty slot. Enables a sign-style
/// empty match on a group of bytes.
pub const empty = 0x80;

/// Top bit set, bit 0 clear: a tombstone. Distinguishable from `empty`
/// by one bit; both sort below `sentinel`.
pub const deleted = 0xFE;

/// `0xFF`. Reserved by the Abseil/Go encoding for whole-array bulk
/// operations; a `bounded` table never stores it — its mirrored tail
/// replicates real bytes instead.
pub const sentinel = 0xFF;

/// Group width: 16 where the target has 128-bit vectors, 8 scalar. The
/// whole family's own shape — hashbrown and Abseil run 16 on SSE2 and 8
/// elsewhere; Zig's native vector-to-mask idiom is the reason 16 works
/// on aarch64 too, where hashbrown's hand-written NEON chose 8.
pub const group_width = if (std.simd.suggestVectorLength(u8)) |width|
    @min(width, 16)
else
    8;

const Group = @Vector(group_width, u8);

/// The group mask type: one bit per lane, `@bitCast` of the compare's
/// bool vector — the repo's shipped idiom.
pub const Mask = @Int(.unsigned, group_width);

/// A full control byte: the top 7 bits of the hash in the low 7 bits,
/// top bit clear.
pub fn full(h2: u64) u8 {
    return @truncate(h2 >> 57);
}

/// The lanes holding a full byte (any H2).
pub fn matchFull(bytes: *const [group_width]u8) Mask {
    const top: Group = @splat(0x80);
    const chunk: Group = bytes.*;
    const is_full = (chunk & top) == @as(Group, @splat(0));
    return @bitCast(is_full);
}

/// The lanes holding `empty`.
pub fn matchEmpty(bytes: *const [group_width]u8) Mask {
    const chunk: Group = bytes.*;
    const is_empty = chunk == @as(Group, @splat(empty));
    return @bitCast(is_empty);
}

/// The lanes holding `deleted`.
pub fn matchDeleted(bytes: *const [group_width]u8) Mask {
    const chunk: Group = bytes.*;
    const is_deleted = chunk == @as(Group, @splat(deleted));
    return @bitCast(is_deleted);
}

/// The lanes holding an empty or deleted byte — the probe's stop
/// condition. Equivalent to "top bit set", since every special byte in
/// a table (or its mirror) has it and no full byte does.
pub fn matchEmptyOrDeleted(bytes: *const [group_width]u8) Mask {
    const top: Group = @splat(0x80);
    const chunk: Group = bytes.*;
    const is_special = (chunk & top) == top;
    return @bitCast(is_special);
}

/// The lanes holding a full byte whose H2 equals `tag` — a candidate
/// slot for a key with that fingerprint.
pub fn matchH2(bytes: *const [group_width]u8, tag: u8) Mask {
    const chunk: Group = bytes.*;
    const matches = chunk == @as(Group, @splat(tag));
    return @bitCast(matches);
}

/// The group's first set lane in `mask`, or null.
pub fn firstSet(mask: Mask) ?u6 {
    if (mask == 0) return null;
    return @intCast(@ctz(mask));
}

test {
    testing.refAllDecls(@This());

    // Group matching over crafted bytes: full tags with distinct H2,
    // an empty, a deleted, and the mirrored-wrap property.
    var bytes: [group_width]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = full(i *% 0x9E3779B97F4A7C15);

    // All full: matchFull is every lane, the others none.
    try testing.expectEqual(~@as(Mask, 0), matchFull(&bytes));
    try testing.expectEqual(@as(Mask, 0), matchEmpty(&bytes));
    try testing.expectEqual(@as(Mask, 0), matchEmptyOrDeleted(&bytes));

    // Each lane's own H2 matches exactly there, nowhere else.
    for (bytes, 0..) |tag, i| {
        const m = matchH2(&bytes, tag);
        try testing.expectEqual(@as(Mask, 1) << @intCast(i), m);
        try testing.expectEqual(i, firstSet(m).?);
    }

    // Specials in two lanes: each matcher finds its own, both found by
    // the special test, and full excludes both.
    bytes[0] = empty;
    bytes[group_width - 1] = deleted;
    try testing.expectEqual(@as(Mask, 1), matchEmpty(&bytes));
    try testing.expectEqual(@as(Mask, 1) << (group_width - 1), matchDeleted(&bytes));
    try testing.expectEqual(
        @as(Mask, 1) | (@as(Mask, 1) << (group_width - 1)),
        matchEmptyOrDeleted(&bytes),
    );
    try testing.expectEqual(
        ~@as(Mask, (1) | (@as(Mask, 1) << (group_width - 1))),
        matchFull(&bytes),
    );

    // full() takes the hash's top 7 bits and clears the top bit.
    try testing.expectEqual(@as(u8, 0x7f), full(0xFFFFFFFFFFFFFFFF));
    try testing.expectEqual(@as(u8, 0x3f), full(0x7FFFFFFFFFFFFFFF));
    try testing.expectEqual(@as(u8, 0x40), full(0x8000000000000000));

    // firstSet on zero.
    try testing.expectEqual(@as(?u6, null), firstSet(0));
}
