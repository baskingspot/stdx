const std = @import("std");
const stdx = @import("stdx");
const buffer = stdx.buffer;
const Ip4 = stdx.net.Ip4;

const Backend = struct {
    addr: Ip4,
    port: u16,
};

// A list field that copies with its struct. No allocator, no deinit, no
// ownership to track.
const BackendList = buffer.Array(Backend, 8);

const Config = struct {
    listen: Ip4 = .loopback,
    backends: BackendList = .empty,
};

test "a config copies by value" {
    var config: Config = .{};
    try config.backends.append(.{ .addr = .parseComptime("10.0.0.1"), .port = 5432 });

    // The copy owns its own list. A reload can edit one and keep the other.
    var next = config;
    try next.backends.append(.{ .addr = .parseComptime("10.0.0.2"), .port = 5432 });

    try std.testing.expectEqual(1, config.backends.constSlice().len);
    try std.testing.expectEqual(2, next.backends.constSlice().len);
}

test "the whole capacity travels with the value" {
    // A copy moves every byte of the storage, used or not. Keep the
    // capacity close to the real maximum.
    try std.testing.expect(@sizeOf(buffer.Array(u8, 4096)) >= 4096);
}
