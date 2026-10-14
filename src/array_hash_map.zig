//! Fixed-capacity insertion-ordered hash map: `std.AutoArrayHashMapUnmanaged`'s
//! data structure with its capacity fixed at comptime and its storage embedded
//! in the value, so no allocator is involved and insertion fails only with
//! `error.NoSpaceLeft`.
//!
//! Index-header sizing, probing and deletion are ported from Zig 0.16.0
//! `std.array_hash_map` (MIT, Zig contributors; see LICENSE-ZIG). Entries keep
//! insertion order: overwriting a key leaves its position alone, `orderedRemove`
//! compacts the entry arrays, and `swapRemove` moves the last entry into the
//! removed entry's position.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// A hash map that stores up to `buffer_capacity` key-value pairs in arrays
/// embedded in the value, indexed by `std.array_hash_map`'s open-addressed
/// header. Entries are kept in insertion order.
///
/// `Context` may follow either std convention: `std.array_hash_map`'s
/// `hash(self, K) u32` / `eql(self, K, K, usize) bool`, or `std.hash_map`'s
/// `hash(self, K) u64` / `eql(self, K, K) bool`. Hashes are narrowed to `u32`
/// internally, and each entry's hash is stored.
///
/// The parameter is named `buffer_capacity` rather than `capacity` because Zig
/// rejects a container declaration that shadows an enclosing function
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
            index: Index,
        };

        // --- Index header sizing, ported from std.array_hash_map ---

        const CapacityIndexType = enum { u8, u16, u32 };

        fn capacityIndexType(bit_index: u8) CapacityIndexType {
            if (bit_index <= 8) return .u8;
            if (bit_index <= 16) return .u16;
            assert(bit_index <= 32);
            return .u32;
        }

        /// The largest index array must fit in a usize: a power-of-two length
        /// times the size of a `u32` slot.
        const max_representable_index_len = @bitSizeOf(usize) - 4;
        const max_bit_index = @min(32, max_representable_index_len);
        const min_bit_index = 5;
        const max_capacity = (1 << max_bit_index) - 1;

        /// Usable entry count of an index array of length `1 << i`: the index
        /// is kept at most 60% full, std's load factor, so probes stay short.
        const index_capacities = blk: {
            var caps: [max_bit_index + 1]u32 = undefined;
            for (caps[0..max_bit_index], 0..) |*item, i| {
                item.* = (1 << i) * 3 / 5;
            }
            caps[max_bit_index] = max_capacity;
            break :blk caps;
        };

        /// Smallest bit index whose index array holds `desired_capacity`
        /// entries at the 60% load factor, clamped to `min_bit_index`.
        fn findBitIndex(comptime desired_capacity: usize) u8 {
            if (desired_capacity > max_capacity) {
                @compileError("buffer_capacity exceeds the largest indexable capacity");
            }
            var new_bit_index: u8 = @intCast(std.math.log2_int_ceil(usize, desired_capacity));
            if (desired_capacity > index_capacities[new_bit_index]) new_bit_index += 1;
            if (new_bit_index < min_bit_index) new_bit_index = min_bit_index;
            assert(desired_capacity <= index_capacities[new_bit_index]);
            return new_bit_index;
        }

        const header_bit_index: u8 = findBitIndex(buffer_capacity);
        const index_len: usize = @as(usize, 1) << @intCast(header_bit_index);

        /// Integer stored in one index slot: the smallest that can hold an
        /// entry index and a probe distance for this header size.
        const SlotIndex = switch (capacityIndexType(header_bit_index)) {
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
        };

        /// One slot of the open-addressed index: which entry owns it and how
        /// far the entry was displaced from its ideal slot.
        const IndexSlot = extern struct {
            entry_index: SlotIndex,
            distance_from_start_index: SlotIndex,

            /// `entry_index` value marking an empty slot.
            const empty_sentinel = ~@as(SlotIndex, 0);

            /// An empty slot. std leaves the distance undefined for empty
            /// slots; here it is zero so the embedded header is a plain
            /// constant.
            const empty: IndexSlot = .{
                .entry_index = empty_sentinel,
                .distance_from_start_index = 0,
            };

            fn isEmpty(slot: IndexSlot) bool {
                return slot.entry_index == empty_sentinel;
            }

            fn setEmpty(slot: *IndexSlot) void {
                slot.entry_index = empty_sentinel;
            }
        };

        const RemovalType = enum { swap, ordered };

        /// Keys in insertion order; only `key_buffer[0..len]` is populated.
        key_buffer: [capacity]K,
        /// Values matching `key_buffer`, in insertion order.
        value_buffer: [capacity]V,
        /// Hash of `key_buffer[i]`, so equality checks run only on hash
        /// matches (std's `store_hash = true` layout).
        hash_buffer: [capacity]u32,
        /// The open-addressed index over the entry arrays.
        index_buffer: [index_len]IndexSlot,
        /// Number of populated entries.
        len: Index,
        context: Context,

        /// A map containing no entries. The context is undefined, as in
        /// `std.PriorityQueue.empty`; use `initContext` to set it.
        pub const empty: Self = .{
            .key_buffer = undefined,
            .value_buffer = undefined,
            .hash_buffer = undefined,
            .index_buffer = @splat(IndexSlot.empty),
            .len = 0,
            .context = undefined,
        };

        /// Initialize and return a map with context.
        pub fn initContext(context: Context) Self {
            return .{
                .key_buffer = undefined,
                .value_buffer = undefined,
                .hash_buffer = undefined,
                .index_buffer = @splat(IndexSlot.empty),
                .len = 0,
                .context = context,
            };
        }

        /// Initialize and return a map with a default-initialized context.
        /// Convenience for stateless contexts such as
        /// `std.hash_map.AutoContext` and `std.array_hash_map.StringContext`;
        /// contexts that carry state must use `initContext`.
        pub fn init() Self {
            return initContext(.{});
        }

        /// Number of entries currently stored.
        pub fn count(self: *const Self) Index {
            return self.len;
        }

        /// The keys in insertion order. Writing through this slice is allowed
        /// only if it does not change key hashes or equality; the slice is
        /// invalidated by the next insertion or removal.
        pub fn keys(self: *Self) []K {
            return self.key_buffer[0..self.len];
        }

        /// The values in insertion order. The slice is invalidated by the next
        /// insertion or removal.
        pub fn values(self: *Self) []V {
            return self.value_buffer[0..self.len];
        }

        // --- Lookup ---

        /// Hash a key and narrow it to the `u32` the index arithmetic uses.
        fn contextHash(ctx: Context, key: K) u32 {
            return @truncate(ctx.hash(key));
        }

        /// Context equality, accepting both std signatures.
        fn contextEql(ctx: Context, a: K, b: K, b_index: usize) bool {
            if (comptime eqlTakesIndex(Context)) return ctx.eql(a, b, b_index);
            return ctx.eql(a, b);
        }

        /// Whether `Context.eql` takes the stored key's index, as in
        /// `std.array_hash_map`, rather than the three-argument
        /// `std.hash_map` shape.
        fn eqlTakesIndex(comptime C: type) bool {
            const Struct = switch (@typeInfo(C)) {
                .pointer => |ptr| ptr.child,
                else => C,
            };
            return @typeInfo(@TypeOf(Struct.eql)).@"fn".params.len == 4;
        }

        fn constrainIndex(index: usize) usize {
            return index & (index_len - 1);
        }

        /// Index into the entry arrays for `key`, or null.
        fn getIndex(self: *const Self, key: K) ?Index {
            const slot = self.getSlotByKey(key) orelse return null;
            return @intCast(self.index_buffer[slot].entry_index);
        }

        /// The index slot holding `key`, or null. Ported from std's
        /// `getSlotByKey`: the scan stops at an empty slot or at a slot whose
        /// displacement is smaller than the current distance, because the key
        /// would have displaced that entry if it were present.
        fn getSlotByKey(self: *const Self, key: K) ?usize {
            const h = contextHash(self.context, key);
            const start_index: usize = h;
            const end_index = start_index +% index_len;

            var index = start_index;
            var distance: SlotIndex = 0;
            while (index != end_index) : ({
                index +%= 1;
                distance += 1;
            }) {
                const slot = constrainIndex(index);
                const slot_data = self.index_buffer[slot];
                if (slot_data.isEmpty() or slot_data.distance_from_start_index < distance)
                    return null;

                const i = slot_data.entry_index;
                if (h == self.hash_buffer[i] and
                    contextEql(self.context, key, self.key_buffer[i], i))
                {
                    return slot;
                }
            }
            unreachable;
        }

        /// Value stored for `key`, or null.
        pub fn get(self: *const Self, key: K) ?V {
            const index = self.getIndex(key) orelse return null;
            return self.value_buffer[index];
        }

        /// Pointer to the value stored for `key`, or null. The pointer is
        /// invalidated by the next insertion or removal.
        pub fn getPtr(self: *Self, key: K) ?*V {
            const index = self.getIndex(key) orelse return null;
            return &self.value_buffer[index];
        }

        /// Whether `key` is stored in the map.
        pub fn contains(self: *const Self, key: K) bool {
            return self.getIndex(key) != null;
        }

        // --- Insertion ---

        /// Insert or overwrite `key`. An overwrite replaces the value in place
        /// and does not change insertion order. Returns `error.NoSpaceLeft`
        /// when the map is full and `key` is new.
        pub fn put(self: *Self, key: K, value: V) error{NoSpaceLeft}!void {
            const result = try self.getOrPut(key);
            result.value_ptr.* = value;
        }

        /// Find or insert `key`. On a full map an existing key is still found;
        /// a new key returns `error.NoSpaceLeft`. A new entry's value is
        /// undefined until the caller initializes `value_ptr`.
        pub fn getOrPut(self: *Self, key: K) error{NoSpaceLeft}!GetOrPutResult {
            if (self.len == capacity) {
                // The entry array is full. std's getOrPut still succeeds for
                // an existing key when its capacity growth fails; mirror that.
                const index = self.getIndex(key) orelse return error.NoSpaceLeft;
                return .{
                    .key_ptr = &self.key_buffer[index],
                    .value_ptr = &self.value_buffer[index],
                    .found_existing = true,
                    .index = index,
                };
            }
            return self.getOrPutAssumeCapacity(key);
        }

        /// Find or insert `key`, asserting the map is not full.
        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPutResult {
            assert(self.len < capacity);
            const result = self.getOrPutInternal(key);
            if (!result.found_existing) result.key_ptr.* = key;
            return result;
        }

        /// The insert half of `getOrPutAssumeCapacity`, ported from std's
        /// `getOrPutInternal` (the `store_hash = true` path): the robin-hood
        /// displacement keeps probe distances small, and a new key takes the
        /// first slot whose occupant is closer to its ideal slot than the new
        /// key. The key itself is not written; the caller does that.
        fn getOrPutInternal(self: *Self, key: K) GetOrPutResult {
            const h = contextHash(self.context, key);
            const start_index: usize = h;
            const end_index = start_index +% index_len;

            var index = start_index;
            var distance: SlotIndex = 0;
            while (index != end_index) : ({
                index +%= 1;
                distance += 1;
            }) {
                var slot = constrainIndex(index);
                var slot_data = self.index_buffer[slot];

                // An empty slot ends the run, so the key is new.
                if (slot_data.isEmpty()) {
                    const new_index = self.len;
                    self.len += 1;
                    self.index_buffer[slot] = .{
                        .distance_from_start_index = distance,
                        .entry_index = @intCast(new_index),
                    };
                    self.hash_buffer[new_index] = h;
                    return .{
                        .found_existing = false,
                        .key_ptr = &self.key_buffer[new_index],
                        .value_ptr = &self.value_buffer[new_index],
                        .index = new_index,
                    };
                }

                const i = slot_data.entry_index;
                if (h == self.hash_buffer[i] and
                    contextEql(self.context, key, self.key_buffer[i], i))
                {
                    return .{
                        .found_existing = true,
                        .key_ptr = &self.key_buffer[i],
                        .value_ptr = &self.value_buffer[i],
                        .index = @intCast(i),
                    };
                }

                // The occupant is closer to its ideal slot than the new key
                // would be: insert here and shift the occupant (and the rest
                // of the run) forward.
                if (slot_data.distance_from_start_index < distance) {
                    const new_index = self.len;
                    self.len += 1;
                    self.hash_buffer[new_index] = h;
                    self.index_buffer[slot] = .{
                        .entry_index = @intCast(new_index),
                        .distance_from_start_index = distance,
                    };
                    distance = slot_data.distance_from_start_index;
                    var displaced_entry_index = slot_data.entry_index;

                    index +%= 1;
                    distance += 1;
                    while (index != end_index) : ({
                        index +%= 1;
                        distance += 1;
                    }) {
                        slot = constrainIndex(index);
                        slot_data = self.index_buffer[slot];
                        if (slot_data.isEmpty()) {
                            self.index_buffer[slot] = .{
                                .entry_index = displaced_entry_index,
                                .distance_from_start_index = distance,
                            };
                            return .{
                                .found_existing = false,
                                .key_ptr = &self.key_buffer[new_index],
                                .value_ptr = &self.value_buffer[new_index],
                                .index = new_index,
                            };
                        }

                        if (slot_data.distance_from_start_index < distance) {
                            self.index_buffer[slot] = .{
                                .entry_index = displaced_entry_index,
                                .distance_from_start_index = distance,
                            };
                            displaced_entry_index = slot_data.entry_index;
                            distance = slot_data.distance_from_start_index;
                        }
                    }
                    unreachable;
                }
            }
            unreachable;
        }

        // --- Removal ---

        /// Remove `key`, shifting the entries after it forward so the
        /// insertion order of the remaining entries is preserved. Returns
        /// false when `key` is absent.
        pub fn orderedRemove(self: *Self, key: K) bool {
            return self.removeByKey(key, .ordered);
        }

        /// Remove `key` by moving the last entry into its position. O(1), but
        /// the order of the remaining entries changes: the last entry takes
        /// the removed entry's position. Returns false when `key` is absent.
        pub fn swapRemove(self: *Self, key: K) bool {
            return self.removeByKey(key, .swap);
        }

        fn removeByKey(self: *Self, key: K, comptime removal_type: RemovalType) bool {
            const slot = self.getSlotByKey(key) orelse return false;
            const entry_index: Index = @intCast(self.index_buffer[slot].entry_index);
            self.removeSlot(slot);
            self.removeFromArrayAndUpdateIndex(entry_index, removal_type);
            return true;
        }

        /// Remove `removed_slot` from the index by shifting the following
        /// colliding slots backward, so no tombstone is needed. Ported from
        /// std's `removeSlot`.
        fn removeSlot(self: *Self, removed_slot: usize) void {
            const start_index = removed_slot +% 1;
            const end_index = start_index +% index_len;

            var last_slot = removed_slot;
            var index = start_index;
            while (index != end_index) : (index +%= 1) {
                const slot = constrainIndex(index);
                const slot_data = self.index_buffer[slot];
                if (slot_data.isEmpty() or slot_data.distance_from_start_index == 0) {
                    self.index_buffer[last_slot].setEmpty();
                    return;
                }
                self.index_buffer[last_slot] = .{
                    .entry_index = slot_data.entry_index,
                    .distance_from_start_index = slot_data.distance_from_start_index - 1,
                };
                last_slot = slot;
            }
            unreachable;
        }

        /// The index slot holding the entry at `entry_index`. Asserts the
        /// entry is indexed; used to re-point slots when entries move.
        fn getSlotByIndex(self: *const Self, entry_index: Index) usize {
            const h = self.hash_buffer[entry_index];
            const start_index: usize = h;
            const end_index = start_index +% index_len;

            var index = start_index;
            var distance: SlotIndex = 0;
            while (index != end_index) : ({
                index +%= 1;
                distance += 1;
            }) {
                const slot = constrainIndex(index);
                const slot_data = self.index_buffer[slot];

                // If this assert fails, the entry was not in the index.
                assert(!slot_data.isEmpty());
                assert(slot_data.distance_from_start_index >= distance);

                if (slot_data.entry_index == entry_index) return slot;
            }
            unreachable;
        }

        fn updateEntryIndex(self: *Self, old_entry_index: Index, new_entry_index: Index) void {
            const slot = self.getSlotByIndex(old_entry_index);
            self.index_buffer[slot].entry_index = @intCast(new_entry_index);
        }

        /// Remove the entry at `entry_index` from the entry arrays, keeping
        /// the index consistent. Ported from std's
        /// `removeFromArrayAndUpdateIndex`; the slot updates run before the
        /// arrays move, because they read the old entry positions.
        fn removeFromArrayAndUpdateIndex(
            self: *Self,
            entry_index: Index,
            comptime removal_type: RemovalType,
        ) void {
            const last_index: Index = @intCast(@as(usize, self.len) - 1);
            switch (removal_type) {
                .swap => {
                    if (last_index != entry_index) {
                        // The last entry is about to move into the hole, so
                        // its slot must point at the new position first.
                        self.updateEntryIndex(last_index, entry_index);
                    }
                    self.swapRemoveAtAssumeNonEmpty(entry_index);
                },
                .ordered => {
                    var i: usize = entry_index;
                    while (i < last_index) : (i += 1) {
                        self.updateEntryIndex(@intCast(i + 1), @intCast(i));
                    }
                    self.orderedRemoveAtAssumeNonEmpty(entry_index);
                },
            }
        }

        fn swapRemoveAtAssumeNonEmpty(self: *Self, entry_index: Index) void {
            const last_index: usize = @as(usize, self.len) - 1;
            self.key_buffer[entry_index] = self.key_buffer[last_index];
            self.value_buffer[entry_index] = self.value_buffer[last_index];
            self.hash_buffer[entry_index] = self.hash_buffer[last_index];
            self.len = @intCast(last_index);
        }

        fn orderedRemoveAtAssumeNonEmpty(self: *Self, entry_index: Index) void {
            var i: usize = entry_index;
            while (i + 1 < self.len) : (i += 1) {
                self.key_buffer[i] = self.key_buffer[i + 1];
                self.value_buffer[i] = self.value_buffer[i + 1];
                self.hash_buffer[i] = self.hash_buffer[i + 1];
            }
            self.len = @intCast(i);
        }

        /// Remove all entries, keeping the storage. The map is immediately
        /// reusable.
        pub fn clear(self: *Self) void {
            self.len = 0;
            @memset(&self.index_buffer, IndexSlot.empty);
        }

        // --- Iteration ---

        pub const Iterator = struct {
            map: *Self,
            index: Index,

            /// The next entry in insertion order, or null.
            pub fn next(it: *Iterator) ?Entry {
                if (it.index >= it.map.len) return null;
                const i = it.index;
                it.index += 1;
                return .{
                    .key_ptr = &it.map.key_buffer[i],
                    .value_ptr = &it.map.value_buffer[i],
                };
            }

            /// Reset the iterator to the first entry.
            pub fn reset(it: *Iterator) void {
                it.index = 0;
            }
        };

        /// An iterator over the entries in insertion order. Modifying the map
        /// invalidates it.
        pub fn iterator(self: *Self) Iterator {
            return .{ .map = self, .index = 0 };
        }
    };
}

