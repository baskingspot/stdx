//! `.env` file parsing: `KEY=VALUE` lines, quotes, and comments.
//!
//! std has no parser for this format, and every project that reads one writes
//! its own trimming, comment, and quoting rules. A loader that quietly
//! disagrees with the file it was given resolves an empty value or a stale
//! key, and the mistake shows up as a wrong port, not as an error. This
//! parser implements one grammar and names the line that does not fit:
//!
//! - One assignment per line. A line ends at `\n` or at the end of the
//!   source, and a `\r` immediately before either belongs to the terminator,
//!   so a CRLF file parses like an LF file. The source may start with a UTF-8
//!   BOM.
//! - Leading spaces and tabs are skipped. A line whose first other byte is
//!   `#` is a comment. A line of nothing but spaces and tabs is blank.
//! - `export` followed by a space or a tab before the key is ignored. The key
//!   matches `[A-Za-z_][A-Za-z0-9_]*`; anything else is
//!   `error.InvalidKey`. A line with no `=` is `error.MissingEquals`.
//! - Spaces and tabs around `=`, and after an unquoted value, are trimmed.
//! - An unquoted value runs to the end of the line. A `#` preceded by a space
//!   or a tab begins a comment; any other `#` is part of the value, so
//!   `PASSWORD=#secret` keeps its `#`.
//! - A single-quoted value is literal up to the next `'`. No escape is
//!   interpreted.
//! - A double-quoted value accepts `\n`, `\r`, `\t`, `\\`, `\"`, and `\$`.
//!   Any other escape is `error.InvalidEscape`. Both quoted forms may span
//!   lines, and inside them every byte is taken as written, CRLF included.
//! - A quoted value may be followed by spaces, a tab, and a comment on the
//!   same line. Anything else is `error.TrailingCharacters`.
//!
//! Duplicate keys are kept in order, and `Doc.get` returns the last one;
//! nothing here decides which assignment the caller believes. Nothing expands
//! a variable either: expansion needs an environment, which belongs to the
//! caller, not to the file. `$VAR` stays four bytes.
//!
//! The parse allocates nothing. A key or a value is a slice of the caller's
//! source, or of a caller-owned scratch buffer when a double-quoted escape
//! needs decoding. The entry list is a caller-owned array. A file larger than
//! either reports `error.EntriesFull` or `error.ScratchFull` rather than
//! growing.

const std = @import("std");
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;
const print = std.debug.print;
const testing = std.testing;

/// The UTF-8 byte order mark, accepted at the start of a source and nowhere
/// else.
const bom = "\xEF\xBB\xBF";

/// The bytes that separate tokens: a space and a tab. A newline ends the line.
const blanks = " \t";

/// One `KEY=VALUE` assignment. `key` and `value` point into the caller's
/// source or scratch, and stay valid while both live. `line` is the 1-based
/// line where the key starts.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    line: u32,
};

/// Why a parse stopped.
pub const Error = error{
    /// A line is neither blank, a comment, nor an assignment.
    MissingEquals,
    /// The key is empty or holds a byte outside `[A-Za-z_][A-Za-z0-9_]*`.
    InvalidKey,
    /// A backslash in a double-quoted value is followed by a byte outside
    /// `n`, `r`, `t`, `\`, `"`, and `$`.
    InvalidEscape,
    /// A quoted value reaches the end of the source with no closing quote.
    UnterminatedQuote,
    /// A quoted value is followed by a byte other than a blank, a comment, or
    /// the line terminator.
    TrailingCharacters,
    /// The caller's entry array is full.
    EntriesFull,
    /// The caller's scratch buffer is full.
    ScratchFull,
};

/// Where a parse stopped, and why. `parse` fills every field before it
/// returns the error, and writes nothing at all when the parse succeeds.
pub const Diagnostics = struct {
    /// Byte offset into the original source. For `EntriesFull` this is the
    /// start of the entry that did not fit; for `ScratchFull` it is the
    /// escape whose decoded byte did not fit.
    offset: usize,
    /// The 1-based line of `offset`, counted on the original bytes.
    line: u32,
    /// The 1-based column of `offset`, counted in bytes from the last newline
    /// before it. On the first line a UTF-8 BOM counts like any other byte,
    /// the way `std.json.Diagnostics.getColumn` counts it.
    column: u32,
    /// The failure.
    problem: Error,

    /// The problem in a few words, for a log line.
    pub fn message(self: Diagnostics) []const u8 {
        return switch (self.problem) {
            error.MissingEquals => "a line with no '='",
            error.InvalidKey => "invalid key",
            error.InvalidEscape => "invalid escape",
            error.UnterminatedQuote => "unterminated quote",
            error.TrailingCharacters => "characters after a quoted value",
            error.EntriesFull => "no room for another entry",
            error.ScratchFull => "scratch buffer full",
        };
    }
};

