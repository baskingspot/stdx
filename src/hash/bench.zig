//! The hash module's benchmarks: RapidHash against Wyhash, the incumbent,
//! on small keys (4/8/16 bytes, the author's own workload shape) and a
//! 16 KiB buffer.

const bench = @import("benchmark");

const std = @import("std");

const stdx = @import("stdx");
const RapidHash = stdx.hash.RapidHash;

// The small-key workload cycles 4/8/16-byte slices of a fixed 4096-key
// table, the large one hashes a single 16 KiB buffer. Each implementation
// gets its own timed loop — the names pair up, the hashes never
// interleave.
const hash_keys = blk: {
    @setEvalBranchQuota(100_000);
    var keys: [4096][16]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&keys) |*key| {
        for (key) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(state >> 32);
        }
    }
    break :blk keys;
};

const hash_key_lens = [_]usize{ 4, 8, 16 };

const hash_large_len = 16 * 1024;

const hash_large = blk: {
    @setEvalBranchQuota(100_000);
    var data: [hash_large_len]u8 = undefined;
    var state: u64 = 0x2545f4914f6a03d5;
    for (&data) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    break :blk data;
};

pub fn benchmarkRapidhashSmall(b: *bench.B) !void {
    var sink: u64 = 0;
    var i: usize = 0;
    while (try b.loop()) {
        const key: []const u8 = b.blackBox(&hash_keys[i & (hash_keys.len - 1)]);
        sink +%= RapidHash.hash(0, key[0..hash_key_lens[i % hash_key_lens.len]]);
        i += 1;
    }
    b.keepAlive(sink);
}

pub fn benchmarkWyhashSmall(b: *bench.B) !void {
    var sink: u64 = 0;
    var i: usize = 0;
    while (try b.loop()) {
        const key: []const u8 = b.blackBox(&hash_keys[i & (hash_keys.len - 1)]);
        sink +%= std.hash.Wyhash.hash(0, key[0..hash_key_lens[i % hash_key_lens.len]]);
        i += 1;
    }
    b.keepAlive(sink);
}

pub fn benchmarkRapidhashLarge(b: *bench.B) !void {
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= RapidHash.hash(0, b.blackBox(&hash_large));
    }
    b.keepAlive(sink);
}

pub fn benchmarkWyhashLarge(b: *bench.B) !void {
    var sink: u64 = 0;
    while (try b.loop()) {
        sink +%= std.hash.Wyhash.hash(0, b.blackBox(&hash_large));
    }
    b.keepAlive(sink);
}
