//! Resizable Swiss-table hash map: the hashbrown / Abseil control-byte design
//! with heap storage and growth, and the allocator passed to every operation
//! instead of stored in the value.
//!
//! The control-byte encoding, the SIMD group matchers and the mirrored tail
//! live in `swiss.zig`; this file is the table over them. A bucket is
//! `hash & bucket_mask`, its entry lives at the same index in the parallel key
//! and value arrays, and a probe reads one group of control bytes per step:
//! `matchH2` screens the group's full lanes, keys are compared only for the
//! lanes that survive, and `matchEmpty` ends the walk. Probe positions follow
//! hashbrown's triangular sequence (`stride += group_width; pos += stride`),
//! which visits every group exactly once for the power-of-two bucket counts
//! used here, so a walk is bounded by `bucket_count / group_width` group reads
//! and sees every bucket.
//!
//! Sizing: the bucket count is the smallest power of two at or above
//! `ceil(requested * 8 / 7)`, floored at 8, so `capacity()` entries fit at no
//! more than 7/8 load and at least one bucket stays empty. An insertion that
//! would exceed that load allocates a table at double the bucket count and
//! reinserts every live entry through the normal probe; the fresh table is
//! all-empty, so growth is also where tombstones disappear. Growth clears
//! tombstones; churn without growth accumulates tombstones and lengthens
//! probe paths; no in-place compaction is shipped — a future trigger for that
//! is a documented gap.
//!
//! Removal always writes a tombstone (Abseil's rule): groups align to each
//! probe's own position, so writing `empty` could break another key's probe
//! path, while the walk sees every bucket and so finds the tombstone and
//! reuses it for the next insertion that crosses it.
//!
//! Storage is three heap arrays: the control bytes (one per bucket plus the
//! mirrored tail), the keys, and the values. The only metadata is the 1-byte
//! control tag: an entry's full hash is never stored and is recomputed from
//! the key when a probe, a reinsertion or a growth needs it. Against
//! `std.hash_map`, the pitch is group matching — one vector compare screens a
//! whole probe step instead of one key per step — and no per-entry hash
//! storage.
//!
//! Iteration is in bucket order, not insertion order: entries move between
//! buckets as tombstones are reused and as the table grows. Contrast
//! `bounded_array_hash_map.Auto`, which iterates in insertion order.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const StringContext = std.hash_map.StringContext;
const AutoContext = std.hash_map.AutoContext;

const swiss = @import("../swiss.zig");
const group_width = swiss.group_width;

/// A `Custom` that hashes keys with `std.hash_map.AutoContext`, like std's
/// `AutoHashMap`: one context, no type-dependent routing. Slices — including
/// `[]const u8` — are rejected by `std.hash.autoHash`; string keys use
/// `String`.
pub fn Auto(comptime K: type, comptime V: type) type {
    return Custom(AutoContext(K), K, V);
}

/// A `Custom` for string keys, like std's `StringHashMap`: the one context
/// that hashes `[]const u8` by content. Key memory is managed by the caller.
pub fn String(comptime V: type) type {
    return Custom(StringContext, []const u8, V);
}