/// Options for `parse`.
pub const ParseOptions = struct {
    /// Filled on a failed parse. Untouched when the parse succeeds.
    diagnostics: ?*Diagnostics,

    /// A parse that reports no position.
    pub const init: ParseOptions = .{ .diagnostics = null };
};

/// A parsed source: every entry in file order, duplicates included.
pub const Doc = struct {
    /// The entries in file order. A repeated key appears once per assignment.
    entries: []const Entry,

    /// The value of the last entry for `key`, or null. The scan runs
    /// backwards, so the last assignment to a key wins. This is linear in the
    /// entry count, which for a configuration file is tens of entries.
    pub fn get(self: Doc, key: []const u8) ?[]const u8 {
        var i = self.entries.len;
        while (i > 0) {
            i -= 1;
            if (mem.eql(u8, self.entries[i].key, key)) return self.entries[i].value;
        }
        return null;
    }
};

/// Parse `source` into `entries`, with the decoded bytes of double-quoted
/// escapes going into `scratch`.
///
/// `scratch` holds one byte per decoded escape and is empty for a source with
/// no escaped value. A source of `n` bytes never needs more than `n` bytes of
/// scratch: a decoded value is never longer than the text it came from, and
/// the values it holds are disjoint. The contract matches `sort.radix`, whose
/// scratch is also the caller's.
///
/// Nothing is allocated and nothing is copied except an escaped value. Keys,
/// unquoted values, and quoted values without escapes point into `source`;
/// an escaped value points into `scratch`. The returned `Doc` is a window
/// into `entries`. All three outlive the `Doc`, and none of them may move
/// while it is in use.
///
/// A capacity that is too small is an error, not a panic:
/// `error.EntriesFull` when the file holds more assignments than `entries`,
/// and `error.ScratchFull` when the escapes decode to more bytes than
/// `scratch` holds. A caller that does not know the count allocates
/// `entries` from an arena and retries on `error.EntriesFull`.
///
/// A failure returns one of `Error`. Set `options.diagnostics` to a
/// `Diagnostics` value to receive the position of the byte that stopped the
/// parse. Nothing is copied: the parser writes into that value directly, and
/// it stays untouched when the parse succeeds.
pub fn parse(
    source: []const u8,
    entries: []Entry,
    scratch: []u8,
    options: ParseOptions,
) Error!Doc {
    var parser: Parser = .init(source, entries, scratch, options.diagnostics);
    return parser.run();
}

/// The bytes of 1-based `line`, without the line terminator and without the
/// BOM that line 1 may start with. The result is empty when `line` is past
/// the last line. Use it to show the diagnostics for a failed parse beside
/// the text that caused them.
pub fn lineText(source: []const u8, line: u32) []const u8 {
    if (line == 0) return "";
    var start: usize = if (mem.startsWith(u8, source, bom)) bom.len else 0;
    var n: u32 = 1;
    while (n < line) : (n += 1) {
        const end = mem.findScalarPos(u8, source, start, '\n') orelse return "";
        start = end + 1;
    }
    const end = mem.findScalarPos(u8, source, start, '\n') orelse source.len;
    const stop = if (end > start and source[end - 1] == '\r') end - 1 else end;
    return source[start..stop];
}

