//! The struct-of-arrays pair: `Array` (fixed length) and `Buffer` (fixed
//! capacity, runtime `len`) — the std convention of short flavor names inside
//! a package that names the concept, like `std.array_hash_map.Auto`.
//!
//! `std.MultiArrayList(T)` splits a struct (or tagged union) into one array
//! per field, but backs them with a heap allocation sized at runtime and a
//! runtime byte-offset map. These siblings embed the field arrays instead:
//! `Array(T, length)` is the comptime-length counterpart of `mem.Array`
//! (exactly `length` elements, no `len` field), and `Buffer(T, capacity)` is
//! the `ArrayBuffer` counterpart (fixed capacity, runtime `len`, list API,
//! no allocator). The field arrays are generated as one `.auto` layout
//! struct at comptime, so the compiler handles alignment and padding — std's
//! runtime offset sorting disappears entirely.

const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;
const mem = std.mem;
const testing = std.testing;

/// The element type whose fields back the per-field arrays: `T` itself for
/// structs, or `{ tags, data }` for tagged unions — adapted from
/// `std.MultiArrayList`.
fn Element(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .@"union" => |u| struct {
            const Self = @This();

            pub const Bare = Bare: {
                const Attrs = std.builtin.Type.UnionField.Attributes;
                var field_names: [u.fields.len][]const u8 = undefined;
                var field_types: [u.fields.len]type = undefined;
                var field_attrs: [u.fields.len]Attrs = undefined;
                for (
                    u.fields,
                    &field_names,
                    &field_types,
                    &field_attrs,
                ) |field, *name, *Type, *attrs| {
                    name.* = field.name;
                    Type.* = field.type;
                    attrs.* = .{ .@"align" = field.alignment };
                }
                break :Bare @Union(u.layout, null, &field_names, &field_types, &field_attrs);
            };
            pub const Tag = u.tag_type orelse @compileError(
                "multi_array.Array and multi_array.Buffer do not support untagged unions",
            );
            tags: Tag,
            data: Bare,

            pub fn fromT(outer: T) Self {
                const tag = meta.activeTag(outer);
                return .{
                    .tags = tag,
                    .data = switch (tag) {
                        inline else => |t| @unionInit(
                            Bare,
                            @tagName(t),
                            @field(outer, @tagName(t)),
                        ),
                    },
                };
            }

            pub fn toT(tag: Tag, bare: Bare) T {
                return switch (tag) {
                    inline else => |t| @unionInit(T, @tagName(t), @field(bare, @tagName(t))),
                };
            }
        },
        else => @compileError(
            "multi_array.Array and multi_array.Buffer only support structs and tagged unions",
        ),
    };
}

