const std = @import("std");
const Ip4 = @import("stdx").net.Ip4;

// Count the addresses from `first` to `last`, inclusive. `next` carries
// across octets and returns null past the last address, so the loop ends
// at 255.255.255.255 instead of wrapping.
fn countRange(first: Ip4, last: Ip4) u32 {
    var count: u32 = 0;
    var current = first;
    while (current.order(last) != .gt) {
        count += 1;
        current = current.next() orelse break;
    }
    return count;
}

test "a range that crosses an octet" {
    const first: Ip4 = .parseComptime("10.0.0.250");
    try std.testing.expectEqual(12, countRange(first, .parseComptime("10.0.1.5")));
}

test "a range that ends at the top of the space" {
    try std.testing.expectEqual(2, countRange(.parseComptime("255.255.255.254"), .broadcast));
}

test "order compares numerically" {
    const two: Ip4 = .parseComptime("2.0.0.0");
    try std.testing.expectEqual(.lt, two.order(.parseComptime("10.0.0.0")));

    const ten: Ip4 = .parseComptime("10.0.0.2");
    try std.testing.expectEqual(Ip4.parseComptime("10.0.0.1"), ten.prev());
}
