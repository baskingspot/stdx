const std = @import("std");
const timex = @import("stdx").time;

// One cache per thread. The thread that ticks it owns it.
threadlocal var clock: timex.CachedClock(.awake) = .init;

// The top of every loop iteration: one real clock read.
fn tick() void {
    _ = clock.refresh();
}

// Everything else in the iteration reads the cache.
fn stamp() i96 {
    return clock.now().nanoseconds;
}

test "every read inside a tick is the same sample" {
    defer clock.clear();
    tick();
    try std.testing.expectEqual(stamp(), stamp());
}
