//! The bit_set module's benchmarks: the reused-workspace scratch set.
//!
//! The lookup rows mirror the cache-path shape in #16: a positive lookup in
//! the last word of a warm set. The reuse rows model a request that clears
//! the set, touches a batch of offsets, and checks each one.

const testingx = @import("testingx");

const stdx = @import("stdx");
const bit_set = stdx.bit_set;

/// One request's worth of offsets, spread across the capacity. The arrays are
/// rotated per iteration so the compiler cannot fold the whole batch.
const touches = 128;

const offsets_1024 = blk: {
    var out: [touches]usize = undefined;
    for (&out, 0..) |*offset, index| offset.* = (index * 7) & 1023;
    break :blk out;
};

const offsets_10000 = blk: {
    var out: [touches]usize = undefined;
    for (&out, 0..) |*offset, index| offset.* = (index * 97) % 10000;
    break :blk out;
};

const offsets_65536 = blk: {
    var out: [touches]usize = undefined;
    for (&out, 0..) |*offset, index| offset.* = (index * 509) & 65535;
    break :blk out;
};

/// One operation is a batch of 64 positive lookups, the scale of the cache
/// path's lookup work. A single lookup rounds to 2–3 ns and hides the helper
/// call this suite exists to watch.
const lookups = 64;

fn lookupBatch(comptime capacity: usize, b: *testingx.B) !void {
    var set: bit_set.Scratch(capacity) = undefined;
    set.clear();

    // Claim the last word and set the 64 bits the batch looks up.
    var bit: usize = 0;
    while (bit < lookups) : (bit += 1) set.set(capacity - 1 - bit);

    var sink: usize = 0;
    defer b.keepAlive(sink);
    var i: usize = 0;
    while (try b.loop()) : (i += 1) {
        var found: usize = 0;
        var j: usize = 0;
        while (j < lookups) : (j += 1) {
            var index = capacity - 1 - ((i + j) & (lookups - 1));
            const hidden = b.blackBox(&index);
            found += @intFromBool(set.isSet(hidden.*));
        }
        sink +%= found;
    }
    b.keepAlive(&set);
}

pub fn benchmarkScratchLookupBatch1024(b: *testingx.B) !void {
    try lookupBatch(1024, b);
}

pub fn benchmarkScratchLookupBatch10000(b: *testingx.B) !void {
    try lookupBatch(10_000, b);
}

fn reuse(
    comptime capacity: usize,
    comptime offsets: [touches]usize,
    b: *testingx.B,
) !void {
    var set: bit_set.Scratch(capacity) = undefined;
    set.clear();

    var sink: usize = 0;
    defer b.keepAlive(sink);
    var i: usize = 0;
    while (try b.loop()) : (i += 1) {
        set.clear();
        const shift = i & (touches - 1);
        var touch: usize = 0;
        while (touch < touches) : (touch += 1) {
            const offset = offsets[(touch + shift) & (touches - 1)];
            set.set(offset);
            sink += @intFromBool(set.isSet(offset));
        }
    }
    b.keepAlive(&set);
}

pub fn benchmarkScratchReuse1024(b: *testingx.B) !void {
    try reuse(1024, offsets_1024, b);
}

pub fn benchmarkScratchReuse65536(b: *testingx.B) !void {
    try reuse(65536, offsets_65536, b);
}
