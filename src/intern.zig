//! One copy of each distinct string, one `u32` id per string.
//!
//! A compiler, an evaluator, or a config loader reads the same handful of
//! names thousands of times: field names, environment keys, option names.
//! Interning copies each name once and turns every later comparison into an
//! integer compare.
//!
//! Bytes live in chunks. A name is copied into the tail of the current chunk,
//! and a name that does not fit gets a new chunk, so an intern allocates only
//! when a chunk fills instead of once per name. One table holds a slice per id
//! for an O(1) `get`; the map the pool is built on holds the same slices as
//! keys, hashed with `std.hash_map.StringContext`.
//!
//! The pool is unmanaged: the allocator is a parameter of `intern` and
//! `deinit`. An instance is a plain value with no hidden child pointer, so a
//! static or comptime instance costs only its fields.
//!
//! There is no deletion and no thread safety. An id stays valid until
//! `deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;

const swiss = @import("swiss.zig");

/// What `intern` can fail with: allocation, and nothing else.
pub const Error = Allocator.Error;

/// A string pool with stable ids.
///
/// Ids are dense: the first intern is 0 and each new string takes the next
/// integer. Interning bytes that are already present returns the id of the
/// stored copy, so two callers that intern equal bytes get the same id.
pub const Pool = struct {
    /// Payload bytes in one chunk. A longer name gets a chunk of its own.
    pub const chunk_size: usize = 4096;

    const Chunk = struct {
        bytes: []u8,
        used: usize,
    };

    /// Every chunk, in allocation order.
    chunks: std.ArrayList(Chunk),
    /// Index of the chunk that takes the next copy, or null before the first
    /// intern.
    current: ?usize,
    /// The stored bytes, indexed by id.
    names: std.ArrayList([]const u8),
    /// The stored bytes to id. The keys are the slices in `names`.
    ids: swiss.String(u32),

    /// A pool holding nothing.
    pub const init: Pool = .{
        .chunks = .empty,
        .current = null,
        .names = .empty,
        .ids = .init,
    };

    /// The id of `bytes`, copying the bytes into the pool on the first call.
    ///
    /// Returns the existing id when the bytes are already present. The copy is
    /// written before either table is published, so `error.OutOfMemory` leaves
    /// the pool consistent; it may hold unused chunk space.
    pub fn intern(self: *Pool, gpa: Allocator, bytes: []const u8) Error!u32 {
        if (self.ids.get(bytes)) |id| return id;

        try self.names.ensureUnusedCapacity(gpa, 1);
        const storage = try self.copy(gpa, bytes);
        const id: u32 = @intCast(self.names.items.len);
        self.names.appendAssumeCapacity(storage);
        self.ids.put(gpa, storage, id) catch |err| {
            _ = self.names.pop();
            return err;
        };
        return id;
    }

    /// The bytes for `id`. Asserts `id` is one this pool handed out.
    pub fn get(self: *const Pool, id: u32) []const u8 {
        assert(id < self.names.items.len);
        return self.names.items[id];
    }

    /// The id of `bytes` without inserting it.
    pub fn lookup(self: *const Pool, bytes: []const u8) ?u32 {
        return self.ids.get(bytes);
    }

    /// The number of distinct strings interned.
    pub fn count(self: *const Pool) usize {
        return self.names.items.len;
    }

    /// Release every chunk and both tables. The pool is undefined afterward.
    pub fn deinit(self: *Pool, gpa: Allocator) void {
        for (self.chunks.items) |chunk| gpa.free(chunk.bytes);
        self.chunks.deinit(gpa);
        self.names.deinit(gpa);
        self.ids.deinit(gpa);
        self.* = undefined;
    }

    /// Copy `bytes` into chunk storage and return the copy.
    fn copy(self: *Pool, gpa: Allocator, bytes: []const u8) Error![]u8 {
        if (self.current) |index| {
            const chunk = &self.chunks.items[index];
            if (chunk.bytes.len - chunk.used >= bytes.len) return appendTo(chunk, bytes);
        }
        // A name too long for a fresh chunk gets exactly its own size.
        const storage = try gpa.alloc(u8, @max(bytes.len, chunk_size));
        errdefer gpa.free(storage);
        try self.chunks.append(gpa, .{ .bytes = storage, .used = 0 });
        self.current = self.chunks.items.len - 1;
        return appendTo(&self.chunks.items[self.current.?], bytes);
    }

    fn appendTo(chunk: *Chunk, bytes: []const u8) []u8 {
        const slot = chunk.bytes[chunk.used..][0..bytes.len];
        @memcpy(slot, bytes);
        chunk.used += bytes.len;
        return slot;
    }
};

