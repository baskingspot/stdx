//! stdx benchmarks: the bounded maps against each other, the pairing the
//! IDEAS ledger cares about — `array_hash_map.Bounded` (robin) is the
//! small-table map, `swiss.Bounded` the large-table one, and the numbers
//! are the crossover story: same keys, same capacities, both sizes.

const bench = @import("benchmark");
const stdx = @import("stdx");

const swiss = stdx.swiss;
const robin = stdx.array_hash_map;

// The small workload: 3000 keys in 3584 capacity (~83% load), u64 keys —
// the table sits in cache and fingerprint precision decides.
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

// The large workload: 7M keys in 8M capacity (~87% load), u32 keys — the
// metadata (swiss ~16MB ctrl vs robin ~150MB header+hash+entries)
// overflows cache and probe traffic decides. Filled once, shared by the
// large benchmarks; setup is excluded from timing.
const large_capacity = 8_000_000;
const large_fill = 7_000_000;
const large_probe_keys = 4096;

var large_swiss: swiss.Bounded(u32, u32, large_capacity) = .init();
var large_robin: robin.Bounded(u32, u32, large_capacity) = .init();
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
        try large_swiss.put(k, k);
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

pub fn benchmarkSwissSmall(b: *bench.B) !void {
    var map: swiss.Bounded(u64, u64, small_capacity) = .init();
    for (small_keys) |k| try map.put(k, k);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&small_keys)) |k| {
            if (map.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkRobinSmall(b: *bench.B) !void {
    var map: robin.Bounded(u64, u64, small_capacity) = .init();
    for (small_keys) |k| try map.put(k, k);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&small_keys)) |k| {
            if (map.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissSmallMiss(b: *bench.B) !void {
    var map: swiss.Bounded(u64, u64, small_capacity) = .init();
    for (small_keys) |k| try map.put(k, k);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (small_keys) |k| {
            if (map.get(k ^ 1)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkRobinSmallMiss(b: *bench.B) !void {
    var map: robin.Bounded(u64, u64, small_capacity) = .init();
    for (small_keys) |k| try map.put(k, k);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (small_keys) |k| {
            if (map.get(k ^ 1)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissLarge(b: *bench.B) !void {
    try ensureLargeFilled();
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_hit_keys)) |k| {
            if (large_swiss.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkRobinLarge(b: *bench.B) !void {
    try ensureLargeFilled();
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_hit_keys)) |k| {
            if (large_robin.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissLargeMiss(b: *bench.B) !void {
    try ensureLargeFilled();
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_miss_keys)) |k| {
            if (large_swiss.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkRobinLargeMiss(b: *bench.B) !void {
    try ensureLargeFilled();
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&large_miss_keys)) |k| {
            if (large_robin.get(k)) |v| sink +%= v;
        }
    }
    b.keepAlive(sink);
}
