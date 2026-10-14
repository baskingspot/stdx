//! Fixed-capacity priority queue: the binary heap of `std.PriorityQueue` with
//! its capacity fixed at comptime and its storage embedded in the value. No
//! allocator is involved, so insertion fails only with `error.NoSpaceLeft`.
//!
//! The heap logic and public surface mirror std's: `compareFn` returns
//! `Order.lt` when its second argument should be popped before its third,
//! `iterator` walks storage order without consuming the queue, and
//! `initContext` carries the comparator's context. Like std's `empty`, the
//! `empty` value leaves the context undefined; use `initContext` whenever the
//! comparator dereferences it.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;
const Order = math.Order;

/// A priority queue that stores up to `buffer_capacity` elements in a
/// `[buffer_capacity]T` array embedded in the value.
///
/// The parameter is named `buffer_capacity` rather than `capacity` because
/// Zig rejects a container declaration that shadows an enclosing function
/// parameter; the bound is exposed as the `capacity` constant instead.
pub fn Custom(
    comptime T: type,
    comptime Context: type,
    buffer_capacity: comptime_int,
    comptime compareFn: fn (context: Context, a: T, b: T) Order,
) type {
    return struct {
        const Self = @This();

        /// Smallest integer type that can hold `0..capacity`.
        pub const Index = math.IntFittingRange(0, buffer_capacity);

        /// Maximum number of elements the queue can hold.
        pub const capacity: Index = @intCast(buffer_capacity);

        buffer: [capacity]T,
        len: Index,
        context: Context,

        /// A priority queue containing no elements. The context is undefined,
        /// as in `std.PriorityQueue.empty`; use `initContext` to set it.
        pub const empty: Self = .{
            .buffer = undefined,
            .len = 0,
            .context = undefined,
        };

        /// Initialize and return a priority queue with context.
        pub fn initContext(context: Context) Self {
            return .{ .buffer = undefined, .len = 0, .context = context };
        }

        /// Insert `elem`, maintaining priority. Returns `error.NoSpaceLeft`
        /// when the queue is already at capacity.
        pub fn push(self: *Self, elem: T) error{NoSpaceLeft}!void {
            if (self.len == capacity) return error.NoSpaceLeft;
            self.pushAssumeCapacity(elem);
        }

        /// Insert `elem`, maintaining priority. Asserts that the queue is not
        /// at capacity.
        pub fn pushAssumeCapacity(self: *Self, elem: T) void {
            assert(self.len < capacity);
            self.buffer[self.len] = elem;
            self.len += 1;
            self.siftUp(self.len - 1);
        }

        /// Add each element in `items`, maintaining priority. All or nothing:
        /// the capacity check precedes every insertion, so on
        /// `error.NoSpaceLeft` the queue is untouched. This mirrors std's
        /// `pushSlice`, which reserves capacity up front.
        pub fn pushSlice(self: *Self, items: []const T) error{NoSpaceLeft}!void {
            const remaining: usize = capacity - self.len;
            if (items.len > remaining) return error.NoSpaceLeft;
            for (items) |elem| self.pushAssumeCapacity(elem);
        }

        /// Look at the highest priority element. Returns `null` if empty;
        /// does not modify the queue.
        pub fn peek(self: *const Self) ?T {
            return if (self.len > 0) self.buffer[0] else null;
        }

        /// Remove and return the highest priority element. Returns `null` if
        /// empty.
        pub fn pop(self: *Self) ?T {
            return if (self.len > 0) self.popIndex(0) else null;
        }

        /// Remove and return the element at `index`. Indices follow iterator
        /// order, which is not necessarily priority order. Asserts that
        /// `index < count()`.
        pub fn popIndex(self: *Self, index: usize) T {
            assert(self.len > index);
            const i: Index = @intCast(index);
            const last = self.buffer[self.len - 1];
            const item = self.buffer[i];
            self.buffer[i] = last;
            self.len -= 1;

            const new_len: usize = self.len;
            if (index == new_len) {
                // Last element removed, nothing more to do.
            } else if (index == 0) {
                self.siftDown(0);
            } else {
                const parent_index: Index = @intCast((@as(usize, i) - 1) >> 1);
                const parent = self.buffer[parent_index];
                if (compareFn(self.context, last, parent) == .gt) {
                    self.siftDown(i);
                } else {
                    self.siftUp(i);
                }
            }

            return item;
        }

        /// Number of elements currently in the queue.
        pub fn count(self: *const Self) Index {
            return self.len;
        }

        /// Remove all elements. The capacity is unchanged, so the queue can be
        /// refilled immediately.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Replace the first element that compares equal to `elem` with
        /// `new_elem`, maintaining priority. Returns `error.ElementNotFound`
        /// if no stored element compares equal to `elem`.
        pub fn update(self: *Self, elem: T, new_elem: T) error{ElementNotFound}!void {
            const update_index: Index = blk: {
                const len: usize = self.len;
                var idx: usize = 0;
                while (idx < len) : (idx += 1) {
                    if (compareFn(self.context, self.buffer[idx], elem) == .eq) {
                        break :blk @intCast(idx);
                    }
                }
                return error.ElementNotFound;
            };
            const old_elem = self.buffer[update_index];
            self.buffer[update_index] = new_elem;
            switch (compareFn(self.context, new_elem, old_elem)) {
                .lt => self.siftUp(update_index),
                .gt => self.siftDown(update_index),
                .eq => {}, // Equal priority: the heap property still holds.
            }
        }

        pub const Iterator = struct {
            queue: *Custom(T, Context, buffer_capacity, compareFn),
            index: Index,

            pub fn next(it: *Iterator) ?T {
                if (it.index >= it.queue.len) return null;
                const out = it.queue.buffer[it.index];
                it.index += 1;
                return out;
            }

            pub fn reset(it: *Iterator) void {
                it.index = 0;
            }
        };

        /// Return an iterator over the stored elements. Like std's, it walks
        /// storage order (not priority order) without consuming the queue;
        /// any modification invalidates it.
        pub fn iterator(self: *Self) Iterator {
            return .{ .queue = self, .index = 0 };
        }

        fn siftUp(self: *Self, start_index: Index) void {
            const child = self.buffer[start_index];
            var child_index = start_index;
            while (child_index > 0) {
                const parent_index: Index = @intCast((@as(usize, child_index) - 1) >> 1);
                const parent = self.buffer[parent_index];
                if (compareFn(self.context, child, parent) != .lt) break;
                self.buffer[child_index] = parent;
                child_index = parent_index;
            }
            self.buffer[child_index] = child;
        }

        fn siftDown(self: *Self, target_index: Index) void {
            const target_element = self.buffer[target_index];
            const len: usize = self.len;
            var index: usize = target_index;
            while (true) {
                var lesser_child_i = (math.mul(usize, index, 2) catch break) | 1;
                if (!(lesser_child_i < len)) break;

                const next_child_i = lesser_child_i + 1;
                if (next_child_i < len and
                    compareFn(
                        self.context,
                        self.buffer[next_child_i],
                        self.buffer[lesser_child_i],
                    ) == .lt)
                {
                    lesser_child_i = next_child_i;
                }

                if (compareFn(self.context, target_element, self.buffer[lesser_child_i]) == .lt) {
                    break;
                }

                self.buffer[index] = self.buffer[lesser_child_i];
                index = lesser_child_i;
            }
            self.buffer[index] = target_element;
        }
    };
}

