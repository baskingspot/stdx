//! One log line per interval, with a count of the lines it held back.
//!
//! A condition that repeats per connection or per accept (a full fd table)
//! would otherwise write one line per event. The caller logs only when
//! `admit` returns a count, and puts that count in the entry.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const Io = std.Io;

const RateLimit = @This();

interval_ms: i64 = 1000,
/// The earliest time the next line may go out.
next_ms: i64 = math.minInt(i64),
/// Lines held back since the last one that went out.
suppressed: u32 = 0,

/// Null: hold this line back. Otherwise log it, with the returned count of
/// the lines held back since the previous one. `now` is a monotonic
/// sample.
pub fn admit(self: *RateLimit, now: Io.Timestamp) ?u32 {
    const now_ms = now.toMilliseconds();
    if (now_ms < self.next_ms) {
        self.suppressed +|= 1;
        return null;
    }
    self.next_ms = now_ms + self.interval_ms;
    defer self.suppressed = 0;
    return self.suppressed;
}

/// The tests' Timestamp at `x` ms: the interval math speaks ms, the
/// boundary speaks Timestamps.
fn atMs(x: i64) Io.Timestamp {
    return .fromNanoseconds(@as(i96, x) * std.time.ns_per_ms);
}

test "one line per interval, carrying the count it held back" {
    var limit: RateLimit = .{};
    try testing.expectEqual(@as(?u32, 0), limit.admit(atMs(5_000)));
    // A storm inside the interval: nothing goes out.
    for (0..49) |i| {
        const now = atMs(5_000 + @as(i64, @intCast(i)) * 20);
        try testing.expectEqual(@as(?u32, null), limit.admit(now));
    }
    try testing.expectEqual(@as(?u32, null), limit.admit(atMs(5_999)));
    // The next line reports all 50 it held back, and the count restarts.
    try testing.expectEqual(@as(?u32, 50), limit.admit(atMs(6_000)));
    try testing.expectEqual(@as(?u32, null), limit.admit(atMs(6_500)));
    try testing.expectEqual(@as(?u32, 1), limit.admit(atMs(7_000)));
    // A quiet stretch longer than the interval: the next line goes at once.
    try testing.expectEqual(@as(?u32, 0), limit.admit(atMs(60_000)));
}

test "the held-back count saturates instead of wrapping" {
    var limit: RateLimit = .{ .next_ms = math.maxInt(i64), .suppressed = math.maxInt(u32) };
    try testing.expectEqual(@as(?u32, null), limit.admit(atMs(0)));
    try testing.expectEqual(math.maxInt(u32), limit.suppressed);
}

test "admit composes with time.now" {
    const time = @import("../time.zig");
    var limit: RateLimit = .{};
    // A fresh monotonic sample on the admitted path, a suppressed one after.
    try testing.expectEqual(@as(?u32, 0), limit.admit(time.now(.awake)));
    try testing.expectEqual(@as(?u32, null), limit.admit(time.now(.awake)));
}
