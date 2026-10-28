//! Sorting that `std.mem.sort` does not have: a stable radix sort for
//! integers, and selection of the k-th element.
//!
//! `radix` sorts signed and unsigned integers with one pass per digit. It is
//! stable and needs a caller-owned scratch slice. `nth` partitions a slice so
//! the value at `n` is the n-th smallest, in expected O(n); `select` returns
//! that value.
//!
//! Use `radix` for large, unordered integer arrays. `std.mem.sortUnstable`
//! (pdqsort) wins on sorted or nearly sorted input; at small sizes the fixed
//! passes do not pay off.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const testing = std.testing;

pub const RadixError = error{NoSpaceLeft};

/// Stable LSD radix sort for integers.
///
/// `scratch` must have at least `items.len` elements and must not overlap
/// `items`. Returns `error.NoSpaceLeft` when it is shorter.
pub fn radix(comptime T: type, items: []T, scratch: []T) RadixError!void {
    if (isInteger(T) and items.len > 1 and scratch.len < items.len) return error.NoSpaceLeft;
    radixAssumeCapacity(T, items, scratch);
}

/// Stable LSD radix sort for integers. Asserts that `scratch` is large enough
/// and does not overlap `items`.
pub fn radixAssumeCapacity(comptime T: type, items: []T, scratch: []T) void {
    assert(isInteger(T));
    if (items.len <= 1) return;
    assert(scratch.len >= items.len);
    const items_start = @intFromPtr(items.ptr);
    const items_end = items_start + items.len * @sizeOf(T);
    const scratch_start = @intFromPtr(scratch.ptr);
    const scratch_end = scratch_start + scratch.len * @sizeOf(T);
    assert(scratch_end <= items_start or items_end <= scratch_start);

    const info = @typeInfo(T).int;
    const U = @Int(.unsigned, info.bits);
    const Shift = math.Log2Int(U);
    const digit_bits: u16 = if (info.bits <= 16) 8 else 11;
    const Digit = @Int(.unsigned, digit_bits);
    const passes = (info.bits + digit_bits - 1) / digit_bits;
    const sign_bit: U = if (info.signedness == .signed)
        @as(U, 1) << (info.bits - 1)
    else
        0;

    var src = items;
    var dst = scratch;
    var pass: u16 = 0;
    while (pass < passes) : (pass += 1) {
        const shift: Shift = @intCast(pass * digit_bits);
        var counts: [1 << digit_bits]usize = undefined;
        @memset(&counts, 0);

        for (src) |item| {
            const digit: Digit = @truncate((@as(U, @bitCast(item)) ^ sign_bit) >> shift);
            counts[digit] += 1;
        }

        var sum: usize = 0;
        for (&counts) |*count| {
            const n = count.*;
            count.* = sum;
            sum += n;
        }

        for (src) |item| {
            const digit: Digit = @truncate((@as(U, @bitCast(item)) ^ sign_bit) >> shift);
            dst[counts[digit]] = item;
            counts[digit] += 1;
        }

        const tmp = src;
        src = dst;
        dst = tmp;
    }

    if (src.ptr != items.ptr) @memcpy(items, src);
}

fn isInteger(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        else => @compileError("sort.radix: T must be an integer, not " ++ @typeName(T)),
    };
}

/// Partition `items` so that `items[n]` is the n-th smallest element. Every
/// element before it is less than or equal to it under `lessThan`; every
/// element after it is greater than or equal to it. The order inside each
/// side is unspecified.
///
/// Expected O(n). A run of bad pivots falls back to an unstable sort of the
/// active range, so the worst case is O(n log n). Panics when `n` is not a
/// valid index.
pub fn nth(
    comptime T: type,
    items: []T,
    n: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) void {
    assert(n < items.len);
    if (items.len == 1) return;

    var left: usize = 0;
    var right: usize = items.len;
    var depth: usize = 2 * math.log2_int_ceil(usize, items.len);
    while (right - left > 1) {
        if (depth == 0) {
            mem.sortUnstable(T, items[left..right], context, lessThan);
            return;
        }
        depth -= 1;

        const mid = left + (right - left) / 2;
        const pivot = medianOfThree(T, items, left, mid, right - 1, context, lessThan);

        var lt = left;
        var i = left;
        var gt = right;
        while (i < gt) {
            if (lessThan(context, items[i], pivot)) {
                mem.swap(T, &items[lt], &items[i]);
                lt += 1;
                i += 1;
            } else if (lessThan(context, pivot, items[i])) {
                gt -= 1;
                mem.swap(T, &items[i], &items[gt]);
            } else {
                i += 1;
            }
        }

        if (n < lt) {
            right = lt;
        } else if (n >= gt) {
            left = gt;
        } else {
            return;
        }
    }
}

/// The n-th smallest element, by the same rules as `nth`.
pub fn select(
    comptime T: type,
    items: []T,
    n: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) T {
    nth(T, items, n, context, lessThan);
    return items[n];
}

