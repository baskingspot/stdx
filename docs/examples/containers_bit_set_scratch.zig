const std = @import("std");
const bit_set = @import("stdx").bit_set;

// There is no by-value constructor: it would copy the whole backing. Declare
// the set undefined and clear it in place.
test "track touched offsets across a reuse" {
    var scratch: bit_set.Scratch(1 << 10) = undefined;
    scratch.clear();

    scratch.set(7);
    scratch.set(700);
    try std.testing.expect(scratch.isSet(7));
    try std.testing.expect(scratch.isSet(700));
    try std.testing.expect(!scratch.isSet(8));

    // Reuse for the next request. The old bits read as unset, and the data
    // words are zeroed only as the new request touches them.
    scratch.clear();
    try std.testing.expect(!scratch.isSet(7));
    try std.testing.expect(!scratch.isSet(700));

    scratch.set(8);
    try std.testing.expect(scratch.isSet(8));
    try std.testing.expect(!scratch.isSet(7));
}
