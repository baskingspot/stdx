//! A fixed-capacity least-recently-used cache.
//!
//! `String(V, capacity)` and `Auto(K, V, capacity)` store up to `capacity`
//! entries with no allocator. `get` moves a hit to the front; `put` evicts the
//! least-recently-used entry when a new key arrives at capacity.
//!
//! The index is a `bounded_array_hash_map` from key to node slot. The nodes
//! live in one array and form an intrusive doubly linked list with integer
//! links, not pointers. `get` only relinks, so a hit is constant time and no
//! entry data moves.
//!
//! A value pointer from `get` or `peek` keeps its address for the cache's
//! lifetime. Once its entry is removed, a later `put` can reuse the node, so
//! the old pointer then refers to the new value.
//!
//! Eviction is the caller's job to clean up. `put` returns the displaced
//! entry, either the old value for an existing key or the entry evicted for a
//! new one. `popLru` and `popMru` return a whole entry. There is no eviction
//! callback: a callback could reenter the cache while it is mid-update.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;
const AutoContext = std.hash_map.AutoContext;
const StringContext = std.hash_map.StringContext;

const bounded_array_hash_map = @import("bounded_array_hash_map.zig");

/// A bounded LRU with `Custom`'s hash context.
pub fn Custom(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    buffer_capacity: comptime_int,
) type {
    return struct {
        const Self = @This();

        comptime {
            if (buffer_capacity < 1) @compileError("lru: buffer_capacity must be at least 1");
        }

        const NodeIndex = std.math.IntFittingRange(0, buffer_capacity);
        pub const Map = bounded_array_hash_map.Custom(K, NodeIndex, Context, buffer_capacity);
        pub const Index = Map.Index;
        pub const capacity = Map.capacity;

        pub const Entry = struct {
            key: K,
            value: V,
        };

        pub const Item = struct {
            key: K,
            value: *V,
        };

        pub const PutResult = struct {
            replaced: ?V = null,
            evicted: ?Entry = null,
        };

        const none = math.maxInt(Index);

        const Node = struct {
            entry: Entry,
            prev: Index,
            next: Index,
        };

        map: Map,
        nodes: [buffer_capacity]Node,
        head: Index,
        tail: Index,
        free_head: Index,
        next_free: Index,

        pub const empty: Self = .{
            .map = .empty,
            .nodes = undefined,
            .head = none,
            .tail = none,
            .free_head = none,
            .next_free = 0,
        };

        pub fn initContext(context: Context) Self {
            return .{
                .map = .initContext(context),
                .nodes = undefined,
                .head = none,
                .tail = none,
                .free_head = none,
                .next_free = 0,
            };
        }

        /// Number of cached entries.
        pub fn count(self: *const Self) Index {
            return self.map.count();
        }

        /// Whether `key` is cached. Does not change recency.
        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        /// The value for `key`, moved to the most-recently-used position.
        pub fn get(self: *Self, key: K) ?*V {
            const index = self.map.get(key) orelse return null;
            self.moveToFront(index);
            return &self.nodes[index].entry.value;
        }

        /// The value for `key`, without changing recency.
        pub fn peek(self: *Self, key: K) ?*V {
            const index = self.map.get(key) orelse return null;
            return &self.nodes[index].entry.value;
        }

        /// Insert or update `key`. An update moves the entry to the front and
        /// returns the old value in `replaced`. A new key at capacity evicts
        /// the tail and returns it in `evicted`.
        pub fn put(self: *Self, key: K, value: V) PutResult {
            if (self.map.get(key)) |index| {
                const old = self.nodes[index].entry.value;
                self.nodes[index].entry.value = value;
                self.moveToFront(index);
                return .{ .replaced = old };
            }

            var result: PutResult = .{};
            const index: Index = if (self.map.count() == capacity) evict: {
                const tail = self.tail;
                assert(tail != none);
                const entry = self.nodes[tail].entry;
                assert(self.map.swapRemove(entry.key));
                self.unlink(tail);
                result.evicted = entry;
                break :evict tail;
            } else self.allocNode();

            const slot = self.map.getOrPutAssumeCapacity(key);
            assert(!slot.found_existing);
            slot.value_ptr.* = index;
            self.nodes[index] = .{
                .entry = .{ .key = key, .value = value },
                .prev = none,
                .next = none,
            };
            self.linkFront(index);
            return result;
        }

        /// Remove `key` and return its value.
        pub fn remove(self: *Self, key: K) ?V {
            const index = self.map.get(key) orelse return null;
            const value = self.nodes[index].entry.value;
            assert(self.map.swapRemove(key));
            self.unlink(index);
            self.freeNode(index);
            return value;
        }

        /// Remove and return the least-recently-used entry.
        pub fn popLru(self: *Self) ?Entry {
            if (self.tail == none) return null;
            return self.popIndex(self.tail);
        }

        /// Remove and return the most-recently-used entry.
        pub fn popMru(self: *Self) ?Entry {
            if (self.head == none) return null;
            return self.popIndex(self.head);
        }

        /// Drop every entry, keeping the storage. The values are not returned;
        /// drain with the iterator first when `V` owns resources.
        pub fn clear(self: *Self) void {
            self.map.clear();
            self.head = none;
            self.tail = none;
            self.free_head = none;
            self.next_free = 0;
        }

        pub const Iterator = struct {
            cache: *Self,
            index: Index,

            /// The next entry from most to least recently used, or null.
            pub fn next(self: *Iterator) ?Item {
                if (self.index == none) return null;
                const index = self.index;
                self.index = self.cache.nodes[index].next;
                return .{
                    .key = self.cache.nodes[index].entry.key,
                    .value = &self.cache.nodes[index].entry.value,
                };
            }

            /// Restart at the most-recently-used entry.
            pub fn reset(self: *Iterator) void {
                self.index = self.cache.head;
            }
        };

        /// An iterator from most to least recently used. Modify the cache
        /// during iteration only through the returned value pointers: `get`,
        /// `put`, `remove`, and `clear` invalidate the iterator.
        pub fn iterator(self: *Self) Iterator {
            return .{ .cache = self, .index = self.head };
        }

        fn popIndex(self: *Self, index: Index) Entry {
            const entry = self.nodes[index].entry;
            assert(self.map.swapRemove(entry.key));
            self.unlink(index);
            self.freeNode(index);
            return entry;
        }

        fn allocNode(self: *Self) Index {
            if (self.free_head != none) {
                const index = self.free_head;
                self.free_head = self.nodes[index].next;
                return index;
            }
            assert(self.next_free < capacity);
            const index = self.next_free;
            self.next_free += 1;
            return index;
        }

        fn freeNode(self: *Self, index: Index) void {
            self.nodes[index].next = self.free_head;
            self.free_head = index;
        }

        fn linkFront(self: *Self, index: Index) void {
            self.nodes[index].prev = none;
            self.nodes[index].next = self.head;
            if (self.head == none) {
                self.tail = index;
            } else {
                self.nodes[self.head].prev = index;
            }
            self.head = index;
        }

        fn unlink(self: *Self, index: Index) void {
            const prev = self.nodes[index].prev;
            const next = self.nodes[index].next;
            if (prev == none) {
                self.head = next;
            } else {
                self.nodes[prev].next = next;
            }
            if (next == none) {
                self.tail = prev;
            } else {
                self.nodes[next].prev = prev;
            }
        }

        fn moveToFront(self: *Self, index: Index) void {
            if (self.head == index) return;
            self.unlink(index);
            self.linkFront(index);
        }
    };
}

