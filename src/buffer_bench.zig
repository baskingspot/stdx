//! The buffer module's benchmarks: the append path and the queue's
//! write/consume/rebase cycle.

const testingx = @import("testingx");

const stdx = @import("stdx");
const buffer = stdx.buffer;

pub fn benchmarkArrayAppend(b: *testingx.B) !void {
    var list: buffer.Array(u32, 256) = .empty;
    var sink: u32 = 0;
    defer b.keepAlive(sink);
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        if (list.remainingCapacity() == 0) list.clear();
        list.appendAssumeCapacity(i);
        sink +%= list.get(list.len - 1);
    }
    b.keepAlive(&list);
}

pub fn benchmarkQueueReuse(b: *testingx.B) !void {
    var storage: [4096]u8 = undefined;
    var queue: buffer.Queue(u8) = .init(&storage);
    var chunk: [512]u8 = undefined;
    for (&chunk, 0..) |*byte, index| byte.* = @truncate(index);

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        queue.clear();
        @memcpy(queue.unusedCapacitySlice()[0..chunk.len], &chunk);
        queue.advanceUnchecked(chunk.len);
        queue.tossUnchecked(256);
        queue.rebase();
        sink +%= queue.bufferedLen() + queue.constBuffered()[0];
    }
    b.keepAlive(&queue);
}
