//! Prefix maps: a compressed radix tree of byte-string keys, built from a
//! literal at compile time or at runtime.
//!
//! The map answers two questions. `get` is an exact lookup. `getLongestPrefix`
//! returns the value of the longest stored key that is a prefix of the input,
//! which is the shape a route table or a layered config lookup needs.
//!
//! The tree stores one node per branching point or key end. A node carries
//! the bytes shared by every key under it, so a long common prefix costs one
//! node and one compare. Its children are a sorted range in a flat array. The
//! nodes, child edges, prefix bytes, and values are contiguous slices, so a
//! comptime-built map is a constant with no runtime initialization, and a
//! runtime-built map is four allocations.
//!
//! The keys are copied into the tree. The input slices do not need to outlive
//! `init`, and values are copied into the value array.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub fn Map(comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            prefix_off: u32,
            prefix_len: u32,
            value: u32 = none,
            child_off: u32,
            child_len: u32,
        };

        const Child = struct {
            byte: u8,
            node: u32,
        };

        const Entry = struct {
            key: []const u8,
            value: V,
        };

        const none = std.math.maxInt(u32);

        nodes: []const Node,
        children: []const Child,
        prefix_bytes: []const u8,
        values: []const V,

        /// The number of keys in the map.
        pub fn count(self: Self) usize {
            return self.values.len;
        }

        /// The value for `key`, or null.
        pub fn get(self: Self, key: []const u8) ?V {
            var node_index: u32 = 0;
            var depth: usize = 0;
            while (true) {
                const node = self.nodes[node_index];
                const prefix_len: usize = node.prefix_len;
                if (key.len < depth + prefix_len) return null;
                const prefix_off: usize = node.prefix_off;
                if (!mem.eql(
                    u8,
                    key[depth..][0..prefix_len],
                    self.prefix_bytes[prefix_off..][0..prefix_len],
                )) return null;
                depth += prefix_len;
                if (depth == key.len) {
                    return if (node.value == none) null else self.values[node.value];
                }
                const child = self.findChild(node, key[depth]) orelse return null;
                node_index = child.node;
                depth += 1;
            }
        }

        /// The value of the longest stored key that is a prefix of `key`, or
        /// null when no stored key is a prefix.
        pub fn getLongestPrefix(self: Self, key: []const u8) ?V {
            var node_index: u32 = 0;
            var depth: usize = 0;
            var best: ?V = null;
            while (true) {
                const node = self.nodes[node_index];
                const prefix_len: usize = node.prefix_len;
                if (key.len < depth + prefix_len) return best;
                const prefix_off: usize = node.prefix_off;
                if (!mem.eql(
                    u8,
                    key[depth..][0..prefix_len],
                    self.prefix_bytes[prefix_off..][0..prefix_len],
                )) return best;
                depth += prefix_len;
                if (node.value != none) best = self.values[node.value];
                if (depth == key.len) return best;
                const child = self.findChild(node, key[depth]) orelse return best;
                node_index = child.node;
                depth += 1;
            }
        }

        /// Whether `key` is one of the stored keys.
        pub fn has(self: Self, key: []const u8) bool {
            return self.get(key) != null;
        }

        /// Build a map from a literal during compilation. The result is a
        /// constant: all of its storage is in the binary, and it has no
        /// runtime initialization.
        ///
        /// A duplicate key is a compile error.
        pub inline fn initComptime(comptime kvs: anytype) Self {
            comptime {
                const n = kvs.len;

                var prefix_total: usize = 0;
                for (kvs) |kv| prefix_total += kv[0].len;
                @setEvalBranchQuota(
                    10 * n * std.math.log2_int_ceil(usize, @max(n, 2)) + 10 * prefix_total + 1000,
                );

                var entries: [n]Entry = undefined;
                for (kvs, 0..) |kv, i| {
                    entries[i] = .{ .key = kv[0], .value = kv[1] };
                }
                mem.sort(Entry, &entries, {}, lessThan);
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    if (mem.eql(u8, entries[i - 1].key, entries[i].key)) {
                        @compileError("prefix_map: duplicate key \"" ++
                            entries[i].key[0..entries[i].key.len] ++ "\"");
                    }
                }

                var counter = Builder{ .entries = &entries };
                if (n == 0) counter.node_count = 1 else _ = counter.build(false, 0, n, 0);
                const node_count = counter.node_count;
                const child_count = counter.child_count;
                const prefix_len = counter.prefix_len;
                const value_count = counter.value_count;

                var node_buf: [node_count]Node = undefined;
                var child_buf: [child_count]Child = undefined;
                var prefix_buf: [prefix_len]u8 = undefined;
                var value_buf: [value_count]V = undefined;

                if (n == 0) {
                    node_buf[0] = .{
                        .prefix_off = 0,
                        .prefix_len = 0,
                        .child_off = 0,
                        .child_len = 0,
                    };
                } else {
                    var builder = Builder{
                        .entries = &entries,
                        .nodes = &node_buf,
                        .children = &child_buf,
                        .prefix = &prefix_buf,
                        .values = &value_buf,
                    };
                    _ = builder.build(true, 0, n, 0);
                }

                const final_nodes = node_buf;
                const final_children = child_buf;
                const final_prefix = prefix_buf;
                const final_values = value_buf;
                return .{
                    .nodes = &final_nodes,
                    .children = &final_children,
                    .prefix_bytes = &final_prefix,
                    .values = &final_values,
                };
            }
        }

        /// Build a map from `kvs` with `allocator`. The keys and values are
        /// copied. Release the map with `deinit`.
        ///
        /// A duplicate key returns `error.DuplicateKey`.
        pub fn init(kvs: anytype, allocator: mem.Allocator) !Self {
            const n = kvs.len;
            const entries = try allocator.alloc(Entry, n);
            defer allocator.free(entries);
            fillEntries(entries, kvs);
            mem.sort(Entry, entries, {}, lessThan);
            var i: usize = 1;
            while (i < n) : (i += 1) {
                if (mem.eql(u8, entries[i - 1].key, entries[i].key)) {
                    return error.DuplicateKey;
                }
            }

            var counter = Builder{ .entries = entries };
            if (n == 0) counter.node_count = 1 else _ = counter.build(false, 0, n, 0);

            const nodes = try allocator.alloc(Node, counter.node_count);
            errdefer allocator.free(nodes);
            const children = try allocator.alloc(Child, counter.child_count);
            errdefer allocator.free(children);
            const prefix = try allocator.alloc(u8, counter.prefix_len);
            errdefer allocator.free(prefix);
            const values = try allocator.alloc(V, counter.value_count);
            errdefer allocator.free(values);

            if (n == 0) {
                nodes[0] = .{
                    .prefix_off = 0,
                    .prefix_len = 0,
                    .child_off = 0,
                    .child_len = 0,
                };
            } else {
                var builder = Builder{
                    .entries = entries,
                    .nodes = nodes,
                    .children = children,
                    .prefix = prefix,
                    .values = values,
                };
                _ = builder.build(true, 0, n, 0);
            }

            return .{
                .nodes = nodes,
                .children = children,
                .prefix_bytes = prefix,
                .values = values,
            };
        }

        /// Free a map built with `init`. Do not call this for a map built with
        /// `initComptime`: that storage is a constant.
        pub fn deinit(self: Self, allocator: mem.Allocator) void {
            allocator.free(self.nodes);
            allocator.free(self.children);
            allocator.free(self.prefix_bytes);
            allocator.free(self.values);
        }

        fn findChild(self: Self, node: Node, byte: u8) ?Child {
            const start: usize = node.child_off;
            const len: usize = node.child_len;
            if (len <= 8) {
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    const child = self.children[start + i];
                    if (child.byte == byte) return child;
                    if (child.byte > byte) return null;
                }
                return null;
            }

            var low: usize = 0;
            var high: usize = len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (self.children[start + mid].byte < byte) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            if (low < len and self.children[start + low].byte == byte) {
                return self.children[start + low];
            }
            return null;
        }

        const Builder = struct {
            entries: []const Entry,
            nodes: []Node = &.{},
            children: []Child = &.{},
            prefix: []u8 = &.{},
            values: []V = &.{},
            node_count: u32 = 0,
            child_count: u32 = 0,
            prefix_len: u32 = 0,
            value_count: u32 = 0,

            fn build(self: *Builder, comptime write: bool, lo: usize, hi: usize, depth: usize) u32 {
                const first = self.entries[lo].key;
                const last = self.entries[hi - 1].key;

                const limit = @min(first.len, last.len);
                var prefix_len: usize = 0;
                while (depth + prefix_len < limit and
                    first[depth + prefix_len] == last[depth + prefix_len]) : (prefix_len += 1)
                {}

                const node_index = self.node_count;
                self.node_count += 1;
                if (write and node_index >= self.nodes.len) unreachable;

                const prefix_off = self.prefix_len;
                self.prefix_len += @intCast(prefix_len);
                if (write and self.prefix_len > self.prefix.len) unreachable;

                var value: u32 = none;
                var rest_lo = lo;
                if (first.len == depth + prefix_len) {
                    value = self.value_count;
                    self.value_count += 1;
                    if (write) {
                        if (value >= self.values.len) unreachable;
                        self.values[value] = self.entries[lo].value;
                    }
                    rest_lo += 1;
                }

                if (write) {
                    @memcpy(
                        self.prefix[prefix_off..][0..prefix_len],
                        first[depth..][0..prefix_len],
                    );
                    self.nodes[node_index] = .{
                        .prefix_off = prefix_off,
                        .prefix_len = @intCast(prefix_len),
                        .value = value,
                        .child_off = self.child_count,
                        .child_len = 0,
                    };
                }

                if (rest_lo == hi) return node_index;

                const branch = depth + prefix_len;
                var groups: u32 = 0;
                var i = rest_lo;
                while (i < hi) {
                    const byte = self.entries[i].key[branch];
                    groups += 1;
                    i += 1;
                    while (i < hi and self.entries[i].key[branch] == byte) i += 1;
                }

                const child_off = self.child_count;
                self.child_count += groups;
                if (write and self.child_count > self.children.len) unreachable;
                if (write) self.nodes[node_index].child_len = groups;

                var group: u32 = 0;
                i = rest_lo;
                while (i < hi) {
                    const byte = self.entries[i].key[branch];
                    const start = i;
                    i += 1;
                    while (i < hi and self.entries[i].key[branch] == byte) i += 1;
                    const child_index = self.build(write, start, i, branch + 1);
                    if (write) {
                        self.children[child_off + group] = .{
                            .byte = byte,
                            .node = child_index,
                        };
                    }
                    group += 1;
                }

                return node_index;
            }
        };

        fn fillEntries(entries: []Entry, kvs: anytype) void {
            if (comptime isTuple(@TypeOf(kvs))) {
                inline for (kvs, 0..) |kv, i| {
                    entries[i] = .{ .key = kv[0], .value = kv[1] };
                }
            } else {
                for (kvs, 0..) |kv, i| {
                    entries[i] = .{ .key = kv[0], .value = kv[1] };
                }
            }
        }

        fn isTuple(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct" => |info| info.is_tuple,
                else => false,
            };
        }

        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return mem.order(u8, a.key, b.key) == .lt;
        }
    };
}

