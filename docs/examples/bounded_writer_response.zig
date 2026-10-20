const std = @import("std");
const BoundedWriter = @import("stdx").BoundedWriter;

// A response built from an unbounded row set must not outgrow its buffer.
fn render(rows: []const u32, out: *BoundedWriter) !void {
    try out.writer.writeAll("[");
    for (rows, 0..) |row, index| {
        if (index != 0) try out.writer.writeAll(",");
        try out.writer.print("{d}", .{row});
    }
    try out.writer.writeAll("]");
}

test "a response that fits is kept whole" {
    var out: BoundedWriter = .init(std.testing.allocator, 64);
    defer out.deinit();

    try render(&.{ 1, 2, 3 }, &out);
    try std.testing.expectEqualStrings("[1,2,3]", out.written());
}

test "a write past the limit fails and keeps the prefix" {
    var out: BoundedWriter = .init(std.testing.allocator, 8);
    defer out.deinit();

    // "[" and the first row make 7 bytes, and the separator reaches the
    // limit exactly. The next digit is the write that fails.
    try std.testing.expectError(error.WriteFailed, render(&.{ 123_456, 2 }, &out));
    try std.testing.expectEqualStrings("[123456,", out.written());
}
