//! Fixed-capacity Swiss-table hash map: the hashbrown / Abseil control-byte
//! design with the capacity fixed at comptime and the storage embedded in
//! the value, so no allocator is involved and insertion fails only with
//! `error.NoSpaceLeft`.
//!
//! The control-byte encoding, the SIMD group matchers and the mirrored tail
//! live in `swiss.zig`; this file is the bounded table over them. A bucket
//! is `hash & bucket_mask`, its entry lives at the same index in the
//! parallel key and value arrays, and a probe reads one group of control
//! bytes per step: `matchH2` screens the group's full lanes, keys are
//! compared only for the lanes that survive, and `matchEmpty` ends the walk.
//! Probe positions follow hashbrown's triangular sequence (`stride +=
//! group_width; pos += stride`), which visits every group exactly once for
//! the power-of-two bucket counts used here, so a walk is bounded by
//! `bucket_count / group_width` group reads.
//!
//! Sizing: `bucket_count` is the next power of two at or above
//! `ceil(buffer_capacity * 8 / 7)`, floored at 8, so `buffer_capacity`
//! entries always fit at no more than 7/8 load. Capacity 15 is the one case
//! where 16 buckets would exceed 7/8 load, so it takes 32 buckets.
//!
//! Removal writes `empty` when the probe's group holds any empty byte and
//! `deleted` otherwise (hashbrown's rule), so a removal never cuts a probe
//! chain short; later inserts reuse the tombstones. When a new key meets a
//! full map, the table compacts in place with Abseil's
//! DropDeletesWithoutResize before the map reports `error.NoSpaceLeft`:
//! every tombstone becomes `empty`, every entry is re-placed at the first
//! empty-or-deleted lane of its own probe path, and a landing on another
//! pending entry swaps the two and continues with the displaced entry.
//! `rebuildCount` reports how often that compaction ran.
//!
//! Iteration is in bucket order, not insertion order: entries move between
//! buckets as tombstones are reused and as the table is compacted. Contrast
//! `array_hash_map.Bounded`, which iterates in insertion order.

const std = @import("std");
const swiss = @import("../swiss.zig");
const assert = std.debug.assert;
const testing = std.testing;
const group_width = swiss.group_width;

