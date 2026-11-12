const std = @import("std");
const base64 = @import("stdx").base64;

// Encode takes the codec as a comptime value, so the alphabet lookup the
// kernel indexes is a constant in the binary. `standard` is the padded
// alphabet from RFC 4648 section 4.
test "encode and decode round-trip" {
    const payload = "the quick brown fox jumps over the lazy dog";
    var encoded: [base64.standard.encodedLen(payload.len)]u8 = undefined;
    var decoded: [payload.len]u8 = undefined;

    const chars = base64.standard.encode(&encoded, payload);
    try std.testing.expectEqualStrings(
        "dGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZw==",
        chars,
    );

    const bytes = try base64.standard.decode(&decoded, chars);
    try std.testing.expectEqualStrings(payload, bytes);
}

// The decode is the validation. A byte outside the alphabet and a bad
// trailing group are both errors, so a decoded slice is always canonical.
test "decode rejects what is not base64" {
    var decoded: [16]u8 = undefined;
    // `!` is not in the alphabet.
    try std.testing.expectError(
        error.InvalidCharacter,
        base64.standard.decode(&decoded, "dGhlIQ!!"),
    );
    // The unused low bits of a partial group must be zero, and the pad count
    // must match: one byte takes two pads, not three.
    try std.testing.expectError(
        error.InvalidPadding,
        base64.standard.decode(&decoded, "dGhlA==="),
    );
}

// URL-safe base64 trades two alphabet characters and is unpadded when the
// format says so. Both are the same codec at a different comptime value.
test "url-safe and unpadded are the same codec" {
    const payload = [_]u8{ 0xFB, 0xFF, 0xBF };
    var encoded: [8]u8 = undefined;

    try std.testing.expectEqualStrings("+/+/", base64.standard.encode(&encoded, &payload));
    try std.testing.expectEqualStrings("-_-_", base64.url_safe.encode(&encoded, &payload));
    try std.testing.expectEqualStrings("-_-_", base64.url_safe_no_pad.encode(&encoded, &payload));
}

// Sizing a destination: `encodedLen` is exact, `decodedUpperBound` fits any
// input, and `decodedLen` is exact for one already in hand.
test "the lengths are computable before the call" {
    try std.testing.expectEqual(@as(usize, 4), base64.standard.encodedLen(1));
    try std.testing.expectEqual(@as(usize, 2), base64.standard_no_pad.encodedLen(1));
    try std.testing.expectEqual(@as(usize, 1), try base64.standard.decodedLen("Zg=="));
    try std.testing.expectEqual(@as(usize, 1), try base64.standard_no_pad.decodedLen("Zg"));
    try std.testing.expectEqual(@as(usize, 3), base64.standard.decodedUpperBound(4));
}
