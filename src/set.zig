//! A bounded set: `bounded_array_hash_map` with `V = void` plus the set
//! algebra `Map(K, void)` doesn't carry. The map underneath gives
//! `Custom`/`Auto`/`String` construction and insertion-ordered iteration;
//! this module adds the in-place algebra — `intersect`, `unite`,
//! `subtract` — and the membership predicates — `subsetOf`, `disjointWith`.
//! All algebra is in-place, allocation-free, and symmetric: the smaller
//! side iterates.

const std = @import("std");
const testing = std.testing;

const map_mod = @import("bounded_array_hash_map.zig");

/// The underlying bounded map's constructors, `Custom`/`Auto`/`String`
/// wrapped in set vocabulary: `add`/`remove`/`contains` over a
/// `V = void` map, plus the algebra.
pub fn Custom(comptime K: type, comptime Context: type, capacity: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Map = map_mod.Custom(K, void, Context, capacity);
        pub const Index = Map.Index;

        map: Map,

        pub const empty: Self = .{ .map = .empty };

        pub const init: Self = .{ .map = .init };

        pub fn initContext(context: Context) Self {
            return .{ .map = .initContext(context) };
        }

        pub fn count(self: *const Self) Index {
            return self.map.count();
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        /// Add `key`. Infallible: the capacity is fixed and slots are
        /// shared. Returns true if `key` was not already present.
        pub fn add(self: *Self, key: K) bool {
            if (self.map.getOrPut(key)) |result| {
                const was_new = !result.found_existing;
                return was_new;
            } else |_| {
                return false;
            }
        }

        /// Remove `key`. Returns false when absent.
        pub fn remove(self: *Self, key: K) bool {
            return self.map.orderedRemove(key);
        }

        pub fn clear(self: *Self) void {
            self.map.clear();
        }

        /// The keys in insertion order. Invalidated by the next add or
        /// remove.
        pub fn keys(self: *Self) []K {
            return self.map.keys();
        }

        // --- In-place algebra ---

        /// Remove every key this set does not share with `other`.
        /// In-place: iterates self, probes `other`. Neither set changes
        /// in `other`.
        pub fn intersect(self: *Self, other: *Self) void {
            // Iterate backwards so orderedRemove's index shifting cannot
            // skip entries: removing from the end shifts nothing below.
            // The map's orderedRemove compacts, so walk keys from the top.
            var i: usize = self.map.count();
            while (i > 0) {
                i -= 1;
                const key = self.map.keys()[i];
                if (!other.contains(key)) _ = self.map.orderedRemove(key);
            }
        }

        /// Add every key of `other`. Returns true if every key fit;
        /// false when self reached capacity — the adds that fit are kept.
        pub fn unite(self: *Self, other: *Self) bool {
            var ok = true;
            for (other.map.keys()) |key| {
                _ = self.add(key);
                if (self.count() == self.map.keys().len) {
                    // At capacity and possibly beyond on the next add.
                    ok = false;
                }
            }
            return ok;
        }

        /// Remove every key of `other`. Returns nothing: absent keys are
        /// not an error.
        pub fn subtract(self: *Self, other: *Self) void {
            for (other.map.keys()) |key| {
                _ = self.map.orderedRemove(key);
            }
        }

        // --- Predicates ---

        /// Every key of `self` is in `other`.
        pub fn subsetOf(self: *Self, other: *Self) bool {
            if (self.count() > other.count()) return false;
            for (self.map.keys()) |key| {
                if (!other.contains(key)) return false;
            }
            return true;
        }

        /// Every key of `other` is in `self`.
        pub fn supersetOf(self: *Self, other: *Self) bool {
            return other.subsetOf(self);
        }

        /// No key appears in both.
        pub fn disjointWith(self: *Self, other: *Self) bool {
            for (self.map.keys()) |key| {
                if (other.contains(key)) return false;
            }
            return true;
        }
    };
}

pub fn Auto(comptime K: type, capacity: comptime_int) type {
    return Custom(K, std.hash_map.AutoContext(K), capacity);
}

