//! The slot module's benchmarks: the intrusive live list against the shape it
//! replaces, a scan of the whole entry array for a live flag. The entries are
//! a realistic size — http's h2 slot is 776 bytes — so the scan pays one cache
//! line per stored entry while the list pays one per live entry. That
//! difference is the reason the primitive exists.

const testingx = @import("testingx");

const stdx = @import("stdx");
const slot = stdx.slot;

const capacity = 1024;
const live = 16;

const Entry = struct {
    prev: u32,
    next: u32,
    /// Only the scan baseline reads it; the list finds liveness structurally.
    live: bool,
    value: u64,
    /// Stand-in for the stream state a real slot carries.
    payload: [768]u8,
};

const Pool = slot.Pool(Entry, "prev", "next");

// 1024 entries of 792 bytes is too large for a stack.
var entries: [capacity]Entry = undefined;

pub fn benchmarkSlotAcquireRelease(b: *testingx.B) !void {
    var pool: Pool = .init(&entries);
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const handle = try pool.acquire();
        pool.get(handle).value = sink;
        sink +%= handle;
        pool.release(handle);
    }
}

pub fn benchmarkSlotIterate(b: *testingx.B) !void {
    var pool: Pool = .init(&entries);
    for (0..live) |index| {
        const handle = try pool.acquire();
        pool.get(handle).value = index;
    }
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var it = pool.iterator();
        while (it.next()) |item| sink +%= item.entry.value;
    }
}

pub fn benchmarkSlotIterateScan(b: *testingx.B) !void {
    // The baseline: a live flag per entry and a scan of every one, which is
    // what the intrusive list replaced.
    for (&entries) |*entry| entry.live = false;
    for (entries[0..live], 0..) |*entry, index| {
        entry.live = true;
        entry.value = index;
    }

    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (b.blackBox(&entries)) |entry| {
            if (entry.live) sink +%= entry.value;
        }
    }
}
