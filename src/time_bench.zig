//! The time module's benchmarks: the RFC 3339 formatter and the cached clock
//! read.

const std = @import("std");
const Io = std.Io;
const testingx = @import("testingx");

const stdx = @import("stdx");
const timex = stdx.time;

pub fn benchmarkWriteRfc3339Millis(b: *testingx.B) !void {
    var buffer: [40]u8 = undefined;
    var sink: usize = 0;
    var i: u64 = 0;
    while (try b.loop()) : (i +%= 1) {
        var writer: Io.Writer = .fixed(&buffer);
        const timestamp = Io.Timestamp.fromNanoseconds(
            1_700_000_000_000_000_000 + @as(i96, @intCast(i)) * 1_000_000,
        );
        try timex.writeRfc3339(&writer, timestamp, .milliseconds);
        sink +%= writer.buffered().len;
    }
    b.keepAlive(sink);
}

pub fn benchmarkCachedClockRead(b: *testingx.B) !void {
    var clock: timex.CachedClock(.awake) = .init;
    _ = clock.refresh();

    var sink: i128 = 0;
    while (try b.loop()) {
        const hidden = b.blackBox(&clock);
        sink +%= @as(i128, hidden.now().nanoseconds);
    }
    b.keepAlive(sink);
}
