//! The ordered map behind `stdx.btree`: a B+tree of cache-sized nodes with
//! inline keys and per-node prefix stripping.
//!
//! # Shape
//!
//! Leaves hold the entries; internal nodes hold child pointers, one more
//! child than separators. Separator `i` is the smallest key in child `i+1`,
//! which is that child's own `low` field: a node carries one key, not one per
//! slot, so internal nodes are windows and edges. `low[i-1] <= k < low[i]`
//! routes to child `i`.
//!
//! ```text
//! leaf     | header | low | windows | (k v) (k v) ... |
//! internal | header | low | windows | child child ... |
//! ```
//!
//! `windows` is the dense array a search reads first: each key's big-endian
//! bytes at the node's `prefix_len`, truncated to `width`. Unused lanes hold
//! the maximum word, so a full-width vector compare never counts them as
//! smaller than the query.
//!
//! # Search
//!
//! One vector compare against the query's window produces the number of
//! strictly smaller windows; that count is the insertion position when no
//! window ties. A tie resolves the equal window run against the real keys.
//! A lookup that finds its key reads the header, the window line it lands
//! in, and the entry line, and nothing else.
//!
//! # Threading
//!
//! One thread at a time. The map has no lock, and it does not promise safe
//! concurrent reads: the pointer guard is a plain counter under runtime
//! safety. Upstream's concurrent map (per-node version locks, optimistic
//! inner nodes, a free list for reclamation) is a different tree.
//!
//! # Prefix stripping
//!
//! A node between fences `low` and `high` (the nearest separators around it
//! in the tree) has every key starting with the fences' common prefix, so
//! `prefix_len = commonPrefix(low, high)` and windows start there. The map
//! keeps its smallest and largest keys, so the spines that have no separator
//! on one side are fenced by those, and every node but the empty one has two
//! fences. Prefixes are recomputed when a node's fences change: a split, a
//! merge, a redistribution, or an insertion that moves an outer fence.
//!
//! A key outside `[lowest, highest]` moves an outer fence, which changes the
//! shared prefix of the spine it lands on, so the map widens the fences and
//! refits that spine before the search that inserts the key. A lookup of a
//! key outside the range can use a prefix the key does not share; it then
//! compares the real keys at the leaf, so it still answers correctly.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const math = std.math;
const Order = math.Order;

const stability = @import("../stability.zig");

/// Compile-time knobs for a map's nodes.
pub const Config = struct {
    /// Maximum keys per node, odd and at least 3. A split leaves
    /// `(max - 1) / 2` keys on each side with the middle one promoted. Null
    /// takes the context's `node_max`.
    max: ?u16 = null,
    /// Bytes of each window kept in the node: 2, 4, or 8. Null takes the
    /// context's `inline_width`, which is the width its measurements chose.
    width: ?u16 = null,
};

/// Longest prefix a node strips. Longer shared prefixes stop paying: the
/// window is already past every byte a human key shares.
const max_prefix = 4096;

/// Stack depth for removal and iteration. A node has at least 2 children, so
/// 32 frames address 2^32 entries at worst.
const max_depth = 32;

