//! Cuckoo filter benchmarks: steady-state `contains` and `add`/`remove` churn
//! on a 100k-key `u16` filter.

const testingx = @import("testingx");

const stdx = @import("stdx");
const cuckoo = stdx.cuckoo;

const Filter = cuckoo.Auto(u64, .fromCapacity(100_000, 0.01));
const keys = blk: {
    @setEvalBranchQuota(20_000);
    var ks: [10_000]u64 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&ks) |*k| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        k.* = state;
    }
    break :blk ks;
};

pub fn benchmarkCuckooContains(b: *testingx.B) !void {
    var filter: Filter = .empty;
    for (keys) |k| try filter.add(k);

    var found: usize = 0;
    var i: usize = 0;
    while (try b.loop()) {
        found += @intFromBool(filter.contains(keys[i]));
        i += 1;
        if (i == keys.len) i = 0;
    }
    b.keepAlive(found);
}

pub fn benchmarkCuckooAddRemove(b: *testingx.B) !void {
    var filter: Filter = .empty;
    for (keys[0..5000]) |k| try filter.add(k);

    var i: usize = 5000;
    while (try b.loop()) {
        try filter.add(keys[i]);
        _ = filter.remove(keys[i]);
        i += 1;
        if (i == keys.len) i = 5000;
    }
    b.keepAlive(&filter);
}
