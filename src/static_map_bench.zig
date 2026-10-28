//! The static_map module's benchmarks: a lookup in a comptime table.

const testingx = @import("testingx");

const stdx = @import("stdx");
const static_map = stdx.static_map;

const Table = static_map.Auto(u8, u16, .{
    .{ 0, 0 },   .{ 1, 1 },   .{ 2, 2 },   .{ 3, 3 },
    .{ 4, 4 },   .{ 5, 5 },   .{ 6, 6 },   .{ 7, 7 },
    .{ 8, 8 },   .{ 9, 9 },   .{ 10, 10 }, .{ 11, 11 },
    .{ 12, 12 }, .{ 13, 13 }, .{ 14, 14 }, .{ 15, 15 },
});

pub fn benchmarkStaticMapGet(b: *testingx.B) !void {
    var sink: u16 = 0;
    defer b.keepAlive(sink);
    var i: u8 = 0;
    while (try b.loop()) : (i +%= 1) {
        const key = b.blackBox(&i).* & 15;
        sink +%= Table.get(key) orelse 0;
    }
}