/// A Swiss-table hash map that stores up to `buffer_capacity` key-value
/// pairs in arrays embedded in the value, indexed by the control bytes
/// described in `swiss.zig`.
///
/// `Context` follows the `std.hash_map` convention: `hash(self, K) u64` and
/// `eql(self, K, K) bool`. The hash's low bits pick the starting bucket and
/// its top 7 bits form the H2 tag; a context that hashes to a narrower
/// integer should spread it across the `u64` itself, because a hash whose
/// top 7 bits are constant makes the tag match every full lane in a group.
///
/// The parameter is named `buffer_capacity` rather than `capacity` because
/// Zig rejects a container declaration that shadows an enclosing function
/// parameter; the bound is exposed as the `capacity` constant instead.
pub fn BoundedWith(
    comptime Context: type,
    comptime K: type,
    comptime V: type,
    buffer_capacity: comptime_int,
) type {
    return struct {
        const Self = @This();

        comptime {
            if (buffer_capacity < 1) @compileError("buffer_capacity must be at least 1");
        }

        /// Smallest integer type that can hold `0..capacity`.
        pub const Index = std.math.IntFittingRange(0, buffer_capacity);

        /// Maximum number of entries the map can hold.
        pub const capacity: Index = @intCast(buffer_capacity);

        /// Number of buckets: the smallest power of two at or above
        /// `ceil(buffer_capacity * 8 / 7)`, floored at 8. Capacity 15 is the
        /// only case where 16 buckets would exceed 7/8 load, so it takes 32.
        pub const bucket_count: usize = blk: {
            if (buffer_capacity < 8) break :blk 8;
            const needed = (buffer_capacity * 8 + 6) / 7;
            break :blk @max(16, std.math.ceilPowerOfTwoAssert(usize, needed));
        };

        comptime {
            assert(bucket_count >= buffer_capacity + 1);
            assert(bucket_count * 7 / 8 >= buffer_capacity);
            assert(std.math.isPowerOfTwo(bucket_count));
        }

        const bucket_mask = bucket_count - 1;
        const hash_mask: u64 = bucket_count - 1;

        /// Pointers to a key and value stored in the map.
        pub const Entry = struct {
            key_ptr: *K,
            value_ptr: *V,
        };

        /// Result of `getOrPut`. When `found_existing` is false the key has
        /// been written into the map and the value is undefined until the
        /// caller initializes `value_ptr`.
        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };

        /// Control byte per bucket, plus a mirrored tail: `ctrl[bucket_count
        /// + j]` duplicates `ctrl[j % bucket_count]`, so a group read that
        /// runs past the last bucket reads the wrapped bytes.
        ctrl: [bucket_count + group_width - 1]u8,
        /// Key of the entry in each bucket; a bucket holds an entry only
        /// while its control byte is full.
        key_buffer: [bucket_count]K,
        /// Value of the entry in each bucket.
        value_buffer: [bucket_count]V,
        /// Number of live entries.
        used: Index,
        /// Lifetime count of in-place tombstone compactions.
        rebuilds: u32,
        context: Context,

        /// A map containing no entries. The context is undefined, as in
        /// `std.PriorityQueue.empty`; use `initContext` to set it.
        pub const empty: Self = .{
            .ctrl = @splat(swiss.empty),
            .key_buffer = undefined,
            .value_buffer = undefined,
            .used = 0,
            .rebuilds = 0,
            .context = undefined,
        };

        /// Initialize and return a map with context.
        pub fn initContext(context: Context) Self {
            return .{
                .ctrl = @splat(swiss.empty),
                .key_buffer = undefined,
                .value_buffer = undefined,
                .used = 0,
                .rebuilds = 0,
                .context = context,
            };
        }

        /// Initialize and return a map with a default-initialized context.
        /// Convenience for stateless contexts such as
        /// `std.hash_map.AutoContext` and `std.hash_map.StringContext`;
        /// contexts that carry state must use `initContext`.
        pub fn init() Self {
            return initContext(.{});
        }

        /// Number of entries currently stored.
        pub fn count(self: *const Self) Index {
            return self.used;
        }

        /// Number of in-place tombstone compactions this map has run over
        /// its lifetime; `clear` does not reset it.
        pub fn rebuildCount(self: *const Self) u32 {
            return self.rebuilds;
        }

        /// Write `byte` to the control byte of `slot` and to every mirrored
        /// copy of that byte in the tail.
        fn setCtrl(self: *Self, slot: usize, byte: u8) void {
            self.ctrl[slot] = byte;
            var mirror = slot + bucket_count;
            while (mirror < self.ctrl.len) : (mirror += bucket_count) self.ctrl[mirror] = byte;
        }

        /// The probe walk shared by lookup, insert and remove. `found` is
        /// the bucket holding `key`; `insert` and `deleted` are the first
        /// empty and the first tombstone on the key's path, recorded only
        /// while the key was not found.
        const Probe = struct {
            hash: u64,
            found: ?usize = null,
            insert: ?usize = null,
            deleted: ?usize = null,
        };

        fn probe(self: *const Self, key: K) Probe {
            const hash: u64 = self.context.hash(key);
            const tag = swiss.full(hash);
            var result: Probe = .{ .hash = hash };
            var pos: usize = @intCast(hash & hash_mask);
            var stride: usize = 0;
            var groups_left: usize = @max(1, bucket_count / group_width);
            while (groups_left > 0) : (groups_left -= 1) {
                const bytes: *const [group_width]u8 = self.ctrl[pos..][0..group_width];
                var matches = swiss.matchH2(bytes, tag);
                while (swiss.firstSet(matches)) |lane| {
                    matches &= matches - 1;
                    const slot = (pos + lane) & bucket_mask;
                    if (self.context.eql(key, self.key_buffer[slot])) {
                        return .{ .hash = hash, .found = slot };
                    }
                }
                if (result.deleted == null) {
                    if (swiss.firstSet(swiss.matchDeleted(bytes))) |lane| {
                        result.deleted = (pos + lane) & bucket_mask;
                    }
                }
                if (swiss.firstSet(swiss.matchEmpty(bytes))) |lane| {
                    result.insert = (pos + lane) & bucket_mask;
                    return result;
                }
                stride += group_width;
                pos = (pos + stride) & bucket_mask;
            }
            return result;
        }

        /// The first empty-or-deleted lane on the probe path for `hash`,
        /// the landing target the compaction uses. A pending entry always
        /// exists while the compaction runs, so the walk always finds one.
        fn findLanding(self: *const Self, hash: u64) usize {
            var pos: usize = @intCast(hash & hash_mask);
            var stride: usize = 0;
            var groups_left: usize = @max(1, bucket_count / group_width);
            while (groups_left > 0) : (groups_left -= 1) {
                const bytes: *const [group_width]u8 = self.ctrl[pos..][0..group_width];
                if (swiss.firstSet(swiss.matchEmptyOrDeleted(bytes))) |lane| {
                    return (pos + lane) & bucket_mask;
                }
                stride += group_width;
                pos = (pos + stride) & bucket_mask;
            }
            unreachable;
        }

        /// Store `key` in `slot`, whose control byte is empty or deleted,
        /// and return its storage. The value is left undefined.
        fn insertAt(self: *Self, slot: usize, key: K, hash: u64) GetOrPutResult {
            assert(self.used < capacity);
            self.key_buffer[slot] = key;
            self.setCtrl(slot, swiss.full(hash));
            self.used += 1;
            return .{
                .key_ptr = &self.key_buffer[slot],
                .value_ptr = &self.value_buffer[slot],
                .found_existing = false,
            };
        }

        /// Value stored for `key`, or null.
        pub fn get(self: *const Self, key: K) ?V {
            const slot = self.probe(key).found orelse return null;
            return self.value_buffer[slot];
        }

        /// Pointer to the value stored for `key`, or null. The pointer is
        /// invalidated by the next insertion, removal or compaction.
        pub fn getPtr(self: *Self, key: K) ?*V {
            const slot = self.probe(key).found orelse return null;
            return &self.value_buffer[slot];
        }

        /// Whether `key` is stored in the map.
        pub fn contains(self: *const Self, key: K) bool {
            return self.probe(key).found != null;
        }

        /// Insert or overwrite `key`. Returns `error.NoSpaceLeft` when the
        /// map is full and `key` is new.
        pub fn put(self: *Self, key: K, value: V) error{NoSpaceLeft}!void {
            const result = try self.getOrPut(key);
            result.value_ptr.* = value;
        }

        /// Find or insert `key`. On a full map an existing key is still
        /// found; a new key compacts the table in place and returns
        /// `error.NoSpaceLeft`. A new entry's value is undefined until the
        /// caller initializes `value_ptr`.
        pub fn getOrPut(self: *Self, key: K) error{NoSpaceLeft}!GetOrPutResult {
            const first = self.probe(key);
            if (first.found) |slot| {
                return .{
                    .key_ptr = &self.key_buffer[slot],
                    .value_ptr = &self.value_buffer[slot],
                    .found_existing = true,
                };
            }
            if (self.used == capacity) {
                // No room for a new entry: compact the tombstones in place
                // (Abseil's drop-deletes at growth_left == 0) so the table
                // stays probe-friendly across full/empty cycles, then report
                // the bound. The retry cannot change the outcome: the
                // compaction does not change `used`.
                self.rebuild();
                return error.NoSpaceLeft;
            }
            const slot = first.deleted orelse first.insert orelse blk: {
                // No landing slot on the probe path. Unreachable while
                // used < capacity < bucket_count, because a probe walks
                // every bucket and at least one bucket is not full; kept as
                // the specified fallback.
                self.rebuild();
                const retry = self.probe(key);
                break :blk retry.deleted orelse retry.insert orelse return error.NoSpaceLeft;
            };
            return self.insertAt(slot, key, first.hash);
        }

        /// Remove `key`. Returns false when `key` is absent.
        pub fn remove(self: *Self, key: K) bool {
            const result = self.probe(key);
            const slot = result.found orelse return false;
            // Always a tombstone — Abseil's rule. Writing `empty` here could
            // break another key's probe: groups align to each probe's own
            // position, so the finding probe's group having an empty says
            // nothing about every other window covering this slot. The
            // compaction reclaims tombstones; nothing else needs to.
            self.setCtrl(slot, swiss.deleted);
            self.used -= 1;
            return true;
        }

        /// Remove all entries, keeping the storage. Every control byte,
        /// mirrored tail included, becomes `empty`.
        pub fn clear(self: *Self) void {
            @memset(&self.ctrl, swiss.empty);
            self.used = 0;
        }

        /// Abseil's DropDeletesWithoutResize, in place. Pass 1 re-tags every
        /// tombstone `empty` and every full bucket `deleted`, leaving the
        /// entries where they are; the slots tagged `deleted` are the
        /// pending entries. Pass 2 walks the buckets and places each
        /// pending entry at the first empty-or-deleted lane of its own
        /// probe path. A landing on another pending entry swaps the two and
        /// continues with the displaced entry, so the only empty pass 2
        /// creates is the one a finished walker just left: every placed
        /// entry sits on a path that passes no empty.
        fn rebuild(self: *Self) void {
            var slot: usize = 0;
            while (slot < bucket_count) : (slot += 1) {
                const byte = self.ctrl[slot];
                if (byte == swiss.deleted) {
                    self.setCtrl(slot, swiss.empty);
                } else if (byte != swiss.empty) {
                    self.setCtrl(slot, swiss.deleted);
                }
            }
            slot = 0;
            while (slot < bucket_count) : (slot += 1) {
                // A `deleted` byte here is a pending entry: pass 1 produced
                // every one of them, and this walk leaves each bucket full
                // or empty.
                while (self.ctrl[slot] == swiss.deleted) {
                    const hash: u64 = self.context.hash(self.key_buffer[slot]);
                    const target = self.findLanding(hash);
                    if (target == slot) {
                        // The walker's own bucket is the landing spot.
                        self.setCtrl(slot, swiss.full(hash));
                    } else if (self.ctrl[target] == swiss.empty) {
                        self.key_buffer[target] = self.key_buffer[slot];
                        self.value_buffer[target] = self.value_buffer[slot];
                        self.setCtrl(target, swiss.full(hash));
                        self.setCtrl(slot, swiss.empty);
                    } else {
                        // Another pending entry: swap the two and repeat
                        // from this bucket with the displaced entry's hash.
                        std.mem.swap(K, &self.key_buffer[slot], &self.key_buffer[target]);
                        std.mem.swap(V, &self.value_buffer[slot], &self.value_buffer[target]);
                        self.setCtrl(target, swiss.full(hash));
                    }
                }
            }
            self.rebuilds +%= 1;
        }

        /// Advance `slot` to the next bucket holding an entry, or return
        /// null when the buckets are exhausted. A bucket holds an entry
        /// exactly when its control byte is full, and the encoding makes
        /// that a less-than-empty test.
        fn nextFullSlot(self: *const Self, slot: *usize) ?usize {
            while (slot.* < bucket_count) {
                const candidate = slot.*;
                slot.* += 1;
                if (self.ctrl[candidate] < swiss.empty) return candidate;
            }
            return null;
        }

        pub const Iterator = struct {
            map: *Self,
            slot: usize,

            /// The next entry in bucket order, or null.
            pub fn next(it: *Iterator) ?Entry {
                const slot = it.map.nextFullSlot(&it.slot) orelse return null;
                return .{
                    .key_ptr = &it.map.key_buffer[slot],
                    .value_ptr = &it.map.value_buffer[slot],
                };
            }

            /// Reset the iterator to the first bucket.
            pub fn reset(it: *Iterator) void {
                it.slot = 0;
            }
        };

        /// An iterator over the entries in bucket order. The entry pointers
        /// alias the map's storage; the iterator is invalidated by the next
        /// insertion, removal or compaction.
        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self, .slot = 0 };
        }

        pub const KeyIterator = struct {
            map: *Self,
            slot: usize,

            /// The next key in bucket order, or null.
            pub fn next(it: *KeyIterator) ?*K {
                const slot = it.map.nextFullSlot(&it.slot) orelse return null;
                return &it.map.key_buffer[slot];
            }

            /// Reset the iterator to the first bucket.
            pub fn reset(it: *KeyIterator) void {
                it.slot = 0;
            }
        };

        /// An iterator over the keys in bucket order. The pointers alias
        /// the map's storage; the iterator is invalidated by the next
        /// insertion, removal or compaction.
        pub fn keys(self: *Self) KeyIterator {
            return .{ .map = self, .slot = 0 };
        }

        pub const ValueIterator = struct {
            map: *Self,
            slot: usize,

            /// The next value in bucket order, or null.
            pub fn next(it: *ValueIterator) ?*V {
                const slot = it.map.nextFullSlot(&it.slot) orelse return null;
                return &it.map.value_buffer[slot];
            }

            /// Reset the iterator to the first bucket.
            pub fn reset(it: *ValueIterator) void {
                it.slot = 0;
            }
        };

        /// An iterator over the values in bucket order, matching `keys()`
        /// step for step. The pointers alias the map's storage; the
        /// iterator is invalidated by the next insertion, removal or
        /// compaction.
        pub fn values(self: *Self) ValueIterator {
            return .{ .map = self, .slot = 0 };
        }
    };
}

