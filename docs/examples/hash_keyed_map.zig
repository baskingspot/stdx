const std = @import("std");
const stdx = @import("stdx");
const bounded_array_hash_map = stdx.bounded_array_hash_map;
const rapidhash = stdx.hash.RapidHash;

// `StringContext` is a std-style hash-map context: rapidhash over the
// key bytes, with the map's equality for the rest.
const Counts = bounded_array_hash_map.Custom([]const u8, u32, rapidhash.StringContext, 16);

fn record(counts: *Counts, route: []const u8) !u32 {
    const entry = try counts.getOrPut(route);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    entry.value_ptr.* += 1;
    return entry.value_ptr.*;
}

test "one seed and one input give one hash" {
    try std.testing.expectEqual(rapidhash.hash(0, "GET /health"), rapidhash.hash(0, "GET /health"));
    try std.testing.expect(rapidhash.hash(7, "GET /health") != rapidhash.hash(0, "GET /health"));
}

test "string keys hash with rapidhash" {
    var counts: Counts = .init;
    try std.testing.expectEqual(1, try record(&counts, "GET /health"));
    try std.testing.expectEqual(2, try record(&counts, "GET /health"));
    try std.testing.expectEqual(1, try record(&counts, "POST /jobs"));
}