/// A map ordered by `Context.compare`, with inline keys when `Context`
/// declares `inlineKey`.
///
/// `Context` declares:
///
/// - `pub fn compare(self: Context, a: K, b: K) std.math.Order` — required.
/// - `pub fn inlineKey(self: Context, key: K, offset: usize) u64` —
///   optional. Returns bytes `offset..offset + 8` of an encoding of `key`
///   that sorts as the key sorts, big-endian and zero-padded past its end.
///   The contract: if `a`'s encoding sorts before `b`'s, then `a < b`.
///   Equal encodings decide nothing; the map compares the real keys. A
///   context without `inlineKey` gets the plain B+tree: same shape, same
///   correctness, full-key binary search.
pub fn Custom(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime config: Config,
) type {
    return struct {
        const Self = @This();

        comptime {
            switch (config.max orelse 15) {
                3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 63 => {},
                else => @compileError("btree.Config.max must be an odd number"),
            }
            switch (config.width orelse 2) {
                2, 4, 8 => {},
                else => @compileError("btree.Config.width must be 2, 4 or 8"),
            }
            if (!@hasDecl(Context, "compare"))
                @compileError("btree: Context must declare " ++
                    "`pub fn compare(self: Context, a: K, b: K) math.Order`");
        }

        /// Maximum keys per node.
        const max: usize = config.max orelse
            (if (@hasDecl(Context, "node_max")) Context.node_max else 15);
        /// Minimum keys per node, the root excepted.
        const min: usize = (max - 1) / 2;
        /// Bytes of each window kept.
        const width: u16 = config.width orelse
            (if (@hasDecl(Context, "inline_width")) Context.inline_width else 4);
        /// Whether the context supplies inline keys.
        const has_windows = @hasDecl(Context, "inlineKey");

        /// The window word: `width` bytes, compared unsigned.
        const Word = @Int(.unsigned, width * 8);
        /// The lanes a search compares: the node's capacity, rounded up to
        /// a vector width so the load never reads past the array.
        const vec_len = math.ceilPowerOfTwoAssert(usize, max);
        /// Window slots per node; none without a codec.
        const window_count = if (has_windows) vec_len else 0;
        /// A node's window array: one lane per slot, real keys first and
        /// `pad` for the rest. The `len` field says where the real ones end.
        const Windows = [window_count]Word;
        /// A whole node's windows as one vector, for a single compare.
        const Lanes = @Vector(vec_len, Word);
        /// One bool per lane: what that compare produces, before `@bitCast`
        /// packs it into a `Mask`.
        const LaneMask = @Vector(vec_len, bool);
        /// The packed lane result, one bit per lane.
        const Mask = @Int(.unsigned, vec_len);
        /// An unused lane: never smaller than any real window.
        const pad: Word = math.maxInt(Word);

        comptime {
            assert(vec_len <= 64);
        }

        /// One stored entry.
        pub const Element = struct { key: K, value: V };

        /// Pointers to a stored key and value. An entry lives in a leaf, so
        /// another leaf's churn does not move it, but any insertion or removal
        /// in its own leaf does, and a split or a merge can free the leaf
        /// outright. `lockPointers` turns those calls into an assertion while
        /// the pointers are in use.
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };

        /// Result of `getOrPut`. When `found_existing` is false the key has
        /// been written and the value is undefined until the caller sets it.
        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };

        const Kind = enum(u8) { leaf, internal };

        /// The alignment every node pointer carries, so a `*Header` can be
        /// cast to the concrete node type it belongs to.
        const node_align = @max(@alignOf(K), @alignOf(V), @alignOf(*anyopaque));

        /// Every node starts with this: the kind, the key count, and the
        /// length of the prefix its windows skip. A child is a `*Header`, so
        /// an internal node's edge array is eight bytes per edge.
        const Header = struct {
            len: u32,
            prefix_len: u16,
            kind: Kind,
        };

        const Leaf = struct {
            header: Header align(node_align),
            /// Smallest key in this leaf: the separator to its left. A node's
            /// key lives here, once per node, instead of once per slot in its
            /// parent.
            low: K,
            windows: Windows,
            elements: [max]Element,
        };

        const Internal = struct {
            header: Header align(node_align),
            /// Smallest key in this subtree, the separator to its left.
            low: K,
            /// Window of each separator: separator `i` is
            /// `children[i + 1].low`, one more child than windows.
            windows: Windows,
            children: [max + 1]Node,
        };

        const Node = *align(node_align) Header;

        fn asLeaf(node: Node) *Leaf {
            assert(node.kind == .leaf);
            return @fieldParentPtr("header", node);
        }

        fn asInternal(node: Node) *Internal {
            assert(node.kind == .internal);
            return @fieldParentPtr("header", node);
        }

        /// The smallest key in a node's subtree, which is also its
        /// separator in the parent.
        fn lowOf(node: Node) K {
            return switch (node.kind) {
                .leaf => asLeaf(node).low,
                .internal => asInternal(node).low,
            };
        }

        /// Number of entries in the map.
        used: usize,
        /// Root node, or null when the map is empty.
        root: ?Node,
        /// Debug and ReleaseSafe only: while a borrow is outstanding, every
        /// call that can move or free an entry asserts instead.
        pointer_stability: stability.SafetyLock = .{},
        /// Length of the prefix every key in the map shares, kept in step
        /// with the extremes.
        shared_prefix: u16 = 0,
        /// Smallest key in the map, the outer fence of the left spine.
        lowest: ?K,
        /// Largest key in the map, the outer fence of the right spine.
        highest: ?K,
        /// The ordering and inline-key hooks.
        context: Context,

        /// A map with no entries. The context is undefined, as in
        /// `std.PriorityQueue.empty`; use `initContext` whenever the
        /// comparator reads it.
        pub const empty: Self = .{
            .used = 0,
            .root = null,
            .lowest = null,
            .highest = null,
            .context = undefined,
        };

        /// A map with no entries and the given context.
        pub fn initContext(context: Context) Self {
            return .{
                .used = 0,
                .root = null,
                .lowest = null,
                .highest = null,
                .context = context,
            };
        }

        /// Number of entries in the map.
        pub fn count(self: *const Self) usize {
            return self.used;
        }

        /// Whether the map has no entries.
        pub fn isEmpty(self: *const Self) bool {
            return self.used == 0;
        }

        /// Forbid entry invalidation until `unlockPointers`. While locked,
        /// any call that can move or free a stored entry (every insertion,
        /// removal, and `clearAndFree`) fails an assertion in Debug and
        /// ReleaseSafe, and does nothing in ReleaseFast.
        ///
        /// Bracket the lifetime of pointers from `getPtr` and `getOrPut`,
        /// and of an iterator over node memory, with this call. The counter
        /// is not atomic, so this guard assumes one thread at a time like
        /// everything else here.
        ///
        /// It may be called several times, so independent borrowers can hold
        /// the map at once; `unlockPointers` restores the previous state when
        /// called as many times. This is the rule `std.ArrayList` states for
        /// its own `lockPointers`.
        pub fn lockPointers(self: *Self) void {
            self.pointer_stability.lockShared();
        }

        /// Undo one call to `lockPointers`.
        pub fn unlockPointers(self: *Self) void {
            self.pointer_stability.unlockShared();
        }

        /// Value stored for `key`, or null.
        pub fn get(self: *const Self, key: K) ?V {
            const value_ptr = self.getPtr(key) orelse return null;
            return value_ptr.*;
        }

        /// Pointer to the value stored for `key`, or null. Any insertion,
        /// removal, or `clearAndFree` invalidates it; `lockPointers` turns
        /// that into an assertion in Debug and ReleaseSafe instead.
        pub fn getPtr(self: *const Self, key: K) ?*V {
            var node = self.root orelse return null;
            while (node.kind == .internal) {
                const in = asInternal(node);
                node = in.children[self.searchInternal(in, key)];
            }
            const leaf = asLeaf(node);
            const found = self.searchLeaf(leaf, key);
            if (!found.found) return null;
            return &leaf.elements[found.pos].value;
        }

        /// Pointer to the value stored for `key`; when absent, inserts `key`
        /// with an undefined value and reports `found_existing = false`. The
        /// caller must initialize `value_ptr` in that case.
        pub fn getOrPut(self: *Self, gpa: Allocator, key: K) !GetOrPutResult {
            self.pointer_stability.assertUnlocked();
            if (self.root == null) {
                const node = try createLeaf(gpa);
                const leaf = asLeaf(node);
                leaf.elements[0].key = key;
                leaf.header.len = 1;
                self.lowest = key;
                self.highest = key;
                self.updateSharedPrefix();
                self.refit(node, .{ .low = key, .high = key });
                self.root = node;
                self.used = 1;
                return .{
                    .key_ptr = &leaf.elements[0].key,
                    .value_ptr = &leaf.elements[0].value,
                    .found_existing = false,
                };
            }

            // A key outside the tree's range moves the outer fences, which are
            // the shared prefix every window in the tree is taken at. Update
            // them before the search: a window at the old prefix would order
            // the new key against keys it does not share that prefix with.
            self.widenExtremes(key);

            var root = self.root.?;
            if (isFull(root)) root = try self.splitRoot(gpa, root);
            var node = root;
            var outer = Fences{ .low = self.lowest, .high = self.highest };
            while (true) {
                if (node.kind == .leaf) {
                    const leaf = asLeaf(node);
                    const found = self.searchLeaf(leaf, key);
                    if (found.found) return .{
                        .key_ptr = &leaf.elements[found.pos].key,
                        .value_ptr = &leaf.elements[found.pos].value,
                        .found_existing = true,
                    };
                    assert(leaf.header.len < max); // the descent splits full children
                    const pos = found.pos;
                    self.insertElement(leaf, pos, key, undefined);
                    self.used += 1;
                    return .{
                        .key_ptr = &leaf.elements[pos].key,
                        .value_ptr = &leaf.elements[pos].value,
                        .found_existing = false,
                    };
                }
                const in = asInternal(node);
                var idx = self.searchInternal(in, key);
                var child = in.children[idx];
                if (isFull(child)) {
                    try self.splitChild(gpa, in, idx, childFences(in, idx, outer));
                    if (self.compare(key, lowOf(in.children[idx + 1])) != .lt) idx += 1;
                    child = in.children[idx];
                }
                node = child;
                outer = childFences(in, idx, outer);
            }
        }

        /// Insert `key` with `value`, replacing any existing value.
        pub fn put(self: *Self, gpa: Allocator, key: K, value: V) !void {
            const result = try self.getOrPut(gpa, key);
            result.value_ptr.* = value;
        }

        /// Insert `key` with `value`, returning the value replaced.
        pub fn fetchPut(self: *Self, gpa: Allocator, key: K, value: V) !?V {
            const result = try self.getOrPut(gpa, key);
            if (result.found_existing) {
                const previous = result.value_ptr.*;
                result.value_ptr.* = value;
                return previous;
            }
            result.value_ptr.* = value;
            return null;
        }

        /// Remove `key`, returning whether it was present.
        pub fn remove(self: *Self, gpa: Allocator, key: K) bool {
            return self.fetchRemove(gpa, key) != null;
        }

        /// Remove `key`, returning the value it held.
        pub fn fetchRemove(self: *Self, gpa: Allocator, key: K) ?V {
            self.pointer_stability.assertUnlocked();
            var path: [max_depth]Frame = undefined;
            var node = self.root orelse return null;
            var depth: usize = 0;
            var outer = Fences{ .low = self.lowest, .high = self.highest };
            while (true) {
                if (node.kind == .leaf) {
                    const leaf = asLeaf(node);
                    const found = self.searchLeaf(leaf, key);
                    if (!found.found) return null;
                    const value = leaf.elements[found.pos].value;
                    self.removeElement(leaf, found.pos);
                    self.used -= 1;
                    var min_moved = false;
                    if (found.pos == 0 and leaf.header.len > 0) {
                        min_moved = self.refreshLow(path[0..depth], leaf);
                    }
                    self.refreshPath(path[0..depth]);
                    self.rebalanceUp(gpa, path[0..depth]);
                    self.fixRoot(gpa);
                    self.noteRemoved(key, min_moved);
                    return value;
                }
                const in = asInternal(node);
                const idx = self.searchInternal(in, key);
                assert(depth < max_depth);
                path[depth] = .{ .node = node, .index = idx, .fences = outer };
                depth += 1;
                node = in.children[idx];
                outer = childFences(in, idx, outer);
            }
        }

        /// Remove every entry and free every node.
        pub fn clearAndFree(self: *Self, gpa: Allocator) void {
            self.pointer_stability.assertUnlocked();
            if (self.root) |root| self.destroyNode(gpa, root);
            self.root = null;
            self.used = 0;
            self.lowest = null;
            self.highest = null;
            self.shared_prefix = 0;
        }

        /// Iterate entries in ascending key order.
        pub fn iterator(self: *const Self) Iterator {
            var it: Iterator = .{ .depth = 0 };
            if (self.root) |root| it.descend(root, 0);
            return it;
        }

        /// Iterate entries from `key` upward. `inclusive` keeps an entry whose
        /// key equals `key`; otherwise iteration starts after it. A key that
        /// is not in the map starts at the next larger key. The iterator is
        /// empty when `key` is greater than the map's largest stored key.
        pub fn iteratorFrom(self: *const Self, key: K, inclusive: bool) Iterator {
            var it: Iterator = .{ .depth = 0 };
            var node = self.root orelse return it;
            // A key outside the map's range does not share the prefix the
            // windows are taken at, so its search position means nothing.
            // Both ends answer without searching: below the smallest key the
            // whole map qualifies, above the largest nothing does.
            if (self.lowest) |low| {
                if (self.compare(key, low) == .lt) return self.iterator();
            }
            if (self.highest) |high| {
                const order = self.compare(key, high);
                if (order == .gt or (order == .eq and !inclusive)) return it;
            }
            while (true) {
                if (node.kind == .leaf) {
                    const found = self.searchLeaf(asLeaf(node), key);
                    const start = found.pos + @intFromBool(found.found and !inclusive);
                    it.frames[it.depth] = .{ .node = node, .index = start };
                    it.depth += 1;
                    return it;
                }
                const idx = self.searchInternal(asInternal(node), key);
                it.frames[it.depth] = .{ .node = node, .index = idx };
                it.depth += 1;
                node = asInternal(node).children[idx];
            }
        }

        /// The smallest entry, or null.
        pub fn first(self: *const Self) ?Entry {
            var it = self.iterator();
            return it.next();
        }

        /// The largest entry, or null.
        pub fn last(self: *const Self) ?Entry {
            var node = self.root orelse return null;
            while (node.kind == .internal) {
                const in = asInternal(node);
                node = in.children[in.header.len];
            }
            const leaf = asLeaf(node);
            return .{
                .key_ptr = &leaf.elements[leaf.header.len - 1].key,
                .value_ptr = &leaf.elements[leaf.header.len - 1].value,
            };
        }

        // --- windows ---

        /// `key`'s window at `prefix`, truncated to the node layout's width.
        fn windowOf(self: *const Self, key: K, prefix: usize) Word {
            const window = self.context.inlineKey(key, prefix);
            const shift: u6 = @intCast(64 - @as(u32, width) * 8);
            return @truncate(window >> shift);
        }

        // --- search ---

        const Found = struct { pos: usize, found: bool };

        fn searchLeaf(self: *const Self, leaf: *const Leaf, key: K) Found {
            const n: usize = leaf.header.len;
            if (comptime !has_windows) {
                return binarySearchLeaf(self, leaf, 0, n, key);
            } else {
                const target = self.windowOf(key, leaf.header.prefix_len);
                const less = countLess(&leaf.windows, target);
                if (less == n or leaf.windows[less] != target) {
                    return .{ .pos = less, .found = false };
                }
                const leq = countLeq(&leaf.windows, target, n);
                const tie_offset = @as(usize, leaf.header.prefix_len) + width;
                if (leq - less == 1) {
                    const order = self.compareFrom(leaf.elements[less].key, key, tie_offset);
                    return switch (order) {
                        .lt => .{ .pos = less + 1, .found = false },
                        .eq => .{ .pos = less, .found = true },
                        .gt => .{ .pos = less, .found = false },
                    };
                }
                return binarySearchLeaf(self, leaf, less, leq, key);
            }
        }

        fn binarySearchLeaf(
            self: *const Self,
            leaf: *const Leaf,
            from: usize,
            to: usize,
            key: K,
        ) Found {
            var lo = from;
            var hi = to;
            const tie_offset = @as(usize, leaf.header.prefix_len) + width;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (self.compareFrom(leaf.elements[mid].key, key, tie_offset)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return .{ .pos = mid, .found = true },
                }
            }
            return .{ .pos = lo, .found = false };
        }

        /// Index of the child to follow: the number of separators at or
        /// below `key`. A separator is the `low` key of the child to its
        /// right, so the nodes here carry no key array.
        fn searchInternal(self: *const Self, in: *const Internal, key: K) usize {
            const n: usize = in.header.len;
            if (comptime !has_windows) {
                return self.upperBound(in, 0, n, key);
            } else {
                const target = self.windowOf(key, in.header.prefix_len);
                const less = countLess(&in.windows, target);
                if (less == n or in.windows[less] != target) return less;
                const leq = countLeq(&in.windows, target, n);
                const tie_offset = @as(usize, in.header.prefix_len) + width;
                if (leq - less == 1) {
                    const separator = lowOf(in.children[less + 1]);
                    const order = self.compareFrom(separator, key, tie_offset);
                    return if (order == .gt) less else less + 1;
                }
                return self.upperBound(in, less, leq, key);
            }
        }

        fn upperBound(
            self: *const Self,
            in: *const Internal,
            from: usize,
            to: usize,
            key: K,
        ) usize {
            var lo = from;
            var hi = to;
            const tie_offset = @as(usize, in.header.prefix_len) + width;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (self.compareFrom(lowOf(in.children[mid + 1]), key, tie_offset)) {
                    .gt => hi = mid,
                    else => lo = mid + 1,
                }
            }
            return lo;
        }

        fn splat(target: Word) Lanes {
            return @splat(target);
        }

        /// Number of real windows strictly below `target`. Padding lanes hold
        /// the maximum word, so they never count.
        fn countLess(windows: *const Windows, target: Word) usize {
            const lanes: Lanes = windows.*;
            const less: LaneMask = lanes < splat(target);
            const mask: Mask = @bitCast(less);
            return @popCount(mask);
        }

        /// Number of real windows at or below `target`, bounded by `len`.
        fn countLeq(windows: *const Windows, target: Word, len: usize) usize {
            if (len == 0) return 0;
            const lanes: Lanes = windows.*;
            const leq: LaneMask = lanes <= splat(target);
            const mask: Mask = @as(Mask, @bitCast(leq)) & lenMask(len);
            return @popCount(mask);
        }

        fn lenMask(len: usize) Mask {
            return ~@as(Mask, 0) >> @intCast(vec_len - len);
        }

        fn compare(self: *const Self, a: K, b: K) Order {
            return self.context.compare(a, b);
        }

        /// Compare two keys whose encodings are known equal up to `offset`:
        /// the context compares the bytes past the offset when it can, and
        /// the full keys settle the tie when the suffixes are equal.
        fn compareFrom(self: *const Self, a: K, b: K, offset: usize) Order {
            if (comptime @hasDecl(Context, "compareFrom")) {
                switch (self.context.compareFrom(a, b, offset)) {
                    .eq => {},
                    else => |order| return order,
                }
            }
            return self.context.compare(a, b);
        }

        // --- node mutation ---

        fn isFull(node: Node) bool {
            return node.len == max;
        }

        fn fill(node: Node) usize {
            return node.len;
        }

        fn insertElement(self: *Self, leaf: *Leaf, pos: usize, key: K, value: V) void {
            const n: usize = leaf.header.len;
            var i = n;
            while (i > pos) : (i -= 1) {
                leaf.elements[i] = leaf.elements[i - 1];
                if (comptime has_windows) leaf.windows[i] = leaf.windows[i - 1];
            }
            leaf.elements[pos] = .{ .key = key, .value = value };
            if (comptime has_windows) {
                leaf.windows[pos] = self.windowOf(key, leaf.header.prefix_len);
            }
            leaf.header.len = @intCast(n + 1);
        }

        fn removeElement(self: *Self, leaf: *Leaf, pos: usize) void {
            _ = self;
            const n: usize = leaf.header.len;
            var i = pos;
            while (i + 1 < n) : (i += 1) {
                leaf.elements[i] = leaf.elements[i + 1];
                if (comptime has_windows) leaf.windows[i] = leaf.windows[i + 1];
            }
            if (comptime has_windows) leaf.windows[n - 1] = pad;
            leaf.header.len = @intCast(n - 1);
        }

        /// Write the window of separator `idx`, which is the lower fence of
        /// `children[idx + 1]`.
        fn setWindow(self: *Self, in: *Internal, idx: usize) void {
            if (comptime has_windows) {
                in.windows[idx] = self.windowOf(lowOf(in.children[idx + 1]), in.header.prefix_len);
            }
        }

        /// Insert `child` at `idx + 1` of an internal node that has room. The
        /// separator it adds is the child's own low key, so no key array
        /// moves.
        fn insertChild(self: *Self, in: *Internal, idx: usize, child: Node) void {
            const n: usize = in.header.len;
            var i = n;
            while (i > idx) : (i -= 1) {
                in.children[i + 1] = in.children[i];
                if (comptime has_windows) in.windows[i] = in.windows[i - 1];
            }
            in.children[idx + 1] = child;
            in.header.len = @intCast(n + 1);
            self.setWindow(in, idx);
        }

        /// Remove separator `idx` and child `idx + 1`.
        fn removeChild(self: *Self, in: *Internal, idx: usize) void {
            _ = self;
            const n: usize = in.header.len;
            var i = idx;
            while (i + 1 < n) : (i += 1) {
                in.children[i + 1] = in.children[i + 2];
                if (comptime has_windows) in.windows[i] = in.windows[i + 1];
            }
            if (comptime has_windows) in.windows[n - 1] = pad;
            in.header.len = @intCast(n - 1);
        }

        // --- construction ---

        fn createLeaf(gpa: Allocator) !Node {
            const leaf = try gpa.create(Leaf);
            leaf.header = .{ .len = 0, .prefix_len = 0, .kind = .leaf };
            if (comptime has_windows) @memset(&leaf.windows, pad);
            return @alignCast(&leaf.header);
        }

        fn createInternal(gpa: Allocator) !Node {
            const in = try gpa.create(Internal);
            in.header = .{ .len = 0, .prefix_len = 0, .kind = .internal };
            if (comptime has_windows) @memset(&in.windows, pad);
            return @alignCast(&in.header);
        }

        /// Set a node's lower fence, its prefix from both fences, and every
        /// window. A node's own `low` is the fence the parent routes by.
        fn refit(self: *Self, node: Node, fences: Fences) void {
            var prefix: u16 = 0;
            if (comptime has_windows) {
                if (fences.low != null and fences.high != null) {
                    const low = fences.low.?;
                    const high = fences.high.?;
                    prefix = @intCast(commonPrefix(K, Context, self.context, low, high));
                } else {
                    // A border node has no fence on one side, so it strips
                    // what every key of the tree shares and no more: a key
                    // outside the range still shares that much.
                    prefix = self.sharedPrefix();
                }
            }
            node.prefix_len = prefix;
            switch (node.kind) {
                .leaf => {
                    const leaf = asLeaf(node);
                    const n: usize = leaf.header.len;
                    leaf.low = fences.low orelse self.lowest orelse leaf.low;
                    if (comptime has_windows) {
                        for (0..n) |i| {
                            leaf.windows[i] = self.windowOf(leaf.elements[i].key, prefix);
                        }
                        @memset(leaf.windows[n..], pad);
                    }
                },
                .internal => {
                    const in = asInternal(node);
                    const n: usize = in.header.len;
                    in.low = fences.low orelse self.lowest orelse in.low;
                    if (comptime has_windows) {
                        for (0..n) |i| {
                            in.windows[i] = self.windowOf(lowOf(in.children[i + 1]), prefix);
                        }
                        @memset(in.windows[n..], pad);
                    }
                },
            }
        }

        /// Split a full root into a new root with two children.
        fn splitRoot(self: *Self, gpa: Allocator, old: Node) !Node {
            const root = try createInternal(gpa);
            const fences = Fences{ .low = self.lowest, .high = self.highest };
            const in = asInternal(root);
            in.children[0] = old;
            self.refit(root, fences);
            self.splitChild(gpa, in, 0, fences) catch |err| {
                gpa.destroy(in);
                return err;
            };
            self.root = root;
            return root;
        }

        /// Split `parent.children[idx]` in half. The new separator needs no
        /// key: it is the right half's own low key.
        fn splitChild(
            self: *Self,
            gpa: Allocator,
            parent: *Internal,
            idx: usize,
            fences: Fences,
        ) !void {
            const child = parent.children[idx];
            switch (child.kind) {
                .leaf => {
                    const leaf = asLeaf(child);
                    const n: usize = leaf.header.len;
                    const mid = n / 2;
                    const right = try createLeaf(gpa);
                    const r = asLeaf(right);
                    r.header.len = @intCast(n - mid);
                    @memcpy(r.elements[0 .. n - mid], leaf.elements[mid..n]);
                    r.low = r.elements[0].key;
                    leaf.header.len = @intCast(mid);
                    self.insertChild(parent, idx, right);
                    self.refit(right, .{ .low = r.low, .high = fences.high });
                    self.refit(child, .{ .low = fences.low, .high = r.low });
                },
                .internal => {
                    const in = asInternal(child);
                    const n: usize = in.header.len;
                    const mid = n / 2;
                    const right = try createInternal(gpa);
                    const r = asInternal(right);
                    r.header.len = @intCast(n - mid - 1);
                    @memcpy(r.children[0 .. n - mid], in.children[mid + 1 .. n + 1]);
                    r.low = lowOf(r.children[0]);
                    in.header.len = @intCast(mid);
                    self.insertChild(parent, idx, right);
                    self.refit(right, .{ .low = r.low, .high = fences.high });
                    self.refit(child, .{ .low = fences.low, .high = r.low });
                },
            }
        }

        // --- removal and balance ---

        /// The keys on either side of a node: its separators in the parent,
        /// or the map's outer fences at the spines.
        const Fences = struct { low: ?K, high: ?K };

        /// One step of a root-to-leaf path: the node, the child to follow,
        /// and the fences around the node.
        const Frame = struct { node: Node, index: usize, fences: Fences };

        /// Rewrite what a leaf's changed smallest key affects: the separator
        /// to its left, the leaf's own prefix, and the prefix of the previous
        /// sibling, whose upper fence is that separator. A fence that moves
        /// changes the common prefix for the whole spine under it, so each
        /// refit walks the matching spine. Returns whether the map's smallest
        /// key moved.
        fn refreshLow(self: *Self, path: []const Frame, leaf: *Leaf) bool {
            leaf.low = leaf.elements[0].key;
            var node: Node = @alignCast(&leaf.header);
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const frame = path[i];
                const parent = asInternal(frame.node);
                const idx = frame.index;
                self.refitSpineAt(node, childFences(parent, idx, frame.fences), 0);
                if (idx > 0) {
                    self.setWindow(parent, idx - 1);
                    const previous = childFences(parent, idx - 1, frame.fences);
                    self.refitSpineAt(parent.children[idx - 1], previous, 1);
                    return false;
                }
                parent.low = lowOf(node);
                node = frame.node;
            }
            // Every ancestor was a first child, so the leaf is the map's
            // leftmost and the smallest key moved with it.
            self.lowest = leaf.low;
            return true;
        }

        /// Recompute every frame's fences from the tree's current extremes.
        fn refreshPath(self: *const Self, path: []Frame) void {
            var outer = Fences{ .low = self.lowest, .high = self.highest };
            for (path) |*frame| {
                frame.fences = outer;
                outer = childFences(asInternal(frame.node), frame.index, outer);
            }
        }

        /// Fix every node on the path that fell below the minimum fill.
        fn rebalanceUp(self: *Self, gpa: Allocator, path: []const Frame) void {
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const frame = path[i];
                const parent = asInternal(frame.node);
                if (fill(parent.children[frame.index]) >= min) break;
                self.rebalance(gpa, parent, frame.index, frame.fences);
            }
        }

        /// Restore the minimum fill of `parent.children[idx]` by borrowing
        /// from a sibling or merging with one.
        fn rebalance(
            self: *Self,
            gpa: Allocator,
            parent: *Internal,
            idx: usize,
            outer: Fences,
        ) void {
            const n: usize = parent.header.len;
            const left: ?usize = if (idx > 0) idx - 1 else null;
            const right: ?usize = if (idx < n) idx + 1 else null;
            if (left) |li| {
                if (fill(parent.children[li]) > min) return self.borrowFromLeft(parent, idx, outer);
            }
            if (right) |ri| {
                if (fill(parent.children[ri]) > min) {
                    return self.borrowFromRight(parent, idx, outer);
                }
            }
            if (left) |li| return self.merge(gpa, parent, li, outer);
            return self.merge(gpa, parent, idx, outer);
        }

        /// The fences around `parent.children[idx]`: the members' own low
        /// keys, or the node's outer fences at the borders.
        fn childFences(parent: *const Internal, idx: usize, outer: Fences) Fences {
            const n: usize = parent.header.len;
            return .{
                .low = if (idx > 0) lowOf(parent.children[idx]) else outer.low,
                .high = if (idx < n) lowOf(parent.children[idx + 1]) else outer.high,
            };
        }

        /// The length of the prefix every key in the map shares. A node with
        /// no fence on one side strips exactly this much, so that a key which
        /// shares it can be searched anywhere in the tree.
        fn sharedPrefix(self: *const Self) u16 {
            return self.shared_prefix;
        }

        /// Recompute the shared prefix from the extremes. Call it whenever
        /// either extreme moves.
        fn updateSharedPrefix(self: *Self) void {
            if (comptime !has_windows) {
                self.shared_prefix = 0;
                return;
            }
            if (self.lowest == null or self.highest == null) {
                self.shared_prefix = 0;
                return;
            }
            const prefix = commonPrefix(K, Context, self.context, self.lowest.?, self.highest.?);
            self.shared_prefix = @intCast(prefix);
        }

        // --- extremes ---

        /// Move the outer fences out to `key` when it lies outside the tree,
        /// and refit the spine whose fence moved. A fence that is too low (or
        /// too high) only shortens the shared prefix, which stays correct; an
        /// insert that later fails leaves the map with a wider range than its
        /// keys, and the next removal of that extreme recomputes it.
        fn widenExtremes(self: *Self, key: K) void {
            var moved = false;
            if (self.lowest) |lowest| {
                if (self.compare(key, lowest) == .lt) {
                    self.lowest = key;
                    moved = true;
                }
            } else {
                self.lowest = key;
                moved = true;
            }
            if (self.highest) |highest| {
                if (self.compare(key, highest) == .gt) {
                    self.highest = key;
                    moved = true;
                }
            } else {
                self.highest = key;
                moved = true;
            }
            // The shared prefix is a property of both extremes, and every
            // border node on either spine strips it.
            if (moved) {
                self.updateSharedPrefix();
                self.refitSpines();
            }
        }

        /// Replace a removed extreme with the current one, and refit the
        /// spine whose outer fence moved.
        fn noteRemoved(self: *Self, key: K, min_moved: bool) void {
            if (self.used == 0) {
                self.lowest = null;
                self.highest = null;
                self.shared_prefix = 0;
                return;
            }
            var moved_high = false;
            if (self.highest) |highest| {
                if (self.compare(key, highest) == .eq) {
                    self.highest = self.extremeKey(1);
                    moved_high = true;
                }
            }
            if (min_moved or moved_high) {
                self.updateSharedPrefix();
                self.refitSpines();
            }
        }

        /// The smallest (`side = 0`) or largest (`side = 1`) key in the map.
        fn extremeKey(self: *const Self, comptime side: u1) K {
            var node = self.root.?;
            while (node.kind == .internal) {
                const in = asInternal(node);
                node = if (side == 0) in.children[0] else in.children[in.header.len];
            }
            const leaf = asLeaf(node);
            return if (side == 0)
                leaf.elements[0].key
            else
                leaf.elements[leaf.header.len - 1].key;
        }

        /// Refit every node on the left (`side = 0`) or right spine, whose
        /// outer fence is the tree's extreme key.
        /// Refit both spines: the shared prefix they strip changed.
        fn refitSpines(self: *Self) void {
            self.refitSpine(0);
            self.refitSpine(1);
        }

        fn refitSpine(self: *Self, comptime side: u1) void {
            const root = self.root orelse return;
            self.refitSpineAt(root, .{ .low = self.lowest, .high = self.highest }, side);
        }

        /// Refit a node and the spine below it on one side. A fence that moves
        /// down or up widens the common prefix for everything under it.
        fn refitSpineAt(self: *Self, node_: Node, fences: Fences, comptime side: u1) void {
            var node = node_;
            var outer = fences;
            while (true) {
                self.refit(node, outer);
                if (node.kind == .leaf) return;
                const in = asInternal(node);
                const idx: usize = if (side == 0) 0 else in.header.len;
                node = in.children[idx];
                outer = childFences(in, idx, outer);
            }
        }

        /// Move the left sibling's last entry into child `idx`.
        fn borrowFromLeft(self: *Self, parent: *Internal, idx: usize, outer: Fences) void {
            const left = parent.children[idx - 1];
            const child = parent.children[idx];
            const sep_idx = idx - 1;
            switch (child.kind) {
                .leaf => {
                    const l = asLeaf(left);
                    const c = asLeaf(child);
                    const moved = l.elements[l.header.len - 1];
                    self.insertElement(c, 0, moved.key, moved.value);
                    l.header.len -= 1;
                    c.low = c.elements[0].key;
                },
                .internal => {
                    const l = asInternal(left);
                    const c = asInternal(child);
                    var i: usize = c.header.len;
                    while (i > 0) : (i -= 1) c.children[i + 1] = c.children[i];
                    // The loop leaves children[1..] shifted; child 0 still
                    // holds the old first child, which moves up one slot.
                    c.children[1] = c.children[0];
                    c.children[0] = l.children[l.header.len];
                    c.header.len += 1;
                    l.header.len -= 1;
                    c.low = lowOf(c.children[0]);
                },
            }
            self.setWindow(parent, sep_idx);
            self.refit(left, childFences(parent, idx - 1, outer));
            // The child's lower fence moved down, so its own prefix and the
            // prefix of every leftmost descendant shrank.
            self.refitSpineAt(child, childFences(parent, idx, outer), 0);
        }

        /// Move the right sibling's first entry into child `idx`.
        fn borrowFromRight(self: *Self, parent: *Internal, idx: usize, outer: Fences) void {
            const child = parent.children[idx];
            const right = parent.children[idx + 1];
            const sep_idx = idx;
            switch (child.kind) {
                .leaf => {
                    const c = asLeaf(child);
                    const r = asLeaf(right);
                    const moved = r.elements[0];
                    self.insertElement(c, c.header.len, moved.key, moved.value);
                    var i: usize = 0;
                    while (i + 1 < r.header.len) : (i += 1) r.elements[i] = r.elements[i + 1];
                    r.header.len -= 1;
                    r.low = r.elements[0].key;
                },
                .internal => {
                    const c = asInternal(child);
                    const r = asInternal(right);
                    c.children[c.header.len + 1] = r.children[0];
                    c.header.len += 1;
                    var i: usize = 0;
                    while (i + 1 < r.header.len) : (i += 1) {
                        r.children[i] = r.children[i + 1];
                    }
                    r.children[r.header.len - 1] = r.children[r.header.len];
                    r.header.len -= 1;
                    r.low = lowOf(r.children[0]);
                },
            }
            self.setWindow(parent, sep_idx);
            // The child's upper fence moved up, widening its prefix.
            self.refitSpineAt(child, childFences(parent, idx, outer), 1);
            self.refit(right, childFences(parent, idx + 1, outer));
        }

        /// Merge children `sep_idx` and `sep_idx + 1`. No key moves down: the
        /// separator they shared was only the right child's low key.
        fn merge(
            self: *Self,
            gpa: Allocator,
            parent: *Internal,
            sep_idx: usize,
            outer: Fences,
        ) void {
            const left = parent.children[sep_idx];
            const right = parent.children[sep_idx + 1];
            const merged = Fences{
                .low = if (sep_idx > 0) lowOf(left) else outer.low,
                .high = if (sep_idx + 1 < parent.header.len)
                    lowOf(parent.children[sep_idx + 2])
                else
                    outer.high,
            };
            // A merge at either edge leaves the merged node with no fence on
            // that side, so everything below it strips only the shared prefix.
            const at_left = sep_idx == 0;
            const at_right = sep_idx + 1 == parent.header.len;
            switch (left.kind) {
                .leaf => {
                    const l = asLeaf(left);
                    const r = asLeaf(right);
                    const n: usize = l.header.len;
                    const m: usize = r.header.len;
                    @memcpy(l.elements[n .. n + m], r.elements[0..m]);
                    l.header.len = @intCast(n + m);
                    self.removeChild(parent, sep_idx);
                    self.refit(left, merged);
                    if (at_left) self.refitSpineAt(left, merged, 0);
                    if (at_right) self.refitSpineAt(left, merged, 1);
                    gpa.destroy(r);
                },
                .internal => {
                    const l = asInternal(left);
                    const r = asInternal(right);
                    const n: usize = l.header.len;
                    const m: usize = r.header.len;
                    @memcpy(l.children[n + 1 .. n + 2 + m], r.children[0 .. m + 1]);
                    l.header.len = @intCast(n + 1 + m);
                    self.removeChild(parent, sep_idx);
                    self.refit(left, merged);
                    if (at_left) self.refitSpineAt(left, merged, 0);
                    if (at_right) self.refitSpineAt(left, merged, 1);
                    gpa.destroy(r);
                },
            }
        }

        /// Collapse a root internal node that lost its last separator, and
        /// free an empty root leaf.
        fn fixRoot(self: *Self, gpa: Allocator) void {
            const root = self.root orelse return;
            switch (root.kind) {
                .leaf => {
                    const leaf = asLeaf(root);
                    if (leaf.header.len == 0) {
                        gpa.destroy(leaf);
                        self.root = null;
                    }
                },
                .internal => {
                    const in = asInternal(root);
                    if (in.header.len == 0) {
                        self.root = in.children[0];
                        gpa.destroy(in);
                    }
                },
            }
        }

        fn destroyNode(self: *Self, gpa: Allocator, node: Node) void {
            switch (node.kind) {
                .leaf => gpa.destroy(asLeaf(node)),
                .internal => {
                    const in = asInternal(node);
                    const n: usize = in.header.len;
                    for (0..n + 1) |i| destroyNode(self, gpa, in.children[i]);
                    gpa.destroy(in);
                },
            }
        }

        /// Ascending iterator over a map. The frames address nodes, so a
        /// mutation while the iterator is live is a use-after-free; bracket
        /// the walk with `lockPointers` to make that assert.
        pub const Iterator = struct {
            frames: [max_depth]IterFrame = undefined,
            depth: usize,

            const IterFrame: type = struct { node: Node, index: usize };

            /// Next entry in ascending key order.
            pub fn next(self: *Iterator) ?Entry {
                while (self.depth > 0) {
                    const top = &self.frames[self.depth - 1];
                    if (top.node.kind == .leaf) {
                        const leaf = asLeaf(top.node);
                        if (top.index < leaf.header.len) {
                            const i = top.index;
                            top.index += 1;
                            return .{
                                .key_ptr = &leaf.elements[i].key,
                                .value_ptr = &leaf.elements[i].value,
                            };
                        }
                        self.depth -= 1;
                        if (self.depth > 0) self.frames[self.depth - 1].index += 1;
                    } else {
                        const in = asInternal(top.node);
                        if (top.index > in.header.len) {
                            self.depth -= 1;
                            if (self.depth > 0) self.frames[self.depth - 1].index += 1;
                            continue;
                        }
                        self.descend(in.children[top.index], 0);
                    }
                }
                return null;
            }

            fn descend(self: *Iterator, node: Node, index: usize) void {
                assert(self.depth < max_depth);
                self.frames[self.depth] = .{ .node = node, .index = index };
                self.depth += 1;
                if (node.kind == .internal) {
                    self.descend(asInternal(node).children[index], 0);
                }
            }
        };

        /// Assert the tree's structural invariants. Test-only: it walks every
        /// node and compares every key.
        fn checkInvariants(self: *const Self) !void {
            const root = self.root orelse {
                try testing.expectEqual(@as(usize, 0), self.used);
                return;
            };
            var leaf_depth: ?usize = null;
            var seen: usize = 0;
            const outer: Fences = .{ .low = self.lowest, .high = self.highest };
            try self.checkNode(root, outer, 0, true, &leaf_depth, &seen);
            try testing.expectEqual(self.used, seen);
        }

        fn checkNode(
            self: *const Self,
            node: Node,
            fences: Fences,
            depth: usize,
            is_root: bool,
            leaf_depth: *?usize,
            seen: *usize,
        ) !void {
            const n: usize = node.len;
            try testing.expect(n <= max);
            // A prefix shorter than the fences allow is safe, only slower: a
            // stale one must never be longer, or the windows would compare
            // bytes the keys do not share.
            try testing.expect(node.prefix_len <= expectedPrefix(self, fences));
            switch (node.kind) {
                .leaf => {
                    const leaf = asLeaf(node);
                    if (!is_root) try testing.expect(n >= min);
                    // The separator to the left of a leaf is its own
                    // smallest key, exactly.
                    if (fences.low) |low| try testing.expect(self.compare(leaf.low, low) == .eq);
                    for (0..n) |i| {
                        const key = leaf.elements[i].key;
                        if (i > 0) {
                            const order = self.compare(leaf.elements[i - 1].key, key);
                            try testing.expect(order == .lt);
                        }
                        if (fences.low) |l| try testing.expect(self.compare(l, key) != .gt);
                        if (fences.high) |h| try testing.expect(self.compare(key, h) != .gt);
                        if (comptime has_windows) {
                            const window = self.windowOf(key, node.prefix_len);
                            try testing.expectEqual(window, leaf.windows[i]);
                        }
                    }
                    if (comptime has_windows) {
                        for (leaf.windows[n..]) |w| try testing.expectEqual(pad, w);
                    }
                    seen.* += n;
                    if (leaf_depth.*) |d| {
                        try testing.expectEqual(d, depth);
                    } else leaf_depth.* = depth;
                },
                .internal => {
                    const in = asInternal(node);
                    if (is_root) {
                        try testing.expect(n >= 1);
                    } else {
                        try testing.expect(n >= min);
                    }
                    if (fences.low) |low| try testing.expect(self.compare(in.low, low) == .eq);
                    for (0..n) |i| {
                        const separator = lowOf(in.children[i + 1]);
                        if (i > 0) {
                            const order = self.compare(lowOf(in.children[i]), separator);
                            try testing.expect(order == .lt);
                        }
                        if (fences.high) |h| try testing.expect(self.compare(separator, h) != .gt);
                        if (comptime has_windows) {
                            const window = self.windowOf(separator, node.prefix_len);
                            try testing.expectEqual(window, in.windows[i]);
                        }
                    }
                    if (comptime has_windows) {
                        for (in.windows[n..]) |w| try testing.expectEqual(pad, w);
                    }
                    for (0..n + 1) |i| {
                        const child = childFences(in, i, fences);
                        try self.checkNode(
                            in.children[i],
                            child,
                            depth + 1,
                            false,
                            leaf_depth,
                            seen,
                        );
                    }
                },
            }
        }

        fn expectedPrefix(self: *const Self, fences: Fences) u16 {
            if (comptime !has_windows) return 0;
            if (fences.low == null or fences.high == null) return self.sharedPrefix();
            return @intCast(commonPrefix(K, Context, self.context, fences.low.?, fences.high.?));
        }
    };
}

