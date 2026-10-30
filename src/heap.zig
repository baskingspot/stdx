//! Heap extensions to `std.heap`.
//!
//! Allocator shapes std lacks: fixed-capacity pooling without a retained
//! allocator, and a single-threaded bump arena.

const std = @import("std");
const testing = std.testing;

pub const Bump = @import("heap/bump.zig").Bump;
pub const SizeClassPool = @import("heap/size_class_pool.zig").SizeClassPool;
const slab_allocator = @import("heap/slab_allocator.zig");
pub const SlabAllocator = slab_allocator.SlabAllocator;

test {
    testing.refAllDecls(@This());
}
