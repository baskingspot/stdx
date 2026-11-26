//! Hash extensions to `std.hash`.
//!
//! `RapidHash` is a port of rapidhash V3: a 64-bit non-cryptographic hash
//! that takes an explicit seed, like `std.hash.Wyhash.hash`. Its output
//! reproduces upstream's reference values on every host. Upstream and
//! license are in `THIRD_PARTY.md`.
//!
//! `crc32c` is CRC-32C (Castagnoli), where the digest itself is the state:
//! `hash` for one buffer, and `append(digest, more)` to continue from a
//! stored one. The polynomial is not `std.hash.Crc32`'s IEEE one, and
//! `std.hash.crc.@"CRC-32/ISCSI"`'s `crc` field is a digest only on some
//! targets. The kernels are SSE4.2 on x86-64, ARMv8's `crc32c` on aarch64,
//! and slice-by-16 tables elsewhere.

const std = @import("std");
const testing = std.testing;

pub const RapidHash = @import("hash/rapidhash.zig");

pub const crc32c = @import("hash/crc32c.zig");

test {
    testing.refAllDecls(@This());
}
