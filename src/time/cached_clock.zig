//! A cached clock, one clock per instance: `CachedClock(.awake)` is the
//! event loop's monotonic clock, `CachedClock(.real)` its wall clock.
//! The caller owns the instance and the refresh cadence — an event
//! loop ticking it once per iteration, say. Reads during a tick are
//! one plain load instead of a clock call.
//!
//! Not thread-safe: one thread owns the instance, and refresh and
//! reads happen on that thread. A thread that wants cached time makes
//! its own — `threadlocal var clock: CachedClock(.awake) = .init;` is
//! the idiom for a per-thread cache.
//!
//! The cache is stale-never-ahead: a `now` result is never in the
//! future, and it lags true time by at most one refresh interval —
//! the refresh cadence is the granularity, and nothing else is. Good
//! for log timestamps, metrics, rate limits; wrong for deadlines and
//! timeouts — measure those with `time.now` directly.
//!
//! Elapsed time and deadlines read `.awake`; `.real` is for wall
//! timestamps. A cached `.awake` value is meaningful only inside this
//! process: monotonic readings from other processes are random numbers
//! wearing a clock's clothes, so anything crossing a process boundary
//! carries `.real`.
//!
//! The cached word is `i64` nanoseconds. `.awake` fits forever; a
//! `.real` word fits until the year 2262, and the `@intCast` in
//! `refresh` fails loud there rather than wrapping. Zero means never
//! refreshed: a cold clock reads directly.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const time = @import("../time.zig");

pub fn CachedClock(comptime clock: Io.Clock) type {
    return struct {
        const Self = @This();

        cached: i64,

        pub const init: Self = .{ .cached = 0 };

        /// Read the clock and store it. Returns the full-precision
        /// sample — the cache keeps one word.
        pub fn refresh(self: *Self) Io.Timestamp {
            const t = time.now(clock);
            self.cached = @intCast(t.nanoseconds);
            return t;
        }

        /// The cached time — stale-never-ahead, or a direct read from
        /// a cold clock.
        pub fn now(self: *Self) Io.Timestamp {
            if (self.cached != 0) return .fromNanoseconds(self.cached);
            return time.now(clock);
        }

        /// Drop the cache so the next read goes direct. A test that
        /// pins time with `refresh` restores the clock with this.
        pub fn clear(self: *Self) void {
            self.cached = 0;
        }
    };
}

test CachedClock {
    // Shape, not values. A cold clock reads direct — a fresh, boot-scale
    // timestamp, same shape as time.now(.awake).
    var clock: CachedClock(.awake) = .init;
    const wall_scale = std.time.ns_per_day * 365 * 20;
    const cold = clock.now();
    try testing.expect(cold.nanoseconds > 0);
    try testing.expect(cold.nanoseconds < wall_scale);

    // The round trip is the cache's whole wiring: refresh stores the
    // word, now() serves it back.
    const sample = clock.refresh();
    try testing.expectEqual(sample.nanoseconds, clock.now().nanoseconds);

    // clear returns it to the cold, direct-reading path.
    clock.clear();
    try testing.expect(clock.now().nanoseconds < wall_scale);

    // The generic's other arm: a wall clock serves its sample too.
    var wall_clock: CachedClock(.real) = .init;
    const wall_sample = wall_clock.refresh();
    try testing.expectEqual(wall_sample.nanoseconds, wall_clock.now().nanoseconds);
}
