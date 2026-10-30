//! A single-threaded bump arena over chunks from a child allocator.
//!
//! `std.heap.ArenaAllocator` is thread-safe by contract, and its hot path pays
//! for that: every allocation takes an atomic add on the chunk cursor and,
//! when the alignment overshoots, a compare-exchange to give the slack back.
//! An evaluator, parser, or compiler that allocates one arena per job never
//! shares it, so those atomics buy nothing.
//!
//! `Bump(.{ ... })` returns a type with the chunk sizes fixed at comptime, the
//! way `SlabAllocator` takes its size classes. An instance holds only the
//! child allocator and the chunk list. Allocations advance a cursor, `free` is
//! a no-op, and `deinit` releases the chunks. The type presents an
//! `Allocator`, so `create`, `alloc`, and every container that takes one work
//! unchanged. Share it only when every participating thread owns a distinct
//! arena; one arena has exactly one owner.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const Alignment = mem.Alignment;
const Allocator = mem.Allocator;
const testing = std.testing;

/// Payload sizes for the chunks of a `Bump`. The first chunk holds
/// `first_chunk` bytes. A later chunk doubles its predecessor, up to
/// `max_chunk`; a request larger than that gets a chunk of its own size.
/// Payload excludes the chunk header.
pub const Config = struct {
    first_chunk: comptime_int = 256 * 1024,
    max_chunk: comptime_int = 4 * 1024 * 1024,
};