test "equal bytes take one id" {
    var pool: Pool = .init;
    defer pool.deinit(testing.allocator);

    const field = try pool.intern(testing.allocator, "field");
    try testing.expectEqual(@as(u32, 0), field);
    try testing.expectEqual(field, try pool.intern(testing.allocator, "field"));
    try testing.expectEqual(@as(usize, 1), pool.count());

    const value = try pool.intern(testing.allocator, "value");
    try testing.expectEqual(@as(u32, 1), value);
    try testing.expectEqual(@as(usize, 2), pool.count());

    try testing.expectEqual(@as(?u32, field), pool.lookup("field"));
    try testing.expectEqual(@as(?u32, value), pool.lookup("value"));
    try testing.expectEqual(@as(?u32, null), pool.lookup("fiel"));
    try testing.expectEqual(@as(?u32, null), pool.lookup("fields"));
    try testing.expectEqual(@as(?u32, null), pool.lookup(""));
}

test "the empty string interns like any other" {
    var pool: Pool = .init;
    defer pool.deinit(testing.allocator);

    const empty = try pool.intern(testing.allocator, "");
    try testing.expectEqual(@as(u32, 0), empty);
    try testing.expectEqualStrings("", pool.get(empty));
    try testing.expectEqual(empty, try pool.intern(testing.allocator, ""));
    try testing.expectEqual(@as(?u32, empty), pool.lookup(""));
    try testing.expectEqual(@as(usize, 1), pool.count());
}

test "names spanning chunk boundaries keep their bytes" {
    var pool: Pool = .init;
    defer pool.deinit(testing.allocator);

    // Own copies of what each id must return, so a clobbered input buffer
    // cannot hide a borrowed slice.
    var expected: std.ArrayList([]const u8) = .empty;
    defer {
        for (expected.items) |bytes| testing.allocator.free(bytes);
        expected.deinit(testing.allocator);
    }

    var buf: [6000]u8 = undefined;
    var index: usize = 0;
    while (index < 300) : (index += 1) {
        // Every seventh name is longer than a chunk; the rest fill several.
        const len = if (index % 7 == 0) 5000 + index else 8 + index % 97;
        // The index in the first four bytes makes every name distinct.
        mem.writeInt(u32, buf[0..4], @intCast(index), .little);
        for (buf[4..len], 4..) |*byte, i| byte.* = 'a' + @as(u8, @intCast((index + i) % 26));
        const copy = try testing.allocator.dupe(u8, buf[0..len]);
        try expected.append(testing.allocator, copy);

        const id = try pool.intern(testing.allocator, buf[0..len]);
        try testing.expectEqual(@as(u32, @intCast(index)), id);
        try testing.expectEqualStrings(copy, pool.get(id));
    }

    try testing.expectEqual(expected.items.len, pool.count());

    // Nothing points at the input buffer.
    @memset(&buf, 'x');
    for (expected.items, 0..) |bytes, id| {
        try testing.expectEqualStrings(bytes, pool.get(@intCast(id)));
        try testing.expectEqual(@as(?u32, @intCast(id)), pool.lookup(bytes));
    }
}

test "intern allocates on chunk boundaries, not per name" {
    var pool: Pool = .init;
    defer pool.deinit(testing.allocator);

    var buf: [8]u8 = undefined;
    @memset(buf[4..], 'a');
    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        mem.writeInt(u32, buf[0..4], @intCast(index), .little);
        const id = try pool.intern(testing.allocator, &buf);
        try testing.expectEqual(@as(u32, @intCast(index)), id);
    }

    // 1000 eight-byte names are 8000 bytes: two 4096-byte chunks, not 1000
    // allocations. The exact count is an implementation detail, so only the
    // bound is asserted.
    try testing.expect(pool.chunks.items.len <= 3);
}

fn internThenFree(gpa: Allocator) !void {
    var pool: Pool = .init;
    defer pool.deinit(gpa);

    const first = try pool.intern(gpa, "field");
    try testing.expectEqual(@as(u32, 0), first);
    try testing.expectEqual(first, try pool.intern(gpa, "field"));

    var buf: [5000]u8 = undefined;
    @memset(&buf, 'n');
    const long = try pool.intern(gpa, &buf);
    try testing.expectEqual(@as(u32, 1), long);
    try testing.expectEqualStrings(&buf, pool.get(long));
}

test "every allocation failure leaves the pool consistent" {
    try testing.checkAllAllocationFailures(testing.allocator, internThenFree, .{});
}
