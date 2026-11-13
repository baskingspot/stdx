const std = @import("std");
const slot = @import("stdx").slot;

// The links live in the entry, at comptime-known field names. The pool owns
// these two fields; every other field is yours. Their type is the handle type,
// and a narrow type such as u16 packs a small table.
const Stream = struct {
    prev: u32,
    next: u32,
    id: u32,
    open: bool,
};

const Pool = slot.Pool(Stream, "prev", "next");

test "acquire, release, and walk in acquisition order" {
    // Capacity is the slice length, so a local array is a fixed-size pool.
    var entries: [4]Stream = undefined;
    var pool: Pool = .init(&entries);

    var handles: [3]u32 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = try pool.acquire();
        pool.get(handle.*).id = @intCast(index);
        pool.get(handle.*).open = true;
    }

    // Release the middle stream. The walk keeps acquisition order.
    pool.release(handles[1]);
    try std.testing.expect(!pool.isLive(handles[1]));

    var seen: [2]u32 = undefined;
    var count: usize = 0;
    var it = pool.iterator();
    while (it.next()) |item| : (count += 1) seen[count] = item.entry.id;
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, seen[0..count]);
}

test "a full pool reports it" {
    var entries: [1]Stream = undefined;
    var pool: Pool = .init(&entries);

    const handle = try pool.acquire();
    try std.testing.expectError(error.NoSpaceLeft, pool.acquire());

    // The handle is the entry's index, so a caller never needs pointer
    // arithmetic to recover it.
    try std.testing.expectEqual(@as(u32, 0), handle);
    pool.release(handle);
    try std.testing.expectEqual(handle, try pool.acquire());
}

test "release the entry a walk is visiting" {
    var entries: [3]Stream = undefined;
    var pool: Pool = .init(&entries);
    for (0..3) |_| _ = try pool.acquire();

    // The iterator moves to the next entry before the body runs, so releasing
    // the entry it handed over is safe.
    var it = pool.iterator();
    while (it.next()) |item| {
        pool.release(item.handle);
    }
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

// The owning form keeps the array inside the pool, so the whole value can be
// copied or returned, and the capacity is part of the type.
const Cache = slot.Array(Stream, "prev", "next", 16);

test "an owning pool" {
    var cache: Cache = .empty;
    const handle = try cache.acquire();
    cache.get(handle).id = 7;

    // The front of the list is the entry most recently moved there.
    cache.moveToFront(handle);
    try std.testing.expectEqual(@as(u32, 7), cache.popFront().?.id);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "runtime capacity from an allocated slice" {
    const entries = try std.testing.allocator.alloc(Stream, 128);
    defer std.testing.allocator.free(entries);

    var pool: Pool = .init(entries);
    try std.testing.expectEqual(@as(usize, 128), pool.capacity());

    const handle = try pool.acquire();
    pool.get(handle).id = 7;
    try std.testing.expectEqual(@as(u32, 7), pool.get(handle).id);
}
