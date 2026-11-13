//! A fixed-capacity pool of caller-owned entries: O(1) acquire and release,
//! an intrusive doubly linked list over the live entries, and a free list that
//! costs no memory.
//!
//! The links live inside the entry, in two fields the caller names at comptime,
//! so walking the live set reads only the entries it visits. That is the point
//! of the shape: a table of a thousand entries with a handful live costs one
//! cache line per live entry to walk, not one per stored entry.
//!
//! The link fields carry the handle type. Any unsigned integer works, and the
//! type decides how many entries fit: `u32` holds four billion, and a narrow
//! type such as `std.math.IntFittingRange` packs a small table. Both fields
//! must have the same type. The type's maximum value is the "no neighbor"
//! sentinel, so the capacity is at most that value.
//!
//! Two constructors, one implementation:
//!
//! - `Pool(Entry, "prev", "next")` holds a `[]Entry` given at `init`, for a
//!   capacity known at runtime, such as a connection table sized from config.
//! - `Array(Entry, "prev", "next", n)` owns an `[n]Entry`, for a capacity
//!   known at comptime. A `Pool` value holds a slice, so it must not be copied;
//!   the owning form is what a self-contained value uses.
//!
//! `acquire` returns a handle and links the entry at the back of the list.
//! `release` takes the handle back. The handle is the entry's index, so a
//! caller recovers the index by keeping the handle, never by pointer arithmetic
//! on a `*Entry`. `get` returns the entry for a handle.
//!
//! The list order is the caller's. A pool that never reorders iterates in
//! acquisition order, and `moveToFront` reorders, which is how a
//! recency-ordered cache is built on top (`lru` is).
//!
//! The free list is lazy: the first acquisitions come from the entries in index
//! order, and released handles go on a stack in front of them. Nothing walks
//! the storage at `init`, so `empty` is a plain value. A free entry points
//! `prev` at its own handle, so releasing the same handle twice trips an assert
//! in a safe build instead of handing the slot to two callers.
//!
//! The pool owns the link fields and the caller owns everything else. An
//! acquired entry is not cleared, and the pool never writes a field other than
//! the two links.
//!
//! Not thread-safe.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

/// Reject an entry that cannot carry the links, before anything else runs.
fn validate(
    comptime Entry: type,
    comptime prev_field: []const u8,
    comptime next_field: []const u8,
) void {
    if (@typeInfo(Entry) != .@"struct") {
        @compileError("slot: Entry must be a struct, found " ++ @typeName(Entry));
    }
    if (prev_field.len == 0 or next_field.len == 0) {
        @compileError("slot: the link field names must be nonempty");
    }
    if (mem.eql(u8, prev_field, next_field)) {
        @compileError("slot: prev and next must name different fields");
    }
    for ([_][]const u8{ prev_field, next_field }) |name| {
        if (!@hasField(Entry, name)) {
            @compileError("slot: Entry has no field named " ++ name);
        }
        const Link = @FieldType(Entry, name);
        switch (@typeInfo(Link)) {
            .int => |info| if (info.signedness != .unsigned) {
                @compileError(
                    "slot: Entry." ++ name ++ " must be unsigned, found " ++ @typeName(Link),
                );
            },
            else => @compileError(
                "slot: Entry." ++ name ++ " must be an unsigned integer, found " ++ @typeName(Link),
            ),
        }
    }
    if (@FieldType(Entry, prev_field) != @FieldType(Entry, next_field)) {
        @compileError(
            "slot: Entry." ++ prev_field ++ " and Entry." ++ next_field ++ " must share one type",
        );
    }
}