const TestValue = u16;

const routes = Map(TestValue).initComptime(.{
    .{ "api/", 1 },
    .{ "api/v1/", 2 },
    .{ "api/v1/users/", 3 },
    .{ "static/", 4 },
});

test "exact and longest-prefix lookups" {
    try testing.expectEqual(@as(?TestValue, 2), routes.get("api/v1/"));
    try testing.expectEqual(@as(?TestValue, null), routes.get("api/v1/users/42"));
    try testing.expectEqual(@as(?TestValue, 3), routes.getLongestPrefix("api/v1/users/42"));
    try testing.expectEqual(@as(?TestValue, 1), routes.getLongestPrefix("api/v2/"));
    try testing.expectEqual(@as(?TestValue, 4), routes.getLongestPrefix("static/app.js"));
    try testing.expectEqual(@as(?TestValue, null), routes.getLongestPrefix("other"));
    try testing.expect(routes.has("static/"));
    try testing.expect(!routes.has("static"));
    try testing.expectEqual(@as(usize, 4), routes.count());
}

test "a key that is a prefix of another" {
    const m = Map(u8).initComptime(.{
        .{ "abc", 1 },
        .{ "abcd", 2 },
        .{ "abce", 3 },
    });
    try testing.expectEqual(@as(?u8, 1), m.get("abc"));
    try testing.expectEqual(@as(?u8, 2), m.get("abcd"));
    try testing.expectEqual(@as(?u8, 2), m.getLongestPrefix("abcdef"));
    try testing.expectEqual(@as(?u8, 1), m.getLongestPrefix("abcx"));
    try testing.expectEqual(@as(?u8, 1), m.getLongestPrefix("abc"));
    try testing.expectEqual(@as(?u8, null), m.get("ab"));
}

