//! The shared form of `std.debug.SafetyLock`, which Zig 0.17 ships and 0.16
//! does not: 0.16's lock is exclusive, so two independent read-only borrowers
//! of one container trip over each other.
//!
//! Vendored from `lib/std/debug.zig` on the Zig master branch (MIT, Zig
//! contributors; see `LICENSE-ZIG` and `THIRD_PARTY.md`). The additions are
//! this comment, and the two lines that move the counter: master writes
//! `@backingInt`/`@fromBackingInt`, which 0.16 does not have, so they are
//! `@intFromEnum`/`@enumFromInt` here. When the pinned toolchain ships the
//! shared form, this file becomes `pub const SafetyLock =
//! std.debug.SafetyLock;` with no change at the call sites.
//!
//! A container carries one as `pointer_stability`. `lockPointers` takes a
//! shared borrow, every call that relocates or frees an entry calls
//! `assertUnlocked`, and `lock` marks an operation that must not overlap any
//! borrow. The state is a plain counter, not an atomic: this guard is for
//! single-threaded containers, and it compiles to nothing without runtime
//! safety.

const std = @import("std");

const runtime_safety = std.debug.runtime_safety;
const assert = std.debug.assert;
const math = std.math;

pub const SafetyLock = struct {
    state: State = if (runtime_safety) .unlocked else .unknown,

    pub const State = if (runtime_safety) enum(usize) {
        unlocked = 0,
        exclusive = math.maxInt(usize),
        _, // shared lock count

        fn isShared(state: State) bool {
            return switch (state) {
                _ => true,
                else => false,
            };
        }
    } else enum { unknown };

    /// Exclusive. Use when mutating data.
    pub fn lock(l: *SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state == .unlocked);
        l.state = .exclusive;
    }

    pub fn unlock(l: *SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state == .exclusive);
        l.state = .unlocked;
    }

    /// Use when consuming data in a read-only manner.
    pub fn lockShared(l: *SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state != .exclusive);
        l.state = @enumFromInt(@intFromEnum(l.state) + 1);
        assert(l.state.isShared()); // Catch overflow to `exclusive`.
    }

    pub fn unlockShared(l: *SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state.isShared());
        l.state = @enumFromInt(@intFromEnum(l.state) - 1);
    }

    pub fn assertUnlocked(l: SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state == .unlocked);
    }

    pub fn assertLocked(l: SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state == .exclusive);
    }

    pub fn assertLockedShared(l: SafetyLock) void {
        if (!runtime_safety) return;
        assert(l.state.isShared());
    }
};

test SafetyLock {
    var safety_lock: SafetyLock = .{};
    safety_lock.assertUnlocked();
    safety_lock.lock();
    safety_lock.assertLocked();
    safety_lock.unlock();
    safety_lock.assertUnlocked();
    safety_lock.lockShared();
    safety_lock.assertLockedShared();
    for (0..3) |_| safety_lock.lockShared();
    safety_lock.assertLockedShared();
    for (0..4) |_| safety_lock.unlockShared();
    safety_lock.assertUnlocked();
}
