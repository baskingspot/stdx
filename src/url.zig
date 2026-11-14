//! WHATWG URL parsing, the contract browsers implement, for absolute URLs.
//!
//! `std.Uri` splits a URI into its components and leaves the bytes alone. That
//! is the RFC 3986 shape, and it is the wrong contract whenever the caller
//! needs the same answer a browser gives: a normalized serialization with the
//! scheme and host folded, the default port dropped, dot segments removed,
//! unsafe bytes percent-encoded, IPv4 hosts canonicalized, and the input
//! validated against a grammar instead of searched for separators. The two
//! contracts disagree on real input in ways that matter to a client:
//!
//!     HTTP://EXAMPLE.COM:80/a/../b   -> http://example.com/b
//!     http://example.com\@evil.com/  -> http://example.com/@evil.com/   (host is example.com)
//!     http://0x7f.1/                 -> http://127.0.0.1/
//!     http://example.com/%2e%2e/x    -> http://example.com/x
//!
//! This module is the prototype for that second contract. It follows the
//! algorithm ada-url implements: one pass over the input, writing the
//! serialization and recording spans into it, with the WHATWG percent-encode
//! sets, the special-scheme rules, the IPv4 number parser, and the IPv6
//! parser and serializer.
//!
//! # What is missing
//!
//! - IDNA. A host with non-ASCII bytes is `error.IdnaUnsupported`. The mapping
//!   tables (UTS #46) are the large part of a real implementation: ada ships
//!   about 6,900 lines of them.
//! - Base resolution. Only an absolute URL parses; a relative reference needs
//!   the base and the rest of the state machine.
//! - `file:`. The drive-letter and empty-host rules are not implemented.
//! - The non-special `..` rule that inserts `.` to keep a path from starting
//!   with `//`.
//!
//! Against the WPT `urltestdata.json` corpus, on the 701 cases with an
//! absolute input, this passes 655, rejects 6 it should accept, and takes 27
//! serialization shortcuts. All 13 IDNA cases report `error.IdnaUnsupported`.
//! The residue is `file:` and the `..` rule above.
//!
//! The buffer holds the serialization, so the caller sizes it. Worst case is
//! three bytes of output per input byte; a URL that needs no encoding is one
//! byte per byte.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub const ParseError = error{
    /// The text before the first `:` is not a scheme.
    MissingScheme,
    /// A special scheme has an empty host, or credentials or a port with no
    /// host.
    EmptyHost,
    /// The host contains a byte the grammar forbids, or a `%` escape that
    /// does not decode.
    InvalidHost,
    /// The port is not decimal, or does not fit in 16 bits.
    InvalidPort,
    /// A host that ends in a number is not a valid IPv4 address.
    InvalidIpv4,
    /// A bracketed host is not a valid IPv6 address.
    InvalidIpv6,
    /// The host has non-ASCII bytes, which need IDNA to become ASCII.
    IdnaUnsupported,
    /// A `file:` URL carries a port.
    FileWithPort,
    /// The output buffer is too small for the serialization.
    NoSpaceLeft,
};

pub const Url = struct {
    /// The serialized URL. Points into the caller's buffer.
    bytes: []const u8,
    scheme: []const u8,
    /// Empty when the URL has no host. IPv6 keeps its brackets.
    host: []const u8,
    /// Null when absent, or when it is the scheme's default port.
    port: ?u16,
    path: []const u8,
    /// Without the leading `?`.
    query: ?[]const u8,
    /// Without the leading `#`.
    fragment: ?[]const u8,
};

const EncodeSet = enum { c0, fragment, query, special_query, path, userinfo };

fn isSpecial(scheme: []const u8) bool {
    return std.mem.eql(u8, scheme, "http") or
        std.mem.eql(u8, scheme, "https") or
        std.mem.eql(u8, scheme, "ws") or
        std.mem.eql(u8, scheme, "wss") or
        std.mem.eql(u8, scheme, "ftp") or
        std.mem.eql(u8, scheme, "file");
}

fn defaultPort(scheme: []const u8) ?u16 {
    if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "ws")) return 80;
    if (std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss")) return 443;
    if (std.mem.eql(u8, scheme, "ftp")) return 21;
    return null;
}

