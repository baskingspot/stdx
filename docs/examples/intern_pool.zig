const std = @import("std");
const intern = @import("stdx").intern;

// One pool per run. Ids are dense and stay valid until `deinit`.
test "intern a name once" {
    var names: intern.Pool = .init;
    defer names.deinit(std.testing.allocator);

    const field = try names.intern(std.testing.allocator, "field");
    const again = try names.intern(std.testing.allocator, "field");
    try std.testing.expectEqual(field, again);

    const value = try names.intern(std.testing.allocator, "value");
    try std.testing.expectEqual(@as(u32, 1), value);

    // The stored bytes come back by id, and a lookup finds them by content.
    try std.testing.expectEqualStrings("field", names.get(field));
    try std.testing.expectEqual(@as(?u32, field), names.lookup("field"));
    try std.testing.expectEqual(@as(?u32, null), names.lookup("missing"));
}

// The pool copies the bytes, so a parser can reuse its scratch buffer.
test "the pool owns the bytes" {
    var names: intern.Pool = .init;
    defer names.deinit(std.testing.allocator);

    var scratch: [4]u8 = undefined;
    @memcpy(&scratch, "name");
    const id = try names.intern(std.testing.allocator, &scratch);
    @memset(&scratch, 'x');

    try std.testing.expectEqualStrings("name", names.get(id));
}

// A table that compares names by id for the rest of the run.
const Symbols = struct {
    pool: intern.Pool = .init,

    fn declare(self: *Symbols, gpa: std.mem.Allocator, name: []const u8) !u32 {
        return self.pool.intern(gpa, name);
    }

    fn resolve(self: *const Symbols, name: []const u8) ?u32 {
        return self.pool.lookup(name);
    }

    fn deinit(self: *Symbols, gpa: std.mem.Allocator) void {
        self.pool.deinit(gpa);
        self.* = undefined;
    }
};

test "compare names as integers" {
    var symbols: Symbols = .{};
    defer symbols.deinit(std.testing.allocator);

    const field = try symbols.declare(std.testing.allocator, "field");
    const value = try symbols.declare(std.testing.allocator, "value");

    try std.testing.expect(field != value);
    try std.testing.expectEqual(@as(?u32, value), symbols.resolve("value"));
}