/// A `BoundedWith` that hashes keys with std's default context.
///
/// Plain auto-hashable key types need no context argument. `[]const u8` keys
/// route to `std.hash_map.StringContext`, which hashes string contents
/// (std's `StringHashMap` choice): `std.hash_map.AutoContext` rejects slices
/// outright, so it cannot be the default for strings. Other key types use
/// `std.hash_map.AutoContext(K)`; slices inside a key type, or any type
/// `std.hash.autoHash` refuses, still need an explicit context through
/// `BoundedWith`.
pub fn Bounded(
    comptime K: type,
    comptime V: type,
    buffer_capacity: comptime_int,
) type {
    return BoundedWith(
        if (K == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(K),
        K,
        V,
        buffer_capacity,
    );
}

// --- Tests ---

test "empty" {
    // `empty`'s context is undefined, which is harmless for the zero-sized
    // auto contexts; `init` is the same value with the context defaulted.
    var map: Bounded(u32, u32, 4) = .empty;
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));
    try map.put(1, 10);
    try testing.expectEqual(@as(?u32, 10), map.get(1));

    var initialized = Bounded(u32, u32, 4).init();
    try initialized.put(2, 20);
    try testing.expectEqual(@as(?u32, 20), initialized.get(2));
    try testing.expectEqual(@as(usize, 1), @as(usize, initialized.count()));
}

