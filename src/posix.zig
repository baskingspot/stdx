//! POSIX extensions to `std.posix`.
//!
//! Raw-layer calls std forgot to wrap, with errno decoded by hand instead of
//! routed through `posix.unexpectedErrno`. For callers that own raw socket
//! handles (io_uring data paths); code holding an `Io.net.Socket` should
//! prefer the typed APIs instead.

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const net = Io.net;

pub const GetSockNameError =
    posix.GetSockNameError ||
    posix.UnexpectedError ||
    error{AddressFamilyNotSupported};

/// Peer address of a connected socket, by fd. `error.SocketUnconnected`
/// covers ENOTCONN — std's `posix.getpeername` does the conversion, so
/// this wrapper does not decode errno by hand.
pub fn getpeername(fd: posix.socket_t) GetSockNameError!net.Ip4Address {
    var in: posix.sockaddr.in = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getpeername(fd, @ptrCast(&in), &len);
    return fromSockAddrIn(&in, len);
}

/// Local address of a socket, by fd. The port is the bound (possibly
/// ephemeral) port, which is how a caller recovers the real port after
/// binding to port 0.
///
/// std wraps `getpeername` but not `getsockname` in 0.16, so this decodes
/// errno over the raw call.
pub fn getsockname(fd: posix.socket_t) GetSockNameError!net.Ip4Address {
    var in: posix.sockaddr.in = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    return switch (posix.errno(posix.system.getsockname(fd, @ptrCast(&in), &len))) {
        .SUCCESS => fromSockAddrIn(&in, len),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn fromSockAddrIn(
    in: *const posix.sockaddr.in,
    len: posix.socklen_t,
) GetSockNameError!net.Ip4Address {
    // Matches the conversion in std's Io.Threaded: port is network-endian in
    // the sockaddr and native-endian in net.Ip4Address.
    if (in.family != posix.AF.INET) return error.AddressFamilyNotSupported;
    assert(len >= @sizeOf(posix.sockaddr.in));
    return .{
        .port = mem.bigToNative(u16, in.port),
        .bytes = @bitCast(in.addr),
    };
}

test getpeername {
    const io = testing.io;
    const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    const connect_addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    const client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server = try listener.accept(io);
    defer server.close(io);

    // The server side's peer is the client's local address.
    const peer = try getpeername(server.socket.handle);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &peer.bytes);
    const client_local = try getsockname(client.socket.handle);
    try testing.expectEqual(peer.port, client_local.port);
}

test getsockname {
    const io = testing.io;
    const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    try testing.expect(port != 0);

    const connect_addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    const client = try connect_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server = try listener.accept(io);
    defer server.close(io);

    // The server side's local address is the listener's bound port.
    const server_local = try getsockname(server.socket.handle);
    try testing.expectEqual(port, server_local.port);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &server_local.bytes);

    // The client side's local port is ephemeral, distinct from the bound port.
    const client_local = try getsockname(client.socket.handle);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &client_local.bytes);
    try testing.expect(client_local.port != port);
}
