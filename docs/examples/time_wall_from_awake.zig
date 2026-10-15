const std = @import("std");
const Io = std.Io;
const timex = @import("stdx").time;

// The offset between the two clocks, computed once and shared.
var wall_from_awake: timex.WallFromAwake = .uninitialized;
threadlocal var clock: timex.CachedClock(.awake) = .init;

// Call once, before any thread starts.
pub fn init() void {
    wall_from_awake = .compute();
}

// A log timestamp: the tick's sample, converted to wall time.
pub fn logTimestamp() Io.Timestamp {
    return wall_from_awake.toWall(clock.now());
}

test "log timestamps are wall time and never go backwards" {
    init();
    defer clock.clear();

    _ = clock.refresh();
    const first = logTimestamp();
    try std.testing.expect(first.toSeconds() > 1_577_836_800); // after 2020

    _ = clock.refresh();
    try std.testing.expect(logTimestamp().nanoseconds >= first.nanoseconds);
}
