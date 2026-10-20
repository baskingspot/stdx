//! Fixed-capacity bitsets. `Scratch` is the reusable form: its backing words
//! stay dirty between uses, and a data word is read only after `set` claims
//! it. A reset costs the words a request touched, not the whole capacity.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const ArrayBitSet = std.bit_set.ArrayBitSet;

const word_bits = @bitSizeOf(usize);
const Word = std.bit_set.IntegerBitSet(word_bits);

/// A fixed-capacity set of indices over dirty words.
///
/// Initialize in place: `var set: Scratch(1 << 14) = undefined; set.clear();`.
/// There is no by-value constructor. Returning or copying the set copies the
/// data words, and this type exists to avoid that cost; `clear` writes only
/// the initialized-word map.
///
/// The data words are undefined on first use and stale after a reset, until
/// `set` claims their word. The initialized-word map marks the words that
/// `set` has zeroed for this generation. `isSet` and `unset` never read a
/// data word unless the map marks it, so unclaimed bytes are never observed.
pub fn Scratch(comptime capacity: usize) type {
    comptime {
        if (capacity < 1) @compileError("bit_set.Scratch capacity must be positive");
    }
    const words = (capacity - 1) / word_bits + 1;
    return struct {
        const Self = @This();
        const Bits = ArrayBitSet(usize, capacity);
        const Initialized = ArrayBitSet(usize, words);

        bits: Bits,
        initialized: Initialized,

        /// Start a generation: forget every word and claim none. The data
        /// words stay as they are. This is also the initializer for a value
        /// declared `undefined`.
        pub inline fn clear(self: *Self) void {
            self.initialized = .empty;
        }

        pub inline fn isSet(self: *const Self, index: usize) bool {
            assert(index < capacity);
            if (!wordIsSet(&self.initialized.masks, index / word_bits)) return false;
            return wordIsSet(&self.bits.masks, index);
        }

        pub inline fn set(self: *Self, index: usize) void {
            assert(index < capacity);
            const word = index / word_bits;
            if (!wordIsSet(&self.initialized.masks, word)) {
                // Assign, do not clear: a read-modify-write would read an
                // undefined or stale word. The map exposes the word only
                // after this write.
                self.bits.masks[word] = 0;
                self.initialized.set(word);
            }
            self.bits.set(index);
        }

        /// Clear `index`. A word that was never touched reads as unset, so
        /// this is a no-op there.
        pub fn unset(self: *Self, index: usize) void {
            assert(index < capacity);
            if (!wordIsSet(&self.initialized.masks, index / word_bits)) return;
            self.bits.unset(index);
        }
    };
}

/// One bit from a backing array.
///
/// `ArrayBitSet.isSet` takes `Self` by value, so a call copies the
/// whole mask array. For a 64 KiB set that is an 8 KiB copy per
/// lookup. A single-word `IntegerBitSet` reads the one mask instead.
inline fn wordIsSet(masks: []const usize, index: usize) bool {
    const word: Word = .{ .mask = masks[index / word_bits] };
    return word.isSet(index % word_bits);
}

test Scratch {
    // A capacity that is not a multiple of the word size: the last word is
    // partial.
    var set: Scratch(70) = undefined;
    set.clear();
    try testing.expect(!set.isSet(0));
    try testing.expect(!set.isSet(69));

    set.set(69);
    try testing.expect(set.isSet(69));
    try testing.expect(!set.isSet(68));
    try testing.expect(!set.isSet(6));

    // Dirty every backing word, then reuse. The first set must zero the rest
    // of its word, and an untouched word must stay unreadable.
    for (&set.bits.masks) |*mask| mask.* = ~@as(usize, 0);
    set.clear();
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