/// Struct-of-arrays storage for `length` elements of `T`: one
/// `[length]FieldType` field per element field, in an `.auto` layout struct
/// so the compiler picks field order and padding.
fn Storage(comptime T: type, comptime length: comptime_int) type {
    const Attrs = std.builtin.Type.StructField.Attributes;
    const elem_fields = meta.fields(Element(T));
    var field_names: [elem_fields.len][]const u8 = undefined;
    var field_types: [elem_fields.len]type = undefined;
    var field_attrs: [elem_fields.len]Attrs = undefined;
    for (elem_fields, &field_names, &field_types, &field_attrs) |field, *name, *Type, *attrs| {
        if (field.is_comptime) {
            @compileError(
                "multi_array.Array and multi_array.Buffer do not support comptime fields",
            );
        }
        name.* = field.name;
        Type.* = [length]field.type;
        attrs.* = .{};
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

/// Sort context adapting a user `lessThan` context to the `swap`/`lessThan`
/// pair `mem.sortContext` expects — adapted from `std.MultiArrayList`.
/// `Container` is an `Array` or `Buffer` instantiation; both expose
/// `swap(a, b)`.
fn SortContext(comptime Container: type, comptime SubCtx: type) type {
    return struct {
        const Self = @This();

        sub_ctx: SubCtx,
        container: *Container,

        pub fn swap(sc: Self, a_index: usize, b_index: usize) void {
            sc.container.swap(a_index, b_index);
        }

        pub fn lessThan(sc: Self, a_index: usize, b_index: usize) bool {
            return sc.sub_ctx.lessThan(a_index, b_index);
        }
    };
}

/// A struct-of-arrays container of exactly `length` elements of `T`, stored
/// inline — the fixed-size sibling of `std.MultiArrayList` and the
/// comptime-length sibling of `mem.Array`.
///
/// Each field of `T` lives in its own `[length]FieldType` array, so a
/// computation touching only some fields walks contiguous memory, and `T`'s
/// padding never repeats per element. There is no runtime `len`:
/// `items(.x)` returns `*[length]F`, which coerces to slices and casts to
/// vector types (`@Vector(length, F)`).
///
/// `T` may be a struct or a tagged union; unions are stored as `tags` and
/// `data` arrays like `std.MultiArrayList`.
pub fn Array(comptime T: type, comptime length: comptime_int) type {
    return struct {
        const Self = @This();

        /// The number of elements; also the length of every field array.
        pub const len: usize = @intCast(length);

        const Elem = Element(T);
        const fields = meta.fields(Elem);
        pub const Field = meta.FieldEnum(Elem);

        storage: Storage(T, length),

        pub const empty: Self = .{ .storage = undefined };

        fn FieldType(comptime field: Field) type {
            return @FieldType(Elem, @tagName(field));
        }

        /// The `[length]F` array for `field` over a const reference.
        pub fn constItems(
            self: *const Self,
            comptime field: Field,
        ) *const [length]FieldType(field) {
            return &@field(self.storage, @tagName(field));
        }

        /// The `[length]F` array for `field`.
        pub fn items(self: *Self, comptime field: Field) *[length]FieldType(field) {
            return &@field(self.storage, @tagName(field));
        }

        /// Gather the element at `index` back into a `T`.
        pub fn get(self: *const Self, index: usize) T {
            var result: Elem = undefined;
            inline for (fields) |field_info| {
                @field(result, field_info.name) = @field(self.storage, field_info.name)[index];
            }
            return switch (@typeInfo(T)) {
                .@"struct" => result,
                .@"union" => Elem.toT(result.tags, result.data),
                else => unreachable,
            };
        }

        /// Scatter `elem` into the per-field arrays at `index`.
        pub fn set(self: *Self, index: usize, elem: T) void {
            const e = switch (@typeInfo(T)) {
                .@"struct" => elem,
                .@"union" => Elem.fromT(elem),
                else => unreachable,
            };
            inline for (fields) |field_info| {
                @field(self.storage, field_info.name)[index] = @field(e, field_info.name);
            }
        }

        /// Scatter `value` into every element.
        pub fn fill(self: *Self, value: T) void {
            const e = switch (@typeInfo(T)) {
                .@"struct" => value,
                .@"union" => Elem.fromT(value),
                else => unreachable,
            };
            inline for (fields) |field_info| {
                @memset(&@field(self.storage, field_info.name), @field(e, field_info.name));
            }
        }

        /// Exchange the elements at `a` and `b`.
        pub fn swap(self: *Self, a: usize, b: usize) void {
            inline for (fields) |field_info| {
                if (@sizeOf(field_info.type) != 0) {
                    const arr = &@field(self.storage, field_info.name);
                    mem.swap(field_info.type, &arr[a], &arr[b]);
                }
            }
        }

        /// Build from an array of structs (AoS to SoA).
        pub fn fromArray(values: [length]T) Self {
            var self: Self = .empty;
            for (values, 0..) |value, index| self.set(index, value);
            return self;
        }

        /// Gather every element into an array of structs (SoA to AoS).
        pub fn toArray(self: *const Self) [length]T {
            var values: [length]T = undefined;
            for (&values, 0..) |*value, index| value.* = self.get(index);
            return values;
        }

        fn sortInternal(self: *Self, ctx: anytype, comptime mode: std.sort.Mode) void {
            const sort_context = SortContext(Self, @TypeOf(ctx)){
                .sub_ctx = ctx,
                .container = self,
            };

            switch (mode) {
                .stable => mem.sortContext(0, len, sort_context),
                .unstable => mem.sortUnstableContext(0, len, sort_context),
            }
        }

        /// Stable sort of all `len` elements. Preserves the relative order of
        /// equal elements; `sortUnstable` is a faster alternative when that
        /// does not matter.
        /// `ctx` has the following method:
        /// `fn lessThan(ctx: @TypeOf(ctx), a_index: usize, b_index: usize) bool`
        pub fn sort(self: *Self, ctx: anytype) void {
            self.sortInternal(ctx, .stable);
        }

        /// Unstable sort of all `len` elements. The relative order of equal
        /// elements may change.
        /// `ctx` has the following method:
        /// `fn lessThan(ctx: @TypeOf(ctx), a_index: usize, b_index: usize) bool`
        pub fn sortUnstable(self: *Self, ctx: anytype) void {
            self.sortInternal(ctx, .unstable);
        }
    };
}

/// A fixed-capacity struct-of-arrays list — the `ArrayBuffer` sibling of
/// `std.MultiArrayList`. Storage is embedded (`[capacity]FieldType` per
/// field), `len` is runtime, and there is no allocator: appending to a full
/// list returns `error.NoSpaceLeft`.
///
/// `T` may be a struct or a tagged union; unions are stored as `tags` and
/// `data` arrays like `std.MultiArrayList`.
pub fn Buffer(comptime T: type, comptime buffer_capacity: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Index = std.math.IntFittingRange(0, buffer_capacity);
        pub const capacity: Index = @intCast(buffer_capacity);

        const Elem = Element(T);
        const fields = meta.fields(Elem);
        pub const Field = meta.FieldEnum(Elem);

        storage: Storage(T, capacity),
        len: Index,

        pub const empty: Self = .{ .storage = undefined, .len = 0 };

        fn FieldType(comptime field: Field) type {
            return @FieldType(Elem, @tagName(field));
        }

        /// The `[]F` slice of populated values for `field` over a const
        /// reference.
        pub fn constItems(self: *const Self, comptime field: Field) []const FieldType(field) {
            return @field(self.storage, @tagName(field))[0..self.len];
        }

        /// The `[]F` slice of populated values for `field`.
        pub fn items(self: *Self, comptime field: Field) []FieldType(field) {
            return @field(self.storage, @tagName(field))[0..self.len];
        }

        /// Gather the element at `index` back into a `T`.
        pub fn get(self: *const Self, index: usize) T {
            assert(index < self.len);
            var result: Elem = undefined;
            inline for (fields) |field_info| {
                @field(result, field_info.name) = @field(self.storage, field_info.name)[index];
            }
            return switch (@typeInfo(T)) {
                .@"struct" => result,
                .@"union" => Elem.toT(result.tags, result.data),
                else => unreachable,
            };
        }

        /// Scatter `elem` into the per-field arrays at `index`.
        pub fn set(self: *Self, index: usize, elem: T) void {
            assert(index < self.len);
            const e = switch (@typeInfo(T)) {
                .@"struct" => elem,
                .@"union" => Elem.fromT(elem),
                else => unreachable,
            };
            inline for (fields) |field_info| {
                @field(self.storage, field_info.name)[index] = @field(e, field_info.name);
            }
        }

        pub fn remainingCapacity(self: *const Self) Index {
            return capacity - self.len;
        }

        /// Extend the list by 1 element. Returns `error.NoSpaceLeft` if the
        /// list is full.
        pub fn append(self: *Self, elem: T) error{NoSpaceLeft}!void {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            self.appendAssumeCapacity(elem);
        }

        /// Extend the list by 1 element. Asserts that capacity is sufficient
        /// to hold an additional item.
        pub fn appendAssumeCapacity(self: *Self, elem: T) void {
            assert(self.len < capacity);
            self.len += 1;
            self.set(self.len - 1, elem);
        }

        /// Extend the list by `values.len` elements. Returns
        /// `error.NoSpaceLeft` if they do not all fit.
        pub fn appendSlice(self: *Self, values: []const T) error{NoSpaceLeft}!void {
            if (values.len > self.remainingCapacity()) return error.NoSpaceLeft;
            for (values) |value| self.appendAssumeCapacity(value);
        }

        /// Extend the list by 1 element, returning the index of the
        /// uninitialized slot. Returns `error.NoSpaceLeft` if the list is full.
        pub fn addOne(self: *Self) error{NoSpaceLeft}!usize {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            return self.addOneAssumeCapacity();
        }

        /// Extend the list by 1 element, returning the index of the
        /// uninitialized slot. Asserts that capacity is sufficient to hold an
        /// additional item.
        pub fn addOneAssumeCapacity(self: *Self) usize {
            assert(self.len < capacity);
            const index: usize = self.len;
            self.len += 1;
            return index;
        }

        /// Remove and return the last element, or return `null` if the list
        /// is empty.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const value = self.get(self.len - 1);
            self.len -= 1;
            return value;
        }

        /// Insert `elem` at `index`, shifting all elements from `index` up by
        /// one. Returns `error.NoSpaceLeft` if the list is full.
        pub fn insert(self: *Self, index: usize, elem: T) error{NoSpaceLeft}!void {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            self.insertAssumeCapacity(index, elem);
        }

        /// Insert `elem` at `index`, shifting all elements from `index` up by
        /// one. Asserts that capacity is sufficient and `index <= len`.
        pub fn insertAssumeCapacity(self: *Self, index: usize, elem: T) void {
            assert(self.len < capacity);
            assert(index <= self.len);
            const length: usize = self.len;
            self.len += 1;
            inline for (fields) |field_info| {
                if (@sizeOf(field_info.type) != 0) {
                    const arr = &@field(self.storage, field_info.name);
                    @memmove(arr[index + 1 .. length + 1], arr[index..length]);
                }
            }
            self.set(index, elem);
        }

        /// Remove the element at `index` by swapping the last element into its
        /// place. Fast, but does not retain list ordering.
        pub fn swapRemove(self: *Self, index: usize) void {
            assert(self.len > 0);
            assert(index < self.len);
            self.set(index, self.get(@as(usize, self.len) - 1));
            self.len -= 1;
        }

        /// Remove the element at `index`, shifting the elements above it down
        /// to preserve order.
        pub fn orderedRemove(self: *Self, index: usize) void {
            assert(self.len > 0);
            assert(index < self.len);
            const last: usize = @as(usize, self.len) - 1;
            inline for (fields) |field_info| {
                if (@sizeOf(field_info.type) != 0) {
                    const arr = &@field(self.storage, field_info.name);
                    @memmove(arr[index..last], arr[index + 1 .. last + 1]);
                }
            }
            self.len -= 1;
        }

        /// Adjust the list's length to `new_len`. `Index` cannot express a
        /// value above `capacity`, so no bounds check is needed. Does not
        /// initialize added slots, if any.
        pub fn resize(self: *Self, new_len: Index) void {
            self.len = new_len;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        fn swap(self: *Self, a: usize, b: usize) void {
            inline for (fields) |field_info| {
                if (@sizeOf(field_info.type) != 0) {
                    const arr = &@field(self.storage, field_info.name);
                    mem.swap(field_info.type, &arr[a], &arr[b]);
                }
            }
        }

        fn sortInternal(self: *Self, ctx: anytype, comptime mode: std.sort.Mode) void {
            const sort_context = SortContext(Self, @TypeOf(ctx)){
                .sub_ctx = ctx,
                .container = self,
            };

            switch (mode) {
                .stable => mem.sortContext(0, self.len, sort_context),
                .unstable => mem.sortUnstableContext(0, self.len, sort_context),
            }
        }

        /// Stable sort of the populated elements. Preserves the relative
        /// order of equal elements; `sortUnstable` is a faster alternative
        /// when that does not matter.
        /// `ctx` has the following method:
        /// `fn lessThan(ctx: @TypeOf(ctx), a_index: usize, b_index: usize) bool`
        pub fn sort(self: *Self, ctx: anytype) void {
            self.sortInternal(ctx, .stable);
        }

        /// Unstable sort of the populated elements. The relative order of
        /// equal elements may change.
        /// `ctx` has the following method:
        /// `fn lessThan(ctx: @TypeOf(ctx), a_index: usize, b_index: usize) bool`
        pub fn sortUnstable(self: *Self, ctx: anytype) void {
            self.sortInternal(ctx, .unstable);
        }
    };
}

test "Array: get, set, constItems, swap" {
    const Row = struct { a: u32, b: []const u8, c: u8 };

    var arr: Array(Row, 4) = .empty;
    arr.set(0, .{ .a = 1, .b = "one", .c = 'a' });
    arr.set(1, .{ .a = 2, .b = "two", .c = 'b' });

    try testing.expectEqual(@as(u32, 1), arr.get(0).a);
    try testing.expectEqualStrings("two", arr.get(1).b);
    try testing.expectEqual(@as(u8, 'a'), arr.get(0).c);

    const const_arr: *const Array(Row, 4) = &arr;
    try testing.expectEqual(@as(usize, 4), const_arr.constItems(.a).len);
    try testing.expectEqual(@as(u32, 1), const_arr.constItems(.a)[0]);
    try testing.expectEqual(@as(u32, 2), const_arr.constItems(.a)[1]);

    arr.swap(0, 1);
    try testing.expectEqual(@as(u32, 2), arr.get(0).a);
    try testing.expectEqual(@as(u32, 1), arr.get(1).a);

    var other: Array(Row, 4) = .empty;
    other.fill(.{ .a = 7, .b = "seven", .c = 's' });
    try testing.expectEqual(@as(u32, 7), other.get(3).a);
    try testing.expectEqualStrings("seven", other.get(2).b);
}

test "Array: items are fixed-length arrays" {
    const Row = struct { a: u32, c: u8 };

    var arr: Array(Row, 4) = .empty;
    arr.set(0, .{ .a = 1, .c = 'a' });
    arr.set(1, .{ .a = 2, .c = 'b' });
    arr.set(2, .{ .a = 3, .c = 'c' });
    arr.set(3, .{ .a = 4, .c = 'd' });

    const fixed: *const [4]u32 = arr.constItems(.a);
    try testing.expectEqual(@as(u32, 3), fixed[2]);

    const v: @Vector(4, u32) = @bitCast(arr.constItems(.a).*);
    try testing.expectEqual(@as(u32, 10), @reduce(.Add, v));

    arr.items(.a)[2] = 30;
    try testing.expectEqual(@as(u32, 30), arr.get(2).a);
}

test "Array: fromArray and toArray" {
    const Row = struct { a: u32, b: []const u8, c: u8 };

    const arr = Array(Row, 3).fromArray(.{
        .{ .a = 1, .b = "one", .c = 'a' },
        .{ .a = 2, .b = "two", .c = 'b' },
        .{ .a = 3, .b = "three", .c = 'c' },
    });
    try testing.expectEqual(@as(u32, 2), arr.get(1).a);

    const back = arr.toArray();
    try testing.expectEqual(@as(u32, 3), back[2].a);
    try testing.expectEqualStrings("two", back[1].b);
}

test "Array: sort" {
    const Row = struct { a: u32, c: u8 };

    var arr = Array(Row, 5).fromArray(.{
        .{ .a = 5, .c = 'e' },
        .{ .a = 3, .c = 'c' },
        .{ .a = 1, .c = 'a' },
        .{ .a = 4, .c = 'd' },
        .{ .a = 2, .c = 'b' },
    });

    const Descending = struct {
        const Self = @This();

        arr: *const Array(Row, 5),

        fn lessThan(ctx: Self, a_index: usize, b_index: usize) bool {
            return ctx.arr.get(a_index).a > ctx.arr.get(b_index).a;
        }
    };
    arr.sort(Descending{ .arr = &arr });
    try testing.expectEqualSlices(u32, &.{ 5, 4, 3, 2, 1 }, arr.constItems(.a));
    try testing.expectEqualSlices(u8, &.{ 'e', 'd', 'c', 'b', 'a' }, arr.constItems(.c));
}

test "Array: tagged union" {
    const Value = union(enum) { int: u32, float: f64 };

    var arr: Array(Value, 3) = .empty;
    arr.set(0, .{ .int = 10 });
    arr.set(1, .{ .float = 2.5 });
    arr.set(2, .{ .int = 30 });

    try testing.expect(arr.constItems(.tags)[0] == .int);
    try testing.expect(arr.constItems(.tags)[1] == .float);
    try testing.expectEqual(@as(u32, 10), arr.get(0).int);
    try testing.expectEqual(@as(f64, 2.5), arr.get(1).float);

    arr.set(1, .{ .int = 11 });
    const back = arr.toArray();
    try testing.expectEqual(@as(u32, 11), back[1].int);
    try testing.expectEqual(@as(u32, 30), back[2].int);
}

test "Buffer: basic usage" {
    const Row = struct { a: u32, b: []const u8, c: u8 };

    var list: Buffer(Row, 8) = .empty;
    try testing.expectEqual(@as(usize, 0), list.items(.a).len);
    try testing.expectEqual(@as(usize, 8), list.remainingCapacity());

    try list.append(.{ .a = 1, .b = "one", .c = 'a' });
    try list.appendSlice(&.{
        .{ .a = 2, .b = "two", .c = 'b' },
        .{ .a = 3, .b = "three", .c = 'c' },
    });
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("three", list.get(2).b);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, list.constItems(.a));

    const index = try list.addOne();
    list.set(index, .{ .a = 4, .b = "four", .c = 'd' });
    try testing.expectEqual(@as(u32, 4), list.get(3).a);

    try testing.expectEqualStrings("four", list.pop().?.b);
    try testing.expectEqualStrings("three", list.pop().?.b);
    try testing.expectEqual(@as(usize, 2), list.len);

    list.clear();
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expectEqual(@as(usize, 8), list.remainingCapacity());
}

