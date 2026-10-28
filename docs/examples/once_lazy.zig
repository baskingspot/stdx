const std = @import("std");
const once = @import("stdx").once;

var calls: u32 = 0;

fn load() u32 {
    calls += 1;
    return 42;
}

test "lazy" {
    var lazy: once.Lazy(u32, load) = .empty;
    try std.testing.expectEqual(@as(u32, 42), lazy.get().*);
    try std.testing.expectEqual(@as(u32, 42), lazy.get().*);
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(lazy.isInitialized());
}

fn initWith(ctx: *u32) u32 {
    ctx.* += 1;
    return 7;
}

test "sync cell" {
    var cell: once.SyncCell(u32) = .empty;
    try std.testing.expectEqual(@as(?*u32, null), cell.get());

    var init_calls: u32 = 0;
    const value = try cell.getOrInit(std.testing.io, &init_calls, initWith);
    try std.testing.expectEqual(@as(u32, 7), value.*);
    try std.testing.expectEqual(@as(u32, 1), init_calls);
    try std.testing.expectError(error.AlreadySet, cell.set(std.testing.io, 9));
}
