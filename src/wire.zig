//! Forward-only encoding and decoding of caller-owned bytes, with the byte
//! order fixed at comptime.
//!
//! `Writer(.big)` and `Writer(.little)` write fixed-width integers, enums, and
//! packed structs in the chosen order, byte slices, reserved slots, and LEB128
//! varints. A reserved slot is the reason this exists as a type: a length
//! prefix, checksum, or tag is often known only after the body, and `reserve`
//! hands back the bytes to fill later.
//!
//! `Reader(.big)` and `Reader(.little)` are the inverse. They read the same
//! widths and hand back zero-copy slices of the bytes they were given: a run of
//! `n` bytes, or the bytes before a delimiter. The `peek` forms return the same
//! values and leave the cursor alone.
//!
//! A varint carries its own length, so it has no width parameter and no slot.
//! `appendLeb128` and `readLeb128` take the sign from the type: an unsigned
//! width writes ULEB128 and a signed one writes SLEB128.
//!
//! A packed struct has a defined bit layout and no padding, so it writes as its
//! backing integer in one store, and a run of values wider than a byte takes
//! `appendSliceEndian` and `readSliceEndian`, which order each element instead
//! of copying bytes.
//!
//! Every fallible method has an unchecked form. The checked form returns an
//! error; the unchecked form asserts the same bound, so it panics in Debug and
//! ReleaseSafe and compiles out in ReleaseFast, where an overstep writes or
//! reads out of bounds. A parser that has checked the total length once uses
//! the unchecked forms so it does not branch on every field.
//!
//! ### Why not `std.Io.Reader` and `std.Io.Writer`
//!
//! Those are stream interfaces: a vtable, a buffer the reader refills from a
//! source, and one `error.WriteFailed` for every sink failure. This is the
//! layer underneath them. `read` is `std.mem.readInt` plus one compare, and
//! `std.Io.Reader.takeInt` inlines to the same instructions on a fixed buffer,
//! so taking it on would add a vtable and a coarser error set and buy nothing.
//! `std.Io.Reader` has no unchecked forms at all, which is the other half of
//! the point. On the write side `append` is also cheaper than `writeInt`,
//! because `writeInt` routes through `writeAll`, which does not inline: five
//! integers cost five calls there and none here.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const mem = std.mem;
const writeInt = mem.writeInt;
const readInt = mem.readInt;

/// The error set of `Reader.readLeb128`.
pub const Leb128Error = error{
    /// The bytes ended before the terminator byte.
    UnexpectedEof,
    /// A byte past the width of the type does not extend the value.
    Overflow,
};

/// The most bytes `encodeLeb128` writes for `T`.
///
/// A signed type needs one bit of headroom for the sign, and seven payload
/// bits fit in each byte, so the count is `floor((bits - 1) / 7) + 1` for both
/// signnesses. The decoder also accepts a redundant tail, so this is the
/// shortest bound, not the only one that decodes.
fn leb128MaxBytes(comptime T: type) comptime_int {
    const bits = switch (@typeInfo(T)) {
        .int => |info| info.bits,
        else => @compileError("wire: LEB128 of " ++ @typeName(T) ++ " is not an integer"),
    };
    if (bits == 0) @compileError("wire: LEB128 of " ++ @typeName(T) ++ " carries no bits");
    return @divFloor(bits - 1, 7) + 1;
}

