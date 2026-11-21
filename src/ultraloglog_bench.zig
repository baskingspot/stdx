//! UltraLogLog benchmarks: steady-state `add`, `estimate`, and `merge` at
//! `p = 14` (16 KiB, ~0.61% RSE).

const testingx = @import("testingx");

const stdx = @import("stdx");
const ultraloglog = stdx.ultraloglog;

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

pub fn benchmarkUltraLogLogAdd(b: *testingx.B) !void {
    var sketch: ultraloglog.Auto(u64, 14) = .empty;
    var i: usize = 0;
    while (try b.loop()) {
        sketch.add(keys[i]);
        i += 1;
        if (i == keys.len) i = 0;
    }
    b.keepAlive(&sketch);
}

pub fn benchmarkUltraLogLogEstimate(b: *testingx.B) !void {
    var sketch: ultraloglog.Auto(u64, 14) = .empty;
    for (keys) |k| sketch.add(k);

    var acc: f64 = 0;
    while (try b.loop()) {
        acc += sketch.estimate();
    }
    b.keepAlive(acc);
}

pub fn benchmarkUltraLogLogEstimateDense(b: *testingx.B) !void {
    var sketch: ultraloglog.Auto(u64, 14) = .empty;
    for (0..500_000) |i| sketch.add(@intCast(i));

    var acc: f64 = 0;
    while (try b.loop()) {
        acc += sketch.estimate();
    }
    b.keepAlive(acc);
}

pub fn benchmarkUltraLogLogMerge(b: *testingx.B) !void {
    var a: ultraloglog.Auto(u64, 14) = .empty;
    var other: ultraloglog.Auto(u64, 14) = .empty;
    for (keys[0..5000]) |k| a.add(k);
    for (keys[5000..]) |k| other.add(k);

    while (try b.loop()) {
        a.merge(&other);
    }
    b.keepAlive(&a);
}
