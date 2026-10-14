//! stdx — shared standard-library extensions.
//!
//! Modules mirror std namespaces where they extend one (`memx` ↔ `std.mem`,
//! `netx` ↔ `std.Io.net`, `fmtx` ↔ `std.fmt`); single data structures lift
//! to top-level names, and concepts with multiple flavors get a package of
//! short names (`multi_array.{Array, Buffer}`, like `std.array_hash_map.Auto`).

const std = @import("std");

pub const ArrayBuffer = @import("array_buffer.zig").ArrayBuffer;
pub const BoundedWriter = @import("BoundedWriter.zig");
pub const fmtx = @import("fmtx.zig");
pub const heapx = @import("heapx.zig");
pub const memx = @import("memx.zig");
pub const multi_array = @import("multi_array.zig");
pub const netx = @import("netx.zig");
pub const posixx = @import("posixx.zig");
pub const simdx = @import("simdx.zig");
pub const SliceBuffer = @import("slice_buffer.zig").SliceBuffer;

test {
    std.testing.refAllDecls(@This());
}
