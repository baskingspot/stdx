//! The bounded_array_hash_map module's benchmarks: the robin side of the
//! crossover suite against `swiss.Auto` — the incumbent baseline. Same
//! keys, same capacities, both sizes (see swiss/bench.zig for the story).

const testingx = @import("testingx");

const stdx = @import("stdx");
const robin = stdx.bounded_array_hash_map;

// The small workload: 3000 keys in 3584 capacity, u64 — cached, fingerprint
// precision decides.
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

// The large workload: 7M keys in 8M capacity, u32 — ~160MB of metadata
// (64MB index + 96MB entries), past cache.
const large_capacity = 8_000_000;
const large_fill = 7_000_000;
const large_probe_keys = 4096;

var large_robin: robin.Auto(u32, u32, large_capacity) = .empty;
var large_hit_keys: [large_probe_keys]u32 = undefined;
var large_miss_keys: [large_probe_keys]u32 = undefined;
var large_filled = false;

fn ensureLargeFilled() !void {
    if (large_filled) return;
    defer large_filled = true;

    var state: u64 = 0x2545f4914f6a03d5;
    var i: usize = 0;
    var saved: usize = 0;
    while (i < large_fill) : (i += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const k: u32 = @truncate(state >> 32);
        try large_robin.put(k, k);
        if (i % (large_fill / large_probe_keys) == 0 and saved < large_probe_keys) {
            large_hit_keys[saved] = k;
            saved += 1;
        }
    }
    for (&large_miss_keys, 0..) |*k, idx| {
        k.* = large_hit_keys[idx] ^ 0xFFFF_0000;
    }
}

pub fn benchmarkRobinSmall(b: *testingx.B) !void {
    var map: robin.Auto(u64, u64, small_capacity) = .empty;
    for (small_keys) |k| try map.put(k, k);
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (b.blackBox(&small_keys)) |k| {
            if (map.get(k)) |v| sink +%= v;
        }
    }
}

pub fn benchmarkRobinSmallMiss(b: *testingx.B) !void {
    var map: robin.Auto(u64, u64, small_capacity) = .empty;
    for (small_keys) |k| try map.put(k, k);
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (small_keys) |k| {
            if (map.get(k ^ 1)) |v| sink +%= v;
        }
    }
}

pub fn benchmarkRobinLarge(b: *testingx.B) !void {
    try ensureLargeFilled();
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (b.blackBox(&large_hit_keys)) |k| {
            if (large_robin.get(k)) |v| sink +%= v;
        }
    }
}

pub fn benchmarkRobinLargeMiss(b: *testingx.B) !void {
    try ensureLargeFilled();
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (b.blackBox(&large_miss_keys)) |k| {
            if (large_robin.get(k)) |v| sink +%= v;
        }
    }
}
