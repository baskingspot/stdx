//! A bounded `Io.Writer` backed by a dynamically-allocated buffer with a hard
//! byte ceiling. When a `drain` or `rebase` would push the buffered content
//! past `limit`, the writer returns `error.WriteFailed` instead of growing.
//!
//! This is the bounded counterpart to `std.Io.Writer.Allocating`: same
//! accumulating-writer semantics (flush is a no-op, all buffered content is
//! retained), but the buffer never exceeds `limit` bytes. Useful for
//! serializing unbounded input into a fixed-size output — e.g. building a JSON
//! response from a large result set without risking OOM.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Io = std.Io;
const testing = std.testing;

const BoundedWriter = @This();

allocator: mem.Allocator,
writer: Io.Writer,
limit: usize,

const vtable: Io.Writer.VTable = .{
    .drain = drain,
    .flush = Io.Writer.noopFlush,
    .rebase = rebase,
};

pub fn init(allocator: mem.Allocator, limit: usize) BoundedWriter {
    return .{
        .allocator = allocator,
        .writer = .{ .buffer = &.{}, .vtable = &vtable },
        .limit = limit,
    };
}

pub fn deinit(self: *BoundedWriter) void {
    self.allocator.free(self.writer.buffer);
    self.* = undefined;
}

pub fn written(self: *BoundedWriter) []const u8 {
    return self.writer.buffered();
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const self: *BoundedWriter = @fieldParentPtr("writer", w);
    const gpa = self.allocator;
    const pattern = data[data.len - 1];
    var list: ArrayList(u8) = .{
        .items = w.buffer[0..w.end],
        .capacity = w.buffer.len,
    };
    defer {
        w.buffer = list.allocatedSlice();
        w.end = list.items.len;
    }
    const start_len = list.items.len;
    assert(data.len != 0);

    // Compute the actual number of new bytes this drain will append.
    // All data slices are appended, then the last element (pattern) is
    // repeated `splat - 1` more times (or removed if splat == 0).
    var total_new: usize = 0;
    for (data) |bytes| {
        total_new = math.add(usize, total_new, bytes.len) catch
            return error.WriteFailed;
    }
    if (splat == 0) {
        total_new -= pattern.len; // last element is undone
    } else if (pattern.len > 0) {
        const extra = math.mul(usize, pattern.len, splat - 1) catch
            return error.WriteFailed;
        total_new = math.add(usize, total_new, extra) catch
            return error.WriteFailed;
    }
    // Check limit BEFORE any allocation.
    const projected = math.add(usize, list.items.len, total_new) catch
        return error.WriteFailed;
    if (projected > self.limit) return error.WriteFailed;

    // Ensure capacity for exactly the bytes we need — no over-allocation
    // beyond the limit, so subsequent writes that would exceed the limit
    // are forced through drain (and its limit check) rather than silently
    // fitting in excess capacity.
    list.ensureTotalCapacityPrecise(gpa, projected) catch
        return error.WriteFailed;
    for (data) |bytes| {
        list.appendSliceAssumeCapacity(bytes);
    }
    if (splat == 0) {
        list.items.len -= pattern.len;
    } else switch (pattern.len) {
        0 => {},
        1 => list.appendNTimesAssumeCapacity(pattern[0], splat - 1),
        else => for (0..splat - 1) |_| list.appendSliceAssumeCapacity(pattern),
    }
    return list.items.len - start_len;
}

fn rebase(w: *Io.Writer, preserve: usize, minimum_len: usize) Io.Writer.Error!void {
    _ = preserve;
    const self: *BoundedWriter = @fieldParentPtr("writer", w);
    const gpa = self.allocator;
    // For an accumulating writer (flush is a no-op), all buffered content
    // is preserved — the effective capacity needed is w.end + minimum_len,
    // not preserve + minimum_len.  preserve may be less than w.end when the
    // caller only needs a prefix, but the buffer still holds w.end bytes.
    const total = math.add(usize, w.end, minimum_len) catch
        return error.WriteFailed;
    if (total > self.limit) return error.WriteFailed;
    var list: ArrayList(u8) = .{
        .items = w.buffer[0..w.end],
        .capacity = w.buffer.len,
    };
    defer {
        w.buffer = list.allocatedSlice();
        w.end = list.items.len;
    }
    list.ensureTotalCapacityPrecise(gpa, total) catch return error.WriteFailed;
}

test "writes within limit" {
    var bw: BoundedWriter = .init(testing.allocator, 100);
    defer bw.deinit();
    try bw.writer.writeAll("hello");
    try testing.expectEqualStrings("hello", bw.written());
}

test "rejects at cap-plus-one" {
    const cap: usize = 10;
    var bw: BoundedWriter = .init(testing.allocator, cap);
    defer bw.deinit();
    // Write exactly cap bytes — should succeed.
    try bw.writer.writeAll("0123456789");
    try testing.expectEqual(@as(usize, cap), bw.written().len);
    // One more byte should fail.
    try testing.expectError(error.WriteFailed, bw.writer.writeByte('x'));
}

test "accepts exact cap" {
    const cap: usize = 16;
    var bw: BoundedWriter = .init(testing.allocator, cap);
    defer bw.deinit();
    const data = "0123456789abcdef"; // exactly 16 bytes
    try bw.writer.writeAll(data);
    try testing.expectEqualStrings(data, bw.written());
}

test "rejects large single write" {
    const cap: usize = 64;
    var bw: BoundedWriter = .init(testing.allocator, cap);
    defer bw.deinit();
    // A write larger than the limit should fail.
    const big = "x" ** 128;
    try testing.expectError(error.WriteFailed, bw.writer.writeAll(big));
}
