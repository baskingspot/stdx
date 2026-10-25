//! The ordered map behind `stdx.btree`: a B+tree of cache-sized nodes with
//! inline keys and per-node prefix stripping.
//!
//! # Shape
//!
//! Leaves hold the entries; internal nodes hold separator keys and child
//! pointers, one more child than keys. `key[i-1] <= k < key[i]` routes to
//! child `i`, and the separator `key[i]` is a copy of the smallest key in
//! child `i+1` at the time it was written. Removal leaves separators stale
//! (smaller than the real bound), which keeps routing correct and only costs
//! prefix quality.
//!
//! ```text
//! leaf     | len prefix | windows | (k v) (k v) ... |
//! internal | len prefix | windows | k k ... | child child ... |
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
    /// `(max - 1) / 2` keys on each side with the middle one promoted.
    max: u16 = 15,
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
            if (config.max < 3 or config.max % 2 == 0)
                @compileError("btree.Config.max must be odd and at least 3");
            switch (config.width orelse 2) {
                2, 4, 8 => {},
                else => @compileError("btree.Config.width must be 2, 4 or 8"),
            }
            if (!@hasDecl(Context, "compare"))
                @compileError("btree: Context must declare " ++
                    "`pub fn compare(self: Context, a: K, b: K) math.Order`");
        }

        /// Maximum keys per node.
        const max: usize = config.max;
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

        const Leaf = struct {
            len: u32,
            prefix_len: u16,
            windows: Windows,
            elements: [max]Element,
        };

        const Node = union(enum) {
            leaf: *Leaf,
            internal: *Internal,
        };

        const Internal = struct {
            len: u32,
            prefix_len: u16,
            windows: Windows,
            keys: [max]K,
            children: [max + 1]Node,
        };

        /// Number of entries in the map.
        used: usize,
        /// Root node, or null when the map is empty.
        root: ?Node,
        /// Debug and ReleaseSafe only: while a borrow is outstanding, every
        /// call that can move or free an entry asserts instead.
        pointer_stability: stability.SafetyLock = .{},
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
            while (true) switch (node) {
                .leaf => |leaf| {
                    const found = self.searchLeaf(leaf, key);
                    if (!found.found) return null;
                    return &leaf.elements[found.pos].value;
                },
                .internal => |in| node = in.children[self.searchInternal(in, key)],
            };
        }

        /// Pointer to the value stored for `key`; when absent, inserts `key`
        /// with an undefined value and reports `found_existing = false`. The
        /// caller must initialize `value_ptr` in that case.
        pub fn getOrPut(self: *Self, gpa: Allocator, key: K) !GetOrPutResult {
            self.pointer_stability.assertUnlocked();
            if (self.root == null) {
                const leaf = try createLeaf(gpa);
                leaf.elements[0].key = key;
                leaf.len = 1;
                self.lowest = key;
                self.highest = key;
                self.refit(.{ .leaf = leaf }, .{ .low = key, .high = key });
                self.root = .{ .leaf = leaf };
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
            var outer: Fences = .{ .low = self.lowest, .high = self.highest };
            while (true) switch (node) {
                .leaf => |leaf| {
                    const found = self.searchLeaf(leaf, key);
                    if (found.found) return .{
                        .key_ptr = &leaf.elements[found.pos].key,
                        .value_ptr = &leaf.elements[found.pos].value,
                        .found_existing = true,
                    };
                    assert(leaf.len < max); // the descent splits full children
                    const pos = found.pos;
                    self.insertElement(leaf, pos, key, undefined);
                    self.used += 1;
                    return .{
                        .key_ptr = &leaf.elements[pos].key,
                        .value_ptr = &leaf.elements[pos].value,
                        .found_existing = false,
                    };
                },
                .internal => |in| {
                    var idx = self.searchInternal(in, key);
                    var child = in.children[idx];
                    if (isFull(child)) {
                        try self.splitChild(gpa, in, idx, childFences(in, idx, outer));
                        if (self.compare(key, in.keys[idx]) != .lt) idx += 1;
                        child = in.children[idx];
                    }
                    node = child;
                    outer = childFences(in, idx, outer);
                },
            };
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
            var outer: Fences = .{ .low = self.lowest, .high = self.highest };
            while (true) switch (node) {
                .leaf => |leaf| {
                    const found = self.searchLeaf(leaf, key);
                    if (!found.found) return null;
                    const value = leaf.elements[found.pos].value;
                    self.removeElement(leaf, found.pos);
                    self.used -= 1;
                    self.rebalanceUp(gpa, path[0..depth]);
                    self.fixRoot(gpa);
                    self.noteRemoved(key);
                    return value;
                },
                .internal => |in| {
                    const idx = self.searchInternal(in, key);
                    assert(depth < max_depth);
                    path[depth] = .{ .node = node, .index = idx, .fences = outer };
                    depth += 1;
                    node = in.children[idx];
                    outer = childFences(in, idx, outer);
                },
            };
        }

        /// Remove every entry and free every node.
        pub fn clearAndFree(self: *Self, gpa: Allocator) void {
            self.pointer_stability.assertUnlocked();
            if (self.root) |root| self.destroyNode(gpa, root);
            self.root = null;
            self.used = 0;
            self.lowest = null;
            self.highest = null;
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
            while (true) switch (node) {
                .leaf => |leaf| {
                    const found = self.searchLeaf(leaf, key);
                    const start = found.pos + @intFromBool(found.found and !inclusive);
                    it.frames[it.depth] = .{ .node = node, .index = start };
                    it.depth += 1;
                    return it;
                },
                .internal => |in| {
                    const idx = self.searchInternal(in, key);
                    it.frames[it.depth] = .{ .node = node, .index = idx };
                    it.depth += 1;
                    node = in.children[idx];
                },
            };
        }

        /// The smallest entry, or null.
        pub fn first(self: *const Self) ?Entry {
            var it = self.iterator();
            return it.next();
        }

        /// The largest entry, or null.
        pub fn last(self: *const Self) ?Entry {
            var node = self.root orelse return null;
            while (true) switch (node) {
                .leaf => |leaf| return .{
                    .key_ptr = &leaf.elements[leaf.len - 1].key,
                    .value_ptr = &leaf.elements[leaf.len - 1].value,
                },
                .internal => |in| node = in.children[in.len],
            };
        }

        /// `key`'s window at `prefix`, truncated to the node layout's width.
        fn windowOf(self: *const Self, key: K, prefix: usize) Word {
            const window = self.context.inlineKey(key, prefix);
            const shift: u6 = @intCast(64 - @as(u32, width) * 8);
            return @truncate(window >> shift);
        }

        const Found = struct { pos: usize, found: bool };

        fn searchLeaf(self: *const Self, leaf: *const Leaf, key: K) Found {
            const n: usize = leaf.len;
            if (comptime !has_windows) {
                return binarySearchLeaf(self, leaf, 0, n, key);
            } else {
                const target = self.windowOf(key, leaf.prefix_len);
                const less = countLess(&leaf.windows, target);
                if (less == n or leaf.windows[less] != target) {
                    return .{ .pos = less, .found = false };
                }
                const leq = countLeq(&leaf.windows, target, n);
                const tie_offset = @as(usize, leaf.prefix_len) + width;
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
            const tie_offset = @as(usize, leaf.prefix_len) + width;
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
        /// below `key`.
        fn searchInternal(self: *const Self, in: *const Internal, key: K) usize {
            const n: usize = in.len;
            if (comptime !has_windows) {
                return upperBound(self, in, 0, n, key);
            } else {
                const target = self.windowOf(key, in.prefix_len);
                const less = countLess(&in.windows, target);
                if (less == n or in.windows[less] != target) return less;
                const leq = countLeq(&in.windows, target, n);
                const tie_offset = @as(usize, in.prefix_len) + width;
                if (leq - less == 1) {
                    const order = self.compareFrom(in.keys[less], key, tie_offset);
                    return if (order == .gt) less else less + 1;
                }
                return upperBound(self, in, less, leq, key);
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
            const tie_offset = @as(usize, in.prefix_len) + width;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (self.compareFrom(in.keys[mid], key, tie_offset)) {
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

        fn isFull(node: Node) bool {
            return switch (node) {
                .leaf => |leaf| leaf.len == max,
                .internal => |in| in.len == max,
            };
        }

        fn fill(node: Node) usize {
            return switch (node) {
                .leaf => |leaf| leaf.len,
                .internal => |in| in.len,
            };
        }

        fn insertElement(self: *Self, leaf: *Leaf, pos: usize, key: K, value: V) void {
            const n: usize = leaf.len;
            var i = n;
            while (i > pos) : (i -= 1) {
                leaf.elements[i] = leaf.elements[i - 1];
                if (comptime has_windows) leaf.windows[i] = leaf.windows[i - 1];
            }
            leaf.elements[pos] = .{ .key = key, .value = value };
            if (comptime has_windows) leaf.windows[pos] = self.windowOf(key, leaf.prefix_len);
            leaf.len = @intCast(n + 1);
        }

        fn removeElement(self: *Self, leaf: *Leaf, pos: usize) void {
            _ = self;
            const n: usize = leaf.len;
            var i = pos;
            while (i + 1 < n) : (i += 1) {
                leaf.elements[i] = leaf.elements[i + 1];
                if (comptime has_windows) leaf.windows[i] = leaf.windows[i + 1];
            }
            if (comptime has_windows) leaf.windows[n - 1] = pad;
            leaf.len = @intCast(n - 1);
        }

        /// Insert `sep` and `child` at `idx` into an internal node that has
        /// room, shifting the rest right.
        fn insertSeparator(self: *Self, in: *Internal, idx: usize, sep: K, child: Node) void {
            const n: usize = in.len;
            var i = n;
            while (i > idx) : (i -= 1) {
                in.keys[i] = in.keys[i - 1];
                in.children[i + 1] = in.children[i];
                if (comptime has_windows) in.windows[i] = in.windows[i - 1];
            }
            in.keys[idx] = sep;
            in.children[idx + 1] = child;
            if (comptime has_windows) in.windows[idx] = self.windowOf(sep, in.prefix_len);
            in.len = @intCast(n + 1);
        }

        /// Replace separator `idx`, keeping its window in step with the node.
        fn setSeparator(self: *Self, in: *Internal, idx: usize, sep: K) void {
            in.keys[idx] = sep;
            if (comptime has_windows) {
                in.windows[idx] = self.windowOf(sep, in.prefix_len);
            }
        }

        /// Remove separator `idx` and child `idx + 1` from an internal node.
        fn removeSeparator(self: *Self, in: *Internal, idx: usize) void {
            _ = self;
            const n: usize = in.len;
            var i = idx;
            while (i + 1 < n) : (i += 1) {
                in.keys[i] = in.keys[i + 1];
                in.children[i + 1] = in.children[i + 2];
                if (comptime has_windows) in.windows[i] = in.windows[i + 1];
            }
            if (comptime has_windows) in.windows[n - 1] = pad;
            in.len = @intCast(n - 1);
        }

        fn createLeaf(gpa: Allocator) !*Leaf {
            const leaf = try gpa.create(Leaf);
            leaf.len = 0;
            leaf.prefix_len = 0;
            if (comptime has_windows) @memset(leaf.windows[0..], pad);
            return leaf;
        }

        fn createInternal(gpa: Allocator) !*Internal {
            const in = try gpa.create(Internal);
            in.len = 0;
            in.prefix_len = 0;
            if (comptime has_windows) @memset(in.windows[0..], pad);
            return in;
        }

        /// Set a node's prefix from its fences and stamp every window.
        fn refit(self: *Self, node: Node, fences: Fences) void {
            var prefix: u16 = 0;
            if (comptime has_windows) {
                if (fences.low != null and fences.high != null) {
                    const low = fences.low.?;
                    const high = fences.high.?;
                    prefix = @intCast(commonPrefix(K, Context, self.context, low, high));
                }
            }
            switch (node) {
                .leaf => |leaf| {
                    const n: usize = leaf.len;
                    leaf.prefix_len = prefix;
                    if (comptime has_windows) {
                        for (0..n) |i| {
                            leaf.windows[i] = self.windowOf(leaf.elements[i].key, prefix);
                        }
                        @memset(leaf.windows[n..], pad);
                    }
                },
                .internal => |in| {
                    const n: usize = in.len;
                    in.prefix_len = prefix;
                    if (comptime has_windows) {
                        for (0..n) |i| in.windows[i] = self.windowOf(in.keys[i], prefix);
                        @memset(in.windows[n..], pad);
                    }
                },
            }
        }

        /// Split a full root into a new root with two children.
        fn splitRoot(self: *Self, gpa: Allocator, old: Node) !Node {
            const root = try createInternal(gpa);
            root.children[0] = old;
            const fences: Fences = .{ .low = self.lowest, .high = self.highest };
            self.refit(.{ .internal = root }, fences);
            self.splitChild(gpa, root, 0, fences) catch |err| {
                gpa.destroy(root);
                return err;
            };
            self.root = .{ .internal = root };
            return self.root.?;
        }

        /// Split `parent.children[idx]` in half, promote the middle key, and
        /// refit both halves from their new fences.
        fn splitChild(
            self: *Self,
            gpa: Allocator,
            parent: *Internal,
            idx: usize,
            fences: Fences,
        ) !void {
            const child = parent.children[idx];
            switch (child) {
                .leaf => |leaf| {
                    const n: usize = leaf.len;
                    const mid = n / 2;
                    const right = try createLeaf(gpa);
                    right.len = @intCast(n - mid);
                    @memcpy(right.elements[0 .. n - mid], leaf.elements[mid..n]);
                    const sep = right.elements[0].key;
                    self.insertSeparator(parent, idx, sep, .{ .leaf = right });
                    self.refit(.{ .leaf = right }, .{ .low = sep, .high = fences.high });
                    leaf.len = @intCast(mid);
                    self.refit(.{ .leaf = leaf }, .{ .low = fences.low, .high = sep });
                },
                .internal => |in| {
                    const n: usize = in.len;
                    const mid = n / 2;
                    const sep = in.keys[mid];
                    const right = try createInternal(gpa);
                    right.len = @intCast(n - mid - 1);
                    @memcpy(right.keys[0 .. n - mid - 1], in.keys[mid + 1 .. n]);
                    @memcpy(right.children[0 .. n - mid], in.children[mid + 1 .. n + 1]);
                    in.len = @intCast(mid);
                    self.insertSeparator(parent, idx, sep, .{ .internal = right });
                    self.refit(.{ .internal = right }, .{ .low = sep, .high = fences.high });
                    self.refit(.{ .internal = in }, .{ .low = fences.low, .high = sep });
                },
            }
        }

        /// One step of a root-to-leaf path: the node and the child to follow.
        /// The keys on either side of a node: its separators in the parent,
        /// or the map's outer fences at the spines.
        const Fences = struct { low: ?K, high: ?K };

        /// One step of a root-to-leaf path: the node, the child to follow,
        /// and the fences around the node.
        const Frame = struct { node: Node, index: usize, fences: Fences };

        /// Fix every node on the path that fell below the minimum fill.
        fn rebalanceUp(self: *Self, gpa: Allocator, path: []const Frame) void {
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const frame = path[i];
                const parent = frame.node.internal;
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
            const n: usize = parent.len;
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

        /// The fences around `parent.children[idx]`: the separators beside it,
        /// or the node's own outer fences at the borders.
        fn childFences(parent: *const Internal, idx: usize, outer: Fences) Fences {
            const n: usize = parent.len;
            return .{
                .low = if (idx > 0) parent.keys[idx - 1] else outer.low,
                .high = if (idx < n) parent.keys[idx] else outer.high,
            };
        }

        /// Move the outer fences out to `key` when it lies outside the tree,
        /// and refit the spine whose fence moved. A fence that is too low (or
        /// too high) only shortens the shared prefix, which stays correct; an
        /// insert that later fails leaves the map with a wider range than its
        /// keys, and the next removal of that extreme recomputes it.
        fn widenExtremes(self: *Self, key: K) void {
            if (self.lowest) |lowest| {
                if (self.compare(key, lowest) == .lt) {
                    self.lowest = key;
                    self.refitSpine(0);
                }
            } else {
                self.lowest = key;
            }
            if (self.highest) |highest| {
                if (self.compare(key, highest) == .gt) {
                    self.highest = key;
                    self.refitSpine(1);
                }
            } else {
                self.highest = key;
            }
        }

        /// Replace a removed extreme with the current one, and refit the
        /// spine whose outer fence moved.
        fn noteRemoved(self: *Self, key: K) void {
            if (self.used == 0) {
                self.lowest = null;
                self.highest = null;
                return;
            }
            var moved_low = false;
            var moved_high = false;
            if (self.lowest) |lowest| {
                if (self.compare(key, lowest) == .eq) {
                    self.lowest = self.extremeKey(0);
                    moved_low = true;
                }
            }
            if (self.highest) |highest| {
                if (self.compare(key, highest) == .eq) {
                    self.highest = self.extremeKey(1);
                    moved_high = true;
                }
            }
            if (moved_low) self.refitSpine(0);
            if (moved_high) self.refitSpine(1);
        }

        /// The smallest (`side = 0`) or largest (`side = 1`) key in the map.
        fn extremeKey(self: *const Self, comptime side: u1) K {
            var node = self.root.?;
            while (true) switch (node) {
                .leaf => |leaf| return if (side == 0)
                    leaf.elements[0].key
                else
                    leaf.elements[leaf.len - 1].key,
                .internal => |in| node = if (side == 0) in.children[0] else in.children[in.len],
            };
        }

        /// Refit every node on the left (`side = 0`) or right spine, whose
        /// outer fence is the tree's extreme key.
        fn refitSpine(self: *Self, comptime side: u1) void {
            var node = self.root orelse return;
            var outer: Fences = .{ .low = self.lowest, .high = self.highest };
            while (true) {
                self.refit(node, outer);
                switch (node) {
                    .leaf => return,
                    .internal => |in| {
                        const idx: usize = if (side == 0) 0 else in.len;
                        node = in.children[idx];
                        outer = childFences(in, idx, outer);
                    },
                }
            }
        }

        /// Move the left sibling's last entry into child `idx`.
        fn borrowFromLeft(self: *Self, parent: *Internal, idx: usize, outer: Fences) void {
            const left = parent.children[idx - 1];
            const child = parent.children[idx];
            const sep_idx = idx - 1;
            switch (child) {
                .leaf => |leaf| {
                    const sibling = left.leaf;
                    const moved = sibling.elements[sibling.len - 1];
                    insertElement(self, leaf, 0, moved.key, moved.value);
                    sibling.len -= 1;
                    const sep = leaf.elements[0].key;
                    self.setSeparator(parent, sep_idx, sep);
                    self.refit(left, childFences(parent, idx - 1, outer));
                    self.refit(child, childFences(parent, idx, outer));
                },
                .internal => |in| {
                    const sibling = left.internal;
                    const moved_key = sibling.keys[sibling.len - 1];
                    const moved_child = sibling.children[sibling.len];
                    const sep = parent.keys[sep_idx];
                    var i: usize = in.len;
                    while (i > 0) : (i -= 1) {
                        in.keys[i] = in.keys[i - 1];
                        in.children[i + 1] = in.children[i];
                    }
                    in.children[1] = in.children[0];
                    in.children[0] = moved_child;
                    in.keys[0] = sep;
                    in.len += 1;
                    sibling.len -= 1;
                    self.setSeparator(parent, sep_idx, moved_key);
                    self.refit(left, childFences(parent, idx - 1, outer));
                    self.refit(child, childFences(parent, idx, outer));
                },
            }
        }

        /// Move the right sibling's first entry into child `idx`.
        fn borrowFromRight(self: *Self, parent: *Internal, idx: usize, outer: Fences) void {
            const child = parent.children[idx];
            const right = parent.children[idx + 1];
            const sep_idx = idx;
            switch (child) {
                .leaf => |leaf| {
                    const sibling = right.leaf;
                    const moved = sibling.elements[0];
                    insertElement(self, leaf, leaf.len, moved.key, moved.value);
                    var i: usize = 0;
                    const n: usize = sibling.len;
                    while (i + 1 < n) : (i += 1) sibling.elements[i] = sibling.elements[i + 1];
                    sibling.len -= 1;
                    self.setSeparator(parent, sep_idx, sibling.elements[0].key);
                    self.refit(child, childFences(parent, idx, outer));
                    self.refit(right, childFences(parent, idx + 1, outer));
                },
                .internal => |in| {
                    const sibling = right.internal;
                    const n: usize = sibling.len;
                    in.keys[in.len] = parent.keys[sep_idx];
                    in.children[in.len + 1] = sibling.children[0];
                    in.len += 1;
                    const moved_key = sibling.keys[0];
                    var i: usize = 0;
                    while (i + 1 < n) : (i += 1) {
                        sibling.keys[i] = sibling.keys[i + 1];
                        sibling.children[i] = sibling.children[i + 1];
                    }
                    sibling.children[n - 1] = sibling.children[n];
                    sibling.len -= 1;
                    self.setSeparator(parent, sep_idx, moved_key);
                    self.refit(child, childFences(parent, idx, outer));
                    self.refit(right, childFences(parent, idx + 1, outer));
                },
            }
        }

        /// Merge children `sep_idx` and `sep_idx + 1`, dropping separator
        /// `sep_idx` from the parent.
        fn merge(
            self: *Self,
            gpa: Allocator,
            parent: *Internal,
            sep_idx: usize,
            outer: Fences,
        ) void {
            const left = parent.children[sep_idx];
            const right = parent.children[sep_idx + 1];
            const merged: Fences = .{
                .low = childFences(parent, sep_idx, outer).low,
                .high = childFences(parent, sep_idx + 1, outer).high,
            };
            switch (left) {
                .leaf => |leaf| {
                    const sibling = right.leaf;
                    const n: usize = leaf.len;
                    const m: usize = sibling.len;
                    @memcpy(leaf.elements[n .. n + m], sibling.elements[0..m]);
                    leaf.len = @intCast(n + m);
                    self.removeSeparator(parent, sep_idx);
                    self.refit(left, merged);
                    gpa.destroy(sibling);
                },
                .internal => |in| {
                    const sibling = right.internal;
                    const n: usize = in.len;
                    const m: usize = sibling.len;
                    in.keys[n] = parent.keys[sep_idx];
                    @memcpy(in.keys[n + 1 .. n + 1 + m], sibling.keys[0..m]);
                    @memcpy(in.children[n + 1 .. n + 2 + m], sibling.children[0 .. m + 1]);
                    in.len = @intCast(n + 1 + m);
                    self.removeSeparator(parent, sep_idx);
                    self.refit(left, merged);
                    gpa.destroy(sibling);
                },
            }
        }

        /// Collapse a root internal node that lost its last separator, and
        /// free an empty root leaf.
        fn fixRoot(self: *Self, gpa: Allocator) void {
            const root = self.root orelse return;
            switch (root) {
                .leaf => |leaf| {
                    if (leaf.len == 0) {
                        gpa.destroy(leaf);
                        self.root = null;
                    }
                },
                .internal => |in| {
                    if (in.len == 0) {
                        self.root = in.children[0];
                        gpa.destroy(in);
                    }
                },
            }
        }

        fn destroyNode(self: *Self, gpa: Allocator, node: Node) void {
            switch (node) {
                .leaf => |leaf| gpa.destroy(leaf),
                .internal => |in| {
                    const n: usize = in.len;
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
                    switch (top.node) {
                        .leaf => |leaf| {
                            if (top.index < leaf.len) {
                                const i = top.index;
                                top.index += 1;
                                return .{
                                    .key_ptr = &leaf.elements[i].key,
                                    .value_ptr = &leaf.elements[i].value,
                                };
                            }
                            self.depth -= 1;
                            if (self.depth > 0) self.frames[self.depth - 1].index += 1;
                        },
                        .internal => |in| {
                            if (top.index > in.len) {
                                self.depth -= 1;
                                if (self.depth > 0) self.frames[self.depth - 1].index += 1;
                                continue;
                            }
                            const child = in.children[top.index];
                            self.descend(child, 0);
                        },
                    }
                }
                return null;
            }

            fn descend(self: *Iterator, node: Node, index: usize) void {
                assert(self.depth < max_depth);
                self.frames[self.depth] = .{ .node = node, .index = index };
                self.depth += 1;
                switch (node) {
                    .leaf => {},
                    .internal => |in| self.descend(in.children[index], 0),
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
            switch (node) {
                .leaf => |leaf| {
                    const n: usize = leaf.len;
                    try testing.expect(n <= max);
                    if (!is_root) try testing.expect(n >= min);
                    try testing.expectEqual(expectedPrefix(self, fences), leaf.prefix_len);
                    for (0..n) |i| {
                        const key = leaf.elements[i].key;
                        if (i > 0) {
                            const order = self.compare(leaf.elements[i - 1].key, key);
                            try testing.expect(order == .lt);
                        }
                        if (fences.low) |l| try testing.expect(self.compare(l, key) != .gt);
                        if (fences.high) |h| try testing.expect(self.compare(key, h) != .gt);
                        if (comptime has_windows) {
                            const window = self.windowOf(key, leaf.prefix_len);
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
                .internal => |in| {
                    const n: usize = in.len;
                    try testing.expect(n <= max);
                    if (is_root) {
                        try testing.expect(n >= 1);
                    } else {
                        try testing.expect(n >= min);
                    }
                    try testing.expectEqual(expectedPrefix(self, fences), in.prefix_len);
                    for (0..n) |i| {
                        if (i > 0) {
                            const order = self.compare(in.keys[i - 1], in.keys[i]);
                            try testing.expect(order == .lt);
                        }
                        if (comptime has_windows) {
                            const window = self.windowOf(in.keys[i], in.prefix_len);
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
            if (fences.low == null or fences.high == null) return 0;
            return @intCast(commonPrefix(K, Context, self.context, fences.low.?, fences.high.?));
        }
    };
}

/// Byte offset of the first byte where `a`'s and `b`'s encodings differ.
fn commonPrefix(comptime K: type, comptime Context: type, context: Context, a: K, b: K) usize {
    var offset: usize = 0;
    while (offset < max_prefix) : (offset += 8) {
        const wa = context.inlineKey(a, offset);
        const wb = context.inlineKey(b, offset);
        if (wa != wb) return offset + @as(usize, @clz(wa ^ wb)) / 8;
    }
    return max_prefix;
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
