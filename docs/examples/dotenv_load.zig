const std = @import("std");
const dotenv = @import("stdx").dotenv;

// A configuration file: one assignment per line, an optional `export`, a
// comment, and quotes where the value needs them.
test "read a configuration file" {
    const source =
        \\# The service configuration.
        \\PORT=8080
        \\export HOST=127.0.0.1
        \\GREETING="hello\nworld"
        \\
    ;

    // The entries are the caller's array, and the escapes need a scratch
    // buffer. `source.len` always fits, because a decoded value is never
    // longer than the text it came from.
    var entries: [8]dotenv.Entry = undefined;
    var scratch: [source.len]u8 = undefined;
    const doc = switch (dotenv.parse(source, &entries, &scratch)) {
        .doc => |doc| doc,
        .diagnostic => |d| {
            std.debug.print("{s} at line {d}\n", .{ d.message(), d.line });
            return error.BadConfig;
        },
    };

    // `get` returns the last assignment, so a duplicate key is not an error.
    try std.testing.expectEqualStrings("8080", doc.get("PORT").?);
    try std.testing.expectEqualStrings("127.0.0.1", doc.get("HOST").?);
    try std.testing.expectEqualStrings("hello\nworld", doc.get("GREETING").?);
    try std.testing.expect(doc.get("MISSING") == null);

    // Nothing is copied and nothing needs freeing: the entries point into the
    // caller's bytes.
    try std.testing.expectEqual(@as(usize, 3), doc.entries.len);
    try std.testing.expectEqual(@as(u32, 2), doc.entries[0].line);
}
