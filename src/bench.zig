//! The bench barrel: imports each module's contextual bench file, and
//! zig-benchmark's `runModuleBenchmarks` recursion discovers every
//! benchmark through them. The naming carries the module context
//! (`BenchmarkSwissSmall`, `BenchmarkBloomAdd`), so the flat discovered
//! names stay unambiguous.

pub const swiss = @import("swiss/bench.zig");
pub const bounded_array_hash_map = @import("bounded_array_hash_map_bench.zig");
pub const bloom = @import("bloom_bench.zig");
pub const hash = @import("hash/bench.zig");
pub const slot_ring = @import("slot_ring_bench.zig");