pub fn Auto(comptime K: type, comptime V: type, buffer_capacity: comptime_int) type {
    return Custom(K, V, AutoContext(K), buffer_capacity);
}

pub fn String(comptime V: type, buffer_capacity: comptime_int) type {
    return Custom([]const u8, V, StringContext, buffer_capacity);
}

test "put, get, eviction, and replacement" {
    const Cache = String(u32, 2);
    var cache: Cache = .empty;

    try testing.expectEqual(@as(usize, 0), cache.count());
    var result = cache.put("a", 1);
    try testing.expectEqual(@as(?u32, null), result.replaced);
    try testing.expect(result.evicted == null);
    result = cache.put("b", 2);
    try testing.expect(result.evicted == null);
    try testing.expectEqual(@as(u32, 1), cache.get("a").?.*);

    result = cache.put("a", 10);
    try testing.expectEqual(@as(?u32, 1), result.replaced);
    try testing.expect(result.evicted == null);
    try testing.expectEqual(@as(u32, 10), cache.peek("a").?.*);

    result = cache.put("c", 3);
    try testing.expectEqualStrings("b", result.evicted.?.key);
    try testing.expectEqual(@as(u32, 2), result.evicted.?.value);
    try testing.expectEqual(@as(usize, 2), cache.count());
    try testing.expect(cache.contains("a"));
    try testing.expect(cache.contains("c"));
    try testing.expect(!cache.contains("b"));
}

