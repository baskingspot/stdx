const std = @import("std");
const prefix_map = @import("stdx").prefix_map;

// The tree is a constant. Shared prefixes are stored once.
const routes = prefix_map.Map(u8).initComptime(.{
    .{ "api/", 1 },
    .{ "api/v1/", 2 },
    .{ "static/", 3 },
});

test "exact and longest-prefix lookups" {
    try std.testing.expectEqual(@as(?u8, 2), routes.get("api/v1/"));
    try std.testing.expectEqual(@as(?u8, null), routes.get("api/v1/users/42"));
    try std.testing.expectEqual(@as(?u8, 2), routes.getLongestPrefix("api/v1/users/42"));
    try std.testing.expectEqual(@as(?u8, 1), routes.getLongestPrefix("api/v2/"));
    try std.testing.expectEqual(@as(?u8, 3), routes.getLongestPrefix("static/app.js"));
    try std.testing.expectEqual(@as(usize, 3), routes.count());
}

test "build at runtime" {
    const runtime = try prefix_map.Map(u8).init(.{
        .{ "api/", 1 },
        .{ "api/v1/", 2 },
        .{ "static/", 3 },
    }, std.testing.allocator);
    defer runtime.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u8, 2), runtime.getLongestPrefix("api/v1/users/42"));
}
