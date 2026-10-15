const std = @import("std");
const multi_array = @import("stdx").multi_array;

const Particle = struct {
    x: f32,
    y: f32,
    alive: bool,
};

// One array per field, with fixed capacity and a runtime length.
const Particles = multi_array.Buffer(Particle, 128);

test "a field is a contiguous slice" {
    var particles: Particles = .empty;
    try particles.append(.{ .x = 1, .y = 10, .alive = true });
    try particles.append(.{ .x = 2, .y = 20, .alive = false });

    // A loop over one field touches one array, not every struct.
    for (particles.items(.x)) |*x| x.* += 1;

    try std.testing.expectEqualSlices(f32, &.{ 2, 3 }, particles.constItems(.x));
    try std.testing.expectEqual(10, particles.get(0).y);
}
