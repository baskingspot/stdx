//! A set of timers over `Io.Timestamp`, backed by `std.Treap`.
//!
//! An experiment: Go's `time` package mirrored onto Zig without
//! goroutines. The collection owns no clock and no wake machinery —
//! the caller drives every tick: a loop sleeps until `next()` and
//! calls `expire(now)` when it wakes, which fires everything due.
//!
//! The entries are intrusive and caller-owned, `std.Treap`'s own
//! shape: nothing is allocated, nothing is created by the
//! collection. The caller constructs a `Timer` — standalone, in an
//! array, or embedded in a connection record — and arms it into a
//! `Timers`. `arm` links it, `stop` unlinks it, and the node pointer
//! is the handle: removal is by node, never by key search.
//!
//! Callbacks follow libxev's shape: the callback receives the
//! collection and the `Timer` back, and `@fieldParentPtr` recovers
//! the caller's enclosing record — no separate context pointer.
//! Callbacks run inside `expire`, after the tree surgery on their
//! own entry is complete, so a callback may arm, reset, or stop any
//! timer, including its own.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Order = std.math.Order;
const Treap = std.Treap;
const assert = std.debug.assert;

/// The tree key: deadline first, a monotone sequence second so equal
/// deadlines do not collide — the treap is a set — and ties fire in
/// insertion order.
const Key = struct {
    deadline: Io.Timestamp,
    seq: u64,
};

fn keyOrder(a: Key, b: Key) Order {
    if (a.deadline.nanoseconds < b.deadline.nanoseconds) return .lt;
    if (a.deadline.nanoseconds > b.deadline.nanoseconds) return .gt;
    if (a.seq < b.seq) return .lt;
    if (a.seq > b.seq) return .gt;
    return .eq;
}

/// A disarm-only callback for timers whose fire is observed by
/// `armed` and `next()` rather than a callback: a free function, the
/// `void`-record shape of `arm`'s typed callbacks.
pub fn disarm(_: void, _: *Timers, _: *Timer) Action {
    return .disarm;
}

/// What `expire` does with a timer after its callback returns:
/// re-arm a period timer for its next fire, or let it stay fired.
pub const Action = enum { disarm, rearm };

/// The erased callback shape `expire` invokes: the collection and the
/// entry back. Typed callbacks are stored through an inlining wrapper
/// built by `arm` — libxev's trick — so a fire costs one call through
/// this pointer with the typed body inlined into the wrapper, the
/// same indirection libxev carries.
pub const Callback = *const fn (timers: *Timers, timer: *Timer) Action;

/// One timer, caller-owned. Construct it anywhere; `arm` links it
/// into a `Timers` and the node is the handle.
pub const Timer = struct {
    node: Treap(Key, keyOrder).Node,
    /// A period re-arms the timer each time it fires: Go's `Ticker`.
    /// The next deadline is the fired deadline plus the period, not
    /// the caller's `now`, so drift never accumulates.
    period: ?Io.Duration,
    /// Invoked by `expire` after the entry's tree surgery is
    /// complete. A null callback fires silently — `armed` is the
    /// observable state.
    callback: ?Callback,
    /// True between `arm` and fire-or-`stop`. `stop` and `reset`
    /// report it: false means the timer already fired or was stopped.
    armed: bool,

    /// The one-shot timer: no period, no callback — arm it, it fires
    /// once. The fields carry no defaults, so a bare `.{}` does not
    /// construct. Embed `.one_shot` as a record field default for the
    /// common embedded shape.
    pub const one_shot: Timer = .{
        .node = undefined,
        .period = null,
        .callback = null,
        .armed = false,
    };

    /// The repeating timer: it fires, and `.rearm` from its callback
    /// re-arms it at the fired deadline plus this period. The Go
    /// split — `NewTimer` vs `NewTicker` — without a second type.
    pub fn repeat(period: Io.Duration) Timer {
        return .{
            .node = undefined,
            .period = period,
            .callback = null,
            .armed = false,
        };
    }

    /// The armed deadline, or the last one a fired or stopped timer
    /// had. The timer must have been armed at least once: the node
    /// key of a never-armed timer is undefined.
    pub fn deadline(self: *const Timer) Io.Timestamp {
        return self.node.key.deadline;
    }
};