fn minOrder(context: void, a: u32, b: u32) Order {
    _ = context;
    return math.order(a, b);
}

fn maxOrder(context: void, a: u32, b: u32) Order {
    _ = context;
    return math.order(a, b).invert();
}

fn equalOrder(context: void, a: u32, b: u32) Order {
    _ = context;
    _ = a;
    _ = b;
    return .eq;
}

const Small = Custom(u32, void, 4, minOrder);
const MaxHeap = Custom(u32, void, 8, maxOrder);

test Custom {
    // Pushed ascending: a min-heap pops them back in ascending order.
    var ascending: Small = .empty;
    try ascending.pushSlice(&.{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(?u32, 1), ascending.peek());
    try testing.expectEqual(@as(?u32, 1), ascending.peek());
    try testing.expectEqual(@as(Small.Index, 4), ascending.count());
    for ([_]u32{ 1, 2, 3, 4 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), ascending.pop());
    }
    try testing.expectEqual(@as(?u32, null), ascending.pop());
    try testing.expectEqual(@as(?u32, null), ascending.peek());

    // Pushed descending: the pops still come out ascending.
    var descending: Small = .empty;
    try descending.pushSlice(&.{ 4, 3, 2, 1 });
    for ([_]u32{ 1, 2, 3, 4 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), descending.pop());
    }

    // Max-heap comparator: the same pushes pop in the opposite order.
    var maxed: MaxHeap = .empty;
    try maxed.pushSlice(&.{ 4, 3, 2, 1 });
    for ([_]u32{ 4, 3, 2, 1 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), maxed.pop());
    }

    // All elements compare equal: every pushed value is still retrievable.
    var equal: Small = .empty;
    try equal.pushSlice(&.{ 7, 7, 7, 7 });
    try testing.expectEqual(@as(Small.Index, 4), equal.count());
    var popped: usize = 0;
    while (equal.pop()) |elem| : (popped += 1) {
        try testing.expectEqual(@as(u32, 7), elem);
    }
    try testing.expectEqual(@as(usize, 4), popped);
    try testing.expectEqual(@as(?u32, null), equal.peek());

    // pushAssumeCapacity fills exactly up to the boundary.
    var assumed: Small = .empty;
    assumed.pushAssumeCapacity(4);
    assumed.pushAssumeCapacity(3);
    assumed.pushAssumeCapacity(2);
    assumed.pushAssumeCapacity(1);
    try testing.expectEqual(@as(Small.Index, 4), assumed.count());
    try testing.expectError(error.NoSpaceLeft, assumed.push(0));

    // A full queue rejects both push and pushSlice.
    try testing.expectError(error.NoSpaceLeft, assumed.pushSlice(&.{0}));
    try testing.expectError(error.NoSpaceLeft, assumed.pushSlice(&.{ 0, 1 }));
    try testing.expectEqual(@as(Small.Index, 4), assumed.count());

    // pushSlice that does not fit leaves the queue untouched.
    var partial: Small = .empty;
    try partial.pushSlice(&.{ 3, 1 });
    try testing.expectError(error.NoSpaceLeft, partial.pushSlice(&.{ 5, 4, 2 }));
    try testing.expectEqual(@as(Small.Index, 2), partial.count());
    try testing.expectEqual(@as(?u32, 1), partial.pop());
    try testing.expectEqual(@as(?u32, 3), partial.pop());
    try testing.expectEqual(@as(?u32, null), partial.pop());

    // clear resets the queue without touching its capacity.
    try partial.pushSlice(&.{ 9, 8 });
    partial.clear();
    try testing.expectEqual(@as(Small.Index, 0), partial.count());
    try testing.expectEqual(@as(?u32, null), partial.peek());
    try testing.expectEqual(@as(?u32, null), partial.pop());
    try testing.expectEqual(@as(Small.Index, 4), Small.capacity);
    try partial.pushSlice(&.{ 9, 8, 7, 6 });
    try testing.expectEqual(@as(Small.Index, 4), partial.count());
    try testing.expectError(error.NoSpaceLeft, partial.push(5));
    for ([_]u32{ 6, 7, 8, 9 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), partial.pop());
    }
}

