const std = @import("std");
const buffer = @import("stdx").buffer;

// `Slice` has the API of `Array`, but over storage the caller owns. The
// capacity is a runtime value: the length of the slice.
test "append into caller storage" {
    var storage: [8]u8 = undefined;
    var out: buffer.Slice(u8) = .init(&storage);

    try out.appendSlice("abc");
    try std.testing.expectEqualStrings("abc", out.constSlice());

    // The bytes are in the caller's array, not in a copy.
    try std.testing.expectEqualStrings("abc", storage[0..3]);

    try std.testing.expectError(error.NoSpaceLeft, out.appendSlice("too long"));
}