/// A set of timers over `Io.Timestamp`. No clock, no wake, no
/// allocation: the caller drives ticks and owns every entry. One
/// loop owns the set: no method is thread-safe, and no atomics are
/// involved.
pub const Timers = struct {
    treap: Treap(Key, keyOrder),
    /// The tie-breaking sequence: equal deadlines fire in arm order.
    /// Wraps at 2^64 arms — ~585,000 years at a million arms a second,
    /// where wrapped ties would sort before live ones. Unreachable in
    /// practice; a process that lives that long can re-create its
    /// timers.
    seq: u64,

    pub const empty: Timers = .{ .treap = .{}, .seq = 0 };

    /// Arm a timer to fire at `at`. The timer must not be armed.
    /// Arming an already-armed timer is a caller bug the assert
    /// makes loud; `reset` is the re-arm path.
    ///
    /// `cb` is the typed callback, inlined through the stored erased
    /// pointer (libxev's trick): its first parameter is the enclosing
    /// record's pointer type, and the wrapper recovers the record by
    /// `@fieldParentPtr("timer", ...)` — so the record's `Timer` field
    /// must be named `timer`. A `void` first parameter arms a timer
    /// that is not embedded anywhere.
    pub fn arm(
        self: *Timers,
        timer: *Timer,
        at: Io.Timestamp,
        comptime cb: anytype,
    ) void {
        self.armNode(timer, at);
        timer.callback = wrapCallback(cb);
    }

    /// The tree surgery of `arm`, without the callback: the re-arm
    /// path (`reset`, `expire`'s ticker continuation) keeps the
    /// callback the timer already carries.
    fn armNode(self: *Timers, timer: *Timer, at: Io.Timestamp) void {
        assert(!timer.armed);
        // A zero period would re-arm at the fired deadline, which is
        // still due: `expire` would spin on it forever. Go panics on
        // `NewTicker(0)`; the assert is the same refusal, louder.
        if (timer.period) |period| assert(period.nanoseconds > 0);
        self.seq +%= 1;
        var entry = self.treap.getEntryFor(.{ .deadline = at, .seq = self.seq });
        entry.set(&timer.node);
        timer.armed = true;
    }

    /// Build the erased callback that inlines the typed one. The
    /// wrapper recovers the record by fieldParentPtr when the
    /// callback's first parameter is a record pointer, and passes
    /// nothing for `void`.
    fn wrapCallback(comptime cb: anytype) Callback {
        const record_type = @typeInfo(@TypeOf(cb)).@"fn".params[0].type.?;
        if (record_type != void) {
            return (struct {
                fn wrapper(timers: *Timers, timer: *Timer) Action {
                    const record: record_type = @fieldParentPtr("timer", timer);
                    return @call(.always_inline, cb, .{ record, timers, timer });
                }
            }).wrapper;
        }
        return (struct {
            fn wrapper(timers: *Timers, timer: *Timer) Action {
                return @call(.always_inline, cb, .{ {}, timers, timer });
            }
        }).wrapper;
    }

    /// Stop an armed timer. Returns true if it was armed and is now
    /// stopped; false if it had already fired or been stopped —
    /// Go's `Timer.Stop` semantics, without the channel to drain.
    pub fn stop(self: *Timers, timer: *Timer) bool {
        if (!timer.armed) return false;
        var entry = self.treap.getEntryForExisting(&timer.node);
        entry.set(null);
        timer.armed = false;
        return true;
    }

    /// Re-arm a timer to fire at `at`, armed or fired. Returns true
    /// if it was still armed (reset before firing); false if it had
    /// fired or been stopped — Go 1.23 `Reset` semantics. There is
    /// no stale-delivery race to reason about: nothing is delivered
    /// except inside `expire`, and `false` only means it fired.
    pub fn reset(self: *Timers, timer: *Timer, at: Io.Timestamp) bool {
        const was_armed = timer.armed;
        if (was_armed) {
            var entry = self.treap.getEntryForExisting(&timer.node);
            entry.set(null);
            timer.armed = false;
        }
        // The re-arm keeps the callback the timer carries.
        self.armNode(timer, at);
        return was_armed;
    }

    /// The earliest armed deadline, what a loop sleeps toward:
    /// `Io.Timeout` sleeps until this minus now. Null when nothing
    /// is armed — a loop with a null `next` sleeps on its other
    /// events.
    pub fn next(self: *const Timers) ?Io.Timestamp {
        const min = self.treap.getMin() orelse return null;
        return min.key.deadline;
    }

    /// Fire everything due at `now`, earliest first, ties in arm
    /// order. A period timer re-arms at its deadline plus its period
    /// when its callback returns `.rearm`, so the callback runs with
    /// the entry disarmed and decides the next fire. Callbacks run
    /// with the caller's tree consistent: a callback may arm, reset,
    /// or stop any timer, including its own.
    pub fn expire(self: *Timers, now: Io.Timestamp) void {
        while (self.treap.getMin()) |min| {
            if (min.key.deadline.nanoseconds > now.nanoseconds) return;
            const timer: *Timer = @fieldParentPtr("node", min);
            // Both read before the callback: the fired deadline is the
            // no-drift anchor even if the callback re-arms this timer
            // itself (which overwrites the node's key), and the period
            // is fixed at fire time — a callback that retunes its own
            // period uses `reset`.
            const fired = min.key.deadline;
            const period = timer.period;
            var entry = self.treap.getEntryForExisting(min);
            entry.set(null);
            timer.armed = false;
            const action: Action = if (timer.callback) |cb|
                cb(self, timer)
            else
                .disarm;
            // After the callback the timer is touched only on this
            // path: a callback that frees its own record must return
            // `.disarm`, and this condition reads nothing of the timer
            // when it does.
            if (period) |p| {
                if (action == .rearm and !timer.armed) {
                    // The ticker re-arm: fire then re-arm, the next
                    // deadline anchored to the fired one, so drift
                    // never accumulates. The callback is kept. A
                    // callback that re-armed this timer itself wins;
                    // the returned `.rearm` is then moot.
                    self.armNode(timer, fired.addDuration(p));
                }
            } else {
                // A one-shot has no next deadline: .rearm has nothing
                // to re-arm it to.
                assert(action == .disarm);
            }
        }
    }
};