/// A resizable Swiss-table hash map that grows on the heap through the
/// allocator passed to each operation.
///
/// `Context` follows the `std.hash_map` convention: `hash(self, K) u64` and
/// `eql(self, K, K) bool`. The hash's low bits pick the starting bucket and
/// its top 7 bits form the H2 tag; a context that hashes to a narrower
/// integer should spread it across the `u64` itself, because a hash whose top
/// 7 bits are constant makes the tag match every full lane in a group.
pub fn Custom(comptime Context: type, comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

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
        /// runs past the last bucket reads the wrapped bytes. Zero-length in
        /// the empty map.
        ctrl: []u8,
        /// Key of the entry in each bucket; a bucket holds an entry only
        /// while its control byte is full.
        keys: []K,
        /// Value of the entry in each bucket.
        values: []V,
        /// Number of buckets, a power of two; 0 in the empty map.
        bucket_count: usize,
        /// Number of live entries.
        used: usize,
        context: Context,

        /// A map containing no entries. The context is undefined, as in
        /// `std.PriorityQueue.empty`; use `initContext` to set it. Reads and
        /// `count` work without allocating; the first insertion allocates
        /// the initial table.
        pub const empty: Self = .{
            .ctrl = &.{},
            .keys = &.{},
            .values = &.{},
            .bucket_count = 0,
            .used = 0,
            .context = undefined,
        };

        /// Initialize and return a map with a default-initialized context.
        /// Convenience for stateless contexts such as
        /// `std.hash_map.AutoContext` and `std.hash_map.StringContext`;
        /// contexts that carry state must use `initContext`.
        pub const init: Self = .{
            .ctrl = &.{},
            .keys = &.{},
            .values = &.{},
            .bucket_count = 0,
            .used = 0,
            .context = .{},
        };

        /// Initialize and return a map with `context`.
        pub fn initContext(context: Context) Self {
            return .{
                .ctrl = &.{},
                .keys = &.{},
                .values = &.{},
                .bucket_count = 0,
                .used = 0,
                .context = context,
            };
        }

        /// Number of entries currently stored.
        pub fn count(self: *const Self) usize {
            return self.used;
        }

        /// Number of entries the table can hold before the next insertion
        /// grows it: 7/8 of the bucket count, with at least one bucket left
        /// empty. The empty map has capacity 0.
        pub fn capacity(self: *const Self) usize {
            return bucketsToCapacity(self.bucket_count);
        }

        /// Number of buckets for a table that must hold `requested` entries
        /// at the 7/8 load target: the smallest power of two at or above
        /// `ceil(requested * 8 / 7)`, floored at 8 so the smallest table
        /// holds 7 entries.
        fn capacityToBuckets(requested: usize) usize {
            if (requested < 8) return 8;
            const needed = (requested * 8 + 6) / 7;
            return @max(16, std.math.ceilPowerOfTwoAssert(usize, needed));
        }

        /// Entries a table of `buckets` buckets holds at the 7/8 load
        /// target. Power-of-two bucket counts are multiples of 8, so the
        /// division is exact and one bucket always stays empty.
        fn bucketsToCapacity(buckets: usize) usize {
            return buckets / 8 * 7;
        }

        /// Write `byte` to the control byte of `slot` and to every mirrored
        /// copy of that byte in the tail.
        fn setCtrl(self: *Self, slot: usize, byte: u8) void {
            self.ctrl[slot] = byte;
            var mirror = slot + self.bucket_count;
            while (mirror < self.ctrl.len) : (mirror += self.bucket_count) self.ctrl[mirror] = byte;
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
            // The empty map has no table to walk and no hash to spend; the
            // one caller that could insert (getOrPut) allocates first and
            // probes again.
            if (self.bucket_count == 0) return .{ .hash = 0 };
            const hash: u64 = self.context.hash(key);
            var result: Probe = .{ .hash = hash };
            const tag = swiss.full(hash);
            const bucket_mask = self.bucket_count - 1;
            var pos: usize = @as(usize, @truncate(hash)) & bucket_mask;
            var stride: usize = 0;
            var groups_left: usize = @max(1, self.bucket_count / group_width);
            while (groups_left > 0) : (groups_left -= 1) {
                const bytes: *const [group_width]u8 = self.ctrl[pos..][0..group_width];
                var matches = swiss.matchH2(bytes, tag);
                while (swiss.firstSet(matches)) |lane| {
                    matches &= matches - 1;
                    const slot = (pos + lane) & bucket_mask;
                    if (self.context.eql(key, self.keys[slot])) {
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

        /// Store `key` in `slot`, whose control byte is empty or deleted,
        /// and return its storage. The value is left undefined.
        fn insertAt(self: *Self, slot: usize, key: K, hash: u64) GetOrPutResult {
            assert(self.used < self.capacity());
            self.keys[slot] = key;
            self.setCtrl(slot, swiss.full(hash));
            self.used += 1;
            return .{
                .key_ptr = &self.keys[slot],
                .value_ptr = &self.values[slot],
                .found_existing = false,
            };
        }

        /// Double the bucket count. Called when live entries fill the
        /// capacity (or, for the empty map, when the first entry arrives);
        /// the reinsertion into the fresh table is where tombstones
        /// disappear.
        fn grow(self: *Self, gpa: Allocator) Allocator.Error!void {
            const new_buckets = if (self.bucket_count == 0) 8 else self.bucket_count * 2;
            try self.rehash(gpa, new_buckets);
        }

        /// Allocate a table of `new_buckets` buckets, move every live entry
        /// into it through the normal probe, and free the old arrays. The
        /// fresh table starts all-empty, so no control byte of the old table
        /// carries over and every tombstone is gone.
        fn rehash(self: *Self, gpa: Allocator, new_buckets: usize) Allocator.Error!void {
            assert(new_buckets >= 8);
            assert(std.math.isPowerOfTwo(new_buckets));

            const new_ctrl = try gpa.alloc(u8, new_buckets + group_width - 1);
            errdefer gpa.free(new_ctrl);
            const new_keys = try gpa.alloc(K, new_buckets);
            errdefer gpa.free(new_keys);
            const new_values = try gpa.alloc(V, new_buckets);

            const old_ctrl = self.ctrl;
            const old_keys = self.keys;
            const old_values = self.values;
            const old_buckets = self.bucket_count;

            self.ctrl = new_ctrl;
            self.keys = new_keys;
            self.values = new_values;
            self.bucket_count = new_buckets;
            self.used = 0;
            @memset(new_ctrl, swiss.empty);

            for (0..old_buckets) |slot| {
                if (old_ctrl[slot] >= swiss.empty) continue;
                const found = self.probe(old_keys[slot]);
                const result = self.insertAt(found.insert.?, old_keys[slot], found.hash);
                result.value_ptr.* = old_values[slot];
            }
            assert(self.used <= self.capacity());

            gpa.free(old_ctrl);
            gpa.free(old_keys);
            gpa.free(old_values);
        }

        /// Insert `key`, which the map does not contain, into a table that
        /// has just grown. The walk must land on an empty bucket: the fresh
        /// table has no tombstones and holds fewer entries than its
        /// capacity.
        fn insertAfterGrow(self: *Self, key: K) GetOrPutResult {
            const retry = self.probe(key);
            assert(retry.found == null);
            return self.insertAt(retry.insert.?, key, retry.hash);
        }

        /// Value stored for `key`, or null. Reads never allocate.
        pub fn get(self: *const Self, key: K) ?V {
            const slot = self.probe(key).found orelse return null;
            return self.values[slot];
        }

        /// Pointer to the value stored for `key`, or null. The pointer is
        /// invalidated by the next insertion or growth.
        pub fn getPtr(self: *Self, key: K) ?*V {
            const slot = self.probe(key).found orelse return null;
            return &self.values[slot];
        }

        /// Whether `key` is stored in the map.
        pub fn contains(self: *const Self, key: K) bool {
            return self.probe(key).found != null;
        }

        /// Insert or overwrite `key`.
        pub fn put(self: *Self, gpa: Allocator, key: K, value: V) Allocator.Error!void {
            const result = try self.getOrPut(gpa, key);
            result.value_ptr.* = value;
        }

        /// Find or insert `key`. A new entry's value is undefined until the
        /// caller initializes `value_ptr`. The table grows when live entries
        /// fill the capacity, so the only failure is the allocator failing.
        pub fn getOrPut(self: *Self, gpa: Allocator, key: K) Allocator.Error!GetOrPutResult {
            const first = self.probe(key);
            if (first.found) |slot| {
                return .{
                    .key_ptr = &self.keys[slot],
                    .value_ptr = &self.values[slot],
                    .found_existing = true,
                };
            }
            if (self.used == self.capacity()) {
                // At the 7/8 target there is no room for another entry even
                // though the table still has empty or deleted bytes: double
                // it, which re-places every live entry in a fresh table.
                try self.grow(gpa);
                return self.insertAfterGrow(key);
            }
            const slot = first.deleted orelse first.insert orelse {
                // The walk found no landing, so every bucket is full. The
                // load check above prevents this state; doubling is the
                // correct recovery if it ever happens.
                try self.grow(gpa);
                return self.insertAfterGrow(key);
            };
            return self.insertAt(slot, key, first.hash);
        }

        /// Remove `key`. Returns false when `key` is absent. The bucket
        /// becomes a tombstone.
        pub fn remove(self: *Self, key: K) bool {
            const result = self.probe(key);
            const slot = result.found orelse return false;
            // Always a tombstone — Abseil's rule. Writing `empty` here could
            // break another key's probe: groups align to each probe's own
            // position, so the finding probe's group having an empty says
            // nothing about every other window covering this slot. The walk
            // sees every bucket, so the next insertion on such a path finds
            // the tombstone and reuses it; growth reclaims all of them.
            self.setCtrl(slot, swiss.deleted);
            self.used -= 1;
            return true;
        }

        /// Remove all entries, keeping the storage. Every control byte,
        /// mirrored tail included, becomes `empty`.
        pub fn clearRetainingCapacity(self: *Self) void {
            @memset(self.ctrl, swiss.empty);
            self.used = 0;
        }

        /// Remove all entries and release the storage, returning to the
        /// empty state; the next insertion allocates again.
        pub fn clearAndFree(self: *Self, gpa: Allocator) void {
            gpa.free(self.ctrl);
            gpa.free(self.keys);
            gpa.free(self.values);
            self.ctrl = &.{};
            self.keys = &.{};
            self.values = &.{};
            self.bucket_count = 0;
            self.used = 0;
        }

        /// Grow so that `expected` entries fit without another allocation;
        /// no-op when the current capacity already covers `expected`.
        pub fn ensureTotalCapacity(
            self: *Self,
            gpa: Allocator,
            expected: usize,
        ) Allocator.Error!void {
            if (self.capacity() >= expected) return;
            try self.rehash(gpa, capacityToBuckets(expected));
        }

        /// Release the storage and invalidate the map.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.ctrl);
            gpa.free(self.keys);
            gpa.free(self.values);
            self.* = undefined;
        }

        /// Advance `slot` to the next bucket holding an entry, or return
        /// null when the buckets are exhausted. A bucket holds an entry
        /// exactly when its control byte is full, and the encoding makes
        /// that a less-than-empty test.
        fn nextFullSlot(self: *const Self, slot: *usize) ?usize {
            while (slot.* < self.bucket_count) {
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
                    .key_ptr = &it.map.keys[slot],
                    .value_ptr = &it.map.values[slot],
                };
            }

            /// Reset the iterator to the first bucket.
            pub fn reset(it: *Iterator) void {
                it.slot = 0;
            }
        };

        /// An iterator over the entries in bucket order. The entry pointers
        /// alias the map's storage; the iterator is invalidated by the next
        /// insertion, removal or growth.
        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self, .slot = 0 };
        }

        pub const KeyIterator = struct {
            map: *Self,
            slot: usize,

            /// The next key in bucket order, or null.
            pub fn next(it: *KeyIterator) ?*K {
                const slot = it.map.nextFullSlot(&it.slot) orelse return null;
                return &it.map.keys[slot];
            }

            /// Reset the iterator to the first bucket.
            pub fn reset(it: *KeyIterator) void {
                it.slot = 0;
            }
        };

        /// An iterator over the keys in bucket order, matching `iterator()`
        /// step for step. The pointers alias the map's storage; the iterator
        /// is invalidated by the next insertion, removal or growth.
        pub fn keyIterator(self: *Self) KeyIterator {
            return .{ .map = self, .slot = 0 };
        }

        pub const ValueIterator = struct {
            map: *Self,
            slot: usize,

            /// The next value in bucket order, or null.
            pub fn next(it: *ValueIterator) ?*V {
                const slot = it.map.nextFullSlot(&it.slot) orelse return null;
                return &it.map.values[slot];
            }

            /// Reset the iterator to the first bucket.
            pub fn reset(it: *ValueIterator) void {
                it.slot = 0;
            }
        };

        /// An iterator over the values in bucket order, matching
        /// `keyIterator()` step for step. The pointers alias the map's
        /// storage; the iterator is invalidated by the next insertion,
        /// removal or growth.
        pub fn valueIterator(self: *Self) ValueIterator {
            return .{ .map = self, .slot = 0 };
        }
    };
}

