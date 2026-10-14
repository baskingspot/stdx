//! Fixed-capacity Bloom filters: `contains` never misses an added key, and
//! it reports an absent key as present at a bounded rate. The storage is a
//! `std.StaticBitSet` embedded in the value, so a filter is a flat value
//! with no allocator, no initialization failure, and no failure mode on
//! `add`.
//!
//! Sizing is comptime metaprogramming. `Bloom` computes the optimal bit
//! count for the request, rounds it up to a power of two so probe
//! positions mask instead of reduce, derives the probe count, and
//! recomputes the false-positive rate that the rounded filter delivers.
//! The recomputed value is `actual_rate`: the request is a target,
//! `actual_rate` is the truth.
//!
//! One 64-bit hash per key drives every probe (Kirsch-Mitzenmacher): the
//! low half picks the first bit and a forced-odd stride from the high half
//! walks the rest, so a power-of-two table cannot collapse onto a subset
//! of its bits.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const StringContext = std.hash_map.StringContext;
const AutoContext = std.hash_map.AutoContext;

/// A `Bloom` that hashes keys with `std.hash_map.AutoContext`, like std's
/// `AutoHashMap`: one context, no type-dependent routing. Slices — including
/// `[]const u8` — are rejected by `std.hash.autoHash`; string keys use
/// `String`.
pub fn Auto(
    comptime T: type,
    comptime item_count: comptime_int,
    comptime target_rate: comptime_float,
) type {
    return Custom(T, AutoContext(T), item_count, target_rate);
}

/// A `Bloom` for string keys, like std's `StringHashMap`: the one context
/// that hashes `[]const u8` by content. Key memory is managed by the caller.
pub fn String(
    comptime item_count: comptime_int,
    comptime target_rate: comptime_float,
) type {
    return Custom([]const u8, StringContext, item_count, target_rate);
}