/// Write `value` into `out` and return the byte count. `out` is at least
/// `leb128MaxBytes(T)` long, and the result is at most that.
fn encodeLeb128(comptime T: type, out: []u8, value: T) usize {
    const info = switch (@typeInfo(T)) {
        .int => |info| info,
        else => @compileError("wire: LEB128 of " ++ @typeName(T) ++ " is not an integer"),
    };
    const bits = info.bits;
    const U = @Int(.unsigned, bits);

    var rest: U = if (info.signedness == .signed) @bitCast(value) else value;
    var n: usize = 0;
    while (true) {
        const payload: u7 = @truncate(rest);
        // An arithmetic shift keeps a negative value negative, which is what
        // decides whether the next byte is pure sign extension.
        rest = if (info.signedness == .signed)
            @bitCast(@as(@Int(.signed, bits), @bitCast(rest)) >> 7)
        else
            rest >> 7;

        const last = if (info.signedness == .signed)
            (rest == 0 and payload & 0x40 == 0) or
                (rest == std.math.maxInt(U) and payload & 0x40 != 0)
        else
            rest == 0;

        out[n] = if (last) @as(u8, payload) else @as(u8, payload) | 0x80;
        n += 1;
        if (last) return n;
    }
}

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

        /// Append an integer, enum, or packed struct in the writer's byte
        /// order.
        ///
        /// Integers of any byte width work, including `u24`, `u48`, `u128`,
        /// and the signed types. An enum is written as its backing integer, and
        /// a packed struct too, since it has no padding: its fields fill that
        /// integer from its low bit. Returns `error.NoSpaceLeft` when the value
        /// does not fit.
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
                .@"enum" => |info| self.appendAssumeCapacity(
                    info.tag_type,
                    @backingInt(value),
                ),
                .@"struct" => |info| {
                    if (comptime info.layout != .@"packed") @compileError(
                        "wire.Writer.append: " ++ @typeName(T) ++ " has no wire form; " ++
                            "only a packed struct does",
                    );
                    self.appendAssumeCapacity(info.backing_integer.?, @bitCast(value));
                },
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

        /// Append a slice of integers or packed structs in the writer's byte
        /// order, one element at a time. Returns `error.NoSpaceLeft` when the
        /// run does not fit.
        ///
        /// `appendSlice` copies bytes verbatim, which is wrong for an array of
        /// multi-byte values on a host whose order differs. This one writes
        /// through `append`, so the caller gets the same bytes as a loop.
        pub fn appendSliceEndian(
            self: *Self,
            comptime Elem: type,
            values: []const Elem,
        ) error{NoSpaceLeft}!void {
            if (wireSize(Elem) * values.len > self.unusedCapacityLen()) {
                return error.NoSpaceLeft;
            }
            self.appendSliceEndianAssumeCapacity(Elem, values);
        }

        /// `appendSliceEndian` without the error return. Asserts the run fits.
        pub fn appendSliceEndianAssumeCapacity(
            self: *Self,
            comptime Elem: type,
            values: []const Elem,
        ) void {
            assert(wireSize(Elem) * values.len <= self.buffer.len - self.end);
            for (values) |value| self.appendAssumeCapacity(Elem, value);
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

        /// Append a LEB128-encoded integer.
        ///
        /// An unsigned `value` writes unsigned LEB128 and a signed `value`
        /// writes signed LEB128. The length follows from the value, so the
        /// write is never padded and never needs a slot. Returns
        /// `error.NoSpaceLeft` when the encoding does not fit.
        pub fn appendLeb128(self: *Self, comptime T: type, value: T) error{NoSpaceLeft}!void {
            var scratch: [leb128MaxBytes(T)]u8 = undefined;
            const n = encodeLeb128(T, &scratch, value);
            try self.appendSlice(scratch[0..n]);
        }

        /// `appendLeb128` without the error return. Asserts the encoding fits.
        pub fn appendLeb128AssumeCapacity(self: *Self, comptime T: type, value: T) void {
            var scratch: [leb128MaxBytes(T)]u8 = undefined;
            const n = encodeLeb128(T, &scratch, value);
            self.appendSliceAssumeCapacity(scratch[0..n]);
        }

        /// Drop the last `n` bytes from the output. Asserts `n` fits the bytes
        /// written.
        ///
        /// A speculatively written field that the caller decides against comes
        /// back off the output this way. The bytes stay in the backing, so a
        /// later append overwrites them, and a slot below the new cursor is no
        /// longer part of `buffered`.
        pub fn undo(self: *Self, n: usize) void {
            assert(n <= self.end);
            self.end -= n;
        }

        fn destination(self: *Self, comptime n: usize) *[n]u8 {
            return @ptrCast(self.buffer.ptr + self.end);
        }

        fn wireSize(comptime T: type) comptime_int {
            return switch (@typeInfo(T)) {
                .int => @divExact(@bitSizeOf(T), 8),
                .@"enum" => |info| wireSize(info.tag_type),
                .@"struct" => |info| {
                    if (info.layout != .@"packed") @compileError(
                        "wire.Writer: " ++ @typeName(T) ++ " has no wire form; " ++
                            "only a packed struct does",
                    );
                    if (@bitSizeOf(T) % 8 != 0) @compileError(
                        "wire.Writer: " ++ @typeName(T) ++ " is not a whole number of bytes",
                    );
                    return @divExact(@bitSizeOf(T), 8);
                },
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
/// The `read`, `readSlice`, `readUntil`, and `skip` forms return
/// `error.UnexpectedEof` when the request exceeds the unread bytes. The
/// `peek` forms return the same values and leave the cursor alone. The
/// `assume` forms assert the same bound instead. Bounds are checked as
/// `n > remaining().len`, never `end + n`, which would wrap in ReleaseFast.
///
/// A failed read never moves the cursor, so a framer can restore its start and
/// retry once more bytes arrive.
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

        /// Read an integer, enum, or packed struct in the reader's byte order.
        /// Returns `error.UnexpectedEof` when the value does not fit.
        ///
        /// Integers of any byte width work, including `u24`, `u48`, `u128`,
        /// and the signed types. An enum is read as its backing integer, and a
        /// packed struct too. Only non-exhaustive enums are allowed: an unknown
        /// tag is representable, so validation stays with the caller instead of
        /// a panic here.
        pub fn read(self: *Self, comptime T: type) error{UnexpectedEof}!T {
            const value = try self.peek(T);
            self.end += comptime wireSize(T);
            return value;
        }

        /// `read` without the error return. Asserts the value fits.
        pub fn assumeRead(self: *Self, comptime T: type) T {
            const value = self.assumePeek(T);
            self.end += comptime wireSize(T);
            return value;
        }

        /// Read the next value without moving the cursor. Returns
        /// `error.UnexpectedEof` when the value does not fit.
        ///
        /// This is how a decoder looks at a tag or a length before it commits
        /// to reading it, or decides which decoder to route a field to.
        pub fn peek(self: *Self, comptime T: type) error{UnexpectedEof}!T {
            if (wireSize(T) > self.remaining().len) return error.UnexpectedEof;
            return self.assumePeek(T);
        }

        /// `peek` without the error return. Asserts the value fits.
        pub fn assumePeek(self: *Self, comptime T: type) T {
            switch (@typeInfo(T)) {
                .int => {
                    const n = comptime wireSize(T);
                    assert(n <= self.remaining().len);
                    return readInt(T, self.destination(n), endian);
                },
                .@"enum" => |info| {
                    if (comptime info.mode == .exhaustive) @compileError(
                        "wire.Reader: enum " ++ @typeName(T) ++ " must be non-exhaustive, " ++
                            "so the caller validates an unknown tag",
                    );
                    return @fromBackingInt(self.assumePeek(info.tag_type));
                },
                .@"struct" => |info| {
                    if (comptime info.layout != .@"packed") @compileError(
                        "wire.Reader: " ++ @typeName(T) ++ " has no wire form; " ++
                            "only a packed struct does",
                    );
                    return @bitCast(self.assumePeek(info.backing_integer.?));
                },
                else => @compileError("wire.Reader: unsupported type " ++ @typeName(T)),
            }
        }

        /// Read `dest.len` integers or packed structs in the reader's byte
        /// order into `dest`. Returns `error.UnexpectedEof` when the run does
        /// not fit.
        ///
        /// This is the one read that cannot hand back a slice: the values are
        /// only `Elem` once the byte order is applied, so the bytes have to
        /// land somewhere first. On a host whose order already matches, a
        /// `readSlice` and a cast do the same job.
        pub fn readSliceEndian(
            self: *Self,
            comptime Elem: type,
            dest: []Elem,
        ) error{UnexpectedEof}!void {
            if (wireSize(Elem) * dest.len > self.remaining().len) return error.UnexpectedEof;
            self.assumeReadSliceEndian(Elem, dest);
        }

        /// `readSliceEndian` without the error return. Asserts the run fits.
        pub fn assumeReadSliceEndian(self: *Self, comptime Elem: type, dest: []Elem) void {
            assert(wireSize(Elem) * dest.len <= self.remaining().len);
            for (dest) |*slot| slot.* = self.assumeRead(Elem);
        }

        /// Read `n` bytes as a zero-copy slice. Returns
        /// `error.UnexpectedEof` when the slice does not fit.
        pub fn readSlice(self: *Self, n: usize) error{UnexpectedEof}![]const u8 {
            const bytes = try self.peekSlice(n);
            self.end += n;
            return bytes;
        }

        /// `readSlice` without the error return. Asserts the slice fits.
        pub fn assumeReadSlice(self: *Self, n: usize) []const u8 {
            const bytes = self.assumePeekSlice(n);
            self.end += n;
            return bytes;
        }

        /// Read the next `n` bytes without moving the cursor. Returns
        /// `error.UnexpectedEof` when the slice does not fit.
        pub fn peekSlice(self: *Self, n: usize) error{UnexpectedEof}![]const u8 {
            if (n > self.remaining().len) return error.UnexpectedEof;
            return self.assumePeekSlice(n);
        }

        /// `peekSlice` without the error return. Asserts the slice fits.
        pub fn assumePeekSlice(self: *Self, n: usize) []const u8 {
            assert(n <= self.remaining().len);
            return self.buffer[self.end..][0..n];
        }

        /// Read the bytes before `delimiter`, then consume the delimiter. The
        /// returned slice is a zero-copy view and excludes the delimiter.
        ///
        /// This is the lengthless field: a C string ends at a NUL, a line at a
        /// newline. The delimiter is a parameter, not a fixed `0`, so the rule
        /// "a field with no terminator is `error.UnexpectedEof`" lives in one
        /// place rather than in every protocol decoder.
        ///
        /// Returns `error.UnexpectedEof` when `delimiter` is not in the unread
        /// bytes. The cursor does not move in that case, and the delimiter is
        /// consumed only on success.
        pub fn readUntil(self: *Self, delimiter: u8) error{UnexpectedEof}![]const u8 {
            const field = try self.peekUntil(delimiter);
            self.end += field.len + 1;
            return field;
        }

        /// `readUntil` without the error return. Asserts `delimiter` is in the
        /// unread bytes.
        pub fn assumeReadUntil(self: *Self, delimiter: u8) []const u8 {
            const field = self.assumePeekUntil(delimiter);
            self.end += field.len + 1;
            return field;
        }

        /// Peek the bytes before `delimiter` without moving the cursor. The
        /// delimiter is not consumed and is not part of the slice.
        ///
        /// Returns `error.UnexpectedEof` when `delimiter` is not in the unread
        /// bytes.
        pub fn peekUntil(self: *Self, delimiter: u8) error{UnexpectedEof}![]const u8 {
            const index = mem.findScalar(u8, self.remaining(), delimiter);
            if (index == null) return error.UnexpectedEof;
            return self.assumePeekSlice(index.?);
        }

        /// `peekUntil` without the error return. Asserts `delimiter` is in the
        /// unread bytes.
        pub fn assumePeekUntil(self: *Self, delimiter: u8) []const u8 {
            const index = mem.findScalar(u8, self.remaining(), delimiter);
            assert(index != null);
            return self.assumePeekSlice(index.?);
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

        /// Read a LEB128-encoded integer.
        ///
        /// An unsigned `T` reads unsigned LEB128 and a signed `T` reads signed
        /// LEB128. The encoding carries its own length, so no width is read
        /// here and none is written by `appendLeb128`.
        ///
        /// Returns `error.UnexpectedEof` when the bytes end before the
        /// terminator. Returns `error.Overflow` when a byte past the width of
        /// `T` is not a valid extension of the value, so a redundant tail is
        /// rejected without stranding the cursor: the whole encoding is
        /// consumed first. A failed read leaves the cursor where it was.
        pub fn readLeb128(self: *Self, comptime T: type) Leb128Error!T {
            return self.decodeLeb128(T, true);
        }

        /// `readLeb128` without the error return. Asserts the bytes are there
        /// and the encoding fits.
        pub fn assumeReadLeb128(self: *Self, comptime T: type) T {
            return self.decodeLeb128(T, false) catch unreachable;
        }

        fn decodeLeb128(self: *Self, comptime T: type, comptime checked: bool) Leb128Error!T {
            const info = switch (@typeInfo(T)) {
                .int => |info| info,
                else => @compileError(
                    "wire.Reader: LEB128 of " ++ @typeName(T) ++ " is not an integer",
                ),
            };
            const bits = info.bits;
            const start = self.end;
            errdefer self.end = start;

            // The value accumulates in a `u128`, the widest Zig integer. The
            // low `bits` bits hold the value; a negative signed value is
            // sign-extended from the last bit actually read.
            //
            // Every byte is read to the terminator, even past the width of the
            // type. A redundant tail is malformed, but consuming it keeps the
            // cursor on the next field, so a caller can reject the value and
            // keep its framing.
            var acc: u128 = 0;
            var shift: usize = 0;
            var fits = true;
            while (true) {
                const byte = if (checked) try self.read(u8) else self.assumeRead(u8);
                const payload: u7 = @truncate(byte);

                if (shift < bits) {
                    // How many of this byte's payload bits land inside `T`.
                    const room = bits - shift;
                    if (room >= 7) {
                        acc |= @as(u128, payload) << @intCast(shift);
                    } else {
                        const keep: u3 = @intCast(room);
                        const mask: u7 = @truncate((@as(u8, 1) << keep) - 1);
                        acc |= @as(u128, payload & mask) << @intCast(shift);

                        // The bits that did not fit must extend the value. An
                        // unsigned value extends with zeros, a negative signed
                        // value with ones.
                        const negative = info.signedness == .signed and
                            (payload >> (keep - 1)) & 1 != 0;
                        const want: u7 = if (negative) @as(u7, 0x7f) >> keep else 0;
                        if (payload >> keep != want) fits = false;
                    }
                } else {
                    // Every bit of this byte is surplus, and it must match the
                    // sign of the value already accumulated.
                    const negative = info.signedness == .signed and
                        (acc >> @intCast(bits - 1)) & 1 != 0;
                    const want: u7 = if (negative) 0x7f else 0;
                    if (payload != want) fits = false;
                }

                if (byte & 0x80 == 0) {
                    // A short signed encoding carries its sign in bit 6 of the
                    // last byte, not in bit `bits - 1` of the accumulator.
                    const total = shift + 7;
                    if (info.signedness == .signed and total < bits and (payload >> 6) & 1 != 0) {
                        acc |= ~((@as(u128, 1) << @intCast(total)) - 1);
                    }
                    if (!fits) {
                        if (checked) return error.Overflow;
                        unreachable;
                    }
                    const U = @Int(.unsigned, bits);
                    const low: U = if (comptime bits == 128) acc else @truncate(acc);
                    return @bitCast(low);
                }
                shift += 7;
            }
        }

        fn destination(self: *Self, comptime n: usize) *const [n]u8 {
            return @ptrCast(self.buffer.ptr + self.end);
        }

        fn wireSize(comptime T: type) comptime_int {
            return switch (@typeInfo(T)) {
                .int => @divExact(@bitSizeOf(T), 8),
                .@"enum" => |info| wireSize(info.tag_type),
                .@"struct" => |info| {
                    if (info.layout != .@"packed") @compileError(
                        "wire.Reader: " ++ @typeName(T) ++ " has no wire form; " ++
                            "only a packed struct does",
                    );
                    if (@bitSizeOf(T) % 8 != 0) @compileError(
                        "wire.Reader: " ++ @typeName(T) ++ " is not a whole number of bytes",
                    );
                    return @divExact(@bitSizeOf(T), 8);
                },
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

    // A delimited field is the bytes before the delimiter, and the delimiter
    // is consumed with it.
    var delimited: Big = .init("id\x00age\x00");
    try testing.expectEqualStrings("id", try delimited.readUntil(0));
    try testing.expectEqualStrings("age", try delimited.readUntil(0));
    try testing.expectEqual(@as(usize, 0), delimited.remaining().len);

    // The delimiter is a parameter, so another protocol uses the same read.
    var line: Big = .init("hello world\r\nrest");
    try testing.expectEqualStrings("hello world\r", try line.readUntil('\n'));
    try testing.expectEqualSlices(u8, "rest", line.remaining());

    // A delimiter at the cursor is an empty field, not a skip.
    var empty_field: Big = .init("\x00\x00x");
    try testing.expectEqualStrings("", try empty_field.readUntil(0));
    try testing.expectEqualStrings("", try empty_field.readUntil(0));
    try testing.expectEqualSlices(u8, "x", empty_field.remaining());

    // A delimiter in the last byte is still found.
    var last_byte: Big = .init("x\x00");
    try testing.expectEqualStrings("x", try last_byte.readUntil(0));
    try testing.expectEqual(@as(usize, 0), last_byte.remaining().len);

    // A missing delimiter is an error, and the cursor does not move.
    var unterminated: Big = .init("no terminator");
    const before_failure = unterminated.end;
    try testing.expectError(error.UnexpectedEof, unterminated.readUntil(0));
    try testing.expectEqual(before_failure, unterminated.end);
    try testing.expectEqualSlices(u8, "no terminator", unterminated.remaining());

    // A delimited field leaves the cursor at the next typed field.
    var mixed: Big = .init("ab\x00\x00\x02");
    try testing.expectEqualStrings("ab", try mixed.readUntil(0));
    try testing.expectEqual(@as(u16, 0x0002), try mixed.read(u16));

    // The unchecked form takes the same path once the delimiter is known to
    // be present.
    var assumed_until: Big = .init("ab,c");
    try testing.expectEqualStrings("ab", assumed_until.assumeReadUntil(','));
    try testing.expectEqual(@as(u8, 'c'), try assumed_until.read(u8));

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
    try testing.expectEqual(@as(u16, 0x9999), @backingInt(unknown));

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
    try testing.expectError(error.UnexpectedEof, exact.readUntil('x'));
    try testing.expectError(error.UnexpectedEof, exact.skip(1));
    try testing.expectError(error.UnexpectedEof, exact.read(u16));

    // The empty reader has no storage.
    var empty_reader: Big = .empty;
    try testing.expectEqual(@as(usize, 0), empty_reader.capacity());
    try testing.expectEqual(@as(usize, 0), empty_reader.remaining().len);
    try testing.expectError(error.UnexpectedEof, empty_reader.read(u8));
    try testing.expectError(error.UnexpectedEof, empty_reader.readUntil(0));
}

test "peek" {
    const Big = Reader(.big);

    // A peek returns the value and leaves the cursor alone.
    var reader: Big = .init(&.{ 0x01, 0x02, 0x03, 0x04 });
    try testing.expectEqual(@as(u16, 0x0102), try reader.peek(u16));
    try testing.expectEqual(@as(usize, 0), reader.end);
    try testing.expectEqual(@as(u8, 0x01), try reader.peek(u8));
    try testing.expectEqual(@as(usize, 0), reader.end);

    // The read that follows consumes what the peek already showed.
    try testing.expectEqual(@as(u16, 0x0102), try reader.read(u16));
    try testing.expectEqual(@as(usize, 2), reader.end);

    // Slices peek without consuming the delimiter, so a caller can decide
    // whether to take the field.
    var fields: Big = .init("ab,cd");
    try testing.expectEqualStrings("ab", try fields.peekUntil(','));
    try testing.expectEqual(@as(usize, 0), fields.end);
    const view = try fields.peekSlice(3);
    try testing.expectEqualStrings("ab,", view);
    try testing.expectEqual(fields.buffer.ptr, view.ptr);
    try testing.expectEqual(@as(usize, 0), fields.end);
    try testing.expectEqualStrings("ab", try fields.readUntil(','));
    try testing.expectEqualStrings("cd", fields.remaining());

    // The unchecked forms assert the same bounds.
    var assumed: Big = .init("?ignored");
    try testing.expectEqual(@as(u8, '?'), assumed.assumePeek(u8));
    try testing.expectEqualStrings("?", assumed.assumePeekUntil('i'));
    try testing.expectEqualStrings("?ig", assumed.assumePeekSlice(3));
    try testing.expectEqual(@as(usize, 0), assumed.end);

    // An enum peeks as its backing integer.
    const Kind = enum(u8) { first = 0x07, _ };
    var tagged: Big = .init(&.{ 0x07, 0x99 });
    try testing.expectEqual(Kind.first, try tagged.peek(Kind));
    try testing.expectEqual(@as(usize, 0), tagged.end);
    try testing.expectEqual(Kind.first, try tagged.read(Kind));
    try testing.expectEqual(@as(usize, 1), tagged.end);

    // Boundary: a peek that reaches exactly the end succeeds, one more fails,
    // and no failure moves the cursor.
    var exact: Big = .init(&.{0xaa});
    try testing.expectEqual(@as(u8, 0xaa), try exact.peek(u8));
    try testing.expectError(error.UnexpectedEof, exact.peek(u16));
    try testing.expectError(error.UnexpectedEof, exact.peekSlice(2));
    try testing.expectError(error.UnexpectedEof, exact.peekUntil(0));
    try testing.expectEqual(@as(usize, 0), exact.end);

    var empty: Big = .empty;
    try testing.expectError(error.UnexpectedEof, empty.peek(u8));
    try testing.expectError(error.UnexpectedEof, empty.peekSlice(1));
}

test "append LEB128" {
    const Big = Writer(.big);

    // Known encodings, unsigned and signed.
    var storage: [leb128MaxBytes(u128)]u8 = undefined;
    var writer: Big = .init(&storage);

    try writer.appendLeb128(u32, 624485);
    try testing.expectEqualSlices(u8, &.{ 0xe5, 0x8e, 0x26 }, writer.constBuffered());

    writer.clear();
    try writer.appendLeb128(i32, -123456);
    try testing.expectEqualSlices(u8, &.{ 0xc0, 0xbb, 0x78 }, writer.constBuffered());

    writer.clear();
    try writer.appendLeb128(u8, 0);
    try writer.appendLeb128(u8, 127);
    try writer.appendLeb128(i8, -1);
    try writer.appendLeb128(i8, 63);
    try writer.appendLeb128(i8, 64);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x7f, 0x7f, 0x3f, 0xc0, 0x00 },
        writer.constBuffered(),
    );

    // A full buffer is `error.NoSpaceLeft` and writes nothing.
    var tight_storage: [1]u8 = undefined;
    var tight: Big = .init(&tight_storage);
    try testing.expectError(error.NoSpaceLeft, tight.appendLeb128(i32, 1000));
    try testing.expectEqual(@as(usize, 0), tight.constBuffered().len);
    try tight.appendLeb128(i32, 63);
    try testing.expectEqualSlices(u8, &.{0x3f}, tight.constBuffered());

    // The unchecked form takes the same path.
    var assumed_storage: [4]u8 = undefined;
    var assumed: Big = .init(&assumed_storage);
    assumed.appendLeb128AssumeCapacity(u32, 16384);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, assumed.constBuffered());

    // Every width encodes in at most `leb128MaxBytes`, and signed values round
    // trip through their own decoder.
    inline for (.{ u8, u16, u24, u32, u48, u64, u128 }) |U| {
        const max = std.math.maxInt(U);
        for ([_]U{ 0, 1, max / 2, max - 1, max }) |value| {
            var bytes: [leb128MaxBytes(U)]u8 = undefined;
            var w: Big = .init(&bytes);
            try w.appendLeb128(U, value);
            try testing.expect(w.constBuffered().len <= leb128MaxBytes(U));

            var r: Reader(.big) = .init(w.constBuffered());
            try testing.expectEqual(value, try r.readLeb128(U));
            try testing.expectEqual(@as(usize, 0), r.remaining().len);

            var again: Reader(.big) = .init(w.constBuffered());
            try testing.expectEqual(value, again.assumeReadLeb128(U));
        }
    }

    // A value at each seven-bit step, on a width that holds them all.
    for ([_]u64{ 0x7f, 0x80, 0x3fff, 0x4000, 0x1fffff, 0x200000 }) |value| {
        var bytes: [leb128MaxBytes(u64)]u8 = undefined;
        var w: Big = .init(&bytes);
        try w.appendLeb128(u64, value);
        var r: Reader(.big) = .init(w.constBuffered());
        try testing.expectEqual(value, try r.readLeb128(u64));
    }

    inline for (.{ i8, i16, i24, i32, i48, i64, i128 }) |I| {
        const min = std.math.minInt(I);
        const max = std.math.maxInt(I);
        for ([_]I{ 0, 1, -1, -2, min, min + 1, max - 1, max }) |value| {
            var bytes: [leb128MaxBytes(I)]u8 = undefined;
            var w: Big = .init(&bytes);
            try w.appendLeb128(I, value);
            try testing.expect(w.constBuffered().len <= leb128MaxBytes(I));

            var r: Reader(.big) = .init(w.constBuffered());
            try testing.expectEqual(value, try r.readLeb128(I));
            try testing.expectEqual(@as(usize, 0), r.remaining().len);
        }
    }

    // The signed step boundaries: 63 and -64 still fit one byte, 64 and -65
    // need a second.
    for ([_]i64{ 63, -64 }) |value| {
        var bytes: [leb128MaxBytes(i64)]u8 = undefined;
        var w: Big = .init(&bytes);
        try w.appendLeb128(i64, value);
        try testing.expectEqual(@as(usize, 1), w.constBuffered().len);
    }
    for ([_]i64{ 64, -65 }) |value| {
        var bytes: [leb128MaxBytes(i64)]u8 = undefined;
        var w: Big = .init(&bytes);
        try w.appendLeb128(i64, value);
        try testing.expectEqual(@as(usize, 2), w.constBuffered().len);
    }
}

test "read LEB128" {
    const Big = Reader(.big);

    // wire reads what std.Io writes and std.Io reads what wire writes, for
    // every width and both signnesses.
    inline for (.{ u8, u16, u24, u32, u48, u64, u128 }) |U| {
        const max = std.math.maxInt(U);
        for ([_]U{ 0, 1, max / 2, max - 1, max }) |value| {
            var io_storage: [leb128MaxBytes(U)]u8 = undefined;
            var io_writer = Io.Writer.fixed(&io_storage);
            try io_writer.writeLeb128(value);

            var r: Big = .init(Io.Writer.buffered(&io_writer));
            try testing.expectEqual(value, try r.readLeb128(U));
            try testing.expectEqual(@as(usize, 0), r.remaining().len);

            var wire_storage: [leb128MaxBytes(U)]u8 = undefined;
            var w: Writer(.big) = .init(&wire_storage);
            try w.appendLeb128(U, value);
            var io_reader = Io.Reader.fixed(w.constBuffered());
            try testing.expectEqual(value, try io_reader.takeLeb128(U));
        }
    }

    inline for (.{ i8, i16, i24, i32, i48, i64, i128 }) |I| {
        const min = std.math.minInt(I);
        const max = std.math.maxInt(I);
        for ([_]I{ 0, 1, -1, -2, min, min + 1, max - 1, max }) |value| {
            var io_storage: [leb128MaxBytes(I)]u8 = undefined;
            var io_writer = Io.Writer.fixed(&io_storage);
            try io_writer.writeLeb128(value);

            var r: Big = .init(Io.Writer.buffered(&io_writer));
            try testing.expectEqual(value, try r.readLeb128(I));

            var io_reader = Io.Reader.fixed(Io.Writer.buffered(&io_writer));
            var wire_storage: [leb128MaxBytes(I)]u8 = undefined;
            var w: Writer(.big) = .init(&wire_storage);
            try w.appendLeb128(I, value);
            try testing.expectEqual(value, try io_reader.takeLeb128(I));
        }
    }

    // The surplus bits of the last byte must extend the value. `0x80 0x02` is
    // 256, which does not fit a byte.
    var too_big: Big = .init(&.{ 0x80, 0x02 });
    try testing.expectError(error.Overflow, too_big.readLeb128(u8));
    try testing.expectEqual(@as(usize, 0), too_big.end);
    try testing.expectEqual(@as(u16, 256), try too_big.readLeb128(u16));

    // An unsigned value extends with zeros, so all-ones surplus is overflow.
    var wrong_sign: Big = .init(&.{ 0xff, 0x7f });
    try testing.expectError(error.Overflow, wrong_sign.readLeb128(u8));

    // A signed value extends with its own sign, so `0x7f 0x7f` is -1, not 127.
    var sign_extended: Big = .init(&.{ 0x7f, 0x7f });
    try testing.expectEqual(@as(i8, -1), try sign_extended.readLeb128(i8));

    // A leading zero byte is redundant but the value still fits.
    var redundant: Big = .init(&.{ 0x80, 0x00 });
    try testing.expectEqual(@as(u8, 0), try redundant.readLeb128(u8));

    // A redundant tail is consumed, not stranded. Three zero bytes and a
    // terminator is a valid encoding of zero for a sixteen-bit type.
    var redundant_tail: Big = .init(&.{ 0x80, 0x80, 0x80, 0x00, 0x2a });
    try testing.expectEqual(@as(u16, 0), try redundant_tail.readLeb128(u16));
    try testing.expectEqual(@as(u8, 0x2a), try redundant_tail.read(u8));

    // A tail that does not extend the value is overflow, and the whole
    // encoding is still consumed so the cursor lands on the next field.
    var bad_tail: Big = .init(&.{ 0x80, 0x80, 0x80, 0x01, 0x2a });
    try testing.expectError(error.Overflow, bad_tail.readLeb128(u16));
    try testing.expectEqual(@as(usize, 0), bad_tail.end);
    try testing.expectEqual(@as(u8, 0x80), try bad_tail.read(u8));

    // The bytes ending before the terminator is `error.UnexpectedEof`, and the
    // cursor stays at the start.
    var truncated: Big = .init(&.{0x80});
    try testing.expectError(error.UnexpectedEof, truncated.readLeb128(u32));
    try testing.expectEqual(@as(usize, 0), truncated.end);
    try testing.expectEqualSlices(u8, &.{0x80}, truncated.remaining());

    // A value lands back at the cursor for the next field.
    var framed: Big = .init(&.{ 0x96, 0x01, 0xff });
    try testing.expectEqual(@as(u16, 150), try framed.readLeb128(u16));
    try testing.expectEqual(@as(u8, 0xff), try framed.read(u8));
    try testing.expectEqual(@as(usize, 0), framed.remaining().len);
}

/// A LEB128 decode that disagrees with `std.Io.Reader.takeLeb128` is a bug,
/// including on bytes neither encoder produces and on the error kind.
fn expectLeb128MatchesStd(comptime T: type, bytes: []const u8) !void {
    var io = Io.Reader.fixed(bytes);
    var reader: Reader(.big) = .init(bytes);

    if (io.takeLeb128(T)) |want| {
        try testing.expectEqual(want, try reader.readLeb128(T));
        // The same value consumes the same bytes.
        try testing.expectEqual(io.seek, reader.end);
        return;
    } else |io_error| {
        switch (io_error) {
            error.Overflow, error.EndOfStream => {},
            else => unreachable,
        }
        // The kind must match, and a failed read must not move the cursor.
        if (reader.readLeb128(T)) |_| {
            try testing.expect(false);
        } else |wire_error| {
            try testing.expectEqual(io_error == error.Overflow, wire_error == error.Overflow);
            try testing.expectEqual(@as(usize, 0), reader.end);
        }
    }
}

test "packed struct" {
    const Big = Writer(.big);
    const RBig = Reader(.big);

    // A packed struct has a defined bit layout and no padding, so it is its
    // backing integer. A flags byte is one append.
    const Flags = packed struct {
        read: bool,
        write: bool,
        exec: bool,
        reserved: u5,
    };
    var storage: [8]u8 = undefined;
    var writer: Big = .init(&storage);
    try writer.append(Flags, .{ .read = true, .write = false, .exec = true, .reserved = 0 });
    try testing.expectEqualSlices(u8, &.{0x05}, writer.constBuffered());

    var reader: RBig = .init(writer.constBuffered());
    const flags = try reader.read(Flags);
    try testing.expect(flags.read);
    try testing.expect(!flags.write);
    try testing.expect(flags.exec);

    var peeked: RBig = .init(writer.constBuffered());
    try testing.expect((try peeked.peek(Flags)).exec);
    try testing.expectEqual(@as(usize, 0), peeked.end);

    // Fields fill the backing integer from its low bit, so on a big-endian
    // writer the first declared field lands in the last byte. This is the
    // backing integer's byte order, not a protocol bit order.
    const Pair = packed struct { low: u16, high: u16 };
    var pair_storage: [4]u8 = undefined;
    var pair_writer: Big = .init(&pair_storage);
    try pair_writer.append(Pair, .{ .low = 0x0102, .high = 0x0304 });
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x04, 0x01, 0x02 }, pair_writer.constBuffered());

    var little_storage: [4]u8 = undefined;
    var little: Writer(.little) = .init(&little_storage);
    try little.append(Pair, .{ .low = 0x0102, .high = 0x0304 });
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x04, 0x03 }, little.constBuffered());

    // A run of them goes through the same writes.
    var run_storage: [8]u8 = undefined;
    var run: Big = .init(&run_storage);
    try run.appendSliceEndian(Pair, &.{
        .{ .low = 0x0102, .high = 0x0304 },
        .{ .low = 0x0506, .high = 0x0708 },
    });
    try testing.expectEqualSlices(
        u8,
        &.{ 0x03, 0x04, 0x01, 0x02, 0x07, 0x08, 0x05, 0x06 },
        run.constBuffered(),
    );

    var back: RBig = .init(run.constBuffered());
    var pairs: [2]Pair = undefined;
    try back.readSliceEndian(Pair, &pairs);
    try testing.expectEqual(@as(u16, 0x0102), pairs[0].low);
    try testing.expectEqual(@as(u16, 0x0304), pairs[0].high);
    try testing.expectEqual(@as(u16, 0x0708), pairs[1].high);
    try testing.expectEqual(@as(usize, 0), back.remaining().len);
}

