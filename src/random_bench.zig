//! The random module's benchmarks: the per-thread CSPRNG fill.

const testingx = @import("testingx");

const stdx = @import("stdx");
const random = stdx.random;

pub fn benchmarkRandomFill32(b: *testingx.B) !void {
    var buffer: [32]u8 = undefined;
    random.fill(&buffer);

    var sink: u64 = 0;
    while (try b.loop()) {
        random.fill(&buffer);
        sink +%= buffer[0];
    }
    b.keepAlive(sink);
}

pub fn benchmarkRandomFill1024(b: *testingx.B) !void {
    var buffer: [1024]u8 = undefined;
    random.fill(&buffer);

    var sink: u64 = 0;
    while (try b.loop()) {
        random.fill(&buffer);
        sink +%= buffer[0] + buffer[buffer.len - 1];
    }
    b.keepAlive(sink);
}
