//! The base32 module's benchmarks: encode and decode of a 10-byte key.

const testingx = @import("testingx");

const stdx = @import("stdx");
const base32 = stdx.base32;

pub fn benchmarkBase32Encode(b: *testingx.B) !void {
    var key: [10]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @truncate(index * 31);

    var sink: u8 = 0;
    var i: u8 = 0;
    while (try b.loop()) : (i +%= 1) {
        key[0] = i;
        const token = base32.encode(10, &key);
        sink +%= token[0];
    }
    b.keepAlive(sink);
    b.keepAlive(&key);
}

pub fn benchmarkBase32Decode(b: *testingx.B) !void {
    const token: [16]u8 = "0123456789abcdef".*;
    const hidden = b.blackBox(&token);

    var sink: u8 = 0;
    while (try b.loop()) {
        const bytes = try base32.decode(10, hidden);
        sink +%= bytes[0];
    }
    b.keepAlive(sink);
}
