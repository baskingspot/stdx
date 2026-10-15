//! The swiss module's benchmarks: the crossover suite against
//! `bounded_array_hash_map.Auto` (robin) — same keys, same capacities, both
//! sizes. Small (3000 keys in 3584 capacity, cached): fingerprint precision
//! decides, robin wins. Large (7M in 8M, metadata past cache): probe traffic
//! decides, swiss wins. The pairing is the IDEAS ledger's story.

const bench = @import("benchmark");

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
// 8MB ctrl + 64MB entries), past cache, where probe traffic decides.
const large_fill = 7_000_000;
const large_probe_keys = 4096;

var large_swiss: swiss.Auto(u32, u32) = .empty;
var large_hit_keys: [large_probe_keys]u32 = undefined;
var large_miss_keys: [large_probe_keys]u32 = undefined;
var large_filled = false;

fn ensureLargeFilled(gpa: std.mem.Allocator) !void {
    if (large_filled) return;
    defer large_filled = true;

    var state: u64 = 0x2545f4914f6a03d5;
    var i: usize = 0;
    var saved: usize = 0;
    while (i < large_fill) : (i += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const k: u32 = @truncate(state >> 32);
        try large_swiss.put(gpa, k, k);
        if (i % (large_fill / large_probe_keys) == 0 and saved < large_probe_keys) {
            large_hit_keys[saved] = k;
            saved += 1;
        }
    }
    for (&large_miss_keys, 0..) |*k, idx| {
        k.* = large_hit_keys[idx] ^ 0xFFFF_0000;
    }
}

pub fn benchmarkSwissSmall(b: *bench.B) !void {
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

pub fn benchmarkSwissSmallMiss(b: *bench.B) !void {
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

pub fn benchmarkSwissLarge(b: *bench.B) !void {
    try ensureLargeFilled(b.allocator);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_hit_keys)) |k| {
            if (large_swiss.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissLargeMiss(b: *bench.B) !void {
    try ensureLargeFilled(b.allocator);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_miss_keys)) |k| {
            if (large_swiss.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}
