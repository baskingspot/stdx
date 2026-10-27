//! Enum utilities beyond `std.enums`: turn a comptime list of byte
//! strings into an enum whose tags are the strings, and look up the tag
//! with the string length checked first.
//!
//! `Open` generates a non-exhaustive enum. The miss is an unnamed value, so
//! `else` is the miss arm and no tag name is reserved:
//!
//! ```zig
//! const Modes = enums.Open(.{ "transaction", "session", "statement" });
//!
//! switch (Modes.match(value)) {
//!     .transaction => startTransaction(),
//!     .session => startSession(),
//!     .statement => runStatement(),
//!     else => return error.InvalidMode,
//! }
//! ```
//!
//! `Closed` takes the name of a fallback tag and generates an exhaustive
//! enum. The compiler then checks that every tag has an arm:
//!
//! ```zig
//! const Modes = enums.Closed(.{ "transaction", "session", "statement" }, "other");
//!
//! switch (Modes.match(value)) {
//!     .transaction => startTransaction(),
//!     .session => startSession(),
//!     .statement => runStatement(),
//!     .other => return error.InvalidMode,
//! }
//! ```
//!
//! The lookup compares bytes exactly, not text. A tag may be any non-empty
//! byte string without a null byte, so `"content-type"` is the tag
//! `.@"content-type"`. For keys that cannot be tag names, use
//! `static_map.String` or `std.StaticStringMap`.
//!
//! `stringToEnum` is `std.meta.stringToEnum` for an existing enum, with the
//! same length-first lookup.

const std = @import("std");
const testing = std.testing;

/// A non-exhaustive enum generated from `names`, plus the lookup.
///
/// `names` is a tuple of byte strings. Each becomes a tag with the same
/// name. `match` returns the tag, or `miss` when the value is not one of
/// them.
pub fn Open(comptime names: anytype) type {
    comptime validate(names);

    return struct {
        /// The generated enum: one tag per name, plus the unnamed miss value.
        pub const Tag = blk: {
            const IntTag = std.math.IntFittingRange(0, names.len);
            var name_array: [names.len][]const u8 = undefined;
            var value_array: [names.len]IntTag = undefined;
            for (names, 0..) |name, i| {
                name_array[i] = name;
                value_array[i] = @intCast(i);
            }
            const final_names = name_array;
            const final_values = value_array;
            break :blk @Enum(IntTag, .nonexhaustive, &final_names, &final_values);
        };

        /// The value `match` returns for bytes that are not a name.
        pub const miss: Tag = @enumFromInt(names.len);

        /// The names, in the order of the literal.
        pub const keys: []const []const u8 = keys: {
            var arr: [names.len][]const u8 = undefined;
            for (names, 0..) |name, i| arr[i] = name;
            const final = arr;
            break :keys &final;
        };

        /// The number of names.
        pub const count: usize = names.len;

        /// The tag for `value`, or `miss`.
        pub fn match(value: []const u8) Tag {
            if (indexOf(keys, value)) |i| return @enumFromInt(i);
            return miss;
        }

        /// Whether `value` is one of the names.
        pub fn has(value: []const u8) bool {
            return indexOf(keys, value) != null;
        }
    };
}