test "empty" {
    // `empty`'s context is undefined, which is harmless for the zero-sized
    // auto contexts; `init` is the same value with the context defaulted.
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expectEqual(@as(usize, 0), map.capacity());
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expect(!map.contains(1));
    try map.put(testing.allocator, 1, 10);
    try testing.expectEqual(@as(?u32, 10), map.get(1));

    var initialized: Auto(u32, u32) = .init;
    defer initialized.deinit(testing.allocator);
    try initialized.put(testing.allocator, 2, 20);
    try testing.expectEqual(@as(?u32, 20), initialized.get(2));
    try testing.expectEqual(@as(usize, 1), initialized.count());
}

test "put" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    try map.put(testing.allocator, 3, 30);
    try map.put(testing.allocator, 1, 10);
    try map.put(testing.allocator, 2, 20);
    try testing.expectEqual(@as(usize, 3), map.count());

    // An overwrite replaces the value in place and does not consume room.
    try map.put(testing.allocator, 1, 11);
    try testing.expectEqual(@as(?u32, 11), map.get(1));
    try testing.expectEqual(@as(usize, 3), map.count());

    // A removal frees room for a new key.
    try testing.expect(map.remove(3));
    try map.put(testing.allocator, 5, 50);
    try testing.expectEqual(@as(?u32, 50), map.get(5));
    try testing.expectEqual(@as(?u32, null), map.get(3));
    try testing.expectEqual(@as(usize, 3), map.count());
}

test "get" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expect(!map.contains(1));
    try testing.expect(map.getPtr(1) == null);

    try map.put(testing.allocator, 1, 10);
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
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    // Missing key: false, map untouched.
    try testing.expect(!map.remove(9));
    try testing.expectEqual(@as(usize, 0), map.count());

    try map.put(testing.allocator, 1, 10);
    try map.put(testing.allocator, 2, 20);
    try map.put(testing.allocator, 3, 30);

    try testing.expect(map.remove(2));
    try testing.expect(!map.contains(2));
    try testing.expectEqual(@as(?u32, null), map.get(2));
    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expect(!map.remove(2));

    // The survivors are still reachable and the room is reusable.
    try testing.expectEqual(@as(?u32, 10), map.get(1));
    try testing.expectEqual(@as(?u32, 30), map.get(3));
    try map.put(testing.allocator, 4, 40);
    try testing.expectEqual(@as(?u32, 40), map.get(4));

    // Empty it out and reuse it from scratch.
    try testing.expect(map.remove(1));
    try testing.expect(map.remove(3));
    try testing.expect(map.remove(4));
    try testing.expectEqual(@as(usize, 0), map.count());
    try map.put(testing.allocator, 5, 50);
    try testing.expectEqual(@as(?u32, 50), map.get(5));
    try testing.expect(!map.contains(1));
}

test "getOrPut" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    const first = try map.getOrPut(testing.allocator, 7);
    try testing.expect(!first.found_existing);
    try testing.expectEqual(@as(u32, 7), first.key_ptr.*);
    first.value_ptr.* = 70;
    try testing.expectEqual(@as(?u32, 70), map.get(7));

    const second = try map.getOrPut(testing.allocator, 7);
    try testing.expect(second.found_existing);
    try testing.expectEqual(@as(u32, 70), second.value_ptr.*);
    second.value_ptr.* = 71;
    try testing.expectEqual(@as(?u32, 71), map.get(7));
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "clearRetainingCapacity and clearAndFree" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    for (0..100) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
    const buckets = map.bucket_count;

    map.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expectEqual(buckets, map.bucket_count);
    try testing.expectEqual(@as(?u32, null), map.get(0));
    var iterator = map.iterator();
    try testing.expect(iterator.next() == null);
    for (map.ctrl) |byte| try testing.expectEqual(swiss.empty, byte);

    // Refill at the retained capacity without growing.
    const retained = map.capacity();
    for (0..retained) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    try testing.expectEqual(buckets, map.bucket_count);
    for (0..retained) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }

    // clearAndFree returns to the empty state; the next insert allocates
    // the smallest table again.
    map.clearAndFree(testing.allocator);
    try testing.expectEqual(@as(usize, 0), map.bucket_count);
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expectEqual(@as(?u32, null), map.get(0));
    try map.put(testing.allocator, 7, 70);
    try testing.expectEqual(@as(usize, 8), map.bucket_count);
    try testing.expectEqual(@as(?u32, 70), map.get(7));
}

