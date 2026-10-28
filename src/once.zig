//! Set-once values and lazy initialization.
//!
//! `Cell(T)` holds one value that is set at most once. `get` returns null
//! until the value exists. `getOrInit` initializes it on the first call and
//! returns a pointer, so later calls pay one branch.
//!
//! `Lazy(T, init)` is a cell whose initializer is fixed at compile time.
//!
//! `Cell` and `Lazy` are single-threaded. `SyncCell` and `SyncLazy` add an
//! atomic fast path and an `Io.Mutex` on the first initialization, so one
//! thread initializes while the others wait. The fast path takes no lock.
//!
//! `set` returns `error.AlreadySet` when a value exists. `take` moves the
//! value out of an unsync cell. Do not copy a cell after use.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const atomic = std.atomic;

/// A single-threaded set-once value.
pub fn Cell(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        initialized: bool,

        pub const empty: Self = .{ .value = undefined, .initialized = false };

        /// The value, or null.
        pub fn get(self: *Self) ?*T {
            if (!self.initialized) {
                @branchHint(.unlikely);
                return null;
            }
            return &self.value;
        }

        /// Whether a value has been set.
        pub fn isInitialized(self: *Self) bool {
            return self.initialized;
        }

        /// Set the value. Returns `error.AlreadySet` when one exists.
        pub fn set(self: *Self, value: T) error{AlreadySet}!void {
            if (self.initialized) return error.AlreadySet;
            self.value = value;
            self.initialized = true;
        }

        /// The value, initialized by `f` on the first call.
        pub fn getOrInit(self: *Self, ctx: anytype, comptime f: fn (@TypeOf(ctx)) T) *T {
            if (!self.initialized) {
                @branchHint(.cold);
                return self.initSlow(ctx, f);
            }
            return &self.value;
        }

        noinline fn initSlow(self: *Self, ctx: anytype, comptime f: fn (@TypeOf(ctx)) T) *T {
            self.value = f(ctx);
            self.initialized = true;
            return &self.value;
        }

        /// Like `getOrInit`, for an initializer that can fail. A failed call
        /// leaves the cell empty, so a later call can try again.
        pub fn getOrTryInit(self: *Self, ctx: anytype, comptime f: anytype) InitError(f)!*T {
            if (!self.initialized) {
                @branchHint(.cold);
                return self.tryInitSlow(ctx, f);
            }
            return &self.value;
        }

        noinline fn tryInitSlow(self: *Self, ctx: anytype, comptime f: anytype) InitError(f)!*T {
            self.value = try f(ctx);
            self.initialized = true;
            return &self.value;
        }

        /// Move the value out and empty the cell.
        pub fn take(self: *Self) ?T {
            if (!self.initialized) return null;
            self.initialized = false;
            return self.value;
        }
    };
}