/// A Bloom filter over `T` that is sized for `item_count` distinct keys at
/// the requested false-positive rate `target_rate`.
///
/// Sizing: `bits` is the smallest power of two at or above the optimal bit
/// count for the request, `hash_functions` is the optimal probe count for
/// the unrounded count, and `actual_rate` is the false-positive rate the
/// filter delivers at `expected_items` distinct keys. The request is a
/// target: rounding `bits` up can beat it, and a tiny request can miss it.
///
/// Contract: `contains` never returns false for a key passed to `add`. An
/// absent key tests true at `actual_rate` while the filter holds
/// `expected_items` distinct keys. The rate degrades as distinct keys are
/// added. At `2 * expected_items`, each probe bit is set with probability
/// `1 - a^2` instead of `1 - a` (`a = exp(-hash_functions * expected_items
/// / bits)`), so the rate grows by about `(1 + a)^hash_functions` — near
/// 17x for the 100-item filter in the tests. The design point is not a
/// bound.
///
/// `Auto` hashes with `std.hash_map.AutoContext`, `String` with
/// `std.hash_map.StringContext` — the std `AutoHashMap`/`StringHashMap` split,
/// because `std.hash.autoHash` rejects slices: string keys are a separate
/// entry point, not silent routing.
/// does not compile.
///
/// The parameters are named `item_count` and `target_rate` rather than
/// `expected_items` and `requested_rate` because a container declaration
/// cannot shadow a parameter of the enclosing function; the requested
/// values are exposed as those constants instead.
pub fn Custom(
    comptime T: type,
    comptime Context: type,
    comptime item_count: comptime_int,
    comptime target_rate: comptime_float,
) type {
    comptime {
        if (item_count < 1) @compileError("item_count must be at least 1");
        if (!(target_rate > 0 and target_rate < 1)) {
            @compileError("target_rate must be in the open interval (0, 1)");
        }
    }

    return struct {
        const Self = @This();

        /// Number of distinct keys the filter is sized for: the
        /// `actual_rate` contract holds at this count.
        pub const expected_items: u64 = item_count;

        /// The requested false-positive rate, echoed for reference. It is
        /// a target, not a bound; `actual_rate` is the delivered rate.
        pub const requested_rate: f64 = target_rate;

        /// Optimal bit count before rounding: `ceil(-n ln p / (ln 2)^2)`.
        const optimal_bits: comptime_int = @ceil(
            -item_count * @log(target_rate) / (@log(2.0) * @log(2.0)),
        );

        /// Optimal probe count before the floor: `round((m_opt / n) ln 2)`.
        const optimal_hash_functions: comptime_int = @intFromFloat(@round(
            @as(comptime_float, optimal_bits) / @as(comptime_float, item_count) * @log(2.0),
        ));

        /// Bits of storage: the smallest power of two at or above
        /// `optimal_bits`, floored at 2. Power-of-two sizing turns the
        /// probe modulo into a mask.
        pub const bits: u64 = std.math.ceilPowerOfTwoAssert(u64, @max(optimal_bits, 2));

        /// Probes per key, floored at 1 so every key sets at least one bit.
        pub const hash_functions: u64 = @max(1, optimal_hash_functions);

        /// A probe position or the number of probes: both bounded by
        /// comptime-known sizes, so the narrowest fitting integer is the
        /// storage. The repo's `buffer.Array` convention.
        pub const Index = std.math.IntFittingRange(0, bits);
        const Probe = std.math.IntFittingRange(0, hash_functions);

        /// False-positive rate at `expected_items` distinct keys,
        /// recomputed from `bits` and `hash_functions` after the
        /// power-of-two rounding: `(1 - e^(-k n / m))^k`. This is the
        /// delivered rate; the request is only a target.
        pub const actual_rate: f64 = blk: {
            const base: f64 = 1 - @exp(
                -@as(comptime_float, hash_functions) * item_count / @as(comptime_float, bits),
            );
            var rate: f64 = 1;
            var probe: Probe = 0;
            while (probe < hash_functions) : (probe += 1) rate *= base;
            break :blk rate;
        };

        /// The hash context, provided by the caller. `Auto` picks
        /// the std default.
        const HashContext = Context;

        /// Membership bits, indexed by the masked probe positions.
        bit_set: std.StaticBitSet(bits),
        /// Number of `add` calls since the last `init` or `clear`.
        added: u64,

        /// A filter with no keys added.
        pub const empty: Self = .{ .bit_set = .empty, .added = 0 };

        /// Number of `add` calls since the last `init` or `clear`. A
        /// repeated add counts again, and adds past `expected_items` keep
        /// counting: this is a call counter, not the number of distinct
        /// keys, and not the population count of the bits.
        pub fn count(self: *const Self) u64 {
            return self.added;
        }

        /// Add `key`: set its `hash_functions` probe bits. Adding is
        /// infallible — the capacity is fixed and the bits are shared.
        pub fn add(self: *Self, key: T) void {
            const hash = hashKey(key);
            const stride: Index = @truncate((hash >> 32) | 1);
            var index: Index = @as(Index, @truncate(hash)) & index_mask;
            var probe: Probe = 0;
            while (probe < hash_functions) : (probe += 1) {
                self.bit_set.set(@intCast(index));
                index = (index +% stride) & index_mask;
            }
            self.added += 1;
        }

        /// Whether `key` was added. No false negatives: a key passed to
        /// `add` always tests true. A true result for an absent key is the
        /// documented false positive.
        pub fn contains(self: *const Self, key: T) bool {
            const hash = hashKey(key);
            const stride: Index = @truncate((hash >> 32) | 1);
            var index: Index = @as(Index, @truncate(hash)) & index_mask;
            var probe: Probe = 0;
            while (probe < hash_functions) : (probe += 1) {
                if (!self.isBitSet(index)) return false;
                index = (index +% stride) & index_mask;
            }
            return true;
        }

        /// Whether bit `index` is set. `ArrayBitSet.isSet` takes the set by
        /// value, and the compiler materializes that copy even in
        /// ReleaseFast: a 2 MiB filter then copies 2 MiB per probe (290us
        /// per `contains`, measured). Read the word the same way
        /// `ArrayBitSet.isSet` reads it. An `IntegerBitSet` fits in a
        /// register, so the std call stays for that arm.
        fn isBitSet(self: *const Self, index: Index) bool {
            if (comptime bits <= @bitSizeOf(u64)) return self.bit_set.isSet(@intCast(index));
            const word_bits: u64 = @bitSizeOf(u64);
            // masks is std's []usize — the one usize at the std boundary.
            const word = self.bit_set.masks[@intCast(index / word_bits)];
            return word & (@as(u64, 1) << @intCast(index % word_bits)) != 0;
        }

        /// Remove every key and reset `count` to zero.
        pub fn clear(self: *Self) void {
            self.bit_set = .empty;
            self.added = 0;
        }

        /// Probe indices are masked with this: `bits` is a power of two,
        /// so the modulo is a bitwise and.
        const index_mask: Index = bits - 1;

        fn hashKey(key: T) u64 {
            return HashContext.hash(.{}, key);
        }
    };
}

/// Deterministic pseudo-random keys (an LCG run at comptime). The top bit
/// is clear so `absent_keys` (top bit set) is disjoint by construction, and
/// the low 32 bits stay distinct within each table because an LCG modulo
/// 2^64 has a period of 2^32 in its low 32 bits.
const present_keys = blk: {
    @setEvalBranchQuota(500_000);
    var keys: [1000]u64 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&keys) |*key| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        key.* = state & 0x7fff_ffff_ffff_ffff;
    }
    break :blk keys;
};

const absent_keys = blk: {
    @setEvalBranchQuota(500_000);
    var keys: [30_000]u64 = undefined;
    var state: u64 = 0x9e3779b97f4a7c15;
    for (&keys) |*key| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        key.* = state | 0x8000_0000_0000_0000;
    }
    break :blk keys;
};

