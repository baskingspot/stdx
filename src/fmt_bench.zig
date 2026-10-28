//! The fmt module's benchmarks: strict integer parsing, checked and
//! unchecked.

const testingx = @import("testingx");

const stdx = @import("stdx");
const fmt = stdx.fmt;

pub fn benchmarkAtoi(b: *testingx.B) !void {
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const text = b.blackBox("123456789");
        sink +%= try fmt.atoi(u64, text);
    }
}

pub fn benchmarkAtoiUnchecked(b: *testingx.B) !void {
    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const text = b.blackBox("123456789");
        sink +%= try fmt.atoiUnchecked(u64, text);
    }
}
