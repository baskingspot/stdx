const std = @import("std");
const priority_queue = @import("stdx").priority_queue;

const Timer = struct {
    deadline_ms: i64,
    id: u32,
};

// The comparator returns `.lt` when `a` must pop before `b`.
fn byDeadline(_: void, a: Timer, b: Timer) std.math.Order {
    return std.math.order(a.deadline_ms, b.deadline_ms);
}

// At most 64 pending timers. The queue never allocates.
const Timers = priority_queue.Custom(Timer, void, 64, byDeadline);

test "timers pop in deadline order" {
    var timers: Timers = .empty;
    try timers.push(.{ .deadline_ms = 300, .id = 1 });
    try timers.push(.{ .deadline_ms = 100, .id = 2 });
    try timers.push(.{ .deadline_ms = 200, .id = 3 });

    // Peek reads the next deadline without removing it.
    try std.testing.expectEqual(100, timers.peek().?.deadline_ms);

    try std.testing.expectEqual(2, timers.pop().?.id);
    try std.testing.expectEqual(3, timers.pop().?.id);
    try std.testing.expectEqual(1, timers.pop().?.id);
    try std.testing.expectEqual(null, timers.pop());
}