test "empty key is the default prefix" {
    const m = Map(u8).initComptime(.{
        .{ "", 0 },
        .{ "a", 1 },
    });
    try testing.expectEqual(@as(?u8, 0), m.get(""));
    try testing.expectEqual(@as(?u8, 0), m.getLongestPrefix("zzz"));
    try testing.expectEqual(@as(?u8, 1), m.getLongestPrefix("abc"));
}

test "empty map" {
    const m = Map(u8).initComptime(.{});
    try testing.expectEqual(@as(?u8, null), m.get(""));
    try testing.expectEqual(@as(?u8, null), m.get("anything"));
    try testing.expectEqual(@as(usize, 0), m.count());

    const r = try Map(u8).init(.{}, testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, null), r.get("anything"));
    try testing.expectEqual(@as(usize, 0), r.count());
}

test "runtime build matches comptime build" {
    const kvs = .{
        .{ "api/", 1 },
        .{ "api/v1/", 2 },
        .{ "api/v1/users/", 3 },
        .{ "static/", 4 },
    };
    const r = try Map(TestValue).init(kvs, testing.allocator);
    defer r.deinit(testing.allocator);

    inline for (.{
        "api/",
        "api/v1/",
        "api/v1/users/",
        "api/v1/users/me",
        "api/v1/users/42",
        "api/v2/",
        "static/app.js",
        "other",
        "",
    }) |probe| {
        try testing.expectEqual(
            if (routes.get(probe)) |v| v else null,
            if (r.get(probe)) |v| v else null,
        );
    }
    try testing.expectEqual(routes.count(), r.count());
}

