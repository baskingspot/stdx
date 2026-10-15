const std = @import("std");
const stdx = @import("stdx");
const bounded_array_hash_map = stdx.bounded_array_hash_map;
const Ip4 = stdx.net.Ip4;

// An `Ip4` is four bytes with no padding, so it works as a key as it is.
const Hits = bounded_array_hash_map.Auto(Ip4, u32, 16);

fn record(hits: *Hits, client: Ip4) !u32 {
    const entry = try hits.getOrPut(client);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    entry.value_ptr.* += 1;
    return entry.value_ptr.*;
}

test "count requests per client" {
    var hits: Hits = .init;
    const a: Ip4 = .parseComptime("10.0.0.1");
    const b: Ip4 = .parseComptime("10.0.0.2");

    try std.testing.expectEqual(1, try record(&hits, a));
    try std.testing.expectEqual(2, try record(&hits, a));
    try std.testing.expectEqual(1, try record(&hits, b));
}
