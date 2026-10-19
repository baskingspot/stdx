const std = @import("std");
const bitset = @import("stdx").bitset;

// A reused workspace: init clears the validity map, not the dirty words.
test "track touched offsets across a reuse" {
    var scratch: bitset.Scratch(1 << 10) = undefined;
    scratch.init();

    scratch.set(7);
    scratch.set(700);
    try std.testing.expect(scratch.isSet(7));
    try std.testing.expect(scratch.isSet(700));
    try std.testing.expect(!scratch.isSet(8));

    // Reuse for the next request. The old bits read as unset, and the data
    // words are zeroed only as the new request touches them.
    scratch.init();
    try std.testing.expect(!scratch.isSet(7));
    try std.testing.expect(!scratch.isSet(700));

    scratch.set(8);
    try std.testing.expect(scratch.isSet(8));
    try std.testing.expect(!scratch.isSet(7));
}
