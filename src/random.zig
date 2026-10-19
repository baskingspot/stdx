//! Io-less secure randomness: a per-thread CSPRNG, lazily seeded once
//! from the platform's secure source — the behavior of `Io.random`
//! without the `Io`. A failed seed is fatal: there is no fallback that
//! preserves the guarantee.
//!
//! Thread-safety comes from isolation, std's own mechanism: every
//! thread owns its generator, seeded on its first `fill`, so there are
//! no locks and no atomics anywhere. The first `fill` on a thread pays
//! one syscall for the seed; every later `fill` is ChaCha out of
//! thread-local state, and no RNG state is shared to steal.

const std = @import("std");
const linux = std.os.linux;
const math = std.math;
const testing = std.testing;
const DefaultCsprng = std.Random.DefaultCsprng;
const builtin = @import("builtin");

comptime {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => @compileError("random supports Linux and macOS"),
    }
}

/// A lazily initialized `std.Random.DefaultCsprng`, mirroring the
/// wrapper `Io.Threaded` keeps per thread. `maxInt(usize)` offset means
/// never seeded — an impossible value doing sentinel duty.
const Csprng = struct {
    rng: DefaultCsprng,

    const uninitialized: Csprng = .{ .rng = .{
        .state = undefined,
        .offset = math.maxInt(usize),
    } };

    fn isInitialized(self: *const Csprng) bool {
        return self.rng.offset != math.maxInt(usize);
    }
};

threadlocal var csprng: Csprng = .uninitialized;

/// Fill `buffer` with cryptographically secure random bytes from the
/// thread's lazily seeded CSPRNG. Never fails; thread-safe by
/// isolation.
pub fn fill(buffer: []u8) void {
    if (!csprng.isInitialized()) {
        @branchHint(.unlikely);
        var seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
        secureFill(&seed);
        csprng.rng = .init(seed);
    }
    csprng.rng.fill(buffer);
}

/// One draw from the platform's secure source, for the seed.
fn secureFill(buffer: []u8) void {
    switch (builtin.os.tag) {
        // getrandom with no flags blocks until the pool is ready. Before
        // Linux 5.6 a signal can interrupt that wait, and the call returns
        // EINTR; it can also return a short count. Retry both, the way
        // std's randomSecure does. Any other error means the process has no
        // entropy source, which no fallback can repair.
        .linux => {
            var rest: []u8 = buffer;
            while (rest.len != 0) {
                const rc = linux.getrandom(rest.ptr, rest.len, 0);
                switch (linux.errno(rc)) {
                    .SUCCESS => rest = rest[@intCast(rc)..],
                    .INTR => continue,
                    else => |e| std.debug.panic(
                        "stdx: getrandom failed with {t}; no secure entropy source",
                        .{e},
                    ),
                }
            }
        },
        .macos => std.c.arc4random_buf(buffer.ptr, buffer.len),
        else => unreachable,
    }
}

test fill {
    // Shape, not values: two draws differ, and the thread's generator
    // is seeded after the first.
    var a: [16]u8 = @splat(0);
    var b: [16]u8 = @splat(0);
    fill(&a);
    try testing.expect(csprng.isInitialized());
    fill(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));

    // Zero-length fills are fine: the generator runs, nothing writes.
    fill(&.{});

    // Larger than one ChaCha block, to exercise the multi-block path.
    var big: [256]u8 = @splat(0);
    fill(&big);
    try testing.expect(!std.mem.eql(u8, big[0..64], big[64..128]));
}
