//! Fixed-capacity buffer backed by an array.
//!
//! Useful for building messages or accumulating bytes without heap allocation.
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;
const Alignment = mem.Alignment;
const crypto = std.crypto;

pub fn ArrayBuffer(comptime T: type, comptime buffer_capacity: comptime_int) type {
    return ArrayBufferAligned(T, .of(T), buffer_capacity);
}

fn ArrayBufferAligned(
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

        pub fn resize(self: *Self, len: Index) void {
            assert(len <= self.buffer.len);
            self.len = len;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Zero the full storage and reset. `std.crypto.secureZero` handles
        /// any element type — 0.16 implements it as `@memset` over a `[]volatile
        /// T` view, so non-scalar elements (a certificate chain of borrowed
        /// DER, say) zero the same way; the volatile qualifier prevents the
        /// dead store from being elided.
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

test ArrayBuffer {
    var buf: ArrayBuffer(u8, 32) = .empty;

    try buf.appendSlice("hello");
    try testing.expectEqualStrings("hello", buf.constSlice());
    try buf.appendSlice(" world");
    try testing.expectEqualStrings("hello world", buf.constSlice());
    buf.appendSliceAssumeCapacity("!");
    try testing.expectEqualStrings("hello world!", buf.constSlice());

    // Overflow is an error for append and appendSlice alike.
    var small: ArrayBuffer(u8, 4) = .empty;
    try small.appendSlice("hi");
    try testing.expectError(error.NoSpaceLeft, small.appendSlice("hello"));
    try testing.expectEqualStrings("hi", small.constSlice());
    try small.append('!');
    try testing.expectEqualStrings("hi!", small.constSlice());
    small.appendAssumeCapacity('?');
    try testing.expectEqualStrings("hi!?", small.constSlice());
    try testing.expectError(error.NoSpaceLeft, small.append('x'));

    // get, set, resize.
    var four: ArrayBuffer(u8, 4) = .empty;
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
    var secure: ArrayBuffer(u8, 8) = .{ .buffer = @splat(0x5a), .len = 0 };
    try secure.appendSlice("secret");
    secure.secureClear();
    try testing.expectEqual(@as(usize, 0), secure.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0x5a, 0x5a }, &secure.buffer);

    // secureZero clears full storage and length.
    var zero: ArrayBuffer(u8, 8) = .empty;
    try zero.appendSlice("secret");
    zero.secureZero();
    try testing.expectEqual(@as(usize, 0), zero.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, &zero.buffer);

    // Non-scalar elements: append, get, set, pop — the whole element-value
    // path, then the secureClear claim above.
    var headers: ArrayBuffer([]const u8, 4) = .empty;
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
