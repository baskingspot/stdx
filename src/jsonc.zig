//! JSON with comments, for configuration files.
//!
//! JSONC is RFC 8259 JSON plus `//` and `/* */` comments and a trailing comma
//! before `}` or `]`. This module does not parse JSON. It copies the source,
//! blanks every comment byte and trailing comma to a space, and hands the copy
//! to `std.json`, so std owns every JSON rule and every JSON error.
//!
//! The copy has the same length as the source and every byte keeps its offset.
//! A `std.json.Diagnostics` read from the copy reports the line and column of
//! the same byte in the caller's input.
//!
//! A UTF-8 BOM at offset 0 is blanked. That is the one leniency beyond
//! comments and trailing commas. JSON5 needs a real parser and stays out:
//! single quotes, unquoted keys, hex numbers, `NaN`, `Infinity`, and a leading
//! or trailing decimal point.

const std = @import("std");
const json = std.json;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

/// The UTF-8 byte order mark, accepted only at offset 0.
const bom = "\xEF\xBB\xBF";

/// Failures of the scrubber itself. Every JSON failure comes from `std.json`
/// after the scrub, not from here.
pub const Error = error{
    /// A `/*` with no closing `*/`. `scrubWithDiagnostics` and
    /// `scrubInPlaceWithDiagnostics` report the position in `Diagnostics`.
    UnterminatedBlockComment,
};

/// The position of a scrub failure, in the caller's source. The fields hold
/// their defaults until a scrub fails.
pub const Diagnostics = struct {
    /// Byte offset of the opening `/*`.
    offset: usize = 0,
    /// 1-based line at `offset`.
    line: usize = 1,
    /// 1-based column at `offset`.
    column: usize = 1,
};

/// What the scrub accepts beyond JSON.
pub const Options = struct {
    /// Accept `//` and `/* */` comments. When false, a comment byte reaches
    /// `std.json` unchanged and fails there.
    comments: bool = true,
    /// Accept a comma that follows a value and precedes `}` or `]`. When
    /// false, the comma reaches `std.json` unchanged and fails there.
    trailing_commas: bool = true,
};

/// An owned scrubbed copy of a source. Byte `i` of `bytes` is byte `i` of the
/// source, either unchanged or replaced by a space.
pub const Scrubbed = struct {
    /// The copy. Its length equals the source length.
    bytes: []u8,
    /// The allocator that owns `bytes`.
    allocator: Allocator,

    /// Free the copy.
    pub fn deinit(self: *Scrubbed) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Copy `source` into a new buffer and blank its comments and trailing commas
/// to spaces. The copy has the same length as `source`, and a UTF-8 BOM at
/// offset 0 is blanked too.
///
/// For the position of an `error.UnterminatedBlockComment`, use
/// `scrubWithDiagnostics`.
pub fn scrub(
    allocator: Allocator,
    source: []const u8,
    options: Options,
) (Error || Allocator.Error)!Scrubbed {
    var diagnostics: Diagnostics = .{};
    return scrubWithDiagnostics(allocator, source, options, &diagnostics);
}

/// `scrub`, with the position of a failure written to `diagnostics`.
pub fn scrubWithDiagnostics(
    allocator: Allocator,
    source: []const u8,
    options: Options,
    diagnostics: *Diagnostics,
) (Error || Allocator.Error)!Scrubbed {
    const buffer = try allocator.dupe(u8, source);
    errdefer allocator.free(buffer);
    try scrubInPlaceWithDiagnostics(buffer, options, diagnostics);
    return .{ .bytes = buffer, .allocator = allocator };
}

/// Blank the comments, the trailing commas, and a UTF-8 BOM at offset 0 in
/// `buffer` without allocating.
///
/// The buffer is the caller's source and is modified in place. On
/// `error.UnterminatedBlockComment`, bytes before the opening `/*` may already
/// be blanked.
pub fn scrubInPlace(buffer: []u8, options: Options) Error!void {
    var diagnostics: Diagnostics = .{};
    return scrubInPlaceWithDiagnostics(buffer, options, &diagnostics);
}

/// `scrubInPlace`, with the position of a failure written to `diagnostics`.
pub fn scrubInPlaceWithDiagnostics(
    buffer: []u8,
    options: Options,
    diagnostics: *Diagnostics,
) Error!void {
    diagnostics.* = .{};

    if (mem.startsWith(u8, buffer, bom)) @memset(buffer[0..bom.len], ' ');

    // The last byte outside a string that is not whitespace or a comment. A
    // comma is trailing only after a value, so `[,]` stays for std.json to
    // reject instead of becoming `[ ]`.
    var previous: u8 = 0;
    var i: usize = 0;
    while (i < buffer.len) {
        switch (buffer[i]) {
            '"' => {
                i = skipString(buffer, i);
                previous = '"';
            },
            '/' => {
                if (options.comments and i + 1 < buffer.len) {
                    switch (buffer[i + 1]) {
                        '/' => {
                            i = blankLineComment(buffer, i);
                            continue;
                        },
                        '*' => {
                            i = try blankBlockComment(buffer, i, diagnostics);
                            continue;
                        },
                        else => {},
                    }
                }
                previous = buffer[i];
                i += 1;
            },
            ',' => {
                if (options.trailing_commas and canEndValue(previous)) {
                    switch (try nextSignificant(buffer, i + 1, options, diagnostics)) {
                        .close => buffer[i] = ' ',
                        .other, .end => {},
                    }
                }
                previous = ',';
                i += 1;
            },
            ' ', '\t', '\r', '\n' => i += 1,
            else => {
                previous = buffer[i];
                i += 1;
            },
        }
    }
}

/// Parse `source` as JSONC into `T`. `std.json` does the parse.
///
/// The returned value owns the scrubbed copy, so a string in `value` stays
/// valid until `deinit`. `parse_options` passes to `std.json` unchanged.
pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: Options,
    parse_options: json.ParseOptions,
) ParseError!Parsed(T) {
    var scrubbed = try scrub(allocator, source, options);
    errdefer scrubbed.deinit();
    const parsed = try json.parseFromSlice(T, allocator, scrubbed.bytes, parse_options);
    return .{ .value = parsed.value, .parsed = parsed, .scrubbed = scrubbed };
}