/// The handle type, list, free list, and iterator for one entry type. Both
/// constructors wrap it; no code below this line is duplicated.
fn Core(
    comptime Entry: type,
    comptime prev_field: []const u8,
    comptime next_field: []const u8,
) type {
    return struct {
        /// The type of both link fields, read from the entry.
        pub const Handle = @FieldType(Entry, prev_field);

        /// No neighbor: the head's `prev`, the tail's `next`, and the end of
        /// the free list. One above the highest legal handle.
        pub const none: Handle = math.maxInt(Handle);

        /// Where `acquireFront` and `acquire` link a newly taken entry.
        const Place = enum { back, front };

        /// The bookkeeping, without the entries.
        pub const State = struct {
            /// First live entry.
            used_head: Handle,
            /// Last live entry.
            used_tail: Handle,
            /// Most recently released entry, in front of `next_free`.
            free_head: Handle,
            /// Entries below this index have been acquired at least once. The
            /// rest are untouched and free.
            next_free: Handle,
            /// Number of live entries.
            live: usize,

            /// Nothing live, nothing acquired.
            pub const empty: State = .{
                .used_head = none,
                .used_tail = none,
                .free_head = none,
                .next_free = 0,
                .live = 0,
            };

            /// Take a free entry and link it at the back. Returns
            /// `error.NoSpaceLeft` when every entry is live.
            pub fn acquire(self: *State, entries: anytype) error{NoSpaceLeft}!Handle {
                if (self.free_head == none and self.next_free >= entries.len) {
                    return error.NoSpaceLeft;
                }
                return self.acquireAssumeCapacity(entries);
            }

            /// `acquire` without the error return. Asserts an entry is free.
            pub fn acquireAssumeCapacity(self: *State, entries: anytype) Handle {
                return self.takeFree(entries, .back);
            }

            /// Take a free entry and link it at the front of the list.
            pub fn acquireFront(self: *State, entries: anytype) error{NoSpaceLeft}!Handle {
                if (self.free_head == none and self.next_free >= entries.len) {
                    return error.NoSpaceLeft;
                }
                return self.takeFree(entries, .front);
            }

            /// `acquireFront` without the error return. Asserts an entry is
            /// free.
            pub fn acquireFrontAssumeCapacity(self: *State, entries: anytype) Handle {
                return self.takeFree(entries, .front);
            }

            fn takeFree(self: *State, entries: anytype, comptime place: Place) Handle {
                const handle = if (self.free_head != none) blk: {
                    const free = self.free_head;
                    self.free_head = @field(entries[free], next_field);
                    break :blk free;
                } else blk: {
                    assert(self.next_free < entries.len);
                    const fresh = self.next_free;
                    self.next_free += 1;
                    break :blk fresh;
                };
                switch (place) {
                    .back => self.linkAtBack(entries, handle),
                    .front => self.linkAtFront(entries, handle),
                }
                self.live += 1;
                return handle;
            }

            /// Return `handle` to the free list. Asserts `handle` is live.
            pub fn release(self: *State, entries: anytype, handle: Handle) void {
                assert(handle < self.next_free);
                assert(@field(entries[handle], prev_field) != handle);
                self.unlink(entries, handle);

                // A free entry points at itself, and threads the free stack
                // through `next`.
                @field(entries[handle], prev_field) = handle;
                @field(entries[handle], next_field) = self.free_head;
                self.free_head = handle;
                self.live -= 1;
            }

            /// Move a live entry to the front of the list.
            pub fn moveToFront(self: *State, entries: anytype, handle: Handle) void {
                if (self.used_head == handle) return;
                self.unlink(entries, handle);
                self.linkAtFront(entries, handle);
            }

            /// Remove the front entry and release its handle.
            pub fn popFront(self: *State, entries: anytype) ?Entry {
                if (self.used_head == none) return null;
                return self.popAt(entries, self.used_head);
            }

            /// Remove the back entry and release its handle.
            pub fn popBack(self: *State, entries: anytype) ?Entry {
                if (self.used_tail == none) return null;
                return self.popAt(entries, self.used_tail);
            }

            /// Whether `handle` is live. An out-of-range or never-acquired
            /// handle is not.
            pub fn isLive(self: *const State, entries: []const Entry, handle: Handle) bool {
                // `next_free` never exceeds the capacity, so this also catches
                // an out-of-range handle before the index below.
                if (handle >= self.next_free) return false;
                return @field(entries[handle], prev_field) != handle;
            }

            fn popAt(self: *State, entries: anytype, handle: Handle) Entry {
                const entry = entries[handle];
                self.release(entries, handle);
                return entry;
            }

            fn linkAtBack(self: *State, entries: anytype, handle: Handle) void {
                @field(entries[handle], prev_field) = self.used_tail;
                @field(entries[handle], next_field) = none;
                if (self.used_tail == none) {
                    self.used_head = handle;
                } else {
                    @field(entries[self.used_tail], next_field) = handle;
                }
                self.used_tail = handle;
            }

            fn linkAtFront(self: *State, entries: anytype, handle: Handle) void {
                @field(entries[handle], prev_field) = none;
                @field(entries[handle], next_field) = self.used_head;
                if (self.used_head == none) {
                    self.used_tail = handle;
                } else {
                    @field(entries[self.used_head], prev_field) = handle;
                }
                self.used_head = handle;
            }

            fn unlink(self: *State, entries: anytype, handle: Handle) void {
                const prev = @field(entries[handle], prev_field);
                const next = @field(entries[handle], next_field);
                if (prev == none) {
                    self.used_head = next;
                } else {
                    @field(entries[prev], next_field) = next;
                }
                if (next == none) {
                    self.used_tail = prev;
                } else {
                    @field(entries[next], prev_field) = prev;
                }
            }
        };

        /// One live entry and the handle that names it.
        pub const Item = struct {
            handle: Handle,
            entry: *Entry,
        };

        /// A walk over the live entries, front to back.
        pub const Iterator = struct {
            state: *const State,
            entries: []Entry,
            cursor: Handle,

            /// The next live entry, or null at the end of the list.
            ///
            /// The cursor advances before the caller's body runs, so the body
            /// may release the entry it was handed. Releasing any other live
            /// entry, or acquiring, during the walk is not supported.
            pub fn next(self: *Iterator) ?Item {
                const handle = self.cursor;
                if (handle == none) return null;
                const entry = &self.entries[handle];
                self.cursor = @field(entry, next_field);
                return .{ .handle = handle, .entry = entry };
            }

            /// Restart at the current front of the list.
            pub fn reset(self: *Iterator) void {
                self.cursor = self.state.used_head;
            }
        };
    };
}

