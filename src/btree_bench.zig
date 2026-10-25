//! The btree module's benchmarks: lookups, build, churn and scan against the
//! alternatives Zig 0.16 and stdx leave.
//!
//! Zig has no ordered map in `std` — `std.Treap` takes a caller-allocated
//! node per element and chases pointers down the tree. The baselines are the
//! ones people actually reach for: `swiss` (the package's fastest unordered
//! map) and `std.AutoHashMap` when order is not needed, and a sorted array
//! with a binary search when the data is built once.
//!
//! The maps are filled as untimed setup; each loop body does one unit of the
//! measured work. Keys are a seeded LCG, so every run sees the same map.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const stdx = @import("stdx");
const btree = stdx.btree;
const testingx = @import("testingx");

const Map = btree.Auto(u64, u64);
const HashMap = std.AutoHashMap(u64, u64);

const entry_count = 1_000_000;
const probe_count = 4096;

const string_count = 200_000;

const item_format = "srv/2026/10/25/requests/item-{d:0>9}";
const string_number_space = 1_000_000_000;

/// Sequential hits: `probe_count` keys that exist.
var hit_keys: [probe_count]u64 = undefined;
/// Same keys, high bits flipped: guaranteed misses.
var miss_keys: [probe_count]u64 = undefined;

var string_keys: [string_count][]const u8 = undefined;
var string_storage: [string_count * 48]u8 = undefined;
var string_hit_keys: [probe_count][]const u8 = undefined;
var string_miss_storage: [probe_count][48]u8 = undefined;
var string_miss_keys: [probe_count][]const u8 = undefined;

fn keyAt(index: u64) u64 {
    var state = index *% 6364136223846793005 +% 1442695040888963407;
    state ^= state >> 33;
    state *%= 0xff51afd7ed558ccd;
    state ^= state >> 33;
    return state;
}

/// Fill the u64 probe keys. A miss flips a middle bit, so it lands in a
/// different region from its hit key instead of the far end of the order the
/// way the top bit would land it. A miss set concentrated on one path would
/// measure that path, not a lookup.
fn fillU64Probes() void {
    for (0..probe_count) |i| {
        const key = keyAt(i * (entry_count / probe_count));
        hit_keys[i] = key;
        miss_keys[i] = key ^ (@as(u64, 1) << 40);
    }
}

fn fillU64(gpa: Allocator, map: anytype) !void {
    fillU64Probes();
    for (0..entry_count) |i| {
        const key = keyAt(i);
        try map.put(gpa, key, key);
    }
}

/// Fill the key pool and the string probe keys. Numbers spread over a
/// nine-digit space, the way real paths do, so a near miss lands beside its
/// key rather than at the end of a sequential range.
fn fillStringProbes() !void {
    const stride = string_count / probe_count;
    var offset: usize = 0;
    for (0..string_count) |i| {
        const number = keyAt(i) % string_number_space;
        const key = try std.fmt.bufPrint(string_storage[offset..], item_format, .{number});
        offset += 48;
        string_keys[i] = key;
        if (i % stride == 0 and i / stride < probe_count) {
            const slot = i / stride;
            string_hit_keys[slot] = key;
            const near = (number + 1) % string_number_space;
            const miss = try std.fmt.bufPrint(&string_miss_storage[slot], item_format, .{near});
            string_miss_keys[slot] = miss;
        }
    }
}

fn fillStrings(gpa: Allocator, map: anytype) !void {
    try fillStringProbes();
    for (string_keys, 0..) |key, i| try map.put(gpa, key, i);
}

// --- btree ---