/// The single-pass scanner. `pos` is always the next byte to read, and `line`
/// follows it, so an entry's line number costs nothing extra.
const Parser = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    entries: []Entry,
    count: usize,
    scratch: []u8,
    written: usize,
    /// The caller's struct, or null when the caller asked for no position.
    diagnostics: ?*Diagnostics,

    fn init(
        source: []const u8,
        entries: []Entry,
        scratch: []u8,
        diagnostics: ?*Diagnostics,
    ) Parser {
        return .{
            .source = source,
            .pos = if (mem.startsWith(u8, source, bom)) bom.len else 0,
            .line = 1,
            .entries = entries,
            .count = 0,
            .scratch = scratch,
            .written = 0,
            .diagnostics = diagnostics,
        };
    }

    fn run(self: *Parser) Error!Doc {
        while (self.pos < self.source.len) try self.statement();
        return .{ .entries = self.entries[0..self.count] };
    }

    /// One line: blank, a comment, or an assignment.
    fn statement(self: *Parser) Error!void {
        self.skipBlanks();
        if (self.atEol()) return self.endLine();
        if (self.source[self.pos] == '#') return self.endLine();
        try self.assignment();
    }

    fn assignment(self: *Parser) Error!void {
        const entry_line = self.line;
        if (self.exportPrefix()) self.skipBlanks();
        const key_start = self.pos;
        const equals = mem.findScalar(u8, self.source[key_start..self.lineEnd()], '=') orelse
            return self.fail(error.MissingEquals, key_start);
        const equals_pos = key_start + equals;
        const key = mem.trimEnd(u8, self.source[key_start..equals_pos], blanks);
        if (invalidKey(key)) |bad| return self.fail(error.InvalidKey, key_start + bad);

        self.pos = equals_pos + 1;
        self.skipBlanks();
        const value = try self.parseValue();
        try self.append(.{ .key = key, .value = value, .line = entry_line }, key_start);
        self.endLine();
    }

    /// A value in any of the three forms. The first byte decides: a quote
    /// starts a quoted value, and everything else is unquoted.
    fn parseValue(self: *Parser) Error![]const u8 {
        if (self.pos >= self.contentEnd()) return "";
        return switch (self.source[self.pos]) {
            '\'' => self.singleQuoted(),
            '"' => self.doubleQuoted(),
            else => self.bare(),
        };
    }

    /// A value with no quotes: the rest of the line, less a trailing comment.
    fn bare(self: *Parser) []const u8 {
        const start = self.pos;
        const end = self.contentEnd();
        var stop = end;
        var i = start;
        while (i < end) : (i += 1) {
            if (self.source[i] != '#') continue;
            // A `#` begins a comment only after a blank. A value that starts
            // with one (`KEY=#secret`) keeps it, because the byte before is
            // the `=`.
            if (i > 0 and isBlank(self.source[i - 1])) {
                stop = i;
                break;
            }
        }
        self.pos = end;
        return mem.trimEnd(u8, self.source[start..stop], blanks);
    }

    fn singleQuoted(self: *Parser) Error![]const u8 {
        const open = self.pos;
        const close = mem.findScalarPos(u8, self.source, open + 1, '\'') orelse
            return self.fail(error.UnterminatedQuote, open);
        self.line += @intCast(mem.count(u8, self.source[open..close], "\n"));
        self.pos = close + 1;
        try self.endQuoted();
        return self.source[open + 1 .. close];
    }

    fn doubleQuoted(self: *Parser) Error![]const u8 {
        const open = self.pos;
        // The value stays a slice of the source until the first escape, then
        // it moves to the scratch and stays there. An escape makes the value
        // one contiguous run either way, so no second copy is needed.
        var value_start: ?usize = null;
        var i = open + 1;
        while (i < self.source.len) {
            const byte = self.source[i];
            if (byte == '"') {
                const value = if (value_start) |start|
                    self.scratch[start..self.written]
                else
                    self.source[open + 1 .. i];
                self.line += @intCast(mem.count(u8, self.source[open + 1 .. i], "\n"));
                self.pos = i + 1;
                try self.endQuoted();
                return value;
            }
            if (byte == '\\') {
                if (i + 1 == self.source.len) return self.fail(error.UnterminatedQuote, open);
                const decoded: u8 = switch (self.source[i + 1]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '$' => '$',
                    else => return self.fail(error.InvalidEscape, i),
                };
                if (value_start == null) {
                    value_start = self.written;
                    try self.pushSlice(self.source[open + 1 .. i], i);
                }
                try self.push(decoded, i);
                i += 2;
                continue;
            }
            if (value_start != null) try self.push(byte, i);
            i += 1;
        }
        return self.fail(error.UnterminatedQuote, open);
    }

    /// After a closing quote: blanks, then a comment or the line terminator.
    /// A comment needs a blank before its `#`, so a `#` glued to the quote is
    /// the mistake it looks like.
    fn endQuoted(self: *Parser) Error!void {
        const after = self.pos;
        const end = self.contentEnd();
        var i = after;
        while (i < end and isBlank(self.source[i])) i += 1;
        if (i >= end) return;
        if (self.source[i] == '#' and i > after) return;
        return self.fail(error.TrailingCharacters, i);
    }

    fn push(self: *Parser, byte: u8, origin: usize) Error!void {
        if (self.written == self.scratch.len) return self.fail(error.ScratchFull, origin);
        self.scratch[self.written] = byte;
        self.written += 1;
    }

    fn pushSlice(self: *Parser, bytes: []const u8, origin: usize) Error!void {
        if (bytes.len > self.scratch.len - self.written) {
            return self.fail(error.ScratchFull, origin);
        }
        @memcpy(self.scratch[self.written..][0..bytes.len], bytes);
        self.written += bytes.len;
    }

    fn append(self: *Parser, entry: Entry, origin: usize) Error!void {
        if (self.count == self.entries.len) return self.fail(error.EntriesFull, origin);
        self.entries[self.count] = entry;
        self.count += 1;
    }

    /// `export` followed by a blank is a prefix; anything else is the start
    /// of the key.
    fn exportPrefix(self: *Parser) bool {
        const rest = self.source[self.pos..];
        if (!mem.startsWith(u8, rest, "export")) return false;
        if (rest.len == "export".len or !isBlank(rest["export".len])) return false;
        self.pos += "export".len;
        return true;
    }

    fn skipBlanks(self: *Parser) void {
        while (self.pos < self.source.len and isBlank(self.source[self.pos])) self.pos += 1;
    }

    /// Nothing but the CRLF or the terminator is left on this line.
    fn atEol(self: Parser) bool {
        return self.pos >= self.contentEnd();
    }

    /// Consume the rest of the line and its terminator.
    fn endLine(self: *Parser) void {
        self.pos = self.lineEnd();
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.line += 1;
        }
    }

    /// Index of the next `\n`, or the end of the source.
    fn lineEnd(self: Parser) usize {
        return mem.findScalarPos(u8, self.source, self.pos, '\n') orelse self.source.len;
    }

    /// `lineEnd` less the `\r` of a CRLF terminator. Both ends of a line stop
    /// here, so no caller sees a terminator byte.
    fn contentEnd(self: Parser) usize {
        const end = self.lineEnd();
        return if (end > self.pos and self.source[end - 1] == '\r') end - 1 else end;
    }

    fn fail(self: *Parser, problem: Error, origin: usize) Error {
        if (self.diagnostics) |diagnostics| {
            noteError(diagnostics, self.source, origin, problem);
        }
        return problem;
    }
};