/// Byte offset of the first byte where `a`'s and `b`'s encodings differ.
fn commonPrefix(comptime K: type, comptime Context: type, context: Context, a: K, b: K) usize {
    const capped = if (@hasDecl(Context, "encodedLen"))
        @min(context.encodedLen(a), context.encodedLen(b))
    else
        max_prefix;
    // Zero padding makes a key look like it continues with zeros, so a
    // difference past the shorter key's end says nothing; the cap decides.
    const limit = @min(capped, max_prefix);
    var offset: usize = 0;
    while (offset < limit) : (offset += 8) {
        const wa = context.inlineKey(a, offset);
        const wb = context.inlineKey(b, offset);
        if (wa != wb) return @min(offset + @as(usize, @clz(wa ^ wb)) / 8, limit);
    }
    return limit;
}

fn bytesWindow(bytes: []const u8, offset: usize) u64 {
    if (offset >= bytes.len) return 0;
    const rest = bytes.len - offset;
    if (rest >= 8) return mem.readInt(u64, bytes[offset..][0..8], .big);
    // Fewer than eight bytes remain: read the last eight bytes of the key,
    // which overlaps what this window needs, and shift the tail up. Only a
    // key shorter than eight bytes needs a byte-wise assembly, and there the
    // window is the whole padded key shifted past `offset`.
    if (bytes.len >= 8) {
        const tail = mem.readInt(u64, bytes[bytes.len - 8 ..][0..8], .big);
        return tail << @intCast(8 * (8 - rest));
    }
    var buffer: [8]u8 = @splat(0);
    @memcpy(buffer[0..bytes.len], bytes);
    const word = mem.readInt(u64, &buffer, .big);
    return word << @intCast(8 * offset);
}