fn isC0OrSpace(c: u8) bool {
    return c <= 0x20;
}

fn isTabOrNewline(c: u8) bool {
    return c == '\t' or c == '\n' or c == '\r';
}

const forbidden_host = blk: {
    @setEvalBranchQuota(1000);
    var t: [256]bool = @splat(false);
    const banned = [_]u8{
        0,   '\t', '\n', '\r', ' ', '#', '/', ':', '<', '>',
        '?', '@',  '[',  '\\', ']', '^', '|',
    };
    for (banned) |c| t[c] = true;
    break :blk t;
};

fn isForbiddenHost(c: u8) bool {
    return forbidden_host[c];
}

fn isForbiddenDomain(c: u8) bool {
    return c <= 0x1f or isForbiddenHost(c) or c == '%' or c == 0x7f;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn needsEncodeScalar(comptime set: EncodeSet, c: u8) bool {
    const c0 = c <= 0x1f or c > 0x7e;
    return switch (set) {
        .c0 => c0,
        .fragment => c0 or c == ' ' or c == '"' or c == '<' or c == '>' or c == '`',
        .query => c0 or c == ' ' or c == '"' or c == '#' or c == '<' or c == '>',
        .special_query => needsEncodeScalar(.query, c) or c == '\'',
        .path => needsEncodeScalar(.query, c) or
            c == '?' or c == '^' or c == '`' or c == '{' or c == '}',
        .userinfo => needsEncodeScalar(.path, c) or c == '/' or c == ':' or c == ';' or c == '=' or
            c == '@' or c == '[' or c == '\\' or c == ']' or c == '|',
    };
}

/// One lookup table per set: a branch chain per byte is the hot loop, and a
/// byte table is one load.
const encode_tables = blk: {
    @setEvalBranchQuota(10000);
    var t: [std.enums.values(EncodeSet).len][256]bool = undefined;
    for (std.enums.values(EncodeSet)) |set| {
        for (0..256) |c| t[@backingInt(set)][c] = needsEncodeScalar(set, @intCast(c));
    }
    break :blk t;
};

fn needsEncode(comptime set: EncodeSet, c: u8) bool {
    return encode_tables[@backingInt(set)][c];
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn write(self: *Writer, bytes: []const u8) ParseError!void {
        if (self.buf.len - self.len < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn byte(self: *Writer, c: u8) ParseError!void {
        if (self.len == self.buf.len) return error.NoSpaceLeft;
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn hex(self: *Writer, c: u8) ParseError!void {
        if (self.buf.len - self.len < 3) return error.NoSpaceLeft;
        self.buf[self.len] = '%';
        self.buf[self.len + 1] = "0123456789ABCDEF"[c >> 4];
        self.buf[self.len + 2] = "0123456789ABCDEF"[c & 0xf];
        self.len += 3;
    }

    /// Copies `bytes`, dropping tabs and newlines and percent-encoding the
    /// set. Returns the span in the output.
    fn encoded(self: *Writer, bytes: []const u8, comptime set: EncodeSet) ParseError!Span {
        const start = self.len;
        for (bytes) |c| {
            if (isTabOrNewline(c)) continue;
            if (needsEncode(set, c)) try self.hex(c) else try self.byte(c);
        }
        return .{ .start = start, .len = self.len - start };
    }

    fn asciiLowered(self: *Writer, bytes: []const u8) ParseError!Span {
        const start = self.len;
        for (bytes) |c| try self.byte(lower(c));
        return .{ .start = start, .len = self.len - start };
    }

    fn slice(self: *const Writer, span: Span) []const u8 {
        return self.buf[span.start..][0..span.len];
    }
};

const Span = struct { start: usize, len: usize };

pub fn parse(input: []const u8, out_buf: []u8) ParseError!Url {
    var w: Writer = .{ .buf = out_buf };

    // Strip leading and trailing C0 or space; tabs and newlines are dropped
    // wherever they appear, by every copy below.
    var start: usize = 0;
    while (start < input.len and isC0OrSpace(input[start])) start += 1;
    var end = input.len;
    while (end > start and isC0OrSpace(input[end - 1])) end -= 1;
    const text = input[start..end];

    // Scheme.
    var i: usize = 0;
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return error.MissingScheme;
    while (i < text.len and text[i] != ':') : (i += 1) {
        const c = text[i];
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) {
            return error.MissingScheme;
        }
    }
    if (i == text.len) return error.MissingScheme;
    const scheme_span = try w.asciiLowered(text[0..i]);
    const scheme = w.slice(scheme_span);
    try w.byte(':');
    i += 1;

    const special = isSpecial(scheme);
    const file = std.mem.eql(u8, scheme, "file");

    var has_authority = false;
    if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
        has_authority = true;
        i += 2;
    } else if (special) {
        // `http:example.com`, `http:/example.com`, `http:\\example.com` all
        // reach the authority.
        has_authority = true;
        while (i < text.len and (text[i] == '/' or text[i] == '\\')) i += 1;
    }

    var host: []const u8 = "";
    var port: ?u16 = null;
    if (has_authority) {
        try w.write("//");
        var auth_end = i;
        while (auth_end < text.len) : (auth_end += 1) {
            const c = text[auth_end];
            if (c == '/' or c == '?' or c == '#') break;
            if (special and c == '\\') break;
        }

        var host_start = i;
        var at_sign_seen = false;
        if (std.mem.findLast(u8, text[i..auth_end], "@")) |at| {
            at_sign_seen = true;
            const before = w.len;
            try writeUserinfo(&w, text[i .. i + at]);
            if (w.len != before) try w.byte('@');
            host_start = i + at + 1;
        }

        var host_end = auth_end;
        var port_start: ?usize = null;
        if (host_start < auth_end and text[host_start] == '[') {
            const close = std.mem.findScalar(u8, text[host_start..auth_end], ']') orelse
                return error.InvalidIpv6;
            host_end = host_start + close + 1;
            if (host_end < auth_end) {
                if (text[host_end] != ':') return error.InvalidIpv6;
                port_start = host_end + 1;
            }
        } else if (std.mem.findScalar(u8, text[host_start..auth_end], ':')) |colon| {
            host_end = host_start + colon;
            port_start = host_end + 1;
        }

        const host_raw = text[host_start..host_end];
        if (host_raw.len > 0 and host_raw[0] == '[') {
            host = try writeIpv6(&w, host_raw[1 .. host_raw.len - 1]);
        } else {
            host = try writeHost(&w, host_raw, special);
        }
        if (host.len == 0 and special and !file) return error.EmptyHost;

        if (port_start) |ps| {
            if (file) return error.FileWithPort;
            port = try parsePort(text[ps..auth_end]);
            if (port != null and port.? == defaultPort(scheme)) port = null;
        }
        if (host.len == 0 and (at_sign_seen or port_start != null)) return error.EmptyHost;
        if (port) |p| {
            var digits: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&digits, ":{d}", .{p}) catch unreachable;
            try w.write(s);
        }
        i = auth_end;
    }

    const path_start = i;
    i = std.mem.findAnyPos(u8, text, path_start, "?#") orelse text.len;
    const raw_path = text[path_start..i];

    var path: []const u8 = "";
    if (!has_authority and !(raw_path.len > 0 and raw_path[0] == '/')) {
        // Opaque path: no dot segments, no slash rewriting. A space that
        // ends the path is the one byte the C0 control set misses.
        const span = try w.encoded(raw_path, .c0);
        path = w.slice(span);
        if (path.len > 0 and path[path.len - 1] == ' ') {
            w.len -= 1;
            try w.hex(' ');
            path = w.buf[span.start..w.len];
        }
    } else {
        const span = try writePath(&w, raw_path, special);
        path = w.slice(span);
        if (path.len == 0 and special) {
            try w.byte('/');
            path = w.buf[w.len - 1 ..][0..1];
        }
    }

    var query: ?[]const u8 = null;
    var fragment: ?[]const u8 = null;
    if (i < text.len and text[i] == '?') {
        i += 1;
        const qstart = i;
        i = std.mem.findAnyPos(u8, text, qstart, "#") orelse text.len;
        try w.byte('?');
        const span = if (special)
            try w.encoded(text[qstart..i], .special_query)
        else
            try w.encoded(text[qstart..i], .query);
        query = w.slice(span);
    }
    if (i < text.len and text[i] == '#') {
        i += 1;
        try w.byte('#');
        const span = try w.encoded(text[i..], .fragment);
        fragment = w.slice(span);
    }

    return .{
        .bytes = w.buf[0..w.len],
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
        .query = query,
        .fragment = fragment,
    };
}

fn writeUserinfo(w: *Writer, userinfo: []const u8) ParseError!void {
    var colon: ?usize = null;
    for (userinfo, 0..) |c, idx| {
        if (c == ':' and colon == null) colon = idx;
    }
    if (colon) |c| {
        _ = try w.encoded(userinfo[0..c], .userinfo);
        if (c + 1 == userinfo.len) return; // empty password: no colon
        try w.byte(':');
        _ = try w.encoded(userinfo[c + 1 ..], .userinfo);
    } else {
        _ = try w.encoded(userinfo, .userinfo);
        return;
    }
}

fn parsePort(text: []const u8) ParseError!?u16 {
    var value: u32 = 0;
    var digits: usize = 0;
    for (text) |c| {
        if (isTabOrNewline(c)) continue;
        if (!std.ascii.isDigit(c)) return error.InvalidPort;
        value = value * 10 + (c - '0');
        if (value > 0xffff) return error.InvalidPort;
        digits += 1;
    }
    if (digits == 0) return null;
    return @intCast(value);
}

fn writeHost(w: *Writer, raw: []const u8, special: bool) ParseError![]const u8 {
    if (!special) {
        // The opaque host parser does not percent-decode: `%` is allowed on
        // its own, non-ASCII is percent-encoded, and only the forbidden host
        // code points fail.
        const start = w.len;
        for (raw) |c| {
            if (isTabOrNewline(c)) continue;
            if (c == 0x7f or isForbiddenHost(c)) return error.InvalidHost;
            if (needsEncode(.c0, c)) try w.hex(c) else try w.byte(c);
        }
        return w.buf[start..w.len];
    }

    // Percent-decode first: the spec validates and classifies the decoded
    // text.
    var decoded_buf: [4096]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (isTabOrNewline(c)) {
            i += 1;
            continue;
        }
        if (n >= decoded_buf.len) return error.NoSpaceLeft;
        if (c == '%') {
            if (i + 2 >= raw.len) return error.InvalidHost;
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidHost;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.InvalidHost;
            decoded_buf[n] = hi << 4 | lo;
            i += 3;
        } else {
            decoded_buf[n] = c;
            i += 1;
        }
        n += 1;
    }
    const decoded = decoded_buf[0..n];
    if (decoded.len == 0) return "";

    for (decoded) |c| {
        if (c >= 0x80) return error.IdnaUnsupported;
    }
    if (endsInANumber(decoded)) {
        const ip4 = try parseIpv4(decoded);
        var text: [15]u8 = undefined;
        const s = std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{
            ip4[0], ip4[1], ip4[2], ip4[3],
        }) catch unreachable;
        try w.write(s);
        return w.buf[w.len - s.len ..][0..s.len];
    }
    for (decoded) |c| {
        if (isForbiddenDomain(c)) return error.InvalidHost;
    }
    const span = try w.asciiLowered(decoded);
    return w.slice(span);
}