/// A pool over a `[]Entry` given at `init`, for a capacity known at runtime.
///
/// `prev_field` and `next_field` name the two link fields the pool owns. They
/// must exist, be distinct, and share one unsigned integer type.
pub fn Pool(
    comptime Entry: type,
    comptime prev_field: []const u8,
    comptime next_field: []const u8,
) type {
    comptime validate(Entry, prev_field, next_field);
    const core = Core(Entry, prev_field, next_field);

    return struct {
        const Self = @This();

        /// The type of both link fields, read from the entry.
        pub const Handle = core.Handle;
        /// No neighbor.
        pub const none = core.none;
        /// The list and free-list bookkeeping.
        pub const State = core.State;
        /// One live entry and the handle that names it.
        pub const Item = core.Item;
        /// A walk over the live entries, front to back.
        pub const Iterator = core.Iterator;

        /// The whole storage, in handle order.
        entries: []Entry,
        /// The list and free-list bookkeeping.
        state: State,

        /// A pool over no storage. Only `init` replaces the slice.
        pub const empty: Self = .{ .entries = &.{}, .state = .empty };

        /// Use `entries` as the whole storage. Every entry starts free.
        ///
        /// Contents other than the link fields are left as they are.
        pub fn init(entries: []Entry) Self {
            assert(entries.len <= none);
            return .{ .entries = entries, .state = .empty };
        }

        /// Number of live entries.
        pub fn count(self: *const Self) usize {
            return self.state.live;
        }

        /// The whole capacity.
        pub fn capacity(self: *const Self) usize {
            return self.entries.len;
        }

        /// Take a free entry and return its handle. Returns
        /// `error.NoSpaceLeft` when every entry is live.
        pub fn acquire(self: *Self) error{NoSpaceLeft}!Handle {
            return self.state.acquire(self.entries);
        }

        /// `acquire` without the error return. Asserts an entry is free.
        pub fn acquireAssumeCapacity(self: *Self) Handle {
            return self.state.acquireAssumeCapacity(self.entries);
        }

        /// Take a free entry and link it at the front of the list. Returns
        /// `error.NoSpaceLeft` when every entry is live.
        pub fn acquireFront(self: *Self) error{NoSpaceLeft}!Handle {
            return self.state.acquireFront(self.entries);
        }

        /// `acquireFront` without the error return. Asserts an entry is free.
        pub fn acquireFrontAssumeCapacity(self: *Self) Handle {
            return self.state.acquireFrontAssumeCapacity(self.entries);
        }

        /// The entry for `handle`. Asserts only that the handle is in range;
        /// whether it is live is the caller's business, and `isLive` answers
        /// it.
        pub fn get(self: *Self, handle: Handle) *Entry {
            assert(handle < self.entries.len);
            return &self.entries[handle];
        }

        /// Whether `handle` is live. An out-of-range or never-acquired handle
        /// is not.
        pub fn isLive(self: *const Self, handle: Handle) bool {
            return self.state.isLive(self.entries, handle);
        }

        /// Return `handle` to the free list. Asserts `handle` is live.
        ///
        /// The entry's other fields keep their values until the slot is
        /// acquired again.
        pub fn release(self: *Self, handle: Handle) void {
            self.state.release(self.entries, handle);
        }

        /// Move a live entry to the front of the list.
        pub fn moveToFront(self: *Self, handle: Handle) void {
            self.state.moveToFront(self.entries, handle);
        }

        /// Remove the front entry and release its handle. The entry comes back
        /// by value, with its link fields stale.
        pub fn popFront(self: *Self) ?Entry {
            return self.state.popFront(self.entries);
        }

        /// Remove the back entry and release its handle. The entry comes back
        /// by value, with its link fields stale.
        pub fn popBack(self: *Self) ?Entry {
            return self.state.popBack(self.entries);
        }

        /// Walk the live entries from front to back.
        pub fn iterator(self: *Self) Iterator {
            return .{
                .state = &self.state,
                .entries = self.entries,
                .cursor = self.state.used_head,
            };
        }
    };
}