/// A `Context` for keys with Zig's ordering operators, encoding each key as
/// its own big-endian bytes. Integers only.
pub fn AutoContext(comptime K: type) type {
    comptime {
        if (@typeInfo(K) != .int)
            @compileError("btree.Auto takes an integer key; use btree.Custom for other types");
    }
    return struct {
        const Self = @This();

        /// Two bytes: with eight-byte keys, the first two already separate
        /// neighbours, and sixteen lanes then share one cache line with the
        /// node header.
        pub const inline_width: u16 = 2;

        pub fn compare(_: Self, a: K, b: K) Order {
            return math.order(a, b);
        }

        /// The length of the key's encoding.
        pub fn encodedLen(_: Self, _: K) usize {
            return @bitSizeOf(K) / 8;
        }

        pub fn inlineKey(_: Self, key: K, offset: usize) u64 {
            const bytes = @bitSizeOf(K) / 8;
            if (offset >= bytes) return 0;
            const I = @Int(.unsigned, @bitSizeOf(K));
            var bits: I = @bitCast(key);
            if (@typeInfo(K).int.signedness == .signed) {
                bits ^= @as(I, 1) << (@bitSizeOf(K) - 1);
            }
            // The encoding is the integer's big-endian bytes, zero-padded
            // past its end. Widened to 16 bytes and shifted, the window at
            // `offset` is one shift pair, with no buffer in between.
            const encoded: u128 = @as(u128, bits) << (8 * (16 - bytes));
            return @truncate((encoded << @intCast(8 * offset)) >> 64);
        }
    };
}

