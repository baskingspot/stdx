//! A nonnegative clock reading in one 64-bit word.
//!
//! Nanoseconds since the clock's epoch cover almost 585 years. The caller picks
//! one clock, such as `.awake` for deadlines, and does not mix it with another.
//! This type identifies a point on a clock; it does not support a negative
//! elapsed time. Use `durationTo` for a later reading and `compare` for either
//! ordering. Wall-clock formatting retains `Io.Timestamp` in RFC 3339 helpers.

const std = @import("std");
const Io = std.Io;
const math = std.math;
const time = std.time;
const testing = std.testing;

const Duration = @import("Duration.zig");

const Timestamp = @This();

nanoseconds: u64,

pub const zero: Timestamp = .{ .nanoseconds = 0 };

pub const Error = Duration.Error;

pub fn fromNanoseconds(value: u64) Timestamp {
    return .{ .nanoseconds = value };
}

pub fn fromMicroseconds(value: u64) Error!Timestamp {
    return scaled(value, time.ns_per_us);
}

pub fn fromMilliseconds(value: u64) Error!Timestamp {
    return scaled(value, time.ns_per_ms);
}

pub fn fromSeconds(value: u64) Error!Timestamp {
    return scaled(value, time.ns_per_s);
}

/// Construct known nanoseconds without a failing unit conversion.
pub fn fromNanosecondsComptime(comptime value: u64) Timestamp {
    return .fromNanoseconds(value);
}

/// Convert known microseconds. Overflow is a compile error.
pub fn fromMicrosecondsComptime(comptime value: u64) Timestamp {
    return scaledComptime(value, time.ns_per_us);
}

/// Convert known milliseconds. Overflow is a compile error.
pub fn fromMillisecondsComptime(comptime value: u64) Timestamp {
    return scaledComptime(value, time.ns_per_ms);
}

/// Convert known seconds. Overflow is a compile error.
pub fn fromSecondsComptime(comptime value: u64) Timestamp {
    return scaledComptime(value, time.ns_per_s);
}

/// Convert a std timestamp. Values before the clock's epoch or beyond the
/// `u64` nanosecond range return `error.OutOfRange`.
pub fn fromStd(timestamp: Io.Timestamp) Error!Timestamp {
    const value: u64 = math.cast(u64, timestamp.nanoseconds) orelse return error.OutOfRange;
    return .fromNanoseconds(value);
}

/// Widen the reading for std. Every value fits std's `i96`.
pub fn toStd(self: Timestamp) Io.Timestamp {
    return .fromNanoseconds(self.nanoseconds);
}

pub fn toMicroseconds(self: Timestamp) u64 {
    return self.nanoseconds / time.ns_per_us;
}

pub fn toMilliseconds(self: Timestamp) u64 {
    return self.nanoseconds / time.ns_per_ms;
}

pub fn toSeconds(self: Timestamp) u64 {
    return self.nanoseconds / time.ns_per_s;
}

/// Return the timestamp after `duration`, without restarting its budget.
pub fn add(self: Timestamp, duration: Duration) Error!Timestamp {
    return .fromNanoseconds(math.add(u64, self.nanoseconds, duration.nanoseconds) catch
        return error.OutOfRange);
}

/// Return `later - self`. A later reading before this timestamp cannot become
/// a nonnegative duration and returns `error.OutOfRange`.
pub fn durationTo(self: Timestamp, later: Timestamp) Error!Duration {
    if (later.nanoseconds < self.nanoseconds) return error.OutOfRange;
    return .fromNanoseconds(later.nanoseconds - self.nanoseconds);
}

pub fn compare(self: Timestamp, other: Timestamp) math.Order {
    return math.order(self.nanoseconds, other.nanoseconds);
}

fn scaled(value: u64, factor: u64) Error!Timestamp {
    return .fromNanoseconds(math.mul(u64, value, factor) catch return error.OutOfRange);
}

fn scaledComptime(comptime value: u64, comptime factor: u64) Timestamp {
    return comptime fromNanoseconds(math.mul(u64, value, factor) catch
        @compileError("timestamp does not fit in u64 nanoseconds"));
}

test Timestamp {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Timestamp));
    try testing.expectEqual(@as(usize, 8), @alignOf(Timestamp));
    try testing.expectEqual(Timestamp.zero, Timestamp.fromNanoseconds(0));
}

test "clock values carry their unit and range" {
    const started: Timestamp = try .fromMilliseconds(84);
    const deadline: Timestamp = try started.add(try Duration.fromSeconds(2));
    try testing.expectEqual(@as(u64, 2_084_000_000), deadline.nanoseconds);
    try testing.expectEqual(@as(u64, 2), (try started.durationTo(deadline)).toSeconds());
    try testing.expectEqual(math.Order.lt, started.compare(deadline));

    try testing.expectError(error.OutOfRange, deadline.durationTo(started));
    try testing.expectError(error.OutOfRange, Timestamp.fromSeconds(math.maxInt(u64)));
    try testing.expectError(error.OutOfRange, Timestamp.fromNanoseconds(math.maxInt(u64)).add(
        .fromNanoseconds(1),
    ));
}

test "compile-time unit conversions return values" {
    const microseconds: Timestamp = .fromMicrosecondsComptime(42);
    try testing.expectEqual(@as(u64, 42_000), microseconds.nanoseconds);
    const milliseconds: Timestamp = .fromMillisecondsComptime(42);
    try testing.expectEqual(@as(u64, 42_000_000), milliseconds.nanoseconds);
    const seconds: Timestamp = .fromSecondsComptime(42);
    try testing.expectEqual(@as(u64, 42_000_000_000), seconds.nanoseconds);
}

test "std conversion checks the supported epoch" {
    try testing.expectError(error.OutOfRange, Timestamp.fromStd(.fromNanoseconds(-1)));
    const beyond: Io.Timestamp = .fromNanoseconds(@as(i96, math.maxInt(u64)) + 1);
    try testing.expectError(error.OutOfRange, Timestamp.fromStd(beyond));
    for ([_]i96{ 0, 1, time.ns_per_s, math.maxInt(u64) }) |nanoseconds| {
        const converted: Timestamp = try .fromStd(.fromNanoseconds(nanoseconds));
        try testing.expectEqual(nanoseconds, converted.toStd().nanoseconds);
    }
}