test "iterator" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    // Empty map: next() is null immediately.
    var empty_iterator = map.iterator();
    try testing.expect(empty_iterator.next() == null);

    try map.put(testing.allocator, 4, 40);
    try map.put(testing.allocator, 2, 20);
    try map.put(testing.allocator, 7, 70);

    // Iteration is in bucket order: exactly the buckets whose control byte
    // is full, in increasing bucket index. Insertion order (4, 2, 7) is
    // deliberately not what the iterator promises.
    var expected_keys: [8]u32 = undefined;
    var expected_values: [8]u32 = undefined;
    var expected_len: usize = 0;
    for (0..map.bucket_count) |slot| {
        if (map.ctrl[slot] < swiss.empty) {
            expected_keys[expected_len] = map.keys[slot];
            expected_values[expected_len] = map.values[slot];
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
    try map.put(testing.allocator, 2, 22);
    try testing.expect(map.remove(4));
    try map.put(testing.allocator, 9, 90);
    var after_keys: [8]u32 = undefined;
    var after_values: [8]u32 = undefined;
    var after_len: usize = 0;
    for (0..map.bucket_count) |slot| {
        if (map.ctrl[slot] < swiss.empty) {
            after_keys[after_len] = map.keys[slot];
            after_values[after_len] = map.values[slot];
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

test "keyIterator and valueIterator" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, 2, 20);
    try map.put(testing.allocator, 1, 10);

    // keyIterator() and valueIterator() walk the same buckets in the same
    // order.
    var key_iterator = map.keyIterator();
    var value_iterator = map.valueIterator();
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
    var values = map.valueIterator();
    while (values.next()) |value_ptr| value_ptr.* += 1000;
    try testing.expectEqual(@as(?u32, 1010), map.get(1));
    try testing.expectEqual(@as(?u32, 1020), map.get(2));

    // reset() rewinds to the first bucket, and the walk repeats.
    values.reset();
    var repeat = map.valueIterator();
    while (repeat.next()) |value_ptr| {
        try testing.expectEqual(value_ptr.*, values.next().?.*);
    }
    try testing.expect(values.next() == null);
}

test "capacity arithmetic" {
    const Map = Auto(u32, u32);

    // The bucket count is a power of two that holds the request at 7/8 load
    // and always leaves at least one bucket empty.
    var requested: usize = 1;
    while (requested <= 1 << 20) : (requested *= 2) {
        const buckets = Map.capacityToBuckets(requested);
        try testing.expect(std.math.isPowerOfTwo(buckets));
        try testing.expect(buckets >= 8);
        try testing.expect(Map.bucketsToCapacity(buckets) >= requested);
        try testing.expect(Map.bucketsToCapacity(buckets) < buckets);
    }

    // The boundaries: 7 entries need 8 buckets, 8 need 16, and 15 is the
    // first request where 16 buckets would exceed 7/8 load.
    try testing.expectEqual(@as(usize, 8), Map.capacityToBuckets(7));
    try testing.expectEqual(@as(usize, 16), Map.capacityToBuckets(8));
    try testing.expectEqual(@as(usize, 16), Map.capacityToBuckets(14));
    try testing.expectEqual(@as(usize, 32), Map.capacityToBuckets(15));
    try testing.expectEqual(@as(usize, 7), Map.bucketsToCapacity(8));
    try testing.expectEqual(@as(usize, 56), Map.bucketsToCapacity(64));
}

test "growth" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    // Lazy init: the first insert allocates the smallest table.
    try testing.expectEqual(@as(usize, 0), map.bucket_count);
    try testing.expectEqual(@as(usize, 0), map.capacity());
    try map.put(testing.allocator, 1, 10);
    try testing.expectEqual(@as(usize, 8), map.bucket_count);
    try testing.expectEqual(@as(usize, 7), map.capacity());

    // Organic growth crosses several doublings; every key reads back.
    for (2..200) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    try testing.expectEqual(@as(usize, 199), map.count());
    try testing.expect(map.bucket_count >= 256);
    for (1..200) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
}

test "ensureTotalCapacity" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    // No-op while the current capacity already covers the request.
    try map.ensureTotalCapacity(testing.allocator, 0);
    try testing.expectEqual(@as(usize, 0), map.bucket_count);

    try map.ensureTotalCapacity(testing.allocator, 100);
    try testing.expect(map.capacity() >= 100);
    const reserved = map.bucket_count;

    // Inserts up to the request do not grow the table.
    for (0..100) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
    try testing.expectEqual(reserved, map.bucket_count);
    try testing.expectEqual(@as(usize, 100), map.count());

    // A smaller request is a no-op; a larger one grows.
    try map.ensureTotalCapacity(testing.allocator, 50);
    try testing.expectEqual(reserved, map.bucket_count);
    try map.ensureTotalCapacity(testing.allocator, 1000);
    try testing.expect(map.capacity() >= 1000);
    for (0..100) |i| try testing.expectEqual(@as(?u32, @intCast(i)), map.get(@intCast(i)));

    // Reserved growth and organic growth agree by key.
    var organic: Auto(u32, u32) = .empty;
    defer organic.deinit(testing.allocator);
    for (0..100) |i| try organic.put(testing.allocator, @intCast(i), @intCast(i));
    try testing.expectEqual(organic.count(), map.count());
    for (0..100) |i| {
        try testing.expectEqual(organic.get(@intCast(i)), map.get(@intCast(i)));
        try testing.expectEqual(organic.contains(@intCast(i)), map.contains(@intCast(i)));
    }
}

