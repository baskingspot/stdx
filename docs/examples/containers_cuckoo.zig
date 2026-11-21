const std = @import("std");
const cuckoo = @import("stdx").cuckoo;

// Sized at compile time for 10,000 keys at a false-positive rate at or below 1%.
const Active = cuckoo.Auto(u64, .fromCapacity(10_000, 0.01));

test "cuckoo filters support removal" {
    var active: Active = .empty;
    try active.add(42);
    try active.add(99);
    try std.testing.expect(active.contains(42));

    try std.testing.expect(active.remove(42));
    try std.testing.expect(!active.contains(42));
    try std.testing.expect(active.contains(99));
}
