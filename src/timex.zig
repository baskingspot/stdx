//! Cached wall-clock time.
//!
//! Worker loops refresh a thread-local monotonic value once per tick; the
//! logger converts it to Unix time via an offset computed once at startup.
//! Both clocks are process-wide, so the offset is identical on every
//! thread, and monotonic time does not jump, so `tick + offset` stays
//! aligned to wall time for the process lifetime.
//!
//! Threads that never refresh (main, the test runner) read the clock
//! directly — one vdso call per timestamp, the uncached cost.
//!
//! std.time lost its timestamp helpers in 0.16, and Io.Clock.now needs
//! an Io the logger does not carry, so the reads go through the raw
//! `linux.clock_gettime` (vdso-backed) like the rest of this codebase.

const std = @import("std");
const linux = std.os.linux;
const time = std.time;
const testing = std.testing;
const assert = std.debug.assert;

var mono_to_wall_offset_ms: i64 = 0;

/// Compute the wall offset. Call once at startup, before workers spawn.
pub fn init() void {
    mono_to_wall_offset_ms = realtimeMs() - monotonicMs();
}

/// The thread's cached monotonic time, in ms. Null until the first
/// refresh — those callers pay the direct clock read instead.
threadlocal var tick_mono_ms: ?i64 = null;

/// Refresh the thread's cached time. The worker loop calls this once per
/// tick; every timestamp taken during the tick reuses the value.
pub fn refreshTick() void {
    _ = refreshTickUs();
}

/// Drop the thread's cached time, so that tickMs reads the clock again.
/// A test that pins the tick with refreshTick restores the thread with
/// this.
pub fn clearTick() void {
    tick_mono_ms = null;
}

/// Refresh the log cache and return the same monotonic sample in microseconds.
pub fn refreshTickUs() i64 {
    const us = monotonicUs();
    tick_mono_ms = @divFloor(us, time.us_per_ms);
    return us;
}

/// Monotonic microseconds for the bounded poll window.
pub fn monotonicUs() i64 {
    var ts: linux.timespec = undefined;
    readClock(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), time.ns_per_us);
}

/// Monotonic ms: the cached tick value on worker threads, a direct clock
/// read anywhere else. Worker paths use this instead of a fresh read.
pub inline fn tickMs() i64 {
    return tick_mono_ms orelse monotonicMs();
}

/// Wall-clock Unix ms: the cached tick value plus the startup offset on
/// worker threads, a direct clock read anywhere else.
pub inline fn wallMs() i64 {
    const mono: i64 = tick_mono_ms orelse monotonicMs();
    return mono + mono_to_wall_offset_ms;
}

/// Wall-clock Unix µs, always a direct read. The logfmt dev format wants
/// microsecond precision; its consumers are human eyes at a terminal, so
/// the per-call vdso cost is the wrong thing to optimize.
pub fn realtimeUs() i64 {
    var ts: linux.timespec = undefined;
    readClock(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), time.ns_per_us);
}

/// Monotonic ms, for deadline math (immune to wall-clock jumps).
pub fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    readClock(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), time.ns_per_ms);
}

fn realtimeMs() i64 {
    var ts: linux.timespec = undefined;
    readClock(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * time.ms_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), time.ns_per_ms);
}

/// The clock ids are compile-time-valid constants and the pointer is
/// caller-owned, so a vdso clock_gettime cannot fail on Linux.
fn readClock(clk: linux.CLOCK, ts: *linux.timespec) void {
    const rc = linux.clock_gettime(clk, ts);
    assert(linux.errno(rc) == .SUCCESS);
}

test wallMs {
    // The test thread never refreshes, so wallMs reads the clock directly.
    init();
    const a = wallMs();
    const b = wallMs();
    try testing.expect(b >= a);
    const direct = realtimeMs();
    try testing.expect(@abs(b - direct) < 5_000); // within 5s of wall time
}

test refreshTick {
    init();
    refreshTick();
    const cached = wallMs();
    // A direct read moments later is within a generous window of the
    // cached conversion — proves the cached path returns real time.
    try testing.expect(@abs(cached - realtimeMs()) < 5_000);
}

test refreshTickUs {
    init();
    const before = monotonicUs();
    const tick = refreshTickUs();
    const after = monotonicUs();
    try testing.expect(before <= tick and tick <= after);
    try testing.expectEqual(@divFloor(tick, time.us_per_ms) + mono_to_wall_offset_ms, wallMs());
}