/// Fill `diagnostics` with the position and the cause of a failure at
/// `offset`.
fn noteError(diagnostics: *Diagnostics, source: []const u8, offset: usize, problem: Error) void {
    assert(offset <= source.len);
    const before = source[0..offset];
    const line_start = if (mem.findScalarLast(u8, before, '\n')) |newline| newline + 1 else 0;
    diagnostics.* = .{
        .offset = offset,
        .line = @intCast(1 + mem.count(u8, before, "\n")),
        .column = @intCast(offset - line_start + 1),
        .problem = problem,
    };
}

fn isBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

/// The first byte of `key` that the grammar rejects, or null.
fn invalidKey(key: []const u8) ?usize {
    if (key.len == 0) return 0;
    if (!isKeyStart(key[0])) return 0;
    for (key[1..], 1..) |byte, i| {
        if (!isKeyByte(byte)) return i;
    }
    return null;
}

fn isKeyStart(byte: u8) bool {
    return byte == '_' or ascii.isAlphabetic(byte);
}

fn isKeyByte(byte: u8) bool {
    return isKeyStart(byte) or ascii.isDigit(byte);
}

test parse {
    const source =
        \\# a comment
        \\PORT=8080
        \\export HOST=127.0.0.1
        \\
        \\GREETING='hello world'
        \\
    ;
    var entries: [8]Entry = undefined;
    var scratch: [64]u8 = undefined;
    const doc = try expectDoc(source, &entries, &scratch);

    try testing.expectEqual(@as(usize, 3), doc.entries.len);
    try testing.expectEqualStrings("PORT", doc.entries[0].key);
    try testing.expectEqualStrings("8080", doc.entries[0].value);
    try testing.expectEqual(@as(u32, 2), doc.entries[0].line);
    try testing.expectEqualStrings("HOST", doc.entries[1].key);
    try testing.expectEqual(@as(u32, 3), doc.entries[1].line);
    try testing.expectEqualStrings("hello world", doc.get("GREETING").?);
    try testing.expect(doc.get("MISSING") == null);

    // A key is a slice of the caller's bytes, not a copy.
    const key_at = mem.find(u8, source, "PORT").?;
    try testing.expectEqual(@intFromPtr(source[key_at..].ptr), @intFromPtr(doc.entries[0].key.ptr));
}

