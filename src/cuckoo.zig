//! Fixed-capacity Cuckoo filters (Fan, Andersen, Kaminsky, and Mitzenmacher,
//! CoNEXT 2014): approximate set membership with deletion, stored in a flat
//! table of 4-slot fingerprint buckets with no allocator and SIMD-accelerated
//! bucket probes.
//!
//! Each key hashes to a nonzero fingerprint and two candidate buckets `i1` and
//! `i2 = i1 ^ delta(fp)`. Because XOR is its own inverse, a fingerprint can be
//! relocated between its two buckets without storing the original key, and
//! `remove` deletes a key's fingerprint from either bucket. When both buckets
//! are full, `add` performs up to `max_kicks` random relocations; if the table
//! is too full to settle, `add` rolls back every relocation so the filter is
//! unchanged and returns `error.FilterFull`.
//!
//! Contract: `contains` never returns false for a key that was added and not
//! removed. `remove` is only valid for keys currently present in the filter:
//! removing an absent key can delete a colliding key's fingerprint and cause a
//! false negative. Duplicate adds store duplicate fingerprints (up to 8 copies
//! across the two buckets).
//!
//! `Filter` is the hash-level primitive driven directly by uniform 64-bit
//! hashes. `Custom`, `Auto`, and `String` layer key hashing on top using the
//! `std.hash_map` split and delegate every bucket operation to `Filter`.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const Wyhash = std.hash.Wyhash;
const AutoContext = std.hash_map.AutoContext;
const StringContext = std.hash_map.StringContext;

/// Errors returned when inserting into a Cuckoo filter.
pub const Error = error{
    /// Relocation exhausted `max_kicks` without finding an empty slot. The
    /// filter state is rolled back unchanged.
    FilterFull,
};

/// Comptime sizing and fingerprint configuration for a Cuckoo filter.
// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const Config = struct {
    /// Number of 4-slot buckets; must be a power of two (`>= 1`).
    buckets: u32 = 256,
    /// Byte-aligned unsigned fingerprint type: `u8` (~3.1% max FPR), `u16`
    /// (~0.012% max FPR), or `u32` (~1.9e-9 max FPR).
    Fingerprint: type = u16,
    /// Maximum fingerprint relocations attempted before rolling back and
    /// returning `error.FilterFull`.
    max_kicks: u32 = 500,

    /// Derive a configuration sized to hold at least `capacity` items (at a
    /// <= 90% design load factor) with a full-load false-positive rate at or
    /// below `target_rate`.
    pub fn fromCapacity(
        comptime capacity: comptime_int,
        comptime target_rate: comptime_float,
    ) Config {
        comptime {
            if (capacity < 1) {
                @compileError("capacity must be at least 1");
            }
            if (!(target_rate > 0.0 and target_rate < 1.0)) {
                @compileError("target_rate must be in the open interval (0, 1)");
            }
            const Fp: type = if (target_rate >= 8.0 / 255.0)
                u8
            else if (target_rate >= 8.0 / 65535.0)
                u16
            else
                u32;

            // Size buckets so `capacity` fits at <= 90% load (4 slots/bucket).
            const min_buckets: u32 = @intFromFloat(@ceil(@as(comptime_float, capacity) / 3.6));
            return .{
                .buckets = math.ceilPowerOfTwoAssert(u32, @max(1, min_buckets)),
                .Fingerprint = Fp,
                .max_kicks = 500,
            };
        }
    }
};

/// A Cuckoo filter that hashes keys with `std.hash_map.AutoContext`.
/// Slices — including `[]const u8` — are rejected by `std.hash.autoHash`;
/// string keys use `String`.
pub fn Auto(comptime T: type, comptime config: Config) type {
    return Custom(T, AutoContext(T), config);
}

/// A Cuckoo filter for string keys (`[]const u8`), using
/// `std.hash_map.StringContext`. Key memory is managed by the caller.
pub fn String(comptime config: Config) type {
    return Custom([]const u8, StringContext, config);
}