test "put" {
    var map = Bounded(u32, u32, 4).initContext(.{});

    try map.put(3, 30);
    try map.put(1, 10);
    try map.put(2, 20);
    try testing.expectEqual(@as(usize, 3), @as(usize, map.count()));

    // An overwrite replaces the value in place and does not consume room.
    try map.put(1, 11);
    try testing.expectEqual(@as(?u32, 11), map.get(1));
    try testing.expectEqual(@as(usize, 3), @as(usize, map.count()));

    // Full map: a new key fails, an existing key still overwrites.
    try map.put(4, 40);
    try testing.expectError(error.NoSpaceLeft, map.put(5, 50));
    try map.put(3, 33);
    try testing.expectEqual(@as(?u32, 33), map.get(3));
    try testing.expectEqual(@as(?u32, null), map.get(5));
    try testing.expectEqual(@as(usize, 4), @as(usize, map.count()));

    // A removal frees room for a new key.
    try testing.expect(map.remove(3));
    try map.put(5, 50);
    try testing.expectEqual(@as(?u32, 50), map.get(5));
    try testing.expectEqual(@as(?u32, null), map.get(3));
    try testing.expectEqual(@as(usize, 4), @as(usize, map.count()));
}

test "get" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expect(!map.contains(1));
    try testing.expect(map.getPtr(1) == null);

    try map.put(1, 10);
    try testing.expectEqual(@as(?u32, 10), map.get(1));
    try testing.expect(map.contains(1));
    try testing.expectEqual(@as(u32, 10), map.getPtr(1).?.*);

    // getPtr aliases storage: writes are visible through get.
    map.getPtr(1).?.* = 11;
    try testing.expectEqual(@as(?u32, 11), map.get(1));

    try testing.expectEqual(@as(?u32, null), map.get(2));
    try testing.expect(!map.contains(2));
    try testing.expect(map.getPtr(2) == null);
}

test "remove" {
    var map = Bounded(u32, u32, 8).initContext(.{});

    // Missing key: false, map untouched.
    try testing.expect(!map.remove(9));
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    try testing.expect(map.remove(2));
    try testing.expect(!map.contains(2));
    try testing.expectEqual(@as(?u32, null), map.get(2));
    try testing.expectEqual(@as(usize, 2), @as(usize, map.count()));
    try testing.expect(!map.remove(2));

    // The survivors are still reachable and the room is reusable.
    try testing.expectEqual(@as(?u32, 10), map.get(1));
    try testing.expectEqual(@as(?u32, 30), map.get(3));
    try map.put(4, 40);
    try testing.expectEqual(@as(?u32, 40), map.get(4));

    // Empty it out and reuse it from scratch.
    try testing.expect(map.remove(1));
    try testing.expect(map.remove(3));
    try testing.expect(map.remove(4));
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));
    try map.put(5, 50);
    try testing.expectEqual(@as(?u32, 50), map.get(5));
    try testing.expect(!map.contains(1));
}

test "getOrPut" {
    var map = Bounded(u32, u32, 4).initContext(.{});

    const first = try map.getOrPut(7);
    try testing.expect(!first.found_existing);
    try testing.expectEqual(@as(u32, 7), first.key_ptr.*);
    first.value_ptr.* = 70;
    try testing.expectEqual(@as(?u32, 70), map.get(7));

    const second = try map.getOrPut(7);
    try testing.expect(second.found_existing);
    try testing.expectEqual(@as(u32, 70), second.value_ptr.*);
    second.value_ptr.* = 71;
    try testing.expectEqual(@as(?u32, 71), map.get(7));
    try testing.expectEqual(@as(usize, 1), @as(usize, map.count()));

    // Full map: an existing key is found, a new key is NoSpaceLeft.
    try map.put(1, 1);
    try map.put(2, 2);
    try map.put(3, 3);
    const existing = try map.getOrPut(2);
    try testing.expect(existing.found_existing);
    try testing.expectEqual(@as(u32, 2), existing.value_ptr.*);
    try testing.expectError(error.NoSpaceLeft, map.getOrPut(9));
    try testing.expectEqual(@as(usize, 4), @as(usize, map.count()));
}

test "clear" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try map.put(1, 10);
    try map.put(2, 20);

    map.clear();
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expectEqual(@as(?u32, null), map.get(2));
    var iterator = map.iterator();
    try testing.expect(iterator.next() == null);
    for (map.ctrl) |byte| try testing.expectEqual(swiss.empty, byte);

    // The map is reusable at full capacity, with no stale entries.
    for (0..4) |i| try map.put(@intCast(i), @intCast(i * 10));
    for (0..4) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
    try testing.expectError(error.NoSpaceLeft, map.put(4, 40));
    try testing.expectEqual(@as(?u32, null), map.get(4));

    map.clear();
    try testing.expectEqual(@as(?u32, null), map.get(0));
    try map.put(9, 90);
    try testing.expectEqual(@as(?u32, 90), map.get(9));
}

