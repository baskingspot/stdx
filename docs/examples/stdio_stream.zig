const std = @import("std");
const stdio = @import("stdx").stdio;

// `stdio.err` and `stdio.out` are ready on import, so most code never
// builds a `Stream`. This one writes to a pipe and leaves the process's
// own stdio alone, which is also how to test code that formats output.
test "a stream buffers until flush" {
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    var stream: stdio.Stream = undefined;
    stream = .{
        .buffer = undefined,
        .file_writer = .initStreaming(
            .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            std.testing.io,
            &stream.buffer,
        ),
    };

    // No method returns an error, and nothing lands until flush.
    stream.print("{s}: {d}\n", .{ "cache miss", 42 });
    stream.flush();

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("cache miss: 42\n", buf[0..n]);
}
