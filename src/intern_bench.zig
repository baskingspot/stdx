//! The intern module's benchmarks: the chunked pool against the shape it
//! replaces — one `dupe` per name in a `swiss.String` table. The pool's claim
//! is allocation traffic, so the insert pair is the row that matters; the
//! lookup pair shows the chunked storage costs nothing on the read side.

const testingx = @import("testingx");

const std = @import("std");
const mem = std.mem;

const stdx = @import("stdx");
const intern = stdx.intern;
const swiss = stdx.swiss;

const name_count = 2000;
const name_len = 16;

/// Distinct names, 16 bytes each, the first four carrying the index so the
/// pool's copy is never confused with a duplicate.
const names: [name_count][name_len]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [name_count][name_len]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&table, 0..) |*name, index| {
        mem.writeInt(u32, name[0..4], @intCast(index), .little);
        for (name[4..]) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = 'a' + @as(u8, @truncate(state >> 56)) % 26;
        }
    }
    break :blk table;
};

/// The per-name-allocation baseline: own every name, index it in a string
/// map. Both benchmarks build it as untimed setup or timed work, and both
/// free it, so the pair stays like-for-like.
const Naive = struct {
    ids: swiss.String(u32),
    owned: std.ArrayList([]const u8),

    fn init() Naive {
        return .{ .ids = .init, .owned = .empty };
    }

    fn deinit(self: *Naive, gpa: mem.Allocator) void {
        for (self.owned.items) |bytes| gpa.free(bytes);
        self.owned.deinit(gpa);
        self.ids.deinit(gpa);
        self.* = undefined;
    }

    fn put(self: *Naive, gpa: mem.Allocator, name: []const u8) !u32 {
        if (self.ids.get(name)) |id| return id;
        const copy = try gpa.dupe(u8, name);
        errdefer gpa.free(copy);
        try self.owned.append(gpa, copy);
        const id: u32 = @intCast(self.owned.items.len - 1);
        try self.ids.put(gpa, copy, id);
        return id;
    }
};

pub fn benchmarkInternInsert(b: *testingx.B) !void {
    var sink: u32 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var pool: intern.Pool = .init;
        defer pool.deinit(b.allocator);
        for (b.blackBox(&names)) |*name| sink +%= try pool.intern(b.allocator, name);
    }
}

pub fn benchmarkInternInsertNaive(b: *testingx.B) !void {
    var sink: u32 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var table: Naive = .init();
        defer table.deinit(b.allocator);
        for (b.blackBox(&names)) |*name| sink +%= try table.put(b.allocator, name);
    }
}

pub fn benchmarkInternHit(b: *testingx.B) !void {
    var pool: intern.Pool = .init;
    defer pool.deinit(b.allocator);
    for (&names) |*name| _ = try pool.intern(b.allocator, name);

    var sink: u32 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (b.blackBox(&names)) |*name| {
            if (pool.lookup(name)) |id| sink +%= id;
        }
    }
}

pub fn benchmarkInternHitNaive(b: *testingx.B) !void {
    var table: Naive = .init();
    defer table.deinit(b.allocator);
    for (&names) |*name| _ = try table.put(b.allocator, name);

    var sink: u32 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (b.blackBox(&names)) |*name| {
            if (table.ids.get(name)) |id| sink +%= id;
        }
    }
}