/// A set-once value shared by threads.
pub fn SyncCell(comptime T: type) type {
    return struct {
        const Self = @This();

        const State = enum(u8) { uninit, initialized };

        mutex: Io.Mutex,
        state: atomic.Value(State),
        value: T,

        pub const empty: Self = .{
            .mutex = .init,
            .state = .init(.uninit),
            .value = undefined,
        };

        pub const SetError = error{AlreadySet} || Io.Cancelable;

        /// The value, or null. The fast path is one acquire load.
        pub fn get(self: *Self) ?*T {
            if (self.state.load(.acquire) != .initialized) {
                @branchHint(.unlikely);
                return null;
            }
            return &self.value;
        }

        /// Whether a value has been set.
        pub fn isInitialized(self: *Self) bool {
            return self.state.load(.acquire) == .initialized;
        }

        /// Set the value. Returns `error.AlreadySet` when one exists.
        pub fn set(self: *Self, io: Io, value: T) SetError!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.state.load(.acquire) == .initialized) return error.AlreadySet;
            self.value = value;
            self.state.store(.initialized, .release);
        }

        /// The value, initialized by `f` on the first call. Threads that
        /// arrive during the first call wait on the mutex.
        pub fn getOrInit(
            self: *Self,
            io: Io,
            ctx: anytype,
            comptime f: fn (@TypeOf(ctx)) T,
        ) Io.Cancelable!*T {
            if (self.state.load(.acquire) != .initialized) {
                @branchHint(.cold);
                return self.initSlow(io, ctx, f);
            }
            return &self.value;
        }

        noinline fn initSlow(
            self: *Self,
            io: Io,
            ctx: anytype,
            comptime f: fn (@TypeOf(ctx)) T,
        ) Io.Cancelable!*T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.state.load(.acquire) == .initialized) return &self.value;
            self.value = f(ctx);
            self.state.store(.initialized, .release);
            return &self.value;
        }

        /// Like `getOrInit`, for an initializer that can fail. A failed call
        /// leaves the cell empty, so a later call can try again.
        pub fn getOrTryInit(
            self: *Self,
            io: Io,
            ctx: anytype,
            comptime f: anytype,
        ) (InitError(f) || Io.Cancelable)!*T {
            if (self.state.load(.acquire) != .initialized) {
                @branchHint(.cold);
                return self.tryInitSlow(io, ctx, f);
            }
            return &self.value;
        }

        noinline fn tryInitSlow(
            self: *Self,
            io: Io,
            ctx: anytype,
            comptime f: anytype,
        ) (InitError(f) || Io.Cancelable)!*T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.state.load(.acquire) == .initialized) return &self.value;
            self.value = try f(ctx);
            self.state.store(.initialized, .release);
            return &self.value;
        }
    };
}

/// A single-threaded lazy value. `init` runs on the first `get`.
pub fn Lazy(comptime T: type, comptime init: fn () T) type {
    return struct {
        const Self = @This();

        cell: Cell(T),

        pub const empty: Self = .{ .cell = .empty };

        /// The value, initialized on the first call.
        pub fn get(self: *Self) *T {
            return self.cell.getOrInit({}, struct {
                fn call(_: void) T {
                    return init();
                }
            }.call);
        }

        /// Whether the value has been initialized.
        pub fn isInitialized(self: *Self) bool {
            return self.cell.isInitialized();
        }

        /// Move the value out and empty the cell.
        pub fn take(self: *Self) ?T {
            return self.cell.take();
        }
    };
}

/// A thread-safe lazy value. `init` runs on the first `get`.
pub fn SyncLazy(comptime T: type, comptime init: fn () T) type {
    return struct {
        const Self = @This();

        cell: SyncCell(T),

        pub const empty: Self = .{ .cell = .empty };

        /// The value, initialized on the first call.
        pub fn get(self: *Self, io: Io) Io.Cancelable!*T {
            return self.cell.getOrInit(io, {}, struct {
                fn call(_: void) T {
                    return init();
                }
            }.call);
        }

        /// Whether the value has been initialized.
        pub fn isInitialized(self: *Self) bool {
            return self.cell.isInitialized();
        }
    };
}

/// The error set of an initializer that returns an error union.
fn InitError(comptime f: anytype) type {
    const return_type = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return switch (@typeInfo(return_type)) {
        .error_union => |info| info.error_set,
        else => @compileError("once: the initializer must return an error union"),
    };
}

var lazy_count: atomic.Value(u32) = .init(0);

fn lazyInit() u32 {
    _ = lazy_count.fetchAdd(1, .monotonic);
    return 42;
}

test "cell set, get, and take" {
    var cell: Cell(u32) = .empty;
    try testing.expectEqual(@as(?*u32, null), cell.get());
    try testing.expect(!cell.isInitialized());

    try cell.set(7);
    try testing.expectEqual(@as(u32, 7), cell.get().?.*);
    try testing.expect(cell.isInitialized());
    try testing.expectError(error.AlreadySet, cell.set(8));
    try testing.expectEqual(@as(u32, 7), cell.get().?.*);

    try testing.expectEqual(@as(?u32, 7), cell.take());
    try testing.expectEqual(@as(?*u32, null), cell.get());
}

