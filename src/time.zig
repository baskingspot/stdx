//! Io-less clock reads in `std.Io.Timestamp` values, for Linux and
//! macOS.
//!
//! `std.Io.Timestamp.now` wants an `Io` that code without an event loop
//! does not carry, and each read is one `clock_gettime` anyway — vDSO on
//! Linux, one libc call on macOS — so `now` goes to the raw layer
//! directly, in std's own types: `Clock` in, `Timestamp` out, and the
//! whole `Duration` conversion ladder (`toMicroseconds`,
//! `toMilliseconds`, `toSeconds`) comes with the type.
//!
//! `CachedClock` is the first-class cache: the caller owns the instance
//! and the refresh cadence — an event loop stores one and ticks it once
//! per iteration, making every timestamp during the tick one atomic
//! load instead of a clock call.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const c = std.c;
const assert = std.debug.assert;
const testing = std.testing;
const time = std.time;
const builtin = @import("builtin");

pub const CachedClock = @import("time/cached_clock.zig").CachedClock;
pub const RateLimit = @import("time/RateLimit.zig").RateLimit;

comptime {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => @compileError("time supports Linux and macOS"),
    }
}

/// Read `clock` directly. One clock call, no `Io`.
///
/// The switch is exhaustive over `Io.Clock` on purpose: if std grows
/// a clock, this becomes a compile error rather than a silent wrong
/// mapping. The `.awake` and `.boot` arms carry the per-OS mapping
/// std's `Io.Clock` docs spell out; dead platform arms are pruned, and
/// the other three clocks share members on both.
pub fn now(clock: Io.Clock) Io.Timestamp {
    const clk: posix.CLOCK = switch (clock) {
        .real => .REALTIME,
        .awake => switch (builtin.os.tag) {
            .linux => .MONOTONIC,
            .macos => .UPTIME_RAW,
            else => unreachable,
        },
        .boot => switch (builtin.os.tag) {
            .linux => .BOOTTIME,
            .macos => .MONOTONIC_RAW,
            else => unreachable,
        },
        .cpu_process => .PROCESS_CPUTIME_ID,
        .cpu_thread => .THREAD_CPUTIME_ID,
    };
    var ts: posix.timespec = undefined;
    switch (builtin.os.tag) {
        .linux => assert(linux.errno(linux.clock_gettime(clk, &ts)) == .SUCCESS),
        .macos => assert(c.clock_gettime(clk, &ts) == 0),
        else => unreachable,
    }
    const ns = @as(i96, @intCast(ts.sec)) * time.ns_per_s + @as(i96, @intCast(ts.nsec));
    return .fromNanoseconds(ns);
}

/// Wall time derived from an `.awake` sample, through the offset between
/// the two clocks computed once at process startup. Both clocks are
/// process-wide, so the offset is identical on every thread: compute it
/// once, before threads spawn, and share the value.
///
/// The pattern this serves: a loop ticks one `CachedClock(.awake)` per
/// iteration and serves both deadline math and log timestamps from that
/// single sample — deadline math reads `mono.now()`, log timestamps read
/// `toWall(mono.now())` — so a log line's timestamp is the same sample the
/// loop acted on. One clock read per tick, not two.
///
/// Derived wall never moves backwards within the process: the offset is
/// fixed and `.awake` never steps back, so timestamps keep monotonic
/// ordering — an NTP step cannot reorder log lines. The trade: derived
/// wall is not true wall; it drifts if the wall clock is stepped after
/// startup, bounded by the startup offset plus drift. For log timestamps
/// that is the right trade. True wall is what `CachedClock(.real)` and
/// `now(.real)` are for.
///
/// `offset_ns` is `i64` nanoseconds: real-minus-awake ≈ real since the
/// epoch, so it carries the same year-2262 ceiling the `CachedClock` doc
/// flags for `.real`.
pub const WallFromAwake = struct {
    offset_ns: i64,

    pub const uninitialized: WallFromAwake = .{ .offset_ns = 0 };

    /// The startup offset: read both clocks once and store the value
    /// wherever the process keeps startup state.
    pub fn compute() WallFromAwake {
        return .{
            .offset_ns = @intCast(now(.real).nanoseconds - now(.awake).nanoseconds),
        };
    }

    /// The wall time of an `.awake` sample.
    pub fn toWall(self: WallFromAwake, awake: Io.Timestamp) Io.Timestamp {
        return .fromNanoseconds(awake.nanoseconds + self.offset_ns);
    }
};

test WallFromAwake {
    // The offset is real minus awake: decades-scale, because real is
    // decades past the epoch and awake is at most days of uptime.
    const offset: WallFromAwake = .compute();
    try testing.expect(offset.offset_ns > time.ns_per_day * 365 * 20);

    // Derived wall tracks real time: toWall of a fresh awake sample lands
    // within a window of a fresh real read.
    const awake = now(.awake);
    const wall = offset.toWall(awake);
    const real = now(.real);
    try testing.expect(@abs(wall.nanoseconds - real.nanoseconds) < time.ns_per_s);

    // Ordering is preserved: two awake samples in order derive wall times
    // in the same order — the never-backwards property, structurally.
    const a = now(.awake);
    const b = now(.awake);
    try testing.expect(b.nanoseconds >= a.nanoseconds);
    try testing.expect(offset.toWall(b).nanoseconds >= offset.toWall(a).nanoseconds);

    // Composes with a cold CachedClock: a never-refreshing thread reads
    // direct, and the derivation stays correct on that direct sample.
    var mono: CachedClock(.awake) = .init;
    const derived = offset.toWall(mono.now());
    try testing.expect(derived.nanoseconds > time.ns_per_day * 365 * 20);

    // And with a refreshed one: toWall(mono.now()) is the same sample the
    // loop would act on.
    const sample = mono.refresh();
    try testing.expectEqual(
        offset.toWall(sample).nanoseconds,
        offset.toWall(mono.now()).nanoseconds,
    );
}

test now {
    // Shape, not values. The magnitudes are what distinguish the clockid
    // mappings — a wall reading is decades past the epoch, a monotonic
    // reading is at most days of uptime — so a swapped mapping fails
    // here, where every "the clock advances" test would pass it.
    const wall_scale = time.ns_per_day * 365 * 20;
    try testing.expect(now(.real).nanoseconds > wall_scale);
    try testing.expect(now(.awake).nanoseconds < wall_scale);
}