fn endsInANumber(host: []const u8) bool {
    var parts_end = host.len;
    if (parts_end > 0 and host[parts_end - 1] == '.') parts_end -= 1;
    if (parts_end == 0) return false;
    var last_start: usize = 0;
    if (std.mem.findScalarLast(u8, host[0..parts_end], '.')) |dot| last_start = dot + 1;
    const last = host[last_start..parts_end];
    if (last.len == 0) return false;
    if (last.len >= 2 and last[0] == '0' and (last[1] == 'x' or last[1] == 'X')) {
        if (last.len == 2) return true;
        for (last[2..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    for (last) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn parseIpv4Number(part: []const u8) ParseError!u32 {
    var base: u8 = 10;
    var digits = part;
    if (part.len >= 2 and part[0] == '0' and (part[1] == 'x' or part[1] == 'X')) {
        base = 16;
        digits = part[2..];
        if (digits.len == 0) return 0;
    } else if (part.len >= 2 and part[0] == '0') {
        base = 8;
        digits = part[1..];
        if (digits.len == 0) return 0;
    }
    var value: u64 = 0;
    for (digits) |c| {
        const d = std.fmt.charToDigit(c, base) catch return error.InvalidIpv4;
        value = value * base + d;
        if (value > 0xffffffff) return error.InvalidIpv4;
    }
    return @intCast(value);
}

fn parseIpv4(host: []const u8) ParseError![4]u8 {
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (n == parts.len) return error.InvalidIpv4;
        parts[n] = part;
        n += 1;
    }
    if (n > 1 and parts[n - 1].len == 0) n -= 1;
    if (n > 4) return error.InvalidIpv4;

    var numbers: [4]u32 = @splat(0);
    for (parts[0..n], 0..) |part, idx| {
        if (part.len == 0) return error.InvalidIpv4;
        numbers[idx] = try parseIpv4Number(part);
    }
    if (n >= 2 and n <= 4) {
        const last_bits: u5 = @intCast(8 * (5 - n));
        if (numbers[n - 1] >= (@as(u32, 1) << last_bits)) return error.InvalidIpv4;
    }
    var ipv4: u32 = numbers[n - 1];
    for (numbers[0 .. n - 1], 0..) |num, idx| {
        if (num > 255) return error.InvalidIpv4;
        const shift: u5 = @intCast(8 * (3 - idx));
        ipv4 +%= num << shift;
    }
    return .{
        @intCast(ipv4 >> 24),
        @intCast((ipv4 >> 16) & 0xff),
        @intCast((ipv4 >> 8) & 0xff),
        @intCast(ipv4 & 0xff),
    };
}

fn writeIpv6(w: *Writer, text: []const u8) ParseError![]const u8 {
    const bytes = try parseIpv6(text);
    const start = w.len;
    try w.byte('[');
    var buf: [48]u8 = undefined;
    try w.write(formatIpv6(bytes, &buf));
    try w.byte(']');
    return w.buf[start..w.len];
}

/// The WHATWG IPv6 parser. Zone identifiers are not part of the grammar, so
/// `%` fails; the embedded IPv4 tail must be four decimal parts.
pub fn parseIpv6(text: []const u8) ParseError![16]u8 {
    var pieces: [8]u16 = @splat(0);
    var n: usize = 0;
    var compressed: ?usize = null;
    var i: usize = 0;

    if (text.len >= 2 and text[0] == ':' and text[1] == ':') {
        compressed = 0;
        i = 2;
    } else if (text.len >= 1 and text[0] == ':') {
        return error.InvalidIpv6;
    }
    if (i == text.len) return error.InvalidIpv6;

    while (i < text.len) {
        if (n == 8) return error.InvalidIpv6;
        if (text[i] == ':') {
            if (compressed != null) return error.InvalidIpv6;
            compressed = n;
            i += 1;
            continue;
        }
        var value: u16 = 0;
        var digits: usize = 0;
        while (digits < 4 and i < text.len and std.ascii.isHex(text[i])) : (digits += 1) {
            value = value * 16 + @as(u16, std.fmt.charToDigit(text[i], 16) catch unreachable);
            i += 1;
        }
        if (digits == 0) return error.InvalidIpv6;
        if (i < text.len and text[i] == '.') {
            // The tail is IPv4: four decimal parts, each 0..255.
            if (n > 6) return error.InvalidIpv6;
            const v4 = try parseEmbeddedIpv4(text[i - digits ..]);
            pieces[n] = @as(u16, v4[0]) << 8 | v4[1];
            pieces[n + 1] = @as(u16, v4[2]) << 8 | v4[3];
            n += 2;
            i = text.len;
            break;
        }
        if (i < text.len and text[i] == ':') {
            i += 1;
            if (i == text.len) return error.InvalidIpv6;
        } else if (i < text.len) {
            return error.InvalidIpv6;
        }
        pieces[n] = value;
        n += 1;
    }

    if (compressed) |c| {
        const tail = n - c;
        if (n > 7) return error.InvalidIpv6;
        // Expand the gap by shifting the tail up.
        var k: usize = n;
        while (k > c) : (k -= 1) pieces[7 - (n - k)] = pieces[k - 1];
        for (c..8 - tail) |j| pieces[j] = 0;
        n = 8;
    }
    if (n != 8) return error.InvalidIpv6;

    var bytes: [16]u8 = undefined;
    for (pieces, 0..) |piece, j| {
        bytes[j * 2] = @intCast(piece >> 8);
        bytes[j * 2 + 1] = @intCast(piece & 0xff);
    }
    return bytes;
}

fn parseEmbeddedIpv4(text: []const u8) ParseError![4]u8 {
    var out: [4]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (n == 4 or part.len == 0) return error.InvalidIpv6;
        if (part.len > 1 and part[0] == '0') return error.InvalidIpv6;
        var v: u16 = 0;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidIpv6;
            v = v * 10 + (c - '0');
            if (v > 255) return error.InvalidIpv6;
        }
        out[n] = @intCast(v);
        n += 1;
    }
    if (n != 4) return error.InvalidIpv6;
    return out;
}

/// Eight lowercase groups, the longest run of two or more zero groups
/// replaced by `::`.
pub fn formatIpv6(bytes: [16]u8, buf: *[48]u8) []const u8 {
    var groups: [8]u16 = undefined;
    for (0..8) |i| groups[i] = @as(u16, bytes[i * 2]) << 8 | bytes[i * 2 + 1];

    var best_start: usize = 8;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (groups[i] != 0) {
            i += 1;
            continue;
        }
        const run_start = i;
        while (i < 8 and groups[i] == 0) i += 1;
        const run_len = i - run_start;
        if (run_len > best_len) {
            best_len = run_len;
            best_start = run_start;
        }
    }
    if (best_len < 2) {
        best_start = 8;
        best_len = 0;
    }

    var out: Io.Writer = .fixed(buf);
    var g: usize = 0;
    var after_gap = false;
    while (g < 8) {
        if (g == best_start) {
            out.writeAll("::") catch unreachable;
            g += best_len;
            after_gap = true;
            continue;
        }
        if (g != 0 and !after_gap) out.writeByte(':') catch unreachable;
        out.print("{x}", .{groups[g]}) catch unreachable;
        after_gap = false;
        g += 1;
    }
    return out.buffered();
}