/// Returns a bump arena type. The chunk sizes are part of the type, so an
/// instance carries no configuration and the growth policy is constant.
pub fn Bump(comptime config: Config) type {
    if (config.first_chunk <= 0) @compileError("Bump first_chunk must be nonzero");
    if (config.max_chunk < config.first_chunk) @compileError("Bump max_chunk is below first_chunk");

    return struct {
        const Self = @This();

        child_allocator: Allocator,
        state: State,

        /// The chunk list without the allocator. The configuration is part of
        /// the type, so a state is two pointers. Promote it to allocate, and
        /// copy `bump.state` back afterward.
        pub const State = struct {
            /// The head of the chunk list, in allocation order.
            chunks: ?*Chunk,
            /// The chunk the next allocation tries first.
            current: ?*Chunk,

            pub const empty: State = .{ .chunks = null, .current = null };

            /// Wraps a stored state in a usable arena. The chunks themselves
            /// are shared; the head and the cursor are copied, so write the
            /// result back before the promoted value goes out of scope:
            ///
            /// ```zig
            /// var arena = self.arena.promote(gpa);
            /// defer self.arena = arena.state;
            /// ```
            pub fn promote(state: State, child_allocator: Allocator) Self {
                return .{ .child_allocator = child_allocator, .state = state };
            }
        };

        /// The two ways to empty the arena. `retain_capacity` keeps every
        /// chunk and refills them in order; `free_all` returns them to the
        /// child allocator.
        pub const ResetMode = enum { free_all, retain_capacity };

        /// Creates an empty arena. No memory is allocated until the first
        /// request.
        pub fn init(child_allocator: Allocator) Self {
            return State.empty.promote(child_allocator);
        }

        /// The `Allocator` face. A request above `max_chunk` is served by a
        /// dedicated chunk, so allocation fails only when the child allocator
        /// fails. The returned value points at `self`: do not move the arena
        /// while a derived allocator is in use.
        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        /// Releases every chunk. The arena must not be used afterwards;
        /// `reset` is the way to empty an arena that stays alive.
        pub fn deinit(self: *Self) void {
            self.freeChunks();
            self.* = undefined;
        }

        /// Empties the arena. `retain_capacity` is the cheap reset for a loop
        /// that parses or evaluates one job per round; `free_all` hands the
        /// memory back and is what `deinit` does.
        pub fn reset(self: *Self, mode: ResetMode) void {
            switch (mode) {
                .free_all => {
                    self.freeChunks();
                    self.state.chunks = null;
                    self.state.current = null;
                },
                .retain_capacity => {
                    var it = self.state.chunks;
                    while (it) |chunk| : (it = chunk.next) chunk.used = 0;
                    self.state.current = self.state.chunks;
                },
            }
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            assert(len > 0);

            // Worst-case padding for this alignment. Reserving it up front
            // makes the aligned start a pure computation on the fill path.
            const align_bytes = alignment.toByteUnits();
            const needed = math.add(usize, len, align_bytes - 1) catch return null;
            const chunk = self.ensureChunk(needed) orelse return null;

            const base = @intFromPtr(payload(chunk));
            const start = mem.alignForward(usize, base + chunk.used, align_bytes) - base;
            assert(start + len <= chunk.capacity);
            chunk.used = start + len;
            return @ptrFromInt(base + start);
        }

        fn resize(
            ctx: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            _ = alignment;
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.resizeLast(memory.ptr, memory.len, new_len) != null;
        }

        fn remap(
            ctx: *anyopaque,
            memory: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            _ = alignment;
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.resizeLast(memory.ptr, memory.len, new_len);
        }

        fn free(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {}

        /// Changes the size of the most recent allocation in place. The
        /// alignment padding before it stays untouched. Returns null for an
        /// older allocation or a request past the chunk capacity; the caller
        /// copies in that case.
        fn resizeLast(self: *Self, ptr: [*]u8, len: usize, new_len: usize) ?[*]u8 {
            assert(new_len > 0);
            const current = self.state.current orelse return null;
            const base = @intFromPtr(payload(current));
            const address = @intFromPtr(ptr);
            if (address < base) return null;
            const start = address - base;
            if (start > current.used) return null;
            if (start + len != current.used) return null;
            if (start + new_len > current.capacity) return null;
            current.used = start + new_len;
            return ptr;
        }

        /// Returns a chunk with at least `needed` bytes of payload free.
        ///
        /// A reset leaves every chunk empty, so the next round refills the
        /// list front to back without touching the child allocator. The scan
        /// checks each chunk's remaining bytes rather than assuming the ones
        /// after `current` are empty, because a `State` written back late can
        /// leave `current` behind the real cursor.
        fn ensureChunk(self: *Self, needed: usize) ?*Chunk {
            if (self.state.current) |current| {
                if (current.capacity - current.used >= needed) return current;
                var candidate = current.next;
                while (candidate) |chunk| : (candidate = chunk.next) {
                    if (chunk.capacity - chunk.used >= needed) {
                        self.state.current = chunk;
                        return chunk;
                    }
                }
            }
            return self.addChunk(needed);
        }

        fn addChunk(self: *Self, needed: usize) ?*Chunk {
            const capacity = @max(self.nextCapacity(), needed);
            const total = math.add(usize, @sizeOf(Chunk), capacity) catch return null;
            const memory = self.child_allocator.alignedAlloc(
                u8,
                .of(Chunk),
                total,
            ) catch return null;

            const chunk: *Chunk = @ptrCast(@alignCast(memory.ptr));
            chunk.* = .{
                .next = if (self.state.current) |current| current.next else null,
                .used = 0,
                .capacity = capacity,
            };
            if (self.state.current) |current| {
                current.next = chunk;
            } else {
                self.state.chunks = chunk;
            }
            self.state.current = chunk;
            return chunk;
        }

        fn nextCapacity(self: *const Self) usize {
            const current = self.state.current orelse return config.first_chunk;
            return @min(current.capacity *| 2, config.max_chunk);
        }

        fn freeChunks(self: *Self) void {
            var it = self.state.chunks;
            while (it) |chunk| {
                const next = chunk.next;
                const bytes = @as([*]u8, @ptrCast(chunk))[0 .. @sizeOf(Chunk) + chunk.capacity];
                self.child_allocator.rawFree(bytes, .of(Chunk), @returnAddress());
                it = next;
            }
        }
    };
}

const Chunk = struct {
    next: ?*Chunk,
    used: usize,
    capacity: usize,
};

fn payload(chunk: *Chunk) [*]u8 {
    return @as([*]u8, @ptrCast(chunk)) + @sizeOf(Chunk);
}

test "init" {
    const Arena = Bump(.{ .first_chunk = 64, .max_chunk = 256 });
    var bump: Arena = .init(testing.allocator);
    defer bump.deinit();

    const arena = bump.allocator();
    const value = try arena.create(u64);
    value.* = 42;
    try testing.expectEqual(@as(u64, 42), value.*);
}

test "alignment above 32 bytes" {
    const Arena = Bump(.{ .first_chunk = 128, .max_chunk = 128 });
    var bump: Arena = .init(testing.allocator);
    defer bump.deinit();

    const arena = bump.allocator();
    for (0..8) |index| {
        const memory = try arena.alignedAlloc(u8, .@"64", 40 + index);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(memory.ptr) % 64);
        @memset(memory, @intCast(index));
    }
}

test "growth keeps every pointer stable" {
    const Arena = Bump(.{ .first_chunk = 64, .max_chunk = 64 });
    var bump: Arena = .init(testing.allocator);
    defer bump.deinit();

    const arena = bump.allocator();
    var values: [100]*u64 = undefined;
    for (&values, 0..) |*slot, index| {
        slot.* = try arena.create(u64);
        slot.*.* = index;
    }
    for (values, 0..) |value, index| {
        try testing.expectEqual(@as(u64, @intCast(index)), value.*);
    }
}