test "churn at capacity" {
    var map: Auto(u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    // Fill to capacity: 56 entries in 64 buckets, then churn: remove most,
    // refill with fresh keys, repeat. Tombstone reuse must absorb the churn
    // without growing the table, and every live entry must stay correct.
    for (0..56) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
    try testing.expectEqual(@as(usize, 56), map.count());
    try testing.expectEqual(@as(usize, 56), map.capacity());
    const buckets = map.bucket_count;

    var base: u16 = 56;
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        // Remove most: keep the newest quarter of the live range.
        var key = base - 56;
        while (key < base - 14) : (key += 1) try testing.expect(map.remove(key));
        try testing.expectEqual(@as(usize, 14), map.count());

        // Refill with fresh keys until the map is at capacity again. Every
        // insert lands on a tombstone or an empty; none may grow the table.
        var fresh = base;
        while (map.count() < map.capacity()) : (fresh += 1) {
            try map.put(testing.allocator, fresh, fresh);
        }
        try testing.expectEqual(buckets, map.bucket_count);
        try testing.expectEqual(@as(usize, 56), map.capacity());

        // Every live entry reads back correct by key.
        key = base - 14;
        while (key < fresh) : (key += 1) {
            try testing.expectEqual(@as(?u32, key), map.get(key));
        }
        try testing.expectEqual(@as(?u32, null), map.get(base - 56));
        base = fresh;
    }
}

test "overwrite at capacity" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    for (0..7) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
    try testing.expectEqual(@as(usize, 7), map.count());
    try testing.expectEqual(@as(usize, 7), map.capacity());
    try testing.expectEqual(@as(usize, 8), map.bucket_count);

    // Overwriting an existing key at capacity must not grow the table.
    try map.put(testing.allocator, 3, 33);
    try testing.expectEqual(@as(usize, 8), map.bucket_count);
    try testing.expectEqual(@as(?u32, 33), map.get(3));
    try testing.expectEqual(@as(usize, 7), map.count());

    // A new key grows instead.
    try map.put(testing.allocator, 9, 90);
    try testing.expectEqual(@as(usize, 16), map.bucket_count);
    try testing.expectEqual(@as(?u32, 90), map.get(9));
    try testing.expectEqual(@as(?u32, 33), map.get(3));
}

test "V = void" {
    var set: Auto(u32, void) = .empty;
    defer set.deinit(testing.allocator);

    try set.put(testing.allocator, 2, {});
    try set.put(testing.allocator, 1, {});
    try set.put(testing.allocator, 3, {});
    try testing.expect(set.contains(1));
    try testing.expect(set.contains(2));
    try testing.expect(!set.contains(9));
    try testing.expectEqual(@as(usize, 3), set.count());

    const result = try set.getOrPut(testing.allocator, 4);
    try testing.expect(!result.found_existing);
    result.value_ptr.* = {};
    try testing.expect(set.contains(4));

    // void values still iterate.
    var iterator = set.iterator();
    var n: usize = 0;
    while (iterator.next()) |entry| : (n += 1) {
        _ = entry.value_ptr.*;
    }
    try testing.expectEqual(@as(usize, 4), n);

    try testing.expect(set.remove(1));
    try testing.expect(!set.contains(1));
    try testing.expectEqual(@as(usize, 3), set.count());
}

test "auto and string keys" {
    // Integer keys through std.hash_map.AutoContext.
    var integers: Auto(u16, u32) = .empty;
    defer integers.deinit(testing.allocator);
    try integers.put(testing.allocator, 3, 30);
    try integers.put(testing.allocator, 1, 10);
    try integers.put(testing.allocator, 3, 33);
    try testing.expectEqual(@as(?u32, 33), integers.get(3));
    try testing.expectEqual(@as(?u32, 10), integers.get(1));
    try testing.expectEqual(@as(?u32, null), integers.get(2));

    // []const u8 keys route to std.hash_map.StringContext because
    // std.hash_map.AutoContext rejects slices.
    var strings: String(u32) = .empty;
    defer strings.deinit(testing.allocator);
    try strings.put(testing.allocator, "one", 1);
    try strings.put(testing.allocator, "two", 2);
    try strings.put(testing.allocator, "one", 11);
    try testing.expectEqual(@as(?u32, 11), strings.get("one"));
    try testing.expectEqual(@as(?u32, 2), strings.get("two"));
    try testing.expectEqual(@as(?u32, null), strings.get("three"));
    try testing.expectEqual(@as(usize, 2), strings.count());
    try testing.expect(strings.remove("one"));
    try testing.expectEqual(@as(usize, 1), strings.count());
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
    var salted: Custom(SaltContext, u32, u32) = .initContext(.{ .salt = 0x1234 });
    defer salted.deinit(testing.allocator);
    try salted.put(testing.allocator, 1, 10);
    try salted.put(testing.allocator, 2, 20);
    try testing.expectEqual(@as(?u32, 10), salted.get(1));
    try testing.expectEqual(@as(?u32, 20), salted.get(2));
    try testing.expect(salted.remove(1));
    try testing.expectEqual(@as(?u32, null), salted.get(1));
    try testing.expectEqual(@as(?u32, 20), salted.get(2));

    // The same key in a map with a different salt still works; the context
    // decides placement, not the map.
    var other: Custom(SaltContext, u32, u32) = .initContext(.{ .salt = 0x5678 });
    defer other.deinit(testing.allocator);
    try other.put(testing.allocator, 1, 10);
    try other.put(testing.allocator, 2, 20);
    try testing.expectEqual(@as(?u32, 10), other.get(1));
    try testing.expectEqual(@as(?u32, 20), other.get(2));

    var points: Custom(PointContext, Point, u32) = .empty;
    defer points.deinit(testing.allocator);
    try points.put(testing.allocator, .{ .x = 1, .y = 2 }, 12);
    try points.put(testing.allocator, .{ .x = 2, .y = 1 }, 21);
    try points.put(testing.allocator, .{ .x = 1, .y = 2 }, 99);
    try testing.expectEqual(@as(?u32, 99), points.get(.{ .x = 1, .y = 2 }));
    try testing.expectEqual(@as(?u32, 21), points.get(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, null), points.get(.{ .x = 3, .y = 3 }));
    try testing.expectEqual(@as(usize, 2), points.count());
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

/// A context whose hash is the same for every key: one probe chain and one
/// H2 tag for the whole table, the hashbrown worst-case-hash class.
const ConstHashContext = struct {
    pub fn hash(self: ConstHashContext, key: u16) u64 {
        _ = self;
        _ = key;
        return 0x9e3779b97f4a7c15;
    }

    pub fn eql(self: ConstHashContext, a: u16, b: u16) bool {
        _ = self;
        return a == b;
    }
};

/// A context the wrapped-probe test steers: the hash's low bits are the
/// key's own low bits, so H1 can be aimed at the final buckets, and the top
/// bits vary with the key so H2 stays a real fingerprint.
const WrapHashContext = struct {
    pub fn hash(self: WrapHashContext, key: u16) u64 {
        _ = self;
        return (@as(u64, key) << 57) | (key & 0xF);
    }

    pub fn eql(self: WrapHashContext, a: u16, b: u16) bool {
        _ = self;
        return a == b;
    }
};

test "collision-heavy small map" {
    // Every key starts in one of three buckets: the probe chains and
    // tombstone reuse both get exercised.
    var map: Custom(NarrowHashContext, u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    for (0..64) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    for (0..64) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
    try testing.expectEqual(@as(?u32, null), map.get(1000));

    // Remove half, refill, verify.
    for (0..32) |i| try testing.expect(map.remove(@intCast(i * 2)));
    for (0..32) |i| try map.put(testing.allocator, @intCast(1000 + i), @intCast(2000 + i));
    for (0..32) |i| {
        try testing.expectEqual(@as(?u32, null), map.get(@intCast(i * 2)));
        try testing.expectEqual(@as(?u32, @intCast(i * 2 * 10 + 10)), map.get(@intCast(i * 2 + 1)));
        try testing.expectEqual(@as(?u32, @intCast(2000 + i)), map.get(@intCast(1000 + i)));
    }
}

test "mirror invariant" {
    var map: Auto(u32, u32) = .empty;
    defer map.deinit(testing.allocator);

    // Enough entries to grow, then removals for tombstones and reinsertions
    // for reuse.
    for (0..300) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
    for (0..100) |i| try testing.expect(map.remove(@intCast(i * 3)));
    try map.put(testing.allocator, 1000, 1000);
    try map.put(testing.allocator, 1001, 1001);
    try map.put(testing.allocator, 1002, 1002);

    // Every group read at every bucket offset reads the wrapped bytes:
    // ctrl[pos + lane] is the control byte of bucket (pos + lane) % count.
    for (0..map.bucket_count) |pos| {
        for (0..group_width) |lane| {
            try testing.expectEqual(
                map.ctrl[(pos + lane) % map.bucket_count],
                map.ctrl[pos + lane],
            );
        }
    }

    // In the common case the tail is a plain copy of the first
    // group_width - 1 buckets.
    for (0..group_width - 1) |i| {
        try testing.expectEqual(map.ctrl[i], map.ctrl[map.bucket_count + i]);
    }
}

test "allocator failure" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();

    var map: Auto(u32, u32) = .empty;
    defer map.deinit(gpa);

    // The initial table's first allocation fails; the map stays empty.
    failing.fail_index = 0;
    try testing.expectError(error.OutOfMemory, map.put(gpa, 1, 10));
    try testing.expectEqual(@as(usize, 0), map.bucket_count);
    try testing.expectEqual(@as(usize, 0), map.count());

    // Partial failure: the control array allocates, the key array fails, and
    // the control array is released again.
    failing.fail_index = 1;
    try testing.expectError(error.OutOfMemory, map.put(gpa, 1, 10));
    try testing.expectEqual(@as(usize, 0), map.bucket_count);

    // A later insert succeeds.
    failing.fail_index = std.math.maxInt(usize);
    try map.put(gpa, 1, 10);
    try testing.expectEqual(@as(?u32, 10), map.get(1));

    // Fill to capacity, then fail the growth: every existing entry
    // survives.
    for (2..8) |i| try map.put(gpa, @intCast(i), @intCast(i));
    try testing.expectEqual(@as(usize, 7), map.count());
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, map.put(gpa, 9, 90));
    try testing.expectEqual(@as(?u32, null), map.get(9));
    try testing.expectEqual(@as(?u32, 10), map.get(1));
    for (2..8) |i| try testing.expectEqual(@as(?u32, @intCast(i)), map.get(@intCast(i)));

    // And a later insert at the same point still succeeds.
    failing.fail_index = std.math.maxInt(usize);
    try map.put(gpa, 9, 90);
    try testing.expectEqual(@as(?u32, 90), map.get(9));
}