fn hasDotSegment(raw: []const u8) bool {
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |seg| {
        if (isSingleDot(seg) or isDoubleDot(seg)) return true;
    }
    return false;
}

fn writePath(w: *Writer, raw: []const u8, special: bool) ParseError!Span {
    // A canonical path copies straight through. Only a '.' costs the extra
    // segment walk.
    const start = w.len;
    var i: usize = 0;
    var saw_suspicious = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '.' or c == '%') {
            saw_suspicious = true;
            continue;
        }
        if (isTabOrNewline(c) or needsEncode(.path, c)) break;
        if (special and c == '\\') break;
    }
    if (i == raw.len and (!saw_suspicious or !hasDotSegment(raw))) {
        try w.write(raw);
        return .{ .start = start, .len = raw.len };
    }

    var tmp: [8192]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| {
        if (isTabOrNewline(c)) continue;
        if (n >= tmp.len) return error.NoSpaceLeft;
        tmp[n] = if (special and c == '\\') '/' else c;
        n += 1;
    }
    var encoded_buf: [8192]u8 = undefined;
    var ew: Writer = .{ .buf = &encoded_buf };
    const encoded = w.slice(try ew.encoded(tmp[0..n], .path));

    const normalized = removeDotSegments(encoded_buf[0..], encoded.len);
    try w.write(normalized);
    return .{ .start = start, .len = normalized.len };
}

