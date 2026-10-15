const std = @import("std");
const Io = std.Io;
const RateLimit = @import("stdx").time.RateLimit;

// A failure that repeats per connection logs once per interval. The
// line carries the number of failures it stands for.
fn logAcceptFailure(limit: *RateLimit, now: Io.Timestamp, out: *Io.Writer) !void {
    const held_back = limit.admit(now) orelse return;
    try out.print("accept failed, {d} more held back\n", .{held_back});
}

fn atMs(ms: i64) Io.Timestamp {
    return .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
}

test "a storm logs once per interval" {
    var limit: RateLimit = .default;
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);

    // The first failure goes out. Nine more inside the interval do not.
    try logAcceptFailure(&limit, atMs(0), &out);
    for (1..10) |i| try logAcceptFailure(&limit, atMs(@as(i64, @intCast(i)) * 100), &out);
    try std.testing.expectEqualStrings("accept failed, 0 more held back\n", out.buffered());

    // The next interval logs again and reports the nine.
    try logAcceptFailure(&limit, atMs(1000), &out);
    try std.testing.expectEqualStrings(
        "accept failed, 0 more held back\naccept failed, 9 more held back\n",
        out.buffered(),
    );
}

// `default` is one second. `init` takes any `Io.Duration`.
test "a custom interval" {
    var limit: RateLimit = .init(.fromMilliseconds(250));
    try std.testing.expectEqual(0, limit.admit(atMs(0)));
    try std.testing.expectEqual(null, limit.admit(atMs(100)));
    try std.testing.expectEqual(1, limit.admit(atMs(250)));
}
