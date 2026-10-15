const std = @import("std");
const bloom = @import("stdx").bloom;

// Sized at compile time for 10,000 keys at about a 1% false-positive rate.
const Seen = bloom.Auto(u64, 10_000, 0.01);

test "a filter has no false negatives" {
    var seen: Seen = .empty;
    seen.add(42);
    try std.testing.expect(seen.contains(42));
}

test "the request is a target and actual_rate is the truth" {
    // The filter rounds its size up to a power of two, so the rate it
    // delivers can differ from the request.
    try std.testing.expect(Seen.actual_rate <= 0.01);
}
