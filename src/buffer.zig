//! Fixed-capacity buffers over caller-owned or embedded storage.
//! `Array(T, capacity)` embeds its storage and `Slice(T)` borrows the
//! caller's; both append and share one API — the append/assume-capacity
//! pairs, `remainingCapacity`, `clear`. `Queue(T)` is the two-cursor form
//! over borrowed storage: elements enter at the tail, leave from the front,
//! and `rebase` compacts.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;
const Alignment = mem.Alignment;
const crypto = std.crypto;

/// Fixed-capacity buffer backed by an array.
///
/// Useful for building messages or accumulating bytes without heap allocation.
pub fn Array(comptime T: type, comptime buffer_capacity: comptime_int) type {
    return ArrayAligned(T, .of(T), buffer_capacity);
}

/// A fixed-capacity `Array` with a caller-chosen alignment: over-
/// aligned SIMD storage, 128-bit types, anything `.of(T)` cannot
/// express from outside the module.
pub fn ArrayAligned(
    comptime T: type,
    comptime alignment: Alignment,
    comptime buffer_capacity: comptime_int,
) type {
    return struct {
        const Self = @This();

        pub const Index = std.math.IntFittingRange(0, buffer_capacity);
        pub const capacity: Index = @intCast(buffer_capacity);

        const align_bytes = alignment.toByteUnits();

        buffer: [capacity]T align(align_bytes),
        len: Index,

        pub const empty: Self = .{ .buffer = undefined, .len = 0 };

        pub fn constSlice(self: *const Self) []align(align_bytes) const T {
            return self.buffer[0..self.len];
        }

        pub fn slice(self: *Self) switch (@TypeOf(&self.buffer)) {
            *align(align_bytes) [capacity]T => []align(align_bytes) T,
            *align(align_bytes) const [capacity]T => []align(align_bytes) const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        pub fn unusedCapacitySlice(self: *Self) []align(align_bytes) T {
            return self.buffer[self.len..];
        }

        pub fn remainingCapacity(self: *const Self) Index {
            return capacity - self.len;
        }

        pub fn append(self: *Self, item: T) error{NoSpaceLeft}!void {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            self.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, items: []const T) error{NoSpaceLeft}!void {
            if (items.len > self.remainingCapacity()) return error.NoSpaceLeft;
            self.appendSliceAssumeCapacity(items);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            assert(items.len <= self.remainingCapacity());
            @memcpy(self.unusedCapacitySlice()[0..items.len], items);
            self.len += @intCast(items.len);
        }

        /// Return the element at index `i` of the slice.
        pub fn get(self: *const Self, i: usize) T {
            return self.constSlice()[i];
        }

        /// Set the value of the element at index `i` of the slice.
        pub fn set(self: *Self, i: usize, item: T) void {
            self.slice()[i] = item;
        }

        /// The last item, removed; null when empty. Matches `std.ArrayList.pop`.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        /// Set the length, e.g. after writing into the raw buffer or
        /// `unusedCapacitySlice()` out of band.
        ///
        /// Takes `usize` so callers never narrow before the check: the
        /// `Index` parameter let `resize(@intCast(n))` trap only where
        /// `@intCast` traps — and in ReleaseFast not even there — and
        /// it caught only values above `Index`'s max, not above
        /// capacity. The panic is the contract: it traps in every
        /// mode. Use `resizeUnchecked` when the caller has proved the
        /// bound.
        pub fn resize(self: *Self, new_len: usize) void {
            if (new_len > self.buffer.len) @panic("buffer.Array.resize past capacity");
            self.resizeUnchecked(new_len);
        }

        /// `resize` without the panic check. Asserts
        /// `new_len <= capacity`, so an overstep is undefined behavior in
        /// ReleaseFast.
        pub fn resizeUnchecked(self: *Self, new_len: usize) void {
            assert(new_len <= self.buffer.len);
            self.len = @intCast(new_len);
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Zero the full storage and reset.
        pub fn secureZero(self: *Self) void {
            crypto.secureZero(T, &self.buffer);
            self.len = 0;
        }

        /// Zero the used span and reset. A full wipe for buffers whose
        /// writes all land below `len` (append, set) and whose every reset
        /// goes through here: nothing past `len` was written since the last
        /// secureClear, so the used span is everything this buffer holds.
        pub fn secureClear(self: *Self) void {
            crypto.secureZero(T, self.slice());
            self.len = 0;
        }
    };
}

test Array {
    var buf: Array(u8, 32) = .empty;

    try buf.appendSlice("hello");
    try testing.expectEqualStrings("hello", buf.constSlice());
    try buf.appendSlice(" world");
    try testing.expectEqualStrings("hello world", buf.constSlice());
    buf.appendSliceAssumeCapacity("!");
    try testing.expectEqualStrings("hello world!", buf.constSlice());

    // Overflow is an error for append and appendSlice alike.
    var small: Array(u8, 4) = .empty;
    try small.appendSlice("hi");
    try testing.expectError(error.NoSpaceLeft, small.appendSlice("hello"));
    try testing.expectEqualStrings("hi", small.constSlice());
    try small.append('!');
    try testing.expectEqualStrings("hi!", small.constSlice());
    small.appendAssumeCapacity('?');
    try testing.expectEqualStrings("hi!?", small.constSlice());
    try testing.expectError(error.NoSpaceLeft, small.append('x'));

    // get, set, resize.
    var four: Array(u8, 4) = .empty;
    try four.appendSlice("abc");
    four.set(1, 'X');
    try testing.expectEqual(@as(u8, 'X'), four.get(1));
    try testing.expectEqualStrings("aXc", four.constSlice());
    four.resize(1);
    try testing.expectEqualStrings("a", four.constSlice());
    try testing.expectEqual(@as(usize, 3), four.remainingCapacity());

    // pop: the last item, null when empty, matching std.ArrayList.pop.
    try testing.expectEqual(@as(?u8, 'a'), four.pop());
    try testing.expect(four.pop() == null);
    try four.append('a');
    try four.append('b');
    try testing.expectEqual(@as(?u8, 'b'), four.pop());
    try testing.expectEqualStrings("a", four.constSlice());
    try testing.expectEqual(@as(?u8, 'a'), four.pop());
    try testing.expect(four.pop() == null);

    // clear resets length.
    try four.append('z');
    four.clear();
    try testing.expectEqual(@as(usize, 0), four.len);
    try testing.expectEqualStrings("", four.constSlice());

    // secureClear zeroes the used span and leaves the tail untouched.
    var secure: Array(u8, 8) = .{ .buffer = @splat(0x5a), .len = 0 };
    try secure.appendSlice("secret");
    secure.secureClear();
    try testing.expectEqual(@as(usize, 0), secure.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0x5a, 0x5a }, &secure.buffer);

    // secureZero clears full storage and length.
    var zero: Array(u8, 8) = .empty;
    try zero.appendSlice("secret");
    zero.secureZero();
    try testing.expectEqual(@as(usize, 0), zero.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &zero.buffer);

    // Non-scalar elements: append, get, set, pop — the whole element-value
    // path, then the secureClear claim above.
    var headers: Array([]const u8, 4) = .empty;
    try headers.append("aa");
    try headers.appendSlice(&.{ "bb", "cc" });
    try testing.expectEqual(@as(usize, 3), headers.len);
    try testing.expectEqualStrings("bb", headers.get(1));
    headers.set(2, "cc!");
    try testing.expectEqualStrings("cc!", headers.get(2));
    try testing.expectEqualStrings("cc!", headers.pop().?);
    try testing.expectEqual(@as(usize, 2), headers.len);
    headers.secureClear();
    try testing.expectEqual(@as(usize, 0), headers.len);
    try testing.expectEqual(@as(usize, 0), headers.buffer[0].len);
}

/// A bounded append-only view over storage the caller owns.
pub fn Slice(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        len: usize,

        pub const empty: Self = .{ .buffer = &.{}, .len = 0 };

        pub fn init(buffer: []T) Self {
            return .{ .buffer = buffer, .len = 0 };
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn unusedCapacitySlice(self: *Self) []T {
            return self.buffer[self.len..];
        }

        pub fn remainingCapacity(self: *const Self) usize {
            return self.buffer.len - self.len;
        }

        pub fn append(self: *Self, item: T) error{NoSpaceLeft}!void {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            self.appendAssumeCapacity(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            assert(self.remainingCapacity() > 0);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, items: []const T) error{NoSpaceLeft}!void {
            if (items.len > self.remainingCapacity()) return error.NoSpaceLeft;
            self.appendSliceAssumeCapacity(items);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            assert(items.len <= self.remainingCapacity());
            @memcpy(self.unusedCapacitySlice()[0..items.len], items);
            self.len += items.len;
        }

        pub fn retainFrom(self: *Self, items: []const T) error{NoSpaceLeft}!void {
            if (items.len > self.buffer.len) return error.NoSpaceLeft;
            self.retainFromAssumeCapacity(items);
        }

        /// `retainFrom` without the error return. Asserts
        /// `items.len <= capacity`.
        pub fn retainFromAssumeCapacity(self: *Self, items: []const T) void {
            assert(items.len <= self.buffer.len);
            @memmove(self.buffer[0..items.len], items);
            self.len = items.len;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buffer[self.len];
        }

        /// Set the length, e.g. after writing into the raw buffer out
        /// of band. The panic is the contract: it traps in every mode.
        /// See `Array`'s `resize`. Use `resizeUnchecked` when the caller
        /// has proved the bound.
        pub fn resize(self: *Self, new_len: usize) void {
            if (new_len > self.buffer.len) @panic("buffer.Slice.resize past capacity");
            self.resizeUnchecked(new_len);
        }

        /// `resize` without the panic check. Asserts
        /// `new_len <= capacity`, so an overstep is undefined behavior in
        /// ReleaseFast.
        pub fn resizeUnchecked(self: *Self, new_len: usize) void {
            assert(new_len <= self.buffer.len);
            self.len = @intCast(new_len);
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

test Slice {
    var storage: [8]u8 = undefined;
    var buf: Slice(u8) = .init(&storage);

    try buf.appendSlice("hello");
    try testing.expectEqualStrings("hello", buf.constSlice());
    try buf.retainFrom(buf.constSlice()[2..]);
    try testing.expectEqualStrings("llo", buf.constSlice());

    // Single-item append, matching Array and std.ArrayList.
    try buf.append('!');
    try testing.expectEqualStrings("llo!", buf.constSlice());
    buf.appendAssumeCapacity('?');
    try testing.expectEqualStrings("llo!?", buf.constSlice());

    // pop: the last item, null when empty, matching std.ArrayList.pop.
    try testing.expectEqual(@as(?u8, '?'), buf.pop());
    try testing.expectEqualStrings("llo!", buf.constSlice());
    buf.clear();
    try testing.expect(buf.pop() == null);

    // resize within the backing storage; capacity math stays honest.
    buf.resize(2);
    try testing.expectEqualStrings("ll", buf.constSlice());
    try testing.expectEqual(@as(usize, 6), buf.remainingCapacity());
    buf.resize(buf.buffer.len);
    try testing.expectEqual(@as(usize, 0), buf.remainingCapacity());

    // Overflow is an error for append, appendSlice, and retainFrom alike.
    try testing.expectError(error.NoSpaceLeft, buf.append('x'));
    try testing.expectError(error.NoSpaceLeft, buf.appendSlice("0123456789"));
    try testing.expectError(error.NoSpaceLeft, buf.retainFrom("012345678"));

    // Non-scalar elements: the whole element-value path, no element
    // arithmetic anywhere.
    const Header = struct { a: u32, b: []const u8 };
    var header_storage: [4]Header = undefined;
    var hbuf: Slice(Header) = .init(&header_storage);
    try hbuf.append(.{ .a = 1, .b = "one" });
    try hbuf.appendSlice(&.{ .{ .a = 2, .b = "two" }, .{ .a = 3, .b = "three" } });
    try testing.expectEqual(@as(usize, 3), hbuf.len);
    try testing.expectEqual(@as(u32, 2), hbuf.slice()[1].a);
    try testing.expectEqual(@as(u32, 3), hbuf.pop().?.a);
    try hbuf.retainFrom(hbuf.constSlice()[1..]);
    try testing.expectEqual(@as(u32, 2), hbuf.slice()[0].a);
    var five: [5]Header = undefined;
    for (&five) |*h| h.* = .{ .a = 0, .b = "" };
    try testing.expectError(error.NoSpaceLeft, hbuf.appendSlice(&five));

    // The unchecked pair skips the error path after the caller checks.
    var un: Slice(u8) = .init(&storage);
    try un.appendSlice("abc");
    un.retainFromAssumeCapacity(un.constSlice()[1..]);
    try testing.expectEqualStrings("bc", un.constSlice());
    un.resizeUnchecked(1);
    try testing.expectEqualStrings("b", un.constSlice());
}

/// A first-in first-out queue over caller-owned storage.
///
/// Elements enter at the tail and leave from the front. `unusedCapacitySlice`
/// is the free tail: write into it, then pass the count to `advance`.
/// `buffered` is the unconsumed front: read it, then pass the count to
/// `toss`. `rebase` moves the unconsumed elements to the front and is the
/// only method that moves them.
///
/// The names follow `std.Io.Reader` (`buffered`, `bufferedLen`, `toss`,
/// `peek`, `take`, `rebase`) and `std.Io.Writer` (`unusedCapacitySlice`,
/// `unusedCapacityLen`, `advance`). A queue has no source to refill from, so
/// `peek` and `take` panic on a short buffer instead of returning an error,
/// and `rebase` takes no capacity hint: the whole backing is the target.
///
/// Every bounds-checked cursor operation has an `Unchecked` form. It asserts
/// the same bound instead of panicking, so the check remains in Debug and
/// ReleaseSafe and compiles out in ReleaseFast, where an overstep is
/// undefined behavior.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The full storage. `seek <= end <= buffer.len` at all times.
        buffer: []T,
        /// The first unconsumed element.
        seek: usize,
        /// One past the last written element.
        end: usize,

        pub const empty: Self = .{ .buffer = &.{}, .seek = 0, .end = 0 };

        /// Use `buffer` as the whole capacity. The queue starts empty.
        pub fn init(buffer: []T) Self {
            return .{ .buffer = buffer, .seek = 0, .end = 0 };
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// True when nothing is buffered. Same as `bufferedLen() == 0`.
        pub fn isEmpty(self: *const Self) bool {
            return self.seek == self.end;
        }

        /// The unconsumed elements, contiguous. Invalidated by `rebase`.
        pub fn buffered(self: *Self) []T {
            return self.buffer[self.seek..self.end];
        }

        /// The const form of `buffered`.
        pub fn constBuffered(self: *const Self) []const T {
            return self.buffer[self.seek..self.end];
        }

        pub fn bufferedLen(self: *const Self) usize {
            return self.end - self.seek;
        }

        /// The free tail. Write into this slice, then call `advance`.
        pub fn unusedCapacitySlice(self: *Self) []T {
            return self.buffer[self.end..];
        }

        pub fn unusedCapacityLen(self: *const Self) usize {
            return self.buffer.len - self.end;
        }

        /// Commit `n` elements written into `unusedCapacitySlice`.
        ///
        /// Panics when `n` exceeds the free tail. The check panics in every
        /// build mode: a cursor past the storage is a slice panic later, or
        /// an out-of-bounds write in ReleaseFast. Use `advanceUnchecked`
        /// when the caller has already proved the bound.
        pub fn advance(self: *Self, n: usize) void {
            if (n > self.buffer.len - self.end) {
                @panic("buffer.Queue.advance past unused capacity");
            }
            self.advanceUnchecked(n);
        }

        /// `advance` without the panic check. Asserts
        /// `n <= unusedCapacityLen()`.
        pub fn advanceUnchecked(self: *Self, n: usize) void {
            assert(n <= self.buffer.len - self.end);
            self.end += n;
        }

        /// Drop `n` elements from the front.
        ///
        /// Panics when `n` exceeds `bufferedLen`. Use `tossUnchecked` when
        /// the caller has already proved the bound.
        pub fn toss(self: *Self, n: usize) void {
            if (n > self.end - self.seek) {
                @panic("buffer.Queue.toss past buffered end");
            }
            self.tossUnchecked(n);
        }

        /// `toss` without the panic check. Asserts `n <= bufferedLen()`.
        pub fn tossUnchecked(self: *Self, n: usize) void {
            assert(n <= self.end - self.seek);
            self.seek += n;
        }

        /// Drop every unconsumed element. The tail stays where it is; call
        /// `rebase` to make the whole backing writable again.
        pub fn tossBuffered(self: *Self) void {
            self.seek = self.end;
        }

        /// The next `n` unconsumed elements, without dropping them.
        ///
        /// Panics when fewer than `n` are buffered. Check `bufferedLen` first
        /// when the length comes from the input. Use `peekUnchecked` when the
        /// caller has already proved the bound.
        pub fn peek(self: *Self, n: usize) []T {
            if (n > self.end - self.seek) {
                @panic("buffer.Queue.peek past buffered end");
            }
            return self.peekUnchecked(n);
        }

        /// `peek` without the panic check. Asserts `n <= bufferedLen()`.
        pub fn peekUnchecked(self: *Self, n: usize) []T {
            assert(n <= self.end - self.seek);
            return self.buffer[self.seek..][0..n];
        }

        /// The next `n` unconsumed elements, and drop them.
        ///
        /// Panics when fewer than `n` are buffered. The returned slice is
        /// invalidated by the next `rebase`. Use `takeUnchecked` when the
        /// caller has already proved the bound.
        pub fn take(self: *Self, n: usize) []T {
            if (n > self.end - self.seek) {
                @panic("buffer.Queue.take past buffered end");
            }
            return self.takeUnchecked(n);
        }

        /// `take` without the panic check. Asserts `n <= bufferedLen()`.
        pub fn takeUnchecked(self: *Self, n: usize) []T {
            const result = self.peekUnchecked(n);
            self.seek += n;
            return result;
        }

        /// Move the unconsumed elements to the front of the backing.
        ///
        /// Invalidates every slice returned by `buffered`, `constBuffered`,
        /// `peek`, and `take`; the move is a `@memmove`, so those slices can
        /// overlap the destination. The whole backing is the target, so this
        /// needs no capacity argument. A no-op when `seek` is already zero.
        pub fn rebase(self: *Self) void {
            if (self.seek > self.end or self.end > self.buffer.len) {
                @panic("buffer.Queue.rebase with corrupt cursors");
            }
            if (self.seek == 0) return;
            const buffered_len = self.end - self.seek;
            @memmove(self.buffer[0..buffered_len], self.buffer[self.seek..self.end]);
            self.seek = 0;
            self.end = buffered_len;
        }

        /// Reset both cursors. The backing bytes stay.
        pub fn clear(self: *Self) void {
            self.seek = 0;
            self.end = 0;
        }

        /// The full backing, cursors ignored. Use it to hand raw storage to a
        /// subsystem that keeps its own offsets.
        pub fn backingSlice(self: *Self) []T {
            return self.buffer;
        }

        /// The const form of `backingSlice`.
        pub fn constBackingSlice(self: *const Self) []const T {
            return self.buffer;
        }

        /// Zero the whole backing and reset both cursors.
        ///
        /// The whole backing, not the buffered span: consumed elements remain
        /// before `seek`, and `rebase` leaves a stale copy of the unconsumed
        /// elements in the range it moved from. Use this before releasing
        /// storage that held secrets.
        pub fn secureZero(self: *Self) void {
            crypto.secureZero(T, self.buffer);
            self.clear();
        }
    };
}

test Queue {
    var storage: [8]u8 = undefined;
    var queue: Queue(u8) = .init(&storage);

    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 8), queue.capacity());
    try testing.expectEqual(@as(usize, 8), queue.unusedCapacityLen());
    try testing.expectEqual(@as(usize, 0), queue.bufferedLen());

    // The write side: fill the free tail, then commit the count.
    @memcpy(queue.unusedCapacitySlice()[0..3], "abc");
    queue.advance(3);
    try testing.expectEqualStrings("abc", queue.buffered());
    try testing.expectEqual(@as(usize, 5), queue.unusedCapacityLen());

    // A zero-length commit leaves the front alone.
    queue.advance(0);
    try testing.expectEqualStrings("abc", queue.buffered());

    // peek does not move the front; take does.
    try testing.expectEqualStrings("ab", queue.peek(2));
    try testing.expectEqual(@as(usize, 3), queue.bufferedLen());
    try testing.expectEqualStrings("ab", queue.take(2));
    try testing.expectEqualStrings("c", queue.buffered());

    // toss drops what the caller has read. The tail does not move.
    queue.toss(1);
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 5), queue.unusedCapacityLen());

    // rebase reclaims the consumed front.
    queue.rebase();
    try testing.expectEqual(@as(usize, 8), queue.unusedCapacityLen());

    // Overlapping rebase: consume a prefix, then move the rest to the front.
    @memcpy(queue.unusedCapacitySlice(), "abcdefgh");
    queue.advance(8);
    queue.toss(3);
    try testing.expectEqualStrings("defgh", queue.buffered());
    queue.rebase();
    try testing.expectEqualStrings("defgh", queue.buffered());
    try testing.expectEqual(@as(usize, 3), queue.unusedCapacityLen());
    @memcpy(queue.unusedCapacitySlice(), "ijk");
    queue.advance(3);
    try testing.expectEqualStrings("defghijk", queue.buffered());

    // tossBuffered drops everything but leaves the tail where it is;
    // rebase returns the whole backing.
    queue.tossBuffered();
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 0), queue.unusedCapacityLen());
    queue.rebase();
    try testing.expectEqual(@as(usize, 8), queue.unusedCapacityLen());

    // clear resets both cursors without a move.
    @memcpy(queue.unusedCapacitySlice()[0..2], "xy");
    queue.advance(2);
    queue.toss(1);
    queue.clear();
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 8), queue.unusedCapacityLen());

    // A const queue exposes the same elements through a const slice.
    @memcpy(queue.unusedCapacitySlice()[0..1], "z");
    queue.advance(1);
    const const_queue: *const Queue(u8) = &queue;
    try testing.expectEqualStrings("z", const_queue.constBuffered());
    try testing.expectEqual(@as(usize, 1), const_queue.bufferedLen());
    try testing.expectEqual(@as(usize, 8), const_queue.capacity());

    // secureZero wipes the whole backing, including the stale copy that
    // rebase leaves past the new end.
    queue.clear();
    @memcpy(queue.unusedCapacitySlice()[0..6], "secret");
    queue.advance(6);
    queue.toss(3);
    queue.rebase();
    try testing.expectEqualStrings("ret", queue.buffered());
    queue.secureZero();
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 8), queue.unusedCapacityLen());
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &storage);

    // Non-scalar elements: the cursor math is in elements, not bytes.
    const Pair = struct { key: u32, value: u8 };
    var pair_storage: [2]Pair = undefined;
    var pairs: Queue(Pair) = .init(&pair_storage);
    pairs.unusedCapacitySlice()[0] = .{ .key = 1, .value = 2 };
    pairs.unusedCapacitySlice()[1] = .{ .key = 3, .value = 4 };
    pairs.advance(2);
    try testing.expectEqual(@as(u32, 1), pairs.peek(1)[0].key);
    try testing.expectEqual(@as(u32, 3), pairs.peek(2)[1].key);
    try testing.expectEqual(@as(u8, 4), pairs.take(2)[1].value);
    pairs.rebase();
    try testing.expect(pairs.isEmpty());

    // The unchecked forms assert the same bound and skip the panic path.
    var unchecked_storage: [4]u8 = undefined;
    var unchecked: Queue(u8) = .init(&unchecked_storage);
    @memcpy(unchecked.unusedCapacitySlice()[0..2], "ab");
    unchecked.advanceUnchecked(2);
    try testing.expectEqualStrings("a", unchecked.peekUnchecked(1));
    try testing.expectEqualStrings("a", unchecked.takeUnchecked(1));
    unchecked.tossUnchecked(1);
    try testing.expect(unchecked.isEmpty());

    // The empty value has no storage and every length is zero.
    const empty: Queue(u8) = .empty;
    try testing.expect(empty.isEmpty());
    try testing.expectEqual(@as(usize, 0), empty.capacity());
    try testing.expectEqual(@as(usize, 0), empty.unusedCapacityLen());
    try testing.expectEqual(@as(usize, 0), empty.constBackingSlice().len);
}

test "Queue: random operations match a model" {
    const gpa = testing.allocator;
    var storage: [32]u8 = undefined;
    var queue: Queue(u8) = .init(&storage);
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);

    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();

    for (0..1000) |_| {
        switch (random.uintLessThan(u8, 4)) {
            0 => {
                const n = random.intRangeAtMost(usize, 0, @min(queue.unusedCapacityLen(), 7));
                const tail = queue.unusedCapacitySlice()[0..n];
                for (tail) |*b| b.* = random.int(u8);
                try model.appendSlice(gpa, tail);
                queue.advance(n);
            },
            1 => {
                const n = random.intRangeAtMost(usize, 0, @min(queue.bufferedLen(), 7));
                queue.toss(n);
                @memmove(model.items[0 .. model.items.len - n], model.items[n..]);
                model.items.len -= n;
            },
            2 => queue.rebase(),
            else => {
                queue.tossBuffered();
                model.clearRetainingCapacity();
            },
        }
        try testing.expectEqualSlices(u8, model.items, queue.buffered());
        try testing.expectEqual(model.items.len, queue.bufferedLen());
    }
}
