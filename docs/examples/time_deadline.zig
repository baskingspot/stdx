const std = @import("std");
const Io = std.Io;
const timex = @import("stdx").time;

// A deadline reads the clock directly. A cached sample can lag by
// one tick, and a timeout must not fire late.
fn expired(started: Io.Timestamp, timeout_ms: i64) bool {
    const elapsed = started.durationTo(timex.now(.awake));
    return elapsed.toMilliseconds() >= timeout_ms;
}

test "a zero timeout is already expired" {
    try std.testing.expect(expired(timex.now(.awake), 0));
}

test "a long timeout is not" {
    try std.testing.expect(!expired(timex.now(.awake), 60_000));
}
