const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const timex = @import("stdx").time;

const Request = struct {
    deadline: timex.OptionalTimestamp,
};

test "a deadline fits in one word and expires by comparison" {
    const start: timex.Timestamp = .fromMillisecondsComptime(84);
    const duration: timex.Duration = .fromMillisecondsComptime(250);
    const deadline = try start.add(duration);
    const request: Request = .{ .deadline = try .init(deadline) };

    try testing.expectEqual(@as(usize, 8), @sizeOf(Request));
    try testing.expectEqual(deadline, request.deadline.get().?);

    const now: Io.Timestamp = .fromNanoseconds(deadline.nanoseconds);
    try testing.expect(deadline.compare(try .fromStd(now)) == .eq);

    const no_deadline: timex.OptionalTimestamp = .none;
    try testing.expectEqual(@as(?timex.Timestamp, null), no_deadline.get());
}
