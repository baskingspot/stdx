//! stdx — shared standard-library extensions.

const std = @import("std");

pub const ArrayBuffer = @import("array_buffer.zig").ArrayBuffer;
pub const array_hash_map = @import("array_hash_map.zig");
pub const BoundedWriter = @import("BoundedWriter.zig");
pub const fmtx = @import("fmtx.zig");
pub const heapx = @import("heapx.zig");
pub const memx = @import("memx.zig");
pub const multi_array = @import("multi_array.zig");
pub const netx = @import("netx.zig");
pub const posixx = @import("posixx.zig");
pub const priority_queue = @import("priority_queue.zig");
pub const randomx = @import("randomx.zig");
pub const SliceBuffer = @import("slice_buffer.zig").SliceBuffer;
pub const stdio = @import("stdio.zig");
pub const timex = @import("timex.zig");
pub const Uuid = @import("Uuid.zig");

test {
    std.testing.refAllDecls(@This());
}