test "duplicate keys keep their order and get returns the last" {
    var entries: [4]Entry = undefined;
    var scratch: [16]u8 = undefined;
    const doc = try expectDoc("A=1\nA=2\nA=3\n", &entries, &scratch);
    try testing.expectEqual(@as(usize, 3), doc.entries.len);
    try testing.expectEqualStrings("1", doc.entries[0].value);
    try testing.expectEqualStrings("2", doc.entries[1].value);
    try testing.expectEqualStrings("3", doc.entries[2].value);
    try testing.expectEqualStrings("3", doc.get("A").?);
}

test "unquoted values" {
    var entries: [16]Entry = undefined;
    var scratch: [64]u8 = undefined;

    // Whitespace around the `=` and after the value is trimmed.
    const doc = try expectDoc(
        "A = 1\nB\t=\t2  \nC=3\n",
        &entries,
        &scratch,
    );
    try testing.expectEqualStrings("1", doc.get("A").?);
    try testing.expectEqualStrings("2", doc.get("B").?);
    try testing.expectEqualStrings("3", doc.get("C").?);

    // The first `=` separates the key; the rest belong to the value.
    const equals = try expectDoc("URL=a=b=c\n", &entries, &scratch);
    try testing.expectEqualStrings("a=b=c", equals.get("URL").?);

    // A value that is only whitespace is empty.
    const blank = try expectDoc("EMPTY=   \n", &entries, &scratch);
    try testing.expectEqualStrings("", blank.get("EMPTY").?);

    // A `#` after a blank begins a comment; inside a word it is literal, and
    // so is one at the start of the value.
    const hashes = try expectDoc(
        "A=one # trailing\nB=two#three\nC=#four\nD= # comment\n",
        &entries,
        &scratch,
    );
    try testing.expectEqualStrings("one", hashes.get("A").?);
    try testing.expectEqualStrings("two#three", hashes.get("B").?);
    try testing.expectEqualStrings("#four", hashes.get("C").?);
    try testing.expectEqualStrings("", hashes.get("D").?);

    // Spaces and tabs inside the value stay.
    const inner = try expectDoc("A=one two\tthree\n", &entries, &scratch);
    try testing.expectEqualStrings("one two\tthree", inner.get("A").?);
}

test "quoted values" {
    var entries: [8]Entry = undefined;
    var scratch: [128]u8 = undefined;

    // Single quotes are literal, including a backslash and a `#`.
    const single = try expectDoc(
        \\A='raw \n stays # here'
        \\
    , &entries, &scratch);
    try testing.expectEqualStrings("raw \\n stays # here", single.get("A").?);

    // Every accepted escape in one value.
    const double = try expectDoc(
        \\A="one\ntwo\tthree\\four\"five\$six\r"
        \\
    , &entries, &scratch);
    try testing.expectEqualStrings("one\ntwo\tthree\\four\"five$six\r", double.get("A").?);

    // A double-quoted value with no escape stays a slice of the source.
    const source = "A=\"plain\"\n";
    const plain = try expectDoc(source, &entries, &scratch);
    const value = plain.get("A").?;
    try testing.expectEqualStrings("plain", value);
    try testing.expectEqual(@intFromPtr(source[3..].ptr), @intFromPtr(value.ptr));

    // Quoted values may span lines, and the next entry's line number follows.
    const multi = try expectDoc(
        "A=\"one\ntwo\"\nB=2\n",
        &entries,
        &scratch,
    );
    try testing.expectEqualStrings("one\ntwo", multi.get("A").?);
    try testing.expectEqual(@as(u32, 3), multi.entries[1].line);

    // A quoted value may be followed by blanks and a comment.
    const comment = try expectDoc("A=\"one\"  # here\nB=2\n", &entries, &scratch);
    try testing.expectEqualStrings("one", comment.get("A").?);
    try testing.expectEqual(@as(u32, 2), comment.entries[1].line);

    // A value starting with a quote is quoted; a quote inside a word is not.
    const apostrophe = try expectDoc("A=it's fine\n", &entries, &scratch);
    try testing.expectEqualStrings("it's fine", apostrophe.get("A").?);

    // An empty quoted value is empty, not a diagnostic.
    const empty = try expectDoc("A=''\nB=\"\"\n", &entries, &scratch);
    try testing.expectEqualStrings("", empty.get("A").?);
    try testing.expectEqualStrings("", empty.get("B").?);
}