/// A `Context` for `[]const u8` keys, ordered by `mem.order` and encoded
/// as their own bytes.
pub const BytesContext = struct {
    /// Four bytes: byte strings share long prefixes and then differ late, so
    /// a two-byte window ties far more often than it saves in cache lines.
    pub const inline_width: u16 = 4;

    /// Thirty-one keys per node: a heap key's comparison is the expensive
    /// part, so the tree trades node size for one fewer level.
    pub const node_max: u16 = 31;

    /// Compare eight bytes at a time as big-endian words instead of calling
    /// `memcmp`: keys are short, and the call is not inlined.
    pub fn compare(_: BytesContext, a: []const u8, b: []const u8) Order {
        return compareBytes(a, b);
    }

    pub fn inlineKey(_: BytesContext, key: []const u8, offset: usize) u64 {
        return bytesWindow(key, offset);
    }

    /// Compare past the bytes a window already showed equal. The empty
    /// suffixes of two keys that both end before `offset` do not decide;
    /// the map falls back to `compare`, which does.
    pub fn compareFrom(_: BytesContext, a: []const u8, b: []const u8, offset: usize) Order {
        return compareBytes(a[@min(offset, a.len)..], b[@min(offset, b.len)..]);
    }

    /// The length of the key's encoding.
    pub fn encodedLen(_: BytesContext, key: []const u8) usize {
        return key.len;
    }
};

