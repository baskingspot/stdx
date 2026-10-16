const std = @import("std");
const base32 = @import("stdx").base32;

// A token carries a binary key of a fixed shape. Sixteen lowercase
// Crockford symbols hold the ten bytes, with no padding.
test "a key round-trips through its token" {
    const key = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const token = base32.encode(10, &key);
    try std.testing.expectEqual(@as(usize, 16), token.len);
    try std.testing.expectEqual(key, try base32.decode(10, &token));
}

// Decode is the validation: a symbol outside the lowercase alphabet is
// the only failure, and no separate check runs before it.
test "every other spelling is rejected" {
    // Uppercase is not a second spelling: no case folding, no aliases.
    try std.testing.expectError(error.InvalidSymbol, base32.decode(10, &"ABCDEFGHJKMNPQRS".*));
    // The excluded letters i, l, o, u are invalid in lowercase too.
    try std.testing.expectError(error.InvalidSymbol, base32.decode(10, &"uuuuuuuuuuuuuuuu".*));
}
