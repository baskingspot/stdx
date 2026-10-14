//! A bounded append-only view over storage the caller owns.
//!
//! Deliberately has no `secureZero`: the bytes belong to the caller, so
//! clearing them is the caller's call, not something a view does to memory
//! it was lent. Zero the backing storage where it is declared, not through
//! the view.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub fn SliceBuffer(comptime T: type) type {
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

        pub fn resize(self: *Self, len: usize) void {
            assert(len <= self.buffer.len);
            self.len = len;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

test SliceBuffer {
    var storage: [8]u8 = undefined;
    var buf: SliceBuffer(u8) = .init(&storage);

    try buf.appendSlice("hello");
    try testing.expectEqualStrings("hello", buf.constSlice());
    try buf.retainFrom(buf.constSlice()[2..]);
    try testing.expectEqualStrings("llo", buf.constSlice());

    // Single-item append, matching ArrayBuffer and std.ArrayList.
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
    var hbuf: SliceBuffer(Header) = .init(&header_storage);
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