test "cell getOrInit runs once" {
    const Counter = struct {
        fn init(ctx: *u32) u32 {
            ctx.* += 1;
            return 42;
        }
    };
    var calls: u32 = 0;
    var cell: Cell(u32) = .empty;
    try testing.expectEqual(@as(u32, 42), cell.getOrInit(&calls, Counter.init).*);
    try testing.expectEqual(@as(u32, 42), cell.getOrInit(&calls, Counter.init).*);
    try testing.expectEqual(@as(u32, 1), calls);
}

test "cell getOrTryInit can retry after an error" {
    const Attempt = struct {
        fn init(ctx: *u32) error{Boom}!u32 {
            ctx.* += 1;
            if (ctx.* == 1) return error.Boom;
            return 42;
        }
    };
    var calls: u32 = 0;
    var cell: Cell(u32) = .empty;
    try testing.expectError(error.Boom, cell.getOrTryInit(&calls, Attempt.init));
    try testing.expectEqual(@as(?*u32, null), cell.get());
    try testing.expectEqual(@as(u32, 42), (try cell.getOrTryInit(&calls, Attempt.init)).*);
    try testing.expectEqual(@as(u32, 2), calls);
}

test "lazy" {
    lazy_count.store(0, .monotonic);
    var lazy: Lazy(u32, lazyInit) = .empty;
    try testing.expect(!lazy.isInitialized());
    try testing.expectEqual(@as(u32, 42), lazy.get().*);
    try testing.expectEqual(@as(u32, 42), lazy.get().*);
    try testing.expect(lazy.isInitialized());
    try testing.expectEqual(@as(u32, 1), lazy_count.load(.monotonic));
    try testing.expectEqual(@as(?u32, 42), lazy.take());
    try testing.expect(!lazy.isInitialized());
}

const SyncCounter = struct {
    count: atomic.Value(u32) = .init(0),
};

fn syncInit(counter: *SyncCounter) u32 {
    _ = counter.count.fetchAdd(1, .monotonic);
    var i: u32 = 0;
    while (i < 100_000) : (i += 1) atomic.spinLoopHint();
    return 42;
}

test "sync cell initializes once across threads" {
    var cell: SyncCell(u32) = .empty;
    var counter: SyncCounter = .{};

    const Worker = struct {
        fn run(c: *SyncCell(u32), n: *SyncCounter) void {
            const value = c.getOrInit(testing.io, n, syncInit) catch unreachable;
            std.debug.assert(value.* == 42);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &cell, &counter });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u32, 1), counter.count.load(.monotonic));
    try testing.expectEqual(@as(u32, 42), cell.get().?.*);
    try testing.expectError(error.AlreadySet, cell.set(testing.io, 7));
}

test "sync cell getOrTryInit can retry after an error" {
    const Attempt = struct {
        fn init(ctx: *u32) error{Boom}!u32 {
            ctx.* += 1;
            if (ctx.* == 1) return error.Boom;
            return 42;
        }
    };
    var calls: u32 = 0;
    var cell: SyncCell(u32) = .empty;
    try testing.expectError(error.Boom, cell.getOrTryInit(testing.io, &calls, Attempt.init));
    try testing.expectEqual(@as(?*u32, null), cell.get());
    try testing.expectEqual(
        @as(u32, 42),
        (try cell.getOrTryInit(testing.io, &calls, Attempt.init)).*,
    );
    try testing.expectEqual(@as(u32, 2), calls);
}

test "sync lazy" {
    lazy_count.store(0, .monotonic);
    var lazy: SyncLazy(u32, lazyInit) = .empty;
    try testing.expect(!lazy.isInitialized());
    try testing.expectEqual(@as(u32, 42), (try lazy.get(testing.io)).*);
    try testing.expectEqual(@as(u32, 42), (try lazy.get(testing.io)).*);
    try testing.expect(lazy.isInitialized());
    try testing.expectEqual(@as(u32, 1), lazy_count.load(.monotonic));
}
