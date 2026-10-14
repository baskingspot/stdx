//! Heap extensions to `std.heap`.
//!
//! Allocator shapes std lacks: fixed-capacity pooling without a retained
//! allocator.

const std = @import("std");

const slab_allocator = @import("heapx/slab_allocator.zig");
pub const SlabAllocator = slab_allocator.SlabAllocator;

test {
    std.testing.refAllDecls(@This());
}