test "runtime duplicate key" {
    try testing.expectError(
        error.DuplicateKey,
        Map(u8).init(.{ .{ "a", 1 }, .{ "a", 2 } }, testing.allocator),
    );
}

test "runtime keys are copied" {
    var key_buf = [_]u8{ 'a', 'b', 'c' };
    var kvs = [_]struct { []const u8, u8 }{.{ key_buf[0..], 7 }};
    const m = try Map(u8).init(&kvs, testing.allocator);
    defer m.deinit(testing.allocator);
    key_buf[0] = 'z';
    try testing.expectEqual(@as(?u8, 7), m.get("abc"));
    try testing.expectEqual(@as(?u8, null), m.get("zbc"));
}

test "long keys, null bytes, and set values" {
    const long = "abcdefghijklmnopqrstuvwxyz" ** 12;
    const m = Map(void).initComptime(.{
        .{ long, {} },
        .{ "a\x00b", {} },
    });
    try testing.expect(m.has(long));
    try testing.expect(m.has("a\x00b"));
    try testing.expect(!m.has(long ++ "x"));
    try testing.expectEqual(@as(?void, {}), m.getLongestPrefix(long ++ "tail"));
}

test "matches a linear scan over many keys" {
    const n = 400;
    var key_buf: [n][32]u8 = undefined;
    var kvs: [n]struct { []const u8, u16 } = undefined;
    for (0..n) |i| {
        const key = try std.fmt.bufPrint(&key_buf[i], "api/v{d}/item{d}/", .{ i % 40, i });
        kvs[i] = .{ key, @intCast(i) };
    }

    const m = try Map(u16).init(&kvs, testing.allocator);
    defer m.deinit(testing.allocator);

    const probes = [_][]const u8{
        "",
        "api/",
        "api/v0/item0/",
        "api/v0/item0/x",
        "api/v39/item399/",
        "api/v39/item399/deep/path",
        "api/v40/item1/",
        "api/v0/item0",
    };
    for (probes) |probe| {
        var best: ?u16 = null;
        var best_len: usize = 0;
        var exact: ?u16 = null;
        for (kvs) |kv| {
            if (kv[0].len > probe.len) continue;
            if (!mem.eql(u8, probe[0..kv[0].len], kv[0])) continue;
            if (kv[0].len == probe.len) exact = kv[1];
            if (kv[0].len > best_len) {
                best = kv[1];
                best_len = kv[0].len;
            }
        }
        try testing.expectEqual(exact, m.get(probe));
        try testing.expectEqual(best, m.getLongestPrefix(probe));
    }
}

test "comptime lookups" {
    comptime {
        try testing.expectEqual(@as(?TestValue, 3), routes.getLongestPrefix("api/v1/users/42"));
        try testing.expectEqual(@as(?TestValue, null), routes.get("api/v1/users/42"));
    }
}