test "peek does not change recency" {
    const Cache = String(u32, 2);
    var cache: Cache = .empty;
    _ = cache.put("a", 1);
    _ = cache.put("b", 2);
    try testing.expectEqual(@as(u32, 1), cache.peek("a").?.*);

    const result = cache.put("c", 3);
    try testing.expectEqualStrings("a", result.evicted.?.key);
}

test "remove, popLru, and popMru" {
    const Cache = String(u32, 3);
    var cache: Cache = .empty;
    _ = cache.put("a", 1);
    _ = cache.put("b", 2);
    _ = cache.put("c", 3);

    try testing.expectEqual(@as(?u32, 2), cache.remove("b"));
    try testing.expect(cache.remove("b") == null);
    try testing.expectEqualStrings("a", cache.popLru().?.key);
    try testing.expectEqualStrings("c", cache.popMru().?.key);
    try testing.expectEqual(@as(usize, 0), cache.count());
    try testing.expect(cache.popLru() == null);
    try testing.expect(cache.popMru() == null);
}

test "iterator walks from most to least recent" {
    const Cache = String(u32, 3);
    var cache: Cache = .empty;
    _ = cache.put("a", 1);
    _ = cache.put("b", 2);
    _ = cache.put("c", 3);
    _ = cache.get("a");

    var it = cache.iterator();
    try testing.expectEqualStrings("a", it.next().?.key);
    try testing.expectEqualStrings("c", it.next().?.key);
    try testing.expectEqualStrings("b", it.next().?.key);
    try testing.expect(it.next() == null);

    it.reset();
    const first = it.next().?;
    try testing.expectEqualStrings("a", first.key);
    first.value.* += 1;
    try testing.expectEqual(@as(u32, 2), cache.peek("a").?.*);
}

test "clear keeps the cache reusable" {
    const Cache = String(u32, 2);
    var cache: Cache = .empty;
    _ = cache.put("a", 1);
    _ = cache.put("b", 2);
    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.count());
    try testing.expectEqual(@as(?*u32, null), cache.get("a"));
    _ = cache.put("c", 3);
    try testing.expectEqual(@as(u32, 3), cache.get("c").?.*);
}

test "capacity one" {
    const Cache = String(u32, 1);
    var cache: Cache = .empty;
    _ = cache.put("a", 1);
    const result = cache.put("b", 2);
    try testing.expectEqualStrings("a", result.evicted.?.key);
    try testing.expectEqual(@as(usize, 1), cache.count());
    try testing.expectEqual(@as(u32, 2), cache.get("b").?.*);
}

test "auto keys and void values" {
    var ints: Auto(u32, u32, 2) = .empty;
    _ = ints.put(1, 10);
    _ = ints.put(2, 20);
    try testing.expectEqual(@as(u32, 10), ints.get(1).?.*);

    var set: String(void, 2) = .empty;
    _ = set.put("a", {});
    try testing.expect(set.get("a") != null);
    const result = set.put("b", {});
    try testing.expect(result.replaced == null);
    try testing.expect(result.evicted == null);
}

