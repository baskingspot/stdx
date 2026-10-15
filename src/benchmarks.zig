//! stdx benchmarks: the maps against each other, the pairing the IDEAS
//! ledger cares about — `bounded_array_hash_map.Auto` (robin) is the
//! small-table map, `swiss.Auto` the resizable large-table one, and the
//! numbers are the crossover story: same keys, both sizes. The Bloom filter
//! follows with its steady-state `add` and `contains` cost, then rapidhash
//! against Wyhash on small keys and a 16 KiB buffer.

const std = @import("std");

const bench = @import("benchmark");
const stdx = @import("stdx");
const swiss = stdx.swiss;
const robin = stdx.bounded_array_hash_map;
const bloom = stdx.bloom;
const rapidhash = stdx.rapidhash;

// The small workload: 3000 keys, u64 keys — robin is declared at 3584
// capacity and swiss grows to the same 4096 buckets (3584 capacity), so the
// pairing stays like-for-like. The table sits in cache and fingerprint
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

// The large workload: 7M keys, u32 keys — swiss grows to 8.4M buckets
// (~72MB: 8MB ctrl + 64MB entries) and robin is declared at 8M capacity
// (~160MB: 64MB index + 96MB entries), so both overflow cache and probe
// traffic decides. Filled once, shared by the large benchmarks; setup is
// excluded from timing.
const large_capacity = 8_000_000;
const large_fill = 7_000_000;
const large_probe_keys = 4096;

var large_swiss: swiss.Auto(u32, u32) = .empty;
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
        try large_swiss.put(std.heap.smp_allocator, k, k);
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

pub fn benchmarkRobinSmall(b: *bench.B) !void {
    var map: robin.Auto(u64, u64, small_capacity) = .empty;
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

pub fn benchmarkRobinSmallMiss(b: *bench.B) !void {
    var map: robin.Auto(u64, u64, small_capacity) = .empty;
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

// The Bloom workload: 10k keys, cycled. The filter is sized for 1M items,
// so after the first pass every add re-sets bits that are already set —
// the steady-state add cost.
const bloom_capacity = 1_000_000;
const bloom_keys = blk: {
    @setEvalBranchQuota(20000);
    var ks: [10_000]u64 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&ks) |*k| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        k.* = state;
    }
    break :blk ks;
};

pub fn benchmarkBloomAdd(b: *bench.B) !void {
    var filter: bloom.Auto(u64, bloom_capacity, 0.01) = .empty;
    var i: usize = 0;
    while (try b.loop()) {
        filter.add(bloom_keys[i]);
        i += 1;
        if (i == bloom_keys.len) i = 0;
    }
    // Keep the filter itself alive: a scalar result would let the optimizer
    // drop the bit writes, and the asm memory clobber in keepAlive pins
    // every store the loop made.
    b.keepAlive(&filter);
}

pub fn benchmarkBloomContains(b: *bench.B) !void {
    var filter: bloom.Auto(u64, bloom_capacity, 0.01) = .empty;
    for (bloom_keys) |key| filter.add(key);

    var found: usize = 0;
    var i: usize = 0;
    while (try b.loop()) {
        found += @intFromBool(filter.contains(bloom_keys[i]));
        i += 1;
        if (i == bloom_keys.len) i = 0;
    }
    b.keepAlive(found);
}

// rapidhash vs Wyhash: the small-key workload cycles 4/8/16-byte slices of
// a fixed 4096-key table, the large one hashes a single 16 KiB buffer. Each
// implementation gets its own timed loop — the names pair up, the hashes
// never interleave.
const hash_keys = blk: {
    @setEvalBranchQuota(100_000);
    var keys: [4096][16]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&keys) |*key| {
        for (key) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(state >> 32);
        }
    }
    break :blk keys;
};

const hash_key_lens = [_]usize{ 4, 8, 16 };

pub fn benchmarkRapidhashSmall(b: *bench.B) !void {
    var sink: u64 = 0;
    var i: usize = 0;
    while (try b.loop()) {
        const key: []const u8 = b.blackBox(&hash_keys[i & (hash_keys.len - 1)]);
        sink +%= rapidhash.hash(0, key[0..hash_key_lens[i % hash_key_lens.len]]);
        i += 1;
    }
    b.keepAlive(sink);
}

pub fn benchmarkWyhashSmall(b: *bench.B) !void {
    var sink: u64 = 0;
    var i: usize = 0;
    while (try b.loop()) {
        const key: []const u8 = b.blackBox(&hash_keys[i & (hash_keys.len - 1)]);
        sink +%= std.hash.Wyhash.hash(0, key[0..hash_key_lens[i % hash_key_lens.len]]);
        i += 1;
    }
    b.keepAlive(sink);
}

const hash_large_len = 16 * 1024;

const hash_large = blk: {
    @setEvalBranchQuota(100_000);
    var data: [hash_large_len]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&data) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    break :blk data;
};

pub fn benchmarkRapidhashLarge(b: *bench.B) !void {
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= rapidhash.hash(0, b.blackBox(&hash_large));
    }
    b.keepAlive(sink);
}

pub fn benchmarkWyhashLarge(b: *bench.B) !void {
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= std.hash.Wyhash.hash(0, b.blackBox(&hash_large));
    }
    b.keepAlive(sink);
}