test "append endian elements" {
    const Big = Writer(.big);

    const values = [_]u32{ 0x01020304, 0x05060708 };
    var storage: [16]u8 = undefined;
    var writer: Big = .init(&storage);
    try writer.appendSliceEndian(u32, &values);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        writer.constBuffered(),
    );

    // One append per element is the same bytes: the run has no privileged
    // path of its own.
    var hand_storage: [16]u8 = undefined;
    var hand: Big = .init(&hand_storage);
    for (values) |value| try hand.append(u32, value);
    try testing.expectEqualSlices(u8, hand.constBuffered(), writer.constBuffered());

    // std writes the same bytes.
    var io_storage: [16]u8 = undefined;
    var io_writer = Io.Writer.fixed(&io_storage);
    try io_writer.writeSliceEndian(u32, &values, .big);
    try testing.expectEqualSlices(u8, Io.Writer.buffered(&io_writer), writer.constBuffered());

    // The little-endian writer reverses each element, not the run.
    var little_storage: [16]u8 = undefined;
    var little: Writer(.little) = .init(&little_storage);
    try little.appendSliceEndian(u32, &values);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x04, 0x03, 0x02, 0x01, 0x08, 0x07, 0x06, 0x05 },
        little.constBuffered(),
    );

    // An empty run writes nothing; a run that cannot fit writes nothing.
    writer.clear();
    try writer.appendSliceEndian(u32, &.{});
    try testing.expectEqual(@as(usize, 0), writer.constBuffered().len);
    var tight_storage: [5]u8 = undefined;
    var tight: Big = .init(&tight_storage);
    try testing.expectError(error.NoSpaceLeft, tight.appendSliceEndian(u32, &values));
    try testing.expectEqual(@as(usize, 0), tight.constBuffered().len);

    // The unchecked form.
    tight.appendSliceEndianAssumeCapacity(u8, &.{ 0xaa, 0xbb });
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, tight.constBuffered());
}

