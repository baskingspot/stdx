const std = @import("std");
const ultraloglog = @import("stdx").ultraloglog;

// Precision 10 holds 1,024 byte registers (~2.4% relative standard error).
const Distinct = ultraloglog.String(10);

test "merge shards, downsize, and roundtrip bytes" {
    var shard_a: Distinct = .empty;
    var shard_b: Distinct = .empty;

    shard_a.add("alice");
    shard_a.add("bob");
    shard_a.add("alice");

    shard_b.add("bob");
    shard_b.add("carol");

    shard_a.merge(&shard_b);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), shard_a.estimate(), 1.5);

    // Serialize the raw bytes and restore with validation.
    const wire = shard_a.asBytes().*;
    const restored = try Distinct.fromBytes(wire);
    try std.testing.expectEqual(shard_a.estimate(), restored.estimate());

    // Downsize to a smaller precision without re-hashing inputs.
    const compact = restored.downsize(8);
    try std.testing.expectEqual(@as(usize, 256), @TypeOf(compact).register_count);
}
