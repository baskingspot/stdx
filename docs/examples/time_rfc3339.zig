const std = @import("std");
const timex = @import("stdx").time;

// Logs want one fixed-width, sortable form. The precision is explicit.
test "format a log timestamp" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const timestamp = std.Io.Timestamp.fromNanoseconds(1_709_210_096_789_999_000);
    try timex.writeRfc3339(&writer, timestamp, .milliseconds);

    try std.testing.expectEqualStrings("2024-02-29T12:34:56.789Z", writer.buffered());
}

test "seconds only" {
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try timex.writeRfc3339(&writer, .fromNanoseconds(0), .seconds);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", writer.buffered());
}