test Custom {
    const Filter = Auto(u64, present_keys.len, 0.01);
    var filter: Filter = .empty;
    try testing.expectEqual(@as(usize, 0), filter.count());

    // Fill to the design load, then assert no false negatives.
    for (present_keys) |key| filter.add(key);
    try testing.expectEqual(@as(usize, present_keys.len), filter.count());
    for (present_keys) |key| {
        try testing.expect(filter.contains(key));
    }
}

test "false positive rate" {
    const Filter = Auto(u64, present_keys.len, 0.01);
    var filter: Filter = .empty;
    for (present_keys) |key| filter.add(key);

    var false_positives: usize = 0;
    for (absent_keys) |key| {
        if (filter.contains(key)) false_positives += 1;
    }

    // The filter predicts ~18 positives across 30k probes; the 4x window
    // absorbs the spread and still fails a filter that always says yes.
    const observed = @as(f64, @floatFromInt(false_positives)) /
        @as(f64, @floatFromInt(absent_keys.len));
    try testing.expect(observed <= 4 * Filter.actual_rate);
}

test "comptime sizing" {
    // Auto(u64, 100, 0.01):
    //   m_opt = ceil(-100 * ln(0.01) / (ln 2)^2)
    //         = ceil(460.5170185988 / 0.4804530139) = ceil(958.5058) = 959
    //   k     = round((959 / 100) * ln 2) = round(6.6473) = 7
    //   bits  = next power of two at or above 959 = 1024
    //   actual_rate = (1 - e^(-7 * 100 / 1024))^7 = 0.0073024212
    const Filter = Auto(u64, 100, 0.01);
    try testing.expectEqual(@as(usize, 100), Filter.expected_items);
    try testing.expectEqual(@as(f64, 0.01), Filter.requested_rate);
    try testing.expectEqual(@as(usize, 1024), Filter.bits);
    try testing.expectEqual(@as(usize, 7), Filter.hash_functions);
    try testing.expectApproxEqRel(0.0073024212, Filter.actual_rate, 0.001);
    try testing.expect(Filter.actual_rate <= Filter.requested_rate * 2);
}

test "clear and reuse" {
    const Filter = Auto(u64, present_keys.len, 0.01);
    var filter: Filter = .empty;

    // count() counts calls: a duplicate add counts again.
    filter.add(present_keys[0]);
    filter.add(present_keys[0]);
    try testing.expectEqual(@as(usize, 2), filter.count());

    for (present_keys) |key| filter.add(key);
    try testing.expectEqual(@as(usize, present_keys.len + 2), filter.count());

    // A cleared filter has no bits set, so nothing tests true.
    filter.clear();
    try testing.expectEqual(@as(usize, 0), filter.count());
    for (present_keys) |key| {
        try testing.expect(!filter.contains(key));
    }

    // Reuse: the same keys are caught again after the clear.
    for (present_keys) |key| filter.add(key);
    try testing.expectEqual(@as(usize, present_keys.len), filter.count());
    for (present_keys) |key| {
        try testing.expect(filter.contains(key));
    }
}

/// A key with no unique representation, so `AutoContext` hashes it field by
/// field and the generic key path is exercised.
const Point = struct {
    x: i32,
    y: i32,
};

test "struct keys" {
    const Filter = Auto(Point, 100, 0.01);
    var filter: Filter = .empty;

    filter.add(.{ .x = 1, .y = 2 });
    filter.add(.{ .x = -3, .y = 4 });
    try testing.expect(filter.contains(.{ .x = 1, .y = 2 }));
    try testing.expect(filter.contains(.{ .x = -3, .y = 4 }));
    try testing.expectEqual(@as(usize, 2), filter.count());

    filter.clear();
    try testing.expect(!filter.contains(.{ .x = 1, .y = 2 }));
    try testing.expect(!filter.contains(.{ .x = -3, .y = 4 }));
}

test "string keys" {
    const Filter = String(100, 0.01);
    var filter: Filter = .empty;

    filter.add("one");
    filter.add("two");
    try testing.expect(filter.contains("one"));
    try testing.expect(filter.contains("two"));
    try testing.expectEqual(@as(usize, 2), filter.count());

    filter.clear();
    try testing.expect(!filter.contains("one"));
}

test "tiny filter" {
    // expected_items = 1 and target_rate = 0.5: m_opt = 2, k = 1, and
    // bits = 2 — the smallest filter the sizing produces.
    const Filter = Auto(u8, 1, 0.5);
    try testing.expectEqual(@as(usize, 2), Filter.bits);
    try testing.expectEqual(@as(usize, 1), Filter.hash_functions);
    try testing.expectApproxEqRel(0.3934693403, Filter.actual_rate, 0.001);

    var filter: Filter = .empty;
    filter.add(7);
    try testing.expect(filter.contains(7));

    filter.clear();
    try testing.expect(!filter.contains(7));
}
