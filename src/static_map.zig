//! Comptime-generated static maps: the bounded map's Robin Hood probe
//! logic built at compile time from a literal, immutable, zero runtime
//! initialization.
//!
//! std covers string keys (`std.StaticStringMap(V)` with `initComptime`) and
//! dense enums (`std.EnumMap`); sparse non-string keys — opcode tables,
//! protocol constants — have nothing. This module fills that gap by building
//! a `bounded_array_hash_map.Custom` at comptime and exposing it as a
//! constant: the whole table lives in `.rodata`, lookups are a probe walk
//! with no allocation and no lazy init.
//!
//! The literal is a tuple of `.{key, value}` tuples, std's
//! `StaticStringMap.initComptime` shape. A duplicate key is a compile error,
//! not a silent overwrite.

const std = @import("std");
const testing = std.testing;

const map_mod = @import("bounded_array_hash_map.zig");

/// A static map with an explicit context, comptime-built from `kvs`.
pub fn Custom(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime kvs: anytype,
) type {
    return struct {
        /// The comptime-filled table. All state is a compile-time constant.
        pub const map = blk: {
            const Map = map_mod.Custom(K, V, Context, kvs.len);
            var m: Map = .init;
            for (kvs) |kv| {
                const result = m.getOrPut(kv[0]) catch unreachable;
                if (result.found_existing) {
                    @compileError("static map: duplicate key " ++ debugKey(kv[0]));
                }
                result.value_ptr.* = kv[1];
            }
            break :blk m;
        };

        /// The number of entries: always `kvs.len` — duplicates are
        /// compile errors, so nothing is dropped.
        pub const count: usize = kvs.len;

        /// The value for `key`, or null.
        pub fn get(key: K) ?V {
            return map.get(key);
        }

        /// The value for `key`. Asserts presence — the table is a literal,
        /// so an absent key is a programming error, not a runtime case.
        pub fn getAssertPresent(key: K) V {
            return get(key) orelse unreachable;
        }

        pub fn has(key: K) bool {
            return map.contains(key);
        }

        /// The keys in insertion order: a comptime-known slice.
        pub const keys = map.key_buffer[0..kvs.len];

        /// The values in insertion order: a comptime-known slice.
        pub const values = map.value_buffer[0..kvs.len];
        fn debugKey(comptime key: K) []const u8 {
            return switch (@typeInfo(K)) {
                .pointer => key,
                else => "(not printable)",
            };
        }
    };
}

/// A static map with std's auto context. Slices — including `[]const u8` —
/// are rejected by `std.hash.autoHash`; string keys use `String`.
pub fn Auto(comptime K: type, comptime V: type, comptime kvs: anytype) type {
    return Custom(K, V, std.hash_map.AutoContext(K), kvs);
}

/// A static string-keyed map, like `std.StaticStringMap` — string keys are
/// a separate entry point because `std.hash.autoHash` rejects slices.
pub fn String(comptime V: type, comptime kvs: anytype) type {
    return Custom([]const u8, V, std.hash_map.StringContext, kvs);
}

test "Auto: get, has, keys, values" {
    const Codes = Auto(u16, []const u8, .{
        .{ 0x0001, "input" },
        .{ 0x0002, "output" },
        .{ 0xFFFE, "halt" },
    });

    try testing.expectEqual(@as(usize, 3), Codes.count);
    try testing.expectEqualStrings("input", Codes.get(0x0001).?);
    try testing.expectEqualStrings("halt", Codes.get(0xFFFE).?);
    try testing.expect(Codes.get(0x0003) == null);
    try testing.expect(Codes.has(0x0002));
    try testing.expect(!Codes.has(0x0003));
    // Insertion order.
    try testing.expectEqual(@as(u16, 0x0001), Codes.keys[0]);
    try testing.expectEqual(@as(u16, 0xFFFE), Codes.keys[2]);
    try testing.expectEqualStrings("output", Codes.values[1]);
    // The map is a const: get at comptime too.
    comptime try testing.expectEqualStrings("input", Codes.get(0x0001).?);
}

test "String: str keys by content" {
    const Ports = String(u16, .{
        .{ "http", 80 },
        .{ "https", 443 },
    });

    try testing.expectEqual(@as(u16, 80), Ports.get("http").?);
    try testing.expectEqual(@as(u16, 443), Ports.get("https").?);
    try testing.expect(Ports.get("ftp") == null);
    // Keys are slices: lookups compare content, not pointers.
    const alias = "http";
    try testing.expectEqual(@as(u16, 80), Ports.get(alias).?);
}

test "Custom: narrow-hash collisions still fill" {
    // Every key hashes to the same slot: the probe walk must place all
    // entries. Comptime build walks the same path the runtime map would.
    const Collide = Custom(u32, u8, AllCollideContext, .{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 } });
    try testing.expectEqual(@as(usize, 3), Collide.count);
    try testing.expectEqual(@as(u8, 10), Collide.get(1).?);
    try testing.expectEqual(@as(u8, 30), Collide.get(3).?);
    try testing.expect(Collide.get(4) == null);
}

const AllCollideContext = struct {
    pub fn hash(_: AllCollideContext, _: u32) u32 {
        return 0;
    }

    pub fn eql(_: AllCollideContext, a: u32, b: u32) bool {
        return a == b;
    }
};

test "V = void works as a set" {
    const Primes = Auto(u8, void, .{ .{ 2, {} }, .{ 3, {} }, .{ 5, {} } });
    try testing.expect(Primes.has(2));
    try testing.expect(!Primes.has(4));
    try testing.expect(Primes.get(5) != null);
}