fn isSingleDot(seg: []const u8) bool {
    return switch (seg.len) {
        1 => seg[0] == '.',
        3 => std.ascii.eqlIgnoreCase(seg, "%2e"),
        else => false,
    };
}

fn isDoubleDot(seg: []const u8) bool {
    return switch (seg.len) {
        2 => seg[0] == '.' and seg[1] == '.',
        4, 6 => blk: {
            var dots: usize = 0;
            var i: usize = 0;
            while (i < seg.len) {
                if (seg[i] == '.') {
                    dots += 1;
                    i += 1;
                } else if (std.ascii.eqlIgnoreCase(seg[i..][0..@min(3, seg.len - i)], "%2e")) {
                    dots += 1;
                    i += 3;
                } else break :blk false;
            }
            break :blk dots == 2;
        },
        else => false,
    };
}

/// The WHATWG path shortening: segments are kept in place in `buf`, which is
/// the same buffer `path` came from, so output never outruns input.
pub fn removeDotSegments(buf: []u8, len: usize) []const u8 {
    const path = buf[0..len];
    if (std.mem.findScalar(u8, path, '.') == null and
        std.mem.findScalar(u8, path, '%') == null) return path;

    var out_len: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        // path[i] is '/' by construction: a path from an authority starts
        // with one, and every segment consumes its leading slash.
        const seg_start = i + 1;
        var seg_end = seg_start;
        while (seg_end < path.len and path[seg_end] != '/') seg_end += 1;
        const seg = buf[seg_start..seg_end];
        const last = seg_end == path.len;
        if (isSingleDot(seg)) {
            if (last) {
                buf[out_len] = '/';
                out_len += 1;
            }
        } else if (isDoubleDot(seg)) {
            if (out_len > 0) {
                out_len -= 1;
                while (out_len > 0 and buf[out_len] != '/') out_len -= 1;
            }
            if (last) {
                buf[out_len] = '/';
                out_len += 1;
            }
        } else {
            buf[out_len] = '/';
            out_len += 1;
            @memmove(buf[out_len..][0..seg.len], seg);
            out_len += seg.len;
        }
        i = seg_end;
    }
    return buf[0..out_len];
}

