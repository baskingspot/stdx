//! stdx — shared standard-library extensions.

const std = @import("std");

pub const ArrayBuffer = @import("array_buffer.zig").ArrayBuffer;
pub const array_hash_map = @import("array_hash_map.zig");
pub const BoundedWriter = @import("BoundedWriter.zig");
pub const fmt = @import("fmt.zig");
pub const heap = @import("heap.zig");
pub const mem = @import("mem.zig");
pub const multi_array = @import("multi_array.zig");
pub const net = @import("net.zig");
pub const posix = @import("posix.zig");
pub const priority_queue = @import("priority_queue.zig");
pub const random = @import("random.zig");
pub const SliceBuffer = @import("slice_buffer.zig").SliceBuffer;
pub const stdio = @import("stdio.zig");
pub const swiss = @import("swiss.zig");
pub const time = @import("time.zig");
pub const Uuid = @import("Uuid.zig");

test {
    std.testing.refAllDecls(@This());
}
