//! The base64 module's benchmarks: the vector kernels against the std
//! codec they replace, at a size that exercises the block loops and at a
//! size where the tail dominates.

const testingx = @import("testingx");

const std = @import("std");
const stdx = @import("stdx");
const base64 = stdx.base64;

const large_len = 1 << 16;
const small_len = 64;

var source: [large_len]u8 = undefined;
var encoded: [large_len / 3 * 4 + 4]u8 = undefined;
var decoded: [large_len]u8 = undefined;

pub fn benchmarkEncodeLarge(b: *testingx.B) !void {
    fill();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(source[0..large_len]);
        sink +%= base64.standard.encode(&encoded, hidden).len;
    }
}

pub fn benchmarkEncodeLargeStd(b: *testingx.B) !void {
    fill();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(source[0..large_len]);
        sink +%= std.base64.standard.Encoder.encode(&encoded, hidden).len;
    }
}

pub fn benchmarkDecodeLarge(b: *testingx.B) !void {
    fill();
    const chars = base64.standard.encode(&encoded, source[0..large_len]);
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(chars);
        sink +%= (try base64.standard.decode(&decoded, hidden)).len;
    }
}

pub fn benchmarkDecodeLargeStd(b: *testingx.B) !void {
    fill();
    const chars = base64.standard.encode(&encoded, source[0..large_len]);
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(chars);
        const out = decoded[0 .. hidden.len / 4 * 3];
        std.base64.standard.Decoder.decode(out, hidden) catch unreachable;
        sink +%= hidden.len;
    }
}

pub fn benchmarkEncodeSmall(b: *testingx.B) !void {
    fill();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(source[0..small_len]);
        sink +%= base64.standard.encode(&encoded, hidden).len;
    }
}

pub fn benchmarkEncodeSmallStd(b: *testingx.B) !void {
    fill();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(source[0..small_len]);
        sink +%= std.base64.standard.Encoder.encode(&encoded, hidden).len;
    }
}

pub fn benchmarkDecodeSmall(b: *testingx.B) !void {
    fill();
    const chars = base64.standard.encode(&encoded, source[0..small_len]);
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(chars);
        sink +%= (try base64.standard.decode(&decoded, hidden)).len;
    }
}

pub fn benchmarkDecodeSmallStd(b: *testingx.B) !void {
    fill();
    const chars = base64.standard.encode(&encoded, source[0..small_len]);
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        const hidden = b.blackBox(chars);
        const out = decoded[0 .. hidden.len / 4 * 3];
        std.base64.standard.Decoder.decode(out, hidden) catch unreachable;
        sink +%= hidden.len;
    }
}

fn fill() void {
    for (&source, 0..) |*byte, i| byte.* = @truncate(i *% 151 +% 7);
}
