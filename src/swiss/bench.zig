//! The swiss module's benchmarks: the crossover suite against
//! `bounded_array_hash_map.Auto` (robin) — same keys, same capacities, both
//! sizes. Small (3000 keys in 3584 capacity, cached): fingerprint precision
//! decides, robin wins. Large (7M in 8M, metadata past cache): probe traffic
//! decides, swiss wins. The pairing is the IDEAS ledger's story.

const testingx = @import("testingx");

const std = @import("std");

const stdx = @import("stdx");
const swiss = stdx.swiss;

// The small workload: 3000 keys, u64 — robin is declared at 3584 capacity
// and swiss grows to the same 4096 buckets (3584 capacity), so the pairing
// stays like-for-like.
const small_capacity = 3584;
const small_keys = blk: {
    @setEvalBranchQuota(20000);
    var ks: [3000]u64 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&ks) |*k| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        k.* = state;
    }
    break :blk ks;
};

// The large workload: 7M keys, u32 — swiss grows to 8.4M buckets (~72MB:
// 8MB ctrl + 64MB entries), past cache, where probe traffic decides. The
// hit/miss key tables are module-scope plain data; each benchmark fills its
// own map as untimed setup, like the small ones do.
const large_fill = 7_000_000;
const large_probe_keys = 4096;

var large_hit_keys: [large_probe_keys]u32 = undefined;
var large_miss_keys: [large_probe_keys]u32 = undefined;

/// Fill the map and the shared hit/miss key tables. Runs as untimed setup
/// before the `b.loop()`, so the fill's allocations and time stay out of
/// the metric; the caller deinits the map, so nothing leaks.
fn fillLarge(
    gpa: std.mem.Allocator,
    map: *swiss.Auto(u32, u32),
    hit_keys: *[large_probe_keys]u32,
    miss_keys: *[large_probe_keys]u32,
) !void {
    var state: u64 = 0x2545f4914f6a03d5;
    var i: usize = 0;
    var saved: usize = 0;
    while (i < large_fill) : (i += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const k: u32 = @truncate(state >> 32);
        try map.put(gpa, k, k);
        if (i % (large_fill / large_probe_keys) == 0 and saved < large_probe_keys) {
            hit_keys[saved] = k;
            saved += 1;
        }
    }
    for (miss_keys, 0..) |*k, idx| {
        k.* = hit_keys[idx] ^ 0xFFFF_0000;
    }
}

pub fn benchmarkSwissSmall(b: *testingx.B) !void {
    var map: swiss.Auto(u64, u64) = .empty;
    defer map.deinit(b.allocator);
    for (small_keys) |k| try map.put(b.allocator, k, k);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&small_keys)) |k| {
            if (map.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissSmallMiss(b: *testingx.B) !void {
    var map: swiss.Auto(u64, u64) = .empty;
    defer map.deinit(b.allocator);
    for (small_keys) |k| try map.put(b.allocator, k, k);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (small_keys) |k| {
            if (map.get(k ^ 1)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissLarge(b: *testingx.B) !void {
    var map: swiss.Auto(u32, u32) = .empty;
    defer map.deinit(b.allocator);
    try fillLarge(b.allocator, &map, &large_hit_keys, &large_miss_keys);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_hit_keys)) |k| {
            if (map.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissLargeMiss(b: *testingx.B) !void {
    var map: swiss.Auto(u32, u32) = .empty;
    defer map.deinit(b.allocator);
    try fillLarge(b.allocator, &map, &large_hit_keys, &large_miss_keys);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_miss_keys)) |k| {
            if (map.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

/// One op: grow an empty map to `growth_target` entries. The timed op IS
/// the doubling chain, so allocs/op is the true count (~3 per doubling,
/// not amortized to a printed zero), and B/op is the sum of every
/// intermediate table size.
pub fn benchmarkSwissGrow(b: *testingx.B) !void {
    var map: swiss.Auto(u64, u64) = .empty;
    defer map.deinit(b.allocator);
    while (try b.loop()) {
        map.clearAndFree(b.allocator);
        var k: u64 = 0;
        while (k < growth_target) : (k += 1) {
            try map.put(b.allocator, k, k);
        }
    }
    b.keepAlive(map.count());
}

const growth_target = 1024;
