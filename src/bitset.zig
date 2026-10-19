//! Fixed-capacity bitsets. `Scratch` is the reusable form: its backing words
//! stay dirty between uses, and `init` clears only a small validity map. A
//! data word is zeroed the first time `set` touches it, so a reset costs the
//! words a request touched, not the whole capacity.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// A fixed-capacity set of indices over dirty words.
///
/// The backing words are undefined until their first `set`, and `init` does
/// not clear them. Only `isSet` and `unset` can read a word, and both read it
/// only after the validity map says `set` zeroed it.
pub fn Scratch(comptime capacity: usize) type {
    const words = std.math.divCeil(usize, capacity, 64) catch unreachable;
    return struct {
        const Self = @This();
        const Bits = std.bit_set.ArrayBitSet(u64, capacity);
        const Valid = std.bit_set.ArrayBitSet(u64, words);

        bits: Bits,
        valid: Valid,

        /// Reset the set. Only the validity map is cleared; the data words
        /// stay dirty until a `set` claims one.
        pub fn init(self: *Self) void {
            self.valid = .initEmpty();
        }

        /// The reuse form of `init`: the same reset, named for a workspace
        /// that runs many requests.
        pub fn clear(self: *Self) void {
            self.init();
        }

        pub fn isSet(self: *const Self, index: usize) bool {
            assert(index < capacity);
            if (!wordIsSet(&self.valid.masks, index / 64)) return false;
            return wordIsSet(&self.bits.masks, index);
        }

        pub fn set(self: *Self, index: usize) void {
            assert(index < capacity);
            const word = index / 64;
            if (!wordIsSet(&self.valid.masks, word)) {
                // First touch: the word can hold anything left by an earlier
                // use, so clear its valid bits before the validity map
                // exposes it.
                const start = word * 64;
                self.bits.setRangeValue(.{
                    .start = start,
                    .end = @min(start + 64, capacity),
                }, false);
                self.valid.set(word);
            }
            self.bits.set(index);
        }

        /// Clear `index`. A word that was never touched reads as unset, so
        /// this is a no-op there.
        pub fn unset(self: *Self, index: usize) void {
            assert(index < capacity);
            if (!wordIsSet(&self.valid.masks, index / 64)) return;
            self.bits.unset(index);
        }

        /// One bit from a backing array.
        ///
        /// `ArrayBitSet.isSet` takes the whole array by value, which is the
        /// copy this type exists to avoid. A single-word `IntegerBitSet` reads
        /// the one mask instead.
        fn wordIsSet(masks: []const u64, index: usize) bool {
            const word: std.bit_set.IntegerBitSet(64) = .{ .mask = masks[index / 64] };
            return word.isSet(index % 64);
        }
    };
}

test Scratch {
    // A capacity that is not a multiple of 64: the last word is partial.
    var set: Scratch(70) = undefined;
    set.init();
    try testing.expect(!set.isSet(0));
    try testing.expect(!set.isSet(69));

    set.set(69);
    try testing.expect(set.isSet(69));
    try testing.expect(!set.isSet(68));
    try testing.expect(!set.isSet(6));

    // Dirty every backing word, then reuse. The first set must zero the rest
    // of its word, and an untouched word must stay unreadable.
    set.bits.masks[0] = ~@as(u64, 0);
    set.bits.masks[1] = ~@as(u64, 0);
    set.init();
    try testing.expect(!set.isSet(0));
    try testing.expect(!set.isSet(64));
    set.set(3);
    try testing.expect(set.isSet(3));
    try testing.expect(!set.isSet(4));
    try testing.expect(!set.isSet(63));
    try testing.expect(!set.isSet(64));

    // unset clears a live bit and does nothing for an untouched word.
    set.unset(3);
    try testing.expect(!set.isSet(3));
    set.unset(64);
    try testing.expect(!set.isSet(64));

    // clear forgets the previous request entirely.
    set.set(64);
    try testing.expect(set.isSet(64));
    set.clear();
    try testing.expect(!set.isSet(64));
    try testing.expect(!set.isSet(3));
}
