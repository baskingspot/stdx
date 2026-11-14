//! The WHATWG URL conformance corpus, run against `stdx.url`.
//!
//! `urltestdata.json` is the URL Standard's own test corpus, vendored from
//! web-platform-tests at commit `065d99ab` (2026-11-12), BSD-3-Clause; the
//! license sits beside it in `urltestdata.LICENSE`. Each entry carries an
//! `input`, an optional `base`, and either the expected `href` and components
//! or `"failure": true`.
//!
//! The counts below are the ratchet. A change that makes the parser worse
//! fails the test; a change that makes it better also fails it, until the new
//! numbers are written down here. That is on purpose: the number is the claim
//! the module doc and the README make.

const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const url = @import("stdx").url;

const corpus = @embedFile("urltestdata.json");

const Counts = struct {
    /// Parses, and the serialization equals `href`.
    ok: usize,
    /// Parses when it must not, or serializes to something else.
    bad: usize,
    /// A host with non-ASCII bytes: this parser has no IDNA.
    idna: usize,
    /// A relative reference: base resolution is not implemented yet.
    relative: usize,
};

const expected: Counts = .{
    .ok = 655,
    .bad = 33,
    .idna = 13,
    .relative = 203,
};

/// A scheme has to start with an ASCII letter and hold only scheme
/// characters up to the first `:`.
fn hasScheme(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return false;
}

/// A special scheme whose text after the colon does not start with `//` is a
/// relative reference when the base has the same scheme: it needs the base,
/// not `parse`.
fn needsBase(input: []const u8, base: ?[]const u8) bool {
    const b = base orelse return false;
    const colon = std.mem.findScalar(u8, input, ':') orelse return false;
    const bcolon = std.mem.findScalar(u8, b, ':') orelse return false;
    if (!std.ascii.eqlIgnoreCase(input[0..colon], b[0..bcolon])) return false;
    return !std.mem.startsWith(u8, input[colon + 1 ..], "//");
}

test "WHATWG url corpus" {
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, corpus, .{});
    defer doc.deinit();

    var counts: Counts = .{ .ok = 0, .bad = 0, .idna = 0, .relative = 0 };
    var bad: std.ArrayList([]const u8) = .empty;
    defer bad.deinit(testing.allocator);
    var buf: [16384]u8 = undefined;

    for (doc.value.array.items) |v| {
        if (v != .object) continue;
        const input = switch (v.object.get("input") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const failure = if (v.object.get("failure")) |x| x == .bool and x.bool else false;
        const want = if (v.object.get("href")) |x| switch (x) {
            .string => |s| s,
            else => "",
        } else "";
        const base = if (v.object.get("base")) |x| switch (x) {
            .string => |s| s,
            else => null,
        } else null;

        if (!hasScheme(input) or needsBase(input, base)) {
            counts.relative += 1;
            continue;
        }
        const got = url.parse(input, &buf) catch |err| {
            if (failure) {
                counts.ok += 1;
            } else if (err == error.IdnaUnsupported) {
                counts.idna += 1;
            } else {
                counts.bad += 1;
                try bad.append(testing.allocator, input);
            }
            continue;
        };
        if (!failure and std.mem.eql(u8, got.bytes, want)) {
            counts.ok += 1;
        } else {
            counts.bad += 1;
            try bad.append(testing.allocator, input);
        }
    }

    if (counts.ok != expected.ok or counts.bad != expected.bad or
        counts.idna != expected.idna or counts.relative != expected.relative)
    {
        print(
            "\ncorpus moved: ok {d} -> {d}, bad {d} -> {d}, idna {d} -> {d}, relative {d} -> {d}\n",
            .{
                expected.ok,       counts.ok,
                expected.bad,      counts.bad,
                expected.idna,     counts.idna,
                expected.relative, counts.relative,
            },
        );
        // Only a regression needs the list; a count that moved the other way
        // is the improvement being recorded.
        if (counts.bad > expected.bad) {
            for (bad.items) |input| print("  bad: {s}\n", .{input});
        }
        return error.CorpusMoved;
    }
}
