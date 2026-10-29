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
    const diagnostic = switch (dotenv.parse(source, &entries, &scratch)) {
        .doc => return error.ExpectedDiagnostic,
        .diagnostic => |d| d,
    };

    // The offset points into the original bytes, and the line counts them.
    try std.testing.expectEqual(dotenv.Error.InvalidKey, diagnostic.problem);
    try std.testing.expectEqual(@as(u32, 3), diagnostic.line);
    try std.testing.expectEqual('.', source[diagnostic.offset]);

    // `lineText` returns the offending line for a message or a log line.
    try std.testing.expectEqualStrings("invalid key", diagnostic.message());
    const line = dotenv.lineText(source, diagnostic.line);
    try std.testing.expectEqualStrings("TIMEOUT.SECONDS=30", line);
}
