const std = @import("std");
const Io = std.Io;
const timers = @import("stdx").timers;

// The loop shape: expire what is due, then sleep toward next(). This
// example advances a simulated clock instead of sleeping.
test "a loop drains the timers that are due" {
    var set: timers.Timers = .empty;
    var connect: timers.Timer = .one_shot;
    var request: timers.Timer = .one_shot;
    var canceled: timers.Timer = .one_shot;

    set.arm(&connect, .fromNanoseconds(100), timers.disarm);
    set.arm(&request, .fromNanoseconds(200), timers.disarm);
    set.arm(&canceled, .fromNanoseconds(50), timers.disarm);

    // stop unlinks an armed timer and reports that it was armed.
    try std.testing.expect(set.stop(&canceled));
    try std.testing.expect(!set.stop(&canceled));

    // next() is the earliest armed deadline: what the loop sleeps
    // toward.
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(100), set.next().?);

    var wakes: u32 = 0;
    while (set.next()) |wake| {
        wakes += 1;
        set.expire(wake);
    }
    try std.testing.expectEqual(2, wakes);
    try std.testing.expect(!connect.armed);
    try std.testing.expect(!request.armed);

    // Both fired: reset re-arms the entry and reports that it had
    // already fired.
    try std.testing.expect(!set.reset(&request, .fromNanoseconds(300)));
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(300), set.next().?);
}

// A period timer: the callback returns .rearm until the tick count,
// then .disarm. The record embeds the Timer in a field named `timer`,
// so the typed callback receives the record back.
test "a period timer stops itself after three ticks" {
    const Ticker = struct {
        const Self = @This();

        timer: timers.Timer = .one_shot,
        ticks: u32 = 0,

        fn onTick(self: *Self, _: *timers.Timers, _: *timers.Timer) timers.Action {
            self.ticks += 1;
            return if (self.ticks < 3) .rearm else .disarm;
        }
    };

    var set: timers.Timers = .empty;
    var ticker: Ticker = .{ .timer = timers.Timer.repeat(.fromNanoseconds(10)) };
    set.arm(&ticker.timer, .fromNanoseconds(100), Ticker.onTick);

    // The re-arm anchors to the fired deadline: expiring late fires
    // only the ticks that are due.
    set.expire(.fromNanoseconds(105));
    set.expire(.fromNanoseconds(1000));
    try std.testing.expectEqual(3, ticker.ticks);
    try std.testing.expect(!ticker.timer.armed);
    try std.testing.expectEqual(@as(?Io.Timestamp, null), set.next());
}