/// A Cuckoo filter over keys of type `T`, hashing through `Context` (which must
/// provide `hash(Context, T) u64`) and delegating all bucket operations to
/// `Filter(config)`.
pub fn Custom(comptime T: type, comptime Context: type, comptime config: Config) type {
    const Raw = Filter(config);

    return struct {
        const Self = @This();

        /// Fingerprint integer type stored in each slot.
        pub const Fingerprint = Raw.Fingerprint;

        /// Number of 4-slot buckets (power of two).
        pub const bucket_count: u32 = Raw.bucket_count;

        /// Total fingerprint slots (`4 * bucket_count`).
        pub const slot_count: u64 = Raw.slot_count;

        /// Maximum relocation steps before `add` rolls back and returns `error.FilterFull`.
        pub const max_kicks: u32 = Raw.max_kicks;

        /// Worst-case false-positive rate at full load (`8 / (2^bits - 1)`).
        pub const max_false_positive_rate: f64 = Raw.max_false_positive_rate;

        /// Underlying hash-level filter.
        filter: Raw,

        /// An empty filter with no stored fingerprints.
        pub const empty: Self = .{ .filter = .empty };

        /// Add `key` to the filter. Returns `error.FilterFull` without
        /// modifying the filter if relocation cannot find a free slot.
        pub fn add(self: *Self, key: T) Error!void {
            return self.filter.addHash(Context.hash(.{}, key));
        }

        /// Whether `key` may be in the filter. Never returns false for a key
        /// that was added and not removed.
        pub fn contains(self: *const Self, key: T) bool {
            return self.filter.containsHash(Context.hash(.{}, key));
        }

        /// Remove one copy of `key`'s fingerprint. Returns `true` if a matching
        /// fingerprint was removed, `false` otherwise. Only call for keys that
        /// were previously added; removing an absent key can evict a colliding
        /// key's fingerprint.
        pub fn remove(self: *Self, key: T) bool {
            return self.filter.removeHash(Context.hash(.{}, key));
        }

        /// Number of fingerprints currently stored in the filter.
        pub fn count(self: *const Self) u64 {
            return self.filter.count();
        }

        /// Fraction of slots currently occupied (`count() / slot_count`).
        pub fn loadFactor(self: *const Self) f64 {
            return self.filter.loadFactor();
        }

        /// Remove every fingerprint and reset `count` to zero.
        pub fn clear(self: *Self) void {
            self.filter.clear();
        }
    };
}

