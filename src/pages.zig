//! Whole-kernel-page memory primitives, Linux only.
//!
//! `release` drops the whole kernel pages inside a byte range with
//! MADV_DONTNEED. On private anonymous memory the next touch of a released
//! page faults in a zero page — the Linux-specific guarantee this module
//! leans on. Edge pages that the range shares with other memory stay
//! resident, so a release never zeroes a neighbor's bytes. Darwin's
//! MADV_DONTNEED is advisory with no zero-fill guarantee (the XNU behavior
//! flag is a hint), so this module is Linux-only by design — not a
//! portability gap to close.
//!
//! The `allocator` alias is the intentional `std.heap.page_allocator`: raw
//! mmap and munmap, with no allocator state between them. Four contracts
//! make an intentional use of it over a heap allocator, and a new reason
//! extends this list — a use anywhere else is a regression:
//!
//! - Page-exact geometry: memory that `release` drops must span whole kernel
//!   pages alone. A heap pointer carries a bucket or node header offset, and
//!   its pages share tenants with other allocations.
//! - Lifetime past cleanup: no state exists to deinit, so nothing frees the
//!   allocation behind a detached thread that outlives main's teardown.
//! - A free that returns pages: only munmap hands a scratch page back for the
//!   next allocation. An arena free does nothing unless it frees the most
//!   recent allocation, so non-LIFO churn never returns under an arena.
//! - A ceiling-scale reservation that stays untouched: an arena grows by
//!   doubling its buffer and memcpying it, so a slot-space-sized reservation
//!   would be touched wholesale at every growth step. `reserve` maps whole
//!   pages and touches only what a caller reads.

const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;
const pageSize = std.heap.pageSize;
/// The intentional `std.heap.page_allocator`. See the module doc for the
/// contracts that make an allocation through this alias deliberate.
pub const allocator: Allocator = std.heap.page_allocator;
const builtin = @import("builtin");

comptime {
    switch (builtin.os.tag) {
        .linux => {},
        else => @compileError("pages supports Linux only"),
    }
}
/// Reserve `n` items of `T` as one private anonymous mapping, untouched:
/// the kernel supplies zero pages at first touch. Nothing here rides
/// `Allocator.alloc` — its undefined-fill touches every byte of the
/// allocation at once, which is exactly the resident memory a lazy
/// reservation exists to avoid. The reservation is whole kernel pages
/// alone: `release` drops it exactly.
pub fn reserve(comptime T: type, n: usize) []T {
    const bytes_len = @sizeOf(T) * n;
    if (bytes_len == 0) return &.{};
    const bytes = allocator.rawAlloc(
        bytes_len,
        .fromByteUnits(pageSize()),
        @returnAddress(),
    ) orelse @panic("OOM");
    // The mapping is page-aligned, so any element alignment fits; the
    // alignCast carries the proof.
    return @as([*]T, @ptrCast(@alignCast(bytes)))[0..n];
}

/// Unreserve a `reserve` mapping: rawFree, never the freeing interface —
/// its undefined-fill would touch the whole reservation again on the way
/// out. An empty reservation unreserves nothing.
pub fn unreserve(memory: anytype) void {
    if (memory.len == 0) return;
    const T = std.meta.Child(@TypeOf(memory));
    const bytes: []u8 = @as([*]u8, @ptrCast(memory.ptr))[0 .. memory.len * @sizeOf(T)];
    allocator.rawFree(bytes, .fromByteUnits(pageSize()), @returnAddress());
}

/// A block of `n` pages aligned to `pageSize()`, for tests. Free it with
/// `freeForTest`.
pub fn allocForTest(gpa: Allocator, n: usize) ![]u8 {
    const len = n * pageSize();
    const ptr = gpa.rawAlloc(len, .fromByteUnits(pageSize()), @returnAddress()) orelse
        return error.OutOfMemory;
    return ptr[0..len];
}

pub fn freeForTest(gpa: Allocator, block: []u8) void {
    gpa.rawFree(block, .fromByteUnits(pageSize()), @returnAddress());
}

/// The whole kernel pages inside `bytes`: empty when `bytes` spans none.
pub fn whole(bytes: []u8) []u8 {
    const page = pageSize();
    const base = @intFromPtr(bytes.ptr);
    const start = mem.alignForward(usize, base, page);
    const end = mem.alignBackward(usize, base + bytes.len, page);
    if (end <= start) return &.{};
    return @as([*]u8, @ptrFromInt(start))[0 .. end - start];
}

/// Drop the whole pages inside `bytes`. Best effort: on failure the pages
/// stay resident and keep their bytes, which the caller already wiped.
pub fn release(bytes: []u8) void {
    const span = whole(bytes);
    if (span.len == 0) return;
    _ = linux.madvise(span.ptr, span.len, linux.MADV.DONTNEED);
}

test "only whole pages go back, and they come back zeroed" {
    const page = pageSize();
    const block = try allocForTest(testing.allocator, 4);
    defer freeForTest(testing.allocator, block);
    @memset(block, 0xa5);
    // A range that starts and ends inside pages: only the two interior
    // pages go back; the edge bytes keep their fill.
    const range = block[100 .. 3 * page + 100];
    try testing.expectEqual(@as(usize, 2 * page), whole(range).len);
    release(range);
    try testing.expect(mem.allEqual(u8, block[0..page], 0xa5));
    try testing.expect(mem.allEqual(u8, block[page .. 3 * page], 0));
    try testing.expect(mem.allEqual(u8, block[3 * page ..], 0xa5));
    // A range inside one page releases nothing.
    try testing.expectEqual(@as(usize, 0), whole(block[10 .. page - 10]).len);
}

test "reserve and unreserve" {
    const Block = struct {
        header: u64,
        payload: [64]u8,
    };
    // Large enough to span multiple pages: a reserve at page-exact scale.
    const reserved = reserve(Block, 10_000);
    defer unreserve(reserved);
    try testing.expect(reserved.len == 10_000);
    try testing.expect(@intFromPtr(reserved.ptr) % pageSize() == 0);
    // Untouched pages read as zero on first touch.
    try testing.expect(reserved[9999].header == 0);
    // An empty reservation is nothing to map or unmap.
    try testing.expect(reserve(Block, 0).len == 0);
}

test "whole is empty for sub-page and misaligned ranges" {
    const page = pageSize();
    const block = try allocForTest(testing.allocator, 3);
    defer freeForTest(testing.allocator, block);
    @memset(block, 0xa5);

    // Fully inside one page: no whole page.
    try testing.expectEqual(@as(usize, 0), whole(block[10 .. page - 10]).len);

    // A page-sized range starting 100 bytes in: the aligned start and
    // end coincide, so it still spans no whole page.
    const misfit = block[100 .. page + 100];
    try testing.expectEqual(@as(usize, 0), whole(misfit).len);

    // Misaligned start and end with room between: only the interior
    // page is whole, and the released page reads zeros back on Linux.
    const misaligned = block[100 .. 2 * page + 100];
    try testing.expectEqual(@as(usize, page), whole(misaligned).len);
    release(misaligned);
    try testing.expect(mem.allEqual(u8, block[page .. 2 * page], 0));
    try testing.expect(mem.allEqual(u8, block[0..100], 0xa5));
    try testing.expect(mem.allEqual(u8, block[2 * page ..], 0xa5));
}
