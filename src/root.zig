//! Extensions to the Zig 0.16 standard library: fixed-capacity containers,
//! strict parsers, IPv4 types, and the primitives std lacks.
//!
//! A module that extends a std namespace takes its name (`mem`, `fmt`, `net`,
//! `posix`, `heap`, `hash`). A concept std lacks gets its own (`bloom`,
//! `once`, `swiss`, `set`). A container family follows `std.array_hash_map`: the
//! module names the concept, and the constructors inside are `Custom`, `Auto`,
//! and `String`.
//!
//! The guide at <https://baskingspot.dev/stdx/> says which module to use for a
//! task, with examples. These pages are the reference for each symbol.

const std = @import("std");
const builtin = @import("builtin");

pub const base32 = @import("base32.zig");
pub const bit_set = @import("bit_set.zig");
pub const bloom = @import("bloom.zig");
pub const btree = @import("btree.zig");
pub const bounded_array_hash_map = @import("bounded_array_hash_map.zig");
pub const BoundedWriter = @import("BoundedWriter.zig");
pub const buffer = @import("buffer.zig");
pub const enums = @import("enums.zig");
pub const fmt = @import("fmt.zig");
pub const hash = @import("hash.zig");
pub const heap = @import("heap.zig");
pub const lru = @import("lru.zig");
pub const mem = @import("mem.zig");
pub const multi_array = @import("multi_array.zig");
pub const net = @import("net.zig");
pub const once = @import("once.zig");
const pages_mod = @import("pages.zig");
pub const posix = @import("posix.zig");
pub const prefix_map = @import("prefix_map.zig");
pub const priority_queue = @import("priority_queue.zig");
pub const random = @import("random.zig");
pub const set = @import("set.zig");
const slot_ring_mod = @import("slot_ring.zig");
pub const static_map = @import("static_map.zig");
pub const stdio = @import("stdio.zig");
pub const swiss = @import("swiss.zig");
pub const time = @import("time.zig");
pub const timers = @import("timers.zig");
pub const wire = @import("wire.zig");
pub const Uuid = @import("Uuid.zig");

/// Linux-only by design; the comptime branch prunes the import on other
/// platforms so the package builds on darwin.
pub const pages = if (builtin.os.tag == .linux) pages_mod else void;

/// Linux-only by design; the comptime branch prunes the import on other
/// platforms so the package builds on darwin.
pub const slot_ring = if (builtin.os.tag == .linux) slot_ring_mod else void;
pub const sort = @import("sort.zig");

test {
    std.testing.refAllDecls(@This());
}