/// The result of `parseFromSlice`. It owns the parsed allocations and the
/// scrubbed copy, and a string in `value` can point into either.
pub fn Parsed(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The parsed value.
        value: T,
        /// The `std.json` result, which owns the parsed allocations.
        parsed: json.Parsed(T),
        /// The copy that `value` may point into.
        scrubbed: Scrubbed,

        /// Free the parsed allocations and the copy.
        pub fn deinit(self: *Self) void {
            self.parsed.deinit();
            self.scrubbed.deinit();
            self.* = undefined;
        }
    };
}

/// The errors of `parseFromSlice`: a scrub failure, or any error that
/// `std.json` reports for the copy.
pub const ParseError = Error || json.ParseError(json.Scanner);

/// The byte after a string that opens at `start`, or `buffer.len` when the
/// string never closes. `std.json` reports the missing quote.
fn skipString(buffer: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < buffer.len) {
        switch (buffer[i]) {
            '\\' => {
                // The byte after a backslash is content, even a quote.
                i += 1;
                if (i < buffer.len) i += 1;
            },
            '"' => return i + 1,
            else => i += 1,
        }
    }
    return buffer.len;
}

/// The line ending that ends the line comment at `start`, or `buffer.len`.
/// A bare carriage return ends the comment, as in JavaScript.
fn lineCommentEnd(buffer: []const u8, start: usize) usize {
    var i = start;
    while (i < buffer.len and buffer[i] != '\n' and buffer[i] != '\r') : (i += 1) {}
    return i;
}

/// The byte after the `*/` that closes the block comment at `start`.
fn blockCommentEnd(
    buffer: []const u8,
    start: usize,
    diagnostics: *Diagnostics,
) Error!usize {
    var i = start + 2;
    while (i + 1 < buffer.len) : (i += 1) {
        if (buffer[i] == '*' and buffer[i + 1] == '/') return i + 2;
    }
    return noteError(diagnostics, buffer, start);
}

/// Blank the line comment at `start` and return its line ending or
/// `buffer.len`.
fn blankLineComment(buffer: []u8, start: usize) usize {
    const end = lineCommentEnd(buffer, start);
    @memset(buffer[start..end], ' ');
    return end;
}

/// Blank the block comment at `start` and return the byte after its `*/`.
/// Newlines stay so that every later line keeps its number.
fn blankBlockComment(buffer: []u8, start: usize, diagnostics: *Diagnostics) Error!usize {
    const end = try blockCommentEnd(buffer, start, diagnostics);
    for (buffer[start..end]) |*byte| switch (byte.*) {
        '\n', '\r' => {},
        else => byte.* = ' ',
    };
    return end;
}

/// What the first byte at or after `start` that is not whitespace or a
/// comment is: a closing bracket, anything else, or the end of the buffer.
const Next = enum { close, other, end };

