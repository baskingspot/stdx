const std = @import("std");
const buffer = @import("stdx").buffer;

// A transport delivers bytes in arbitrary chunks. The queue joins them and
// the parser takes one complete length-prefixed message.
test "join chunks into a message" {
    var storage: [8]u8 = undefined;
    var queue: buffer.Queue(u8) = .init(&storage);

    // The first chunk: a length byte and part of the body.
    const first = "\x05hel";
    @memcpy(queue.unusedCapacitySlice()[0..first.len], first);
    queue.advance(first.len);

    // One length byte plus five body bytes: still incomplete.
    try std.testing.expect(queue.bufferedLen() < 1 + queue.peek(1)[0]);

    // The second chunk completes the message.
    const second = "lo";
    @memcpy(queue.unusedCapacitySlice()[0..second.len], second);
    queue.advance(second.len);

    const total = 1 + queue.peek(1)[0];
    const message = queue.take(total);
    try std.testing.expectEqualStrings("\x05hello", message);

    // The consumed bytes are still in the backing. Rebase moves the
    // unconsumed tail, which is empty here, and resets both cursors.
    queue.rebase();
    try std.testing.expectEqual(storage.len, queue.unusedCapacityLen());

    // A stray status byte before the next message is dropped in place.
    const third = "\xff\x02ok";
    @memcpy(queue.unusedCapacitySlice()[0..third.len], third);
    queue.advance(third.len);
    queue.toss(1);
    try std.testing.expectEqualStrings("\x02ok", queue.take(3));
}