/// The hash-level Cuckoo filter primitive: a flat array of 4-slot fingerprint
/// buckets driven directly by uniform 64-bit hashes.
pub fn Filter(comptime config: Config) type {
    comptime {
        if (config.buckets == 0 or !math.isPowerOfTwo(config.buckets)) {
            @compileError("buckets must be a power of two >= 1");
        }
        if (config.Fingerprint != u8 and config.Fingerprint != u16 and config.Fingerprint != u32) {
            @compileError("Fingerprint must be u8, u16, or u32");
        }
        if (config.max_kicks == 0) {
            @compileError("max_kicks must be at least 1");
        }
    }

    return struct {
        const Self = @This();

        /// Fingerprint integer type stored in each slot (`0` marks an empty slot).
        pub const Fingerprint = config.Fingerprint;

        /// Number of 4-slot buckets (power of two).
        pub const bucket_count: u32 = config.buckets;

        /// Total fingerprint slots (`4 * bucket_count`).
        pub const slot_count: u64 = @as(u64, bucket_count) * 4;

        /// Maximum relocation steps before `addHash` rolls back and returns `error.FilterFull`.
        pub const max_kicks: u32 = config.max_kicks;

        /// Worst-case false-positive rate at full load (`8 / (2^bits - 1)`).
        pub const max_false_positive_rate: f64 =
            8.0 / @as(f64, @floatFromInt(math.maxInt(Fingerprint)));

        const Bucket = [4]Fingerprint;
        const Vec = @Vector(4, Fingerprint);
        const Index = math.IntFittingRange(0, bucket_count - 1);
        const bucket_mask: u64 = bucket_count - 1;
        const initial_seed: u64 = 0x9e3779b97f4a7c15;

        const Kick = struct {
            index: Index,
            slot: u2,
            prev_fp: Fingerprint,
        };

        buckets: [bucket_count]Bucket,
        len: u64,
        rng_state: u64,

        /// An empty filter with no stored fingerprints.
        pub const empty: Self = .{
            .buckets = @splat(@splat(0)),
            .len = 0,
            .rng_state = initial_seed,
        };

        fn fingerprintFromHash(hash: u64) Fingerprint {
            const fp: Fingerprint = @truncate(hash >> 32);
            return if (fp == 0) 1 else fp;
        }

        fn indexFromHash(hash: u64) Index {
            return @intCast(hash & bucket_mask);
        }

        /// Involutive alternate-bucket mapping: `altIndex(altIndex(i, fp), fp) == i`.
        /// Forces a nonzero XOR delta whenever `bucket_count >= 2` so the two
        /// candidate buckets are always distinct.
        fn altIndex(index: Index, fp: Fingerprint) Index {
            if (bucket_count == 1) return 0;
            const mixed: u64 = (@as(u64, fp) *% 0x9e3779b97f4a7c15) >> 32;
            const raw: Index = @intCast(mixed & bucket_mask);
            const delta: Index = if (raw == 0) 1 else raw;
            return index ^ delta;
        }

        fn bucketHas(bucket: Bucket, fp: Fingerprint) bool {
            const vec: Vec = bucket;
            return @reduce(.Or, vec == @as(Vec, @splat(fp)));
        }

        fn bucketFind(bucket: Bucket, target: Fingerprint) ?u2 {
            const vec: Vec = bucket;
            const mask: u4 = @bitCast(vec == @as(Vec, @splat(target)));
            if (mask == 0) return null;
            return @intCast(@ctz(mask));
        }

        fn nextRand(self: *Self) u64 {
            // xorshift64*: nonzero state stays nonzero with period 2^64 - 1.
            var x = self.rng_state;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            self.rng_state = x;
            return x *% 0x2545f4914f6a1d;
        }

        /// Insert a uniform 64-bit hash into the filter. Returns
        /// `error.FilterFull` without modifying the filter if relocation
        /// exhausts `max_kicks`.
        pub fn addHash(self: *Self, hash: u64) Error!void {
            const fp = fingerprintFromHash(hash);
            const b1 = indexFromHash(hash);
            if (bucketFind(self.buckets[b1], 0)) |slot| {
                self.buckets[b1][slot] = fp;
                self.len += 1;
                return;
            }
            const b2 = altIndex(b1, fp);
            if (bucketFind(self.buckets[b2], 0)) |slot| {
                self.buckets[b2][slot] = fp;
                self.len += 1;
                return;
            }
            return self.addRelocate(b1, b2, fp);
        }

        noinline fn addRelocate(
            self: *Self,
            b1: Index,
            b2: Index,
            initial_fp: Fingerprint,
        ) Error!void {
            var idx = if ((self.nextRand() & 1) == 0) b1 else b2;
            var fp = initial_fp;
            var log: [max_kicks]Kick = undefined;

            for (0..max_kicks) |k| {
                const slot: u2 = @truncate(self.nextRand());
                const displaced = self.buckets[idx][slot];
                log[k] = .{ .index = idx, .slot = slot, .prev_fp = displaced };
                self.buckets[idx][slot] = fp;
                fp = displaced;
                idx = altIndex(idx, fp);
                if (bucketFind(self.buckets[idx], 0)) |empty_slot| {
                    self.buckets[idx][empty_slot] = fp;
                    self.len += 1;
                    return;
                }
            }

            // Roll back every relocation in reverse so failure leaves the
            // filter bit-for-bit unchanged and loses no existing fingerprint.
            var i: usize = max_kicks;
            while (i > 0) {
                i -= 1;
                const entry = log[i];
                self.buckets[entry.index][entry.slot] = entry.prev_fp;
            }
            return error.FilterFull;
        }

        /// Whether `hash` may be in the filter.
        pub fn containsHash(self: *const Self, hash: u64) bool {
            const fp = fingerprintFromHash(hash);
            const b1 = indexFromHash(hash);
            if (bucketHas(self.buckets[b1], fp)) return true;
            const b2 = altIndex(b1, fp);
            return bucketHas(self.buckets[b2], fp);
        }

        /// Remove one copy of `hash`'s fingerprint. Returns `true` if removed.
        pub fn removeHash(self: *Self, hash: u64) bool {
            const fp = fingerprintFromHash(hash);
            const b1 = indexFromHash(hash);
            if (bucketFind(self.buckets[b1], fp)) |slot| {
                self.buckets[b1][slot] = 0;
                self.len -= 1;
                return true;
            }
            const b2 = altIndex(b1, fp);
            if (bucketFind(self.buckets[b2], fp)) |slot| {
                self.buckets[b2][slot] = 0;
                self.len -= 1;
                return true;
            }
            return false;
        }

        /// Number of fingerprints currently stored in the filter.
        pub fn count(self: *const Self) u64 {
            return self.len;
        }

        /// Fraction of slots currently occupied (`count() / slot_count`).
        pub fn loadFactor(self: *const Self) f64 {
            return @as(f64, @floatFromInt(self.len)) / @as(f64, @floatFromInt(slot_count));
        }

        /// Remove every fingerprint and reset `count` to zero.
        pub fn clear(self: *Self) void {
            self.* = .empty;
        }
    };
}

test "fromCapacity sizing" {
    const cfg_u16: Config = .fromCapacity(1_000, 0.01);
    try testing.expectEqual(u16, cfg_u16.Fingerprint);
    try testing.expectEqual(@as(u32, 512), cfg_u16.buckets);

    const cfg_u8: Config = .fromCapacity(1_000, 0.05);
    try testing.expectEqual(u8, cfg_u8.Fingerprint);

    const cfg_u32: Config = .fromCapacity(1_000, 1e-6);
    try testing.expectEqual(u32, cfg_u32.Fingerprint);
}