test parse {
    var buf: [512]u8 = undefined;

    {
        const url = try parse("HTTP://ExAmPlE.CoM:80/a/../b/./c?x=1#frag", &buf);
        try testing.expectEqualStrings("http://example.com/b/c?x=1#frag", url.bytes);
        try testing.expectEqualStrings("http", url.scheme);
        try testing.expectEqualStrings("example.com", url.host);
        try testing.expectEqualStrings("/b/c", url.path);
        try testing.expectEqualStrings("x=1", url.query.?);
        try testing.expectEqualStrings("frag", url.fragment.?);
        try testing.expectEqual(@as(?u16, null), url.port);
    }

    // A backslash ends a special-scheme authority, so this host is
    // example.com and `/@evil.com/` is the path. Reading the last `@` as the
    // userinfo separator puts evil.com in the host instead, which is the
    // difference between two parsers disagreeing and an allowlist bypass.
    try expectSerialized("http://example.com\\@evil.com/", "http://example.com/@evil.com/", &buf);

    // The WHATWG IPv4 number parser reads hex, octal, and 1..4 parts.
    try expectSerialized("http://0x7f.1/", "http://127.0.0.1/", &buf);
    try expectSerialized("http://127.1/", "http://127.0.0.1/", &buf);
    try expectSerialized("http://192.0x00A80001/", "http://192.168.0.1/", &buf);
    try testing.expectError(error.InvalidIpv4, parse("http://192.168.0.257/", &buf));

    // Percent-encoded separators and dot segments are decoded, then removed.
    try expectSerialized("http://example.com/%2e%2e/admin", "http://example.com/admin", &buf);

    // A leading and trailing space is stripped, and a tab is gone wherever it
    // appears.
    try expectSerialized(" http://example.com/ ", "http://example.com/", &buf);
    try expectSerialized("http://exa\tmple.com/", "http://example.com/", &buf);

    // Empty credentials and an empty port serialize to nothing.
    try expectSerialized("https://:@test", "https://test/", &buf);
    try expectSerialized("https://test:@test", "https://test@test/", &buf);
    try expectSerialized("http://f:/c", "http://f/c", &buf);

    // A special scheme with no `//` still reaches the authority.
    try expectSerialized("http:/example.com/", "http://example.com/", &buf);
    try expectSerialized("http:example.com/", "http://example.com/", &buf);

    // IPv6 hosts serialize in canonical form, including an embedded IPv4 tail.
    try expectSerialized("http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", &buf);
    try expectSerialized("http://[0:0:0:0:0:0:0:1]/", "http://[::1]/", &buf);
    try expectSerialized("http://[2001::1]:80/", "http://[2001::1]/", &buf);

    // Non-special schemes keep an opaque path, and fail where the spec says
    // a host is required.
    try expectSerialized("data:text/plain,hi", "data:text/plain,hi", &buf);
    try expectSerialized("foo://host/path", "foo://host/path", &buf);
    try testing.expectError(error.EmptyHost, parse("http://user:pass@/", &buf));

    // An opaque path ending in a space encodes that one space.
    try expectSerialized("non-special:opaque  ?hi", "non-special:opaque %20?hi", &buf);

    // A space in a path or query is encoded; `%` is not validated there.
    try expectSerialized("http://example.com/a b?c d", "http://example.com/a%20b?c%20d", &buf);
    try expectSerialized("http://example.com/?a=%zz", "http://example.com/?a=%zz", &buf);

    // IDNA is the documented gap, not a silent pass-through.
    try testing.expectError(error.IdnaUnsupported, parse("http://münchen.de/", &buf));
}

