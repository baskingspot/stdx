//! MPSC slot ring: bounded, lock-free, multi-producer single-consumer.
//!
//! The algorithm is Dmitry Vyukov's bounded MPMC queue (the substrate of
//! Rust std's bounded channel and crossbeam's `ArrayQueue`), narrowed to
//! MPSC and adapted for byte slots: producers claim positions with a CAS
//! on the ring head — a refused claim burns no position — and every slot
//! carries a stamp — a lap counter in the high half, a length in the low
//! half — that is the lease. A producer may write only the slot whose
//! stamp names its lap;
//! the consumer may read only a stamp naming its committed lap; the
//! consumer's release writes the stamp of the next lap, which is the
//! handoff back to producers. Two writers can never share a slot, and a
//! reader can never see a half-written one, because the stamp gate and
//! the payload write are ordered by the same word.
//!
//! The layout:
//!
//! ```
//! slots[0]           slots[1]           ...  slots[N-1]
//! [stamp][payload]   [stamp][payload]        [stamp][payload]
//!   |
//!   +-- stamp = lap << 32 | len, one u64: the lease, the commit, and
//!       the release in one word; len = 0 is not committed.
//!
//! head: the monotone claim position, CAS-claimed; a refused claim burns nothing
//!   slot = &slots[head & mask];  lap = @truncate(head >> lap_shift)
//!
//! slot_size is a cache-line multiple and the base is cache-line aligned:
//! adjacent slots never share a line.
//! ```
//!
//! Contract: producers never block. A slot whose stamp shows it is
//! still owned — the consumer has not released it, or a producer is
//! stalled mid-write — refuses the claim under the default policy:
//! `acquire` returns null and the new message is dropped (see
//! `Options.on_full`). The `.drop_oldest` policy instead displaces the
//! oldest committed message and claims its slot, so the newest message
//! wins and the loss moves to the oldest. A producer stalled mid-write
//! refuses under either policy: there is no committed message to
//! displace, and freeing a slot mid-claim would let the late commit
//! rewind the stamp. A displacement also refuses while the consumer is
//! inside its claimed window — the cursor moved, the slot not yet
//! freed — so a paused consumer or a paused displacer stalls no
//! producer: the claim returns null in bounded steps and the new
//! message drops. This is not a lossless queue: overflow drops, and a
//! producer stalled mid-write stalls the consumer behind its slot,
//! exactly as an in-order drain must.
//!
//! The consumer protocol follows the policy. `.drop_new` hands the
//! consumer a borrowed `Read` at a position it owns; `release` writes
//! the free stamp. `.drop_oldest` owns the cursor, so the consumer
//! claims it: `read(buf)` wins the cursor with a CAS before it touches
//! payload bytes, copies into the caller's buffer inside that won
//! window, and frees the slot with a release store. The caller gets
//! stable copied bytes, never a borrowed slice — a borrowed slice
//! cannot be made safe against displacement. The wake loops probe the
//! committed stamp without claiming.
//!
//! The flow:
//!
//! ```
//! producer: acquire -- load head, check the stamp, CAS head h -> h + 1
//!             refused: null under drop_new; under drop_oldest displace the
//!             oldest committed message first and retry, or null when no
//!             displacement can proceed
//!             commit -- write the payload, stamp = lap << 32 | len (release),
//!             then wake per the flavor
//! consumer: read -- acquire-load the stamp; lap match and len > 0 = committed
//!             drop_new:    borrow the payload; release stores (lap + 1) << 32
//!             drop_oldest: CAS the cursor r -> r + 1, copy into the buffer,
//!             free the stamp; a lost CAS returns null
//! ```
//!
//! Slots are a fixed size, a multiple of the cache line, asserted at
//! compile time: the stamp leads the slot so the consumer's acquire
//! load of it prefetches the payload start, and adjacent slots never
//! share a line. The ring head (and, in the armed flavors, the wake
//! word) live together on one cache line so a producer message dirties
//! exactly one metadata line.
//!
//! The wake mechanism is a compile-time choice, because it is decided by
//! the consumer's shape: `.none` for a caller-driven drain (tests,
//! embedded loops), `.eventfd` for a consumer that is an event loop —
//! the fd composes with poll — and `.futex` for a dedicated blocking
//! consumer thread. The `.eventfd` and `.futex` flavors carry the
//! armed-waiter-bit protocol, with the waiter flag and the wake
//! generation packed in one word so a notify cannot miss an armed
//! waiter; the futex flavor adds the shutdown handshake. The producers'
//! pokes are gated on the armed bit: zero syscalls while no consumer is
//! armed, a wake per commit while one is — the eventfd counter combines
//! readability, not writes.
//!
//! The `.eventfd` consumer brackets its wait. Arm the doorbell, re-check
//! the ring, wait only if it is still empty, and disarm on every wake —
//! doorbell, socket, timer, anything:
//!
//! ```
//! // {
//! //     ring.armDoorbell();
//! //     defer ring.disarmDoorbell();
//! //     // Re-check the ring; wait only if it is still empty.
//! // }
//! // Then acknowledge the doorbell if it rang, and drain.
//! ```
//!
//! Do not call `ackDoorbell` between the final empty check and the wait:
//! the counter is the pending notification, and an ack there erases it.
//! Disarm does not fold into `ackDoorbell` — a non-doorbell wake would
//! bypass it, and an unconditional ack costs a read syscall when nothing
//! rang. A caller that never arms gets no pokes between generation
//! carries: each commit still bumps the generation, and the 31-bit carry
//! into the waiter bit arms a phantom waiter that persists until an
//! arm/disarm cycle clears it.
//!
//! Linux only, by design: the eventfd flavor wraps raw syscalls and the
//! futex flavor is exercised on Linux futex semantics.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const heap = std.heap;
const atomic = std.atomic;
const Io = std.Io;
const math = std.math;
const linux = std.os.linux;
const Thread = std.Thread;
const comptimePrint = std.fmt.comptimePrint;
const assert = std.debug.assert;
const builtin = @import("builtin");

comptime {
    switch (builtin.os.tag) {
        .linux => {},
        else => @compileError("slot_ring supports Linux only"),
    }
}

/// The wake mechanism. Decided by the consumer's shape, so it is
/// compile-time.
pub const Wake = enum {
    /// No wake state at all: the caller drives every drain. Nothing is
    /// spent on the producer path and no field exists for waking.
    none,
    /// A best-effort eventfd poke, gated on an armed consumer: no
    /// syscall while no consumer is armed, and a poke per commit while
    /// one is. The fd is exposed for a poll loop; `armDoorbell` and
    /// `disarmDoorbell` bracket the wait. A lost poke only delays the
    /// drain until the next event — the ring is the source of truth,
    /// the fd is only a doorbell.
    eventfd,
    /// The armed-waiter-bit futex protocol for a dedicated blocking
    /// consumer thread: a generation counter in the low bits, the
    /// waiter flag in bit 31, both RMWs on the same word so the notify
    /// gate and the waiter's arm cannot miss each other. Includes the
    /// shutdown handshake.
    futex,
};

/// What a producer does when the claimed slot is still owned: the
/// consumer has not released it, or a producer is stalled mid-write.
pub const OnFull = enum {
    /// Drop the new message: `acquire` returns null. The logging
    /// default — never block, never corrupt, and the loss is one
    /// message, visible to the caller. Bounded loss: under a stall,
    /// the newest messages are the ones refused.
    drop_new,
    /// Displace the oldest committed message and claim its slot, so
    /// the newest message lands and the loss moves to the oldest.
    /// crossbeam's `force_push` on this stamp substrate: the
    /// ring owns the consumer cursor (`readHead`), the consumer's
    /// claiming `read(buf)` wins that cursor with a CAS before it
    /// copies, and a displacing producer wins the same CAS to drop the
    /// oldest — one cursor CAS arbitrates, so a slot's bytes are never
    /// copied and displaced at once. A displacement that cannot win
    /// the cursor in bounded steps — a reader mid-copy, or a displacer
    /// that won and has not freed its slot — refuses the claim: the
    /// new message drops, as under `drop_new`. The consumer reads
    /// through `read(buf)`, which copies into the caller's buffer
    /// inside its window; no borrowed slice is returned.
    drop_oldest,
};

/// The options of `Mpsc`. Comptime throughout: each configuration
/// compiles to its own code, per the `fmt.AtoiOptions` convention.
pub const Options = struct {
    /// Total slot size in bytes, stamp word included. Must be a
    /// multiple of the cache line: adjacent slots must not share one,
    /// or producers on neighboring slots dirty each other's stamps.
    /// The payload capacity is `slot_size - 8`.
    slot_size: comptime_int = 1024,

    /// The wake mechanism. See `Wake`.
    wake: Wake = .none,

    /// What a producer does when the claimed slot is still owned. See
    /// `OnFull`.
    on_full: OnFull = .drop_new,
};