test "iterator" {
    var map = Bounded(u32, u32, 8).initContext(.{});
    const Map = @TypeOf(map);

    // Empty map: next() is null immediately.
    var empty_iterator = map.iterator();
    try testing.expect(empty_iterator.next() == null);

    try map.put(4, 40);
    try map.put(2, 20);
    try map.put(7, 70);

    // Iteration is in bucket order: exactly the buckets whose control byte
    // is full, in increasing bucket index. Insertion order (4, 2, 7) is
    // deliberately not what the iterator promises.
    var expected_keys: [8]u32 = undefined;
    var expected_values: [8]u32 = undefined;
    var expected_len: usize = 0;
    for (0..Map.bucket_count) |slot| {
        if (map.ctrl[slot] < swiss.empty) {
            expected_keys[expected_len] = map.key_buffer[slot];
            expected_values[expected_len] = map.value_buffer[slot];
            expected_len += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), expected_len);

    var iterator = map.iterator();
    var n: usize = 0;
    while (iterator.next()) |entry| : (n += 1) {
        try testing.expectEqual(expected_keys[n], entry.key_ptr.*);
        try testing.expectEqual(expected_values[n], entry.value_ptr.*);
    }
    try testing.expectEqual(expected_len, n);
    try testing.expect(iterator.next() == null);

    // reset() rewinds to the first bucket.
    iterator.reset();
    try testing.expectEqual(expected_keys[0], iterator.next().?.key_ptr.*);

    // The iterator observes overwrites, removals and insertions.
    try map.put(2, 22);
    try testing.expect(map.remove(4));
    try map.put(9, 90);
    var after_keys: [8]u32 = undefined;
    var after_values: [8]u32 = undefined;
    var after_len: usize = 0;
    for (0..Map.bucket_count) |slot| {
        if (map.ctrl[slot] < swiss.empty) {
            after_keys[after_len] = map.key_buffer[slot];
            after_values[after_len] = map.value_buffer[slot];
            after_len += 1;
        }
    }
    iterator.reset();
    n = 0;
    while (iterator.next()) |entry| : (n += 1) {
        try testing.expectEqual(after_keys[n], entry.key_ptr.*);
        try testing.expectEqual(after_values[n], entry.value_ptr.*);
    }
    try testing.expectEqual(after_len, n);
}

test "keys and values" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try map.put(2, 20);
    try map.put(1, 10);

    // keys() and values() walk the same buckets in the same order.
    var key_iterator = map.keys();
    var value_iterator = map.values();
    var n: usize = 0;
    while (key_iterator.next()) |key_ptr| : (n += 1) {
        const value_ptr = value_iterator.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(map.get(key_ptr.*).?, value_ptr.*);
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(value_iterator.next() == null);

    // Both agree with iterator(), pointer for pointer.
    key_iterator.reset();
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        const key_ptr = key_iterator.next() orelse return error.TestUnexpectedResult;
        try testing.expect(entry.key_ptr == key_ptr);
    }
    try testing.expect(key_iterator.next() == null);

    // The pointers alias the map's storage.
    var values = map.values();
    while (values.next()) |value_ptr| value_ptr.* += 1000;
    try testing.expectEqual(@as(?u32, 1010), map.get(1));
    try testing.expectEqual(@as(?u32, 1020), map.get(2));

    // reset() rewinds to the first bucket, and the walk repeats.
    values.reset();
    var repeat = map.values();
    while (repeat.next()) |value_ptr| {
        try testing.expectEqual(value_ptr.*, values.next().?.*);
    }
    try testing.expect(values.next() == null);
}

test "capacity boundaries" {
    inline for ([_]comptime_int{ 1, 2, 7, 8, 15, 16, 17 }) |n| {
        const Map = Bounded(u32, u32, n);
        var map = Map.initContext(.{});
        try testing.expect(Map.Index == std.math.IntFittingRange(0, n));
        try testing.expectEqual(@as(usize, n), @as(usize, Map.capacity));
        try testing.expect(Map.bucket_count >= n + 1);
        try testing.expect(Map.bucket_count * 7 / 8 >= n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            try map.put(@intCast(i), @intCast(i));
            try testing.expectEqual(i + 1, @as(usize, map.count()));
        }
        try testing.expectError(error.NoSpaceLeft, map.put(@intCast(n), 0));

        // Overwrite at capacity still works; remove-then-put reuses the room.
        try map.put(0, 99);
        try testing.expectEqual(@as(?u32, 99), map.get(0));
        try testing.expect(map.remove(0));
        try map.put(@intCast(n), @intCast(n));
        try testing.expectEqual(@as(?u32, @intCast(n)), map.get(@intCast(n)));
        try testing.expectEqual(@as(usize, n), @as(usize, map.count()));

        // Every entry is still reachable.
        i = 1;
        while (i < n) : (i += 1) {
            try testing.expectEqual(@as(?u32, @intCast(i)), map.get(@intCast(i)));
        }
    }
}

test "V = void" {
    var set = Bounded(u32, void, 4).initContext(.{});
    try set.put(2, {});
    try set.put(1, {});
    try set.put(3, {});

    try testing.expect(set.contains(1));
    try testing.expect(set.contains(2));
    try testing.expect(!set.contains(9));
    try testing.expectEqual(@as(usize, 3), @as(usize, set.count()));

    const result = try set.getOrPut(4);
    try testing.expect(!result.found_existing);
    result.value_ptr.* = {};
    try testing.expect(set.contains(4));
    try testing.expectError(error.NoSpaceLeft, set.getOrPut(5));

    // void values still iterate.
    var iterator = set.iterator();
    var n: usize = 0;
    while (iterator.next()) |entry| : (n += 1) {
        _ = entry.value_ptr.*;
    }
    try testing.expectEqual(@as(usize, 4), n);

    try testing.expect(set.remove(1));
    try testing.expect(!set.contains(1));
    try testing.expectEqual(@as(usize, 3), @as(usize, set.count()));
}