pub fn benchmarkBtreeU64GetHit(b: *testingx.B) !void {
    var map: Map = .empty;
    defer map.clearAndFree(b.allocator);
    try fillU64(b.allocator, &map);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&hit_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkBtreeU64GetMiss(b: *testingx.B) !void {
    var map: Map = .empty;
    defer map.clearAndFree(b.allocator);
    try fillU64(b.allocator, &map);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&miss_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkBtreeU64Build(b: *testingx.B) !void {
    var sink: u64 = 0;
    var state: u64 = 1;
    while (try b.loop()) {
        var map: Map = .empty;
        defer map.clearAndFree(b.allocator);
        for (0..20_000) |_| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            try map.put(b.allocator, state, state);
        }
        sink +%= map.count();
    }
    b.keepAlive(sink);
}

pub fn benchmarkBtreeU64Churn(b: *testingx.B) !void {
    var map: Map = .empty;
    defer map.clearAndFree(b.allocator);
    try fillU64(b.allocator, &map);
    const churn = 1024;
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(hit_keys[0..churn])) |key| {
            if (map.fetchRemove(b.allocator, key)) |value| sink +%= value;
        }
        for (b.blackBox(hit_keys[0..churn])) |key| {
            try map.put(b.allocator, key, key);
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkBtreeU64Scan(b: *testingx.B) !void {
    var map: Map = .empty;
    defer map.clearAndFree(b.allocator);
    try fillU64(b.allocator, &map);
    var sink: u64 = 0;
    while (try b.loop()) {
        var it = map.iterator();
        while (it.next()) |entry| sink +%= entry.value_ptr.*;
    }
    b.keepAlive(sink);
}

pub fn benchmarkBtreeStringGetHit(b: *testingx.B) !void {
    var map: btree.String(usize) = .empty;
    defer map.clearAndFree(b.allocator);
    try fillStrings(b.allocator, &map);
    var sink: usize = 0;
    while (try b.loop()) {
        for (b.blackBox(&string_hit_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkBtreeStringGetMiss(b: *testingx.B) !void {
    var map: btree.String(usize) = .empty;
    defer map.clearAndFree(b.allocator);
    try fillStrings(b.allocator, &map);
    var sink: usize = 0;
    while (try b.loop()) {
        for (b.blackBox(&string_miss_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

// --- std.AutoHashMap ---

pub fn benchmarkHashMapU64GetHit(b: *testingx.B) !void {
    var map: HashMap = .init(b.allocator);
    defer map.deinit();
    fillU64Probes();
    for (0..entry_count) |i| {
        const key = keyAt(i);
        try map.put(key, key);
    }
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&hit_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkHashMapU64GetMiss(b: *testingx.B) !void {
    var map: HashMap = .init(b.allocator);
    defer map.deinit();
    fillU64Probes();
    for (0..entry_count) |i| {
        const key = keyAt(i);
        try map.put(key, key);
    }
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&miss_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkHashMapU64Build(b: *testingx.B) !void {
    var sink: u64 = 0;
    var state: u64 = 1;
    while (try b.loop()) {
        var map: HashMap = .init(b.allocator);
        defer map.deinit();
        for (0..20_000) |_| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            try map.put(state, state);
        }
        sink +%= map.count();
    }
    b.keepAlive(sink);
}

pub fn benchmarkHashMapU64Scan(b: *testingx.B) !void {
    var map: HashMap = .init(b.allocator);
    defer map.deinit();
    for (0..entry_count) |i| {
        const key = keyAt(i);
        try map.put(key, key);
    }
    var sink: u64 = 0;
    while (try b.loop()) {
        var it = map.valueIterator();
        while (it.next()) |value| sink +%= value.*;
    }
    b.keepAlive(sink);
}

// --- sorted array + binary search ---

fn sortedSearch(keys: []const u64, key: u64) ?usize {
    var lo: usize = 0;
    var hi = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return if (lo < keys.len and keys[lo] == key) lo else null;
}

pub fn benchmarkSortedU64GetHit(b: *testingx.B) !void {
    const keys = try b.allocator.alloc(u64, entry_count);
    defer b.allocator.free(keys);
    for (keys, 0..) |*key, i| key.* = keyAt(i);
    mem.sort(u64, keys, {}, std.sort.asc(u64));
    for (0..probe_count) |i| {
        hit_keys[i] = keys[i * (entry_count / probe_count)];
    }
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&hit_keys)) |key| {
            if (sortedSearch(keys, key)) |index| sink +%= keys[index];
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSortedU64GetMiss(b: *testingx.B) !void {
    const keys = try b.allocator.alloc(u64, entry_count);
    defer b.allocator.free(keys);
    for (keys, 0..) |*key, i| key.* = keyAt(i);
    mem.sort(u64, keys, {}, std.sort.asc(u64));
    for (0..probe_count) |i| {
        hit_keys[i] = keys[i * (entry_count / probe_count)];
    }
    for (&miss_keys, hit_keys) |*miss, hit| miss.* = hit ^ (1 << 63);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&miss_keys)) |key| {
            if (sortedSearch(keys, key)) |index| sink +%= keys[index];
        }
    }
    b.keepAlive(sink);
}

fn stringSearch(keys: []const []const u8, key: []const u8) ?usize {
    var lo: usize = 0;
    var hi = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (btree.compareBytes(keys[mid], key) == .lt) lo = mid + 1 else hi = mid;
    }
    return if (lo < keys.len and mem.eql(u8, keys[lo], key)) lo else null;
}

pub fn benchmarkSortedStringGetHit(b: *testingx.B) !void {
    const keys = try b.allocator.alloc([]const u8, string_count);
    defer b.allocator.free(keys);
    try fillStringProbes();
    @memcpy(keys, &string_keys);
    mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, other: []const u8) bool {
            return btree.compareBytes(a, other) == .lt;
        }
    }.lessThan);
    var sink: usize = 0;
    while (try b.loop()) {
        for (b.blackBox(&string_hit_keys)) |key| {
            if (stringSearch(keys, key)) |index| sink +%= index;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSortedStringGetMiss(b: *testingx.B) !void {
    const keys = try b.allocator.alloc([]const u8, string_count);
    defer b.allocator.free(keys);
    try fillStringProbes();
    @memcpy(keys, &string_keys);
    mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, other: []const u8) bool {
            return btree.compareBytes(a, other) == .lt;
        }
    }.lessThan);
    var sink: usize = 0;
    while (try b.loop()) {
        for (b.blackBox(&string_miss_keys)) |key| {
            if (stringSearch(keys, key)) |index| sink +%= index;
        }
    }
    b.keepAlive(sink);
}

// --- swiss, for the unordered comparison ---

const swiss = stdx.swiss;

pub fn benchmarkSwissU64GetHit(b: *testingx.B) !void {
    var map: swiss.Auto(u64, u64) = .empty;
    defer map.deinit(b.allocator);
    try fillU64(b.allocator, &map);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&hit_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissU64GetMiss(b: *testingx.B) !void {
    var map: swiss.Auto(u64, u64) = .empty;
    defer map.deinit(b.allocator);
    try fillU64(b.allocator, &map);
    var sink: u64 = 0;
    while (try b.loop()) {
        for (b.blackBox(&miss_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissU64Build(b: *testingx.B) !void {
    var sink: u64 = 0;
    var state: u64 = 1;
    while (try b.loop()) {
        var map: swiss.Auto(u64, u64) = .empty;
        defer map.deinit(b.allocator);
        for (0..20_000) |_| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            try map.put(b.allocator, state, state);
        }
        sink +%= map.count();
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissU64Scan(b: *testingx.B) !void {
    var map: swiss.Auto(u64, u64) = .empty;
    defer map.deinit(b.allocator);
    try fillU64(b.allocator, &map);
    var sink: u64 = 0;
    while (try b.loop()) {
        var it = map.valueIterator();
        while (it.next()) |value| sink +%= value.*;
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissStringGetHit(b: *testingx.B) !void {
    var map: swiss.String(usize) = .empty;
    defer map.deinit(b.allocator);
    try fillStrings(b.allocator, &map);
    var sink: usize = 0;
    while (try b.loop()) {
        for (b.blackBox(&string_hit_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}

pub fn benchmarkSwissStringGetMiss(b: *testingx.B) !void {
    var map: swiss.String(usize) = .empty;
    defer map.deinit(b.allocator);
    try fillStrings(b.allocator, &map);
    var sink: usize = 0;
    while (try b.loop()) {
        for (b.blackBox(&string_miss_keys)) |key| {
            if (map.get(key)) |value| sink +%= value;
        }
    }
    b.keepAlive(sink);
}
