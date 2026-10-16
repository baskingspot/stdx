//! The slot_ring module's benchmarks: the producer claim-commit pair —
//! uncontended and contended on the one hot line — the consumer's
//! read-release pair, and the commit cost of the wake flavors. The claim
//! is a CAS loop (Vyukov's shape), so the contended number is the real
//! cost: one successful RMW plus a retry share.

const bench = @import("benchmark");

const std = @import("std");
const Thread = std.Thread;

const stdx = @import("stdx");
const slot_ring = stdx.slot_ring;

const Ring = slot_ring.Mpsc(.{ .wake = .none });
const EventfdRing = slot_ring.Mpsc(.{ .wake = .eventfd });
const FutexRing = slot_ring.Mpsc(.{ .wake = .futex });

const num_slots = 1024;

const message_len = 128;

var message: [message_len]u8 = @splat(0x61);

/// Claim, copy the message in, commit. A refused claim (a full ring)
/// commits nothing, the `on_full` policy's drop.
fn claimCommit(ring: anytype) void {
    var lease = ring.acquire() orelse return;
    const w = lease.writer();
    @memcpy(w.buffer[0..message_len], &message);
    lease.commit(ring, message_len);
}

/// The one-slot-ahead steady state the round-trip benchmarks run in:
/// claim and commit the next position, then read and release the
/// committed position one behind it, so the ring never empties and never
/// fills. The cursor lives across iterations and across `b.loop()` runs.
fn claimCommitReadRelease(ring: anytype, read_pos: *u64) !void {
    claimCommit(ring);
    const msg = ring.read(read_pos.*) orelse return error.NotCommitted;
    msg.release();
    read_pos.* += 1;
}

/// One producer, an empty ring: the floor cost of a full message round
/// trip — claim, payload copy, commit, read, release.
pub fn benchmarkSlotRingRoundTrip(b: *bench.B) !void {
    var ring: Ring = undefined;
    try ring.init(b.allocator, undefined, num_slots);
    defer ring.deinit(b.allocator);

    var read_pos: u64 = 0;
    while (try b.loop()) try claimCommitReadRelease(&ring, &read_pos);
}

/// Four producers hammering the one head line. The op is one burst: four
/// thread spawns, `4 * 512` claim-commit attempts, the drain of the
/// committed slots, and the four joins. The ring holds 1024 slots and
/// nothing drains during the burst, so the claims past 1024 are refused —
/// the burst carries the refusal cost too. The thread spawn is a measured
/// share of this op; `benchmarkSlotRingThreadSpawn` is the baseline that
/// subtracts it.
pub fn benchmarkSlotRingContendedBurst(b: *bench.B) !void {
    var ring: Ring = undefined;
    try ring.init(b.allocator, undefined, num_slots);
    defer ring.deinit(b.allocator);

    const Producer = struct {
        ring: *Ring,

        const Self = @This();

        fn run(self: Self) void {
            var round: usize = 0;
            while (round < 512) : (round += 1) claimCommit(self.ring);
        }
    };

    var producers: [4]Producer = @splat(.{ .ring = &ring });
    // The consumer cursor lives outside the loop: a fresh cursor would
    // re-drain from position 0, read the previous burst's later-lap
    // stamps, and measure nothing but refused claims.
    var read_pos: u64 = 0;
    while (try b.loop()) {
        var threads: [4]Thread = undefined;
        for (&producers, &threads) |*p, *t| t.* = try .spawn(.{}, Producer.run, .{p.*});
        for (&threads) |*t| t.join();
        // Drain the burst between iterations, so the next burst starts on
        // a free ring and claims its own lap.
        while (read_pos < ring.head()) {
            const msg = ring.read(read_pos) orelse return error.NotCommitted;
            msg.release();
            read_pos += 1;
        }
    }
}

/// Four thread spawns and joins with no ring work: the setup share of
/// `benchmarkSlotRingContendedBurst`, so the claim-commit cost is
/// recoverable from the suite itself.
pub fn benchmarkSlotRingThreadSpawn(b: *bench.B) !void {
    const Idle = struct {
        fn run() void {}
    };

    while (try b.loop()) {
        var threads: [4]Thread = undefined;
        for (&threads) |*t| t.* = try .spawn(.{}, Idle.run, .{});
        for (&threads) |*t| t.join();
    }
}

/// The consumer's drain, steady state: one read-release pair per
/// iteration over a ring the producer keeps one slot ahead. The
/// claim-commit that refills the drained slot is amortized into the same
/// op, so the number reads as the consumer pair plus one producer pair.
pub fn benchmarkSlotRingDrainSteady(b: *bench.B) !void {
    var ring: Ring = undefined;
    try ring.init(b.allocator, undefined, num_slots);
    defer ring.deinit(b.allocator);

    // Untimed setup: the one committed slot the loop drains first.
    claimCommit(&ring);
    var read_pos: u64 = 0;
    while (try b.loop()) try claimCommitReadRelease(&ring, &read_pos);
}

/// The `.eventfd` flavor's round trip with the doorbell never armed —
/// the steady state while the consumer is not waiting: every commit
/// runs the gated RMW on the wake word and no commit writes the fd, so
/// no syscall is in the loop. The number sits in the futex-commit
/// range, because the same RMW is all either flavor pays.
pub fn benchmarkSlotRingEventfdDisarmed(b: *bench.B) !void {
    var ring: EventfdRing = undefined;
    try ring.init(b.allocator, undefined, num_slots);
    defer ring.deinit(b.allocator);

    claimCommit(&ring);
    var read_pos: u64 = 0;
    while (try b.loop()) try claimCommitReadRelease(&ring, &read_pos);
}

/// The `.eventfd` flavor's round trip with the consumer armed and left
/// armed: every commit observes the armed bit and writes the fd — that
/// syscall is the flavor's cost, and it dominates the pair. A real
/// consumer disarms on every wake, so this measures the armed-window
/// burst cost, not the steady state.
pub fn benchmarkSlotRingEventfdArmed(b: *bench.B) !void {
    var ring: EventfdRing = undefined;
    try ring.init(b.allocator, undefined, num_slots);
    defer ring.deinit(b.allocator);

    claimCommit(&ring);
    ring.armDoorbell();
    var read_pos: u64 = 0;
    while (try b.loop()) try claimCommitReadRelease(&ring, &read_pos);
}

/// The `.futex` flavor's round trip with no consumer waiter armed — the
/// common case: the commit's notify is one RMW on the wake word and no
/// syscall.
pub fn benchmarkSlotRingFutexCommit(b: *bench.B) !void {
    var ring: FutexRing = undefined;
    try ring.init(b.allocator, b.timer.io, num_slots);
    defer ring.deinit(b.allocator);

    claimCommit(&ring);
    var read_pos: u64 = 0;
    while (try b.loop()) try claimCommitReadRelease(&ring, &read_pos);
}
