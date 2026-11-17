const std = @import("std");
const wire = @import("stdx").wire;

// A varint carries its own length, so neither call needs a width and neither
// write needs a slot. An unsigned type writes ULEB128 and a signed type writes
// SLEB128.
test "write and read a varint" {
    var storage: [16]u8 = undefined;
    var writer: wire.Writer(.big) = .init(&storage);

    try writer.appendLeb128(u32, 624485);
    try writer.appendLeb128(i32, -123456);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xe5, 0x8e, 0x26, 0xc0, 0xbb, 0x78 },
        writer.buffered(),
    );

    var reader: wire.Reader(.big) = .init(writer.constBuffered());
    try std.testing.expectEqual(@as(u32, 624485), try reader.readLeb128(u32));
    try std.testing.expectEqual(@as(i32, -123456), try reader.readLeb128(i32));
    try std.testing.expectEqual(@as(usize, 0), reader.remaining().len);
}

// A peek returns what the read would, and the read still gets it.
test "peek at a field before reading it" {
    var reader: wire.Reader(.big) = .init("key=value");

    // The delimiter is not consumed, so the key stays available.
    try std.testing.expectEqualStrings("key", try reader.peekUntil('='));
    try std.testing.expectEqual(@as(usize, 0), reader.end);

    try std.testing.expectEqualStrings("key", try reader.readUntil('='));
    try std.testing.expectEqualStrings("value", try reader.readSlice(5));

    // A peek on a short buffer is an error, not a partial value.
    try std.testing.expectError(error.UnexpectedEof, reader.peek(u32));
    try std.testing.expectEqual(@as(usize, 0), reader.remaining().len);
}