test "capacity boundaries" {
    inline for ([_]comptime_int{ 1, 2, 3, 4 }) |n| {
        const Queue = Custom(u32, void, n, minOrder);
        var queue: Queue = .empty;
        try testing.expectEqual(@as(usize, n), @as(usize, Queue.capacity));

        var pushed: usize = 0;
        var value: u32 = @intCast(n);
        while (value > 0) : (value -= 1) {
            try queue.push(value);
            pushed += 1;
            try testing.expectEqual(pushed, @as(usize, queue.count()));
        }
        try testing.expectEqual(@as(usize, n), @as(usize, queue.count()));
        try testing.expectError(error.NoSpaceLeft, queue.push(0));

        value = 1;
        while (value <= n) : (value += 1) {
            try testing.expectEqual(@as(?u32, value), queue.pop());
        }
        try testing.expectEqual(@as(?u32, null), queue.pop());
    }
}

/// Deterministic pseudo-shuffled input (an LCG run at comptime), with
/// duplicates so that tie handling is compared too.
const differential_items = blk: {
    var items: [64]u32 = undefined;
    var state: u32 = 0x2545f491;
    for (&items) |*item| {
        state = state *% 1664525 +% 1013904223;
        item.* = state >> 16;
    }
    break :blk items;
};

/// Push `items` into a `std.PriorityQueue` and a `Custom` with
/// the same element type, context and comparator, then assert the two drain
/// identically — first from the full queues, then after refilling and
/// interleaving pops and pushes.
fn expectMatchesStd(
    comptime T: type,
    comptime Context: type,
    comptime compareFn: fn (context: Context, a: T, b: T) Order,
    comptime buffer_capacity: comptime_int,
    context: Context,
    items: []const T,
) !void {
    const gpa = testing.allocator;
    const Reference = std.PriorityQueue(T, Context, compareFn);
    const Queue = Custom(T, Context, buffer_capacity, compareFn);

    var reference: Reference = .initContext(context);
    defer reference.deinit(gpa);
    var bounded: Queue = .initContext(context);

    for (items) |elem| {
        try reference.push(gpa, elem);
        try bounded.push(elem);
    }
    try testing.expectEqual(reference.count(), @as(usize, bounded.count()));
    try testing.expectEqual(reference.peek(), bounded.peek());

    var drained: usize = 0;
    while (reference.pop()) |expected| : (drained += 1) {
        try testing.expectEqual(expected, bounded.pop().?);
    }
    try testing.expectEqual(items.len, drained);
    try testing.expectEqual(@as(?T, null), bounded.pop());

    // Refill both, then interleave pops and pushes. Every operation must
    // leave the two queues element-for-element identical.
    for (items) |elem| {
        try reference.push(gpa, elem);
        try bounded.push(elem);
    }
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        try testing.expectEqual(reference.pop(), bounded.pop());
        try reference.push(gpa, items[i]);
        try bounded.push(items[i]);
    }
    while (reference.pop()) |expected| {
        try testing.expectEqual(expected, bounded.pop().?);
    }
    try testing.expectEqual(@as(?T, null), bounded.pop());
}

