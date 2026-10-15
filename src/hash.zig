//! Hash extensions to `std.hash`.

const std = @import("std");

pub const RapidHash = @import("hash/rapidhash.zig");

test {
    std.testing.refAllDecls(@This());
}
