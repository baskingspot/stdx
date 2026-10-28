//! The prefix_map module's benchmarks: longest-prefix and exact lookups
//! against std's length-bucketed StaticStringMap over the same 1000 keys.

const std = @import("std");
const testingx = @import("testingx");

const stdx = @import("stdx");
const prefix_map = stdx.prefix_map;

const n = 1000;
var key_buf: [n][40]u8 = undefined;
var kvs: [n]struct { []const u8, u16 } = undefined;
var probes: [2048][]const u8 = undefined;
var prepared = false;

fn prepare() void {
    if (prepared) return;
    for (0..n) |i| {
        const key = std.fmt.bufPrint(&key_buf[i], "api/v{d}/item{d}/", .{
            i % 40,
            i,
        }) catch unreachable;
        kvs[i] = .{ key, @intCast(i) };
    }

    const tail = [_][]const u8{
        "",
        "api/",
        "api/v0/",
        "api/v0/item0/",
        "api/v0/item0/x",
        "api/v39/item999/deep",
        "api/v40/item1/",
        "other",
    };
    var p: usize = 0;
    for (kvs) |kv| {
        if (p == probes.len) break;
        probes[p] = kv[0];
        p += 1;
        if (p == probes.len) break;
        probes[p] = tail[p % tail.len];
        p += 1;
    }
    while (p < probes.len) : (p += 1) probes[p] = kvs[p % n][0];
    prepared = true;
}

const Prefixes = prefix_map.Map(u16);

pub fn benchmarkPrefixMapGet(b: *testingx.B) !void {
    prepare();
    const map = try Prefixes.init(&kvs, std.heap.page_allocator);
    defer map.deinit(std.heap.page_allocator);

    var sink: u32 = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        sink +%= map.get(probes[b.blackBox(&i).* & (probes.len - 1)]) orelse 0;
    }
    b.keepAlive(sink);
}

pub fn benchmarkPrefixMapLongest(b: *testingx.B) !void {
    prepare();
    const map = try Prefixes.init(&kvs, std.heap.page_allocator);
    defer map.deinit(std.heap.page_allocator);

    var sink: u32 = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        sink +%= map.getLongestPrefix(probes[b.blackBox(&i).* & (probes.len - 1)]) orelse 0;
    }
    b.keepAlive(sink);
}

const Static = std.StaticStringMap(u16);

pub fn benchmarkStaticStringMapGet(b: *testingx.B) !void {
    prepare();
    const map = try Static.init(&kvs, std.heap.page_allocator);
    defer map.deinit(std.heap.page_allocator);

    var sink: u32 = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        sink +%= map.get(probes[b.blackBox(&i).* & (probes.len - 1)]) orelse 0;
    }
    b.keepAlive(sink);
}

pub fn benchmarkStaticStringMapLongest(b: *testingx.B) !void {
    prepare();
    const map = try Static.init(&kvs, std.heap.page_allocator);
    defer map.deinit(std.heap.page_allocator);

    var sink: u32 = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        const kv = map.getLongestPrefix(probes[b.blackBox(&i).* & (probes.len - 1)]) orelse {
            continue;
        };
        sink +%= kv.value;
    }
    b.keepAlive(sink);
}
