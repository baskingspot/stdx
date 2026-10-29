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

    // A failed parse writes the byte that stopped it, and the line and column
    // of that byte, into the caller's struct. A successful parse leaves the
    // struct alone.
    var diagnostics: dotenv.Diagnostics = undefined;
    const doc = dotenv.parse(source, &entries, &scratch, .{
        .diagnostics = &diagnostics,
    }) catch {
        std.debug.print("{s} at line {d}, column {d}\n", .{
            diagnostics.message(),
            diagnostics.line,
            diagnostics.column,
        });
        return error.BadConfig;
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