test "Buffer: full capacity" {
    const Row = struct { a: u32, c: u8 };

    var list: Buffer(Row, 2) = .empty;
    try list.append(.{ .a = 1, .c = 'a' });
    try list.append(.{ .a = 2, .c = 'b' });

    try testing.expectError(error.NoSpaceLeft, list.append(.{ .a = 3, .c = 'c' }));
    try testing.expectError(error.NoSpaceLeft, list.addOne());
    try testing.expectError(error.NoSpaceLeft, list.insert(0, .{ .a = 9, .c = 'z' }));
    try testing.expectError(error.NoSpaceLeft, list.appendSlice(&.{.{ .a = 9, .c = 'z' }}));
    try testing.expectEqual(@as(u32, 2), list.get(1).a);
}

test "Buffer: swapRemove, orderedRemove, insert" {
    const Row = struct { a: u32, c: u8 };

    var list: Buffer(Row, 8) = .empty;
    try list.appendSlice(&.{
        .{ .a = 1, .c = 'a' },
        .{ .a = 2, .c = 'b' },
        .{ .a = 3, .c = 'c' },
        .{ .a = 4, .c = 'd' },
    });

    list.swapRemove(0);
    try testing.expectEqualSlices(u32, &.{ 4, 2, 3 }, list.items(.a));

    list.orderedRemove(0);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, list.items(.a));

    try list.insert(1, .{ .a = 9, .c = 'z' });
    try testing.expectEqualSlices(u32, &.{ 2, 9, 3 }, list.items(.a));
    try testing.expectEqualSlices(u8, &.{ 'b', 'z', 'c' }, list.items(.c));

    list.resize(2);
    try testing.expectEqualSlices(u32, &.{ 2, 9 }, list.items(.a));
}

