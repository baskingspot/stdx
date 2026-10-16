const std = @import("std");
const slot_ring = @import("stdx").slot_ring;

// Four 256-byte slots, the default wake flavor and the default drop
// policy: nothing wakes the consumer, and a full ring refuses the new
// line. Worker threads claim, write, and commit; the caller drains.
const LogRing = slot_ring.Mpsc(.{ .slot_size = 256 });

const Log = struct {
    ring: *LogRing,
    // The single consumer owns the read position. It advances only
    // past a committed line that it released.
    read_pos: u64 = 0,
    dropped: u64 = 0,

    // The producer path: claim, write, commit. A refused claim counts
    // the drop and returns, so no path blocks.
    fn write(self: *Log, line: []const u8) void {
        var lease = self.ring.acquire() orelse {
            self.dropped += 1;
            return;
        };
        var w = lease.writer();
        w.writeAll(line[0..@min(line.len, LogRing.payload_size)]) catch unreachable;
        lease.commit(self.ring, @intCast(w.end));
    }

    // The consumer path: read in order from the owned position and
    // stop at the first uncommitted claim, so nothing behind it is
    // skipped.
    fn drain(self: *Log, out: *std.Io.Writer) !void {
        while (self.read_pos < self.ring.head()) : (self.read_pos += 1) {
            const msg = self.ring.read(self.read_pos) orelse break;
            try out.print("{s}\n", .{msg.payload});
            msg.release();
        }
    }
};

test "a full ring drops the newest lines and the drain stays in order" {
    var ring: LogRing = undefined;
    try ring.init(std.testing.allocator, undefined, 4);
    defer ring.deinit(std.testing.allocator);
    var log: Log = .{ .ring = &ring };

    // Six lines into four slots: the first four commit, the last two
    // are refused.
    for (0..6) |i| {
        var buf: [16]u8 = undefined;
        log.write(try std.fmt.bufPrint(&buf, "line {d}", .{i}));
    }
    try std.testing.expectEqual(4, ring.head());
    try std.testing.expectEqual(2, log.dropped);
    // Every line is committed or counted: nothing vanishes.
    try std.testing.expectEqual(6, ring.head() + log.dropped);

    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try log.drain(&out);
    try std.testing.expectEqualStrings("line 0\nline 1\nline 2\nline 3\n", out.buffered());

    // The drain released every slot. The next line lands, and the
    // consumer resumes at its own position.
    log.write("after");
    try std.testing.expectEqual(5, ring.head());
    var more: [32]u8 = undefined;
    var out2: std.Io.Writer = .fixed(&more);
    try log.drain(&out2);
    try std.testing.expectEqualStrings("after\n", out2.buffered());
    try std.testing.expectEqual(5, log.read_pos);
}