/// A pool that owns an `[max_entries]Entry`, for a capacity known at comptime.
///
/// `prev_field` and `next_field` name the two link fields the pool owns, as in
/// `Pool`. Use this form inside a struct that is copied or returned: a `Pool`
/// holds a slice, and a slice into the same struct would not survive the copy.
pub fn Array(
    comptime Entry: type,
    comptime prev_field: []const u8,
    comptime next_field: []const u8,
    comptime max_entries: comptime_int,
) type {
    comptime validate(Entry, prev_field, next_field);
    const core = Core(Entry, prev_field, next_field);

    return struct {
        const Self = @This();

        /// The type of both link fields, read from the entry.
        pub const Handle = core.Handle;
        /// No neighbor.
        pub const none = core.none;
        /// The list and free-list bookkeeping.
        pub const State = core.State;
        /// One live entry and the handle that names it.
        pub const Item = core.Item;
        /// A walk over the live entries, front to back.
        pub const Iterator = core.Iterator;

        /// The storage, inside the value.
        entries: [max_entries]Entry,
        /// The list and free-list bookkeeping.
        state: State,

        /// A pool with an untouched array. Every entry is free.
        pub const empty: Self = .{ .entries = undefined, .state = .empty };

        /// Number of live entries.
        pub fn count(self: *const Self) usize {
            return self.state.live;
        }

        /// The whole capacity.
        pub fn capacity(self: *const Self) usize {
            return self.entries.len;
        }

        /// Take a free entry and return its handle. Returns
        /// `error.NoSpaceLeft` when every entry is live.
        pub fn acquire(self: *Self) error{NoSpaceLeft}!Handle {
            return self.state.acquire(&self.entries);
        }

        /// `acquire` without the error return. Asserts an entry is free.
        pub fn acquireAssumeCapacity(self: *Self) Handle {
            return self.state.acquireAssumeCapacity(&self.entries);
        }

        /// Take a free entry and link it at the front of the list. Returns
        /// `error.NoSpaceLeft` when every entry is live.
        pub fn acquireFront(self: *Self) error{NoSpaceLeft}!Handle {
            return self.state.acquireFront(&self.entries);
        }

        /// `acquireFront` without the error return. Asserts an entry is free.
        pub fn acquireFrontAssumeCapacity(self: *Self) Handle {
            return self.state.acquireFrontAssumeCapacity(&self.entries);
        }

        /// The entry for `handle`. Asserts only that the handle is in range.
        pub fn get(self: *Self, handle: Handle) *Entry {
            assert(handle < max_entries);
            return &self.entries[handle];
        }

        /// Whether `handle` is live. An out-of-range or never-acquired handle
        /// is not.
        pub fn isLive(self: *const Self, handle: Handle) bool {
            return self.state.isLive(&self.entries, handle);
        }

        /// Return `handle` to the free list. Asserts `handle` is live.
        pub fn release(self: *Self, handle: Handle) void {
            self.state.release(&self.entries, handle);
        }

        /// Move a live entry to the front of the list.
        pub fn moveToFront(self: *Self, handle: Handle) void {
            self.state.moveToFront(&self.entries, handle);
        }

        /// Remove the front entry and release its handle. The entry comes back
        /// by value, with its link fields stale.
        pub fn popFront(self: *Self) ?Entry {
            return self.state.popFront(&self.entries);
        }

        /// Remove the back entry and release its handle. The entry comes back
        /// by value, with its link fields stale.
        pub fn popBack(self: *Self) ?Entry {
            return self.state.popBack(&self.entries);
        }

        /// Walk the live entries from front to back.
        pub fn iterator(self: *Self) Iterator {
            return .{
                .state = &self.state,
                .entries = &self.entries,
                .cursor = self.state.used_head,
            };
        }
    };
}