const Model = struct {
    const Item = struct { key: u32, value: u32 };
    const PutResult = struct {
        replaced: ?u32 = null,
        evicted: ?Item = null,
    };

    items: [8]Item = undefined,
    len: usize = 0,

    fn indexOf(self: *Model, key: u32) ?usize {
        for (self.items[0..self.len], 0..) |item, i| {
            if (item.key == key) return i;
        }
        return null;
    }

    fn moveToFront(self: *Model, index: usize) void {
        const item = self.items[index];
        var i = index;
        while (i > 0) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[0] = item;
    }

    fn put(self: *Model, key: u32, value: u32) PutResult {
        if (self.indexOf(key)) |index| {
            const old = self.items[index].value;
            self.items[index].value = value;
            self.moveToFront(index);
            return .{ .replaced = old };
        }

        var result: PutResult = .{};
        if (self.len == self.items.len) {
            result.evicted = self.items[self.len - 1];
            self.len -= 1;
        }
        var i = self.len;
        while (i > 0) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[0] = .{ .key = key, .value = value };
        self.len += 1;
        return result;
    }

    fn get(self: *Model, key: u32) ?u32 {
        const index = self.indexOf(key) orelse return null;
        const value = self.items[index].value;
        self.moveToFront(index);
        return value;
    }

    fn peek(self: *Model, key: u32) ?u32 {
        const index = self.indexOf(key) orelse return null;
        return self.items[index].value;
    }

    fn remove(self: *Model, key: u32) ?u32 {
        const index = self.indexOf(key) orelse return null;
        const value = self.items[index].value;
        var i = index;
        while (i + 1 < self.len) : (i += 1) self.items[i] = self.items[i + 1];
        self.len -= 1;
        return value;
    }

    fn popLru(self: *Model) ?Item {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items[self.len];
    }

    fn popMru(self: *Model) ?Item {
        if (self.len == 0) return null;
        const item = self.items[0];
        var i: usize = 0;
        while (i + 1 < self.len) : (i += 1) self.items[i] = self.items[i + 1];
        self.len -= 1;
        return item;
    }

    fn contains(self: *Model, key: u32) bool {
        return self.indexOf(key) != null;
    }
};

test "differential against a recency list" {
    const Cache = Auto(u32, u32, 8);
    var cache: Cache = .empty;
    var model: Model = .{};
    var seed: u64 = 0x9e3779b97f4a7c15;

    var step: usize = 0;
    while (step < 5000) : (step += 1) {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        const key: u32 = @truncate(seed % 16);
        const value: u32 = @truncate(seed >> 32);

        switch (seed % 10) {
            0, 1, 2, 3 => {
                const got = cache.put(key, value);
                const want = model.put(key, value);
                try testing.expectEqual(want.replaced, got.replaced);
                if (want.evicted) |entry| {
                    try testing.expect(got.evicted != null);
                    try testing.expectEqual(entry.key, got.evicted.?.key);
                    try testing.expectEqual(entry.value, got.evicted.?.value);
                } else {
                    try testing.expect(got.evicted == null);
                }
            },
            4 => {
                const got = cache.get(key);
                const want = model.get(key);
                if (want) |v| {
                    try testing.expectEqual(v, got.?.*);
                } else {
                    try testing.expect(got == null);
                }
            },
            5 => {
                const got = cache.peek(key);
                const want = model.peek(key);
                if (want) |v| {
                    try testing.expectEqual(v, got.?.*);
                } else {
                    try testing.expect(got == null);
                }
            },
            6 => {
                try testing.expectEqual(model.remove(key), cache.remove(key));
            },
            7 => {
                const got = cache.popLru();
                const want = model.popLru();
                if (want) |entry| {
                    try testing.expect(got != null);
                    try testing.expectEqual(entry.key, got.?.key);
                    try testing.expectEqual(entry.value, got.?.value);
                } else {
                    try testing.expect(got == null);
                }
            },
            8 => {
                const got = cache.popMru();
                const want = model.popMru();
                if (want) |entry| {
                    try testing.expect(got != null);
                    try testing.expectEqual(entry.key, got.?.key);
                    try testing.expectEqual(entry.value, got.?.value);
                } else {
                    try testing.expect(got == null);
                }
            },
            9 => {
                try testing.expectEqual(model.contains(key), cache.contains(key));
            },
            else => unreachable,
        }

        try testing.expectEqual(@as(usize, model.len), cache.count());
        var it = cache.iterator();
        var i: usize = 0;
        while (it.next()) |item| : (i += 1) {
            try testing.expectEqual(model.items[i].key, item.key);
            try testing.expectEqual(model.items[i].value, item.value.*);
        }
        try testing.expectEqual(model.len, i);
    }
}
