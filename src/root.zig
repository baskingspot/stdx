//! stdx — shared standard-library extensions.

const std = @import("std");
const builtin = @import("builtin");

pub const bloom = @import("bloom.zig");
pub const bounded_array_hash_map = @import("bounded_array_hash_map.zig");
pub const BoundedWriter = @import("BoundedWriter.zig");
pub const buffer = @import("buffer.zig");
pub const fmt = @import("fmt.zig");
pub const hash = @import("hash.zig");
pub const heap = @import("heap.zig");
pub const mem = @import("mem.zig");
pub const multi_array = @import("multi_array.zig");
pub const net = @import("net.zig");
/// Linux-only by design; the comptime branch prunes the import on other
/// platforms so the package builds on darwin.
pub const pages = if (builtin.os.tag == .linux) pages_mod else void;

const pages_mod = @import("pages.zig");
pub const posix = @import("posix.zig");
pub const priority_queue = @import("priority_queue.zig");
pub const random = @import("random.zig");
pub const set = @import("set.zig");
pub const static_map = @import("static_map.zig");
pub const stdio = @import("stdio.zig");
pub const swiss = @import("swiss.zig");
pub const time = @import("time.zig");
pub const Uuid = @import("Uuid.zig");

test {
    std.testing.refAllDecls(@This());
}