/// A `BoundedWith` that hashes keys with std's default context.
///
/// Plain auto-hashable key types need no context argument. `[]const u8` keys
/// route to `std.array_hash_map.StringContext`, which hashes string contents
/// (std's `StringArrayHashMapUnmanaged` choice): `std.hash_map.AutoContext`
/// rejects slices outright, so it cannot be the default for strings. Other key
/// types use `std.hash_map.AutoContext(K)`; slices inside a key type, or any
/// type `std.hash.autoHash` refuses, still need an explicit context through
/// `BoundedWith`.
pub fn Bounded(
    comptime K: type,
    comptime V: type,
    buffer_capacity: comptime_int,
) type {
    return BoundedWith(
        if (K == []const u8) std.array_hash_map.StringContext else std.hash_map.AutoContext(K),
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
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 30, 10, 20 }, map.values());

    // An overwrite replaces the value in place: the position is untouched.
    try map.put(1, 11);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 30, 11, 20 }, map.values());
    try testing.expectEqual(@as(?u32, 11), map.get(1));
    try testing.expectEqual(@as(usize, 3), @as(usize, map.count()));

    // Full map: a new key fails, an existing key still overwrites.
    try map.put(4, 40);
    try testing.expectError(error.NoSpaceLeft, map.put(5, 50));
    try map.put(3, 33);
    try testing.expectEqual(@as(?u32, 33), map.get(3).?);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2, 4 }, map.keys());
    try testing.expectEqual(@as(usize, 4), @as(usize, map.count()));

    // A removal frees both an entry and an index slot for reuse.
    try testing.expect(map.swapRemove(3));
    try map.put(5, 50);
    try testing.expectEqual(@as(?u32, 50), map.get(5));
    try testing.expectEqual(@as(?u32, null), map.get(3));
    try testing.expectEqual(@as(usize, 4), @as(usize, map.count()));
}