test "Buffer: sort" {
    const Row = struct { a: u32, c: u8 };

    var list: Buffer(Row, 8) = .empty;
    try list.appendSlice(&.{
        .{ .a = 3, .c = 'c' },
        .{ .a = 1, .c = 'a' },
        .{ .a = 2, .c = 'b' },
    });

    const Ascending = struct {
        const Self = @This();

        list: *const Buffer(Row, 8),

        fn lessThan(ctx: Self, a_index: usize, b_index: usize) bool {
            return ctx.list.get(a_index).a < ctx.list.get(b_index).a;
        }
    };
    list.sortUnstable(Ascending{ .list = &list });
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, list.constItems(.a));
    try testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c' }, list.constItems(.c));
}

test "Array and Buffer: zero-sized fields" {
    const Row = struct { a: u32, unit: void, c: u8 };

    var arr: Array(Row, 3) = .empty;
    arr.set(0, .{ .a = 1, .unit = {}, .c = 'a' });
    arr.set(1, .{ .a = 2, .unit = {}, .c = 'b' });
    arr.set(2, .{ .a = 3, .unit = {}, .c = 'c' });
    arr.sortUnstable(struct {
        const Self = @This();

        arr: *const Array(Row, 3),

        fn lessThan(ctx: Self, a_index: usize, b_index: usize) bool {
            return ctx.arr.get(a_index).a > ctx.arr.get(b_index).a;
        }
    }{ .arr = &arr });
    try testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, arr.constItems(.a));

    var list: Buffer(Row, 4) = .empty;
    try list.appendSlice(&.{
        .{ .a = 1, .unit = {}, .c = 'a' },
        .{ .a = 2, .unit = {}, .c = 'b' },
    });
    try list.insert(0, .{ .a = 9, .unit = {}, .c = 'z' });
    list.orderedRemove(2);
    list.swapRemove(0);
    try testing.expectEqualSlices(u32, &.{1}, list.constItems(.a));
}

