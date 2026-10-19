//! Forward-only encoding and decoding of caller-owned bytes, with the byte
//! order fixed at comptime.
//!
//! `Writer(.big)` and `Writer(.little)` write fixed-width integers and enums
//! in the chosen order, byte slices, and reserved slots. A reserved slot is the
//! reason this exists as a type: a length prefix, checksum, or tag is often
//! known only after the body, and `reserve` hands back the bytes to fill later.
//!
//! `Reader(.big)` and `Reader(.little)` are the inverse. They read the same
//! widths and hand back zero-copy slices of the bytes they were given.
//!
//! Every fallible method has an unchecked form. The checked form returns an
//! error; the unchecked form asserts the same bound, so it panics in Debug and
//! ReleaseSafe and compiles out in ReleaseFast, where an overstep writes or
//! reads out of bounds. A parser that has checked the total length once uses
//! the unchecked forms so it does not branch on every field.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const writeInt = std.mem.writeInt;
const readInt = std.mem.readInt;

/// A forward-only writer of big- or little-endian values into caller-owned
/// bytes.
///
/// The byte order is a comptime parameter, so `Writer(.big)` and
/// `Writer(.little)` are different types and each fixed-width store compiles
/// to its own code. The byte slices and reserved slots are order-agnostic.
pub fn Writer(comptime endian: std.builtin.Endian) type {
    return struct {
        const Self = @This();

        /// The byte order this writer uses.
        pub const byte_order = endian;

        /// The full storage.
        buffer: []u8,
        /// One past the last written byte.
        end: usize,

        /// A writer over no storage. Only zero-length writes fit.
        pub const empty: Self = .{ .buffer = &.{}, .end = 0 };

        /// Use `buffer` as the whole capacity. The writer starts empty.
        pub fn init(buffer: []u8) Self {
            return .{ .buffer = buffer, .end = 0 };
        }

        /// The whole storage length.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// The bytes written so far, mutable for in-place work such as
        /// encryption.
        pub fn buffered(self: *Self) []u8 {
            return self.buffer[0..self.end];
        }

        /// The const form of `buffered`.
        pub fn constBuffered(self: *const Self) []const u8 {
            return self.buffer[0..self.end];
        }

        /// The free tail. Write into this slice, then call `advance`. The slice
        /// is only valid until the next append or advance.
        pub fn unusedCapacitySlice(self: *Self) []u8 {
            return self.buffer[self.end..];
        }

        /// The number of free bytes.
        pub fn unusedCapacityLen(self: *const Self) usize {
            return self.buffer.len - self.end;
        }

        /// Reset the write cursor. The written bytes stay in the backing.
        pub fn clear(self: *Self) void {
            self.end = 0;
        }

        /// Commit `n` bytes written into `unusedCapacitySlice`. Returns
        /// `error.NoSpaceLeft` when `n` exceeds the free tail.
        pub fn advance(self: *Self, n: usize) error{NoSpaceLeft}!void {
            if (n > self.unusedCapacityLen()) return error.NoSpaceLeft;
            self.advanceAssumeCapacity(n);
        }

        /// `advance` without the error return. Asserts
        /// `n <= unusedCapacityLen()`.
        pub fn advanceAssumeCapacity(self: *Self, n: usize) void {
            assert(n <= self.buffer.len - self.end);
            self.end += n;
        }

        /// Append an integer or enum in the writer's byte order.
        ///
        /// Integers of any byte width work, including `u24`, `u48`, `u128`,
        /// and the signed types. An enum is written as its backing integer.
        /// Returns `error.NoSpaceLeft` when the value does not fit.
        pub fn append(self: *Self, comptime T: type, value: T) error{NoSpaceLeft}!void {
            if (wireSize(T) > self.unusedCapacityLen()) {
                return error.NoSpaceLeft;
            }
            self.appendAssumeCapacity(T, value);
        }

        /// `append` without the error return. Asserts the value fits.
        pub fn appendAssumeCapacity(self: *Self, comptime T: type, value: T) void {
            switch (@typeInfo(T)) {
                .int => {
                    const n = comptime wireSize(T);
                    assert(n <= self.buffer.len - self.end);
                    writeInt(T, self.destination(n), value, endian);
                    self.end += n;
                },
                .@"enum" => |info| self.appendAssumeCapacity(info.tag_type, @intFromEnum(value)),
                else => @compileError("wire.Writer.append: unsupported type " ++ @typeName(T)),
            }
        }

        /// Append a byte slice. Returns `error.NoSpaceLeft` when it does not
        /// fit.
        pub fn appendSlice(self: *Self, bytes: []const u8) error{NoSpaceLeft}!void {
            if (bytes.len > self.unusedCapacityLen()) return error.NoSpaceLeft;
            self.appendSliceAssumeCapacity(bytes);
        }

        /// `appendSlice` without the error return. Asserts the slice fits.
        pub fn appendSliceAssumeCapacity(self: *Self, bytes: []const u8) void {
            assert(bytes.len <= self.buffer.len - self.end);
            @memcpy(self.buffer[self.end..][0..bytes.len], bytes);
            self.end += bytes.len;
        }

        /// Reserve `n` bytes and return them. The caller fills the slot later,
        /// for a length prefix, checksum, or tag that is not known until the
        /// body is written. Returns `error.NoSpaceLeft` when the slot does not
        /// fit.
        pub fn reserve(self: *Self, comptime n: usize) error{NoSpaceLeft}!*[n]u8 {
            if (n > self.unusedCapacityLen()) return error.NoSpaceLeft;
            return self.reserveAssumeCapacity(n);
        }

        /// `reserve` without the error return. Asserts the slot fits.
        pub fn reserveAssumeCapacity(self: *Self, comptime n: usize) *[n]u8 {
            assert(n <= self.buffer.len - self.end);
            const slot = self.destination(n);
            self.end += n;
            return slot;
        }

        fn destination(self: *Self, comptime n: usize) *[n]u8 {
            return @ptrCast(self.buffer.ptr + self.end);
        }

        fn wireSize(comptime T: type) comptime_int {
            return switch (@typeInfo(T)) {
                .int => @divExact(@bitSizeOf(T), 8),
                .@"enum" => |info| wireSize(info.tag_type),
                else => @compileError("wire.Writer: unsupported type " ++ @typeName(T)),
            };
        }
    };
}