test "getOrPut" {
    var map = Bounded(u32, u32, 4).initContext(.{});

    const gop1 = try map.getOrPut(7);
    try testing.expect(!gop1.found_existing);
    try testing.expectEqual(@as(usize, 0), @as(usize, gop1.index));
    try testing.expectEqual(@as(u32, 7), gop1.key_ptr.*);
    gop1.value_ptr.* = 70;
    try testing.expectEqual(@as(?u32, 70), map.get(7));

    const gop2 = try map.getOrPut(7);
    try testing.expect(gop2.found_existing);
    try testing.expectEqual(@as(u32, 70), gop2.value_ptr.*);
    gop2.value_ptr.* = 71;
    try testing.expectEqual(@as(?u32, 71), map.get(7));
    try testing.expectEqual(@as(usize, 1), @as(usize, map.count()));

    // getOrPutAssumeCapacity is the non-failing half.
    const gop3 = map.getOrPutAssumeCapacity(8);
    try testing.expect(!gop3.found_existing);
    gop3.value_ptr.* = 80;
    try testing.expectEqual(@as(?u32, 80), map.get(8));

    // Full map: an existing key is found, a new key is NoSpaceLeft.
    try map.put(1, 1);
    try map.put(2, 2);
    const gop4 = try map.getOrPut(2);
    try testing.expect(gop4.found_existing);
    try testing.expectEqual(@as(u32, 2), gop4.value_ptr.*);
    try testing.expectError(error.NoSpaceLeft, map.getOrPut(9));
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

test "orderedRemove" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try map.put(3, 30);
    try map.put(1, 10);
    try map.put(2, 20);

    // Missing key: false, map untouched.
    try testing.expect(!map.orderedRemove(9));
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, map.keys());

    // Middle: the remaining entries keep their relative order.
    try testing.expect(map.orderedRemove(1));
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 30, 20 }, map.values());
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expect(!map.contains(1));
    try testing.expect(!map.orderedRemove(1));

    // First, then last.
    try testing.expect(map.orderedRemove(3));
    try testing.expectEqualSlices(u32, &.{2}, map.keys());
    try testing.expect(map.orderedRemove(2));
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));
    try testing.expect(!map.orderedRemove(2));

    // The map is reusable after emptying.
    try map.put(5, 50);
    try testing.expectEqual(@as(?u32, 50), map.get(5));
}