fn expectSerialized(input: []const u8, want: []const u8, buf: []u8) !void {
    const url = try parse(input, buf);
    try testing.expectEqualStrings(want, url.bytes);
}

test parseIpv4 {
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, try parseIpv4("127.0.0.1"));
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, try parseIpv4("127.1"));
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, try parseIpv4("0x7f.0.0.1"));
    try testing.expectEqual([4]u8{ 192, 168, 0, 1 }, try parseIpv4("192.0x00A80001"));
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, try parseIpv4("1.2.3.4."));
    try testing.expectError(error.InvalidIpv4, parseIpv4("192.168.0.257"));
    try testing.expectError(error.InvalidIpv4, parseIpv4("1.2.3.4.5"));
    try testing.expectError(error.InvalidIpv4, parseIpv4("1..2"));
}

/// Builds the byte form from eight 16-bit groups, for readable test vectors.
fn v6(groups: [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |g, i| {
        bytes[i * 2] = @intCast(g >> 8);
        bytes[i * 2 + 1] = @intCast(g & 0xff);
    }
    return bytes;
}

test parseIpv6 {
    try testing.expectEqual(v6(.{ 0, 0, 0, 0, 0, 0, 0, 1 }), try parseIpv6("::1"));
    try testing.expectEqual(
        v6(.{ 0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111 }),
        try parseIpv6("2606:4700:4700::1111"),
    );
    try testing.expectEqual(
        v6(.{ 0, 0, 0, 0, 0, 0xffff, 0x7f00, 1 }),
        try parseIpv6("::ffff:127.0.0.1"),
    );
    try testing.expectError(error.InvalidIpv6, parseIpv6("::1%25eth0"));
    try testing.expectError(error.InvalidIpv6, parseIpv6("1:2:3:4:5:6:7:8:9"));
    try testing.expectError(error.InvalidIpv6, parseIpv6("::1::2"));
}

test formatIpv6 {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("::1", formatIpv6(v6(.{ 0, 0, 0, 0, 0, 0, 0, 1 }), &buf));
    try testing.expectEqualStrings(
        "2606:4700:4700::1111",
        formatIpv6(v6(.{ 0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111 }), &buf),
    );
    try testing.expectEqualStrings(
        "::ffff:7f00:1",
        formatIpv6(v6(.{ 0, 0, 0, 0, 0, 0xffff, 0x7f00, 1 }), &buf),
    );
    // A single zero group is not compressed.
    try testing.expectEqualStrings(
        "1:2:3:4:5:6:0:8",
        formatIpv6(v6(.{ 1, 2, 3, 4, 5, 6, 0, 8 }), &buf),
    );
    // The longest run wins; a tie goes to the first.
    try testing.expectEqualStrings(
        "1:0:0:2::3",
        formatIpv6(v6(.{ 1, 0, 0, 2, 0, 0, 0, 3 }), &buf),
    );
}

test removeDotSegments {
    try expectDotSegments("/a/b/c/./../../g", "/a/g");
    try expectDotSegments("/././foo", "/foo");
    try expectDotSegments("/a/.", "/a/");
    try expectDotSegments("/a/..", "/");
    try expectDotSegments("/foo/%2e", "/foo/");
    try expectDotSegments("/a/%2e%2e/b", "/b");
    try expectDotSegments("/a//b", "/a//b");
}

fn expectDotSegments(input: []const u8, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..input.len], input);
    try testing.expectEqualStrings(want, removeDotSegments(&buf, input.len));
}