test "arm, next, expire fires one-shot in deadline order" {
    var timers: Timers = .empty;
    var early: Timer = .one_shot;
    var late: Timer = .one_shot;

    try testing.expectEqual(@as(?Io.Timestamp, null), timers.next());
    timers.arm(&early, .fromNanoseconds(100), disarm);
    timers.arm(&late, .fromNanoseconds(200), disarm);
    try testing.expectEqual(Io.Timestamp.fromNanoseconds(100), timers.next().?);

    timers.expire(.fromNanoseconds(150));
    try testing.expect(!early.armed);
    try testing.expect(late.armed);
    try testing.expectEqual(Io.Timestamp.fromNanoseconds(200), timers.next().?);

    timers.expire(.fromNanoseconds(200));
    try testing.expect(!late.armed);
    try testing.expectEqual(@as(?Io.Timestamp, null), timers.next());
}

test "stop and reset carry Go's semantics" {
    var timers: Timers = .empty;
    var timer: Timer = .one_shot;

    // Stop before firing: true. Stop again: false (already stopped).
    timers.arm(&timer, .fromNanoseconds(100), disarm);
    try testing.expect(timers.stop(&timer));
    try testing.expect(!timers.stop(&timer));

    // Reset a stopped timer: false (it was not armed). Reset carries the
    // callback forward.
    try testing.expect(!timers.reset(&timer, .fromNanoseconds(300)));
    try testing.expect(timer.armed);
    try testing.expectEqual(Io.Timestamp.fromNanoseconds(300), timers.next().?);

    // Reset an armed timer: true (it had not fired).
    try testing.expect(timers.reset(&timer, .fromNanoseconds(400)));

    // After firing: stop reports false, reset reports false.
    timers.expire(.fromNanoseconds(400));
    try testing.expect(!timers.stop(&timer));
    try testing.expect(!timers.reset(&timer, .fromNanoseconds(500)));
    try testing.expect(timer.armed);
}

test "equal deadlines fire in arm order" {
    var timers: Timers = .empty;
    var fired: [4]u32 = @splat(0);

    // The records embed their timers; the typed callback receives the
    // record and never writes fieldParentPtr itself.
    const Record = struct {
        const Self = @This();

        timer: Timer = .one_shot,
        index: u32,
        fired: *u32,

        fn onFire(self: *Self, _: *Timers, _: *Timer) Action {
            self.fired.* = self.index + 1;
            return .disarm;
        }
    };
    var records: [4]Record = undefined;
    for (&records, &fired, 0..) |*record, *mark, i| {
        record.* = .{ .index = @intCast(i), .fired = mark };
        timers.arm(&record.timer, .fromNanoseconds(100), Record.onFire);
    }
    timers.expire(.fromNanoseconds(100));
    for (fired, 0..) |value, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), value);
    }
}

test "a period timer re-arms without drift, and .disarm stops it" {
    var timers: Timers = .empty;

    const Tick = struct {
        const Self = @This();

        timer: Timer = .one_shot,
        ticks: *u32,
        stop_after: u32,

        fn onTick(self: *Self, _: *Timers, _: *Timer) Action {
            self.ticks.* += 1;
            return if (self.ticks.* < self.stop_after) .rearm else .disarm;
        }
    };
    var ticks: u32 = 0;
    var tick: Tick = .{ .timer = .repeat(.fromNanoseconds(10)), .ticks = &ticks, .stop_after = 3 };
    timers.arm(&tick.timer, .fromNanoseconds(100), Tick.onTick);

    // Three fires at 100, 110, 120: the deadlines stay anchored, so
    // expiring late still fires only what is due.
    timers.expire(.fromNanoseconds(105));
    try testing.expectEqual(@as(u32, 1), ticks);
    timers.expire(.fromNanoseconds(111));
    try testing.expectEqual(@as(u32, 2), ticks);
    timers.expire(.fromNanoseconds(1000));
    try testing.expectEqual(@as(u32, 3), ticks);

    // The callback's .disarm stopped it inside its third fire.
    try testing.expect(!tick.timer.armed);
    try testing.expectEqual(@as(?Io.Timestamp, null), timers.next());
}