test "swapRemove" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try map.put(3, 30);
    try map.put(1, 10);
    try map.put(2, 20);

    // Middle: the last entry moves into the hole, so the order changes.
    try testing.expect(map.swapRemove(1));
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 30, 20 }, map.values());
    try testing.expectEqual(@as(?u32, null), map.get(1));

    // First: the last entry takes position 0.
    try map.put(1, 10);
    try testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, map.keys());
    try testing.expect(map.swapRemove(3));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 10, 20 }, map.values());
    try testing.expectEqual(@as(?u32, null), map.get(3));

    // Last: removing the final entry only shrinks.
    try map.put(3, 30);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, map.keys());
    try testing.expect(map.swapRemove(3));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, map.keys());

    // Missing key.
    try testing.expect(!map.swapRemove(9));

    // Empty it out.
    try testing.expect(map.swapRemove(1));
    try testing.expect(map.swapRemove(2));
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));
    try testing.expect(!map.swapRemove(1));
}

test "iterator" {
    var map = Bounded(u32, u32, 8).initContext(.{});

    // Empty map: next() is null immediately.
    var empty_iterator = map.iterator();
    try testing.expect(empty_iterator.next() == null);

    try map.put(4, 40);
    try map.put(2, 20);
    try map.put(7, 70);

    const expected_keys = [_]u32{ 4, 2, 7 };
    const expected_values = [_]u32{ 40, 20, 70 };
    var iterator = map.iterator();
    var n: usize = 0;
    while (iterator.next()) |entry| : (n += 1) {
        try testing.expectEqual(expected_keys[n], entry.key_ptr.*);
        try testing.expectEqual(expected_values[n], entry.value_ptr.*);
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(iterator.next() == null);

    // reset() rewinds to the first entry.
    iterator.reset();
    try testing.expectEqual(@as(u32, 4), iterator.next().?.key_ptr.*);
    iterator.reset();
    n = 0;
    while (iterator.next()) |entry| : (n += 1) {
        try testing.expectEqual(expected_keys[n], entry.key_ptr.*);
    }
    try testing.expectEqual(@as(usize, 3), n);

    // Overwriting does not disturb iteration order.
    try map.put(2, 22);
    iterator.reset();
    try testing.expectEqual(@as(u32, 4), iterator.next().?.key_ptr.*);
    try testing.expectEqual(@as(u32, 22), iterator.next().?.value_ptr.*);
    try testing.expectEqual(@as(u32, 7), iterator.next().?.key_ptr.*);

    // The iterator observes removals and compaction.
    try testing.expect(map.orderedRemove(4));
    iterator.reset();
    try testing.expectEqual(@as(u32, 2), iterator.next().?.key_ptr.*);
    try testing.expectEqual(@as(u32, 7), iterator.next().?.key_ptr.*);
    try testing.expect(iterator.next() == null);
}

test "keys" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try testing.expectEqualSlices(u32, &.{}, map.keys());
    try testing.expectEqualSlices(u32, &.{}, map.values());

    try map.put(2, 20);
    try map.put(1, 10);
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 20, 10 }, map.values());

    // The slices alias the map's storage: a write through values() is
    // visible to get().
    map.values()[0] = 21;
    try testing.expectEqual(@as(?u32, 21), map.get(2));
    try testing.expectEqual(@as(u32, 2), map.keys()[0]);

    try map.put(3, 30);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 3 }, map.keys());
    try testing.expectEqualSlices(u32, &.{ 21, 10, 30 }, map.values());
}

