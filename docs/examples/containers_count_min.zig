const std = @import("std");
const count_min = @import("stdx").count_min;

// Error bounds: within 0.5% of total weight with at least 99% probability.
const Hits = count_min.String(.fromError(.{ .epsilon = 0.005, .delta = 0.01 }));

test "estimates never undercount and merge across workers" {
    var worker_a: Hits = .empty;
    var worker_b: Hits = .empty;

    worker_a.addConservative("/health", 10);
    worker_b.addConservative("/health", 4);
    worker_b.addConservative("/metrics", 3);

    worker_a.merge(&worker_b);
    try std.testing.expect(worker_a.estimate("/health") >= 14);
    try std.testing.expect(worker_a.estimate("/metrics") >= 3);
    try std.testing.expectEqual(@as(u64, 17), worker_a.count());

    // Halve all counters to age out older traffic.
    worker_a.halve();
    try std.testing.expect(worker_a.estimate("/health") >= 7);
}