test "acquire and release" {
    const Entry = struct {
        prev: u32,
        next: u32,
        value: u32,
    };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [3]Entry = undefined;
    var pool: TestPool = .init(&entries);

    try testing.expectEqual(@as(usize, 3), pool.capacity());
    try testing.expectEqual(@as(usize, 0), pool.count());

    // Handles are dense and in acquisition order.
    const first = try pool.acquire();
    const second = try pool.acquire();
    const third = try pool.acquire();
    try testing.expectEqual(@as(u32, 0), first);
    try testing.expectEqual(@as(u32, 1), second);
    try testing.expectEqual(@as(u32, 2), third);
    try testing.expectEqual(@as(usize, 3), pool.count());

    // The pool never touches a field other than the links.
    pool.get(first).value = 10;
    pool.get(second).value = 20;
    pool.get(third).value = 30;
    try testing.expectEqual(@as(u32, 20), pool.get(second).value);

    for ([_]u32{ first, second, third }) |handle| try testing.expect(pool.isLive(handle));

    // The free list is a stack: the last release comes back first.
    pool.release(second);
    try testing.expect(!pool.isLive(second));
    try testing.expect(pool.isLive(first));
    try testing.expect(pool.isLive(third));
    try testing.expectEqual(@as(usize, 2), pool.count());
    try testing.expectEqual(second, try pool.acquire());
    try testing.expectEqual(@as(usize, 3), pool.count());

    // A full pool refuses, and a release makes room again.
    try testing.expectError(error.NoSpaceLeft, pool.acquire());
    pool.release(third);
    try testing.expectEqual(third, try pool.acquire());

    // Never acquired and out-of-range handles are not live.
    try testing.expect(!pool.isLive(TestPool.none));
}

