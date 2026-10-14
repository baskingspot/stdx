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
const builtin = @import("builtin");

pub const CachedClock = @import("timex/cached_clock.zig").CachedClock;

comptime {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => @compileError("timex supports Linux and macOS"),
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
    const ns = @as(i96, @intCast(ts.sec)) * std.time.ns_per_s + @as(i96, @intCast(ts.nsec));
    return .fromNanoseconds(ns);
}

test now {
    // Shape, not values. The magnitudes are what distinguish the clockid
    // mappings — a wall reading is decades past the epoch, a monotonic
    // reading is at most days of uptime — so a swapped mapping fails
    // here, where every "the clock advances" test would pass it.
    const wall_scale = std.time.ns_per_day * 365 * 20;
    try testing.expect(now(.real).nanoseconds > wall_scale);
    try testing.expect(now(.awake).nanoseconds < wall_scale);
}