test "matches std.PriorityQueue" {
    try expectMatchesStd(u32, void, minOrder, differential_items.len, {}, &differential_items);
    try expectMatchesStd(u32, void, maxOrder, differential_items.len, {}, &differential_items);
}

test "popIndex" {
    // Single element: index 0 is also the last storage slot.
    var single: Custom(u32, void, 1, minOrder) = .empty;
    try single.push(7);
    try testing.expectEqual(@as(u32, 7), single.popIndex(0));
    try testing.expectEqual(@as(?u32, null), single.pop());

    // Root: popIndex(0) is pop.
    var root: Custom(u32, void, 5, minOrder) = .empty;
    try root.pushSlice(&.{ 5, 1, 4, 2, 3 });
    try testing.expectEqual(@as(u32, 1), root.popIndex(0));
    for ([_]u32{ 2, 3, 4, 5 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), root.pop());
    }

    // Middle: locate an index through the iterator, remove it, and the
    // remaining heap still pops in priority order.
    var middle: Custom(u32, void, 7, minOrder) = .empty;
    try middle.pushSlice(&.{ 2, 1, 8, 9, 3, 4, 5 });
    var it = middle.iterator();
    var index: usize = 0;
    var two_index: usize = undefined;
    while (it.next()) |elem| : (index += 1) {
        if (elem == 2) {
            two_index = index;
            break;
        }
    }
    try testing.expectEqual(@as(u32, 2), middle.popIndex(two_index));
    for ([_]u32{ 1, 3, 4, 5, 8, 9 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), middle.pop());
    }
    try testing.expectEqual(@as(?u32, null), middle.pop());

    // Last: remove the final storage slot. The iterator says which element
    // that is; the survivors still drain in priority order.
    const Three = Custom(u32, void, 3, minOrder);
    var last: Three = .empty;
    try last.pushSlice(&.{ 3, 1, 2 });
    var storage: [3]u32 = undefined;
    var n: usize = 0;
    var last_it = last.iterator();
    while (last_it.next()) |elem| : (n += 1) storage[n] = elem;
    try testing.expectEqual(storage[2], last.popIndex(2));
    try testing.expectEqual(@as(usize, 2), @as(usize, last.count()));
    var survivors = [_]u32{ storage[0], storage[1] };
    std.mem.sort(u32, &survivors, {}, std.sort.asc(u32));
    for (survivors) |elem| {
        try testing.expectEqual(@as(?u32, elem), last.pop());
    }
    try testing.expectEqual(@as(?u32, null), last.pop());
}

