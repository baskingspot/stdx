//! The bench suite: registers each module's contextual bench file. `addMod`
//! discovers the top-level `pub fn benchmark*` declarations, and the printed
//! rows carry the module context through their names (`BenchmarkSwissSmall`,
//! `BenchmarkBloomAdd`).

const testingx = @import("testingx");

const swiss = @import("swiss/bench.zig");
const bounded_array_hash_map = @import("bounded_array_hash_map_bench.zig");
const bloom = @import("bloom_bench.zig");
const hash = @import("hash/bench.zig");
const slot_ring = @import("slot_ring_bench.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(swiss);
    try b.addMod(bounded_array_hash_map);
    try b.addMod(bloom);
    try b.addMod(hash);
    try b.addMod(slot_ring);
}