test "clear" {
    var map = Bounded(u32, u32, 4).initContext(.{});
    try map.put(1, 10);
    try map.put(2, 20);

    map.clear();
    try testing.expectEqual(@as(usize, 0), @as(usize, map.count()));
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expectEqual(@as(?u32, null), map.get(2));
    try testing.expectEqualSlices(u32, &.{}, map.keys());
    var iterator = map.iterator();
    try testing.expect(iterator.next() == null);

    // The map is reusable at full capacity, and lookups after reuse see no
    // stale index entries.
    var i: u32 = 0;
    while (i < 4) : (i += 1) try map.put(i, i * 10);
    try testing.expectEqual(@as(usize, 4), @as(usize, map.count()));
    try testing.expectError(error.NoSpaceLeft, map.put(4, 40));
    i = 0;
    while (i < 4) : (i += 1) {
        try testing.expectEqual(@as(?u32, i * 10), map.get(i));
    }
    try testing.expectEqual(@as(?u32, null), map.get(4));

    map.clear();
    try testing.expectEqual(@as(?u32, null), map.get(0));
    try map.put(9, 90);
    try testing.expectEqual(@as(?u32, 90), map.get(9));
}

test "capacity boundaries" {
    inline for ([_]comptime_int{ 1, 2, 3, 4 }) |n| {
        const Map = Bounded(u32, u32, n);
        var map = Map.initContext(.{});
        try testing.expect(Map.Index == std.math.IntFittingRange(0, n));
        try testing.expectEqual(@as(usize, n), @as(usize, Map.capacity));

        var i: usize = 0;
        while (i < n) : (i += 1) {
            try map.put(@intCast(i), @intCast(i));
            try testing.expectEqual(i + 1, @as(usize, map.count()));
        }
        try testing.expectError(error.NoSpaceLeft, map.put(@intCast(n), 0));

        // Overwrite at capacity still works, and remove-then-put reuses the
        // freed slot.
        try map.put(0, 99);
        try testing.expectEqual(@as(?u32, 99), map.get(0));
        try testing.expect(map.orderedRemove(0));
        try map.put(@intCast(n), @intCast(n));
        try testing.expectEqual(@as(?u32, @intCast(n)), map.get(@intCast(n)));
        try testing.expectEqual(@as(usize, n), @as(usize, map.count()));
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
    try testing.expectEqualSlices(u32, &.{ 2, 1, 3 }, set.keys());
    try testing.expectEqual(@as(usize, 3), set.values().len);

    const gop = try set.getOrPut(4);
    try testing.expect(!gop.found_existing);
    gop.value_ptr.* = {};
    try testing.expect(set.contains(4));
    try testing.expectError(error.NoSpaceLeft, set.getOrPut(5));

    // void values still iterate.
    var iterator = set.iterator();
    var n: usize = 0;
    while (iterator.next()) |entry| : (n += 1) {
        _ = entry.value_ptr.*;
    }
    try testing.expectEqual(@as(usize, 4), n);

    try testing.expect(set.orderedRemove(1));
    try testing.expect(!set.contains(1));
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, set.keys());
    try testing.expect(set.swapRemove(2));
    try testing.expectEqualSlices(u32, &.{ 4, 3 }, set.keys());
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
    try testing.expectEqualSlices(u16, &.{ 3, 1 }, integers.keys());

    // []const u8 keys route to std.array_hash_map.StringContext because
    // std.hash_map.AutoContext rejects slices.
    var strings = Bounded([]const u8, u32, 4).initContext(.{});
    try strings.put("one", 1);
    try strings.put("two", 2);
    try strings.put("one", 11);
    try testing.expectEqual(@as(?u32, 11), strings.get("one"));
    try testing.expectEqual(@as(?u32, 2), strings.get("two"));
    try testing.expectEqual(@as(?u32, null), strings.get("three"));
    try testing.expectEqual(@as(usize, 2), @as(usize, strings.count()));
    try testing.expectEqualStrings("one", strings.keys()[0]);
    try testing.expectEqualStrings("two", strings.keys()[1]);
    try testing.expect(strings.orderedRemove("one"));
    try testing.expectEqual(@as(usize, 1), @as(usize, strings.count()));
    try testing.expectEqualStrings("two", strings.keys()[0]);
}