/// A forward-only reader of big- or little-endian values from caller-owned
/// bytes.
///
/// The byte order is a comptime parameter, so `Reader(.big)` and
/// `Reader(.little)` are different types and each fixed-width load compiles to
/// its own code. The byte slices and skips are order-agnostic.
///
/// The `read`, `readSlice`, and `skip` forms return `error.UnexpectedEof` when
/// the request exceeds the unread bytes. The `assume` forms assert the same
/// bound instead. Bounds are checked as `n > remaining().len`, never
/// `end + n`, which would wrap in ReleaseFast.
pub fn Reader(comptime endian: std.builtin.Endian) type {
    return struct {
        const Self = @This();

        /// The byte order this reader uses.
        pub const byte_order = endian;

        /// The full storage.
        buffer: []const u8,
        /// One past the last read byte. A caller that tracks offsets may read
        /// the field, and a caller that backtracks may assign it, such as a
        /// framer that restores the start of a partial message. Prefer
        /// `consumed` and `remaining` for the slices.
        end: usize,

        /// A reader over no storage. Only zero-length reads fit.
        pub const empty: Self = .{ .buffer = &.{}, .end = 0 };

        /// Use `buffer` as the whole storage. The reader starts empty.
        pub fn init(buffer: []const u8) Self {
            return .{ .buffer = buffer, .end = 0 };
        }

        /// The whole storage length.
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// The bytes read so far.
        pub fn consumed(self: *const Self) []const u8 {
            return self.buffer[0..self.end];
        }

        /// The unread bytes.
        pub fn remaining(self: *const Self) []const u8 {
            return self.buffer[self.end..];
        }

        /// Read an integer or enum in the reader's byte order. Returns
        /// `error.UnexpectedEof` when the value does not fit.
        ///
        /// Integers of any byte width work, including `u24`, `u48`, `u128`,
        /// and the signed types. An enum is read as its backing integer. Only
        /// non-exhaustive enums are allowed: an unknown tag is representable,
        /// so validation stays with the caller instead of a panic here.
        pub fn read(self: *Self, comptime T: type) error{UnexpectedEof}!T {
            if (wireSize(T) > self.remaining().len) return error.UnexpectedEof;
            return self.assumeRead(T);
        }

        /// `read` without the error return. Asserts the value fits.
        pub fn assumeRead(self: *Self, comptime T: type) T {
            switch (@typeInfo(T)) {
                .int => {
                    const n = comptime wireSize(T);
                    assert(n <= self.remaining().len);
                    const value = readInt(T, self.destination(n), endian);
                    self.end += n;
                    return value;
                },
                .@"enum" => |info| {
                    if (info.is_exhaustive) @compileError(
                        "wire.Reader: enum " ++ @typeName(T) ++ " must be non-exhaustive, " ++
                            "so the caller validates an unknown tag",
                    );
                    return @enumFromInt(self.assumeRead(info.tag_type));
                },
                else => @compileError("wire.Reader: unsupported type " ++ @typeName(T)),
            }
        }

        /// Read `n` bytes as a zero-copy slice. Returns
        /// `error.UnexpectedEof` when the slice does not fit.
        pub fn readSlice(self: *Self, n: usize) error{UnexpectedEof}![]const u8 {
            if (n > self.remaining().len) return error.UnexpectedEof;
            return self.assumeReadSlice(n);
        }

        /// `readSlice` without the error return. Asserts the slice fits.
        pub fn assumeReadSlice(self: *Self, n: usize) []const u8 {
            assert(n <= self.remaining().len);
            const bytes = self.buffer[self.end..][0..n];
            self.end += n;
            return bytes;
        }

        /// Skip `n` bytes. Returns `error.UnexpectedEof` when the skip does not
        /// fit.
        pub fn skip(self: *Self, n: usize) error{UnexpectedEof}!void {
            if (n > self.remaining().len) return error.UnexpectedEof;
            self.assumeSkip(n);
        }

        /// `skip` without the error return. Asserts the skip fits.
        pub fn assumeSkip(self: *Self, n: usize) void {
            assert(n <= self.remaining().len);
            self.end += n;
        }

        fn destination(self: *Self, comptime n: usize) *const [n]u8 {
            return @ptrCast(self.buffer.ptr + self.end);
        }

        fn wireSize(comptime T: type) comptime_int {
            return switch (@typeInfo(T)) {
                .int => @divExact(@bitSizeOf(T), 8),
                .@"enum" => |info| wireSize(info.tag_type),
                else => @compileError("wire.Reader: unsupported type " ++ @typeName(T)),
            };
        }
    };
}

