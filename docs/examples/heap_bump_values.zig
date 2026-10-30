const std = @import("std");
const heap = @import("stdx").heap;

// The chunk sizes are part of the type. An instance carries only the
// allocator and the chunk list.
const Arena = heap.Bump(.{
    .first_chunk = 4096,
    .max_chunk = 64 * 1024,
});

// One arena per job. The values are immutable and die together.
fn evaluate(allocator: std.mem.Allocator) !u64 {
    var total: u64 = 0;
    for (0..100) |index| {
        const value = try allocator.create(u64);
        value.* = index;
        total += value.*;
    }
    return total;
}

test "an arena per job" {
    var bump: Arena = .init(std.testing.allocator);
    defer bump.deinit();

    try std.testing.expectEqual(@as(u64, 4950), try evaluate(bump.allocator()));
}

test "a reset refills the chunks" {
    var bump: Arena = .init(std.testing.allocator);
    defer bump.deinit();

    const first = try bump.allocator().create(u64);
    bump.reset(.retain_capacity);
    const again = try bump.allocator().create(u64);
    try std.testing.expectEqual(first, again);
}

// A struct that is copied by value stores the state, not the arena, and
// promotes it where the allocations happen.
const Table = struct {
    arena: Arena.State = .empty,

    fn build(self: *Table, gpa: std.mem.Allocator, count: usize) ![]const *const u64 {
        var arena = self.arena.promote(gpa);
        defer self.arena = arena.state;

        const values = try arena.allocator().alloc(*const u64, count);
        for (values, 0..) |*slot, index| {
            const value = try arena.allocator().create(u64);
            value.* = index;
            slot.* = value;
        }
        return values;
    }

    fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        var arena = self.arena.promote(gpa);
        arena.deinit();
        self.* = undefined;
    }
};

test "a stored state" {
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);

    const values = try table.build(std.testing.allocator, 8);
    try std.testing.expectEqual(@as(u64, 7), values[7].*);
}
