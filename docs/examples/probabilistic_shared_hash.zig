const std = @import("std");
const stdx = @import("stdx");
const count_min = stdx.count_min;
const hash = stdx.hash;
const ultraloglog = stdx.ultraloglog;

// Hash each key once and feed both sketches through their hash-level primitives.
const Freq = count_min.Sketch(.{ .depth = 4, .width = 256 });
const Distinct = ultraloglog.Sketch(10);

test "one hash drives multiple sketches" {
    var freq: Freq = .empty;
    var distinct: Distinct = .empty;

    const events = [_][]const u8{ "/health", "/api", "/health", "/metrics", "/health" };
    for (events) |path| {
        const digest = hash.RapidHash.hash(0, path);
        freq.addHashConservative(digest, 1);
        distinct.addHash(digest);
    }

    const health_hash = hash.RapidHash.hash(0, "/health");
    try std.testing.expect(freq.estimateHash(health_hash) >= 3);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), distinct.estimate(), 1.5);
}