test Writer {
    const Big = Writer(.big);
    const Little = Writer(.little);

    try testing.expectEqual(std.builtin.Endian.big, Big.byte_order);
    try testing.expectEqual(std.builtin.Endian.little, Little.byte_order);

    var storage: [64]u8 = undefined;
    var writer: Big = .init(&storage);

    try testing.expectEqual(@as(usize, 64), writer.capacity());
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try testing.expectEqual(@as(usize, 64), writer.unusedCapacityLen());

    // Every width is big-endian, including the odd byte widths.
    try writer.append(u8, 0xab);
    try writer.append(u16, 0x0102);
    try writer.append(u24, 0x030405);
    try writer.append(u32, 0x06070809);
    try writer.append(u48, 0x0a0b0c0d0e0f);
    try writer.append(u64, 0x1011121314151617);
    try writer.append(u128, 0x18191a1b1c1d1e1f2021222324252627);
    try testing.expectEqualSlices(u8, &.{
        0xab,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0a,
        0x0b,
        0x0c,
        0x0d,
        0x0e,
        0x0f,
        0x10,
        0x11,
        0x12,
        0x13,
        0x14,
        0x15,
        0x16,
        0x17,
        0x18,
        0x19,
        0x1a,
        0x1b,
        0x1c,
        0x1d,
        0x1e,
        0x1f,
        0x20,
        0x21,
        0x22,
        0x23,
        0x24,
        0x25,
        0x26,
        0x27,
    }, writer.buffered());

    // Signed integers are two's complement.
    try writer.append(i16, -2);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, writer.buffered()[40..42]);

    // An enum is its backing integer.
    const Kind = enum(u16) { data = 0x0102, _ };
    try writer.append(Kind, .data);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, writer.buffered()[42..44]);

    // Slices append verbatim.
    try writer.appendSlice("ok");
    try testing.expectEqualStrings("ok", writer.buffered()[44..46]);

    // The little-endian type reverses each fixed-width value.
    var le_storage: [8]u8 = undefined;
    var le: Little = .init(&le_storage);
    try le.append(u16, 0x0102);
    try le.append(u24, 0x030405);
    try le.append(i16, -2);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x01, 0x05, 0x04, 0x03, 0xfe, 0xff },
        le.buffered(),
    );

    // A reserved slot is filled in place after the body.
    var framed_storage: [8]u8 = undefined;
    var framed: Big = .init(&framed_storage);
    const len_slot = try framed.reserve(2);
    try framed.appendSlice("body");
    writeInt(u16, len_slot, @intCast(framed.buffered().len - 2), .big);
    try testing.expectEqualSlices(u8, "\x00\x04body", framed.buffered());

    // The unchecked forms take the same path once the bound holds.
    framed.clear();
    const tail = framed.unusedCapacitySlice()[0..2];
    tail[0] = 0xaa;
    tail[1] = 0xbb;
    framed.advanceAssumeCapacity(2);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, framed.buffered());
    framed.clear();
    framed.appendAssumeCapacity(u8, 0x01);
    const slot = framed.reserveAssumeCapacity(1);
    slot.* = .{0x02};
    framed.appendSliceAssumeCapacity("x");
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 'x' }, framed.buffered());

    // clear resets the cursor without touching the bytes.
    framed.clear();
    try testing.expectEqual(@as(usize, 0), framed.buffered().len);
    try testing.expectEqual(@as(usize, 8), framed.unusedCapacityLen());
    try testing.expectEqual(@as(u8, 0x01), framed_storage[0]);

    // The const view.
    const const_writer: *const Big = &framed;
    try testing.expectEqual(@as(usize, 0), const_writer.constBuffered().len);

    // Boundary: exactly full succeeds, one more fails every checked form.
    var small_storage: [2]u8 = undefined;
    var small: Big = .init(&small_storage);
    try small.append(u16, 0xabcd);
    try testing.expectError(error.NoSpaceLeft, small.append(u8, 0));
    try testing.expectError(error.NoSpaceLeft, small.appendSlice("x"));
    try testing.expectError(error.NoSpaceLeft, small.reserve(1));

    // The empty writer has no storage.
    const empty_writer: Big = .empty;
    try testing.expectEqual(@as(usize, 0), empty_writer.capacity());
    try testing.expectEqual(@as(usize, 0), empty_writer.unusedCapacityLen());
    try testing.expectEqual(@as(usize, 0), empty_writer.constBuffered().len);
}

