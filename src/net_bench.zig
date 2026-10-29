//! The net module's benchmarks: dotted-quad parsing against the std parser,
//! the prefix parser, and the host:port splitter.

const std = @import("std");

const stdx = @import("stdx");
const net = stdx.net;
const testingx = @import("testingx");

const Impl = enum { swar, std };

const Input = struct {
    name: []const u8,
    text: []const u8,
};

const inputs = [_]Input{
    .{ .name = "short", .text = "1.1.1.1" },
    .{ .name = "common", .text = "10.1.2.3" },
    .{ .name = "private", .text = "192.168.100.200" },
    .{ .name = "max", .text = "255.255.255.255" },
};

fn Case(comptime text: []const u8, comptime impl: Impl) type {
    return struct {
        fn run(b: *testingx.B) !void {
            var sink: u32 = 0;
            defer b.keepAlive(sink);
            const hidden = b.blackBox(text);
            while (try b.loop()) {
                sink +%= switch (impl) {
                    .swar => @as(u32, @bitCast((net.Ip4.parse(hidden) catch unreachable).bytes)),
                    .std => @as(u32, @bitCast(stdParseBytes(hidden))),
                };
            }
        }
    };
}

pub fn benchmarkIp4Parse(b: *testingx.B) !void {
    inline for (inputs) |input| {
        inline for (.{ Impl.swar, Impl.std }) |impl| {
            const name = input.name ++ "/" ++ @tagName(impl);
            _ = try b.run(name, Case(input.text, impl).run);
        }
    }
}

inline fn stdParseBytes(text: []const u8) [4]u8 {
    return (net.Ip4Address.parse(text, 0) catch unreachable).bytes;
}

pub fn benchmarkPrefix4Parse(b: *testingx.B) !void {
    const text: [10]u8 = "10.0.0.0/8".*;
    const hidden = b.blackBox(&text);

    var sink: u8 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const prefix = net.Prefix4.parse(hidden) catch unreachable;
        sink +%= prefix.addr.bytes[0];
    }
}

pub fn benchmarkHostPortParse(b: *testingx.B) !void {
    const text: [15]u8 = "example.com:853".*;
    const hidden = b.blackBox(&text);

    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const endpoint = net.HostPort.parse(hidden, 53) catch unreachable;
        sink +%= endpoint.host.len + endpoint.port;
    }
}
