//! The lru module's benchmarks: hits (which relink) and misses against a
//! warmed cache, and puts that mix updates and evictions.

const testingx = @import("testingx");

const stdx = @import("stdx");
const lru = stdx.lru;

const Cache = lru.Auto(u32, u32, 1024);

fn warm(cache: *Cache) void {
    var key: u32 = 0;
    while (key < 1024) : (key += 1) {
        _ = cache.put(key, key);
    }
}

pub fn benchmarkLruGetHit(b: *testingx.B) !void {
    var cache: Cache = .empty;
    warm(&cache);

    var sink: u32 = 0;
    defer b.keepAlive(sink);
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        const key = b.blackBox(&i).* & 1023;
        sink +%= cache.get(key).?.*;
    }
}

pub fn benchmarkLruGetMiss(b: *testingx.B) !void {
    var cache: Cache = .empty;
    warm(&cache);

    var sink: u32 = 0;
    defer b.keepAlive(sink);
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        const key = (b.blackBox(&i).* & 1023) + 1024;
        sink += @intFromBool(cache.get(key) == null);
    }
}

pub fn benchmarkLruPut(b: *testingx.B) !void {
    var cache: Cache = .empty;

    var sink: u32 = 0;
    defer b.keepAlive(sink);
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        const key = b.blackBox(&i).* & 2047;
        sink +%= cache.put(key, key).replaced orelse 0;
    }
}
