//! Heap extensions to `std.heap`.
//!
//! Allocator shapes std lacks: fixed-capacity pooling without a retained
//! allocator.

const std = @import("std");

const slab_allocator = @import("heap/slab_allocator.zig");
pub const SlabAllocator = slab_allocator.SlabAllocator;
pub const SizeClassPool = @import("heap/size_class_pool.zig").SizeClassPool;

test {
    std.testing.refAllDecls(@This());
}
