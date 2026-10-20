const std = @import("std");
const memx = @import("stdx").mem;

// The length lives in the type, so a key cannot be copied with the wrong
// width. `secureZero` clears the bytes in a way the optimizer keeps.
const Key = memx.Array(32);

test "a byte value zeroes on request" {
    var key: Key = .init(@splat(0xab));
    key.secureZero();

    const zero: [32]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zero, &key.data);
}

test "the backwards scans return the last match" {
    const bytes = [_]u8{ 0x01, 0x02, 0x00, 0x00 };
    try std.testing.expectEqual(@as(?usize, 1), memx.lastIndexOfNonZero(&bytes));

    const values = [_]u16{ 7, 9, 7, 3 };
    try std.testing.expectEqual(@as(?usize, 2), memx.findScalarLast(u16, &values, 7));
    try std.testing.expectEqual(@as(?usize, 3), memx.findAny(u16, &values, &.{ 3, 5 }));
}
