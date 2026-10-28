//! The multi_array module's benchmarks: a sum over one contiguous column.

const testingx = @import("testingx");

const stdx = @import("stdx");
const multi_array = stdx.multi_array;

const Row = struct { a: u32, b: u32 };
const List = multi_array.Buffer(Row, 1024);

pub fn benchmarkMultiArrayColumnSum(b: *testingx.B) !void {
    var list: List = .empty;
    var index: usize = 0;
    while (index < @as(usize, List.capacity)) : (index += 1) {
        const slot = list.addOneAssumeCapacity();
        list.set(slot, .{ .a = @intCast(slot), .b = 1 });
    }
    const column = list.items(.a);

    var sink: u64 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const values = b.blackBox(column);
        var sum: u64 = 0;
        for (values) |value| sum +%= value;
        sink +%= sum;
    }
    b.keepAlive(&list);
}