fn nextSignificant(
    buffer: []const u8,
    start: usize,
    options: Options,
    diagnostics: *Diagnostics,
) Error!Next {
    var i = start;
    while (i < buffer.len) {
        switch (buffer[i]) {
            ' ', '\t', '\r', '\n' => i += 1,
            '}', ']' => return .close,
            '/' => {
                if (!options.comments or i + 1 == buffer.len) return .other;
                switch (buffer[i + 1]) {
                    '/' => i = lineCommentEnd(buffer, i),
                    '*' => i = try blockCommentEnd(buffer, i, diagnostics),
                    else => return .other,
                }
            },
            else => return .other,
        }
    }
    return .end;
}

/// Whether `byte` can be the last byte of a JSON value. A comma after `[`,
/// `{`, `:`, or another comma is not a trailing comma.
fn canEndValue(byte: u8) bool {
    return switch (byte) {
        '"', '}', ']', '0'...'9', 'e', 'E', '.', '+', '-', 'l' => true,
        else => false,
    };
}

fn noteError(diagnostics: *Diagnostics, source: []const u8, offset: usize) Error {
    const before = source[0..offset];
    const line_start = if (mem.findScalarLast(u8, before, '\n')) |nl| nl + 1 else 0;
    diagnostics.* = .{
        .offset = offset,
        .line = 1 + mem.count(u8, before, "\n"),
        .column = offset - line_start + 1,
    };
    return error.UnterminatedBlockComment;
}

test scrub {
    const source =
        \\/* A block comment before the document. */
        \\// A line comment before the document.
        \\{
        \\    "a": 1, /* a block comment */
        \\    "b": "http://example.com/*not*/a//b", // a line comment
        \\    "c": 3
        \\}
        \\// A comment after it.
        \\/* And a block comment after it. */
    ;
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();

    try testing.expectEqual(source.len, scrubbed.bytes.len);
    try testing.expectEqual(@as(u8, ' '), scrubbed.bytes[0]);
    try testing.expectEqual(@as(u8, '\n'), scrubbed.bytes[mem.find(u8, source, "\n").?]);

    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    const object = doc.value.object;
    try testing.expectEqual(@as(i64, 1), object.get("a").?.integer);
    try testing.expectEqualStrings("http://example.com/*not*/a//b", object.get("b").?.string);
    try testing.expectEqual(@as(i64, 3), object.get("c").?.integer);
}

test "a comment marker inside a string is not a comment" {
    const source =
        \\{
        \\    "url": "http://example.com/a//b",
        \\    "block": "/* not a comment */",
        \\    "close": "*/",
        \\    "quote": "a\"//b"
        \\}
    ;
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();
    try testing.expectEqualStrings(source, scrubbed.bytes);

    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    const object = doc.value.object;
    try testing.expectEqualStrings("http://example.com/a//b", object.get("url").?.string);
    try testing.expectEqualStrings("/* not a comment */", object.get("block").?.string);
    try testing.expectEqualStrings("*/", object.get("close").?.string);
    try testing.expectEqualStrings("a\"//b", object.get("quote").?.string);
}

test "a comma that is not trailing stays a comma" {
    const source = "{\"a\": [1, 2, 3], \"b\": 4}";
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();
    try testing.expectEqualStrings(source, scrubbed.bytes);
}

test "a trailing comma before an object or an array close" {
    const source =
        \\{
        \\    "a": [1, 2,],
        \\    "b": {
        \\        "c": 3 /* a comment */ ,
        \\    },
        \\    "d": 4, // another comment
        \\    "e": [
        \\        1,
        \\        2, // a comment before the close
        \\    ],
        \\}
    ;
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();

    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    const object = doc.value.object;
    try testing.expectEqual(@as(i64, 2), object.get("a").?.array.items[1].integer);
    try testing.expectEqual(@as(i64, 3), object.get("b").?.object.get("c").?.integer);
    try testing.expectEqual(@as(i64, 4), object.get("d").?.integer);
    const e = object.get("e").?.array;
    try testing.expectEqual(@as(usize, 2), e.items.len);
    try testing.expectEqual(@as(i64, 2), e.items[1].integer);
}

test "a comma with no value before it stays for std.json to reject" {
    var scrubbed = try scrub(testing.allocator, "[,]", .{});
    defer scrubbed.deinit();
    try testing.expectEqualStrings("[,]", scrubbed.bytes);
    try testing.expectError(
        error.SyntaxError,
        json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{}),
    );

    var doubled = try scrub(testing.allocator, "[1,,]", .{});
    defer doubled.deinit();
    try testing.expectEqualStrings("[1,,]", doubled.bytes);
    try testing.expectError(
        error.SyntaxError,
        json.parseFromSlice(json.Value, testing.allocator, doubled.bytes, .{}),
    );
}