test "auto keys" {
    // Integer keys through std.hash_map.AutoContext.
    var integers = Bounded(u16, u32, 4).initContext(.{});
    try integers.put(3, 30);
    try integers.put(1, 10);
    try integers.put(3, 33);
    try testing.expectEqual(@as(?u32, 33), integers.get(3));
    try testing.expectEqual(@as(?u32, 10), integers.get(1));
    try testing.expectEqual(@as(?u32, null), integers.get(2));

    // []const u8 keys route to std.hash_map.StringContext because
    // std.hash_map.AutoContext rejects slices.
    var strings = Bounded([]const u8, u32, 4).initContext(.{});
    try strings.put("one", 1);
    try strings.put("two", 2);
    try strings.put("one", 11);
    try testing.expectEqual(@as(?u32, 11), strings.get("one"));
    try testing.expectEqual(@as(?u32, 2), strings.get("two"));
    try testing.expectEqual(@as(?u32, null), strings.get("three"));
    try testing.expectEqual(@as(usize, 2), @as(usize, strings.count()));
    try testing.expect(strings.remove("one"));
    try testing.expectEqual(@as(usize, 1), @as(usize, strings.count()));
    try testing.expect(strings.contains("two"));
}

/// A stateful context in the `std.hash_map` shape: the salt moves keys
/// between buckets, so the map's behavior depends on the stored context.
const SaltContext = struct {
    salt: u64,

    pub fn hash(self: SaltContext, key: u32) u64 {
        return (@as(u64, key) *% 0x9e3779b97f4a7c15) ^ self.salt;
    }

    pub fn eql(self: SaltContext, a: u32, b: u32) bool {
        _ = self;
        return a == b;
    }
};

const Point = struct {
    x: i32,
    y: i32,
};

/// A struct key with a context of its own, exercising the `K` axis. The
/// methods are file-private because the key type is private; contexts used
/// outside this file need `pub` methods.
const PointContext = struct {
    fn hash(self: PointContext, point: Point) u64 {
        _ = self;
        return @bitCast((@as(i64, point.x) << 32) ^ @as(i64, point.y));
    }

    fn eql(self: PointContext, a: Point, b: Point) bool {
        _ = self;
        return a.x == b.x and a.y == b.y;
    }
};

test "custom context" {
    var salted = BoundedWith(SaltContext, u32, u32, 4).initContext(.{ .salt = 0x1234 });
    try salted.put(1, 10);
    try salted.put(2, 20);
    try testing.expectEqual(@as(?u32, 10), salted.get(1));
    try testing.expectEqual(@as(?u32, 20), salted.get(2));
    try testing.expect(salted.remove(1));
    try testing.expectEqual(@as(?u32, null), salted.get(1));
    try testing.expectEqual(@as(?u32, 20), salted.get(2));

    // The same key in a map with a different salt still works; the context
    // decides placement, not the map.
    var other = BoundedWith(SaltContext, u32, u32, 4).initContext(.{ .salt = 0x5678 });
    try other.put(1, 10);
    try other.put(2, 20);
    try testing.expectEqual(@as(?u32, 10), other.get(1));
    try testing.expectEqual(@as(?u32, 20), other.get(2));

    var points = BoundedWith(PointContext, Point, u32, 4).initContext(.{});
    try points.put(.{ .x = 1, .y = 2 }, 12);
    try points.put(.{ .x = 2, .y = 1 }, 21);
    try points.put(.{ .x = 1, .y = 2 }, 99);
    try testing.expectEqual(@as(?u32, 99), points.get(.{ .x = 1, .y = 2 }));
    try testing.expectEqual(@as(?u32, 21), points.get(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, null), points.get(.{ .x = 3, .y = 3 }));
    try testing.expectEqual(@as(usize, 2), @as(usize, points.count()));
    try testing.expect(points.remove(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, null), points.get(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, 99), points.get(.{ .x = 1, .y = 2 }));
}

/// A context whose hash maps every key into one of three buckets, so probes
/// run long collision chains instead of the sparse case.
const NarrowHashContext = struct {
    pub fn hash(self: NarrowHashContext, key: u16) u64 {
        _ = self;
        return key % 3;
    }

    pub fn eql(self: NarrowHashContext, a: u16, b: u16) bool {
        _ = self;
        return a == b;
    }
};

/// A context that puts a key's low bits into H1 and its high bits into H2
/// (`key | key << 57`), so tests can predict which bucket a key lands in
/// without giving up H2 screening. Valid for keys below `1 << 57`.
const IdentityHashContext = struct {
    pub fn hash(self: IdentityHashContext, key: u32) u64 {
        _ = self;
        return key | (@as(u64, key) << 57);
    }

    pub fn eql(self: IdentityHashContext, a: u32, b: u32) bool {
        _ = self;
        return a == b;
    }
};

test "collision-heavy small map" {
    // 8 entries in 16 buckets, with every key starting in one of three
    // buckets: the probe chains and tombstone reuse both get exercised.
    const Map = BoundedWith(NarrowHashContext, u16, u32, 8);
    var map = Map.initContext(.{});

    for (0..8) |i| try map.put(@intCast(i), @intCast(i * 10));
    try testing.expectError(error.NoSpaceLeft, map.put(100, 0));

    for (0..8) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
    try testing.expectEqual(@as(?u32, null), map.get(100));

    // Remove half, refill, verify.
    for (0..4) |i| try testing.expect(map.remove(@intCast(i * 2)));
    for (0..4) |i| try map.put(@intCast(200 + i), @intCast(2000 + i));
    for (0..4) |i| {
        try testing.expectEqual(@as(?u32, null), map.get(@intCast(i * 2)));
        try testing.expectEqual(@as(?u32, @intCast(i * 2 * 10 + 10)), map.get(@intCast(i * 2 + 1)));
        try testing.expectEqual(@as(?u32, @intCast(2000 + i)), map.get(@intCast(200 + i)));
    }
    try testing.expectEqual(@as(usize, 8), @as(usize, map.count()));
}