/// A stateful context: the salt changes where keys land in the header, so a
/// map's behavior depends on the context stored in the value.
const SaltContext = struct {
    salt: u32,

    pub fn hash(self: SaltContext, key: u32) u32 {
        return (key *% 0x9e3779b1) ^ self.salt;
    }

    pub fn eql(self: SaltContext, a: u32, b: u32, b_index: usize) bool {
        _ = self;
        _ = b_index;
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
    fn hash(self: PointContext, point: Point) u32 {
        _ = self;
        return @bitCast(point.x ^ point.y);
    }

    fn eql(self: PointContext, a: Point, b: Point, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return a.x == b.x and a.y == b.y;
    }
};

test "custom context" {
    var salted = BoundedWith(SaltContext, u32, u32, 4).initContext(.{ .salt = 0x1234 });
    try salted.put(1, 10);
    try salted.put(2, 20);
    try testing.expectEqual(@as(?u32, 10), salted.get(1));
    try testing.expectEqual(@as(?u32, 20), salted.get(2));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, salted.keys());
    try testing.expect(salted.orderedRemove(1));
    try testing.expectEqual(@as(?u32, null), salted.get(1));
    try testing.expectEqualSlices(u32, &.{2}, salted.keys());

    var points = BoundedWith(PointContext, Point, u32, 4).initContext(.{});
    try points.put(.{ .x = 1, .y = 2 }, 12);
    try points.put(.{ .x = 2, .y = 1 }, 21);
    try points.put(.{ .x = 1, .y = 2 }, 99);
    try testing.expectEqual(@as(?u32, 99), points.get(.{ .x = 1, .y = 2 }));
    try testing.expectEqual(@as(?u32, 21), points.get(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, null), points.get(.{ .x = 3, .y = 3 }));
    try testing.expectEqual(@as(usize, 2), @as(usize, points.count()));
    try testing.expect(points.swapRemove(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, null), points.get(.{ .x = 2, .y = 1 }));
    try testing.expectEqual(@as(?u32, 99), points.get(.{ .x = 1, .y = 2 }));
}