test "update" {
    // Min-heap: decreasing a key sifts up, increasing it sifts down.
    var min: Custom(u32, void, 8, minOrder) = .empty;
    try min.pushSlice(&.{ 55, 44, 11 });
    try min.update(55, 5); // decrease -> sift up
    try min.update(11, 66); // increase -> sift down
    try min.update(44, 44); // equal priority -> no move
    for ([_]u32{ 5, 44, 66 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), min.pop());
    }
    try testing.expectError(error.ElementNotFound, min.update(5, 6));

    // Max-heap: the directions invert; increasing a key sifts up.
    var max: MaxHeap = .empty;
    try max.pushSlice(&.{ 55, 44, 11 });
    try max.update(55, 66); // increase -> sift up
    try max.update(11, 1); // decrease -> sift down
    for ([_]u32{ 66, 44, 1 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), max.pop());
    }

    // Equal-comparing elements: the first match is replaced.
    var dup: Small = .empty;
    try dup.pushSlice(&.{ 1, 1, 2, 2 });
    try dup.update(1, 5);
    try dup.update(2, 4);
    for ([_]u32{ 1, 2, 4, 5 }) |elem| {
        try testing.expectEqual(@as(?u32, elem), dup.pop());
    }
    try testing.expectError(error.ElementNotFound, dup.update(4, 5));
}

const RankTable = struct {
    ranks: [16]u32,
};

fn rankOrder(context: *const RankTable, a: usize, b: usize) Order {
    return math.order(context.ranks[a], context.ranks[b]);
}

const RankedQueue = Custom(usize, *const RankTable, 16, rankOrder);

test "update with context" {
    const table: RankTable = .{
        .ranks = .{ 5, 3, 4, 2, 8, 9, 0, 7, 1, 6, 10, 11, 12, 13, 14, 15 },
    };
    var queue: RankedQueue = .initContext(&table);

    // Elements are indices; the comparator dereferences the context table,
    // so the index order alone would pop 0, 1, 2, ...
    var i: usize = 0;
    while (i < 7) : (i += 1) try queue.push(i);
    try testing.expectEqual(@as(?usize, 6), queue.peek());

    try queue.update(0, 7); // rank 5 -> 7: increase, sift down
    try queue.update(5, 8); // rank 9 -> 1: decrease, sift up
    try testing.expectError(error.ElementNotFound, queue.update(15, 3));

    for ([_]usize{ 6, 8, 3, 1, 2, 7, 4 }) |elem| {
        try testing.expectEqual(@as(?usize, elem), queue.pop());
    }
    try testing.expectEqual(@as(?usize, null), queue.pop());
}

