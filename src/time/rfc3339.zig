//! RFC 3339 timestamps in UTC: the log form, with the fractional width fixed
//! at comptime.
//!
//! The fractional width is policy, not part of the format. RFC 3339 allows
//! any number of digits after the decimal point, including none. A fixed
//! width per call keeps log lines sortable and parseable without a
//! variable-length fraction.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

/// The fractional-second width.
pub const Precision = enum {
    /// No fractional part.
    seconds,
    /// Three digits: milliseconds.
    milliseconds,
    /// Six digits: microseconds.
    microseconds,
    /// Nine digits: nanoseconds.
    nanoseconds,
};

pub const Error = Io.Writer.Error || error{
    /// The timestamp is outside the RFC 3339 four-digit year range.
    TimestampOutOfRange,
};

/// The first instant of year 0000 and the last of year 9999.
const min_timestamp_ns: i96 = -719_528 * std.time.ns_per_day;
const max_timestamp_ns: i96 = 2_932_897 * std.time.ns_per_day - 1;

/// Write `timestamp` as UTC RFC 3339: `YYYY-MM-DDTHH:MM:SS[.fff]Z`.
///
/// The precision sets the number of fractional digits. The value is
/// truncated to that width, not rounded. A year outside 0000-9999 returns
/// `error.TimestampOutOfRange`.
pub fn write(
    writer: *Io.Writer,
    timestamp: Io.Timestamp,
    comptime precision: Precision,
) Error!void {
    // Bound the input first: it keeps every cast below in range and makes the
    // year check one comparison.
    if (timestamp.nanoseconds < min_timestamp_ns or timestamp.nanoseconds > max_timestamp_ns) {
        return error.TimestampOutOfRange;
    }

    const days: i64 = @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_day));
    const day_ns: i64 = @intCast(@mod(timestamp.nanoseconds, std.time.ns_per_day));
    const seconds: u32 = @intCast(@divFloor(day_ns, std.time.ns_per_s));
    const fraction: u32 = @intCast(@mod(timestamp.nanoseconds, std.time.ns_per_s));

    const date = civilFromDays(days);
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        date.year,
        date.month,
        date.day,
        seconds / 3600,
        (seconds % 3600) / 60,
        seconds % 60,
    });
    switch (precision) {
        .seconds => {},
        .milliseconds => try writer.print(".{d:0>3}", .{fraction / std.time.ns_per_ms}),
        .microseconds => try writer.print(".{d:0>6}", .{fraction / std.time.ns_per_us}),
        .nanoseconds => try writer.print(".{d:0>9}", .{fraction}),
    }
    try writer.writeAll("Z");
}

const Date = struct { year: u16, month: u8, day: u8 };

/// Howard Hinnant's civil_from_days, with floor division so dates before the
/// Unix epoch work.
fn civilFromDays(days: i64) Date {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = @divFloor(
        doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096),
        365,
    ); // [0, 399]
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    year += @intFromBool(month <= 2);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

fn expect(timestamp_ns: i96, comptime precision: Precision, expected: []const u8) !void {
    var buffer: [40]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try write(&writer, .fromNanoseconds(timestamp_ns), precision);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test write {
    try expect(0, .seconds, "1970-01-01T00:00:00Z");
    try expect(0, .milliseconds, "1970-01-01T00:00:00.000Z");
    try expect(0, .microseconds, "1970-01-01T00:00:00.000000Z");
    try expect(0, .nanoseconds, "1970-01-01T00:00:00.000000000Z");

    // Leap day, with the fraction truncated to each requested width.
    try expect(1_709_210_096_789_999_000, .seconds, "2024-02-29T12:34:56Z");
    try expect(1_709_210_096_789_999_000, .milliseconds, "2024-02-29T12:34:56.789Z");
    try expect(1_709_210_096_789_999_000, .microseconds, "2024-02-29T12:34:56.789999Z");
    try expect(1_709_210_096_789_999_000, .nanoseconds, "2024-02-29T12:34:56.789999000Z");

    // End of a year.
    try expect(1_704_067_199_999_000_000, .milliseconds, "2023-12-31T23:59:59.999Z");

    // One nanosecond before the epoch: floor division dates it 1969, and the
    // fraction stays positive.
    try expect(-1, .nanoseconds, "1969-12-31T23:59:59.999999999Z");

    // The ends of the four-digit year range.
    try expect(min_timestamp_ns, .seconds, "0000-01-01T00:00:00Z");
    try expect(max_timestamp_ns, .nanoseconds, "9999-12-31T23:59:59.999999999Z");

    var buffer: [40]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try testing.expectError(
        error.TimestampOutOfRange,
        write(&writer, .fromNanoseconds(min_timestamp_ns - 1), .seconds),
    );
    try testing.expectError(
        error.TimestampOutOfRange,
        write(&writer, .fromNanoseconds(max_timestamp_ns + 1), .seconds),
    );
}
