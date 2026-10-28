//! The sort module's benchmarks: radix against std's pdqsort and block
//! sort on 1M integers, and select against sorting the whole slice.

const std = @import("std");
const testingx = @import("testingx");

const stdx = @import("stdx");
const sort = stdx.sort;

const n = 1_048_576;

fn fillRandom(comptime T: type, values: []T, seed: *u64) void {
    for (values) |*value| {
        seed.* ^= seed.* << 13;
        seed.* ^= seed.* >> 7;
        seed.* ^= seed.* << 17;
        value.* = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(seed.*)));
    }
}

fn runSort(
    b: *testingx.B,
    base: []const u32,
    items: []u32,
    scratch: []u32,
    comptime f: fn ([]u32, []u32) void,
) !void {
    while (try b.loop()) {
        @memcpy(items, base);
        f(items, scratch);
    }
    b.keepAlive(items[0]);
}

fn radixU32(items: []u32, scratch: []u32) void {
    sort.radixAssumeCapacity(u32, items, scratch);
}

fn pdqU32(items: []u32, _: []u32) void {
    std.mem.sortUnstable(u32, items, {}, std.sort.asc(u32));
}

fn blockU32(items: []u32, _: []u32) void {
    std.mem.sort(u32, items, {}, std.sort.asc(u32));
}

pub fn benchmarkRadixU32Random(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    const scratch = try allocator.alloc(u32, n);
    defer allocator.free(scratch);
    var seed: u64 = 0x12345678;
    fillRandom(u32, base, &seed);
    try runSort(b, base, items, scratch, radixU32);
}

pub fn benchmarkPdqU32Random(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    var seed: u64 = 0x12345678;
    fillRandom(u32, base, &seed);
    try runSort(b, base, items, &.{}, pdqU32);
}

pub fn benchmarkBlockU32Random(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    var seed: u64 = 0x12345678;
    fillRandom(u32, base, &seed);
    try runSort(b, base, items, &.{}, blockU32);
}

pub fn benchmarkRadixU32Sorted(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    const scratch = try allocator.alloc(u32, n);
    defer allocator.free(scratch);
    for (base, 0..) |*value, i| value.* = @intCast(i);
    try runSort(b, base, items, scratch, radixU32);
}

pub fn benchmarkPdqU32Sorted(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    for (base, 0..) |*value, i| value.* = @intCast(i);
    try runSort(b, base, items, &.{}, pdqU32);
}

pub fn benchmarkRadixU64Random(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u64, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u64, n);
    defer allocator.free(items);
    const scratch = try allocator.alloc(u64, n);
    defer allocator.free(scratch);
    var seed: u64 = 0xabcdef0123456789;
    fillRandom(u64, base, &seed);

    while (try b.loop()) {
        @memcpy(items, base);
        sort.radixAssumeCapacity(u64, items, scratch);
    }
    b.keepAlive(items[0]);
}

pub fn benchmarkPdqU64Random(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u64, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u64, n);
    defer allocator.free(items);
    var seed: u64 = 0xabcdef0123456789;
    fillRandom(u64, base, &seed);

    while (try b.loop()) {
        @memcpy(items, base);
        std.mem.sortUnstable(u64, items, {}, std.sort.asc(u64));
    }
    b.keepAlive(items[0]);
}

pub fn benchmarkSelectMedian(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    var seed: u64 = 0x12345678;
    fillRandom(u32, base, &seed);

    var sink: u32 = 0;
    while (try b.loop()) {
        @memcpy(items, base);
        sink +%= sort.select(u32, items, n / 2, {}, std.sort.asc(u32));
    }
    b.keepAlive(sink);
}

pub fn benchmarkSortMedian(b: *testingx.B) !void {
    const allocator = std.heap.page_allocator;
    const base = try allocator.alloc(u32, n);
    defer allocator.free(base);
    const items = try allocator.alloc(u32, n);
    defer allocator.free(items);
    var seed: u64 = 0x12345678;
    fillRandom(u32, base, &seed);

    var sink: u32 = 0;
    while (try b.loop()) {
        @memcpy(items, base);
        std.mem.sortUnstable(u32, items, {}, std.sort.asc(u32));
        sink +%= items[n / 2];
    }
    b.keepAlive(sink);
}