test "empty and short sources" {
    var entries: [4]Entry = undefined;
    var scratch: [16]u8 = undefined;

    // An empty file has no entries.
    try testing.expectEqual(@as(usize, 0), (try expectDoc("", &entries, &scratch)).entries.len);

    // A key at the end of the file with an empty value, and no trailing
    // newline anywhere.
    const doc = try expectDoc("A=1\nB=", &entries, &scratch);
    try testing.expectEqual(@as(usize, 2), doc.entries.len);
    try testing.expectEqualStrings("", doc.get("B").?);

    // No trailing newline on the last assignment is the same as one.
    const no_newline = try expectDoc("A=last", &entries, &scratch);
    try testing.expectEqualStrings("last", no_newline.get("A").?);
}

test "export prefix" {
    var entries: [4]Entry = undefined;
    var scratch: [16]u8 = undefined;

    const doc = try expectDoc("export A=1\nexport\tB=2\n", &entries, &scratch);
    try testing.expectEqualStrings("1", doc.get("A").?);
    try testing.expectEqualStrings("2", doc.get("B").?);

    // Without a blank after it, `export` is part of the key.
    const glued = try expectDoc("exportA=1\nexport=2\n", &entries, &scratch);
    try testing.expectEqualStrings("1", glued.get("exportA").?);
    try testing.expectEqualStrings("2", glued.get("export").?);
}

test "BOM and CRLF" {
    var entries: [4]Entry = undefined;
    var scratch: [32]u8 = undefined;

    const doc = try expectDoc("\xEF\xBB\xBFA=1\r\nB=2\r\n", &entries, &scratch);
    try testing.expectEqual(@as(usize, 2), doc.entries.len);
    try testing.expectEqualStrings("A", doc.entries[0].key);
    try testing.expectEqualStrings("1", doc.entries[0].value);
    try testing.expectEqual(@as(u32, 1), doc.entries[0].line);
    try testing.expectEqual(@as(u32, 2), doc.entries[1].line);
    try testing.expectEqualStrings("2", doc.get("B").?);

    // The offsets, the lines, and the columns count the original bytes, BOM
    // and CRLF included.
    const bad = try expectFailure(
        "\xEF\xBB\xBFA=1\r\nB.c=2\r\n",
        &entries,
        &scratch,
        error.InvalidKey,
    );
    try testing.expectEqual(@as(u32, 2), bad.line);
    try testing.expectEqual(@as(u32, 2), bad.column);
    try testing.expectEqual(@as(usize, 9), bad.offset);

    // A trailing `\r` with no `\n` is part of the last terminator.
    const last = try expectDoc("A=1\r", &entries, &scratch);
    try testing.expectEqualStrings("1", last.get("A").?);
}

test "diagnostics" {
    var entries: [8]Entry = undefined;
    var scratch: [32]u8 = undefined;

    const Case = struct {
        source: []const u8,
        problem: Error,
        line: u32,
        column: u32,
        offset: usize,
    };
    const cases = [_]Case{
        // A key outside the grammar is an error, and the position points at
        // the first offending byte.
        .{
            .source = "A=1\nFOO.BAR=2\n",
            .problem = error.InvalidKey,
            .line = 2,
            .column = 4,
            .offset = 7,
        },
        .{
            .source = "1A=2",
            .problem = error.InvalidKey,
            .line = 1,
            .column = 1,
            .offset = 0,
        },
        .{
            .source = "A-B=2",
            .problem = error.InvalidKey,
            .line = 1,
            .column = 2,
            .offset = 1,
        },
        .{
            .source = "=2",
            .problem = error.InvalidKey,
            .line = 1,
            .column = 1,
            .offset = 0,
        },
        .{
            .source = "A=1\n\nNO ASSIGN=1\n",
            .problem = error.InvalidKey,
            .line = 3,
            .column = 3,
            .offset = 7,
        },
        .{
            .source = "\n\nFOO",
            .problem = error.MissingEquals,
            .line = 3,
            .column = 1,
            .offset = 2,
        },
        .{
            .source = "A=\"\\q\"",
            .problem = error.InvalidEscape,
            .line = 1,
            .column = 4,
            .offset = 3,
        },
        .{
            .source = "A='open",
            .problem = error.UnterminatedQuote,
            .line = 1,
            .column = 3,
            .offset = 2,
        },
        .{
            .source = "A=\"open",
            .problem = error.UnterminatedQuote,
            .line = 1,
            .column = 3,
            .offset = 2,
        },
        .{
            .source = "A=\"x\\",
            .problem = error.UnterminatedQuote,
            .line = 1,
            .column = 3,
            .offset = 2,
        },
        // A multiline value reports the line and the column the escape is on.
        .{
            .source = "A=\"one\n\\q\"",
            .problem = error.InvalidEscape,
            .line = 2,
            .column = 1,
            .offset = 7,
        },
        .{
            .source = "A='x' y",
            .problem = error.TrailingCharacters,
            .line = 1,
            .column = 7,
            .offset = 6,
        },
        .{
            .source = "A=\"x\"#c",
            .problem = error.TrailingCharacters,
            .line = 1,
            .column = 6,
            .offset = 5,
        },
    };
    for (cases) |case| {
        const d = try expectFailure(case.source, &entries, &scratch, case.problem);
        try testing.expectEqual(case.problem, d.problem);
        try testing.expectEqual(case.line, d.line);
        try testing.expectEqual(case.column, d.column);
        try testing.expectEqual(case.offset, d.offset);
    }
}

