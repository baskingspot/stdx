//! A nonnegative elapsed time in one 64-bit word.
//!
//! Conversions from `std.Io.Duration` reject negative or unrepresentable values.
//! Unit constructors reject multiplication overflow. A `u64` nanosecond value
//! covers almost 585 years; an event loop never needs std's wider range here.

const std = @import("std");
const Io = std.Io;
const math = std.math;
const time = std.time;
const testing = std.testing;

const Duration = @This();

nanoseconds: u64,

pub const zero: Duration = .{ .nanoseconds = 0 };

pub const Error = error{
    /// A std value is negative or does not fit in a `u64`, or arithmetic exceeds
    /// the duration's range.
    OutOfRange,
};

pub fn fromNanoseconds(value: u64) Duration {
    return .{ .nanoseconds = value };
}

pub fn fromMicroseconds(value: u64) Error!Duration {
    return scaled(value, time.ns_per_us);
}

pub fn fromMilliseconds(value: u64) Error!Duration {
    return scaled(value, time.ns_per_ms);
}

pub fn fromSeconds(value: u64) Error!Duration {
    return scaled(value, time.ns_per_s);
}

/// Construct known nanoseconds without a failing unit conversion.
pub fn fromNanosecondsComptime(comptime value: u64) Duration {
    return .fromNanoseconds(value);
}

/// Convert known microseconds. Overflow is a compile error.
pub fn fromMicrosecondsComptime(comptime value: u64) Duration {
    return scaledComptime(value, time.ns_per_us);
}

/// Convert known milliseconds. Overflow is a compile error.
pub fn fromMillisecondsComptime(comptime value: u64) Duration {
    return scaledComptime(value, time.ns_per_ms);
}

/// Convert known seconds. Overflow is a compile error.
pub fn fromSecondsComptime(comptime value: u64) Duration {
    return scaledComptime(value, time.ns_per_s);
}

/// Convert a std duration without accepting a negative elapsed time.
pub fn fromStd(duration: Io.Duration) Error!Duration {
    const value: u64 = math.cast(u64, duration.nanoseconds) orelse return error.OutOfRange;
    return .fromNanoseconds(value);
}

/// Widen the duration for a std wait. Every value fits std's `i96`.
pub fn toStd(self: Duration) Io.Duration {
    return .fromNanoseconds(self.nanoseconds);
}

pub fn toMicroseconds(self: Duration) u64 {
    return self.nanoseconds / time.ns_per_us;
}

pub fn toMilliseconds(self: Duration) u64 {
    return self.nanoseconds / time.ns_per_ms;
}

pub fn toSeconds(self: Duration) u64 {
    return self.nanoseconds / time.ns_per_s;
}

pub fn add(self: Duration, other: Duration) Error!Duration {
    return .fromNanoseconds(math.add(u64, self.nanoseconds, other.nanoseconds) catch
        return error.OutOfRange);
}

pub fn format(self: Duration, writer: *Io.Writer) Io.Writer.Error!void {
    return self.toStd().format(writer);
}

fn scaled(value: u64, factor: u64) Error!Duration {
    return .fromNanoseconds(math.mul(u64, value, factor) catch return error.OutOfRange);
}

fn scaledComptime(comptime value: u64, comptime factor: u64) Duration {
    return comptime fromNanoseconds(math.mul(u64, value, factor) catch
        @compileError("duration does not fit in u64 nanoseconds"));
}

test Duration {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Duration));
    try testing.expectEqual(@as(usize, 8), @alignOf(Duration));
    try testing.expectEqual(@as(u64, 0), Duration.zero.nanoseconds);
}

test "unit constructors distinguish the input units" {
    const duration: Duration = try .fromMilliseconds(250);
    try testing.expectEqual(@as(u64, 250_000_000), duration.nanoseconds);
    const assigned = Duration.fromNanoseconds(250_000_000);
    try testing.expectEqual(@as(u64, 250), assigned.toMilliseconds());
    try testing.expectEqual(@as(u64, 2), (try Duration.fromSeconds(2)).toSeconds());
    const measured: Duration = try .fromMicroseconds(3_000);
    try testing.expectEqual(@as(u64, 3_000), measured.toMicroseconds());
    try testing.expectError(error.OutOfRange, Duration.fromSeconds(math.maxInt(u64)));
    const sum = Duration.fromNanoseconds(math.maxInt(u64)).add(.fromNanoseconds(1));
    try testing.expectError(error.OutOfRange, sum);
}

test "compile-time unit conversions return values" {
    const microseconds: Duration = .fromMicrosecondsComptime(42);
    try testing.expectEqual(@as(u64, 42_000), microseconds.nanoseconds);
    const milliseconds: Duration = .fromMillisecondsComptime(42);
    try testing.expectEqual(@as(u64, 42_000_000), milliseconds.nanoseconds);
    const seconds: Duration = .fromSecondsComptime(42);
    try testing.expectEqual(@as(u64, 42_000_000_000), seconds.nanoseconds);
}

test "std conversion rejects negative values and preserves the rest" {
    try testing.expectError(error.OutOfRange, Duration.fromStd(.fromSeconds(-1)));
    const beyond: Io.Duration = .fromNanoseconds(@as(i96, math.maxInt(u64)) + 1);
    try testing.expectError(error.OutOfRange, Duration.fromStd(beyond));
    for ([_]i96{ 0, 1, time.ns_per_s, math.maxInt(u64) }) |nanoseconds| {
        const converted: Duration = try .fromStd(.fromNanoseconds(nanoseconds));
        try testing.expectEqual(nanoseconds, converted.toStd().nanoseconds);
    }

    var buffer: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try (try Duration.fromMilliseconds(1500)).format(&writer);
    try testing.expectEqualStrings("1.5s", writer.buffered());
}
