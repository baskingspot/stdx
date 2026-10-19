const std = @import("std");
const wire = @import("stdx").wire;

// A message with a 24-bit body length: reserve the slot, write the body,
// then fill the slot.
test "write a length-prefixed message" {
    var storage: [32]u8 = undefined;
    var writer: wire.Writer(.big) = .init(&storage);

    const body_len_slot = try writer.reserve(3);
    try writer.append(u8, 0x01);
    try writer.append(u16, 0x0203);
    try writer.appendSlice("payload");

    std.mem.writeInt(u24, body_len_slot, @intCast(writer.buffered().len - 3), .big);

    try std.testing.expectEqualSlices(
        u8,
        "\x00\x00\x0a\x01\x02\x03payload",
        writer.buffered(),
    );
}

// The byte order is a comptime parameter, so the other order is its own
// type with its own stores.
test "write in little-endian" {
    var storage: [4]u8 = undefined;
    var writer: wire.Writer(.little) = .init(&storage);

    try writer.append(u16, 0x0102);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, writer.buffered());
}
