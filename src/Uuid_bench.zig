//! The Uuid module's benchmarks: v4 generation, parsing, and formatting.

const std = @import("std");
const Io = std.Io;
const testingx = @import("testingx");

const stdx = @import("stdx");
const Uuid = stdx.Uuid;

pub fn benchmarkUuidV4(b: *testingx.B) !void {
    var sink: u8 = 0;
    while (try b.loop()) {
        const id = Uuid.v4();
        sink +%= id.bytes[0];
    }
    b.keepAlive(sink);
}

pub fn benchmarkUuidParse(b: *testingx.B) !void {
    const text: [36]u8 = "01234567-89ab-cdef-0123-456789abcdef".*;
    const hidden = b.blackBox(&text);

    var sink: u8 = 0;
    while (try b.loop()) {
        const id = try Uuid.parse(hidden);
        sink +%= id.bytes[0];
    }
    b.keepAlive(sink);
}

pub fn benchmarkUuidFormat(b: *testingx.B) !void {
    const id = try Uuid.parse("01234567-89ab-cdef-0123-456789abcdef");
    var buffer: [36]u8 = undefined;

    var sink: usize = 0;
    while (try b.loop()) {
        var writer: Io.Writer = .fixed(&buffer);
        const hidden = b.blackBox(&id);
        try writer.print("{f}", .{hidden.*});
        sink +%= writer.buffered().len;
    }
    b.keepAlive(sink);
}