test "deinit" {
    var map: Auto(u32, u32) = .empty;
    for (0..64) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
    try testing.expect(map.bucket_count > 0);
    map.deinit(testing.allocator);

    // A fresh map built in the same variable works from the empty state.
    map = .empty;
    try map.put(testing.allocator, 1, 1);
    try testing.expectEqual(@as(?u32, 1), map.get(1));
    map.deinit(testing.allocator);
}

test "adversarial constant hash" {
    // hashbrown's worst-case-hash tests: every key shares one hash, so every
    // probe walks one chain and every group lane carries the same H2 tag.
    var map: Custom(ConstHashContext, u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    for (0..200) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    // 200 keys force several growths; the one chain must have walked into
    // the fresh tables and every entry must survive.
    try testing.expect(map.bucket_count >= 256);
    for (0..200) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
        try testing.expect(map.contains(@intCast(i)));
    }

    // Remove half, verify the remainder and the absences, then reinsert.
    for (0..100) |i| try testing.expect(map.remove(@intCast(i * 2)));
    try testing.expectEqual(@as(usize, 100), map.count());
    for (0..200) |i| {
        if (i % 2 == 0) {
            try testing.expectEqual(@as(?u32, null), map.get(@intCast(i)));
            try testing.expect(!map.contains(@intCast(i)));
        } else {
            try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
        }
    }
    for (0..100) |i| try map.put(testing.allocator, @intCast(i * 2), @intCast(i * 20));
    try testing.expectEqual(@as(usize, 200), map.count());
    for (0..200) |i| try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
}