/// An MPSC slot ring. Build with `Mpsc(options)`; the instance is
/// initialized with `init`.
pub fn Mpsc(comptime options: Options) type {
    comptime {
        if (options.slot_size % atomic.cache_line != 0) {
            @compileError("slot_ring.Mpsc: slot_size must be a multiple of the cache line (" ++
                comptimePrint("{d}", .{atomic.cache_line}) ++ "), got " ++
                comptimePrint("{d}", .{options.slot_size}));
        }
        if (options.slot_size < 2 * atomic.cache_line) {
            @compileError("slot_ring.Mpsc: slot_size must hold a payload past the stamp");
        }
    }

    return struct {
        const Self = @This();

        /// The armed-waiter wake word exists for the `.eventfd` and
        /// `.futex` flavors; `.none` has no wake state at all.
        const has_wake_word = options.wake == .eventfd or options.wake == .futex;

        /// Payload bytes per slot: the stamp word is part of the slot.
        pub const payload_size: usize = options.slot_size - @sizeOf(u64);

        /// One slot: the stamp word first, so the consumer's acquire
        /// load of it prefetches the payload start on the same line.
        pub const Slot = extern struct {
            /// High half: the lap this slot's current claim belongs to.
            /// Low half: committed payload length, 0 = not committed.
            /// The full lease protocol in one word.
            stamp: atomic.Value(u64) align(8),
            payload: [payload_size]u8,

            comptime {
                assert(@sizeOf(Slot) == options.slot_size);
                assert(@offsetOf(Slot, "payload") <= atomic.cache_line);
            }
        };

        /// The two words a producer touches per message: the head RMW
        /// of a claim, and the wake RMW of a commit. A sub-struct with
        /// an explicit alignment is the only way to guarantee they
        /// share a line — sibling fields of an auto-layout struct get
        /// no such guarantee (measured: the flat layout put the wake
        /// word two lines away from the head).
        const Hot = struct {
            head: atomic.Value(u64),

            wake_state: if (has_wake_word) atomic.Value(u32) else void,

            comptime {
                assert(@sizeOf(Hot) <= atomic.cache_line);
            }
        };

        /// Bit 31 of `Hot.wake_state` marks an armed waiter; the low 31
        /// bits are the wake generation. Carrying the flag in the wake
        /// word is what makes the notify gate sound: the gate and the
        /// waiter's arm are RMWs on the same location, whose
        /// modification order is total (the Linux futex waiter-bit
        /// pattern).
        ///
        /// A 31-bit generation carries into the waiter bit once per
        /// 2^31 commits, arming a phantom waiter. The phantom costs a
        /// wake per commit — a `futexWake` on zero sleepers, or an
        /// eventfd write — until a real consumer arm/disarm cycle
        /// clears the bit; a consumer that never arms/disarms stays
        /// phantom-armed after the first carry. The futex's
        /// expected-value check keeps the phantom from losing a wake.
        const waiter_bit: u32 = 1 << 31;

        /// The `.drop_oldest` cursor word's alignment: its own cache
        /// line, since the consumer's claiming CAS would otherwise
        /// contend with the producer's claim RMW on `hot`. Under
        /// `.drop_new` the word does not exist, so the `void` field
        /// takes no alignment and the layout is unchanged.
        const cursor_align = if (options.on_full == .drop_oldest) atomic.cache_line else 1;

        // Read-only after init. The slice keeps the array's cache-line
        // alignment so `deinit` frees with the alignment `init`
        // allocated.
        slots: []align(atomic.cache_line) Slot,
        mask: u64,
        /// The shift from a claim position to its lap: positions are
        /// per-slot counts, laps are per-revolution counts.
        lap_shift: u6,

        /// Producer-touched state, on its own line.
        hot: Hot align(atomic.cache_line),

        /// `.drop_oldest`: the ring-owned consumer cursor. The
        /// consumer's claiming `read(buf)` advances it with an
        /// acquire/release CAS; a producer reads it and advances it
        /// only to displace the oldest message under the full
        /// condition. `.drop_new` has no such word — the caller owns
        /// the cursor.
        read_head: if (options.on_full == .drop_oldest)
            atomic.Value(u64)
        else
            void align(cursor_align),

        /// `.drop_oldest`: successful displacements, one per dropped
        /// oldest message. Loss accounting, read like `head()`. Its
        /// own cache line: the fetchAdd must not dirty `read_head`'s
        /// line, which the consumer's claiming CAS touches every
        /// message.
        displaced: if (options.on_full == .drop_oldest)
            atomic.Value(u64)
        else
            void align(cursor_align),

        /// Futex flavor: set once, read only by the waiter's loop —
        /// cold on the producer path.
        shutdown: if (options.wake == .futex) atomic.Value(bool) else void,

        /// Futex flavor: the Io whose futex wait/wake backs the
        /// protocol. Captured at init so arm, wait, and wake all
        /// dispatch through one backend.
        io: if (options.wake == .futex) Io else void,

        /// Eventfd flavor: the doorbell fd, created at init before
        /// any allocation, so a failed creation leaks nothing and
        /// propagates.
        notify_fd: if (options.wake == .eventfd) linux.fd_t else void,

        /// The lap a position belongs to, truncated to the stamp's 32
        /// lap bits: laps live in the stamp's high half, so lap
        /// arithmetic wraps with it — at 2^32 laps per slot the counter
        /// reuses values, and a collision needs a producer stalled for
        /// exactly 2^32 revolutions of its slot.
        inline fn lapOf(self: *const Self, pos: u64) u32 {
            return @truncate(pos >> self.lap_shift);
        }

        /// Initialize the ring. `num_slots` rounds up to a power of
        /// two. The `io` parameter is the futex backend, ignored by the
        /// other flavors.
        pub fn init(self: *Self, gpa: Allocator, io: Io, num_slots: usize) !void {
            assert(num_slots > 0);
            const actual = try math.ceilPowerOfTwo(usize, num_slots);
            comptime assert(@sizeOf(Slot) % atomic.cache_line == 0);
            const fd: if (options.wake == .eventfd) linux.fd_t else void =
                if (options.wake == .eventfd) try eventfd() else {};
            // The doorbell closes if the allocation below fails — the
            // fd exists and nothing else owns it yet.
            errdefer if (options.wake == .eventfd) {
                switch (linux.errno(linux.close(fd))) {
                    .SUCCESS, .INTR, .BADF => {},
                    else => unreachable,
                }
            };

            // The array base takes cache-line alignment so the
            // line-multiple slot stride cannot straddle lines: an
            // 8-aligned base would put every stamp on a line the
            // previous slot's producer dirties.
            const slots = try gpa.alignedAlloc(
                Slot,
                .fromByteUnits(atomic.cache_line),
                actual,
            );
            for (slots) |*slot| slot.stamp = .init(0);

            self.* = .{
                .slots = slots,
                .mask = actual - 1,
                .lap_shift = @intCast(math.log2_int(usize, actual)),
                .hot = .{
                    .head = .init(0),
                    .wake_state = if (has_wake_word) .init(0) else {},
                },
                .read_head = if (options.on_full == .drop_oldest) .init(0) else {},
                .displaced = if (options.on_full == .drop_oldest) .init(0) else {},
                .shutdown = if (options.wake == .futex) .init(false) else {},
                .io = if (options.wake == .futex) io else {},
                .notify_fd = if (options.wake == .eventfd) fd else {},
            };

            assert(math.isPowerOfTwo(self.slots.len));
        }

        /// Tear the ring down. Requires no active producers, consumer,
        /// or leases — the caller quiesces first.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (options.wake == .eventfd) {
                switch (linux.errno(linux.close(self.notify_fd))) {
                    .SUCCESS => {},
                    .BADF => {},
                    // EINTR is ignored, not retried: close may return it
                    // after already closing the fd, so a blind retry can
                    // double-close one another thread has since recycled.
                    // A leak at teardown is the worst case.
                    .INTR => {},
                    else => unreachable,
                }
            }
            gpa.free(self.slots);
            self.* = undefined;
        }

        /// Claim a slot for writing. Returns null when the slot the
        /// head points at is still owned — the consumer has not
        /// released it, or the producer that claimed it is stalled
        /// mid-write (the `on_full` policy); a refused claim burns no
        /// position, so the consumer never sees a hole.
        ///
        /// The claim is a CAS on the head, Vyukov's shape: positions are
        /// claimed strictly in order, so only one producer can hold a
        /// lap of a slot, and a failed claim leaves the head where it
        /// was. Under contention a producer retries at the new head —
        /// one hint between attempts — rather than ever blocking.
        ///
        /// `.drop_oldest`: an owned slot with a committed message is
        /// not refused. The producer displaces the oldest message —
        /// CAS-advances the ring-owned consumer cursor past it and
        /// frees its slot — then retries the claim, so the newest
        /// message lands and the oldest is dropped. An owned slot
        /// whose stamp names no committed message is a producer stalled
        /// mid-write; there is nothing to displace, and freeing that
        /// slot would let the late commit rewind the stamp, so the
        /// claim is refused. A displacement that cannot win the cursor
        /// in bounded steps — the consumer is inside its claimed
        /// window, or another displacer won and has not freed the slot
        /// — also refuses: the claim returns null and the new message
        /// drops, so a paused consumer or displacer stalls no producer.
        pub fn acquire(self: *Self) ?Lease {
            var pos = self.hot.head.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const lap = self.lapOf(pos);
                const stamp = slot.stamp.load(.acquire);
                const stamp_lap: u32 = @truncate(stamp >> 32);
                if (stamp_lap != lap) {
                    // A stamp naming a later lap means this head sample
                    // is stale — the position moved on while it was
                    // held; reload and retry. A stamp naming an earlier
                    // lap means the slot is still owned: full, or a
                    // producer stalled mid-write (the on_full policy).
                    // The delta is lap-wrap-aware: a wrapped-later lap
                    // is a small positive delta, an owned one negative.
                    const delta: i32 = @bitCast(stamp_lap -% lap);
                    if (delta > 0) {
                        pos = self.hot.head.load(.monotonic);
                        continue;
                    }
                    if (comptime options.on_full == .drop_oldest) {
                        // A zero length is a claim whose producer has
                        // not committed: no message to displace, and
                        // freeing the slot would let the late commit
                        // rewind its stamp over the next lap.
                        if (@as(u32, @truncate(stamp)) == 0) return null;
                        // The owned slot holds the message at the
                        // cursor: with the head full, the cursor sits
                        // exactly one capacity behind it, so displacing
                        // r = pos - capacity drops that message and
                        // frees this cell for this lap. The guard keeps
                        // a cursor already advanced — a reader inside
                        // its claimed window, or a displacer that won —
                        // from displacing an unrelated position.
                        const r = self.read_head.load(.acquire);
                        if (r == pos -% (self.mask + 1) and
                            self.read_head.cmpxchgStrong(r, r + 1, .acq_rel, .monotonic) == null)
                        {
                            // Won the cursor: the message at r is
                            // dropped, and its slot — the head's cell,
                            // since r = pos - capacity — frees for
                            // this lap. The claim below now sees a free
                            // stamp. The stamp CAS is a safety net: the
                            // consensus argument says it cannot fail,
                            // because the cursor CAS is the only other
                            // writer of this cell and it lost the race.
                            // Debug-loud; the CAS runs in every mode.
                            const free: u64 = @as(u64, lap) << 32;
                            const won = slot.stamp.cmpxchgStrong(stamp, free, .release, .monotonic);
                            assert(won == null);
                            _ = self.displaced.fetchAdd(1, .monotonic);
                            // The cursor moved: a parked consumer may be
                            // waiting on the displaced position, so bump
                            // the wake per the flavor. Gated on the armed
                            // bit like a commit's notify: a disarmed
                            // consumer pays nothing.
                            switch (options.wake) {
                                .none => {},
                                .eventfd, .futex => self.notifyConsumer(),
                            }
                            // The freed cell claims on the next
                            // iteration.
                            pos = self.hot.head.load(.monotonic);
                            continue;
                        }
                        // The displacement attempt failed: the cursor
                        // moved under the sample (a reader inside its
                        // claimed window, or a displacer that won), or
                        // the CAS lost. Re-load the head once and
                        // re-check its slot: a free or later-lap stamp
                        // means the failed attempt's winner freed the
                        // cell, or the head moved on — retry; a slot
                        // still owned means no displacement can make
                        // room in bounded steps — refuse, and the new
                        // message drops. This is also the paused-
                        // displacer bound: a displacer that won the
                        // cursor and paused before its stamp CAS stalls
                        // no other producer.
                        pos = self.hot.head.load(.monotonic);
                        const next_stamp = self.slots[pos & self.mask].stamp.load(.acquire);
                        const next_lap: u32 = @truncate(next_stamp >> 32);
                        const next_delta: i32 = @bitCast(next_lap -% self.lapOf(pos));
                        if (next_delta >= 0) continue;
                        return null;
                    }
                    return null;
                }
                // The lease check passed for this position: only the
                // claimer of this position can have touched the slot's
                // stamp since, and there is exactly one claimer per
                // position. Claim it.
                pos = self.hot.head.cmpxchgWeak(
                    pos,
                    pos + 1,
                    .acq_rel,
                    .monotonic,
                ) orelse return .{ .slot = slot, .pos = pos, .lap = lap, .spent = false };
                // Lost the race for this position: retry at the new
                // head. No spin hint — it lowers to a full-barrier `isb`
                // per failed attempt, measured at 35-37ns/claim against
                // 29-32 without (isolated CAS-retry hammer, 4 threads),
                // with no line-mercy benefit the winner pays for.
            }
        }

        /// The producer's lease on one slot.
        pub const Lease = struct {
            slot: *Slot,
            /// The claim position, for logging and truncation markers.
            pos: u64,
            /// The lap of the claim, carried so `commit` builds the
            /// stamp word without reloading the shift and recomputing
            /// it — one load and one shift off every commit.
            lap: u32,
            /// Set by `commit`: a second commit can rewind the stamp
            /// after the consumer released the slot, wedging the ring
            /// permanently — the assert makes the misuse loud in Debug.
            spent: bool,

            /// A writer over the slot payload. `end` is the length to
            /// commit.
            pub fn writer(self: Lease) Io.Writer {
                return .fixed(&self.slot.payload);
            }

            /// Commit the message: publish the payload under the
            /// lease's lap, then wake the consumer per the flavor.
            /// The wake is folded in so a commit cannot forget it.
            pub fn commit(self: *Lease, self_ring: *Self, len: u32) void {
                assert(!self.spent);
                self.spent = true;
                assert(len > 0);
                assert(len <= payload_size);
                self.slot.stamp.store((@as(u64, self.lap) << 32) | len, .release);
                switch (options.wake) {
                    .none => {},
                    .eventfd, .futex => self_ring.notifyConsumer(),
                }
            }

            /// The ring position of this lease, for logging and
            /// truncation markers.
            pub fn index(self: Lease) u64 {
                return self.pos;
            }
        };

        /// `.drop_new`'s borrowed read lease on one slot: the committed
        /// payload, plus the slot and its lap, so `release` writes the
        /// next-lap stamp without recomputing the slot address. Under
        /// `.drop_oldest` the type is `void`: a borrowed slice cannot be
        /// made safe against displacement, so the claiming `read(buf)`
        /// copies inside its won window instead.
        pub const Read = if (options.on_full == .drop_oldest) void else struct {
            payload: []const u8,
            slot: *Slot,
            lap: u32,

            /// Release the slot back to producers: write the stamp of
            /// the next lap, the free word the wrapping producer is
            /// waiting to see. The release store orders the consumer's
            /// last read of the payload before the next producer's write.
            ///
            /// The stamp still names this read's lap: the single
            /// consumer owns it until this store, so any other value is
            /// a mis-sequenced release (out of order, or a second
            /// release of an already-released slot) — loud in Debug.
            pub fn release(self: Read) void {
                assert(@as(u32, @truncate(self.slot.stamp.load(.monotonic) >> 32)) == self.lap);
                self.slot.stamp.store(@as(u64, self.lap +% 1) << 32, .release);
            }
        };

        /// `.drop_new`: the committed payload at `read_pos`, or null
        /// when it is not committed yet — a producer claimed but has
        /// not finished writing. The single consumer owns `read_pos`
        /// and advances past a slot only by releasing the read lease;
        /// the returned `Read` borrows the slot.
        ///
        /// `.drop_oldest`: the claiming consume. Loads the ring-owned
        /// cursor, checks the slot at it is committed — a stamp naming
        /// the cursor's lap with a nonzero length — and CAS-advances
        /// the cursor past it, acquire/release, before it touches
        /// payload bytes. A lost CAS returns null and reads no payload:
        /// a displacer took the cursor, and the message is its loss. A
        /// won CAS owns the window — a displacer's expected cursor
        /// value is now stale, so it cannot free this slot — so the
        /// payload is copied into `buf` and the slot is freed with the
        /// next-lap stamp, a release store. Returns `buf[0..len]`.
        ///
        /// The ordering, and why no other fence is needed: the
        /// committed stamp's acquire-load observes the producer's
        /// publication, so the payload reads happen after it; the
        /// cursor CAS excludes displacement for the won window; and
        /// the final release store orders the copied reads before the
        /// next producer's write.
        ///
        /// A `buf` smaller than the committed length is a caller bug:
        /// the Debug assert and the ReleaseSafe slice check are loud,
        /// and ReleaseFast is undefined. Size the buffer to
        /// `payload_size`.
        pub fn read(
            self: if (options.on_full == .drop_oldest) *Self else *const Self,
            arg: if (options.on_full == .drop_oldest) []u8 else u64,
        ) if (options.on_full == .drop_oldest) ?[]u8 else ?Read {
            if (comptime options.on_full == .drop_oldest) {
                const buf = arg;
                const read_pos = self.read_head.load(.acquire);
                const slot = &self.slots[read_pos & self.mask];
                const lap = self.lapOf(read_pos);
                const stamp = slot.stamp.load(.acquire);
                const len: u32 = @truncate(stamp);
                if (@as(u32, @truncate(stamp >> 32)) != lap or len == 0) return null;
                assert(len <= buf.len);
                // Claim the cursor before touching payload bytes: the
                // won window is exclusive.
                if (self.read_head.cmpxchgStrong(
                    read_pos,
                    read_pos + 1,
                    .acq_rel,
                    .monotonic,
                ) != null) return null;
                @memcpy(buf[0..len], slot.payload[0..len]);
                slot.stamp.store(@as(u64, lap +% 1) << 32, .release);
                return buf[0..len];
            }
            const read_pos = arg;
            const slot = &self.slots[read_pos & self.mask];
            const lap = self.lapOf(read_pos);
            const stamp = slot.stamp.load(.acquire);
            const len: u32 = @truncate(stamp);
            if (@as(u32, @truncate(stamp >> 32)) != lap or len == 0) return null;
            return .{
                .payload = slot.payload[0..len],
                .slot = slot,
                .lap = lap,
            };
        }

        /// Number of claims handed out, committed or not.
        pub fn head(self: *const Self) u64 {
            return self.hot.head.load(.acquire);
        }

        /// `.drop_oldest`: the ring-owned consumer cursor, the next
        /// position the consumer may read. A displacing producer can
        /// advance it at any time, and the claiming `read(buf)` loads
        /// it itself; this is for accounting and for callers that need
        /// the cursor without consuming.
        pub fn readHead(self: *const Self) u64 {
            comptime assert(options.on_full == .drop_oldest);
            return self.read_head.load(.acquire);
        }

        /// `.drop_oldest`: messages displaced by producers, one per
        /// oldest message dropped to make room for a newer one. Loss
        /// accounting, read like `head()`.
        pub fn displacedCount(self: *const Self) u64 {
            comptime assert(options.on_full == .drop_oldest);
            return self.displaced.load(.acquire);
        }

        /// Number of slots in the ring.
        pub fn numSlots(self: *const Self) usize {
            return self.mask + 1;
        }

        /// Eventfd flavor: the fd to poll. Created at `init` — a caller
        /// that prefers a caller-driven ring without an fd uses the
        /// `.none` flavor.
        pub fn pollFd(self: *const Self) linux.fd_t {
            comptime assert(options.wake == .eventfd);
            return self.notify_fd;
        }

        /// Eventfd flavor: arm the doorbell for the wait about to
        /// happen. The consumer brackets its wait with the arm and the
        /// disarm:
        ///
        /// ```
        /// // {
        /// //     ring.armDoorbell();
        /// //     defer ring.disarmDoorbell();
        /// //     // Re-check the ring; wait only if it is still empty.
        /// // }
        /// // Then acknowledge the doorbell if it rang, and drain.
        /// ```
        ///
        /// Disarm on EVERY wake — doorbell, socket, timer, anything.
        /// The arm is the producers' gate: a commit observes the armed
        /// bit and pokes, and with no arm there is no poke, so the
        /// re-check after the arm is what finds commits that landed
        /// unannounced. Do not call `ackDoorbell` between the final
        /// empty check and the wait: the counter is the pending
        /// notification, and the ack erases it. A caller that never
        /// arms gets no pokes between generation carries: each commit
        /// bumps the generation, and the 31-bit carry into the waiter
        /// bit arms a phantom waiter until an arm/disarm cycle clears
        /// it.
        pub fn armDoorbell(self: *Self) void {
            comptime assert(options.wake == .eventfd);
            _ = self.hot.wake_state.fetchOr(waiter_bit, .acq_rel);
        }

        /// Eventfd flavor: disarm the doorbell on every wake, whatever
        /// woke the consumer. The armed bit gates the producers' pokes,
        /// so a consumer that stays armed pays a write syscall per
        /// commit; the disarm is the release RMW that clears it.
        pub fn disarmDoorbell(self: *Self) void {
            comptime assert(options.wake == .eventfd);
            _ = self.hot.wake_state.fetchAnd(~waiter_bit, .release);
        }

        /// Eventfd flavor: drain the doorbell counter. The consumer
        /// calls this when the fd reads ready, before draining the
        /// ring — the ring is the source of truth, the counter only
        /// arms the poll again. Benign on an unwoken fd (the read
        /// returns EAGAIN), so a spurious ack cannot wedge the doorbell.
        /// Never call it between the final empty check and the wait:
        /// the counter is the pending notification, and the ack erases
        /// it (see `armDoorbell`).
        pub fn ackDoorbell(self: *Self) void {
            comptime assert(options.wake == .eventfd);
            var counter: [8]u8 = undefined;
            _ = linux.read(self.notify_fd, &counter, 8);
        }

        fn poke(self: *Self) void {
            comptime assert(options.wake == .eventfd);
            // Best-effort: a lost poke only delays the drain until
            // the next event; the message lives in the ring. A failed
            // write does not establish readability.
            const one_u64 = [8]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };
            _ = linux.write(self.notify_fd, &one_u64, 8);
        }

        /// The position the consumer should read next: its own cursor
        /// under `.drop_new`, the ring's under `.drop_oldest`, where a
        /// producer can displace a position and advance the cursor
        /// while the consumer waits — so every check re-loads it.
        inline fn consumerPos(self: *const Self, read_pos: u64) u64 {
            return if (comptime options.on_full == .drop_oldest)
                self.readHead()
            else
                read_pos;
        }

        /// Non-owning committed check at `pos`: the stamp names `pos`'s
        /// lap with a nonzero length. No CAS, no payload access — a
        /// probe, not a claim. The `.drop_oldest` wake loops use it so a
        /// probe cannot consume the message: the claiming `read(buf)`
        /// advances the ring-owned cursor, and only an actual consume
        /// may do that.
        fn committedAt(self: *const Self, pos: u64) bool {
            const stamp = self.slots[pos & self.mask].stamp.load(.acquire);
            return @as(u32, @truncate(stamp >> 32)) == self.lapOf(pos) and
                @as(u32, @truncate(stamp)) != 0;
        }

        /// The wake loops' data probe: is there a committed message at
        /// the consumer's position? `.drop_new` reads through `read` —
        /// the consumer owns the position, and a borrowed lease claims
        /// nothing. `.drop_oldest` uses the non-owning stamp check,
        /// because the claiming `read(buf)` consumes the message.
        inline fn dataReady(self: *Self, read_pos: u64) bool {
            const pos = self.consumerPos(read_pos);
            return if (comptime options.on_full == .drop_oldest)
                self.committedAt(pos)
            else
                self.read(pos) != null;
        }

        /// Futex flavor: wait until the slot at the consumer's position
        /// is committed, or shutdown is requested and everything
        /// committed before it is drained. Returns true when there is
        /// data to read, false when the consumer should exit.
        /// `.drop_oldest` ignores `read_pos`: the ring owns the cursor.
        pub fn waitForData(self: *Self, read_pos: u64) bool {
            comptime assert(options.wake == .futex);
            while (true) {
                // Data wins over shutdown: the promise below is
                // "false only once drained", and producers stop
                // claiming once shutdown is visible, so the pending
                // set is finite and this terminates.
                if (self.dataReady(read_pos)) return true;
                if (self.shutdown.load(.acquire)) {
                    return self.dataAtShutdown(read_pos);
                }

                // Spin briefly before sleeping: 64 iterations covers
                // cache-line transfer latency, skipping the syscall
                // during burst writes.
                for (0..64) |_| {
                    atomic.spinLoopHint();
                    if (self.dataReady(read_pos)) return true;
                }

                // Arm the waiter and snapshot the wake generation in
                // one RMW. The flag and the generation share the word,
                // so the notify gate and this arm cannot miss each
                // other across words; Futex.wait below verifies the
                // post-arm value, so a notify inside the arm-to-wait
                // window forces an immediate return even when its wake
                // hits no sleeper.
                const armed = self.hot.wake_state.fetchOr(waiter_bit, .acq_rel);
                const expected = armed | waiter_bit;

                // Re-check with the waiter armed. A bump observed by
                // the arm RMW pairs with its acquire edge: the commit
                // that bumped is ordered before these loads.
                if (self.dataReady(read_pos)) {
                    _ = self.hot.wake_state.fetchAnd(~waiter_bit, .release);
                    return true;
                }
                if (self.shutdown.load(.acquire)) {
                    _ = self.hot.wake_state.fetchAnd(~waiter_bit, .release);
                    return self.dataAtShutdown(read_pos);
                }

                self.io.futexWaitUncancelable(u32, &self.hot.wake_state.raw, expected);
                _ = self.hot.wake_state.fetchAnd(~waiter_bit, .release);
            }
        }

        /// The shutdown exit, checked AFTER the shutdown acquire: a
        /// producer can commit between the loop's earlier read and the
        /// shutdown load, and producer quiescence before
        /// `requestShutdown` makes every commit sequenced before the
        /// shutdown store this acquire reads from — so this read sees
        /// it. Data wins over shutdown; `waitForData` returns false
        /// only once the consumer's position is drained. Probes without
        /// claiming, like `dataReady`.
        fn dataAtShutdown(self: *Self, read_pos: u64) bool {
            return self.dataReady(read_pos);
        }

        /// Futex flavor: request shutdown and wake the consumer.
        /// `waitForData` returns false once everything committed
        /// before this is drained. Requires producers to have stopped
        /// claiming first.
        pub fn requestShutdown(self: *Self) void {
            comptime assert(options.wake == .futex);
            self.shutdown.store(true, .release);
            self.notifyConsumer();
        }

        /// Futex flavor: has shutdown been requested?
        pub fn isShutdown(self: *const Self) bool {
            comptime assert(options.wake == .futex);
            return self.shutdown.load(.acquire);
        }

        /// The `.eventfd` and `.futex` notify: one RMW bumps the
        /// generation and reports an armed waiter, so a wake cannot be
        /// lost to a stale read of a second gate word. The bump is not
        /// a syscall; only the wake under the armed bit is — the
        /// eventfd write, or the `Futex.wake`.
        fn notifyConsumer(self: *Self) void {
            comptime assert(options.wake == .eventfd or options.wake == .futex);
            const state = self.hot.wake_state.fetchAdd(1, .release);
            if (state & waiter_bit != 0) {
                if (comptime options.wake == .eventfd) {
                    self.poke();
                } else {
                    self.io.futexWake(u32, &self.hot.wake_state.raw, 1);
                }
            }
        }

        /// The eventfd doorbell: CLOEXEC, NONBLOCK, counter semantics
        /// (writes sum, one 8-byte read drains). std.posix has no
        /// wrapper; errno converted by hand.
        fn eventfd() !linux.fd_t {
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            return switch (linux.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .NOMEM => error.SystemResources,
                .MFILE => error.ProcessResources,
                .NFILE => error.FdQuotaExceeded,
                .NODEV => error.InodeMountFail,
                else => unreachable,
            };
        }
    };
}