test "iterator" {
    // Empty queue: next() is null immediately.
    var empty: Small = .empty;
    var empty_it = empty.iterator();
    try testing.expectEqual(@as(?u32, null), empty_it.next());

    // std semantics: the iterator walks storage order without consuming the
    // queue. Collect its output, then rewind with reset() and get the same
    // sequence again.
    var queue: Small = .empty;
    try queue.pushSlice(&.{ 4, 3, 2, 1 });
    var first: [4]u32 = undefined;
    var n: usize = 0;
    var it = queue.iterator();
    while (it.next()) |elem| : (n += 1) first[n] = elem;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(Small.Index, 4), queue.count());
    try testing.expectEqual(@as(?u32, null), it.next());

    it.reset();
    var second: [4]u32 = undefined;
    n = 0;
    while (it.next()) |elem| : (n += 1) second[n] = elem;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u32, &first, &second);

    // The iterator reports the same multiset that pop() drains.
    var sorted_iter: [4]u32 = first;
    std.mem.sort(u32, &sorted_iter, {}, std.sort.asc(u32));
    var popped: [4]u32 = undefined;
    n = 0;
    while (queue.pop()) |elem| : (n += 1) popped[n] = elem;
    try testing.expectEqualSlices(u32, &sorted_iter, &popped);

    // For a min-heap filled in ascending order the backing array is already
    // priority order, so the iterator's drain equals the pop order exactly.
    var ascending: Small = .empty;
    try ascending.pushSlice(&.{ 1, 2, 3, 4 });
    var iterated: [4]u32 = undefined;
    n = 0;
    var ascending_it = ascending.iterator();
    while (ascending_it.next()) |elem| : (n += 1) iterated[n] = elem;
    var drained: [4]u32 = undefined;
    n = 0;
    while (ascending.pop()) |elem| : (n += 1) drained[n] = elem;
    try testing.expectEqualSlices(u32, &drained, &iterated);
}

const Event = struct {
    priority: u32,
    seq: u32,
};

fn eventOrder(context: void, a: Event, b: Event) Order {
    _ = context;
    return switch (math.order(a.priority, b.priority)) {
        .eq => math.order(a.seq, b.seq),
        else => |order| order,
    };
}

test "struct elements" {
    const events = [_]Event{
        .{ .priority = 3, .seq = 0 },
        .{ .priority = 1, .seq = 2 },
        .{ .priority = 2, .seq = 1 },
        .{ .priority = 1, .seq = 1 },
        .{ .priority = 3, .seq = 1 },
        .{ .priority = 2, .seq = 0 },
    };
    const CustomEvents = Custom(Event, void, events.len, eventOrder);

    // Same comparator and sequence as std's queue: drains must be identical.
    try expectMatchesStd(Event, void, eventOrder, events.len, {}, &events);

    // The field comparison drives the order, ties broken by `seq`.
    var queue: CustomEvents = .empty;
    try queue.pushSlice(&events);
    const expected = [_]Event{
        .{ .priority = 1, .seq = 1 },
        .{ .priority = 1, .seq = 2 },
        .{ .priority = 2, .seq = 0 },
        .{ .priority = 2, .seq = 1 },
        .{ .priority = 3, .seq = 0 },
        .{ .priority = 3, .seq = 1 },
    };
    for (expected) |elem| {
        try testing.expectEqual(elem, queue.pop().?);
    }
    try testing.expectEqual(@as(?Event, null), queue.pop());
}

test "equal comparator" {
    const Equal = Custom(u32, void, 4, equalOrder);
    var queue: Equal = .empty;
    try queue.pushSlice(&.{ 3, 1, 4, 2 });
    try testing.expectEqual(@as(usize, 4), @as(usize, queue.count()));
    var seen: u32 = 0;
    while (queue.pop()) |elem| {
        // Every element must be one of the four pushed values, each once.
        try testing.expect(elem >= 1 and elem <= 4);
        seen |= @as(u32, 1) << @intCast(elem);
    }
    try testing.expectEqual(@as(u32, 0b11110), seen);
    try testing.expectEqual(@as(?u32, null), queue.peek());
}