test "Buffer: tagged union" {
    const Value = union(enum) { int: u32, float: f64 };

    var list: Buffer(Value, 4) = .empty;
    try list.append(.{ .int = 10 });
    try list.append(.{ .float = 2.5 });

    try testing.expect(list.constItems(.tags)[0] == .int);
    try testing.expect(list.constItems(.tags)[1] == .float);
    try testing.expectEqual(@as(f64, 2.5), list.pop().?.float);
    try testing.expectEqual(@as(u32, 10), list.get(0).int);
}

test "Array: stable sort preserves equal-key order" {
    const Row = struct { key: u8, seq: u8 };

    var arr = Array(Row, 6).fromArray(.{
        .{ .key = 2, .seq = 0 },
        .{ .key = 1, .seq = 1 },
        .{ .key = 2, .seq = 2 },
        .{ .key = 1, .seq = 3 },
        .{ .key = 2, .seq = 4 },
        .{ .key = 1, .seq = 5 },
    });
    arr.sort(struct {
        const Self = @This();

        arr: *const Array(Row, 6),

        fn lessThan(ctx: Self, a_index: usize, b_index: usize) bool {
            return ctx.arr.get(a_index).key < ctx.arr.get(b_index).key;
        }
    }{ .arr = &arr });
    // Equal keys keep their original relative order: seq ascending within key.
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2, 2, 2 }, arr.constItems(.key));
    try testing.expectEqualSlices(u8, &.{ 1, 3, 5, 0, 2, 4 }, arr.constItems(.seq));
}