test "a callback may arm, reset, and stop timers, including its own" {
    var timers: Timers = .empty;
    var stop_result: bool = true;
    var chained_armed: Timer = .one_shot;

    const Fixture = struct {
        const Self = @This();

        timer: Timer = .one_shot,
        stop_result: *bool,
        chained: *Timer,

        fn onFire(self: *Self, ts: *Timers, t: *Timer) Action {
            // Arm another timer from inside the callback: a future
            // deadline. A past-due one would fire in this same drain —
            // the loop re-checks the minimum after every callback —
            // which is the honest behavior: it is due.
            ts.arm(self.chained, .fromNanoseconds(150), disarm);
            // Stop this own one-shot: the surgery is done, so the
            // stop reports false — it already fired.
            self.stop_result.* = ts.stop(t);
            return .disarm;
        }
    };

    var fixture: Fixture = .{ .stop_result = &stop_result, .chained = &chained_armed };
    timers.arm(&fixture.timer, .fromNanoseconds(100), Fixture.onFire);
    timers.expire(.fromNanoseconds(100));
    try testing.expect(!stop_result);
    try testing.expect(chained_armed.armed);
    try testing.expectEqual(Io.Timestamp.fromNanoseconds(150), timers.next().?);
}

test "a ticker callback decides its re-arm" {
    var timers: Timers = .empty;

    const Tick = struct {
        const Self = @This();

        timer: Timer = .one_shot,
        observed_armed: bool = true,
        fires: u32 = 0,

        fn onTick(self: *Self, _: *Timers, t: *Timer) Action {
            // The callback runs between the fire and the re-arm, so
            // it sees the entry disarmed — the decision is pending.
            self.observed_armed = t.armed;
            self.fires += 1;
            return if (self.fires < 2) .rearm else .disarm;
        }
    };
    var tick: Tick = .{ .timer = .repeat(.fromNanoseconds(10)) };
    timers.arm(&tick.timer, .fromNanoseconds(100), Tick.onTick);
    timers.expire(.fromNanoseconds(100));
    try testing.expect(!tick.observed_armed);
    // The returned .rearm armed it for the next fire, anchored.
    try testing.expect(tick.timer.armed);
    try testing.expectEqual(Io.Timestamp.fromNanoseconds(110), timers.next().?);

    // The second fire's .disarm lets the ticker die from inside.
    timers.expire(.fromNanoseconds(110));
    try testing.expect(!tick.timer.armed);
    try testing.expectEqual(@as(?Io.Timestamp, null), timers.next());
}

test "a period callback that re-arms its own timer wins over the returned .rearm" {
    // Regression shape: a callback that re-arms its own period timer
    // AND returns .rearm once double-inserted the node — Debug
    // asserted, ReleaseFast cycled the treap and hung the loop
    // forever. The re-arm is now conditional: the callback's own arm
    // wins, and the pending .rearm is moot. The anchor is the fired
    // deadline even when the callback overwrote the key.
    var timers: Timers = .empty;
    var ticks: u32 = 0;

    const Tick = struct {
        const Self = @This();

        timer: Timer = .one_shot,
        ticks: *u32,
        rearmed_once: bool = false,

        fn onTick(self: *Self, ts: *Timers, t: *Timer) Action {
            self.ticks.* += 1;
            if (!self.rearmed_once) {
                self.rearmed_once = true;
                // The callback re-arms its own timer to an absolute
                // future deadline: this wins.
                ts.arm(t, .fromNanoseconds(500), Self.onTick);
            }
            return .rearm;
        }
    };
    var tick: Tick = .{ .timer = .repeat(.fromNanoseconds(10)), .ticks = &ticks };
    timers.arm(&tick.timer, .fromNanoseconds(100), Tick.onTick);
    // Returns: the self-arm's 500 is the armed deadline, not the
    // fired 100 plus the period 10.
    timers.expire(.fromNanoseconds(100));
    try testing.expectEqual(@as(u32, 1), ticks);
    try testing.expectEqual(Io.Timestamp.fromNanoseconds(500), timers.next().?);
}

/// The void-first-parameter callback: a timer not embedded in any
/// record. The wrapper passes nothing for the record.
fn voidFirst(_: void, _: *Timers, _: *Timer) Action {
    return .disarm;
}

test "arm" {
    var timers: Timers = .empty;
    var bare: Timer = .one_shot;
    timers.arm(&bare, .fromNanoseconds(100), voidFirst);
    timers.expire(.fromNanoseconds(100));
    try testing.expect(!bare.armed);
    try testing.expectEqual(@as(?Io.Timestamp, null), timers.next());
}