test "diagnostic messages" {
    // Every problem has a message, and no two share one, so a log line names
    // the failure rather than a category.
    const problems = [_]Error{
        error.MissingEquals,
        error.InvalidKey,
        error.InvalidEscape,
        error.UnterminatedQuote,
        error.TrailingCharacters,
        error.EntriesFull,
        error.ScratchFull,
    };
    for (problems, 0..) |problem, i| {
        const d: Diagnostics = .{ .offset = 0, .line = 1, .column = 1, .problem = problem };
        const message = d.message();
        try testing.expect(message.len != 0);
        for (problems[0..i]) |earlier| {
            const e: Diagnostics = .{ .offset = 0, .line = 1, .column = 1, .problem = earlier };
            try testing.expect(!mem.eql(u8, message, e.message()));
        }
    }
}

test "caller capacity" {
    var small: [1]Entry = undefined;
    var scratch: [32]u8 = undefined;

    // More assignments than slots: the entry that did not fit names its line.
    const full = try expectFailure("A=1\nB=2\n", &small, &scratch, error.EntriesFull);
    try testing.expectEqual(@as(u32, 2), full.line);
    try testing.expectEqual(@as(u32, 1), full.column);
    try testing.expectEqual(@as(usize, 4), full.offset);

    // The scratch holds the whole decoded value, not just the escape bytes.
    var entries: [4]Entry = undefined;
    var three: [3]u8 = undefined;
    const decoded = try expectDoc("A=\"x\\ny\"", &entries, &three);
    try testing.expectEqualStrings("x\ny", decoded.get("A").?);

    var none: [0]u8 = undefined;
    _ = try expectFailure("A=\"\\n\\t\"", &entries, &none, error.ScratchFull);
    // A source with no escape needs no scratch at all.
    const plain = try expectDoc("A=\"plain\"", &entries, &none);
    try testing.expectEqualStrings("plain", plain.get("A").?);
}

test "several escapes in one value decode in place" {
    const source = "A=\"\\tone\\ntwo\\\\three\"\n";
    var entries: [2]Entry = undefined;
    var scratch: [source.len]u8 = undefined;
    const doc = try expectDoc(source, &entries, &scratch);
    try testing.expectEqualStrings("\tone\ntwo\\three", doc.get("A").?);
}

test "lineText" {
    const source = "\xEF\xBB\xBFA=1\r\nB=2\n\nC='x' y";
    try testing.expectEqualStrings("A=1", lineText(source, 1));
    try testing.expectEqualStrings("B=2", lineText(source, 2));
    try testing.expectEqualStrings("", lineText(source, 3));
    try testing.expectEqualStrings("C='x' y", lineText(source, 4));
    try testing.expectEqualStrings("", lineText(source, 5));
    try testing.expectEqualStrings("", lineText(source, 0));

    // The diagnostics and the text agree on the line.
    var entries: [8]Entry = undefined;
    var scratch: [32]u8 = undefined;
    const d = try expectFailure(source, &entries, &scratch, error.TrailingCharacters);
    try testing.expectEqualStrings("C='x' y", lineText(source, d.line));
}