test "read endian elements" {
    const Big = Reader(.big);

    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xff };
    var reader: Big = .init(&bytes);
    var values: [2]u32 = undefined;
    try reader.readSliceEndian(u32, &values);
    try testing.expectEqualSlices(u32, &.{ 0x01020304, 0x05060708 }, &values);
    try testing.expectEqual(@as(usize, 8), reader.end);

    // One read per element consumes the same bytes.
    var hand: Big = .init(&bytes);
    try testing.expectEqual(@as(u32, 0x01020304), try hand.read(u32));
    try testing.expectEqual(@as(u32, 0x05060708), try hand.read(u32));
    try testing.expectEqual(hand.end, reader.end);

    // std reads the same values.
    var io_reader = Io.Reader.fixed(&bytes);
    var io_values: [2]u32 = undefined;
    try io_reader.readSliceEndian(u32, &io_values, .big);
    try testing.expectEqualSlices(u32, &values, &io_values);

    // A run that does not fit is an error and does not move the cursor.
    var short: Big = .init(&.{ 0x01, 0x02, 0x03 });
    var one: [1]u32 = undefined;
    try testing.expectError(error.UnexpectedEof, short.readSliceEndian(u32, &one));
    try testing.expectEqual(@as(usize, 0), short.end);

    var little: Reader(.little) = .init(&.{ 0x04, 0x03, 0x02, 0x01 });
    var le: [1]u32 = undefined;
    try little.readSliceEndian(u32, &le);
    try testing.expectEqual(@as(u32, 0x01020304), le[0]);

    // The unchecked form.
    var assumed: Big = .init(&.{ 0x00, 0x00, 0x00, 0x2a });
    var got: [1]u32 = undefined;
    assumed.assumeReadSliceEndian(u32, &got);
    try testing.expectEqual(@as(u32, 42), got[0]);
    try testing.expectEqual(@as(usize, 4), assumed.end);
}

