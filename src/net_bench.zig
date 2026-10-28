//! The net module's benchmarks: IPv4 and prefix parsing, and the host:port
//! splitter.

const testingx = @import("testingx");

const stdx = @import("stdx");
const net = stdx.net;

pub fn benchmarkIp4Parse(b: *testingx.B) !void {
    const text: [8]u8 = "10.1.2.3".*;
    const hidden = b.blackBox(&text);

    var sink: u8 = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const ip = net.Ip4.parse(hidden) catch unreachable;
        sink +%= ip.bytes[0];
    }
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