/// An exhaustive enum generated from `names`, plus `fallback` as the tag for
/// a value that matches no name.
///
/// The switch over `match` must name every tag, `fallback` included.
pub fn Closed(comptime names: anytype, comptime fallback: []const u8) type {
    comptime {
        validate(names);
        checkTag(fallback);
        for (names) |name| {
            if (std.mem.eql(u8, name, fallback)) {
                @compileError("enums.Closed: fallback \"" ++ fallback ++ "\" is also a name");
            }
        }
    }

    return struct {
        /// The generated enum: one tag per name, plus `fallback`.
        pub const Tag = blk: {
            const total = names.len + 1;
            const IntTag = std.math.IntFittingRange(0, total - 1);
            var name_array: [total][]const u8 = undefined;
            var value_array: [total]IntTag = undefined;
            for (names, 0..) |name, i| {
                name_array[i] = name;
                value_array[i] = @intCast(i);
            }
            name_array[names.len] = fallback;
            value_array[names.len] = @intCast(names.len);
            const final_names = name_array;
            const final_values = value_array;
            break :blk @Enum(IntTag, .exhaustive, &final_names, &final_values);
        };

        /// The tag `match` returns for bytes that are not a name.
        pub const miss: Tag = @field(Tag, fallback);

        /// The names, in the order of the literal, without the fallback.
        pub const keys: []const []const u8 = keys: {
            var arr: [names.len][]const u8 = undefined;
            for (names, 0..) |name, i| arr[i] = name;
            const final = arr;
            break :keys &final;
        };

        /// The number of names, without the fallback.
        pub const count: usize = names.len;

        /// The tag for `value`, or `miss`.
        pub fn match(value: []const u8) Tag {
            if (indexOf(keys, value)) |i| return @enumFromInt(i);
            return miss;
        }

        /// Whether `value` is one of the names.
        pub fn has(value: []const u8) bool {
            return indexOf(keys, value) != null;
        }
    };
}

/// The enum value for `value`, or null. The contract of
/// `std.meta.stringToEnum`, with the byte length checked first.
pub fn stringToEnum(comptime E: type, value: []const u8) ?E {
    const Table = struct {
        const fields = switch (@typeInfo(E)) {
            .@"enum" => |info| info.fields,
            else => @compileError("enums.stringToEnum: " ++ @typeName(E) ++
                " is not an enum"),
        };

        const keys: [fields.len][]const u8 = keys: {
            var arr: [fields.len][]const u8 = undefined;
            for (fields, 0..) |field, i| arr[i] = field.name;
            break :keys arr;
        };

        const values: [fields.len]E = values: {
            var arr: [fields.len]E = undefined;
            for (fields, 0..) |field, i| arr[i] = @field(E, field.name);
            break :values arr;
        };
    };

    const i = indexOf(Table.keys, value) orelse return null;
    return Table.values[i];
}

fn validate(comptime names: anytype) void {
    @setEvalBranchQuota(10 * names.len * names.len + 100);
    for (names, 0..) |name, i| {
        checkTag(name);
        for (names, 0..) |other, j| {
            if (i < j and std.mem.eql(u8, name, other)) {
                @compileError("enums: duplicate name \"" ++ name[0..name.len] ++ "\"");
            }
        }
    }
}

/// A tag is written as `.@"..."`, so it can be any byte string except an
/// empty one or one with a null byte. Both are rejected at the use site.
fn checkTag(comptime name: []const u8) void {
    if (name.len == 0) {
        @compileError("enums: an empty name cannot be a tag");
    }
    if (std.mem.indexOfScalar(u8, name, 0) != null) {
        @compileError("enums: a name cannot contain a null byte");
    }
}

/// The index of `value` in `keys`, or null.
///
/// The compiler switches on `value.len` first, so a value whose length no
/// key has costs one test. Each arm then compares only the keys of that
/// length.
fn indexOf(comptime keys: anytype, value: []const u8) ?usize {
    if (keys.len == 0) return null;

    const max_len = comptime blk: {
        var m: usize = 0;
        for (keys) |key| m = @max(m, key.len);
        break :blk m;
    };

    @setEvalBranchQuota(10 * keys.len * (max_len + 1) + 100);
    switch (value.len) {
        inline 0...max_len => |len| {
            inline for (keys, 0..) |key, i| {
                if (comptime key.len == len) {
                    if (eqlFixed(len, value, key)) return i;
                }
            }
            return null;
        },
        else => return null,
    }
}

