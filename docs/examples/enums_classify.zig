const std = @import("std");
const enums = @import("stdx").enums;

const PoolMode = enum { transaction, session, statement, unknown };

// Open: a non-exhaustive enum. The miss is the unnamed value, so the
// switch needs an `else` arm.
const OpenModes = enums.Open(.{ "transaction", "session", "statement" });

// Closed: an exhaustive enum. The last argument names the miss tag, so the
// switch must cover every tag.
const ClosedModes = enums.Closed(.{ "transaction", "session", "statement" }, "other");

test "open: else is the miss" {
    const mode: PoolMode = switch (OpenModes.match("session")) {
        .transaction => .transaction,
        .session => .session,
        .statement => .statement,
        else => .unknown,
    };
    try std.testing.expectEqual(PoolMode.session, mode);
    try std.testing.expectEqual(OpenModes.miss, OpenModes.match("sessions"));
    try std.testing.expect(OpenModes.has("statement"));
}

test "closed: every tag has an arm" {
    const mode: PoolMode = switch (ClosedModes.match("statements")) {
        .transaction => .transaction,
        .session => .session,
        .statement => .statement,
        .other => .unknown,
    };
    try std.testing.expectEqual(PoolMode.unknown, mode);
}

const Headers = enums.Open(.{ "content-type", "content-length" });

test "a tag can be any byte string" {
    const hit = switch (Headers.match("content-type")) {
        .@"content-type" => true,
        .@"content-length" => false,
        else => false,
    };
    try std.testing.expect(hit);
}

test "an existing enum" {
    try std.testing.expectEqual(
        PoolMode.statement,
        enums.stringToEnum(PoolMode, "statement").?,
    );
    try std.testing.expectEqual(
        @as(?PoolMode, null),
        enums.stringToEnum(PoolMode, "statementz"),
    );
}
