const std = @import("std");
const set = @import("stdx").set;

const Ports = set.Auto(u16, 8);

test "membership and set algebra" {
    var allowed: Ports = .init;
    for ([_]u16{ 80, 443, 8080 }) |port| _ = try allowed.add(port);

    var requested: Ports = .init;
    _ = try requested.add(443);
    _ = try requested.add(80);
    try std.testing.expect(requested.subsetOf(&allowed));

    _ = try requested.add(22);
    try std.testing.expect(!requested.subsetOf(&allowed));

    // Keep only what the allow list also holds.
    requested.intersect(&allowed);
    try std.testing.expectEqual(2, requested.count());
    try std.testing.expect(!requested.contains(22));
}

// `add` has three outcomes: newly added, already present, and no room.
test "a full set refuses a new key" {
    var ports: set.Auto(u16, 2) = .init;
    try std.testing.expect(try ports.add(80));
    try std.testing.expect(!try ports.add(80));
    try std.testing.expect(try ports.add(443));
    try std.testing.expectError(error.NoSpaceLeft, ports.add(8080));
}

test "unite fails when the union does not fit" {
    const Small = set.Auto(u16, 3);
    var a: Small = .init;
    var b: Small = .init;
    _ = try a.add(1);
    _ = try a.add(2);
    _ = try b.add(3);
    _ = try b.add(4);
    try std.testing.expectError(error.NoSpaceLeft, a.unite(&b));
}