/// Lexicographic order over `u8` slices, eight bytes at a time, with the
/// final short tail zero-padded and the length as the tie-break.
pub fn compareBytes(a: []const u8, b: []const u8) Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        const aw = mem.readInt(u64, a[i..][0..8], .big);
        const bw = mem.readInt(u64, b[i..][0..8], .big);
        if (aw != bw) return if (aw < bw) .lt else .gt;
    }
    if (i < n) {
        const aw = bytesWindow(a[i..], 0);
        const bw = bytesWindow(b[i..], 0);
        if (aw != bw) return if (aw < bw) .lt else .gt;
    }
    return math.order(a.len, b.len);
}

/// An ordered map for integer keys.
pub fn Auto(comptime K: type, comptime V: type) type {
    return Custom(K, V, AutoContext(K), .{});
}

/// An ordered map for `[]const u8` keys. Key memory is managed by the
/// caller, and must stay alive while the map holds it.
pub fn String(comptime V: type) type {
    return Custom([]const u8, V, BytesContext, .{});
}

test "empty map" {
    var map: Auto(u64, u64) = .empty;
    defer map.clearAndFree(testing.allocator);
    try testing.expect(map.isEmpty());
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expectEqual(@as(?u64, null), map.get(1));
    try testing.expect(map.first() == null);
    try map.checkInvariants();
}

test "put, get, overwrite" {
    const gpa = testing.allocator;
    var map: Auto(u64, u64) = .empty;
    defer map.clearAndFree(gpa);
    try map.put(gpa, 3, 30);
    try map.put(gpa, 1, 10);
    try map.put(gpa, 2, 20);
    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqual(@as(?u64, 10), map.get(1));
    try testing.expectEqual(@as(?u64, 20), map.get(2));
    try testing.expectEqual(@as(?u64, 30), map.get(3));
    try testing.expectEqual(@as(?u64, null), map.get(4));
    try testing.expectEqual(@as(?u64, 20), try map.fetchPut(gpa, 2, 200));
    try testing.expectEqual(@as(?u64, 200), map.get(2));
    try testing.expectEqual(@as(usize, 3), map.count());
    try map.checkInvariants();
}

test "iterate in order" {
    const gpa = testing.allocator;
    var map: Auto(u32, u32) = .empty;
    defer map.clearAndFree(gpa);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) try map.put(gpa, i * 7 % 1000, i);
    var it = map.iterator();
    var expected: u32 = 0;
    var seen: usize = 0;
    while (it.next()) |entry| {
        try testing.expectEqual(expected, entry.key_ptr.*);
        try testing.expectEqual(entry.key_ptr.*, entry.value_ptr.* * 7 % 1000);
        expected += 1;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1000), seen);
    try map.checkInvariants();
}

test "iterate from a key" {
    const gpa = testing.allocator;
    var map: Auto(u32, u32) = .empty;
    defer map.clearAndFree(gpa);
    for (0..100) |i| try map.put(gpa, @intCast(i * 2), @intCast(i));

    var it = map.iteratorFrom(40, true);
    var expected: u32 = 40;
    while (it.next()) |entry| {
        try testing.expectEqual(expected, entry.key_ptr.*);
        expected += 2;
    }
    try testing.expectEqual(@as(u32, 200), expected);

    it = map.iteratorFrom(40, false);
    try testing.expectEqual(@as(u32, 42), it.next().?.key_ptr.*);

    // A key between two stored keys starts at the next one.
    it = map.iteratorFrom(41, true);
    try testing.expectEqual(@as(u32, 42), it.next().?.key_ptr.*);

    // Past the last key there is nothing.
    it = map.iteratorFrom(1000, true);
    try testing.expect(it.next() == null);
}

test "remove" {
    const gpa = testing.allocator;
    var map: Auto(u64, u64) = .empty;
    defer map.clearAndFree(gpa);
    for (0..500) |k| try map.put(gpa, k * 3, k);
    try testing.expect(map.remove(gpa, 3));
    try testing.expect(!map.remove(gpa, 3));
    try testing.expectEqual(@as(?u64, null), map.get(3));
    try testing.expectEqual(@as(usize, 499), map.count());
    // Drain from both ends and the middle.
    var k: u64 = 0;
    while (k < 500) : (k += 1) {
        if (k % 2 == 0) try testing.expect(map.remove(gpa, k * 3));
    }
    try map.checkInvariants();
    k = 0;
    while (k < 500) : (k += 1) {
        if (k % 2 == 1 and k != 1) try testing.expect(map.remove(gpa, k * 3));
    }
    try testing.expect(map.isEmpty());
    try testing.expect(map.last() == null);
    try map.checkInvariants();
}

test "signed keys order numerically" {
    const gpa = testing.allocator;
    var map: Auto(i64, i64) = .empty;
    defer map.clearAndFree(gpa);
    const keys = [_]i64{ -5, -1, math.minInt(i64), 0, 1, math.maxInt(i64), -1_000_000 };
    for (keys) |k| try map.put(gpa, k, k);
    var it = map.iterator();
    var previous: ?i64 = null;
    while (it.next()) |entry| {
        if (previous) |p| try testing.expect(p < entry.key_ptr.*);
        previous = entry.key_ptr.*;
    }
    try testing.expectEqual(@as(?i64, math.minInt(i64)), map.first().?.key_ptr.*);
    try testing.expectEqual(@as(?i64, math.maxInt(i64)), map.last().?.key_ptr.*);
    try map.checkInvariants();
}