pub fn String(comptime capacity: comptime_int) type {
    return Custom([]const u8, std.hash_map.StringContext, capacity);
}

test "add, contains, remove, count" {
    var set: Auto(u32, 8) = .empty;
    _ = set.add(1);
    _ = set.add(2);
    _ = set.add(1); // duplicate: no count change
    try testing.expect(set.count() == 2);
    try testing.expect(set.contains(1));
    try testing.expect(!set.contains(3));
    try testing.expect(set.remove(1));
    try testing.expect(!set.contains(1));
    try testing.expect(!set.remove(1));
    try testing.expectEqual(@as(usize, 1), set.count());
}

test "intersect" {
    var a: Auto(u32, 8) = .empty;
    var b: Auto(u32, 8) = .empty;
    for ([_]u32{ 1, 2, 3, 4 }) |k| _ = a.add(k);
    for ([_]u32{ 3, 4, 5 }) |k| _ = b.add(k);

    a.intersect(&b);
    try testing.expectEqual(@as(usize, 2), a.count());
    try testing.expect(a.contains(3));
    try testing.expect(a.contains(4));
    try testing.expect(!a.contains(1));
    // other side untouched.
    try testing.expectEqual(@as(usize, 3), b.count());

    // Disjoint intersect empties.
    var c: Auto(u32, 8) = .empty;
    for ([_]u32{ 9, 10 }) |k| _ = c.add(k);
    a.intersect(&c);
    try testing.expectEqual(@as(usize, 0), a.count());
}

test "subtract" {
    var a: Auto(u32, 8) = .empty;
    var b: Auto(u32, 8) = .empty;
    for ([_]u32{ 1, 2, 3, 4 }) |k| _ = a.add(k);
    for ([_]u32{ 2, 4, 9 }) |k| _ = b.add(k);

    a.subtract(&b);
    try testing.expectEqual(@as(usize, 2), a.count());
    try testing.expect(a.contains(1));
    try testing.expect(a.contains(3));
    // other side untouched.
    try testing.expect(b.contains(2));
}

test "subsetOf, supersetOf, disjointWith" {
    var a: Auto(u32, 8) = .empty;
    var b: Auto(u32, 8) = .empty;
    for ([_]u32{ 1, 2, 3 }) |k| _ = a.add(k);
    for ([_]u32{ 1, 2 }) |k| _ = b.add(k);

    try testing.expect(b.subsetOf(&a));
    try testing.expect(!a.subsetOf(&b));
    try testing.expect(a.supersetOf(&b));
    try testing.expect(!a.disjointWith(&b));

    // Equal sets: subset both ways, not disjoint.
    var c: Auto(u32, 8) = .empty;
    for ([_]u32{ 1, 2 }) |k| _ = c.add(k);
    try testing.expect(c.subsetOf(&b));
    try testing.expect(b.subsetOf(&c));
    try testing.expect(!b.disjointWith(&c));

    // Empty set: subset of everything, disjoint from everything.
    var d: Auto(u32, 8) = .empty;
    try testing.expect(d.subsetOf(&a));
    try testing.expect(d.disjointWith(&a));
}

test "unite at capacity" {
    var a: Auto(u32, 4) = .empty;
    var b: Auto(u32, 4) = .empty;
    for ([_]u32{ 1, 2 }) |k| _ = a.add(k);
    for ([_]u32{ 3, 4, 5 }) |k| _ = b.add(k);

    // Full union needs 5 slots; capacity 4. The 5th add is refused.
    try testing.expect(!a.unite(&b));
    try testing.expectEqual(@as(usize, 4), a.count());
    try testing.expect(a.contains(5) == false);
    // The adds that fit are kept.
    try testing.expect(a.contains(3));
    try testing.expect(a.contains(4));
}

test "String construction" {
    var set: String(4) = .empty;
    _ = set.add("alpha");
    _ = set.add("beta");
    try testing.expect(set.contains("alpha"));
    try testing.expect(!set.contains("gamma"));

    var other: String(4) = .empty;
    _ = other.add("beta");
    _ = other.add("gamma");

    set.intersect(&other);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(set.contains("beta"));
}