test "iteration is live entries in acquisition order" {
    const Entry = struct {
        prev: u32,
        next: u32,
        value: u32,
    };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [6]Entry = undefined;
    var pool: TestPool = .init(&entries);

    var handles: [6]u32 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).value = @intCast(index);
    }

    // Release from the middle and both ends.
    pool.release(handles[0]);
    pool.release(handles[3]);
    pool.release(handles[5]);

    var seen: [3]u32 = undefined;
    var count: usize = 0;
    var it = pool.iterator();
    while (it.next()) |item| : (count += 1) {
        try testing.expect(item.handle == handles[1] or item.handle == handles[2] or
            item.handle == handles[4]);
        seen[count] = item.entry.value;
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 4 }, &seen);
}

test "moveToFront reorders, popFront and popBack remove the ends" {
    const Entry = struct {
        prev: u32,
        next: u32,
        value: u32,
    };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [5]Entry = undefined;
    var pool: TestPool = .init(&entries);

    var handles: [3]u32 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).value = @intCast(index);
    }
    // The list is 0, 1, 2.
    pool.moveToFront(handles[1]);
    // The list is 1, 0, 2.
    var seen: [3]u32 = undefined;
    var count: usize = 0;
    var it = pool.iterator();
    while (it.next()) |item| : (count += 1) seen[count] = item.entry.value;
    try testing.expectEqualSlices(u32, &.{ 1, 0, 2 }, &seen);

    // Moving the head is a no-op, and moving the tail to the front leaves
    // the same three entries.
    pool.moveToFront(handles[2]);
    pool.moveToFront(handles[1]);
    count = 0;
    it.reset();
    while (it.next()) |item| : (count += 1) seen[count] = item.entry.value;
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, &seen);

    // popFront takes the front and releases its handle. The list is 1, 2, 0.
    const front = pool.popFront().?;
    try testing.expectEqual(@as(u32, 1), front.value);
    try testing.expectEqual(@as(usize, 2), pool.count());
    try testing.expectEqual(@as(u32, 0), pool.popBack().?.value);
    try testing.expectEqual(@as(u32, 2), pool.popBack().?.value);
    try testing.expectEqual(@as(?Entry, null), pool.popBack());
    try testing.expectEqual(@as(usize, 0), pool.count());

    // Every slot is free. The free stack is the release order, so the last
    // pop comes back first, and the frontier continues after it.
    try testing.expectEqual(@as(u32, 2), try pool.acquire());
    try testing.expectEqual(@as(u32, 0), try pool.acquire());
    try testing.expectEqual(@as(u32, 1), try pool.acquire());
    try testing.expectEqual(@as(u32, 3), try pool.acquire());
    try testing.expectEqual(@as(u32, 4), try pool.acquire());
}

test "the walk survives releasing the entry it visits" {
    const Entry = struct {
        prev: u32,
        next: u32,
        value: u32,
    };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [4]Entry = undefined;
    var pool: TestPool = .init(&entries);

    for (0..4) |index| {
        const handle = try pool.acquire();
        pool.get(handle).value = @intCast(index);
    }

    // Releasing the current entry overwrites its `next` with a free-list
    // link; the iterator has already moved past it.
    var total: u32 = 0;
    var it = pool.iterator();
    while (it.next()) |item| {
        total += item.entry.value;
        pool.release(item.handle);
    }
    try testing.expectEqual(@as(u32, 6), total);
    try testing.expectEqual(@as(usize, 0), pool.count());
    try testing.expectEqual(@as(usize, 4), pool.capacity());

    // Every slot is free again, so the next walk is empty, and a new acquire
    // comes off the free stack, newest release first.
    var empty = pool.iterator();
    try testing.expectEqual(@as(?TestPool.Item, null), empty.next());
    try testing.expectEqual(@as(u32, 3), try pool.acquire());
    try testing.expectEqual(@as(u32, 2), try pool.acquire());
}

