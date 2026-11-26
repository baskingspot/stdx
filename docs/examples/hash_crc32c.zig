const std = @import("std");
const hash = @import("stdx").hash;
const crc32c = hash.crc32c;

// A writer that checksums chunk by chunk stores one u32 between calls, and
// the chain equals one pass over the whole message.
test "a stored digest continues the next chunk" {
    const header = "frame:0001";
    const body = "the payload that follows the header";

    const stored = crc32c.hash(header);
    try std.testing.expectEqual(crc32c.hash(header ++ body), crc32c.append(stored, body));
}

// A hole in the middle is ordinary bytes. The chain does not restart.
test "a zero word does not reset the chain" {
    const head = "header";
    const tail = "payload";
    const hole: [8]u8 = @splat(0);

    const after_head = crc32c.hash(head);
    const after_hole = crc32c.append(after_head, &hole);
    try std.testing.expectEqual(
        crc32c.hash(head ++ hole ++ tail),
        crc32c.append(after_hole, tail),
    );
}

test "the reference check value" {
    try std.testing.expectEqual(@as(u32, 0xE306_9283), crc32c.hash("123456789"));
}