fn expectRead(ring: anytype, pos: u64) !@TypeOf(ring.read(pos).?) {
    return ring.read(pos) orelse return error.NotCommitted;
}

/// The `.drop_oldest` claiming read with the caller's buffer: the
/// returned slice points into `buf`, which keeps the bytes after the
/// slot is freed and reused.
fn expectConsume(ring: anytype, buf: []u8) ![]u8 {
    return ring.read(buf) orelse return error.NotCommitted;
}

fn expectAcquire(ring: anytype) !@TypeOf(ring.acquire().?) {
    return ring.acquire() orelse return error.RingFull;
}

/// Test-only: the fill byte a churn message at `pos` carries, derived
/// from the position so a stale or torn payload cannot pass the model
/// check.
fn modelFill(pos: u64) u8 {
    return @truncate(pos *% 0x9E37_79B9_7F4A_7C15 +% 0x51);
}

/// Test-only: the model's bytes for a commit at `pos`: the claim
/// position and its fill byte in the prefix, then padding of the same
/// fill byte out to `len`. A `len` shorter than the prefix truncates it
/// (the one-byte message); the full payload is the other extreme.
fn modelMessage(pos: u64, len: usize, buf: []u8) []const u8 {
    const fill = modelFill(pos);
    var stream: Io.Writer = .fixed(buf);
    stream.print("p{d}m{d}", .{ pos, fill }) catch unreachable;
    if (stream.end > len) stream.end = len;
    @memset(buf[stream.end..len], fill);
    stream.end = len;
    return buf[0..len];
}

/// Test-only: the commit length an op byte selects: the one-byte
/// message, the full payload, or a length that still holds the position
/// prefix. Short and maximum-length messages stay common.
fn modelLen(pos: u64, byte: u8, payload_size: usize) usize {
    const prefix = std.fmt.count("p{d}m{d}", .{ pos, modelFill(pos) });
    return switch (byte % 16) {
        0 => 1,
        1 => payload_size,
        else => prefix + (byte % (payload_size - prefix + 1)),
    };
}

/// Test-only: encode a compact op list into the byte stream the churn
/// fuzz decodes: one `{ kind, selector, aux }` triple per op. Keeps the
/// corpus entries readable.
fn encodeOps(comptime ops: []const [3]u8) [ops.len * 3]u8 {
    var out: [ops.len * 3]u8 = undefined;
    for (ops, 0..) |op, i| {
        out[i * 3] = op[0];
        out[i * 3 + 1] = op[1];
        out[i * 3 + 2] = op[2];
    }
    return out;
}

/// Test-only: the `.drop_new` churn corpus: acquire, commit, read, fill,
/// and a maximum-length commit, so the non-fuzz smoke run covers every
/// op kind.
const churn_drop_new = encodeOps(&.{
    .{ 0, 0, 0 }, // acquire
    .{ 3, 0, 20 }, // commit lease 0, mid length
    .{ 5, 0, 0 }, // read
    .{ 2, 0, 0 }, // fill: claim and commit in a row
    .{ 3, 1, 200 }, // commit lease 1, long
    .{ 6, 0, 0 }, // read
    .{ 0, 0, 0 }, // acquire
    .{ 4, 0, 1 }, // commit lease 0, full payload
    .{ 2, 0, 0 }, // fill
    .{ 5, 0, 0 }, // read
    .{ 3, 2, 0 }, // commit lease 2, one-byte message
    .{ 7, 0, 0 }, // read
});

/// Test-only: the `.drop_oldest` churn corpus: two fill bursts leave the
/// ring exactly full of committed messages, so the next claims displace
/// instead of refusing.
const churn_drop_oldest = encodeOps(&.{
    .{ 2, 0, 0 }, // fill: exactly full, committed
    .{ 2, 0, 0 }, // fill: displacement fires
    .{ 0, 0, 0 }, // acquire: displaces the oldest
    .{ 5, 0, 0 }, // read
    .{ 0, 0, 0 }, // acquire
    .{ 6, 0, 0 }, // read
    .{ 0, 0, 0 }, // acquire
    .{ 3, 1, 120 }, // commit lease 1
    .{ 5, 0, 0 }, // read
    .{ 2, 0, 0 }, // fill
    .{ 7, 0, 0 }, // read
});

/// Test-only: the single-threaded churn model, one instantiation per
/// policy. A 4-slot ring is driven by 128 ops decoded from one smith
/// byte buffer, and a per-position model — claimed, committed,
/// delivered, displaced, plus the committed length — is checked against
/// the ring after every op. Every invariant violation fails the run, it
/// never skips an iteration: a read returns exactly the bytes committed
/// at its position, a refusal burns no position, the head never
/// regresses, and nothing vanishes — every committed position is
/// delivered, displaced, or still in the ring.
fn Churn(comptime policy: OnFull) type {
    return struct {
        const Self = @This();
        const Ring = Mpsc(.{ .slot_size = 256, .on_full = policy });
        const capacity = 4;
        const op_count = 128;
        const max_pos = op_count + capacity + 4;

        const State = enum(u3) { free, claimed, committed, delivered, displaced };

        ring: Ring = undefined,
        state: [max_pos]State = @splat(.free),
        msg_len: [max_pos]usize = @splat(0),
        leases: [capacity]?Ring.Lease = @splat(null),
        /// The consumer's position: the caller's own cursor under
        /// `.drop_new`, the ring-owned cursor mirrored under
        /// `.drop_oldest`.
        cursor: u64 = 0,
        attempts: usize = 0,
        commits: usize = 0,
        refusals: usize = 0,
        in_flight: usize = 0,
        delivered: usize = 0,
        displaced: usize = 0,
        head_high: u64 = 0,
        expect_buf: [Ring.payload_size]u8 = undefined,
        read_buf: [Ring.payload_size]u8 = undefined,

        fn freeLease(self: *Self) ?usize {
            for (&self.leases, 0..) |*slot, idx| {
                if (slot.* == null) return idx;
            }
            return null;
        }

        /// One acquire attempt. A null refusal is legal: the head must
        /// not move and, under `.drop_oldest`, nothing may be displaced.
        /// A grant records the lease, after applying any displacement
        /// the attempt made.
        fn tryClaim(self: *Self, idx: usize) anyerror!bool {
            const before = self.ring.head();
            self.attempts += 1;
            const lease = self.ring.acquire() orelse {
                try testing.expectEqual(before, self.ring.head());
                if (comptime policy == .drop_oldest) {
                    try testing.expectEqual(self.displaced, self.ring.displacedCount());
                }
                self.refusals += 1;
                return false;
            };
            // A claim is granted at the head sample: the refusal path
            // burns no position and a displacement moves only the
            // cursor.
            try testing.expectEqual(before, lease.pos);
            try testing.expect(lease.pos < max_pos);
            if (comptime policy == .drop_oldest) try self.applyDisplacement();
            self.leases[idx] = lease;
            self.in_flight += 1;
            self.state[lease.pos] = .claimed;
            return true;
        }

        /// Apply the displacement a granted `.drop_oldest` claim made:
        /// the cursor advanced past the oldest committed message, which
        /// the model must have recorded as committed at the cursor.
        fn applyDisplacement(self: *Self) anyerror!void {
            const actual = self.ring.displacedCount();
            try testing.expect(actual >= self.displaced);
            try testing.expect(actual - self.displaced <= 1);
            if (actual == self.displaced) return;
            try testing.expectEqual(State.committed, self.state[self.cursor]);
            self.state[self.cursor] = .displaced;
            self.cursor += 1;
            self.displaced += 1;
        }

        /// Commit a lease with a smith-varied length.
        fn commit(self: *Self, lease: Ring.Lease, byte: u8) void {
            const len = modelLen(lease.pos, byte, Ring.payload_size);
            var msg_buf: [Ring.payload_size]u8 = undefined;
            const msg = modelMessage(lease.pos, len, &msg_buf);
            var l = lease;
            var w = l.writer();
            w.writeAll(msg) catch unreachable;
            l.commit(&self.ring, @intCast(w.end));
            self.state[lease.pos] = .committed;
            self.msg_len[lease.pos] = len;
            self.commits += 1;
        }

        /// One in-order read attempt.
        fn read(self: *Self) anyerror!void {
            if (comptime policy == .drop_new) {
                const msg = self.ring.read(self.cursor) orelse return;
                try testing.expectEqual(State.committed, self.state[self.cursor]);
                try testing.expectEqualSlices(
                    u8,
                    modelMessage(self.cursor, self.msg_len[self.cursor], &self.expect_buf),
                    msg.payload,
                );
                self.state[self.cursor] = .delivered;
                self.delivered += 1;
                self.cursor += 1;
                msg.release();
                return;
            }
            const pos = self.ring.readHead();
            try testing.expectEqual(self.cursor, pos);
            const msg = self.ring.read(&self.read_buf) orelse {
                // Nothing committed at the cursor: an uncommitted claim,
                // or the cursor sitting at the head.
                try testing.expect(self.state[pos] == .claimed or self.state[pos] == .free);
                return;
            };
            try testing.expectEqual(State.committed, self.state[pos]);
            try testing.expectEqualSlices(
                u8,
                modelMessage(pos, self.msg_len[pos], &self.expect_buf),
                msg,
            );
            self.state[pos] = .delivered;
            self.delivered += 1;
            self.cursor += 1;
        }

        /// The conservation identity is a scan, so it runs every
        /// sixteenth op and at the end; the O(1) counters carry the
        /// per-op checks.
        fn checkConservation(self: *Self) anyerror!void {
            var pending: usize = 0;
            for (self.state[0..@intCast(self.ring.head())]) |s| {
                if (s == .committed) pending += 1;
            }
            try testing.expectEqual(self.commits, self.delivered + self.displaced + pending);
            if (comptime policy == .drop_oldest) {
                try testing.expectEqual(self.displaced, self.ring.displacedCount());
                try testing.expectEqual(self.delivered + self.displaced, self.cursor);
            }
        }

        fn run(self: *Self, smith: *testing.Smith) anyerror!void {
            var bytes: [op_count * 3]u8 = undefined;
            smith.bytes(&bytes);
            try self.ring.init(testing.allocator, undefined, capacity);
            defer self.ring.deinit(testing.allocator);

            var i: usize = 0;
            while (i < op_count) : (i += 1) {
                const op = bytes[i * 3];
                const sel = bytes[i * 3 + 1];
                const aux = bytes[i * 3 + 2];
                switch (op % 8) {
                    0, 1 => {
                        const idx = self.freeLease() orelse continue;
                        _ = try self.tryClaim(idx);
                    },
                    2 => {
                        // A deliberate fill: claim and commit in a row
                        // until the ring refuses or every lease slot is
                        // held, so the exactly-full state is common and
                        // displacement fires rather than being a rarity.
                        for (0..capacity) |_| {
                            const idx = self.freeLease() orelse break;
                            if (!try self.tryClaim(idx)) break;
                            const lease = self.leases[idx].?;
                            self.commit(lease, aux);
                            self.leases[idx] = null;
                            self.in_flight -= 1;
                        }
                    },
                    3, 4 => {
                        // A commit of a random still-uncommitted lease,
                        // scanned forward from the selector byte.
                        if (self.in_flight == 0) continue;
                        var k: usize = 0;
                        while (k < capacity) : (k += 1) {
                            const idx = (sel + k) % capacity;
                            const lease = self.leases[idx] orelse continue;
                            self.commit(lease, aux);
                            self.leases[idx] = null;
                            self.in_flight -= 1;
                            break;
                        }
                    },
                    5, 6, 7 => try self.read(),
                    else => unreachable,
                }
                // The cheap invariants after every op: the head never
                // regresses, every grant is committed or in flight, and
                // every attempt is a grant or a refusal.
                try testing.expect(self.ring.head() >= self.head_high);
                self.head_high = self.ring.head();
                try testing.expectEqual(self.commits + self.in_flight, self.ring.head());
                try testing.expectEqual(self.ring.head() + self.refusals, self.attempts);
                if (comptime policy == .drop_oldest) {
                    try testing.expectEqual(self.cursor, self.ring.readHead());
                    try testing.expect(self.ring.head() >= self.cursor and
                        self.ring.head() - self.cursor <= capacity);
                }
                if (i % 16 == 15) try self.checkConservation();
            }

            // Drain what the cursor can reach, then close the books. The
            // drain stops at the first position it cannot deliver, and
            // that position must be an uncommitted claim — a committed
            // one would have been delivered — while every position below
            // the cursor was delivered or displaced.
            while (true) {
                const before = self.cursor;
                try self.read();
                if (self.cursor == before) break;
            }
            try self.checkConservation();
            if (self.cursor < self.ring.head()) {
                try testing.expectEqual(State.claimed, self.state[self.cursor]);
            }
            for (self.state[0..@intCast(self.cursor)]) |s| {
                if (comptime policy == .drop_oldest) {
                    try testing.expect(s == .delivered or s == .displaced);
                } else {
                    try testing.expectEqual(State.delivered, s);
                }
            }
        }
    };
}

