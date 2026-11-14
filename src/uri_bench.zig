//! The uri module's benchmark: WHATWG parse and normalize into a fixed
//! buffer, over a corpus shaped like ordinary web URLs.

const stdx = @import("stdx");
const uri = stdx.uri;
const testingx = @import("testingx");

const corpus = [_][]const u8{
    "https://example.com/",
    "https://www.example.com/search?q=zig+url+parser&hl=en&ictx=2",
    "https://example.org/wiki/URL#Components_and_normalization",
    "https://example.net/a/b/../c/./d?x=1&y=2#frag",
    "https://cdn.example.com/assets/app.4f9c1e.css?v=2026-11-14",
    "https://example.com/login/?dest=https%3A%2F%2Fexample.com%2F",
    "postgresql://user:pass@localhost:5432/db?connect_timeout=10&application_name=app",
    "http://192.168.1.1/",
    "http://[2606:4700:4700::1111]/",
    "https://EXAMPLE.com:443/Path/With/Mixed/Case",
};

pub fn benchmarkUriParse(b: *testingx.B) !void {
    var sink: usize = 0;
    defer b.keepAlive(sink);
    const hidden = b.blackBox(&corpus);
    var buf: [8192]u8 = undefined;
    while (try b.loop()) {
        for (hidden) |text| {
            const url = uri.parse(text, &buf) catch continue;
            sink +%= url.bytes.len;
        }
    }
}
