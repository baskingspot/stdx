const std = @import("std");
const Io = std.Io;
const Uuid = @import("stdx").Uuid;

test "generate, format, parse" {
    const id: Uuid = .v4();
    try std.testing.expectEqual(.v4, id.version());

    // The canonical form is 36 bytes.
    var text: [36]u8 = undefined;
    var writer: Io.Writer = .fixed(&text);
    try id.format(&writer);

    const parsed: Uuid = try .parse(&text);
    try std.testing.expect(id.eql(parsed));
}

test "a wrong length is an error" {
    try std.testing.expectError(error.InvalidLength, Uuid.parse("not-a-uuid"));
}