test "a successful parse leaves the caller's diagnostics untouched" {
    // A value no parse would produce, so a write of any field shows up.
    const untouched: Diagnostics = .{
        .offset = std.math.maxInt(usize),
        .line = 0,
        .column = 0,
        .problem = error.ScratchFull,
    };
    var entries: [4]Entry = undefined;
    var scratch: [16]u8 = undefined;
    var diagnostics: Diagnostics = untouched;

    const doc = try parse("A=1\n", &entries, &scratch, .{ .diagnostics = &diagnostics });
    try testing.expectEqualStrings("1", doc.get("A").?);
    try testing.expectEqual(untouched, diagnostics);

    // A caller that wants no position passes no diagnostics, and still gets
    // the error.
    try testing.expectError(error.InvalidKey, parse("A.b=1\n", &entries, &scratch, .init));
}

/// The largest source the fuzz test hands to `parse`. Its scratch is the same
/// size because a decoded value is never longer than the text it came from.
const fuzz_bytes = 192;

test "fuzz: any bytes parse or diagnose, never panic" {
    try testing.fuzz({}, fuzzAny, .{
        .corpus = &.{
            "A=1\n",
            "export A='x'\n# c\nB=\"y\\nz\"\n",
            "A = \"multi\nline\" # tail\n",
            "\xEF\xBB\xBFA=1\r\nB.c=2\r\n",
        },
    });
}

fn fuzzAny(_: void, smith: *testing.Smith) anyerror!void {
    var bytes: [fuzz_bytes]u8 = undefined;
    smith.bytes(&bytes);
    try checkParse(&bytes);

    // Map the same bytes onto the grammar's own alphabet, so the quoting,
    // comment, and escape paths are reached instead of stopping at the first
    // invalid key.
    const alphabet = "ABC_=1 \t\n\r#'\"\\export$";
    for (&bytes) |*byte| byte.* = alphabet[byte.* % alphabet.len];
    try checkParse(&bytes);
}

/// What any input must keep: no panic, every slice inside the buffer it came
/// from, entries in file order, and a failure whose position agrees with the
/// error that came with it.
fn checkParse(source: []const u8) !void {
    assert(source.len <= fuzz_bytes);
    var entries: [16]Entry = undefined;
    var scratch: [fuzz_bytes]u8 = undefined;
    var diagnostics: Diagnostics = undefined;
    if (parse(source, &entries, &scratch, .{ .diagnostics = &diagnostics })) |doc| {
        var previous_line: u32 = 0;
        for (doc.entries) |entry| {
            try testing.expect(within(source, entry.key));
            try testing.expect(within(source, entry.value) or within(&scratch, entry.value));
            try testing.expect(previous_line <= entry.line);
            // A key never spans lines.
            try testing.expectEqual(@as(usize, 0), mem.count(u8, entry.key, "\n"));
            previous_line = entry.line;
        }
        if (doc.entries.len != 0) {
            const last = doc.entries[doc.entries.len - 1];
            try testing.expectEqualStrings(last.value, doc.get(last.key).?);
        }
    } else |problem| {
        // The error union and the struct report the same failure.
        try testing.expectEqual(problem, diagnostics.problem);
        try testing.expect(diagnostics.offset <= source.len);
        try testing.expect(diagnostics.line >= 1);
        try testing.expect(diagnostics.column >= 1);
        try testing.expect(diagnostics.column <= diagnostics.offset + 1);
        _ = lineText(source, diagnostics.line);
    }
}

fn within(buf: []const u8, slice: []const u8) bool {
    if (slice.len == 0) return true;
    const start = @intFromPtr(buf.ptr);
    const at = @intFromPtr(slice.ptr);
    return at >= start and at + slice.len <= start + buf.len;
}

/// Parse `source` and require a document, printing the diagnostics when the
/// requirement fails.
fn expectDoc(source: []const u8, entries: []Entry, scratch: []u8) !Doc {
    var diagnostics: Diagnostics = undefined;
    return parse(source, entries, scratch, .{ .diagnostics = &diagnostics }) catch {
        print("\ndotenv: {s} at line {d}, column {d}, offset {d}\n", .{
            diagnostics.message(),
            diagnostics.line,
            diagnostics.column,
            diagnostics.offset,
        });
        return error.UnexpectedDiagnostic;
    };
}

/// Parse `source` and require the failure `want`, returning the diagnostics
/// the caller's struct received.
fn expectFailure(
    source: []const u8,
    entries: []Entry,
    scratch: []u8,
    want: Error,
) !Diagnostics {
    var diagnostics: Diagnostics = undefined;
    try testing.expectError(
        want,
        parse(source, entries, scratch, .{ .diagnostics = &diagnostics }),
    );
    try testing.expectEqual(want, diagnostics.problem);
    return diagnostics;
}

test {
    testing.refAllDecls(@This());
}
