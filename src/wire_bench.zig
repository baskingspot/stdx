//! The wire module's benchmarks: the forward big-endian write and read paths.

const testingx = @import("testingx");

const stdx = @import("stdx");
const wire = stdx.wire;

pub fn benchmarkWireWrite(b: *testingx.B) !void {
    var storage: [64]u8 = undefined;
    var writer: wire.Writer(.big) = .init(&storage);
    var sink: usize = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        writer.clear();
        writer.appendAssumeCapacity(u8, @truncate(i));
        writer.appendAssumeCapacity(u16, @truncate(i));
        writer.appendAssumeCapacity(u24, @truncate(i));
        writer.appendAssumeCapacity(u32, i);
        writer.appendAssumeCapacity(u64, i);
        sink +%= writer.buffered().len + writer.constBuffered()[0];
    }
    b.keepAlive(sink);
    b.keepAlive(&writer);
}

pub fn benchmarkWireRead(b: *testingx.B) !void {
    var storage: [32]u8 = undefined;
    var seed: wire.Writer(.big) = .init(&storage);
    seed.appendAssumeCapacity(u8, 0xab);
    seed.appendAssumeCapacity(u16, 0x0102);
    seed.appendAssumeCapacity(u24, 0x030405);
    seed.appendAssumeCapacity(u32, 0x06070809);
    seed.appendAssumeCapacity(u64, 0x0a0b0c0d0e0f1011);
    const input_len = seed.constBuffered().len;

    var sink: u64 = 0;
    while (try b.loop()) {
        const input = b.blackBox(&storage)[0..input_len];
        var reader: wire.Reader(.big) = .init(input);
        sink +%= @as(u64, reader.assumeRead(u8));
        sink +%= @as(u64, reader.assumeRead(u16));
        sink +%= @as(u64, reader.assumeRead(u24));
        sink +%= @as(u64, reader.assumeRead(u32));
        sink +%= reader.assumeRead(u64);
        sink +%= @as(u64, @intCast(reader.remaining().len));
    }
    b.keepAlive(sink);
}