/// Compare `a` and `b`, whose length is known to be `len`, using the
/// widest loads that stay in bounds.
///
/// `std.mem.eql` cannot see the length here, so it computes its load
/// offsets at runtime. With `len` fixed, two loads from the ends cover
/// any slice up to 16 bytes, and longer slices walk 8-byte chunks.
/// The loads use native byte order on both sides. Equality does not
/// depend on the order.
fn eqlFixed(comptime len: usize, a: []const u8, b: []const u8) bool {
    if (len < 4) return std.mem.eql(u8, a[0..len], b[0..len]);
    if (len == 4) return u32At(a, 0) == u32At(b, 0);
    if (len < 8) return u32At(a, 0) == u32At(b, 0) and u32At(a, len - 4) == u32At(b, len - 4);
    if (len == 8) return u64At(a, 0) == u64At(b, 0);

    comptime var i: usize = 0;
    inline while (i + 8 <= len) : (i += 8) {
        if (u64At(a, i) != u64At(b, i)) return false;
    }
    if (i < len) {
        const tail = len - 8;
        if (u64At(a, tail) != u64At(b, tail)) return false;
    }
    return true;
}

inline fn u32At(s: []const u8, comptime i: usize) u32 {
    return @bitCast(s[i..][0..4].*);
}

inline fn u64At(s: []const u8, comptime i: usize) u64 {
    return @bitCast(s[i..][0..8].*);
}

const PoolMode = enum { transaction, session, statement, unknown };

const OpenModes = Open(.{ "transaction", "session", "statement" });
const ClosedModes = Closed(.{ "transaction", "session", "statement" }, "other");

test "Open: else is the miss" {
    const hit: PoolMode = switch (OpenModes.match("session")) {
        .transaction => .transaction,
        .session => .session,
        .statement => .statement,
        else => .unknown,
    };
    try testing.expectEqual(PoolMode.session, hit);

    const missing: PoolMode = switch (OpenModes.match("sessions")) {
        .transaction => .transaction,
        .session => .session,
        .statement => .statement,
        else => .unknown,
    };
    try testing.expectEqual(PoolMode.unknown, missing);
}

test "Closed: every tag has an arm" {
    const hit: PoolMode = switch (ClosedModes.match("statement")) {
        .transaction => .transaction,
        .session => .session,
        .statement => .statement,
        .other => .unknown,
    };
    try testing.expectEqual(PoolMode.statement, hit);

    const missing: PoolMode = switch (ClosedModes.match("statements")) {
        .transaction => .transaction,
        .session => .session,
        .statement => .statement,
        .other => .unknown,
    };
    try testing.expectEqual(PoolMode.unknown, missing);
}

test "Open: has, keys, count, miss" {
    try testing.expect(OpenModes.has("statement"));
    try testing.expect(!OpenModes.has("statements"));
    try testing.expectEqual(@as(usize, 3), OpenModes.count);
    try testing.expectEqualStrings("session", OpenModes.keys[1]);
    try testing.expectEqual(OpenModes.miss, OpenModes.match("statements"));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(OpenModes.miss));
}

test "Closed: has, keys, count, miss" {
    try testing.expect(ClosedModes.has("statement"));
    try testing.expect(!ClosedModes.has("statements"));
    try testing.expectEqual(@as(usize, 3), ClosedModes.count);
    try testing.expectEqualStrings("session", ClosedModes.keys[1]);
    try testing.expectEqual(ClosedModes.miss, ClosedModes.match("statements"));
    try testing.expectEqualStrings("other", @tagName(ClosedModes.miss));
}

test "tags are not limited to identifiers" {
    const Headers = Open(.{ "content-type", "content-length", "404", "with space" });
    try testing.expectEqualStrings("content-type", Headers.keys[0]);
    try testing.expectEqual(@as(usize, 0), @intFromEnum(Headers.match("content-type")));
    try testing.expectEqual(@as(usize, 2), @intFromEnum(Headers.match("404")));
    try testing.expectEqual(Headers.miss, Headers.match("Content-Type"));

    const hit = switch (Headers.match("with space")) {
        .@"content-type" => false,
        .@"content-length" => false,
        .@"404" => false,
        .@"with space" => true,
        else => false,
    };
    try testing.expect(hit);
}

test "a closed fallback can be any tag" {
    const Headers = Closed(.{ "content-type", "content-length" }, "not a tag");
    try testing.expectEqualStrings("not a tag", @tagName(Headers.miss));
    try testing.expectEqual(Headers.miss, Headers.match("content-encoding"));
    try testing.expect(Headers.has("content-length"));
    try testing.expect(!Headers.has("not a tag"));
}