/// Test-only: the threaded hammer's message identity. The producer id
/// and message index identify the message; the length and claim position
/// make the payload self-checking, so a torn write or a stale lap cannot
/// pass the consumer's byte-for-byte comparison.
const HammerId = struct {
    id: usize,
    i: usize,
    len: usize,
    pos: u64,
};

/// Test-only: seed for the hammer's xorshift PRNGs; each producer adds
/// its id so the payload lengths differ per producer but stay
/// reproducible run to run.
const hammer_seed: u64 = 0x2545_F491_4F6C_DD1D;

/// Test-only: the shortest hammer message: comfortably above the
/// `p{id}m{i}l{len}s{pos}!` prefix for 3 producers of 200 messages.
const hammer_len_min = 24;

/// Test-only: both threaded hammers use 256-byte slots.
const hammer_payload_size = Mpsc(.{ .slot_size = 256 }).payload_size;

/// Test-only: xorshift64, seeded per producer. Drives the payload
/// lengths and the stall decisions; the scheduling stays the only
/// nondeterminism.
const HammerRng = struct {
    state: u64,

    fn next(self: *HammerRng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }
};

/// Test-only: the hammer message's fill byte, derived from the identity
/// the prefix carries.
fn hammerFill(id: usize, i: usize) u8 {
    return @truncate(id *% 131 +% i *% 17 +% 0x5A);
}

/// Test-only: the exact bytes a hammer commit writes: identity, length,
/// and claim position in the prefix, then padding of the derived fill
/// byte. `len` must hold the prefix.
fn hammerMessage(id: usize, i: usize, pos: u64, len: usize, buf: []u8) []const u8 {
    const fill = hammerFill(id, i);
    var stream = Io.Writer.fixed(buf);
    stream.print("p{d}m{d}l{d}s{d}!", .{ id, i, len, pos }) catch unreachable;
    if (stream.end > len) @panic("hammer message prefix overflows the chosen length");
    @memset(buf[stream.end..len], fill);
    stream.end = len;
    return buf[0..len];
}

/// Test-only: parse a delivered hammer payload and verify it byte for
/// byte against the message the producer wrote for the identity embedded
/// in it. A parse failure, an out-of-range identity, or a byte mismatch
/// is a torn or stale payload: panic.
fn expectHammerPayload(msg: []const u8, num_producers: usize, per_producer: usize) HammerId {
    if (msg.len == 0 or msg[0] != 'p') @panic("hammer payload is torn: no prefix");
    const m = std.mem.indexOfScalarPos(u8, msg, 1, 'm') orelse
        @panic("hammer payload is torn: no index");
    const l = std.mem.indexOfScalarPos(u8, msg, m + 1, 'l') orelse
        @panic("hammer payload is torn: no length");
    const s = std.mem.indexOfScalarPos(u8, msg, l + 1, 's') orelse
        @panic("hammer payload is torn: no position");
    const bang = std.mem.indexOfScalarPos(u8, msg, s + 1, '!') orelse
        @panic("hammer payload is torn: no terminator");
    const id = std.fmt.parseInt(usize, msg[1..m], 10) catch
        @panic("hammer payload is torn: producer id");
    const i = std.fmt.parseInt(usize, msg[m + 1 .. l], 10) catch
        @panic("hammer payload is torn: message index");
    const len = std.fmt.parseInt(usize, msg[l + 1 .. s], 10) catch
        @panic("hammer payload is torn: length");
    const pos = std.fmt.parseInt(u64, msg[s + 1 .. bang], 10) catch
        @panic("hammer payload is torn: position");
    if (id >= num_producers or i >= per_producer) {
        @panic("hammer payload is torn: identity out of range");
    }
    if (len > hammer_payload_size) @panic("hammer payload is torn: length above the payload");
    var expected_buf: [hammer_payload_size]u8 = undefined;
    const expected = hammerMessage(id, i, pos, len, &expected_buf);
    if (!std.mem.eql(u8, expected, msg)) {
        @panic("hammer payload does not match its committed bytes");
    }
    return .{ .id = id, .i = i, .len = len, .pos = pos };
}

/// Test-only: the threaded chaos hammer, one instantiation per policy.
/// Three seeded producers write self-describing payloads into a 16-slot
/// futex ring while one consumer drains it, so the concurrent paths —
/// torn writes, stale stamps, displacement, and the shutdown handshake —
/// run under a fixed seed and bounded work.
fn Hammer(comptime policy: OnFull) type {
    return struct {
        const Ring = Mpsc(.{ .slot_size = 256, .wake = .futex, .on_full = policy });
        const num_producers = 3;
        const per_producer = 200;
        const total = num_producers * per_producer;

        const Producer = struct {
            ring: *Ring,
            id: usize,
            refused: *atomic.Value(usize),

            fn run(self: Producer) void {
                var rng: HammerRng = .{
                    .state = hammer_seed +% @as(u64, self.id) *% 0x9E37_79B9_7F4A_7C15,
                };
                for (0..per_producer) |i| {
                    var lease = self.ring.acquire() orelse {
                        _ = self.refused.fetchAdd(1, .monotonic);
                        continue;
                    };
                    const r = rng.next();
                    const len = hammer_len_min + r % (hammer_payload_size - hammer_len_min + 1);
                    var buf: [hammer_payload_size]u8 = undefined;
                    const msg = hammerMessage(self.id, i, lease.index(), len, &buf);
                    var w = lease.writer();
                    // Write the first half, then occasionally stall
                    // inside the write: a bounded window in which the
                    // slot is half-written with no committed stamp.
                    const split = msg.len / 2;
                    w.writeAll(msg[0..split]) catch unreachable;
                    if (r % 32 == 0) {
                        for (0..400) |_| atomic.spinLoopHint();
                    }
                    w.writeAll(msg[split..]) catch unreachable;
                    lease.commit(self.ring, @intCast(w.end));
                }
            }
        };

        const Consumer = struct {
            ring: *Ring,
            seen: *[num_producers][per_producer]bool,
            received: *usize,

            fn run(self: Consumer) void {
                if (comptime policy == .drop_new) {
                    return self.drainBorrowed();
                } else {
                    return self.drainClaiming();
                }
            }

            fn count(self: Consumer, h: HammerId) void {
                if (self.seen[h.id][h.i]) @panic("hammer delivered a message twice");
                self.seen[h.id][h.i] = true;
                self.received.* += 1;
            }

            fn drainBorrowed(self: Consumer) void {
                var read_pos: u64 = 0;
                while (true) {
                    const msg = self.ring.read(read_pos) orelse {
                        if (!self.ring.waitForData(read_pos)) return;
                        continue;
                    };
                    const h = expectHammerPayload(msg.payload, num_producers, per_producer);
                    if (h.pos != read_pos) {
                        @panic("hammer delivered a stale or out-of-order position");
                    }
                    self.count(h);
                    msg.release();
                    read_pos += 1;
                }
            }

            fn drainClaiming(self: Consumer) void {
                var buf: [hammer_payload_size]u8 = undefined;
                var last_pos: ?u64 = null;
                while (true) {
                    const msg = self.ring.read(&buf) orelse {
                        if (!self.ring.waitForData(0)) return;
                        continue;
                    };
                    const h = expectHammerPayload(msg, num_producers, per_producer);
                    if (last_pos) |prev| {
                        if (h.pos <= prev) @panic("hammer delivered positions out of order");
                    }
                    last_pos = h.pos;
                    self.count(h);
                }
            }
        };
    };
}

/// Test-only: the threaded eventfd hammer, one instantiation per policy.
/// Three seeded producers write self-describing payloads while one
/// consumer drains them through the armed doorbell cycle: arm, re-check
/// the ring, poll only if it is still empty, disarm on the wake,
/// acknowledge, drain. The stop flag is the test's shutdown — the
/// eventfd flavor has no handshake — and the poll timeout bounds every
/// wait, so a lost wake delays the drain but cannot hang it.
fn EventfdHammer(comptime policy: OnFull) type {
    return struct {
        const Ring = Mpsc(.{ .slot_size = 256, .wake = .eventfd, .on_full = policy });
        const num_producers = 3;
        const per_producer = 200;
        const total = num_producers * per_producer;

        /// The consumer's poll timeout: the stop flag is re-checked at
        /// least this often, so the exit is bounded even if a wake is
        /// lost.
        const poll_timeout_ms = 10;

        const Producer = struct {
            ring: *Ring,
            id: usize,
            refused: *atomic.Value(usize),

            fn run(self: Producer) void {
                var rng: HammerRng = .{
                    .state = hammer_seed +% @as(u64, self.id) *% 0x9E37_79B9_7F4A_7C15,
                };
                for (0..per_producer) |i| {
                    var lease = self.ring.acquire() orelse {
                        _ = self.refused.fetchAdd(1, .monotonic);
                        continue;
                    };
                    const r = rng.next();
                    const len = hammer_len_min + r % (hammer_payload_size - hammer_len_min + 1);
                    var buf: [hammer_payload_size]u8 = undefined;
                    const msg = hammerMessage(self.id, i, lease.index(), len, &buf);
                    var w = lease.writer();
                    // Write the first half, then occasionally stall
                    // inside the write: a bounded window in which the
                    // slot is half-written with no committed stamp.
                    const split = msg.len / 2;
                    w.writeAll(msg[0..split]) catch unreachable;
                    if (r % 32 == 0) {
                        for (0..400) |_| atomic.spinLoopHint();
                    }
                    w.writeAll(msg[split..]) catch unreachable;
                    lease.commit(self.ring, @intCast(w.end));
                }
            }
        };

        const Consumer = struct {
            ring: *Ring,
            seen: *[num_producers][per_producer]bool,
            received: *usize,
            stop: *atomic.Value(bool),
            /// `.drop_oldest`: the last delivered position, so an
            /// out-of-order delivery panics.
            last_pos: ?u64 = null,

            fn count(self: *Consumer, h: HammerId) void {
                if (self.seen[h.id][h.i]) @panic("eventfd hammer delivered a message twice");
                self.seen[h.id][h.i] = true;
                self.received.* += 1;
            }

            /// Drain everything committed right now, in order; returns
            /// the number delivered.
            fn drainAll(self: *Consumer, read_pos: *u64) usize {
                var delivered: usize = 0;
                if (comptime policy == .drop_new) {
                    while (true) {
                        const msg = self.ring.read(read_pos.*) orelse break;
                        const h = expectHammerPayload(msg.payload, num_producers, per_producer);
                        if (h.pos != read_pos.*) {
                            @panic("eventfd hammer delivered a stale or out-of-order position");
                        }
                        self.count(h);
                        msg.release();
                        read_pos.* += 1;
                        delivered += 1;
                    }
                } else {
                    var buf: [hammer_payload_size]u8 = undefined;
                    while (self.ring.read(&buf)) |msg| {
                        const h = expectHammerPayload(msg, num_producers, per_producer);
                        if (self.last_pos) |prev| {
                            if (h.pos <= prev) {
                                @panic("eventfd hammer delivered positions out of order");
                            }
                        }
                        self.last_pos = h.pos;
                        self.count(h);
                        delivered += 1;
                    }
                }
                return delivered;
            }

            fn run(self: *Consumer) void {
                var read_pos: u64 = 0;
                while (true) {
                    _ = self.drainAll(&read_pos);
                    if (self.stop.load(.acquire)) {
                        // The producers have stopped: this final drain
                        // closes the race between the first drain and
                        // the stop store.
                        _ = self.drainAll(&read_pos);
                        return;
                    }
                    {
                        // The scoped wait: arm, re-check the ring, poll
                        // only if it is still empty, disarm on the wake.
                        self.ring.armDoorbell();
                        defer self.ring.disarmDoorbell();
                        if (self.drainAll(&read_pos) == 0) {
                            var fds = [1]linux.pollfd{.{
                                .fd = self.ring.pollFd(),
                                .events = linux.POLL.IN,
                                .revents = 0,
                            }};
                            _ = linux.poll(&fds, 1, poll_timeout_ms);
                        }
                    }
                    // Acknowledge the doorbell if it rang, then drain.
                    self.ring.ackDoorbell();
                }
            }
        };
    };
}

