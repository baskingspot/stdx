//! The bench suite: registers each module's contextual bench file. `addMod`
//! discovers the top-level `pub fn benchmark*` declarations, and the printed
//! rows carry the module context through their names (`BenchmarkSwissSmall`,
//! `BenchmarkBloomAdd`).

const testingx = @import("testingx");

const base32 = @import("base32_bench.zig");
const bit_set = @import("bit_set_bench.zig");
const bloom = @import("bloom_bench.zig");
const btree = @import("btree_bench.zig");
const bounded_array_hash_map = @import("bounded_array_hash_map_bench.zig");
const buffer = @import("buffer_bench.zig");
const enums = @import("enums_bench.zig");
const fmt = @import("fmt_bench.zig");
const hash = @import("hash/bench.zig");
const heap = @import("heap_bench.zig");
const mem = @import("mem_bench.zig");
const multi_array = @import("multi_array_bench.zig");
const net = @import("net_bench.zig");
const priority_queue = @import("priority_queue_bench.zig");
const random = @import("random_bench.zig");
const slot_ring = @import("slot_ring_bench.zig");
const static_map = @import("static_map_bench.zig");
const swiss = @import("swiss/bench.zig");
const time = @import("time_bench.zig");
const uuid = @import("Uuid_bench.zig");
const wire = @import("wire_bench.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(base32);
    try b.addMod(bit_set);
    try b.addMod(bloom);
    try b.addMod(btree);
    try b.addMod(bounded_array_hash_map);
    try b.addMod(buffer);
    try b.addMod(enums);
    try b.addMod(fmt);
    try b.addMod(hash);
    try b.addMod(heap);
    try b.addMod(mem);
    try b.addMod(multi_array);
    try b.addMod(net);
    try b.addMod(priority_queue);
    try b.addMod(random);
    try b.addMod(slot_ring);
    try b.addMod(static_map);
    try b.addMod(swiss);
    try b.addMod(time);
    try b.addMod(uuid);
    try b.addMod(wire);
}