test "tombstone reuse" {
    // 28 entries in 32 buckets, and H1 is the key: keys 0..27 land in
    // buckets 0..27, so bucket group 0..15 is completely full while
    // buckets 28..31 stay empty.
    const Map = BoundedWith(IdentityHashContext, u32, u32, 28);
    var map = Map.initContext(.{});
    for (0..28) |i| try map.put(@intCast(i), @intCast(i * 10));

    // Key 5 probes the full group 5..20: no empty byte, so the removal must
    // leave a tombstone rather than an empty.
    try testing.expect(map.remove(5));
    try testing.expectEqual(swiss.deleted, map.ctrl[5]);
    try testing.expect(map.remove(6));
    try testing.expectEqual(swiss.deleted, map.ctrl[6]);
    try testing.expectEqual(@as(usize, 26), @as(usize, map.count()));

    // Key 32 hashes to bucket 0; its probe meets the tombstone at bucket 5
    // before any empty byte and reuses it, with no compaction needed. Key
    // 33 then takes the tombstone at bucket 6.
    try map.put(32, 320);
    try testing.expectEqual(swiss.full(IdentityHashContext.hash(.{}, 32)), map.ctrl[5]);
    try map.put(33, 330);
    try testing.expectEqual(swiss.full(IdentityHashContext.hash(.{}, 33)), map.ctrl[6]);
    try testing.expectEqual(@as(u32, 0), map.rebuildCount());

    // Inserts kept succeeding while used < capacity; now the map is full.
    try testing.expectEqual(@as(usize, 28), @as(usize, map.count()));
    try testing.expectError(error.NoSpaceLeft, map.put(34, 340));

    // Every surviving and reused entry is correct by key.
    for (0..28) |i| {
        if (i == 5 or i == 6) {
            try testing.expectEqual(@as(?u32, null), map.get(@intCast(i)));
        } else {
            try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
        }
    }
    try testing.expectEqual(@as(?u32, 320), map.get(32));
    try testing.expectEqual(@as(?u32, 330), map.get(33));
}

test "mirror invariant" {
    const Map = BoundedWith(IdentityHashContext, u32, u32, 28);
    var map = Map.initContext(.{});
    for (0..28) |i| try map.put(@intCast(i), @intCast(i));
    for (0..10) |i| try testing.expect(map.remove(@intCast(i * 3)));
    try map.put(100, 100);
    try map.put(101, 101);
    try map.put(102, 102);

    // Every group read at every bucket offset reads the wrapped bytes:
    // ctrl[pos + lane] is the control byte of bucket (pos + lane) % count.
    for (0..Map.bucket_count) |pos| {
        for (0..group_width) |lane| {
            try testing.expectEqual(
                map.ctrl[(pos + lane) % Map.bucket_count],
                map.ctrl[pos + lane],
            );
        }
    }

    // In the common case the tail is a plain copy of the first
    // group_width - 1 buckets.
    for (0..group_width - 1) |i| {
        try testing.expectEqual(map.ctrl[i], map.ctrl[Map.bucket_count + i]);
    }
}

test "remove every other and refill" {
    // 112 entries in 128 buckets: dense enough that removals and refills
    // exercise tombstone reuse.
    const Map = Bounded(u16, u32, 112);
    var map = Map.initContext(.{});

    for (0..112) |i| try map.put(@intCast(i), @intCast(i * 10));
    try testing.expectError(error.NoSpaceLeft, map.put(1000, 1));
    try testing.expectEqual(@as(usize, 112), @as(usize, map.count()));

    // Remove every other key: half the entries survive.
    for (0..56) |i| try testing.expect(map.remove(@intCast(i * 2)));
    try testing.expectEqual(@as(usize, 56), @as(usize, map.count()));

    // Refill with fresh keys; every kept and new value must be right.
    for (0..56) |i| try map.put(@intCast(1000 + i), @intCast(10_000 + i));
    try testing.expectEqual(@as(usize, 112), @as(usize, map.count()));
    try testing.expectError(error.NoSpaceLeft, map.put(2000, 1));

    for (0..56) |i| {
        try testing.expectEqual(@as(?u32, null), map.get(@intCast(i * 2)));
        try testing.expectEqual(@as(?u32, @intCast(i * 20 + 10)), map.get(@intCast(i * 2 + 1)));
        try testing.expectEqual(@as(?u32, @intCast(10_000 + i)), map.get(@intCast(1000 + i)));
    }
}

/// Assert that `map` holds exactly the keys in `[from, to)` with each value
/// equal to its key, and no key below `to` outside that range.
fn expectKeyRange(map: anytype, from: u16, to: u16) !void {
    try testing.expectEqual(@as(usize, to - from), @as(usize, map.count()));
    var key: u16 = 0;
    while (key < to) : (key += 1) {
        if (key >= from) {
            try testing.expectEqual(@as(?u32, key), map.get(key));
        } else {
            try testing.expectEqual(@as(?u32, null), map.get(key));
        }
    }
}