test "u128 keys order numerically" {
    const gpa = testing.allocator;
    var map: Auto(u128, u32) = .empty;
    defer map.clearAndFree(gpa);
    const keys = [_]u128{ 0, 1, 1 << 64, (1 << 64) + 1, math.maxInt(u128), 1 << 100 };
    for (keys, 0..) |k, i| try map.put(gpa, k, @intCast(i));
    try testing.expectEqual(@as(?u32, 3), map.get((1 << 64) + 1));
    var it = map.iterator();
    try testing.expectEqual(@as(u128, 0), it.next().?.key_ptr.*);
    try testing.expectEqual(@as(u128, 1), it.next().?.key_ptr.*);
    try testing.expectEqual(@as(u128, 1 << 64), it.next().?.key_ptr.*);
    try map.checkInvariants();
}

test "string keys with a long shared prefix" {
    const gpa = testing.allocator;
    var map: String(u32) = .empty;
    defer map.clearAndFree(gpa);
    var storage: [512][48]u8 = undefined;
    var lens: [512]usize = undefined;
    for (0..512) |i| {
        const key = try std.fmt.bufPrint(&storage[i], "srv/2026/10/25/requests/item-{d:0>6}", .{i});
        lens[i] = key.len;
        try map.put(gpa, key, @intCast(i));
    }
    try map.checkInvariants();
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        try testing.expectEqual(storage[i][0..lens[i]], entry.key_ptr.*);
        try testing.expectEqual(@as(u32, @intCast(i)), entry.value_ptr.*);
    }
    try testing.expectEqual(@as(usize, 512), i);
}

test "a context without inline keys still orders" {
    const gpa = testing.allocator;
    const plain = struct {
        const Self = @This();
        fn compare(_: Self, a: u64, b: u64) Order {
            return math.order(a, b);
        }
    };
    var map: Custom(u64, u64, plain, .{}) = .empty;
    defer map.clearAndFree(gpa);
    for (0..300) |k| try map.put(gpa, k * 11 % 300, k);
    for (0..300) |k| try testing.expectEqual(@as(?u64, k), map.get(k * 11 % 300));
    try map.checkInvariants();
}

test "everything ties: windows decide nothing" {
    const gpa = testing.allocator;
    const ties = struct {
        const Self = @This();
        fn compare(_: Self, a: u64, b: u64) Order {
            return math.order(a, b);
        }
        fn inlineKey(_: Self, _: u64, _: usize) u64 {
            return 0;
        }
    };
    var map: Custom(u64, u64, ties, .{}) = .empty;
    defer map.clearAndFree(gpa);
    for (0..400) |k| try map.put(gpa, k * 37 % 400, k);
    for (0..400) |k| try testing.expectEqual(@as(?u64, k), map.get(k * 37 % 400));
    for (0..400) |k| if (k % 3 == 0) try testing.expect(map.remove(gpa, k * 37 % 400));
    try map.checkInvariants();
}

test "V = void acts as a set" {
    const gpa = testing.allocator;
    var set: Auto(u32, void) = .empty;
    defer set.clearAndFree(gpa);
    for (0..500) |i| if (i % 3 == 0) try set.put(gpa, @intCast(i), {});
    try testing.expect(set.get(300) != null);
    try testing.expect(set.get(301) == null);
    try testing.expect(set.remove(gpa, 300));
    try testing.expectEqual(@as(usize, 166), set.count());
    try set.checkInvariants();
}

test "random operations match a reference" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x12345678);
    const random = prng.random();
    for (0..8) |round| {
        var map: Auto(u32, u32) = .empty;
        defer map.clearAndFree(gpa);
        var reference: std.AutoHashMap(u32, u32) = .init(gpa);
        defer reference.deinit();
        for (0..20_000) |_| {
            const key = random.uintLessThan(u32, 2000);
            switch (random.uintLessThan(u8, 4)) {
                0, 1, 2 => {
                    const value = random.int(u32);
                    try map.put(gpa, key, value);
                    try reference.put(key, value);
                },
                else => {
                    try testing.expectEqual(reference.remove(key), map.remove(gpa, key));
                },
            }
            if (round % 2 == 1 and random.uintLessThan(u8, 16) == 0) try map.checkInvariants();
        }
        try map.checkInvariants();
        try testing.expectEqual(reference.count(), map.count());
        var expected_keys: std.ArrayList(u32) = .empty;
        defer expected_keys.deinit(gpa);
        var reference_it = reference.keyIterator();
        while (reference_it.next()) |key_ptr| try expected_keys.append(gpa, key_ptr.*);
        mem.sort(u32, expected_keys.items, {}, std.sort.asc(u32));
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            try testing.expectEqual(expected_keys.items[i], entry.key_ptr.*);
            try testing.expectEqual(reference.get(entry.key_ptr.*).?, entry.value_ptr.*);
        }
        try testing.expectEqual(expected_keys.items.len, i);
    }
}

test "allocation failure leaves no leak" {
    const Worker = struct {
        fn run(gpa: Allocator, seed: u64) !void {
            var map: Auto(u32, u32) = .empty;
            defer map.clearAndFree(gpa);
            var state = seed;
            for (0..300) |_| {
                state = state *% 6364136223846793005 +% 1442695040888963407;
                const key: u32 = @truncate(state >> 33);
                switch (state >> 60) {
                    0 => _ = map.remove(gpa, key),
                    else => try map.put(gpa, key, key),
                }
            }
        }
    };
    const seed = 0x9e3779b97f4a7c15;
    try testing.checkAllAllocationFailures(testing.allocator, Worker.run, .{seed});
}

test "pointer stability guard" {
    const gpa = testing.allocator;
    var map: Auto(u32, u32) = .empty;
    defer map.clearAndFree(gpa);
    try map.put(gpa, 1, 1);

    map.pointer_stability.assertUnlocked();
    map.lockPointers();
    map.lockPointers();
    map.pointer_stability.assertLockedShared();
    // `put` here would assert; a panic ends the process, so the lock state is
    // the observable part. The panic itself was checked by hand with a locked
    // insert: it names assertUnlocked and getOrPut in the backtrace.
    map.unlockPointers();
    map.unlockPointers();
    map.pointer_stability.assertUnlocked();

    // Locked state is checked even when no pointers exist.
    try map.put(gpa, 2, 2);
    try testing.expectEqual(@as(?u32, 2), map.get(2));
}

// --- fuzzing ---

// The bbtree convention: a fixed op sequence per input, decoded from one
// Smith buffer, run against a sorted array. The arrays are deliberately dumb
// and the key spaces deliberately small, so overwrites, splits, merges and
// stale separators happen constantly. After every operation the target checks
// the whole tree's invariants, every key, and the full iteration order.

/// A sorted array of the same entries: the oracle.
fn Oracle(comptime K: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const context: Context = .{};

        entries: [fuzz_key_space]Element = undefined,
        len: usize = 0,

        const Element = struct { key: K, value: u32 };
        const Found = struct { pos: usize, found: bool };

        fn seek(self: *const Self, key: K) Found {
            var lo: usize = 0;
            var hi = self.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (context.compare(self.entries[mid].key, key)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return .{ .pos = mid, .found = true },
                }
            }
            return .{ .pos = lo, .found = false };
        }

        fn get(self: *const Self, key: K) ?u32 {
            const found = self.seek(key);
            return if (found.found) self.entries[found.pos].value else null;
        }

        fn put(self: *Self, key: K, value: u32) ?u32 {
            const found = self.seek(key);
            if (found.found) {
                const previous = self.entries[found.pos].value;
                self.entries[found.pos].value = value;
                return previous;
            }
            var i = self.len;
            while (i > found.pos) : (i -= 1) self.entries[i] = self.entries[i - 1];
            self.entries[found.pos] = .{ .key = key, .value = value };
            self.len += 1;
            return null;
        }

        fn remove(self: *Self, key: K) ?u32 {
            const found = self.seek(key);
            if (!found.found) return null;
            const previous = self.entries[found.pos].value;
            var i = found.pos;
            while (i + 1 < self.len) : (i += 1) self.entries[i] = self.entries[i + 1];
            self.len -= 1;
            return previous;
        }
    };
}

const fuzz_key_space = 64;
const fuzz_op_count = 96;
const fuzz_bytes = fuzz_op_count * 3;

fn fuzzIntKeys(_: void, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var bytes: [fuzz_bytes]u8 = undefined;
    smith.bytes(&bytes);

    var map: Auto(u16, u32) = .empty;
    defer map.clearAndFree(gpa);
    var oracle: Oracle(u16, AutoContext(u16)) = .{};

    var i: usize = 0;
    while (i < fuzz_op_count) : (i += 1) {
        const op = bytes[i * 3];
        const key: u16 = @as(u16, bytes[i * 3 + 1]) % fuzz_key_space;
        const value: u32 = @as(u32, bytes[i * 3 + 1]) << 8 | bytes[i * 3 + 2];
        switch (op % 6) {
            0, 1, 2 => {
                const previous = try map.fetchPut(gpa, key, value);
                try testing.expectEqual(oracle.put(key, value), previous);
            },
            3, 4 => try testing.expectEqual(oracle.remove(key), map.fetchRemove(gpa, key)),
            else => try testing.expectEqual(oracle.get(key), map.get(key)),
        }

        try map.checkInvariants();
        try testing.expectEqual(oracle.len, map.count());
        for (0..fuzz_key_space) |k| {
            try testing.expectEqual(oracle.get(@intCast(k)), map.get(@intCast(k)));
        }
        var it = map.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) {
            try testing.expect(index < oracle.len);
            try testing.expectEqual(oracle.entries[index].key, entry.key_ptr.*);
            try testing.expectEqual(oracle.entries[index].value, entry.value_ptr.*);
        }
        try testing.expectEqual(oracle.len, index);
    }
}

