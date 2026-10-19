//! The bloom module's benchmarks: steady-state `add` and `contains`
//! cost at a 1M-key filter.

const testingx = @import("testingx");

const stdx = @import("stdx");
const bloom = stdx.bloom;

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

pub fn benchmarkBloomAdd(b: *testingx.B) !void {
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

pub fn benchmarkBloomContains(b: *testingx.B) !void {
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
