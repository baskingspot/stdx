const std = @import("std");
const sort = @import("stdx").sort;

test "radix" {
    var items = [_]u32{ 5, 1, 4, 2, 3 };
    var scratch: [items.len]u32 = undefined;
    try sort.radix(u32, &items, &scratch);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5 }, &items);
}

test "select the middle" {
    var items = [_]u32{ 5, 1, 4, 2, 3 };
    try std.testing.expectEqual(
        @as(u32, 3),
        sort.select(u32, &items, 2, {}, std.sort.asc(u32)),
    );
}
