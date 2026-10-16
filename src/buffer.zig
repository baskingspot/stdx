//! Fixed-capacity append buffers, the `multi_array.{Array, Buffer}` shape:
//! `Array(T, capacity)` embeds its storage, `Slice(T)` borrows the
//! caller's. Same API over both — the append/assume-capacity pairs,
//! `remainingCapacity`, `clear` — with the storage axis as the flavor
//! names.

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
        /// mode, where an `assert` compiles out of ReleaseFast and a
        /// length past capacity becomes a silent out-of-bounds slice.
        pub fn resize(self: *Self, new_len: usize) void {
            if (new_len > self.buffer.len) @panic("buffer.Array.resize past capacity");
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
        /// See `Array`'s `resize` for why the check cannot be an
        /// `assert`.
        pub fn resize(self: *Self, new_len: usize) void {
            if (new_len > self.buffer.len) @panic("buffer.Slice.resize past capacity");
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
}