test Reader {
    const Big = Reader(.big);
    const Little = Reader(.little);

    try testing.expectEqual(std.builtin.Endian.big, Big.byte_order);
    try testing.expectEqual(std.builtin.Endian.little, Little.byte_order);

    const bytes = [_]u8{
        0xab,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0a,
        0x0b,
        0x0c,
        0x0d,
        0x0e,
        0x0f,
        0x10,
        0x11,
        0x12,
        0x13,
        0x14,
        0x15,
        0x16,
        0x17,
        0x18,
        0x19,
        0x1a,
        0x1b,
        0x1c,
        0x1d,
        0x1e,
        0x1f,
        0x20,
        0x21,
        0x22,
        0x23,
        0x24,
        0x25,
        0x26,
        0x27,
        0xff,
        0xfe,
        'o',
        'k',
    };
    var reader: Big = .init(&bytes);

    try testing.expectEqual(@as(usize, bytes.len), reader.capacity());
    try testing.expectEqual(@as(usize, 0), reader.consumed().len);
    try testing.expectEqual(@as(usize, bytes.len), reader.remaining().len);

    // Every width is big-endian, including the odd byte widths.
    try testing.expectEqual(@as(u8, 0xab), try reader.read(u8));
    try testing.expectEqual(@as(u16, 0x0102), try reader.read(u16));
    try testing.expectEqual(@as(u24, 0x030405), try reader.read(u24));
    try testing.expectEqual(@as(u32, 0x06070809), try reader.read(u32));
    try testing.expectEqual(@as(u48, 0x0a0b0c0d0e0f), try reader.read(u48));
    try testing.expectEqual(@as(u64, 0x1011121314151617), try reader.read(u64));
    try testing.expectEqual(
        @as(u128, 0x18191a1b1c1d1e1f2021222324252627),
        try reader.read(u128),
    );

    // Signed integers are two's complement.
    try testing.expectEqual(@as(i16, -2), try reader.read(i16));

    // Slices are zero-copy views into the original bytes.
    const ok = try reader.readSlice(2);
    try testing.expectEqualStrings("ok", ok);
    try testing.expectEqual(bytes[42..44].ptr, ok.ptr);

    // The cursor is one past the last read byte.
    try testing.expectEqual(@as(usize, 44), reader.end);
    try testing.expectEqual(@as(usize, 0), reader.remaining().len);
    try testing.expectEqualSlices(u8, &bytes, reader.consumed());

    // The little-endian type reverses each fixed-width value.
    var le: Little = .init(&.{ 0x02, 0x01, 0x05, 0x04, 0x03, 0xfe, 0xff });
    try testing.expectEqual(@as(u16, 0x0102), try le.read(u16));
    try testing.expectEqual(@as(u24, 0x030405), try le.read(u24));
    try testing.expectEqual(@as(i16, -2), try le.read(i16));

    // A non-exhaustive enum keeps an unknown tag instead of panicking, so the
    // caller can reject it.
    const Kind = enum(u16) { data = 0x0102, _ };
    var kind_bytes: Big = .init(&.{ 0x01, 0x02, 0x99, 0x99 });
    try testing.expectEqual(Kind.data, try kind_bytes.read(Kind));
    const unknown = try kind_bytes.read(Kind);
    try testing.expectEqual(@as(u16, 0x9999), @intFromEnum(unknown));

    // The unchecked forms take the same path once the bound holds.
    var assumed: Big = .init(&.{ 0x01, 0x02, 0x03, 0x04 });
    try testing.expectEqual(@as(u16, 0x0102), assumed.assumeRead(u16));
    try testing.expectEqualSlices(u8, &.{0x03}, assumed.assumeReadSlice(1));
    assumed.assumeSkip(1);
    try testing.expectEqual(@as(usize, 0), assumed.remaining().len);

    // The cursor field is assignable, so a framer can rewind to the start of a
    // partial message.
    var rewindable: Big = .init(&.{ 0x01, 0x02 });
    const start = rewindable.end;
    try testing.expectEqual(@as(u8, 0x01), try rewindable.read(u8));
    rewindable.end = start;
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, rewindable.remaining());

    // A skip moves the cursor without reading.
    var skipping: Big = .init(&.{ 0xaa, 0xbb, 0xcc });
    try skipping.skip(1);
    try testing.expectEqual(@as(u8, 0xbb), try skipping.read(u8));
    try testing.expectEqualSlices(u8, &.{0xcc}, skipping.remaining());

    // Boundary: exactly empty succeeds, one more fails every checked form.
    var exact: Big = .init(&.{0x01});
    try testing.expectEqual(@as(u8, 0x01), try exact.read(u8));
    try testing.expectError(error.UnexpectedEof, exact.read(u8));
    try testing.expectError(error.UnexpectedEof, exact.readSlice(1));
    try testing.expectError(error.UnexpectedEof, exact.skip(1));
    try testing.expectError(error.UnexpectedEof, exact.read(u16));

    // The empty reader has no storage.
    var empty_reader: Big = .empty;
    try testing.expectEqual(@as(usize, 0), empty_reader.capacity());
    try testing.expectEqual(@as(usize, 0), empty_reader.remaining().len);
    try testing.expectError(error.UnexpectedEof, empty_reader.read(u8));
}