test "rebuild cycle" {
    // 112 entries in 128 buckets: 7/8 load, the density where removals
    // produce tombstones and the compaction's swap path runs.
    const Map = Bounded(u16, u32, 112);
    var map = Map.initContext(.{});

    // Full of distinct keys.
    for (0..112) |i| try map.put(@intCast(i), @intCast(i));
    try testing.expectEqual(@as(usize, 112), @as(usize, map.count()));

    var base: u16 = 112;
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        // Remove most: keep the newest quarter of the live range.
        var key = base - 112;
        while (key < base - 28) : (key += 1) try testing.expect(map.remove(key));
        try testing.expectEqual(@as(usize, 28), @as(usize, map.count()));

        // Refill repeatedly with fresh keys until the map is full again.
        var fresh = base;
        while (map.count() < Map.capacity) : (fresh += 1) try map.put(fresh, fresh);
        try expectKeyRange(&map, base - 28, fresh);

        // A new key at capacity compacts the tombstones in place and then
        // reports the bound. The compaction leaves no tombstone behind.
        try testing.expectError(error.NoSpaceLeft, map.put(fresh, 0));
        try testing.expect(map.rebuildCount() >= 1);
        for (map.ctrl) |byte| try testing.expect(byte != swiss.deleted);

        // The compaction must not have disturbed a single entry.
        try expectKeyRange(&map, base - 28, fresh);

        base = fresh;
    }
}

const DifferentialItem = struct {
    key: u16,
    value: u32,
};

/// Deterministic pseudo-random differential input (an LCG run at comptime).
/// The first `key_space` items are an LCG-shuffled permutation of the whole
/// key space, so a map with that capacity fills to the brim and every key is
/// exercised; the remaining items are LCG draws modulo the key space, so puts
/// overwrite and removals repeat.
fn makeDifferentialItems(
    comptime key_space: comptime_int,
    comptime count: comptime_int,
) [count]DifferentialItem {
    var items: [count]DifferentialItem = undefined;
    var state: u32 = 0x2545f491;

    var keys: [key_space]u16 = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    var i: usize = keys.len;
    while (i > 1) {
        i -= 1;
        state = state *% 1664525 +% 1013904223;
        const j = (state >> 16) % (i + 1);
        const swap = keys[i];
        keys[i] = keys[j];
        keys[j] = swap;
    }
    for (keys, 0..) |key, k| {
        state = state *% 1664525 +% 1013904223;
        items[k] = .{ .key = key, .value = state };
    }
    for (items[key_space..]) |*item| {
        state = state *% 1664525 +% 1013904223;
        item.key = @truncate((state >> 16) % key_space);
        item.value = state;
    }
    return items;
}

const differential_items = makeDifferentialItems(64, 96);
const large_differential_items = makeDifferentialItems(200, 260);

/// Assert that `bounded` and the std reference hold the same entries: count,
/// per-key values, and `contains` in both directions over the key space.
/// Iteration order is deliberately never compared.
fn expectEquivalent(reference: anytype, bounded: anytype, comptime key_space: comptime_int) !void {
    try testing.expectEqual(reference.count(), @as(usize, bounded.count()));

    var key: u16 = 0;
    while (key < key_space) : (key += 1) {
        try testing.expectEqual(reference.get(key), bounded.get(key));
        try testing.expectEqual(reference.contains(key), bounded.contains(key));
    }
}

/// Run the same operation sequence against both maps, checking equivalence
/// after every step: fresh puts and overwrites, removals, getOrPut
/// reinsertion, and interleaved remove/put for bucket reuse. Asserts that
/// the sequence actually fills the map, so the full-map paths are covered.
fn runDifferentialOps(
    comptime capacity: comptime_int,
    comptime key_space: comptime_int,
    reference: anytype,
    bounded: anytype,
    items: []const DifferentialItem,
) !void {
    var reached_capacity = false;
    for (items) |item| {
        try reference.put(testing.allocator, item.key, item.value);
        try bounded.put(item.key, item.value);
        if (bounded.count() == capacity) reached_capacity = true;
        try expectEquivalent(reference, bounded, key_space);
    }
    try testing.expect(reached_capacity);

    // Duplicate keys make this a mix of successful and failed removals.
    for (items) |item| {
        try testing.expectEqual(reference.remove(item.key), bounded.remove(item.key));
        try expectEquivalent(reference, bounded, key_space);
    }

    for (items, 0..) |item, i| {
        const reference_result = try reference.getOrPut(testing.allocator, item.key);
        const bounded_result = try bounded.getOrPut(item.key);
        try testing.expectEqual(reference_result.found_existing, bounded_result.found_existing);
        reference_result.value_ptr.* = item.value +% 1;
        bounded_result.value_ptr.* = item.value +% 1;
        if (i % 3 == 0) {
            try reference.put(testing.allocator, item.key, item.value);
            try bounded.put(item.key, item.value);
        }
        try expectEquivalent(reference, bounded, key_space);
    }

    for (items, 0..) |item, i| {
        try testing.expectEqual(reference.remove(item.key), bounded.remove(item.key));
        const value = if (i % 2 == 0) item.value +% 2 else item.value +% 3;
        try reference.put(testing.allocator, item.key, value);
        try bounded.put(item.key, value);
        try expectEquivalent(reference, bounded, key_space);
    }
}

test "matches std.AutoHashMapUnmanaged" {
    const Reference = std.AutoHashMapUnmanaged(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var bounded = Bounded(u16, u32, 64).initContext(.{});
    try runDifferentialOps(64, 64, &reference, &bounded, &differential_items);
}

test "matches std at a large capacity" {
    // Capacity 200 needs 256 buckets, so the bucket mask and the probe
    // arithmetic instantiate at a different size than the 64-entry run.
    const Reference = std.AutoHashMapUnmanaged(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var bounded = Bounded(u16, u32, 200).initContext(.{});
    try runDifferentialOps(200, 200, &reference, &bounded, &large_differential_items);
}

test "collision-heavy differential against std" {
    const Reference = std.hash_map.HashMapUnmanaged(
        u16,
        u32,
        NarrowHashContext,
        std.hash_map.default_max_load_percentage,
    );
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var bounded = BoundedWith(NarrowHashContext, u16, u32, 64).initContext(.{});
    try runDifferentialOps(64, 64, &reference, &bounded, &differential_items);
}