test "a comment may contain a quote or a bracket" {
    const source = "{\"a\"/* a \" and a ] */: 1}";
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();
    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.value.object.get("a").?.integer);
}

test "an unterminated block comment reports its position" {
    const source = "{\n  \"a\": 1,\n  /* open\n}";
    const offset = mem.find(u8, source, "/*").?;

    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.UnterminatedBlockComment,
        scrubWithDiagnostics(testing.allocator, source, .{}, &diagnostics),
    );
    try testing.expectEqual(offset, diagnostics.offset);
    try testing.expectEqual(@as(usize, 3), diagnostics.line);
    try testing.expectEqual(@as(usize, 3), diagnostics.column);
}

test "an unterminated comment in the trailing-comma scan reports its position" {
    const source = "[1, /* open";
    var diagnostics: Diagnostics = .{};
    try testing.expectError(
        error.UnterminatedBlockComment,
        scrubWithDiagnostics(testing.allocator, source, .{}, &diagnostics),
    );
    try testing.expectEqual(mem.find(u8, source, "/*").?, diagnostics.offset);
}

test "an unterminated string is left to std.json" {
    const source = "{\"a\": \"open";
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();
    try testing.expectEqualStrings(source, scrubbed.bytes);
    try testing.expectError(
        error.UnexpectedEndOfInput,
        json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{}),
    );
}

test "a UTF-8 BOM at offset 0 is blanked" {
    const source = "\xEF\xBB\xBF{\"a\": 1}";
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();

    try testing.expectEqual(source.len, scrubbed.bytes.len);
    try testing.expectEqualStrings("   {\"a\": 1}", scrubbed.bytes);
    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.value.object.get("a").?.integer);
}

test "CRLF keeps every line ending" {
    const source = "{\r\n    // a comment\r\n    \"a\": 1, // trailing\r\n}";
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();

    try testing.expectEqual(
        mem.count(u8, source, "\r\n"),
        mem.count(u8, scrubbed.bytes, "\r\n"),
    );
    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.value.object.get("a").?.integer);
}

test "a bare carriage return ends a line comment" {
    const source = "// a comment\r{\"a\": 1}";
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();
    const doc = try json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.value.object.get("a").?.integer);
}

test "comments off leaves a comment for std.json" {
    const source = "{\"a\": 1} // a comment";
    var scrubbed = try scrub(testing.allocator, source, .{ .comments = false });
    defer scrubbed.deinit();
    try testing.expectEqualStrings(source, scrubbed.bytes);
    try testing.expectError(
        error.SyntaxError,
        json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{}),
    );
}

test "trailing commas off leaves the comma for std.json" {
    const source = "[1,]";
    var scrubbed = try scrub(testing.allocator, source, .{ .trailing_commas = false });
    defer scrubbed.deinit();
    try testing.expectEqualStrings(source, scrubbed.bytes);
    try testing.expectError(
        error.SyntaxError,
        json.parseFromSlice(json.Value, testing.allocator, scrubbed.bytes, .{}),
    );
}

test "plain JSON is unchanged" {
    const source = "{\"a\": [1, 2, 3], \"b\": true}";
    var with_extensions = try scrub(testing.allocator, source, .{});
    defer with_extensions.deinit();
    try testing.expectEqualStrings(source, with_extensions.bytes);

    var plain = try scrub(testing.allocator, source, .{
        .comments = false,
        .trailing_commas = false,
    });
    defer plain.deinit();
    try testing.expectEqualStrings(source, plain.bytes);
}

test "every byte keeps its offset" {
    const source =
        \\{
        \\    // a line comment
        \\    "a": "text", /* a block
        \\    comment */ "b": [1, 2,]
        \\}
    ;
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();

    try testing.expectEqual(source.len, scrubbed.bytes.len);
    for (source, scrubbed.bytes) |before, after| {
        try testing.expectEqual(before == '\n', after == '\n');
        if (before != after) try testing.expectEqual(@as(u8, ' '), after);
    }
}

