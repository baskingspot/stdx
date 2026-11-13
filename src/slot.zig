//! A fixed-capacity pool of caller-owned entries: O(1) acquire and release,
//! iteration over live entries in acquisition order.
//!
//! The links live inside the entry, in two `Handle` fields the caller names at
//! comptime, so walking the live set reads only the entries it visits. That is
//! the point of the shape: a table of a thousand entries with a handful live
//! costs one cache line per live entry to walk, not one per stored entry.
//!
//! Capacity is the length of the slice passed to `init`. A comptime-sized
//! array serves the fixed case, and a heap slice serves the runtime case; the
//! type is the same and neither needs an allocator in the value. A released
//! entry threads the free list through its own `next` field, so the free stack
//! costs no memory either.
//!
//! A handle is the entry's index in the slice, so a caller recovers the index
//! by keeping the handle — never by pointer arithmetic on a `*Entry`. The
//! `prev` field doubles as liveness bookkeeping: a free entry points `prev` at
//! its own handle, so releasing the same handle twice trips an assert in a safe
//! build instead of handing the slot out to two callers.
//!
//! The pool owns the link fields and the caller owns everything else. An
//! acquired entry is not cleared, and the pool never writes a field other than
//! the two links.
//!
//! Not thread-safe, and a value must not be copied after `init`: a copy shares
//! the entries, and both copies would hand out the same slot.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

/// An entry's position in its pool, and the type of both link fields.
///
/// A pool holds at most `math.maxInt(Handle)` entries.
pub const Handle = u32;

/// Returns a fixed-capacity pool over `[]Entry`.
///
/// `prev_field` and `next_field` name the two `Handle` fields the pool owns.
/// They must exist, be distinct, and be typed `Handle`.
pub fn Pool(
    comptime Entry: type,
    comptime prev_field: []const u8,
    comptime next_field: []const u8,
) type {
    comptime {
        if (@typeInfo(Entry) != .@"struct") {
            @compileError("slot.Pool: Entry must be a struct, found " ++ @typeName(Entry));
        }
        if (prev_field.len == 0 or next_field.len == 0) {
            @compileError("slot.Pool: the link field names must be nonempty");
        }
        if (mem.eql(u8, prev_field, next_field)) {
            @compileError("slot.Pool: prev and next must name different fields");
        }
        for ([_][]const u8{ prev_field, next_field }) |name| {
            if (!@hasField(Entry, name)) {
                @compileError("slot.Pool: Entry has no field named " ++ name);
            }
            if (@FieldType(Entry, name) != Handle) {
                @compileError(
                    "slot.Pool: Entry." ++ name ++ " must be slot.Handle, found " ++
                        @typeName(@FieldType(Entry, name)),
                );
            }
        }
    }

    return struct {
        const Self = @This();

        /// No neighbor: the head's `prev`, the tail's `next`, and the end of
        /// the free list.
        pub const none: Handle = math.maxInt(Handle);

        /// The whole storage, in handle order.
        entries: []Entry,
        /// First live entry in acquisition order.
        used_head: Handle,
        /// Last live entry.
        used_tail: Handle,
        /// First free entry.
        free_head: Handle,
        /// Number of live entries.
        live: usize,

        /// Use `entries` as the whole storage. Every entry starts free.
        ///
        /// Contents other than the link fields are left as they are.
        pub fn init(entries: []Entry) Self {
            assert(entries.len <= math.maxInt(Handle));
            const self: Self = .{
                .entries = entries,
                .used_head = none,
                .used_tail = none,
                .free_head = if (entries.len == 0) none else 0,
                .live = 0,
            };
            for (entries, 0..) |*entry, index| {
                // A free entry points `prev` at itself, which is what
                // `release` checks to catch a doubled release.
                @field(entry, prev_field) = @intCast(index);
                @field(entry, next_field) = if (index + 1 < entries.len)
                    @intCast(index + 1)
                else
                    none;
            }
            return self;
        }

        /// Number of live entries.
        pub fn count(self: *const Self) usize {
            return self.live;
        }

        /// The whole capacity.
        pub fn capacity(self: *const Self) usize {
            return self.entries.len;
        }

        /// Take a free entry and return its handle. Returns
        /// `error.NoSpaceLeft` when every entry is live.
        pub fn acquire(self: *Self) error{NoSpaceLeft}!Handle {
            if (self.free_head == none) return error.NoSpaceLeft;
            return self.acquireAssumeCapacity();
        }

        /// `acquire` without the error return. Asserts an entry is free.
        pub fn acquireAssumeCapacity(self: *Self) Handle {
            assert(self.free_head != none);
            const handle = self.free_head;
            const entry = &self.entries[handle];
            self.free_head = @field(entry, next_field);
            self.linkAtTail(handle);
            self.live += 1;
            return handle;
        }

        /// The entry for `handle`. Asserts only that the handle is in range;
        /// whether it is live is the caller's business, and `isLive` answers
        /// it.
        pub fn get(self: *Self, handle: Handle) *Entry {
            assert(handle < self.entries.len);
            return &self.entries[handle];
        }

        /// Whether `handle` is live. An out-of-range handle is not.
        pub fn isLive(self: *const Self, handle: Handle) bool {
            if (handle >= self.entries.len) return false;
            return @field(self.entries[handle], prev_field) != handle;
        }

        /// Return `handle` to the free list. Asserts `handle` is live.
        ///
        /// The entry's other fields keep their values until the slot is
        /// acquired again.
        pub fn release(self: *Self, handle: Handle) void {
            assert(handle < self.entries.len);
            const entry = &self.entries[handle];
            assert(@field(entry, prev_field) != handle);

            const prev = @field(entry, prev_field);
            const next = @field(entry, next_field);
            if (prev == none) {
                self.used_head = next;
            } else {
                @field(&self.entries[prev], next_field) = next;
            }
            if (next == none) {
                self.used_tail = prev;
            } else {
                @field(&self.entries[next], prev_field) = prev;
            }

            // Free entries point at themselves and thread the free list.
            @field(entry, prev_field) = handle;
            @field(entry, next_field) = self.free_head;
            self.free_head = handle;
            self.live -= 1;
        }

        fn linkAtTail(self: *Self, handle: Handle) void {
            const entry = &self.entries[handle];
            @field(entry, prev_field) = self.used_tail;
            @field(entry, next_field) = none;
            if (self.used_tail == none) {
                self.used_head = handle;
            } else {
                @field(&self.entries[self.used_tail], next_field) = handle;
            }
            self.used_tail = handle;
        }

        /// One live entry and the handle that names it.
        pub const Item = struct {
            handle: Handle,
            entry: *Entry,
        };

        /// Walk the live entries in acquisition order.
        ///
        /// The iterator advances before the body runs, so the body may release
        /// the entry it was handed. Releasing any other entry, or acquiring,
        /// during the walk is not supported.
        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self, .cursor = self.used_head };
        }

        /// A walk over the live entries of one pool.
        pub const Iterator = struct {
            pool: *Self,
            cursor: Handle,

            /// The next live entry, or null at the end of the list.
            pub fn next(self: *Iterator) ?Item {
                const handle = self.cursor;
                if (handle == none) return null;
                const entry = &self.pool.entries[handle];
                self.cursor = @field(entry, next_field);
                return .{ .handle = handle, .entry = entry };
            }
        };
    };
}