fn medianOfThree(
    comptime T: type,
    items: []T,
    a: usize,
    b: usize,
    c: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) T {
    if (lessThan(context, items[a], items[b])) {
        if (lessThan(context, items[b], items[c])) return items[b];
        return if (lessThan(context, items[a], items[c])) items[c] else items[a];
    }
    if (lessThan(context, items[a], items[c])) return items[a];
    return if (lessThan(context, items[b], items[c])) items[c] else items[b];
}

fn expectSorted(comptime T: type, actual: []const T, expected: []const T) !void {
    try testing.expectEqualSlices(T, expected, actual);
}

fn sortedCopy(comptime T: type, allocator: mem.Allocator, items: []const T) ![]T {
    const copy = try allocator.dupe(T, items);
    mem.sort(T, copy, {}, std.sort.asc(T));
    return copy;
}

fn testRadix(comptime T: type) !void {
    const allocator = testing.allocator;
    const U = @Int(.unsigned, @bitSizeOf(T));
    var seed: u64 = 0x9e3779b97f4a7c15 + @bitSizeOf(T);
    const values = try allocator.alloc(T, 257);
    defer allocator.free(values);
    const scratch = try allocator.alloc(T, values.len);
    defer allocator.free(scratch);

    for (values, 0..) |*value, i| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        value.* = @bitCast(@as(U, @truncate(seed)));
        if (i % 7 == 0) value.* = @bitCast(@as(U, @truncate(i)));
    }

    const expected = try sortedCopy(T, allocator, values);
    defer allocator.free(expected);

    try radix(T, values, scratch);
    try expectSorted(T, values, expected);

    // Sorted and reverse input, plus duplicates.
    mem.sort(T, values, {}, std.sort.asc(T));
    try radix(T, values, scratch);
    try expectSorted(T, values, expected);

    mem.reverse(T, values);
    try radix(T, values, scratch);
    try expectSorted(T, values, expected);

    @memset(values, 7);
    try radix(T, values, scratch);
    try testing.expectEqual(@as(T, 7), values[0]);
    try testing.expectEqual(@as(T, 7), values[values.len - 1]);

    // Min and max.
    if (values.len >= 2) {
        values[0] = math.minInt(T);
        values[1] = math.maxInt(T);
        const min_max = try sortedCopy(T, allocator, values);
        defer allocator.free(min_max);
        try radix(T, values, scratch);
        try expectSorted(T, values, min_max);
    }
}

test "radix sorts every integer width and sign" {
    inline for (.{ u8, u16, u32, u64, usize, i8, i16, i32, i64, isize }) |T| {
        try testRadix(T);
    }
}

test "radix handles empty and single-element slices" {
    var empty: [0]u32 = .{};
    var scratch: [0]u32 = .{};
    try radix(u32, &empty, &scratch);

    var one = [_]u32{42};
    try radix(u32, &one, &scratch);
    try testing.expectEqual(@as(u32, 42), one[0]);
}

test "radix reports a short scratch" {
    var items = [_]u32{ 3, 2, 1 };
    var scratch = [_]u32{0};
    try testing.expectError(error.NoSpaceLeft, radix(u32, &items, &scratch));
}

const Descending = struct {
    fn lessThan(_: void, a: u32, b: u32) bool {
        return a > b;
    }
};

test "select and nth match a sorted copy" {
    const allocator = testing.allocator;
    var seed: u64 = 0x123456789abcdef;
    const values = try allocator.alloc(u32, 257);
    defer allocator.free(values);
    for (values, 0..) |*value, i| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        value.* = @truncate(seed % 1000);
        if (i % 9 == 0) value.* = 0;
        if (i % 11 == 0) value.* = 999;
    }

    const expected = try sortedCopy(u32, allocator, values);
    defer allocator.free(expected);

    const work = try allocator.alloc(u32, values.len);
    defer allocator.free(work);
    for (0..values.len) |n| {
        @memcpy(work, values);
        nth(u32, work, n, {}, std.sort.asc(u32));
        try testing.expectEqual(expected[n], work[n]);
        for (work[0..n]) |v| try testing.expect(v <= work[n]);
        for (work[n + 1 ..]) |v| try testing.expect(v >= work[n]);

        @memcpy(work, values);
        try testing.expectEqual(expected[n], select(u32, work, n, {}, std.sort.asc(u32)));
    }

    // A non-default comparator.
    const descending = try allocator.dupe(u32, values);
    defer allocator.free(descending);
    const highest = select(u32, descending, 0, {}, Descending.lessThan);
    try testing.expectEqual(expected[expected.len - 1], highest);
}

test "nth handles one element" {
    var one = [_]u32{7};
    nth(u32, &one, 0, {}, std.sort.asc(u32));
    try testing.expectEqual(@as(u32, 7), one[0]);
}