test "undo" {
    const Big = Writer(.big);
    var storage: [8]u8 = undefined;
    var writer: Big = .init(&storage);

    try writer.append(u16, 0x0102);
    try writer.append(u16, 0x0304);
    try testing.expectEqual(@as(usize, 4), writer.constBuffered().len);

    // A field the caller decides against comes back off the output.
    writer.undo(2);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, writer.constBuffered());
    try testing.expectEqual(@as(usize, 6), writer.unusedCapacityLen());

    // The bytes stay in the backing, so the next write overwrites them.
    try writer.append(u16, 0x0506);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x05, 0x06 }, writer.constBuffered());

    // Undoing everything is what `clear` does.
    writer.undo(4);
    try testing.expectEqual(@as(usize, 0), writer.constBuffered().len);
    try testing.expectEqual(@as(usize, 8), writer.unusedCapacityLen());
}

test "read LEB128 matches std on malformed input" {
    var prng: std.Random.DefaultPrng = .init(0x9e37_79b9_7f4a_7c15);
    const random = prng.random();

    inline for (.{ u8, u16, u24, u32, u48, u64, u128, i8, i16, i24, i32, i48, i64, i128 }) |T| {
        const limit = comptime leb128MaxBytes(T) + 2;
        var buffer: [limit]u8 = undefined;
        for (0..limit + 1) |len| {
            for (0..120) |_| {
                for (buffer[0..len]) |*byte| byte.* = random.int(u8);
                try expectLeb128MatchesStd(T, buffer[0..len]);
            }
        }
    }
}
