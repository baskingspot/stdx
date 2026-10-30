//! Hash extensions to `std.hash`.
//!
//! `RapidHash` is a port of rapidhash V3: a 64-bit non-cryptographic hash
//! that takes an explicit seed, like `std.hash.Wyhash.hash`. Its output
//! reproduces upstream's reference values on every host. Upstream and
//! license are in `THIRD_PARTY.md`.

const std = @import("std");
const testing = std.testing;

pub const RapidHash = @import("hash/rapidhash.zig");

test {
    testing.refAllDecls(@This());
}
