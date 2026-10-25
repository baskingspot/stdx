//! Ordered map: a B+tree whose nodes are sized for one cache-miss budget,
//! with inline keys and per-node prefix stripping so a lookup reads a few
//! cache lines instead of one per key compared.
//!
//! Zig 0.16 has no ordered map with owned nodes: `std.Treap` takes a node
//! per element from the caller, and the hash maps do not order. This module
//! is the sorted-iteration and range container the standard library lacks.
//!
//! The design is Xiangpeng Hao's, from "bbtree: fastest ordered map"
//! (<https://bbtree.xiangpeng.systems/post/>) and the Rust implementation at
//! <https://github.com/XiangpengHao/bbtree>. This module is a Zig
//! implementation of those ideas, not a port of that code.
//!
//! Three costs rank the work, as his cost model does: chained cache misses,
//! instructions, and cache coherence traffic. Inline keys and prefix keys
//! trace further back, to Graefe and Larson (ICDE 2001) and Bayer and
//! Unterauer (TODS 1977); the outer-fence rule for the spines is his.
//!
//! 1. **Node size.** A node holds 15 keys, so a search is a linear scan over
//!    one or two cache lines, never a pointer chase per key.
//! 2. **Inline keys.** Each key's first bytes, as one big-endian word, sit in
//!    a dense array in front of the keys. A search compares those words with
//!    one vector compare and a popcount, and reads a real key only when two
//!    words tie. For `[]const u8` keys this keeps the comparison off the heap.
//! 3. **Prefix keys.** Every key in a node shares the bytes its two fences
//!    (the nearest separators around it) share. The node stores that shared
//!    length and keeps windows at that offset, so long common prefixes cost
//!    nothing. The map's own smallest and largest keys fence the borders, so
//!    the shared prefix applies to the whole tree, not only the middle of it
//!    where separators exist on both sides.
//!
//! A wrong `inlineKey` implementation gives wrong answers, never undefined
//! behavior: the map never indexes with a window without bounding it by the
//! node length.
//!
//! # Threading
//!
//! The map is not thread safe. Use it from one thread at a time. Two
//! concurrent readers are not supported either, because the pointer guard is a
//! plain counter in Debug and ReleaseSafe, and an insertion or removal moves
//! or frees nodes.
//!
//! Upstream also ships a concurrent map. It puts a version lock on every
//! node, reads inner nodes optimistically, and keeps freed nodes on a free
//! list instead of returning them to the allocator. None of that is here.
//! Adding it is a separate design, not a flag on this one.
//!
//! Keys are values: the map copies a key into the separators that route to
//! it, and never frees a key. `[]const u8` keys are slices the caller owns
//! and must keep alive while the map holds them.
//!
//! The map grows, and it owns the entries, so a pointer it hands out does not
//! survive every call. `getPtr`, `getOrPut`, and an iterator address a leaf;
//! an insertion or removal in that leaf shifts entries, and a split or merge
//! frees the node. `lockPointers` makes that a bug report instead of a silent
//! one, in Debug and ReleaseSafe:
//!
//! ```zig
//! map.lockPointers();
//! defer map.unlockPointers();
//! const score = map.getPtr(key) orelse return;
//! const other = map.getPtr(other_key) orelse return;
//! // Any insertion or removal here asserts instead of invalidating.
//! ```

const std = @import("std");

const map = @import("btree/map.zig");
pub const Config = map.Config;
pub const compareBytes = map.compareBytes;
pub const Custom = map.Custom;
pub const Auto = map.Auto;
pub const String = map.String;
/// A `Context` for integer keys: numeric order, plus inline keys made of the
/// key's own big-endian bytes. A float has no total order (`NaN`), so this
/// context rejects one at compile time.
///
/// `Auto` uses it. Reach for it directly to build a `Custom` map over a key
/// type that wraps an integer, and delegate `compare`, `inlineKey`, and
/// `inline_width` to it.
pub const AutoContext = map.AutoContext;
/// A `Context` for `[]const u8` keys: byte order, plus inline keys made of the
/// key's bytes. The one context that orders slices.
///
/// `String` uses it. Reach for it directly to build a `Custom` map over a key
/// that carries more than its bytes, and delegate `compare`, `inlineKey`,
/// `compareFrom`, and `inline_width` to it.
pub const BytesContext = map.BytesContext;

test {
    std.testing.refAllDecls(@This());
}