fn fuzzStringKeys(_: void, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var bytes: [fuzz_bytes]u8 = undefined;
    smith.bytes(&bytes);

    // Keys share a "srv/" prefix and then carry raw bytes, so windows tie,
    // prefix stripping kicks in, and keys of every short length appear.
    var pool_storage: [fuzz_key_space][16]u8 = undefined;
    var pool: [fuzz_key_space][]const u8 = undefined;
    for (0..fuzz_key_space) |k| {
        const tail = bytes[k] % (pool_storage[k].len - 4);
        @memcpy(pool_storage[k][0..4], "srv/");
        for (4..4 + tail) |j| pool_storage[k][j] = bytes[(k * 7 + j) % fuzz_bytes];
        pool[k] = pool_storage[k][0 .. 4 + tail];
    }

    var map: String(u32) = .empty;
    defer map.clearAndFree(gpa);
    var oracle: Oracle([]const u8, BytesContext) = .{};

    var i: usize = 0;
    while (i < fuzz_op_count) : (i += 1) {
        const op = bytes[i * 3];
        const key = pool[bytes[i * 3 + 1] % fuzz_key_space];
        const value: u32 = @as(u32, bytes[i * 3 + 1]) << 8 | bytes[i * 3 + 2];
        switch (op % 6) {
            0, 1, 2 => {
                const previous = try map.fetchPut(gpa, key, value);
                try testing.expectEqual(oracle.put(key, value), previous);
            },
            3, 4 => try testing.expectEqual(oracle.remove(key), map.fetchRemove(gpa, key)),
            else => try testing.expectEqual(oracle.get(key), map.get(key)),
        }

        try map.checkInvariants();
        try testing.expectEqual(oracle.len, map.count());
        for (pool) |probe| {
            try testing.expectEqual(oracle.get(probe), map.get(probe));
        }
        var it = map.iterator();
        var index: usize = 0;
        while (it.next()) |entry| : (index += 1) {
            try testing.expect(index < oracle.len);
            try testing.expectEqualStrings(oracle.entries[index].key, entry.key_ptr.*);
            try testing.expectEqual(oracle.entries[index].value, entry.value_ptr.*);
        }
        try testing.expectEqual(oracle.len, index);

        // The range iterator starts where the oracle's lower bound does.
        const start_key = pool[bytes[i * 3 + 2] % fuzz_key_space];
        var tail = map.iteratorFrom(start_key, true);
        var from: usize = 0;
        while (from < oracle.len and compareBytes(oracle.entries[from].key, start_key) == .lt) {
            from += 1;
        }
        var tail_index = from;
        while (tail.next()) |entry| : (tail_index += 1) {
            try testing.expect(tail_index < oracle.len);
            try testing.expectEqualStrings(oracle.entries[tail_index].key, entry.key_ptr.*);
        }
        try testing.expectEqual(oracle.len, tail_index);
    }
}

fn fuzzTiedWindows(_: void, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const ties = struct {
        const Self = @This();
        fn compare(_: Self, a: u16, b: u16) Order {
            return std.math.order(a, b);
        }
        /// Every window ties: the tie path decides everything.
        fn inlineKey(_: Self, _: u16, _: usize) u64 {
            return 0;
        }
    };
    var bytes: [fuzz_bytes]u8 = undefined;
    smith.bytes(&bytes);

    var map: Custom(u16, u32, ties, .{}) = .empty;
    defer map.clearAndFree(gpa);
    var oracle: Oracle(u16, ties) = .{};

    var i: usize = 0;
    while (i < fuzz_op_count) : (i += 1) {
        const op = bytes[i * 3];
        const key: u16 = @as(u16, bytes[i * 3 + 1]) % fuzz_key_space;
        const value: u32 = @as(u32, bytes[i * 3 + 1]) << 8 | bytes[i * 3 + 2];
        switch (op % 6) {
            0, 1, 2 => {
                const previous = try map.fetchPut(gpa, key, value);
                try testing.expectEqual(oracle.put(key, value), previous);
            },
            3, 4 => try testing.expectEqual(oracle.remove(key), map.fetchRemove(gpa, key)),
            else => try testing.expectEqual(oracle.get(key), map.get(key)),
        }
        try map.checkInvariants();
        try testing.expectEqual(oracle.len, map.count());
        for (0..fuzz_key_space) |k| {
            try testing.expectEqual(oracle.get(@intCast(k)), map.get(@intCast(k)));
        }
    }
}

test "fuzz: integer keys against a sorted array" {
    try testing.fuzz({}, fuzzIntKeys, .{});
}

test "fuzz: string keys against a sorted array" {
    try testing.fuzz({}, fuzzStringKeys, .{});
}

test "fuzz: every window ties" {
    try testing.fuzz({}, fuzzTiedWindows, .{});
}

test "short keys sort past a stripped prefix" {
    const gpa = testing.allocator;
    var map: String(u32) = .empty;
    defer map.clearAndFree(gpa);
    // The node's prefix is "srv/", so windows start at byte 4. "srv/abc" is
    // shorter than one window past that prefix: its window must be its own
    // last bytes padded, not the prefix again.
    try map.put(gpa, "srv/abc", 1);
    try map.put(gpa, "srv/Q\xe7\x8a\x91#\xf0\x83\xc6\xd7", 2);
    try testing.expectEqual(@as(?u32, 1), map.get("srv/abc"));
    try testing.expectEqual(@as(?u32, 2), map.get("srv/Q\xe7\x8a\x91#\xf0\x83\xc6\xd7"));
    try testing.expectEqual(@as(?u32, null), map.get("srv/xyz"));
    try testing.expectEqual(@as(?u32, null), map.get("srv/aa"));
}

test "lookups outside the key range" {
    const gpa = testing.allocator;
    // A key below the smallest or above the largest does not share the
    // prefix the windows are taken at, so it can route anywhere. It cannot
    // equal a stored key, so the answer is still "absent".
    var map: String(u32) = .empty;
    defer map.clearAndFree(gpa);
    try map.put(gpa, "m/bbb", 1);
    try map.put(gpa, "m/yyy", 2);
    try testing.expectEqual(@as(?u32, 1), map.get("m/bbb"));
    try testing.expectEqual(@as(?u32, 2), map.get("m/yyy"));
    const probes = [_][]const u8{
        "", "a", "m", "m/", "m/aaa", "m/zzz", "m/yyy0", "m/\xff", "n", "z",
    };
    for (probes) |probe| {
        try testing.expectEqual(@as(?u32, null), map.get(probe));
        try testing.expect(map.getPtr(probe) == null);
    }
}

test "keys shorter than a window keep their place past a stripped prefix" {
    const gpa = testing.allocator;
    // Regression: a key shorter than one window, in a node whose stripped
    // prefix is not empty, took its window from the prefix bytes instead of
    // from past them. The stored windows stopped being monotone, and a
    // search for a key that was not there landed one key too far.
    const keys = [_][]const u8{
        "srv/",
        "srv/+s\xc1\x80\xb4\x8cU\xc0<\xf7\x1d",
        "srv/Q\xe7\x8a\x91#\xf0\x83\xc6\xd7",
        "srv/t",
        "srv/\xa65",
        "srv/\xc3\xc5\x02\xfb\x08, \x0c\xdf",
    };
    var map: String(u32) = .empty;
    defer map.clearAndFree(gpa);
    for (keys, 0..) |key, i| try map.put(gpa, key, @intCast(i));

    var it = map.iteratorFrom("srv/I", true);
    try testing.expectEqualStrings(keys[2], it.next().?.key_ptr.*);
    for (keys, 0..) |key, i| {
        try testing.expectEqual(@as(?u32, @intCast(i)), map.get(key));
    }
}

test "iterate from a key outside the range" {
    const gpa = testing.allocator;
    // Regression: a start key below the smallest key does not share the
    // prefix the windows are taken at, so its search position means nothing.
    // Both ends answer without searching.
    var map: String(u32) = .empty;
    defer map.clearAndFree(gpa);
    try map.put(gpa, "srv/\xf8(", 0);
    try map.put(gpa, "srv/\xf8\xec\xa8\x58\xcd\x63\x9b\x9c", 1);

    var it = map.iteratorFrom("srv/\x02\xb2Y\x94\xc6\x19\xb6n", true);
    try testing.expectEqualStrings("srv/\xf8(", it.next().?.key_ptr.*);
    try testing.expectEqualStrings("srv/\xf8\xec\xa8\x58\xcd\x63\x9b\x9c", it.next().?.key_ptr.*);
    try testing.expect(it.next() == null);

    var above = map.iteratorFrom("srv/\xff", true);
    try testing.expect(above.next() == null);

    var exclusive = map.iteratorFrom("srv/\xf8\xec\xa8\x58\xcd\x63\x9b\x9c", false);
    try testing.expect(exclusive.next() == null);

    var inclusive = map.iteratorFrom("srv/\xf8\xec\xa8\x58\xcd\x63\x9b\x9c", true);
    const last = inclusive.next().?;
    try testing.expectEqualStrings("srv/\xf8\xec\xa8\x58\xcd\x63\x9b\x9c", last.key_ptr.*);
}
