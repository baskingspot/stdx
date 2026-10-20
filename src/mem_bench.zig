//! The mem module's benchmarks: the SIMD last-non-zero scan against a scalar
//! reverse loop.

const testingx = @import("testingx");

const stdx = @import("stdx");
const memx = stdx.mem;

const buffer_len = 4096;

fn scalarLastNonZero(buf: []const u8) ?usize {
    var i = buf.len;
    while (i > 0) {
        i -= 1;
        if (buf[i] != 0) return i;
    }
    return null;
}

pub fn benchmarkLastIndexOfNonZero(b: *testingx.B) !void {
    var buffer: [buffer_len]u8 = @splat(0);
    buffer[0] = 1;

    var sink: usize = 0;
    while (try b.loop()) {
        const hidden = b.blackBox(&buffer);
        sink +%= memx.lastIndexOfNonZero(hidden).?;
    }
    b.keepAlive(sink);
}

pub fn benchmarkScalarLastNonZero(b: *testingx.B) !void {
    var buffer: [buffer_len]u8 = @splat(0);
    buffer[0] = 1;

    var sink: usize = 0;
    while (try b.loop()) {
        const hidden = b.blackBox(&buffer);
        sink +%= scalarLastNonZero(hidden).?;
    }
    b.keepAlive(sink);
}
