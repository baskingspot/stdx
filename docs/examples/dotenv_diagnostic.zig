const std = @import("std");
const dotenv = @import("stdx").dotenv;

// A line that does not fit the grammar reports where it is and what is wrong.
test "report the line that does not parse" {
    const source =
        \\PORT=8080
        \\HOST=127.0.0.1
        \\TIMEOUT.SECONDS=30
        \\
    ;

    var entries: [8]dotenv.Entry = undefined;
    var scratch: [source.len]u8 = undefined;

    // `parse` returns the error. The position comes back through the struct,
    // so a caller that only fails fast passes no options at all.
    var diagnostic: dotenv.Diagnostics = undefined;
    try std.testing.expectError(
        dotenv.Error.InvalidKey,
        dotenv.parse(source, &entries, &scratch, .{ .diagnostics = &diagnostic }),
    );

    // The offset points into the original bytes, and the line and column
    // count them.
    try std.testing.expectEqual('.', source[diagnostic.offset]);
    try std.testing.expectEqual(@as(u32, 3), diagnostic.line);
    try std.testing.expectEqual(@as(u32, 8), diagnostic.column);

    // `lineText` returns the offending line for a message or a log line.
    try std.testing.expectEqualStrings("invalid key", diagnostic.message());
    const line = dotenv.lineText(source, diagnostic.line);
    try std.testing.expectEqualStrings("TIMEOUT.SECONDS=30", line);
}
