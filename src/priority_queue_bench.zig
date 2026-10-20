//! The priority_queue module's benchmarks: the heap push and pop path.

const std = @import("std");
const testingx = @import("testingx");

const stdx = @import("stdx");
const priority_queue = stdx.priority_queue;

fn minOrder(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

const Queue = priority_queue.Custom(u32, void, 256, minOrder);

pub fn benchmarkPriorityQueuePushPop(b: *testingx.B) !void {
    var queue: Queue = .empty;
    var sink: u32 = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        queue.clear();
        var j: u32 = 0;
        while (j < 32) : (j += 1) queue.pushAssumeCapacity(i +% j);
        while (queue.pop()) |value| sink +%= value;
    }
    b.keepAlive(sink);
    b.keepAlive(&queue);
}