/// A context whose hash maps every key into one of three starting slots, so
/// the differential run below probes long collision runs and exercises
/// backward-shift deletion rather than the sparse case.
const NarrowHashContext = struct {
    pub fn hash(self: NarrowHashContext, key: u16) u32 {
        _ = self;
        return key % 3;
    }

    pub fn eql(self: NarrowHashContext, a: u16, b: u16, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return a == b;
    }
};

/// A context where every key hashes to slot 0: one maximal collision run, the
/// harshest case for backward-shift deletion.
const AllCollideContext = struct {
    pub fn hash(self: AllCollideContext, key: u32) u32 {
        _ = self;
        _ = key;
        return 0;
    }

    pub fn eql(self: AllCollideContext, a: u32, b: u32, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return a == b;
    }
};

test "deletion under collisions" {
    const Map = BoundedWith(AllCollideContext, u32, u32, 32);
    var map = Map.initContext(.{});

    // Every key lands in the same run, at increasing probe distances.
    for (0..24) |i| {
        try map.put(@intCast(i), @intCast(i * 10));
    }
    try testing.expectEqual(@as(usize, 24), @as(usize, map.count()));

    // Remove every third key from the middle of the run, ordered.
    var key: u32 = 0;
    while (key < 24) : (key += 3) {
        try testing.expect(map.orderedRemove(key));
        try testing.expectEqual(@as(?u32, null), map.get(key));
        try testing.expect(!map.contains(key));
    }

    // Every remaining key must still be found with its value; no phantoms.
    key = 0;
    while (key < 24) : (key += 1) {
        if (key % 3 == 0) {
            try testing.expectEqual(@as(?u32, null), map.get(key));
        } else {
            try testing.expectEqual(@as(?u32, key * 10), map.get(key));
        }
    }
    try testing.expectEqual(@as(usize, 16), @as(usize, map.count()));

    // The same for swap removal, which moves the last entry into the hole and
    // must repoint that entry's slot.
    var swap_map = Map.initContext(.{});
    for (0..24) |i| {
        try swap_map.put(@intCast(i), @intCast(i * 10));
    }
    key = 1;
    while (key < 24) : (key += 3) {
        try testing.expect(swap_map.swapRemove(key));
        try testing.expectEqual(@as(?u32, null), swap_map.get(key));
    }
    key = 0;
    while (key < 24) : (key += 1) {
        if (key % 3 == 1) {
            try testing.expectEqual(@as(?u32, null), swap_map.get(key));
        } else {
            try testing.expectEqual(@as(?u32, key * 10), swap_map.get(key));
        }
    }
    try testing.expectEqual(@as(usize, 16), @as(usize, swap_map.count()));

    // Refill the holes and re-verify everything.
    for (0..24) |i| {
        try map.put(@intCast(i), @intCast(i * 10));
    }
    for (0..24) |i| {
        try testing.expectEqual(@as(?u32, @as(u32, @intCast(i)) * 10), map.get(@intCast(i)));
    }
    try testing.expectEqual(@as(usize, 24), @as(usize, map.count()));
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

/// Assert that `bounded` and the std reference hold the same entries in the
/// same order: count, key set, per-key values, `keys()`/`values()` and
/// iterator output.
fn expectEquivalent(reference: anytype, bounded: anytype, comptime key_space: comptime_int) !void {
    try testing.expectEqual(reference.count(), @as(usize, bounded.count()));
    try testing.expectEqualSlices(u16, reference.keys(), bounded.keys());
    try testing.expectEqualSlices(u32, reference.values(), bounded.values());

    var key: u16 = 0;
    while (key < key_space) : (key += 1) {
        try testing.expectEqual(reference.get(key), bounded.get(key));
        try testing.expectEqual(reference.contains(key), bounded.contains(key));
    }

    var reference_iterator = reference.iterator();
    var bounded_iterator = bounded.iterator();
    while (reference_iterator.next()) |reference_entry| {
        const bounded_entry = bounded_iterator.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(reference_entry.key_ptr.*, bounded_entry.key_ptr.*);
        try testing.expectEqual(reference_entry.value_ptr.*, bounded_entry.value_ptr.*);
    }
    try testing.expect(bounded_iterator.next() == null);
}

/// Run the same operation sequence against both maps, checking equivalence
/// after every step: fresh puts and overwrites, alternating ordered and swap
/// removals, getOrPut reinsertion, and interleaved remove/put for slot reuse.
/// Asserts that the sequence actually fills the map, so the full-map paths are
/// covered.
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
        if (reference.count() == capacity) reached_capacity = true;
        try expectEquivalent(reference, bounded, key_space);
    }
    try testing.expect(reached_capacity);

    // Duplicate keys make this a mix of successful and failed removals.
    for (items, 0..) |item, i| {
        const reference_removed = if (i % 2 == 0)
            reference.orderedRemove(item.key)
        else
            reference.swapRemove(item.key);
        const bounded_removed = if (i % 2 == 0)
            bounded.orderedRemove(item.key)
        else
            bounded.swapRemove(item.key);
        try testing.expectEqual(reference_removed, bounded_removed);
        try expectEquivalent(reference, bounded, key_space);
    }

    for (items, 0..) |item, i| {
        const reference_gop = try reference.getOrPut(testing.allocator, item.key);
        const bounded_gop = try bounded.getOrPut(item.key);
        try testing.expectEqual(reference_gop.found_existing, bounded_gop.found_existing);
        try testing.expectEqual(reference_gop.index, @as(usize, bounded_gop.index));
        reference_gop.value_ptr.* = item.value +% 1;
        bounded_gop.value_ptr.* = item.value +% 1;
        if (i % 3 == 0) {
            try reference.put(testing.allocator, item.key, item.value);
            try bounded.put(item.key, item.value);
        }
        try expectEquivalent(reference, bounded, key_space);
    }

    for (items, 0..) |item, i| {
        const reference_removed = if (i % 3 == 0)
            reference.swapRemove(item.key)
        else
            reference.orderedRemove(item.key);
        const bounded_removed = if (i % 3 == 0)
            bounded.swapRemove(item.key)
        else
            bounded.orderedRemove(item.key);
        try testing.expectEqual(reference_removed, bounded_removed);
        try reference.put(testing.allocator, item.key, item.value +% 2);
        try bounded.put(item.key, item.value +% 2);
        try expectEquivalent(reference, bounded, key_space);
    }
}