test "acquire, commit, read, release" {
    var ring: Mpsc(.{}) = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("hello");
    lease.commit(&ring, @intCast(w.end));

    try testing.expectEqualStrings("hello", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
    // Released: the next lap's producer may claim it.
    try testing.expect(ring.read(0) == null);
}

test "wrap reuses slots across laps" {
    var ring: Mpsc(.{}) = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..2) |round| {
        for (0..4) |i| {
            var lease = try expectAcquire(&ring);
            var w = lease.writer();
            try w.print("r{d}s{d}", .{ round, i });
            lease.commit(&ring, @intCast(w.end));
        }
        const base = round * 4;
        for (0..4) |i| {
            const msg = ring.read(base + i) orelse return error.NotCommitted;
            var expect_buf: [16]u8 = undefined;
            const expect = try std.fmt.bufPrint(&expect_buf, "r{d}s{d}", .{ round, i });
            try testing.expectEqualStrings(expect, msg.payload);
            msg.release();
        }
    }
    try testing.expectEqual(8, ring.head());
}

test "a full ring refuses new claims without corrupting" {
    // Four slots, none consumed: the fifth claim hits a slot still
    // owned and is dropped, and the stalled owner keeps its slot.
    var ring: Mpsc(.{}) = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    var leases: [4]Mpsc(.{}).Lease = undefined;
    for (&leases, 0..) |*l, i| {
        l.* = try expectAcquire(&ring);
        var w = l.writer();
        try w.print("s{d}", .{i});
        l.commit(&ring, @intCast(w.end));
    }
    // All four committed, none released: the ring is full.
    try testing.expect(ring.acquire() == null);

    // Drain releases slots and the next claims succeed again.
    for (0..4) |i| (try expectRead(&ring, i)).release();
    try testing.expect(ring.acquire() != null);
}

test "a stalled mid-write producer blocks the head in order" {
    // Positions are claimed in order, so a producer stalled mid-write
    // at the head blocks every later claim — `acquire` returns null —
    // and the consumer stalls behind its position: the cost of the
    // stall is dropped messages, never corrupted ones.
    var ring: Mpsc(.{}) = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    // Claim position 0 and never commit it.
    var stalled = try expectAcquire(&ring);
    try testing.expect(ring.read(0) == null);
    // The head is at 1: positions 1..3 claim and flow.
    for (0..3) |_| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.writeAll("flow");
        lease.commit(&ring, @intCast(w.end));
    }
    var read_pos: u64 = 1;
    while (read_pos < ring.head()) : (read_pos += 1) {
        (try expectRead(&ring, read_pos)).release();
    }
    // Everything behind the stalled position drains; nothing passes it.
    try testing.expectEqual(4, ring.head());
    try testing.expect(ring.read(0) == null);
    // The stall does not corrupt: releasing nothing, slot 0's stamp
    // still names lap 0, and the stalled lease could still commit.
    var w = stalled.writer();
    try w.writeAll("late");
    stalled.commit(&ring, @intCast(w.end));
    try testing.expectEqualStrings("late", ring.read(0).?.payload);
}

test "multi-threaded producers, single consumer" {
    const Ring = Mpsc(.{ .wake = .futex });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 64);
    defer ring.deinit(testing.allocator);

    const num_producers = 4;
    const per_producer = 100;
    const total = num_producers * per_producer;

    var dropped: atomic.Value(usize) = .init(0);

    const Producer = struct {
        ring: *Ring,
        id: u32,
        dropped: *atomic.Value(usize),

        const Self = @This();

        fn run(self: Self) void {
            for (0..per_producer) |i| {
                var lease = self.ring.acquire() orelse {
                    _ = self.dropped.fetchAdd(1, .monotonic);
                    continue;
                };
                var w = lease.writer();
                w.print("p{d}m{d}", .{ self.id, i }) catch unreachable;
                lease.commit(self.ring, @intCast(w.end));
            }
        }
    };

    const Consumer = struct {
        ring: *Ring,
        received: *usize,

        const Self = @This();

        fn run(self: Self) void {
            var read_pos: u64 = 0;
            while (true) {
                while (read_pos < self.ring.head()) {
                    // In order: stop at the first uncommitted claim —
                    // a producer mid-write — and retry from it; a
                    // consumer that advances past a null read skips
                    // committed messages behind it.
                    const msg = self.ring.read(read_pos) orelse break;
                    // The stamp gate makes torn reads impossible; a
                    // refused claim is a dropped message, not a
                    // corrupted one.
                    if (msg.payload.len == 0) @panic("empty message");
                    msg.release();
                    self.received.* += 1;
                    read_pos += 1;
                }
                if (self.ring.isShutdown() and read_pos >= self.ring.head()) return;
            }
        }
    };

    var received: usize = 0;
    const consumer: Consumer = .{ .ring = &ring, .received = &received };
    const consumer_thread = try Thread.spawn(.{}, Consumer.run, .{consumer});

    var producers: [num_producers]Producer = undefined;
    var threads: [num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = @intCast(i), .dropped = &dropped };
        t.* = try .spawn(.{}, Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    ring.requestShutdown();
    consumer_thread.join();

    // The busy-spin consumer can fall behind four producers, so drops
    // are legitimate; the invariant is that nothing is lost beyond
    // them: every message is either delivered or counted as dropped.
    try testing.expectEqual(total, received + dropped.load(.monotonic));
}

test "futex shutdown wakes the waiter, no lost wake" {
    // Shutdown-race hammer: requestShutdown whose wake fires between the
    // consumer arming the waiter and entering Futex.wait hits no
    // sleeper, and shutdown never advances the head, so the futex
    // expected-value check cannot save it — the consumer would sleep
    // forever. The generation bump in the same word as the waiter flag
    // is the fix: fire shutdown the moment the consumer arms.
    const Ring = Mpsc(.{ .wake = .futex });
    const rounds = 64;
    for (0..rounds) |_| {
        var ring: Ring = undefined;
        try ring.init(testing.allocator, testing.io, 16);
        defer ring.deinit(testing.allocator);

        var result: bool = true;
        const waiter = try Thread.spawn(.{}, struct {
            fn run(r: *Ring, res: *bool) void {
                // Empty ring: blocks until shutdown.
                res.* = r.waitForData(0);
            }
        }.run, .{ &ring, &result });

        // Bound the arming spin: a consumer that never arms must fail
        // the test, not hang it.
        var attempts: usize = 0;
        while (ring.hot.wake_state.load(.acquire) & Ring.waiter_bit == 0) {
            atomic.spinLoopHint();
            attempts += 1;
            if (attempts > 100_000_000) return error.ConsumerNeverArmed;
        }
        ring.requestShutdown();
        waiter.join();

        try testing.expect(!result);
    }
}

test "the shutdown exit keeps data committed into the window" {
    // Regression shape for the shutdown exit: a producer can commit
    // between the consumer's earlier read and the shutdown load, and
    // producer quiescence makes every commit sequenced before the
    // shutdown store — so the exit's post-acquire data check sees it.
    // Pinned directly on the policy helper the two exit branches share.
    const Ring = Mpsc(.{ .wake = .futex });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 4);
    defer ring.deinit(testing.allocator);

    // The consumer's earlier read: nothing at position 0 yet.
    try testing.expect(ring.read(0) == null);

    // The commit lands after that read, before shutdown is observed.
    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("raced");
    lease.commit(&ring, @intCast(w.end));
    ring.requestShutdown();

    // The exit sees the raced commit: data wins over shutdown.
    try testing.expect(ring.dataAtShutdown(0));
    try testing.expectEqualStrings("raced", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
    try testing.expect(!ring.dataAtShutdown(1));
}

test "the hot line holds the head and the wake word for every flavor" {
    // The producer's metadata stays on one line: the head RMW of a
    // claim and the wake RMW of a commit are the two producer writes
    // per message, and a second line would double the coherence
    // traffic. The comptime assert inside `Hot` guards every
    // instantiation; this pins it for the three flavors.
    comptime {
        assert(@sizeOf(Mpsc(.{}).Hot) <= atomic.cache_line);
        assert(@sizeOf(Mpsc(.{ .wake = .eventfd }).Hot) <= atomic.cache_line);
        assert(@sizeOf(Mpsc(.{ .wake = .futex }).Hot) <= atomic.cache_line);
        assert(@sizeOf(Mpsc(.{ .wake = .eventfd, .on_full = .drop_oldest }).Hot) <=
            atomic.cache_line);
    }
}

test "lap arithmetic wraps with the stamp's lap half" {
    // At 2^32 laps per slot the stamp's high half wraps; lapOf wraps
    // with it, so a position past the wrap claims a slot whose stamp
    // arithmetic agrees — modulo 2^32, collisions need a producer
    // stalled exactly 2^32 revolutions.
    var ring: Mpsc(.{}) = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), ring.lapOf(0));
    try testing.expectEqual(@as(u32, 1), ring.lapOf(4));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), ring.lapOf(0xFFFF_FFFF * 4 + 3));
    // The wrap: 2^32 laps truncates to lap 0, same slot, same stamp
    // arithmetic as position 0.
    try testing.expectEqual(@as(u32, 0), ring.lapOf(0x1_0000_0000 * 4));
}