test "resize and remap touch only the last allocation" {
    const Arena = Bump(.{ .first_chunk = 1024, .max_chunk = 1024 });
    var bump: Arena = .init(testing.allocator);
    defer bump.deinit();

    const arena = bump.allocator();
    const first = try arena.alloc(u8, 8);
    const last = try arena.alloc(u8, 8);

    // An older allocation never moves.
    try testing.expect(!arena.resize(first, 16));
    try testing.expect(arena.remap(first, 16) == null);

    // The most recent one grows and shrinks at the same address.
    const grown = arena.remap(last, 16) orelse return error.TestExpectedSuccess;
    try testing.expectEqual(@as(usize, 16), grown.len);
    try testing.expectEqual(@intFromPtr(last.ptr), @intFromPtr(grown.ptr));
    const shrunk = arena.remap(grown, 4) orelse return error.TestExpectedSuccess;
    try testing.expectEqual(@as(usize, 4), shrunk.len);

    // The space the shrink gave back is handed out next.
    const reused = try arena.alloc(u8, 4);
    try testing.expectEqual(@intFromPtr(shrunk.ptr) + 4, @intFromPtr(reused.ptr));

    // A grow that would leave the chunk is refused, not relocated.
    try testing.expect(!arena.resize(reused, 2000));

    // resize reports success without moving; the caller keeps the address.
    const tail = try arena.alloc(u8, 8);
    try testing.expect(arena.resize(tail, 16));
}

test "free releases nothing" {
    const Arena = Bump(.{ .first_chunk = 256, .max_chunk = 256 });
    var bump: Arena = .init(testing.allocator);
    defer bump.deinit();

    const arena = bump.allocator();
    const first = try arena.alloc(u8, 16);
    arena.free(first);
    // The cursor did not move back, so the next allocation is a new one.
    const second = try arena.alloc(u8, 16);
    try testing.expect(@intFromPtr(second.ptr) > @intFromPtr(first.ptr));
}

test "reset" {
    const Arena = Bump(.{ .first_chunk = 64, .max_chunk = 256 });
    var child: testing.FailingAllocator = .init(testing.allocator, .{});
    var bump: Arena = .init(child.allocator());
    defer bump.deinit();

    const arena = bump.allocator();
    const first = try arena.create(u64);
    // Fill past the first chunk so the list holds more than one.
    for (0..20) |_| _ = try arena.create(u64);
    const chunks = child.allocations;

    // The next round refills retained chunks without asking the child.
    bump.reset(.retain_capacity);
    const again = try arena.create(u64);
    try testing.expectEqual(@intFromPtr(first), @intFromPtr(again));
    try testing.expectEqual(chunks, child.allocations);
    try testing.expectEqual(@as(usize, 0), child.deallocations);

    // free_all returns every chunk.
    bump.reset(.free_all);
    try testing.expectEqual(chunks, child.deallocations);
    try testing.expectEqual(child.allocated_bytes, child.freed_bytes);
}

test "State" {
    const Arena = Bump(.{ .first_chunk = 64, .max_chunk = 256 });
    var child: testing.FailingAllocator = .init(testing.allocator, .{});
    var state: Arena.State = .empty;

    {
        var arena = state.promote(child.allocator());
        defer state = arena.state;
        const value = try arena.allocator().create(u64);
        value.* = 7;
    }
    const allocations = child.allocations;
    try testing.expect(allocations > 0);

    {
        var arena = state.promote(child.allocator());
        defer state = arena.state;
        // The retained chunk serves this round without a new allocation.
        _ = try arena.allocator().create(u64);
    }
    try testing.expectEqual(allocations, child.allocations);

    // Deinit is terminal: the state dies with the chunks, as in std's pools.
    var arena = state.promote(child.allocator());
    arena.deinit();
    try testing.expectEqual(child.allocations, child.deallocations);
    try testing.expectEqual(child.allocated_bytes, child.freed_bytes);
}

test "child allocation failure returns OutOfMemory" {
    const Arena = Bump(.{ .first_chunk = 64, .max_chunk = 64 });
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var bump: Arena = .init(failing.allocator());
    defer bump.deinit();

    try testing.expectError(error.OutOfMemory, bump.allocator().create(u64));
}

test "requests above max_chunk get a dedicated chunk" {
    const Arena = Bump(.{ .first_chunk = 64, .max_chunk = 64 });
    var bump: Arena = .init(testing.allocator);
    defer bump.deinit();

    const arena = bump.allocator();
    const big = try arena.alloc(u8, 4096);
    try testing.expectEqual(@as(usize, 4096), big.len);
    @memset(big, 0xab);
    try testing.expectEqual(@as(u8, 0xab), big[4095]);
}
