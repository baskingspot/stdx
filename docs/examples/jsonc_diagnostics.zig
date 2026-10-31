const std = @import("std");
const jsonc = @import("stdx").jsonc;

// The scrub never moves a byte, so a std.json diagnostic names the same
// line and column in the file that a person wrote.
test "an error points at the source position" {
    const source =
        \\{
        \\    // The comma after the next value is missing.
        \\    "a": 1 /* the comment
        \\              spans two lines */
        \\    "b": 2
        \\}
    ;
    var buffer: [source.len]u8 = undefined;
    @memcpy(buffer[0..], source);
    try jsonc.scrubInPlace(&buffer, .{});

    var diagnostics: std.json.Diagnostics = .{};
    var scanner = std.json.Scanner.initCompleteInput(std.testing.allocator, &buffer);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diagnostics);

    const Config = struct { a: u8, b: u8 };
    const result = std.json.parseFromTokenSource(Config, std.testing.allocator, &scanner, .{});
    try std.testing.expectError(error.SyntaxError, result);

    try std.testing.expectEqual(@as(u64, 5), diagnostics.getLine());
    try std.testing.expectEqual(@as(u64, 5), diagnostics.getColumn());
}