test Filter {
    const F = Filter(.fromCapacity(2_000, 0.01));
    var filter: F = .empty;
    try testing.expectEqual(@as(u64, 0), filter.count());
    try testing.expectEqual(@as(f64, 0.0), filter.loadFactor());

    for (0..2_000) |i| {
        const h = Wyhash.hash(0, mem.asBytes(&i));
        try filter.addHash(h);
    }
    try testing.expectEqual(@as(u64, 2_000), filter.count());

    // Zero false negatives for every added key.
    for (0..2_000) |i| {
        const h = Wyhash.hash(0, mem.asBytes(&i));
        try testing.expect(filter.containsHash(h));
    }

    // Remove the first half and verify the second half remains intact.
    for (0..1_000) |i| {
        const h = Wyhash.hash(0, mem.asBytes(&i));
        try testing.expect(filter.removeHash(h));
    }
    try testing.expectEqual(@as(u64, 1_000), filter.count());

    for (1_000..2_000) |i| {
        const h = Wyhash.hash(0, mem.asBytes(&i));
        try testing.expect(filter.containsHash(h));
    }

    // False-positive rate on absent keys stays within the expected bound.
    var fps: usize = 0;
    const probes: usize = 50_000;
    for (100_000..100_000 + probes) |i| {
        const h = Wyhash.hash(0, mem.asBytes(&i));
        if (filter.containsHash(h)) fps += 1;
    }
    const observed = @as(f64, @floatFromInt(fps)) / @as(f64, @floatFromInt(probes));
    try testing.expect(observed <= 4.0 * F.max_false_positive_rate + 0.001);

    filter.clear();
    try testing.expectEqual(@as(u64, 0), filter.count());
}

test "rollback on FilterFull preserves every existing key" {
    const F = Filter(.{ .buckets = 16, .Fingerprint = u16, .max_kicks = 64 });
    var filter: F = .empty;

    var added: usize = 0;
    var saw_full = false;
    var snapshot_buckets: [F.bucket_count][4]F.Fingerprint = undefined;

    for (0..200) |i| {
        const h = Wyhash.hash(3, mem.asBytes(&i));
        snapshot_buckets = filter.buckets;
        const prev_count = filter.count();
        if (filter.addHash(h)) |_| {
            added += 1;
        } else |err| {
            try testing.expectEqual(error.FilterFull, err);
            // Rollback must leave buckets and count bit-for-bit identical.
            try testing.expectEqual(prev_count, filter.count());
            try testing.expectEqual(snapshot_buckets, filter.buckets);
            saw_full = true;
            break;
        }
    }
    try testing.expect(saw_full);
    // 16 * 4 = 64 slots; Cuckoo easily fills past 80% before hitting FilterFull.
    try testing.expect(added >= 50);

    // Every previously inserted key must still test present.
    for (0..added) |i| {
        const h = Wyhash.hash(3, mem.asBytes(&i));
        try testing.expect(filter.containsHash(h));
    }
}

test "high load factor and u8/u32 fingerprints" {
    inline for (.{ u8, u16, u32 }) |Fp| {
        const F = Filter(.{ .buckets = 256, .Fingerprint = Fp });
        var filter: F = .empty;
        // 256 * 4 = 1024 slots; 900 items is ~87.9% load.
        for (0..900) |i| {
            const h = Wyhash.hash(11, mem.asBytes(&i));
            try filter.addHash(h);
        }
        try testing.expect(filter.loadFactor() > 0.87);
        for (0..900) |i| {
            const h = Wyhash.hash(11, mem.asBytes(&i));
            try testing.expect(filter.containsHash(h));
        }
    }
}

test "Auto and String delegate identically to Filter" {
    const cfg: Config = .{ .buckets = 64, .Fingerprint = u16 };
    var typed: Auto(u64, cfg) = .empty;
    var raw: Filter(cfg) = .empty;

    for (0..150) |i| {
        const k: u64 = i;
        try typed.add(k);
        try raw.addHash(AutoContext(u64).hash(.{}, k));
    }
    try testing.expectEqual(raw.count(), typed.count());
    try testing.expectEqual(raw.buckets, typed.filter.buckets);

    var strs: String(cfg) = .empty;
    try strs.add("alpha");
    try strs.add("beta");
    try testing.expect(strs.contains("alpha"));
    try testing.expect(strs.remove("alpha"));
    try testing.expect(!strs.contains("alpha"));
    try testing.expect(strs.contains("beta"));
}
