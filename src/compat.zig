//! Shims for the Zig 0.16 and 0.17 APIs. Private to the module.

const std = @import("std");

/// Zig 0.17's `zig fmt` rewrites these to their `@backingInt` forms, which
/// Zig 0.16 cannot compile. Keep them out of the formatter's reach.
// zig fmt: off
pub fn enumToInt(e: anytype) @typeInfo(@TypeOf(e)).@"enum".tag_type {
    return @intFromEnum(e);
}
pub fn enumFromInt(comptime E: type, raw: anytype) E {
    return @enumFromInt(raw);
}
// zig fmt: on

/// Zig 0.17 removed the `**` array-repeat operator.
pub fn repeatString(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

// Zig 0.17 split a container's `fields` into parallel `field_names` and
// `field_types` arrays, and added `pointer_stability` to ArrayList.
pub fn fieldCount(comptime info: anytype) usize {
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names.len;
    return info.fields.len;
}

pub fn fieldName(comptime info: anytype, comptime i: usize) [:0]const u8 {
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names[i];
    return info.fields[i].name;
}

pub fn FieldType(comptime info: anytype, comptime i: usize) type {
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_types[i];
    return info.fields[i].type;
}

pub fn fieldIsComptime(comptime info: anytype, comptime i: usize) bool {
    if (comptime @hasField(@TypeOf(info), "field_attrs")) return info.field_attrs[i].@"comptime";
    return info.fields[i].is_comptime;
}

pub fn enumIsExhaustive(comptime info: anytype) bool {
    if (comptime @hasField(@TypeOf(info), "mode")) return info.mode == .exhaustive;
    return info.is_exhaustive;
}

pub fn fnParamCount(comptime F: type) usize {
    const info = @typeInfo(F).@"fn";
    if (comptime @hasField(@TypeOf(info), "param_types")) return info.param_types.len;
    return info.params.len;
}

pub fn fnParamType(comptime F: type, comptime i: usize) ?type {
    const info = @typeInfo(F).@"fn";
    if (comptime @hasField(@TypeOf(info), "param_types")) return info.param_types[i];
    return info.params[i].type;
}

pub fn fieldAlign(comptime info: anytype, comptime i: usize) ?usize {
    if (comptime @hasField(@TypeOf(info), "field_attrs")) return info.field_attrs[i].@"align";
    return info.fields[i].alignment;
}

pub fn StructFieldAttributes() type {
    if (comptime @hasDecl(std.builtin.Type.Struct, "FieldAttributes"))
        return std.builtin.Type.Struct.FieldAttributes;
    return std.builtin.Type.StructField.Attributes;
}

pub fn UnionFieldAttributes() type {
    if (comptime @hasDecl(std.builtin.Type.Union, "FieldAttributes"))
        return std.builtin.Type.Union.FieldAttributes;
    return std.builtin.Type.UnionField.Attributes;
}

pub fn arrayList(comptime T: type, items: []T, capacity: usize) std.ArrayList(T) {
    if (comptime @hasField(std.ArrayList(T), "pointer_stability")) {
        return .{ .items = items, .capacity = capacity, .pointer_stability = .{} };
    }
    return .{ .items = items, .capacity = capacity };
}