test "matches std.AutoArrayHashMapUnmanaged" {
    // std.AutoArrayHashMapUnmanaged is the deprecated alias of
    // std.array_hash_map.Auto; the public Bounded uses the
    // std.hash_map auto context, whose hashes agree with std's array hash map
    // context after the internal narrowing to u32.
    const Reference = std.array_hash_map.Auto(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var bounded = Bounded(u16, u32, 64).initContext(.{});
    try runDifferentialOps(64, 64, &reference, &bounded, &differential_items);
}

test "matches std at a large capacity" {
    // Capacity 200 needs a 512-slot index, so the slot type widens from u8 to
    // u16 and the probe arithmetic instantiates on a different integer type.
    const Reference = std.array_hash_map.Auto(u16, u32);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var bounded = Bounded(u16, u32, 200).initContext(.{});
    try runDifferentialOps(200, 200, &reference, &bounded, &large_differential_items);
}

test "collision-heavy differential against std" {
    const Reference = std.array_hash_map.Custom(u16, u32, NarrowHashContext, true);
    var reference: Reference = .empty;
    defer reference.deinit(testing.allocator);

    var bounded = BoundedWith(NarrowHashContext, u16, u32, 64).initContext(.{});
    try runDifferentialOps(64, 64, &reference, &bounded, &differential_items);
}