test "grow across every small boundary" {
    // Go's TestMapGrow class: after each single insert every key so far
    // reads back and the count is exact, so a capacity-arithmetic off-by-one
    // in the 8..256 bucket region cannot hide behind random probes.
    var map: Auto(u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    for (0..200) |i| {
        const key: u16 = @intCast(i);
        try map.put(testing.allocator, key, @as(u32, key) * 10);
        try testing.expectEqual(i + 1, map.count());
        var probe: u16 = 0;
        while (probe <= key) : (probe += 1) {
            try testing.expectEqual(@as(?u32, @as(u32, probe) * 10), map.get(probe));
        }
        try testing.expectEqual(@as(?u32, null), map.get(key + 1));
    }

    // The stream crossed the 8, 16, 32, 64, 128 and 256 bucket thresholds
    // (7, 14, 28, 56, 112 and 224 entries).
    try testing.expect(map.bucket_count >= 256);
    try testing.expectEqual(@as(usize, 200), map.count());
}

test "delete everything then reuse" {
    // Go's empty-map regression class: after the last removal the map must
    // behave like a fresh one, and the retained table must refill through
    // its empty slots without growing.
    var map: Auto(u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    for (0..100) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    const buckets = map.bucket_count;
    try testing.expectEqual(@as(usize, 100), map.count());

    for (0..100) |i| {
        try testing.expect(map.remove(@intCast(i)));
        try testing.expectEqual(99 - i, map.count());
        try testing.expectEqual(@as(?u32, null), map.get(@intCast(i)));
        try testing.expect(!map.contains(@intCast(i)));
    }
    try testing.expectEqual(@as(usize, 0), map.count());
    var iterator = map.iterator();
    try testing.expect(iterator.next() == null);

    // Refill with a disjoint key set: the empty slots left by the removals
    // are reclaimed through the normal paths, so no growth.
    for (1000..1100) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    try testing.expectEqual(buckets, map.bucket_count);
    try testing.expectEqual(@as(usize, 100), map.count());
    for (1000..1100) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
    for (0..100) |i| try testing.expectEqual(@as(?u32, null), map.get(@intCast(i)));
}

test "insertion order independence" {
    // The same key set inserted ascending, descending and LCG-permuted:
    // every key reads the same value in all three maps and contains agrees
    // on present and absent keys. Iteration order is never compared.
    const key_count = 64;
    const Map = Auto(u16, u32);
    var maps: [3]Map = .{ .empty, .empty, .empty };
    defer {
        for (&maps) |*map| map.deinit(testing.allocator);
    }

    for (&maps, 0..) |*map, order| {
        for (0..key_count) |i| {
            const key: u16 = switch (order) {
                0 => @intCast(i),
                1 => @intCast(key_count - 1 - i),
                else => @intCast((i * 37 + 11) % key_count),
            };
            try map.put(testing.allocator, key, @as(u32, key) * 3);
        }
    }

    for (0..key_count) |i| {
        const key: u16 = @intCast(i);
        for (&maps) |*map| {
            try testing.expectEqual(@as(?u32, @as(u32, key) * 3), map.get(key));
            try testing.expect(map.contains(key));
            try testing.expectEqual(@as(usize, key_count), map.count());
        }
    }
    for (key_count..key_count + 8) |i| {
        const key: u16 = @intCast(i);
        for (&maps) |*map| {
            try testing.expectEqual(@as(?u32, null), map.get(key));
            try testing.expect(!map.contains(key));
        }
    }
}

test "wrapped probe" {
    // Keys whose H1 lands in the final buckets: their probe groups read
    // past the bucket array end into the mirrored tail.
    var map: Custom(WrapHashContext, u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    // Seven keys fill the 8-bucket table; keys 7 and 15 both start in the
    // final bucket (H1 = 7), so their groups wrap.
    for ([_]u16{ 0, 1, 2, 3, 4, 7, 15 }) |key| {
        try map.put(testing.allocator, key, @as(u32, key) * 10);
    }
    try testing.expectEqual(@as(usize, 8), map.bucket_count);
    try testing.expectEqual(@as(usize, 7), map.count());

    // Remove two keys, then insert wrapped keys that reuse the tombstones
    // the wrapped probes left behind.
    try testing.expect(map.remove(0));
    try testing.expect(map.remove(2));
    try map.put(testing.allocator, 23, 230);
    try map.put(testing.allocator, 31, 310);
    try testing.expectEqual(@as(usize, 8), map.bucket_count);

    // Every present key is found and the removed ones are gone.
    for ([_]u16{ 1, 3, 4, 7, 15, 23, 31 }) |key| {
        try testing.expectEqual(@as(?u32, @as(u32, key) * 10), map.get(key));
    }
    try testing.expectEqual(@as(?u32, null), map.get(0));
    try testing.expectEqual(@as(?u32, null), map.get(2));
    try testing.expectEqual(@as(usize, 7), map.count());
}

test "tombstone reuse safety" {
    // The class the old bounded simulation falsified: new keys land on
    // tombstones that lie on pre-existing keys' probe paths, and both the
    // new and the pre-existing keys must stay findable.
    var map: Custom(NarrowHashContext, u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    // 28 keys fill a 32-bucket table; every probe starts in buckets 0..2
    // and walks forward, so the keys occupy consecutive buckets.
    for (0..28) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    try testing.expectEqual(@as(usize, 32), map.bucket_count);
    try testing.expectEqual(@as(usize, 28), map.count());

    // Remove the head of the chains: buckets 0..13 become tombstones.
    for (0..14) |i| try testing.expect(map.remove(@intCast(i)));

    // New keys whose probes cross those tombstones and land on them.
    for (1000..1014) |i| try map.put(testing.allocator, @intCast(i), @intCast(i * 10));
    try testing.expectEqual(@as(usize, 32), map.bucket_count);
    try testing.expectEqual(@as(usize, 28), map.count());

    for (1000..1014) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
    for (14..28) |i| {
        try testing.expectEqual(@as(?u32, @intCast(i * 10)), map.get(@intCast(i)));
    }
    for (0..14) |i| {
        try testing.expectEqual(@as(?u32, null), map.get(@intCast(i)));
        try testing.expect(!map.contains(@intCast(i)));
    }
}

test "capacity arithmetic exhaustiveness" {
    // For every requested capacity up to 200 the derived table holds exactly
    // bucketsToCapacity entries, keeps at least one bucket empty, and grows
    // when one more entry arrives.
    const Map = Auto(u16, u32);
    for (0..200) |requested| {
        const buckets = Map.capacityToBuckets(requested);
        try testing.expect(std.math.isPowerOfTwo(buckets));
        try testing.expect(buckets >= 8);
        try testing.expect(Map.bucketsToCapacity(buckets) >= requested);
        try testing.expect(Map.bucketsToCapacity(buckets) < buckets);

        var map: Map = .empty;
        defer map.deinit(testing.allocator);
        const cap = Map.bucketsToCapacity(buckets);
        try map.ensureTotalCapacity(testing.allocator, cap);
        try testing.expectEqual(buckets, map.bucket_count);

        for (0..cap) |i| try map.put(testing.allocator, @intCast(i), @intCast(i));
        try testing.expectEqual(cap, map.count());
        // The 7/8 load target leaves at least one bucket empty.
        try testing.expect(map.used < map.bucket_count);
        for (0..cap) |i| {
            try testing.expectEqual(@as(?u32, @intCast(i)), map.get(@intCast(i)));
        }

        // One more entry crosses the load target and doubles the table.
        try map.put(testing.allocator, @intCast(cap), @intCast(cap));
        try testing.expectEqual(buckets * 2, map.bucket_count);
        try testing.expect(map.capacity() >= cap + 1);
        for (0..cap + 1) |i| {
            try testing.expectEqual(@as(?u32, @intCast(i)), map.get(@intCast(i)));
        }
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
    @setEvalBranchQuota(1_000_000);
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
const growth_differential_items = makeDifferentialItems(200, 260);
const large_differential_items = makeDifferentialItems(1000, 1300);

/// Assert that the std reference and the swiss map hold the same entries:
/// count, per-key values and `contains` in both directions over the key
/// space, plus absent keys just past it. Iteration order is deliberately
/// never compared.
fn expectEquivalent(reference: anytype, map: anytype, comptime key_space: comptime_int) !void {
    try testing.expectEqual(@as(usize, reference.count()), map.count());

    var key: u16 = 0;
    while (key < key_space) : (key += 1) {
        try testing.expectEqual(reference.get(key), map.get(key));
        try testing.expectEqual(reference.contains(key), map.contains(key));
    }

    // Keys past the space are absent in both maps.
    key = key_space;
    while (key < key_space + 8) : (key += 1) {
        try testing.expectEqual(reference.get(key), map.get(key));
        try testing.expectEqual(reference.contains(key), map.contains(key));
    }
}

/// Run the same operation sequence against both maps, checking equivalence
/// after every step: fresh puts and overwrites (which grow the swiss map),
/// removals, getOrPut reinsertion, and interleaved remove/getOrPut for
/// tombstone reuse.
fn runDifferentialOps(
    reference: anytype,
    map: anytype,
    items: []const DifferentialItem,
    comptime key_space: comptime_int,
) !void {
    for (items) |item| {
        try reference.put(testing.allocator, item.key, item.value);
        try map.put(testing.allocator, item.key, item.value);
        try expectEquivalent(reference, map, key_space);
    }

    // Duplicate keys make this a mix of successful and failed removals.
    for (items) |item| {
        try testing.expectEqual(reference.remove(item.key), map.remove(item.key));
        try expectEquivalent(reference, map, key_space);
    }

    for (items, 0..) |item, i| {
        const reference_result = try reference.getOrPut(testing.allocator, item.key);
        const map_result = try map.getOrPut(testing.allocator, item.key);
        try testing.expectEqual(reference_result.found_existing, map_result.found_existing);
        reference_result.value_ptr.* = item.value +% 1;
        map_result.value_ptr.* = item.value +% 1;
        if (i % 3 == 0) {
            try reference.put(testing.allocator, item.key, item.value);
            try map.put(testing.allocator, item.key, item.value);
        }
        try expectEquivalent(reference, map, key_space);
    }

    // Interleave removals and getOrPut reinsertions over the same stream.
    for (items, 0..) |item, i| {
        if (i % 2 == 0) {
            try testing.expectEqual(reference.remove(item.key), map.remove(item.key));
        } else {
            const reference_result = try reference.getOrPut(testing.allocator, item.key);
            const map_result = try map.getOrPut(testing.allocator, item.key);
            try testing.expectEqual(reference_result.found_existing, map_result.found_existing);
            reference_result.value_ptr.* = item.value;
            map_result.value_ptr.* = item.value;
        }
        try expectEquivalent(reference, map, key_space);
    }
}

test "matches std.AutoHashMapUnmanaged" {
    const Reference = std.AutoHashMapUnmanaged(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var map: Auto(u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    try runDifferentialOps(&reference, &map, &differential_items, 64);
}

test "matches std with growth" {
    const Reference = std.AutoHashMapUnmanaged(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    // 200 distinct keys cross five doublings (8 buckets through 256).
    var map: Auto(u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    try runDifferentialOps(&reference, &map, &growth_differential_items, 200);
    try testing.expect(map.bucket_count >= 256);
}

test "matches std at a larger scale" {
    const Reference = std.AutoHashMapUnmanaged(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    // 1000 distinct keys cross eight doublings (8 buckets through 2048).
    var map: Auto(u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    try runDifferentialOps(&reference, &map, &large_differential_items, 1000);
    try testing.expect(map.bucket_count >= 2048);
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

    var map: Custom(NarrowHashContext, u16, u32) = .empty;
    defer map.deinit(testing.allocator);

    try runDifferentialOps(&reference, &map, &differential_items, 64);
}

test "fuzz swiss churn vs model" {
    // Native fuzzing, the fastmem convention: a fixed 128-op churn sequence
    // per iteration against std.AutoHashMapUnmanaged, decoded from one
    // smith-generated byte buffer. The 64-key space is deliberate — a large
    // space would never force the collisions, tombstone reuse and growth
    // crossings that are the point.
    const key_space = 64;
    const op_count = 128;

    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var bytes: [op_count * 2]u8 = undefined;
            smith.bytes(&bytes);

            const Reference = std.AutoHashMapUnmanaged(u16, u32);
            var reference: Reference = .empty;
            defer reference.deinit(testing.allocator);

            var map: Auto(u16, u32) = .empty;
            defer map.deinit(testing.allocator);

            var i: usize = 0;
            while (i < op_count) : (i += 1) {
                const op = bytes[i * 2];
                const key: u16 = bytes[i * 2 + 1] % key_space;
                const value: u32 = bytes[i * 2 + 1];
                switch (op % 5) {
                    0 => {
                        try reference.put(testing.allocator, key, value);
                        try map.put(testing.allocator, key, value);
                    },
                    1 => {
                        try testing.expectEqual(reference.remove(key), map.remove(key));
                    },
                    2 => {
                        const reference_result = try reference.getOrPut(testing.allocator, key);
                        const map_result = try map.getOrPut(testing.allocator, key);
                        try testing.expectEqual(
                            reference_result.found_existing,
                            map_result.found_existing,
                        );
                        reference_result.value_ptr.* = value;
                        map_result.value_ptr.* = value;
                    },
                    3 => {
                        try testing.expectEqual(reference.contains(key), map.contains(key));
                    },
                    4 => {
                        // Clear is rare by design: only when the next op also
                        // decodes to clear. A clear-heavy stream would reset
                        // the map before the churn gets deep.
                        if (i + 1 < op_count and bytes[(i + 1) * 2] % 5 == 4) {
                            reference.clearRetainingCapacity();
                            map.clearRetainingCapacity();
                            i += 1;
                        }
                    },
                    else => unreachable,
                }
                // Every sixteenth op and the final op: one full-equivalence
                // check probes the whole key space on both maps (~30x one
                // churn op), so checking after every op would spend the
                // budget on the oracle instead of on churn; every 16 still
                // catches a divergence within 16 ops of the corruption and
                // the final check closes every iteration.
                if (i % 16 == 15) try expectEquivalent(&reference, &map, key_space);
            }
            try expectEquivalent(&reference, &map, key_space);
        }
    }.run, .{
        .corpus = &.{
            "",
            // Eight distinct puts: the 8th crosses the first grow boundary.
            &.{ 0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7 },
            // Five puts then eight removes: the remove-heavy shape.
            &.{ 0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 1, 0, 1, 1, 1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7 },
        },
    });
}