test "acquire and release" {
    const Entry = struct {
        prev: Handle,
        next: Handle,
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
    try testing.expectEqual(@as(Handle, 0), first);
    try testing.expectEqual(@as(Handle, 1), second);
    try testing.expectEqual(@as(Handle, 2), third);
    try testing.expectEqual(@as(usize, 3), pool.count());

    // The pool never touches a field other than the links.
    pool.get(first).value = 10;
    pool.get(second).value = 20;
    pool.get(third).value = 30;
    try testing.expectEqual(@as(u32, 20), pool.get(second).value);

    for ([_]Handle{ first, second, third }) |handle| try testing.expect(pool.isLive(handle));

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

    // Out-of-range handles are not live.
    try testing.expect(!pool.isLive(3));
    try testing.expect(!pool.isLive(TestPool.none));
}

test "iteration is live entries in acquisition order" {
    const Entry = struct {
        prev: Handle,
        next: Handle,
        value: u32,
    };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [6]Entry = undefined;
    var pool: TestPool = .init(&entries);

    var handles: [6]Handle = undefined;
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

test "the walk survives releasing the entry it visits" {
    const Entry = struct {
        prev: Handle,
        next: Handle,
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

    // Every slot is free again, so the next walk is empty and acquisition
    // starts over.
    var empty = pool.iterator();
    try testing.expectEqual(@as(?TestPool.Item, null), empty.next());

    var handles: [4]Handle = undefined;
    for (&handles) |*handle| handle.* = try pool.acquire();
    try testing.expectEqualSlices(Handle, &.{ 3, 2, 1, 0 }, &handles);
}

test "runtime capacity from an allocated slice" {
    const Entry = struct {
        prev: Handle,
        next: Handle,
        tag: u8,
    };
    const TestPool = Pool(Entry, "prev", "next");

    const entries = try testing.allocator.alloc(Entry, 64);
    defer testing.allocator.free(entries);

    var pool: TestPool = .init(entries);
    try testing.expectEqual(@as(usize, 64), pool.capacity());

    var handles: [64]Handle = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).tag = @truncate(index);
    }
    try testing.expectError(error.NoSpaceLeft, pool.acquire());

    // Release the odd handles, then walk: 32 live entries, even then odd
    // handles in acquisition order.
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
    const Entry = struct { prev: Handle, next: Handle };
    const TestPool = Pool(Entry, "prev", "next");

    var entries: [0]Entry = undefined;
    var pool: TestPool = .init(&entries);

    try testing.expectEqual(@as(usize, 0), pool.capacity());
    try testing.expectEqual(@as(usize, 0), pool.count());
    try testing.expectError(error.NoSpaceLeft, pool.acquire());

    var it = pool.iterator();
    try testing.expectEqual(@as(?TestPool.Item, null), it.next());
}

test "link fields in the middle of a larger entry" {
    const Entry = struct {
        key: u64,
        prev: Handle,
        next: Handle,
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