test "tags can contain any non-null byte" {
    const Raw = Open(.{ "\xff\xfe", "ok" });
    const hit = switch (Raw.match("\xff\xfe")) {
        .@"\xff\xfe" => true,
        .ok => false,
        else => false,
    };
    try testing.expect(hit);
    try testing.expectEqual(Raw.miss, Raw.match("\xff"));
}

test "every length up to 40 compares exactly" {
    const C = Open(.{
        "a",                               "ab",
        "abc",                             "abcd",
        "abcde",                           "abcdef",
        "abcdefg",                         "abcdefgh",
        "abcdefghi",                       "abcdefghij",
        "abcdefghijk",                     "abcdefghijkl",
        "abcdefghijklm",                   "abcdefghijklmn",
        "abcdefghijklmno",                 "abcdefghijklmnop",
        "abcdefghijklmnopq",               "abcdefghijklmnopqr",
        "abcdefghijklmnopqrs",             "abcdefghijklmnopqrst",
        "abcdefghijklmnopqrstu",           "abcdefghijklmnopqrstuv",
        "abcdefghijklmnopqrstuvw",         "abcdefghijklmnopqrstuvwx",
        "abcdefghijklmnopqrstuvwxy",       "abcdefghijklmnopqrstuvwxyz",
        "abcdefghijklmnopqrstuvwxyzabc",   "abcdefghijklmnopqrstuvwxyzabcd",
        "abcdefghijklmnopqrstuvwxyzabcde", "abcdefghijklmnopqrstuvwxyzabcdef",
    });

    inline for (C.keys, 0..) |key, i| {
        try testing.expectEqual(@as(usize, i), @intFromEnum(C.match(key)));
        if (key.len >= 16) {
            var buf: [64]u8 = undefined;
            const copy = buf[0..key.len];
            @memcpy(copy, key);
            copy[key.len / 2] ^= 0x01;
            try testing.expectEqual(C.miss, C.match(copy));
        }
        var buf: [64]u8 = undefined;
        const copy = buf[0..key.len];
        @memcpy(copy, key);
        copy[key.len - 1] ^= 0x01;
        try testing.expectEqual(C.miss, C.match(copy));
    }
}

test "empty name list" {
    const O = Open(.{});
    try testing.expectEqual(O.miss, O.match(""));
    try testing.expectEqual(O.miss, O.match("anything"));
    try testing.expect(!O.has("anything"));

    const C = Closed(.{}, "other");
    try testing.expectEqual(C.miss, C.match("anything"));
    try testing.expectEqualStrings("other", @tagName(C.miss));
}

test "stringToEnum matches field names" {
    try testing.expectEqual(PoolMode.transaction, stringToEnum(PoolMode, "transaction").?);
    try testing.expectEqual(PoolMode.unknown, stringToEnum(PoolMode, "unknown").?);
    try testing.expectEqual(@as(?PoolMode, null), stringToEnum(PoolMode, "transactions"));
    try testing.expectEqual(@as(?PoolMode, null), stringToEnum(PoolMode, ""));
}

test "stringToEnum handles spaced names and non-consecutive values" {
    const Spaced = enum { @"content-type", @"content-length" };
    try testing.expectEqual(Spaced.@"content-type", stringToEnum(Spaced, "content-type").?);
    try testing.expectEqual(@as(?Spaced, null), stringToEnum(Spaced, "content"));

    const Sparse = enum(u8) { a = 3, b = 7 };
    try testing.expectEqual(Sparse.b, stringToEnum(Sparse, "b").?);
    try testing.expectEqual(@as(?Sparse, null), stringToEnum(Sparse, "c"));
}

test "stringToEnum works at comptime" {
    comptime {
        try testing.expectEqual(PoolMode.statement, stringToEnum(PoolMode, "statement").?);
        try testing.expectEqual(@as(?PoolMode, null), stringToEnum(PoolMode, "statements"));
    }
}
