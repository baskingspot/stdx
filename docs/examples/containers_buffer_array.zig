const std = @import("std");
const buffer = @import("stdx").buffer;

// The capacity is part of the type. The storage lives inside the value.
const Frame = buffer.Array(u8, 16);

// A length prefix and a payload, built with no allocator. A payload that
// does not fit is an error the caller handles.
fn encode(payload: []const u8) error{NoSpaceLeft}!Frame {
    var frame: Frame = .empty;
    try frame.append(@intCast(payload.len));
    try frame.appendSlice(payload);
    return frame;
}

// When the code has already checked the size, the AssumeCapacity pair
// skips the error path.
fn encodeChecked(payload: []const u8) ?Frame {
    if (payload.len + 1 > Frame.capacity) return null;
    var frame: Frame = .empty;
    frame.appendAssumeCapacity(@intCast(payload.len));
    frame.appendSliceAssumeCapacity(payload);
    return frame;
}

test "a payload that fits" {
    const frame = try encode("hello");
    try std.testing.expectEqualSlices(u8, "\x05hello", frame.constSlice());
}

test "a payload that does not fit" {
    try std.testing.expectError(error.NoSpaceLeft, encode("this payload is too long"));
    try std.testing.expectEqual(null, encodeChecked("this payload is too long"));
}

test "the checked path matches the fallible path" {
    const a = try encode("abc");
    const b = encodeChecked("abc").?;
    try std.testing.expectEqualSlices(u8, a.constSlice(), b.constSlice());
}
