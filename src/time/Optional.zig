//! An optional compact time value, stored without a separate tag.
//!
//! The highest `u64` nanosecond value is the empty representation. Its loss
//! still leaves nearly 585 years of range. Constructing an occupied value from
//! this reserved word returns `error.OutOfRange`. No boolean tag, alignment, or
//! extra Zig optional adds storage.

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// `T` is one of the time values with a `u64 nanoseconds` field.
pub fn Optional(comptime T: type) type {
    return struct {
        const Self = @This();

        nanoseconds: u64,

        pub const none: Self = .{ .nanoseconds = math.maxInt(u64) };

        pub const Error = error{
            /// The supplied value equals the word reserved for `none`.
            OutOfRange,
        };

        /// Store an optional value. `null` returns `none`.
        pub fn init(value: ?T) Error!Self {
            const present = value orelse return .none;
            if (present.nanoseconds == math.maxInt(u64)) return error.OutOfRange;
            return .{ .nanoseconds = present.nanoseconds };
        }

        /// Construct known nanoseconds. The reserved sentinel is a compile error.
        pub fn fromNanosecondsComptime(comptime value: u64) Self {
            return comptime init(T.fromNanoseconds(value)) catch
                @compileError("time value is reserved for none");
        }

        /// Convert known microseconds. Overflow and the sentinel are compile errors.
        pub fn fromMicrosecondsComptime(comptime value: u64) Self {
            return .fromNanosecondsComptime(T.fromMicrosecondsComptime(value).nanoseconds);
        }

        /// Convert known milliseconds. Overflow and the sentinel are compile errors.
        pub fn fromMillisecondsComptime(comptime value: u64) Self {
            return .fromNanosecondsComptime(T.fromMillisecondsComptime(value).nanoseconds);
        }

        /// Convert known seconds. Overflow and the sentinel are compile errors.
        pub fn fromSecondsComptime(comptime value: u64) Self {
            return .fromNanosecondsComptime(T.fromSecondsComptime(value).nanoseconds);
        }

        /// Return the stored value, or null for `none`.
        pub fn get(self: Self) ?T {
            if (self.nanoseconds == math.maxInt(u64)) return null;
            return .{ .nanoseconds = self.nanoseconds };
        }
    };
}

const Value = struct {
    nanoseconds: u64,
};

test Optional {
    const OptionalValue = Optional(Value);
    try testing.expectEqual(@as(usize, 8), @sizeOf(OptionalValue));
    try testing.expectEqual(@as(usize, 8), @alignOf(OptionalValue));
    try testing.expectEqual(math.maxInt(u64), OptionalValue.none.nanoseconds);
}

test "the sentinel does not cost another word or consume a real value" {
    const OptionalValue = Optional(Value);
    const empty: OptionalValue = try .init(null);
    try testing.expectEqual(@as(?Value, null), empty.get());
    try testing.expectEqual(@as(?Value, null), OptionalValue.none.get());

    const occupied: OptionalValue = try .init(.{ .nanoseconds = 123 });
    try testing.expectEqual(@as(?Value, .{ .nanoseconds = 123 }), occupied.get());
    try testing.expectError(error.OutOfRange, OptionalValue.init(.{
        .nanoseconds = math.maxInt(u64),
    }));

    // The first word below the sentinel remains representable.
    const maximum: OptionalValue = try .init(.{ .nanoseconds = math.maxInt(u64) - 1 });
    try testing.expectEqual(@as(u64, math.maxInt(u64) - 1), maximum.get().?.nanoseconds);
}
