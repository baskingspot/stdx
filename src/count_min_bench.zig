//! Count-Min Sketch benchmarks: `add`, `addConservative`, and `estimate` on a
//! 4x4096 `u32` sketch.

const testingx = @import("testingx");

const stdx = @import("stdx");
const count_min = stdx.count_min;

const cfg: count_min.Config = .{ .depth = 4, .width = 4096 };
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

pub fn benchmarkCountMinAdd(b: *testingx.B) !void {
    var sketch: count_min.Auto(u64, cfg) = .empty;
    var i: usize = 0;
    while (try b.loop()) {
        sketch.add(keys[i], 1);
        i += 1;
        if (i == keys.len) i = 0;
    }
    b.keepAlive(&sketch);
}

pub fn benchmarkCountMinAddConservative(b: *testingx.B) !void {
    var sketch: count_min.Auto(u64, cfg) = .empty;
    var i: usize = 0;
    while (try b.loop()) {
        sketch.addConservative(keys[i], 1);
        i += 1;
        if (i == keys.len) i = 0;
    }
    b.keepAlive(&sketch);
}

pub fn benchmarkCountMinEstimate(b: *testingx.B) !void {
    var sketch: count_min.Auto(u64, cfg) = .empty;
    for (keys) |k| sketch.add(k, 1);

    var acc: u64 = 0;
    var i: usize = 0;
    while (try b.loop()) {
        acc +%= sketch.estimate(keys[i]);
        i += 1;
        if (i == keys.len) i = 0;
    }
    b.keepAlive(acc);
}