test "futex data wins over shutdown" {
    const Ring = Mpsc(.{ .wake = .futex });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("bye");
    lease.commit(&ring, @intCast(w.end));
    ring.requestShutdown();

    // Committed-before-shutdown data is returned first...
    try testing.expect(ring.waitForData(0));
    try testing.expectEqualStrings("bye", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
    // ...then the exit.
    try testing.expect(!ring.waitForData(1));
}

test "eventfd doorbell composes with a poll loop" {
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    try testing.expect(ring.pollFd() >= 0);
    // The consumer's scoped wait: arm, re-check, wait, disarm on the
    // wake.
    ring.armDoorbell();
    try testing.expect(ring.read(0) == null);

    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("ding");
    lease.commit(&ring, @intCast(w.end));

    // The armed commit poked the fd; the wait's poll reads it ready.
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.disarmDoorbell();

    // Acknowledge the doorbell if it rang, then drain by position.
    ring.ackDoorbell();
    try testing.expectEqualStrings("ding", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
}

test "a refused acquire races a consumer release" {
    // The full-ring refusal and the release are deterministic in one
    // thread, so the interleaving is replayed rather than raced: the
    // refusal observes the null, the head does not move across it, and
    // the next claim is granted at the exact position the refusal
    // targeted once the consumer frees the slot.
    const rounds = 64;
    for (0..rounds) |_| {
        var ring: Mpsc(.{}) = undefined;
        try ring.init(testing.allocator, undefined, 4);
        defer ring.deinit(testing.allocator);

        for (0..4) |_| {
            var lease = try expectAcquire(&ring);
            var w = lease.writer();
            try w.writeAll("fill");
            lease.commit(&ring, @intCast(w.end));
        }
        // All four committed, none released: the head is full.
        try testing.expectEqual(4, ring.head());

        // The refusal: slot 0 still names lap 0 while the head wants
        // lap 1. The claim is dropped, not queued.
        const refused = ring.acquire();
        try testing.expect(refused == null);
        // A refused claim burns no position.
        try testing.expectEqual(4, ring.head());

        // The consumer releases slot 0; the next claim is granted at
        // the head, the position the refusal just targeted.
        (try expectRead(&ring, 0)).release();
        var lease = try expectAcquire(&ring);
        try testing.expectEqual(4, lease.index());
        var w = lease.writer();
        try w.writeAll("fresh");
        lease.commit(&ring, @intCast(w.end));
        try testing.expectEqual(5, ring.head());
        try testing.expectEqualStrings("fresh", ring.read(4).?.payload);
    }
}

test "contended claims keep payloads distinct" {
    // The producer CAS races on the head while the consumer parks on
    // the futex; every committed message must read back as its own
    // payload. The single consumer owns the seen table, so a duplicate
    // or a torn message shows up as a repeat or a parse failure rather
    // than as a data race on the table itself.
    const Ring = Mpsc(.{ .wake = .futex });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 64);
    defer ring.deinit(testing.allocator);

    const num_producers = 4;
    const per_producer = 100;
    const total = num_producers * per_producer;

    var dropped: atomic.Value(usize) = .init(0);

    const Producer = struct {
        ring: *Ring,
        id: u32,
        dropped: *atomic.Value(usize),

        const Self = @This();

        fn run(self: Self) void {
            for (0..per_producer) |i| {
                var lease = self.ring.acquire() orelse {
                    _ = self.dropped.fetchAdd(1, .monotonic);
                    continue;
                };
                var w = lease.writer();
                w.print("p{d}m{d}", .{ self.id, i }) catch unreachable;
                lease.commit(self.ring, @intCast(w.end));
            }
        }
    };

    const Consumer = struct {
        ring: *Ring,
        seen: *[num_producers][per_producer]bool,
        received: *usize,
        duplicates: *usize,

        const Self = @This();

        fn run(self: Self) void {
            var read_pos: u64 = 0;
            while (self.ring.waitForData(read_pos)) {
                const msg = self.ring.read(read_pos).?;
                const m = std.mem.indexOfScalar(u8, msg.payload, 'm') orelse
                    @panic("malformed message");
                const id = std.fmt.parseInt(usize, msg.payload[1..m], 10) catch
                    @panic("malformed producer id");
                const i = std.fmt.parseInt(usize, msg.payload[m + 1 ..], 10) catch
                    @panic("malformed message index");
                if (self.seen[id][i]) self.duplicates.* += 1;
                self.seen[id][i] = true;
                self.received.* += 1;
                msg.release();
                read_pos += 1;
            }
        }
    };

    var seen: [num_producers][per_producer]bool = @splat(@splat(false));
    var received: usize = 0;
    var duplicates: usize = 0;
    const consumer: Consumer = .{
        .ring = &ring,
        .seen = &seen,
        .received = &received,
        .duplicates = &duplicates,
    };
    const consumer_thread = try Thread.spawn(.{}, Consumer.run, .{consumer});

    var producers: [num_producers]Producer = undefined;
    var threads: [num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = @intCast(i), .dropped = &dropped };
        t.* = try .spawn(.{}, Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    ring.requestShutdown();
    consumer_thread.join();

    // A stale or torn payload would have landed on an entry already
    // set: no message is ever delivered twice.
    try testing.expectEqual(0, duplicates);
    // Drops are legitimate under contention; nothing is lost beyond
    // them.
    try testing.expectEqual(total, received + dropped.load(.monotonic));
}

test "drop_oldest: a full ring displaces the oldest and the newest lands" {
    // Four slots, four committed unreleased: the ring is full. The
    // fifth claim displaces the oldest (position 0) instead of dropping
    // the new message — the newest message wins.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }
    try testing.expectEqual(4, ring.head());
    try testing.expectEqual(0, ring.readHead());

    // The displacement: the claim lands at position 4, the message at
    // position 0 is dropped, and the ring counts the loss.
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
    var w = lease.writer();
    try w.writeAll("newest");
    lease.commit(&ring, @intCast(w.end));
    try testing.expectEqual(5, ring.head());
    try testing.expectEqual(1, ring.displacedCount());
    try testing.expectEqual(1, ring.readHead());

    // The stream stays in order from the ring's cursor: s1, s2, s3,
    // then the newest message at 4. Each consume claims the cursor.
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expectEqualStrings("s1", try expectConsume(&ring, &buf));
    try testing.expectEqual(2, ring.readHead());
    try testing.expectEqualStrings("s2", try expectConsume(&ring, &buf));
    try testing.expectEqual(3, ring.readHead());
    try testing.expectEqualStrings("s3", try expectConsume(&ring, &buf));
    try testing.expectEqual(4, ring.readHead());
    try testing.expectEqualStrings("newest", try expectConsume(&ring, &buf));
    try testing.expectEqual(5, ring.readHead());
    // Drained: nothing committed at the head.
    try testing.expect(ring.read(&buf) == null);
}

test "drop_oldest: a claimed window cannot be displaced" {
    // The deterministic half of the no-torn-read invariant, in the
    // claiming protocol's order: the reader wins the cursor CAS before
    // touching payload bytes, so its window is exclusive — a
    // displacer's expected cursor value is stale and it cannot free
    // the slot under the reader. A producer under the window refuses
    // in bounded steps and the pinned payload is untouched; the reader
    // then copies inside the window, frees the slot, and the newest
    // message lands. The window is replayed step for step because
    // `read` has no injection point between its CAS and its copy.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    // The reader's claim: the cursor CAS before any payload access.
    const pos = ring.readHead();
    try testing.expectEqual(0, pos);
    const slot = &ring.slots[pos & ring.mask];
    const stamp = slot.stamp.load(.acquire);
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(stamp >> 32)));
    try testing.expectEqual(@as(u32, 2), @as(u32, @truncate(stamp)));
    try testing.expect(ring.read_head.cmpxchgStrong(pos, pos + 1, .acq_rel, .monotonic) == null);

    // A producer under the window: bounded refusal, no displacement,
    // the pinned payload untouched.
    try testing.expect(ring.acquire() == null);
    try testing.expectEqual(4, ring.head());
    try testing.expectEqual(0, ring.displacedCount());
    try testing.expectEqualStrings("s0", slot.payload[0..2]);

    // The reader's copy inside the window, then the release store.
    var copy: [16]u8 = undefined;
    @memcpy(copy[0..2], slot.payload[0..2]);
    slot.stamp.store(@as(u64, 1) << 32, .release);
    try testing.expectEqual(1, ring.readHead());

    // The freed cell claims for the producer, and the copy the reader
    // took was never overwritten by a displacement.
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
    var w = lease.writer();
    try w.writeAll("newest");
    lease.commit(&ring, @intCast(w.end));
    try testing.expectEqualStrings("s0", copy[0..2]);

    // The stream from the cursor is whole: s1, s2, s3, newest.
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expectEqualStrings("s1", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("s2", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("s3", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("newest", try expectConsume(&ring, &buf));
    try testing.expectEqual(5, ring.readHead());
}

test "drop_oldest: a stalled mid-write producer refuses instead of displacing" {
    // There is no committed message to displace when the head's slot
    // holds an uncommitted claim: freeing that slot would let the
    // stalled producer's late commit rewind the stamp over the next
    // lap, so the claim is refused exactly as `.drop_new` refuses it.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    // Position 0 claimed and never committed: the consumer stalls
    // behind it, and positions 1..3 fill the ring.
    var stalled = try expectAcquire(&ring);
    for (1..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }
    try testing.expectEqual(4, ring.head());

    // The head's slot holds the uncommitted claim: refused, and no
    // message was displaced to make room. The claiming read at the
    // cursor refuses too: there is nothing committed to consume.
    try testing.expect(ring.acquire() == null);
    try testing.expectEqual(0, ring.displacedCount());
    try testing.expectEqual(0, ring.readHead());
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expect(ring.read(&buf) == null);
    try testing.expectEqual(0, ring.readHead());

    // The stall clears: the commit lands, the consumer drains 0..3
    // from the ring's cursor, and the ring flows again.
    var w = stalled.writer();
    try w.writeAll("late");
    stalled.commit(&ring, @intCast(w.end));
    for (0..4) |i| {
        try testing.expectEqual(@as(u64, i), ring.readHead());
        _ = try expectConsume(&ring, &buf);
    }
    try testing.expectEqual(4, ring.readHead());
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
}

test "drop_oldest: the eventfd displacement notify is gated on the armed bit" {
    // A displacement advances the ring's cursor, and a consumer may be
    // parked in poll with the displaced position as its cursor — the
    // cursor move is what frees it, so the displacement notifies on
    // its own, before any commit. The notify is gated like a commit's:
    // a disarmed consumer pays nothing, an armed one is poked.
    const Ring = Mpsc(.{ .wake = .eventfd, .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 1);
    defer ring.deinit(testing.allocator);

    // Disarmed: the commit and the displacement that follows it both
    // write nothing.
    var a = try expectAcquire(&ring);
    {
        var w = a.writer();
        try w.writeAll("a");
        a.commit(&ring, @intCast(w.end));
    }
    try testing.expect(!doorbellReadable(ring.pollFd()));

    var b = try expectAcquire(&ring);
    try testing.expectEqual(1, b.index());
    try testing.expectEqual(1, ring.displacedCount());
    try testing.expectEqual(1, ring.readHead());
    try testing.expect(!doorbellReadable(ring.pollFd()));

    // Armed: the commit pokes, and the next displacement pokes on its
    // own after the counter is drained.
    ring.armDoorbell();
    {
        var w = b.writer();
        try w.writeAll("b");
        b.commit(&ring, @intCast(w.end));
    }
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.ackDoorbell();
    try testing.expect(!doorbellReadable(ring.pollFd()));

    var c = try expectAcquire(&ring);
    try testing.expectEqual(2, c.index());
    try testing.expectEqual(2, ring.displacedCount());
    try testing.expectEqual(2, ring.readHead());
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.ackDoorbell();
    ring.disarmDoorbell();
}

test "drop_oldest: threaded churn, received + displaced + refused == total" {
    // The drop_new threaded test's shape, with the loss moved to the
    // oldest: every claim is either received, displaced by a later
    // producer, or refused — the head's slot holds an uncommitted
    // claim, or its window could not be displaced in bounded steps.
    // Nothing else can happen to a message.
    const Ring = Mpsc(.{ .wake = .futex, .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    const num_producers = 4;
    const per_producer = 100;
    const total = num_producers * per_producer;

    var refused: atomic.Value(usize) = .init(0);

    const Producer = struct {
        ring: *Ring,
        id: u32,
        refused: *atomic.Value(usize),

        const Self = @This();

        fn run(self: Self) void {
            for (0..per_producer) |i| {
                var lease = self.ring.acquire() orelse {
                    _ = self.refused.fetchAdd(1, .monotonic);
                    continue;
                };
                var w = lease.writer();
                w.print("p{d}m{d}", .{ self.id, i }) catch unreachable;
                lease.commit(self.ring, @intCast(w.end));
            }
        }
    };

    const Consumer = struct {
        ring: *Ring,
        received: *usize,

        const Self = @This();

        fn run(self: Self) void {
            var buf: [Ring.payload_size]u8 = undefined;
            while (true) {
                // The claiming read copies inside its won window, so a
                // returned payload is whole: count it.
                if (self.ring.read(&buf)) |msg| {
                    if (msg.len == 0) @panic("empty message");
                    self.received.* += 1;
                    continue;
                }
                // Nothing committed at the ring's cursor: a producer
                // mid-write, a lost claim (displaced under the reader),
                // or an empty ring. The wake loop probes without
                // claiming.
                if (!self.ring.waitForData(0)) return;
            }
        }
    };

    var received: usize = 0;
    const consumer: Consumer = .{ .ring = &ring, .received = &received };
    const consumer_thread = try Thread.spawn(.{}, Consumer.run, .{consumer});

    var producers: [num_producers]Producer = undefined;
    var threads: [num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = @intCast(i), .refused = &refused };
        t.* = try .spawn(.{}, Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    ring.requestShutdown();
    consumer_thread.join();

    try testing.expectEqual(
        total,
        received + ring.displacedCount() + refused.load(.monotonic),
    );
}

test "drop_oldest: contended claims keep payloads distinct" {
    // The contended test's protections — no duplicate, no torn
    // payload — re-run under the displacing policy. The claiming read
    // copies inside its won window, so a returned payload is whole: a
    // parse failure is a bug, a repeated payload is a lost exclusion,
    // and the loss accounting must still close.
    const Ring = Mpsc(.{ .wake = .futex, .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    const num_producers = 4;
    const per_producer = 100;
    const total = num_producers * per_producer;

    var refused: atomic.Value(usize) = .init(0);

    const Producer = struct {
        ring: *Ring,
        id: u32,
        refused: *atomic.Value(usize),

        const Self = @This();

        fn run(self: Self) void {
            for (0..per_producer) |i| {
                var lease = self.ring.acquire() orelse {
                    _ = self.refused.fetchAdd(1, .monotonic);
                    continue;
                };
                var w = lease.writer();
                w.print("p{d}m{d}", .{ self.id, i }) catch unreachable;
                lease.commit(self.ring, @intCast(w.end));
            }
        }
    };

    const Consumer = struct {
        ring: *Ring,
        seen: *[num_producers][per_producer]bool,
        received: *usize,
        duplicates: *usize,

        const Self = @This();

        const Parsed = struct { id: usize, i: usize };

        fn parse(payload: []const u8) ?Parsed {
            const m = std.mem.indexOfScalar(u8, payload, 'm') orelse return null;
            const id = std.fmt.parseInt(usize, payload[1..m], 10) catch return null;
            const i = std.fmt.parseInt(usize, payload[m + 1 ..], 10) catch return null;
            if (id >= num_producers or i >= per_producer) return null;
            return .{ .id = id, .i = i };
        }

        fn run(self: Self) void {
            var buf: [Ring.payload_size]u8 = undefined;
            while (true) {
                // The claiming read copies inside its won window, so a
                // returned payload is whole: a parse failure is a bug,
                // not a torn discard.
                const msg = self.ring.read(&buf) orelse {
                    if (!self.ring.waitForData(0)) return;
                    continue;
                };
                const p = parse(msg) orelse @panic("claimed payload is torn");
                if (self.seen[p.id][p.i]) self.duplicates.* += 1;
                self.seen[p.id][p.i] = true;
                self.received.* += 1;
            }
        }
    };

    var seen: [num_producers][per_producer]bool = @splat(@splat(false));
    var received: usize = 0;
    var duplicates: usize = 0;
    const consumer: Consumer = .{
        .ring = &ring,
        .seen = &seen,
        .received = &received,
        .duplicates = &duplicates,
    };
    const consumer_thread = try Thread.spawn(.{}, Consumer.run, .{consumer});

    var producers: [num_producers]Producer = undefined;
    var threads: [num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = @intCast(i), .refused = &refused };
        t.* = try .spawn(.{}, Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    ring.requestShutdown();
    consumer_thread.join();

    // A stale or torn payload would have landed on an entry already
    // set: no message is ever delivered twice.
    try testing.expectEqual(0, duplicates);
    // Every claim is received, displaced, or refused; nothing else can
    // happen to a message.
    try testing.expectEqual(
        total,
        received + ring.displacedCount() + refused.load(.monotonic),
    );
}

test "drop_oldest: a paused reader refuses producers, then completes its window" {
    // Schedule (a): the reader wins the cursor CAS and pauses mid-copy
    // (a bounded spin on a shared flag), producers press on the head.
    // Every claim must refuse in bounded steps — the old protocol spun
    // producers on the paused reader — and must not touch the pinned
    // payload. The reader then copies inside its window, frees the
    // slot, and the ring flows; the copy is intact. The window is
    // replayed step for step because `read` has no injection point
    // between its CAS and its copy.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    const State = struct {
        paused: atomic.Value(bool) = .init(false),
        go: atomic.Value(bool) = .init(false),
        done: atomic.Value(bool) = .init(false),
        copy: [16]u8 = undefined,
        copy_len: usize = 0,
    };
    var state: State = .{};

    const Reader = struct {
        ring: *Ring,
        state: *State,

        const Self = @This();

        fn run(self: Self) void {
            const pos = self.ring.readHead();
            const slot = &self.ring.slots[pos & self.ring.mask];
            const len: u32 = @truncate(slot.stamp.load(.acquire));
            if (self.ring.read_head.cmpxchgStrong(pos, pos + 1, .acq_rel, .monotonic) != null)
                @panic("reader lost its cursor claim");
            self.state.paused.store(true, .release);
            while (!self.state.go.load(.acquire)) atomic.spinLoopHint();
            @memcpy(self.state.copy[0..len], slot.payload[0..len]);
            self.state.copy_len = len;
            slot.stamp.store(@as(u64, self.ring.lapOf(pos) +% 1) << 32, .release);
            self.state.done.store(true, .release);
        }
    };
    const reader: Reader = .{ .ring = &ring, .state = &state };
    const reader_thread = try Thread.spawn(.{}, Reader.run, .{reader});

    // Bounded wait for the pause, so a broken schedule fails the test
    // instead of hanging it.
    var attempts: usize = 0;
    while (!state.paused.load(.acquire)) {
        atomic.spinLoopHint();
        attempts += 1;
        if (attempts > 100_000_000) return error.ReaderNeverPaused;
    }

    // Producers under pressure, while the reader is paused: every
    // claim refuses in bounded steps, the head does not move, nothing
    // is displaced, and the pinned payload is untouched.
    for (0..64) |_| try testing.expect(ring.acquire() == null);
    try testing.expectEqual(4, ring.head());
    try testing.expectEqual(0, ring.displacedCount());
    try testing.expectEqualStrings("s0", ring.slots[0].payload[0..2]);

    state.go.store(true, .release);
    attempts = 0;
    while (!state.done.load(.acquire)) {
        atomic.spinLoopHint();
        attempts += 1;
        if (attempts > 100_000_000) return error.ReaderNeverFinished;
    }
    reader_thread.join();

    // The copy was taken inside the window: intact bytes.
    try testing.expectEqual(2, state.copy_len);
    try testing.expectEqualStrings("s0", state.copy[0..2]);

    // The window's release freed the cell; the producer claims it and
    // the stream is whole.
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
    var w = lease.writer();
    try w.writeAll("newest");
    lease.commit(&ring, @intCast(w.end));
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expectEqualStrings("s1", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("s2", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("s3", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("newest", try expectConsume(&ring, &buf));
    try testing.expectEqual(5, ring.readHead());
}

test "drop_oldest: a displacer's cursor win beats a stale reader claim" {
    // Schedule (b): the reader samples the cursor and the committed
    // stamp; a displacer wins the cursor CAS and frees the cell before
    // the reader's CAS. The reader's CAS at its stale cursor loses and
    // the read returns null without touching payload bytes at all. The
    // claim CAS is replayed directly because `read` has no injection
    // point between its stamp check and its CAS.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    // Reader side, as `read` samples them: the cursor and the
    // committed stamp.
    const r = ring.readHead();
    const slot = &ring.slots[r & ring.mask];
    const stamp = slot.stamp.load(.acquire);
    try testing.expectEqual(0, r);
    try testing.expectEqual(@as(u32, 2), @as(u32, @truncate(stamp)));

    // Displacer side, as `acquire` runs it: win the cursor, free the
    // cell, count the loss.
    const free: u64 = @as(u64, 1) << 32;
    try testing.expect(ring.read_head.cmpxchgStrong(r, r + 1, .acq_rel, .monotonic) == null);
    try testing.expect(slot.stamp.cmpxchgStrong(stamp, free, .release, .monotonic) == null);
    _ = ring.displaced.fetchAdd(1, .monotonic);

    // The reader's claim at its stale r loses: null, and no payload
    // byte was read.
    try testing.expect(ring.read_head.cmpxchgStrong(r, r + 1, .acq_rel, .monotonic) != null);

    // The dropped message is gone; a fresh read claims from the new
    // cursor and gets the next committed message.
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expectEqualStrings("s1", try expectConsume(&ring, &buf));
    try testing.expectEqual(2, ring.readHead());
}

test "drop_oldest: two displacers, one cursor CAS wins" {
    // Both displacers sample the cursor at the exact-full value and
    // both see the guard pass; one cursor CAS wins, the other's fails.
    // Exactly one stamp write frees the cell and one count lands; a
    // claim made while the winner has not freed yet refuses in bounded
    // steps, and after the free the claim takes the position.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    // Both samples: head 4, cursor 0 — the guard value.
    const pos = ring.head();
    const r = ring.readHead();
    try testing.expectEqual(pos -% (ring.mask + 1), r);
    const slot = &ring.slots[r & ring.mask];
    const stamp = slot.stamp.load(.acquire);

    // The winner's cursor CAS and the loser's failed attempt from the
    // same sample.
    try testing.expect(ring.read_head.cmpxchgStrong(r, r + 1, .acq_rel, .monotonic) == null);
    try testing.expect(ring.read_head.cmpxchgStrong(r, r + 1, .acq_rel, .monotonic) != null);

    // The winner has not freed the cell: a producer refuses in bounded
    // steps, no second displacement, no second count.
    try testing.expect(ring.acquire() == null);
    try testing.expectEqual(0, ring.displacedCount());

    // The winner's single stamp write, then its count.
    const free: u64 = @as(u64, 1) << 32;
    try testing.expect(slot.stamp.cmpxchgStrong(stamp, free, .release, .monotonic) == null);
    _ = ring.displaced.fetchAdd(1, .monotonic);
    try testing.expectEqual(1, ring.displacedCount());

    // The freed cell claims now: the loser's retry lands at 4.
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
    try testing.expectEqual(1, ring.readHead());
}

test "drop_oldest: a capacity-1 displacement wakes a parked consumer" {
    // The futex wake pair on a one-slot ring: a displacement advances
    // the cursor and bumps the wake generation, so a consumer parked
    // at the displaced position cannot sleep through the cursor move;
    // the replacement holds its claim uncommitted, so the consumer
    // parks again behind it, and the replacement's commit notify wakes
    // it. The consumer's arm/wait steps are played here — the
    // `waitForData` loop has no injection point — while the producers
    // run the real `acquire` and `commit`.
    const Ring = Mpsc(.{ .wake = .futex, .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 1);
    defer ring.deinit(testing.allocator);

    const timeout: Io.Timeout = .{
        .duration = .{
            .raw = .fromNanoseconds(std.time.ns_per_s),
            .clock = .awake,
        },
    };

    // Producer A claims the one slot and holds it: nothing committed
    // at cursor 0, so the consumer arms its wait.
    var a = try expectAcquire(&ring);
    const armed = ring.hot.wake_state.fetchOr(Ring.waiter_bit, .acq_rel);
    const expected = armed | Ring.waiter_bit;

    // A commits: the notify bumps the generation.
    {
        var w = a.writer();
        try w.writeAll("a");
        a.commit(&ring, @intCast(w.end));
    }
    try testing.expect(ring.hot.wake_state.load(.acquire) != expected);

    // B displaces the committed message and claims the freed cell for
    // the replacement, uncommitted: cursor 1, one loss counted.
    var b = try expectAcquire(&ring);
    try testing.expectEqual(1, b.index());
    try testing.expectEqual(1, ring.displacedCount());
    try testing.expectEqual(1, ring.readHead());

    // The parked consumer's wait cannot sleep: the word no longer
    // matches the armed snapshot, so the cursor move is observed.
    try testing.io.futexWaitTimeout(u32, &ring.hot.wake_state.raw, expected, timeout);
    _ = ring.hot.wake_state.fetchAnd(~Ring.waiter_bit, .release);

    // Parked again behind the replacement's uncommitted position.
    try testing.expect(!ring.committedAt(1));
    const armed2 = ring.hot.wake_state.fetchOr(Ring.waiter_bit, .acq_rel);
    const expected2 = armed2 | Ring.waiter_bit;
    try testing.expect(!ring.committedAt(1));

    // The replacement commits: its notify breaks the second sleep.
    {
        var w = b.writer();
        try w.writeAll("b");
        b.commit(&ring, @intCast(w.end));
    }
    try testing.io.futexWaitTimeout(u32, &ring.hot.wake_state.raw, expected2, timeout);
    _ = ring.hot.wake_state.fetchAnd(~Ring.waiter_bit, .release);

    // The woken consumer reads the replacement, not the displaced
    // message.
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expectEqualStrings("b", try expectConsume(&ring, &buf));
    try testing.expectEqual(2, ring.readHead());
}

test "drop_oldest: a consumer release frees the head's cell before a displacement" {
    // The benign race, replayed: the producer samples the head's
    // owned-committed stamp and the exact-full cursor, and the
    // consumer's claiming read wins the cursor first, copies, and
    // frees the cell directly. The producer's stale samples are not
    // acted on: its next attempt sees the free stamp and claims
    // normally — no displacement, no count.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    // Producer side, as `acquire` samples them: the owned-committed
    // stamp and the exact-full cursor.
    const stamp = ring.slots[0].stamp.load(.acquire);
    const r = ring.readHead();
    try testing.expectEqual(0, r);
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(stamp >> 32)));
    try testing.expectEqual(@as(u32, 2), @as(u32, @truncate(stamp)));

    // The consumer's claiming read: cursor CAS, copy, release.
    var buf: [Ring.payload_size]u8 = undefined;
    try testing.expectEqualStrings("s0", try expectConsume(&ring, &buf));
    try testing.expectEqual(1, ring.readHead());

    // The claim sees the free stamp and lands: the release freed the
    // head's cell, so nothing is displaced.
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
    try testing.expectEqual(0, ring.displacedCount());
    var w = lease.writer();
    try w.writeAll("newest");
    lease.commit(&ring, @intCast(w.end));
    try testing.expectEqualStrings("s1", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("s2", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("s3", try expectConsume(&ring, &buf));
    try testing.expectEqualStrings("newest", try expectConsume(&ring, &buf));
}

test "drop_oldest: a paused displacer refuses producers in bounded steps" {
    // Fix for the paused-displacer spin: a displacer wins the cursor
    // CAS and pauses before its stamp CAS. Other producers' claims
    // must return null in bounded steps — the pre-fix exact-full guard
    // spun them on the pause — and none may claim while the cell is
    // unfreed. When the displacer completes, the claims land.
    const Ring = Mpsc(.{ .on_full = .drop_oldest });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    for (0..4) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("s{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    // The displacer (this thread): win the cursor, then pause.
    const r = ring.readHead();
    const slot = &ring.slots[0];
    const stamp = slot.stamp.load(.acquire);
    try testing.expect(ring.read_head.cmpxchgStrong(r, r + 1, .acq_rel, .monotonic) == null);

    const num_producers = 4;
    var attempted: atomic.Value(u32) = .init(0);
    var claimed_early: atomic.Value(bool) = .init(false);
    var go: atomic.Value(bool) = .init(false);

    const Producer = struct {
        ring: *Ring,
        attempted: *atomic.Value(u32),
        claimed_early: *atomic.Value(bool),
        go: *atomic.Value(bool),
        claimed: bool = false,

        const Self = @This();

        fn run(self: *Self) void {
            // One attempt inside the pause: bounded refusal.
            if (self.ring.acquire() != null) self.claimed_early.store(true, .release);
            _ = self.attempted.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) atomic.spinLoopHint();
            // The pause is over: claim, bounded so a bug fails the test
            // instead of hanging the suite.
            var attempts: usize = 0;
            while (self.ring.acquire() == null) {
                atomic.spinLoopHint();
                attempts += 1;
                if (attempts > 100_000_000) @panic("acquire starved after the pause");
            }
            self.claimed = true;
        }
    };

    var producers: [num_producers]Producer = undefined;
    var threads: [num_producers]Thread = undefined;
    for (&producers, &threads) |*p, *t| {
        p.* = .{
            .ring = &ring,
            .attempted = &attempted,
            .claimed_early = &claimed_early,
            .go = &go,
        };
        t.* = try .spawn(.{}, Producer.run, .{p});
    }

    // Bounded wait for every producer's attempt inside the pause.
    var attempts: usize = 0;
    while (attempted.load(.acquire) < num_producers) {
        atomic.spinLoopHint();
        attempts += 1;
        if (attempts > 100_000_000) return error.ProducersNeverAttempted;
    }
    try testing.expect(!claimed_early.load(.acquire));

    // The displacer completes: the single stamp write and count, then
    // the producers are released. Each claim after the first displaces
    // one older message, so the final count is one plus three.
    const free: u64 = @as(u64, 1) << 32;
    try testing.expect(slot.stamp.cmpxchgStrong(stamp, free, .release, .monotonic) == null);
    _ = ring.displaced.fetchAdd(1, .monotonic);
    go.store(true, .release);

    for (&threads) |*t| t.join();
    for (producers) |p| try testing.expect(p.claimed);
    try testing.expectEqual(4, ring.displacedCount());
}

test "futex waiter blocked behind an uncommitted claim is freed by its commit" {
    // The consumer arms its futex wait behind a claimed-but-uncommitted
    // position. Nothing else is pending, so only the commit's
    // notifyConsumer bump can free it: the data path, not shutdown,
    // wakes a consumer parked behind a mid-write producer.
    const Ring = Mpsc(.{ .wake = .futex });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    // Claim position 0 and hold it: the consumer has nothing to read
    // and must park.
    var lease = try expectAcquire(&ring);

    var received: atomic.Value(u32) = .init(0);

    const Consumer = struct {
        ring: *Ring,
        received: *atomic.Value(u32),

        const Self = @This();

        fn run(self: Self) void {
            var read_pos: u64 = 0;
            while (self.ring.waitForData(read_pos)) {
                const msg = self.ring.read(read_pos).?;
                if (!std.mem.eql(u8, msg.payload, "freed")) @panic("wrong payload");
                _ = self.received.fetchAdd(1, .monotonic);
                msg.release();
                read_pos += 1;
            }
        }
    };

    const consumer: Consumer = .{ .ring = &ring, .received = &received };
    const consumer_thread = try Thread.spawn(.{}, Consumer.run, .{consumer});

    // Bound the arming spin: the commit must find a parked waiter, or
    // the test proves nothing. A consumer that never arms fails the
    // test instead of hanging it.
    var attempts: usize = 0;
    while (ring.hot.wake_state.load(.acquire) & Ring.waiter_bit == 0) {
        atomic.spinLoopHint();
        attempts += 1;
        if (attempts > 100_000_000) return error.ConsumerNeverArmed;
    }

    var w = lease.writer();
    try w.writeAll("freed");
    lease.commit(&ring, @intCast(w.end));
    ring.requestShutdown();
    consumer_thread.join();

    // Exactly the one committed message, read by the woken waiter.
    try testing.expectEqual(1, received.load(.acquire));
}

test "ordered drain recovers after a stalled position commits late" {
    // The stalled test's ending, carried one step further: the head
    // sat at 4 while the stall held, so once the late commit lands and
    // the consumer releases slot 0, the pending claim is granted on
    // lap 1 and the stream is whole again.
    var ring: Mpsc(.{}) = undefined;
    try ring.init(testing.allocator, undefined, 4);
    defer ring.deinit(testing.allocator);

    // Claim position 0 and never commit it.
    var stalled = try expectAcquire(&ring);
    for (0..3) |_| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.writeAll("flow");
        lease.commit(&ring, @intCast(w.end));
    }
    // Positions 1..3 drain; the head parks at 4.
    var read_pos: u64 = 1;
    while (read_pos < ring.head()) : (read_pos += 1) {
        (try expectRead(&ring, read_pos)).release();
    }
    try testing.expectEqual(4, ring.head());
    // While position 0 is uncommitted the ring stays full: slot 0
    // names lap 0 while the head wants lap 1.
    try testing.expect(ring.acquire() == null);

    // The stall clears: position 0 commits, the consumer reads it.
    var w = stalled.writer();
    try w.writeAll("late");
    stalled.commit(&ring, @intCast(w.end));
    try testing.expectEqualStrings("late", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();

    // Slot 0 is free for lap 1: the head's pending claim lands on it
    // and the ring flows again.
    var lease = try expectAcquire(&ring);
    try testing.expectEqual(4, lease.index());
    var w2 = lease.writer();
    try w2.writeAll("resumed");
    lease.commit(&ring, @intCast(w2.end));
    try testing.expectEqualStrings("resumed", ring.read(4).?.payload);
}

test "the futex generation bump breaks a would-be sleep" {
    // Deterministic replay of the shutdown-race class, no scheduler
    // luck required: replay the losing interleaving by hand. The consumer
    // arms the waiter and snapshots the wake word in one RMW; the
    // notify then fires before the consumer can enter Futex.wait, so
    // its wake hits no sleeper. The expected-value check in the wait
    // is what saves it.
    const Ring = Mpsc(.{ .wake = .futex });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    // Consumer side, exactly as waitForData arms it: one RMW.
    const armed = ring.hot.wake_state.fetchOr(Ring.waiter_bit, .acq_rel);
    const expected = armed | Ring.waiter_bit;

    // Notify fires inside the [arm -> Futex.wait] window; the wake
    // hits no sleeper.
    ring.requestShutdown();

    // waitForData's Futex.wait, entered next, cannot block: the word
    // no longer matches the armed snapshot, so the kernel-side
    // comparison fails immediately. The timeout pins that through the
    // real syscall — if a notify ever stops bumping the word the
    // consumer sleeps on, this fails in bounded time instead of
    // hanging.
    const timeout: Io.Timeout = .{
        .duration = .{
            .raw = .fromNanoseconds(std.time.ns_per_s),
            .clock = .awake,
        },
    };
    try testing.io.futexWaitTimeout(
        u32,
        &ring.hot.wake_state.raw,
        expected,
        timeout,
    );
    try testing.expect(ring.isShutdown());
    _ = ring.hot.wake_state.fetchAnd(~Ring.waiter_bit, .release);

    // The data path bumps the same word: a notify with no shutdown
    // also breaks the wait.
    const before = ring.hot.wake_state.load(.acquire);
    ring.notifyConsumer();
    try testing.io.futexWaitTimeout(
        u32,
        &ring.hot.wake_state.raw,
        before,
        timeout,
    );
}

/// Test-only: is the doorbell fd readable right now (zero-timeout poll)?
fn doorbellReadable(fd: linux.fd_t) bool {
    var fds = [1]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    return linux.poll(&fds, 1, 0) != 0;
}

/// Test-only: the doorbell counter right now. One 8-byte read drains
/// it; an empty counter reads EAGAIN and counts as 0.
fn doorbellCount(fd: linux.fd_t) u64 {
    var counter: [8]u8 = undefined;
    const rc = linux.read(fd, &counter, 8);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @bitCast(counter);
}

test "ackDoorbell on an unwoken fd is benign" {
    // A caller may ack the doorbell before any poke: the 8-byte read
    // drains an empty counter and returns EAGAIN, which ackDoorbell
    // swallows. The benign ack must not wedge the doorbell: the fd
    // stays idle and a later poke-commit-drain cycle still works end
    // to end.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    // Nothing poked: the fd is idle, and the early ack drains nothing.
    try testing.expect(!doorbellReadable(ring.pollFd()));
    ring.ackDoorbell();
    try testing.expect(!doorbellReadable(ring.pollFd()));

    // The armed commit pokes the doorbell; the ack drains it; the
    // message still reads by position.
    ring.armDoorbell();
    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("ding");
    lease.commit(&ring, @intCast(w.end));
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.ackDoorbell();
    try testing.expect(!doorbellReadable(ring.pollFd()));
    try testing.expectEqualStrings("ding", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
    ring.disarmDoorbell();
}

test "eventfd: a commit before the arm is found by the post-arm re-check" {
    // The gate's lost-wakeup case, disarmed side: a commit that lands
    // before the consumer arms pokes nothing — no waiter was armed —
    // and the consumer's arm RMW reads the commit's generation bump,
    // so the re-check after the arm sees the data. The wake is
    // best-effort; the ring is the source of truth.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("early");
    lease.commit(&ring, @intCast(w.end));

    // No waiter was armed at the commit: no poke.
    try testing.expect(!doorbellReadable(ring.pollFd()));

    // The arm and the post-arm re-check: the data is found without a
    // doorbell write.
    ring.armDoorbell();
    try testing.expectEqualStrings("early", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
    try testing.expect(!doorbellReadable(ring.pollFd()));
    ring.disarmDoorbell();
}

test "eventfd: a commit inside the arm-to-wait window is poll-readable" {
    // The window the arm closes: the consumer arms, re-checks empty,
    // and a commit lands before it enters the wait. The poke carries
    // the counter past zero, so a zero-timeout poll — the wait's first
    // step — returns readable.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    ring.armDoorbell();
    // The final empty check, after the arm.
    try testing.expect(ring.read(0) == null);

    // The commit lands in the window: it observes the armed bit and
    // pokes.
    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("raced");
    lease.commit(&ring, @intCast(w.end));

    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.disarmDoorbell();

    // Acknowledge the doorbell if it rang, and drain.
    ring.ackDoorbell();
    try testing.expectEqualStrings("raced", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
}

test "eventfd: disarmed commits land in the ring without a poke" {
    // The steady state of a consumer that is not waiting: commits run
    // the gated RMW and write no fd, so a disarmed consumer costs no
    // syscalls. The data is in the ring regardless; the ring is the
    // source of truth.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    for (0..3) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("m{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }
    try testing.expectEqual(0, doorbellCount(ring.pollFd()));

    for (0..3) |i| {
        var expect_buf: [8]u8 = undefined;
        const expect = try std.fmt.bufPrint(&expect_buf, "m{d}", .{i});
        const msg = try expectRead(&ring, i);
        try testing.expectEqualStrings(expect, msg.payload);
        msg.release();
    }
}

test "eventfd: armed commits sum in the counter, one ack drains the burst" {
    // The eventfd counter combines readability, not writes: a burst
    // under an armed consumer leaves the counter at the burst size,
    // and one 8-byte ack drains it. The notification is not one-shot.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    ring.armDoorbell();
    for (0..3) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("m{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }

    // One ack drains all three increments, and the fd goes idle.
    try testing.expectEqual(3, doorbellCount(ring.pollFd()));
    try testing.expect(!doorbellReadable(ring.pollFd()));
    ring.disarmDoorbell();

    // The messages were never at risk: they read by position.
    for (0..3) |i| (try expectRead(&ring, i)).release();
}

test "eventfd: a non-doorbell wake disarms and later commits do not poke" {
    // The scoped pattern disarms on every wake, whatever woke the
    // consumer: a socket or timer wake must disarm too, or the ring
    // stays armed and pays a poke per commit. The disarm is
    // observable: later commits find the bit clear and write nothing.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    // The scoped wait: arm, re-check empty, a simulated non-doorbell
    // wake, disarm.
    ring.armDoorbell();
    try testing.expect(ring.read(0) == null);
    ring.disarmDoorbell();

    for (0..2) |i| {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.print("m{d}", .{i});
        lease.commit(&ring, @intCast(w.end));
    }
    try testing.expect(ring.hot.wake_state.load(.acquire) & Ring.waiter_bit == 0);
    try testing.expect(!doorbellReadable(ring.pollFd()));

    // The data is still in the ring: the re-check finds it.
    try testing.expectEqualStrings("m0", (try expectRead(&ring, 0)).payload);
    (try expectRead(&ring, 0)).release();
    try testing.expectEqualStrings("m1", (try expectRead(&ring, 1)).payload);
    (try expectRead(&ring, 1)).release();
}

test "eventfd: a stale readable doorbell does not wedge the next wait cycle" {
    // A consumer that sees the doorbell readable, acks it, and drains
    // leaves no counter behind: the next arm/re-check/wait cycle
    // starts from an idle fd, and the next armed commit's poke is what
    // makes it readable again.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    // Cycle 1: armed commit, poke, ack, drain.
    {
        ring.armDoorbell();
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.writeAll("first");
        lease.commit(&ring, @intCast(w.end));
        try testing.expect(doorbellReadable(ring.pollFd()));
        ring.disarmDoorbell();
        ring.ackDoorbell();
        const msg = try expectRead(&ring, 0);
        try testing.expectEqualStrings("first", msg.payload);
        msg.release();
    }

    // Cycle 2: the stale readability was drained. The arm finds an
    // idle fd and the wait would park until the next armed commit.
    ring.armDoorbell();
    try testing.expect(ring.read(1) == null);
    try testing.expect(!doorbellReadable(ring.pollFd()));
    {
        var lease = try expectAcquire(&ring);
        var w = lease.writer();
        try w.writeAll("second");
        lease.commit(&ring, @intCast(w.end));
    }
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.disarmDoorbell();
    ring.ackDoorbell();
    const msg = try expectRead(&ring, 1);
    try testing.expectEqualStrings("second", msg.payload);
    msg.release();
}

test "eventfd: the disarmed generation carry arms a phantom waiter" {
    // The 31-bit generation carries into the waiter bit at
    // 0x7fffffff -> 0x80000000. The carrying bump observes no armed
    // bit — no poke — but it leaves the ring phantom-armed, so every
    // later commit pokes until an arm/disarm cycle clears the bit. The
    // wake word is driven directly, the same-file internals the other
    // replay tests use.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    ring.hot.wake_state.store(0x7fff_ffff, .release);

    // The carrying commit: the pre-bump word had no armed bit, so no
    // poke; the post-bump word is phantom-armed.
    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("carry");
    lease.commit(&ring, @intCast(w.end));
    try testing.expect(!doorbellReadable(ring.pollFd()));
    try testing.expect(ring.hot.wake_state.load(.acquire) & Ring.waiter_bit != 0);

    // The phantom costs a poke per commit until a consumer cycle
    // clears it.
    var lease2 = try expectAcquire(&ring);
    var w2 = lease2.writer();
    try w2.writeAll("phantom");
    lease2.commit(&ring, @intCast(w2.end));
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.ackDoorbell();

    // The arm/disarm cycle clears the bit and keeps the generation.
    const before = ring.hot.wake_state.load(.acquire);
    ring.armDoorbell();
    ring.disarmDoorbell();
    const after = ring.hot.wake_state.load(.acquire);
    try testing.expect(after & Ring.waiter_bit == 0);
    try testing.expectEqual(before & ~Ring.waiter_bit, after & ~Ring.waiter_bit);

    // Cleared: later commits do not poke.
    var lease3 = try expectAcquire(&ring);
    var w3 = lease3.writer();
    try w3.writeAll("quiet");
    lease3.commit(&ring, @intCast(w3.end));
    try testing.expect(!doorbellReadable(ring.pollFd()));
}

test "eventfd: an armed generation carry pokes once, then the cleared word skips" {
    // The armed carry at 0xffffffff -> 0: the carrying bump observes
    // the armed bit and pokes — the last wake before the word wraps to
    // generation 0 with no armed bit — and the commits after it find
    // no armed bit and write nothing, until the consumer arms again.
    const Ring = Mpsc(.{ .wake = .eventfd });
    var ring: Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    ring.hot.wake_state.store(0xffff_ffff, .release);

    var lease = try expectAcquire(&ring);
    var w = lease.writer();
    try w.writeAll("last");
    lease.commit(&ring, @intCast(w.end));
    try testing.expect(doorbellReadable(ring.pollFd()));
    try testing.expectEqual(@as(u32, 0), ring.hot.wake_state.load(.acquire));
    ring.ackDoorbell();

    // The word wrapped with no armed bit: later commits skip the poke.
    var lease2 = try expectAcquire(&ring);
    var w2 = lease2.writer();
    try w2.writeAll("quiet");
    lease2.commit(&ring, @intCast(w2.end));
    try testing.expect(!doorbellReadable(ring.pollFd()));

    // The consumer's next cycle works from the wrapped word: the arm
    // sets the bit, a commit pokes, the disarm clears it.
    ring.armDoorbell();
    var lease3 = try expectAcquire(&ring);
    var w3 = lease3.writer();
    try w3.writeAll("again");
    lease3.commit(&ring, @intCast(w3.end));
    try testing.expect(doorbellReadable(ring.pollFd()));
    ring.disarmDoorbell();
    ring.ackDoorbell();
}

test "fuzz slot ring churn vs model: drop_new" {
    // Native fuzzing: a fixed 128-op churn sequence per iteration against
    // a per-position model of a 4-slot ring. The op mix cycles the ring
    // through empty, full, and mid-drain states, and the deliberate fill
    // makes the full-ring refusal common rather than rare.
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var churn: Churn(.drop_new) = .{};
            return churn.run(smith);
        }
    }.run, .{ .corpus = &.{&churn_drop_new} });
}

test "fuzz slot ring churn vs model: drop_oldest" {
    // The same churn under the displacing policy: the model also tracks
    // the ring-owned cursor and the displacement count, so every
    // displacement must drop the committed message at the cursor and
    // advance it by exactly one position.
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var churn: Churn(.drop_oldest) = .{};
            return churn.run(smith);
        }
    }.run, .{ .corpus = &.{&churn_drop_oldest} });
}

test "slot ring threaded chaos hammer: drop_new" {
    // Three seeded producers hammer a 16-slot futex ring while one
    // consumer drains it in order. Every payload carries its producer
    // id, index, committed length, and claim position, so the consumer
    // checks each delivered byte against the producer's own write and
    // the exact position it should have landed at: a torn write or a
    // stale lap is a panic, a refused claim is counted, and nothing else
    // may happen to a message.
    const H = Hammer(.drop_new);
    var ring: H.Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    var refused: atomic.Value(usize) = .init(0);
    var received: usize = 0;
    var seen: [H.num_producers][H.per_producer]bool = @splat(@splat(false));

    const consumer: H.Consumer = .{ .ring = &ring, .seen = &seen, .received = &received };
    const consumer_thread = try Thread.spawn(.{}, H.Consumer.run, .{consumer});

    var producers: [H.num_producers]H.Producer = undefined;
    var threads: [H.num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = i, .refused = &refused };
        t.* = try .spawn(.{}, H.Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    ring.requestShutdown();
    consumer_thread.join();

    // A torn payload, a stale lap, or a duplicate would have panicked in
    // the consumer; here every message must be delivered or counted as
    // refused, and nothing is lost beyond that.
    try testing.expectEqual(H.total, received + refused.load(.monotonic));
}

test "slot ring threaded chaos hammer: drop_oldest" {
    // The same hammer under the displacing policy: the consumer claims
    // the ring-owned cursor per read, and the loss accounting moves to
    // the oldest — every message is delivered, displaced by a later
    // producer, or refused, and the delivered positions must strictly
    // increase because the cursor never rewinds.
    const H = Hammer(.drop_oldest);
    var ring: H.Ring = undefined;
    try ring.init(testing.allocator, testing.io, 16);
    defer ring.deinit(testing.allocator);

    var refused: atomic.Value(usize) = .init(0);
    var received: usize = 0;
    var seen: [H.num_producers][H.per_producer]bool = @splat(@splat(false));

    const consumer: H.Consumer = .{ .ring = &ring, .seen = &seen, .received = &received };
    const consumer_thread = try Thread.spawn(.{}, H.Consumer.run, .{consumer});

    var producers: [H.num_producers]H.Producer = undefined;
    var threads: [H.num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = i, .refused = &refused };
        t.* = try .spawn(.{}, H.Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    ring.requestShutdown();
    consumer_thread.join();

    // A torn payload, a stale lap, a duplicate, or an out-of-order
    // delivery would have panicked in the consumer; here every message
    // must be delivered, displaced, or counted as refused, and nothing
    // is lost beyond that.
    try testing.expectEqual(
        H.total,
        received + ring.displacedCount() + refused.load(.monotonic),
    );
}

test "eventfd: threaded churn with arm/disarm cycles, drop_new" {
    // Three seeded producers against one consumer that uses the scoped
    // armed cycle: arm, re-check the ring, poll only if it is still
    // empty, disarm on the wake, acknowledge, drain. The accounting
    // invariant is the futex hammers' — every message is delivered or
    // counted as refused — and the bounded poll means a lost wake
    // delays the drain but cannot hang the test.
    const H = EventfdHammer(.drop_new);
    var ring: H.Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    var refused: atomic.Value(usize) = .init(0);
    var received: usize = 0;
    var seen: [H.num_producers][H.per_producer]bool = @splat(@splat(false));

    var stop: atomic.Value(bool) = .init(false);
    var consumer: H.Consumer = .{
        .ring = &ring,
        .seen = &seen,
        .received = &received,
        .stop = &stop,
    };
    const consumer_thread = try Thread.spawn(.{}, H.Consumer.run, .{&consumer});

    var producers: [H.num_producers]H.Producer = undefined;
    var threads: [H.num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = i, .refused = &refused };
        t.* = try .spawn(.{}, H.Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    stop.store(true, .release);
    consumer_thread.join();

    // A torn payload, a stale lap, or a duplicate would have panicked
    // in the consumer; every message must be delivered or counted as
    // refused.
    try testing.expectEqual(H.total, received + refused.load(.monotonic));
}

test "eventfd: threaded churn with arm/disarm cycles, drop_oldest" {
    // The same armed cycle under the displacing policy: the consumer
    // claims the ring-owned cursor per read, a displacement pokes only
    // while the consumer is armed, and the loss accounting closes as
    // the futex hammer's does.
    const H = EventfdHammer(.drop_oldest);
    var ring: H.Ring = undefined;
    try ring.init(testing.allocator, undefined, 16);
    defer ring.deinit(testing.allocator);

    var refused: atomic.Value(usize) = .init(0);
    var received: usize = 0;
    var seen: [H.num_producers][H.per_producer]bool = @splat(@splat(false));

    var stop: atomic.Value(bool) = .init(false);
    var consumer: H.Consumer = .{
        .ring = &ring,
        .seen = &seen,
        .received = &received,
        .stop = &stop,
    };
    const consumer_thread = try Thread.spawn(.{}, H.Consumer.run, .{&consumer});

    var producers: [H.num_producers]H.Producer = undefined;
    var threads: [H.num_producers]Thread = undefined;
    for (&producers, &threads, 0..) |*p, *t, i| {
        p.* = .{ .ring = &ring, .id = i, .refused = &refused };
        t.* = try .spawn(.{}, H.Producer.run, .{p.*});
    }
    for (&threads) |*t| t.join();
    stop.store(true, .release);
    consumer_thread.join();

    // A torn payload, a stale lap, a duplicate, or an out-of-order
    // delivery would have panicked in the consumer; every message must
    // be delivered, displaced, or counted as refused.
    try testing.expectEqual(
        H.total,
        received + ring.displacedCount() + refused.load(.monotonic),
    );
}

test {
    testing.refAllDecls(@This());
}