test "a JSON error keeps its line and column" {
    const source =
        \\{
        \\    "a": 1, // first
        \\    /* the rest
        \\       is a comment */
        \\    "b": 2
        \\    "c": 3
        \\}
    ;
    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();

    var diagnostics: json.Diagnostics = .{};
    var scanner = json.Scanner.initCompleteInput(testing.allocator, scrubbed.bytes);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diagnostics);

    const Doc = struct { a: u8, b: u8, c: u8 };
    const result = json.parseFromTokenSource(Doc, testing.allocator, &scanner, .{});
    try testing.expectError(error.SyntaxError, result);

    const bad = mem.find(u8, source, "\"c\"").?;
    const line_start = if (mem.findScalarLast(u8, source[0..bad], '\n')) |nl| nl + 1 else 0;
    try testing.expectEqual(@as(u64, bad), diagnostics.getByteOffset());
    try testing.expectEqual(
        @as(u64, 1 + mem.count(u8, source[0..bad], "\n")),
        diagnostics.getLine(),
    );
    try testing.expectEqual(@as(u64, bad - line_start + 1), diagnostics.getColumn());
}

test "scrub is idempotent" {
    const source =
        \\// leading
        \\{"a": [1,], /* middle */ "b": "// string"}
    ;
    var once = try scrub(testing.allocator, source, .{});
    defer once.deinit();
    var twice = try scrub(testing.allocator, once.bytes, .{});
    defer twice.deinit();
    try testing.expectEqualStrings(once.bytes, twice.bytes);
}

test "scrubInPlace matches scrub" {
    const source =
        \\{
        \\    // a line comment
        \\    "a": [1, 2,], /* a block comment */
        \\}
    ;
    var buffer: [source.len]u8 = undefined;
    @memcpy(buffer[0..], source);
    try scrubInPlace(&buffer, .{});

    var scrubbed = try scrub(testing.allocator, source, .{});
    defer scrubbed.deinit();
    try testing.expectEqualStrings(scrubbed.bytes, &buffer);
}

test "parseFromSlice owns the scrubbed copy" {
    const source =
        \\// config
        \\{
        \\    "name": "gateway", // a name
        \\    "port": 8080,
        \\    /* the list */
        \\    "tags": ["edge", "internal",],
        \\}
    ;
    const Config = struct {
        name: []const u8,
        port: u16,
        tags: []const []const u8,
    };
    var parsed = try parseFromSlice(Config, testing.allocator, source, .{}, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("gateway", parsed.value.name);
    try testing.expectEqual(@as(u16, 8080), parsed.value.port);
    try testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try testing.expectEqualStrings("edge", parsed.value.tags[0]);
    try testing.expectEqualStrings("internal", parsed.value.tags[1]);
}

test "parseFromSlice frees the scrub on a failure" {
    try testing.expectError(
        error.SyntaxError,
        parseFromSlice(json.Value, testing.allocator, "{\"a\": }", .{}, .{}),
    );
    try testing.expectError(
        error.UnterminatedBlockComment,
        parseFromSlice(json.Value, testing.allocator, "{\"a\": 1 /*", .{}, .{}),
    );
}

test "fuzz scrub never panics and keeps the layout" {
    // Native fuzzing: 256 bytes per iteration. The scrub must never panic,
    // must keep every byte in place, and the owned and in-place paths must
    // agree. A successful scrub is idempotent, because it removes every
    // comment and trailing comma that a second pass would act on.
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var input: [256]u8 = undefined;
            smith.bytes(&input);

            var diagnostics: Diagnostics = .{};
            var scrubbed = scrubWithDiagnostics(
                testing.allocator,
                &input,
                .{},
                &diagnostics,
            ) catch |err| {
                try testing.expectEqual(error.UnterminatedBlockComment, err);
                try testing.expect(diagnostics.offset < input.len);
                try testing.expect(diagnostics.line >= 1);
                try testing.expect(diagnostics.column >= 1);
                return;
            };
            defer scrubbed.deinit();

            try testing.expectEqual(input.len, scrubbed.bytes.len);
            for (input, scrubbed.bytes) |before, after| {
                try testing.expect(after == before or after == ' ');
                if (before == '\n') try testing.expectEqual(@as(u8, '\n'), after);
            }

            var in_place = input;
            try scrubInPlace(&in_place, .{});
            try testing.expectEqualStrings(scrubbed.bytes, &in_place);

            var again = try scrub(testing.allocator, scrubbed.bytes, .{});
            defer again.deinit();
            try testing.expectEqualStrings(scrubbed.bytes, again.bytes);
        }
    }.run, .{
        .corpus = &.{
            "",
            "{}",
            "// c\n{\"a\": 1, /* x */}",
            "{\"s\": \"// not a comment\", \"t\": [1, 2,],}",
            "/*",
            "{\"a\": \"unterminated",
        },
    });
}

test {
    testing.refAllDecls(@This());
}
