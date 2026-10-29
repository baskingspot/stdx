const std = @import("std");
const jsonc = @import("stdx").jsonc;

const Config = struct {
    name: []const u8,
    port: u16,
    tags: []const []const u8,
};

// A config file is written by a person, so comments and a trailing comma
// are allowed. std.json still enforces every other rule.
test "read a config file with comments" {
    const source =
        \\// Name shown in logs.
        \\{
        \\    "name": "gateway", // the service name
        \\    "port": 8080,
        \\    /* An empty list is valid. */
        \\    "tags": ["edge", "internal",],
        \\}
    ;
    var config = try jsonc.parseFromSlice(Config, std.testing.allocator, source, .{}, .{});
    defer config.deinit();

    try std.testing.expectEqualStrings("gateway", config.value.name);
    try std.testing.expectEqual(@as(u16, 8080), config.value.port);
    try std.testing.expectEqual(@as(usize, 2), config.value.tags.len);
    try std.testing.expectEqualStrings("internal", config.value.tags[1]);
}