test "the owning array form" {
    const Entry = struct {
        prev: u16,
        next: u16,
        tag: u8,
    };
    const Owned = Array(Entry, "prev", "next", 8);

    // `empty` is a plain value: the array travels inside the pool, so the
    // struct can be copied and returned.
    var pool: Owned = .empty;
    try testing.expectEqual(@as(usize, 8), pool.capacity());

    var handles: [8]u16 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).tag = @intCast(index);
        try testing.expectEqual(@as(u8, @intCast(index)), pool.get(handle.*).tag);
    }
    try testing.expectError(error.NoSpaceLeft, pool.acquire());

    // A copy of the value is independent of the original.
    const copied = pool;
    var copy: Owned = copied;
    copy.release(handles[0]);
    try testing.expectEqual(@as(usize, 7), copy.count());
    try testing.expectEqual(@as(usize, 8), pool.count());
    try testing.expect(pool.isLive(handles[0]));
    try testing.expect(!copy.isLive(handles[0]));
}

test "a narrow handle type packs the links" {
    const Entry = struct {
        prev: u8,
        next: u8,
        value: u32,
    };
    const Owned = Array(Entry, "prev", "next", 200);
    var pool: Owned = .empty;

    // Two one-byte links and a four-byte value: the links cost two bytes.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Entry));
    var handles: [200]u8 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).value = @intCast(index);
    }
    try testing.expectError(error.NoSpaceLeft, pool.acquire());
    try testing.expectEqual(@as(usize, 200), pool.count());
    try testing.expectEqual(@as(u32, 199), pool.get(handles[199]).value);
}

test "runtime capacity from an allocated slice" {
    const Entry = struct {
        prev: u32,
        next: u32,
        tag: u8,
    };
    const TestPool = Pool(Entry, "prev", "next");

    const entries = try testing.allocator.alloc(Entry, 64);
    defer testing.allocator.free(entries);

    var pool: TestPool = .init(entries);
    try testing.expectEqual(@as(usize, 64), pool.capacity());

    var handles: [64]u32 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).tag = @truncate(index);
    }
    try testing.expectError(error.NoSpaceLeft, pool.acquire());

    // Release the odd handles, then walk: 32 live entries, even handles in
    // acquisition order.
    for (handles, 0..) |handle, index| {
        if (index % 2 == 1) pool.release(handle);
    }

    var walked: usize = 0;
    var it = pool.iterator();
    while (it.next()) |item| : (walked += 1) {
        try testing.expectEqual(@as(u8, @truncate(walked * 2)), item.entry.tag);
    }
    try testing.expectEqual(@as(usize, 32), walked);
    try testing.expectEqual(@as(usize, 32), pool.count());
}

test "a pool with no capacity" {
    const Entry = struct { prev: u32, next: u32 };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [0]Entry = undefined;
    var pool: TestPool = .init(&entries);

    try testing.expectEqual(@as(usize, 0), pool.capacity());
    try testing.expectEqual(@as(usize, 0), pool.count());
    try testing.expectError(error.NoSpaceLeft, pool.acquire());
    try testing.expectEqual(@as(?Entry, null), pool.popBack());

    var it = pool.iterator();
    try testing.expectEqual(@as(?TestPool.Item, null), it.next());
}

test "link fields in the middle of a larger entry" {
    const Entry = struct {
        key: u64,
        prev: u32,
        next: u32,
        payload: [24]u8,
    };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [2]Entry = undefined;
    var pool: TestPool = .init(&entries);

    const handle = try pool.acquire();
    const entry = pool.get(handle);
    entry.key = 0x0102_0304_0506_0708;
    @memset(entry.payload[0..], 0xAA);
    var it = pool.iterator();
    try testing.expectEqual(handle, it.next().?.handle);
    try testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), pool.get(handle).key);
    try testing.expectEqual(@as(u8, 0xAA), pool.get(handle).payload[23]);
}