test "Buffer: stable sort preserves equal-key order" {
    const Row = struct { key: u8, seq: u8 };

    var list: Buffer(Row, 6) = .empty;
    try list.appendSlice(&.{
        .{ .key = 2, .seq = 0 },
        .{ .key = 1, .seq = 1 },
        .{ .key = 2, .seq = 2 },
        .{ .key = 1, .seq = 3 },
        .{ .key = 2, .seq = 4 },
        .{ .key = 1, .seq = 5 },
    });
    list.sort(struct {
        const Self = @This();

        list: *const Buffer(Row, 6),

        fn lessThan(ctx: Self, a_index: usize, b_index: usize) bool {
            return ctx.list.get(a_index).key < ctx.list.get(b_index).key;
        }
    }{ .list = &list });
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 2, 2, 2 }, list.constItems(.key));
    try testing.expectEqualSlices(u8, &.{ 1, 3, 5, 0, 2, 4 }, list.constItems(.seq));
}

test "Buffer: edge operations" {
    const Row = struct { a: u32, c: u8 };

    // pop on empty is null, not an error.
    var list: Buffer(Row, 4) = .empty;
    try testing.expect(list.pop() == null);

    // The assume-capacity fast paths.
    list.appendAssumeCapacity(.{ .a = 1, .c = 'a' });
    const index = list.addOneAssumeCapacity();
    try testing.expectEqual(@as(usize, 1), index);
    list.set(index, .{ .a = 2, .c = 'b' });
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, list.items(.a));

    // insert at len is the append position.
    try list.insert(list.len, .{ .a = 3, .c = 'c' });
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, list.items(.a));

    // orderedRemove at the last index: zero-length shift, no bounds damage.
    list.orderedRemove(2);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, list.items(.a));
    try testing.expectEqual(@as(usize, 2), list.remainingCapacity());
}
