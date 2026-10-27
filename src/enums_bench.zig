//! The enums module's benchmarks: a keyword chain, std's
//! length-bucketed map, the generated tags, and `stringToEnum`, over the
//! same corpus. The corpus holds each keyword, the same keyword with one
//! byte changed (a same-length miss), and lengths no keyword has.

const std = @import("std");
const mem = std.mem;

const stdx = @import("stdx");
const enums = stdx.enums;
const testingx = @import("testingx");

const Corpus = struct {
    words: [128][]const u8 = undefined,
    misses: [16][32]u8 = undefined,

    fn init(self: *Corpus, comptime kvs: anytype) void {
        inline for (kvs, 0..) |kv, i| {
            const word = kv[0];
            @memcpy(self.misses[i][0..word.len], word);
            self.misses[i][word.len - 1] = if (word[word.len - 1] == 'z') 'y' else 'z';
            self.words[2 * i] = word;
            self.words[2 * i + 1] = self.misses[i][0..word.len];
        }
        const tail = [_][]const u8{
            "", "q", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "transactional",
        };
        const n = 2 * kvs.len;
        for (tail, 0..) |word, i| self.words[n + i] = word;
        var i = n + tail.len;
        while (i < self.words.len) : (i += 1) self.words[i] = self.words[i % (n + tail.len)];
    }
};

var corpus: Corpus = .{};

fn run(b: *testingx.B, comptime kvs: anytype, comptime f: fn ([]const u8) u8) !void {
    corpus.init(kvs);
    var sink: u16 = 0;
    var i: u32 = 0;
    while (try b.loop()) : (i +%= 1) {
        sink +%= f(corpus.words[b.blackBox(&i).* & 127]);
    }
    b.keepAlive(sink);
}

const Mode = enum { transaction, session, statement, unknown };

const three = .{
    .{ "transaction", Mode.transaction },
    .{ "session", Mode.session },
    .{ "statement", Mode.statement },
};

const three_names = .{ "transaction", "session", "statement" };

fn eqlThree(str: []const u8) u8 {
    inline for (three) |kv| {
        if (mem.eql(u8, str, kv[0])) return @intFromEnum(kv[1]);
    }
    return @intFromEnum(Mode.unknown);
}

const static_three = std.StaticStringMap(Mode).initComptime(three);

fn staticMapThree(str: []const u8) u8 {
    return @intFromEnum(static_three.get(str) orelse Mode.unknown);
}

const openThree = enums.Open(three_names);

fn matchThree(str: []const u8) u8 {
    return @intFromEnum(openThree.match(str));
}

fn toEnumThree(str: []const u8) u8 {
    return @intFromEnum(enums.stringToEnum(Mode, str) orelse Mode.unknown);
}

pub fn benchmarkEqlThree(b: *testingx.B) !void {
    try run(b, three, eqlThree);
}

pub fn benchmarkStaticMapThree(b: *testingx.B) !void {
    try run(b, three, staticMapThree);
}

pub fn benchmarkOpenThree(b: *testingx.B) !void {
    try run(b, three, matchThree);
}

pub fn benchmarkToEnumThree(b: *testingx.B) !void {
    try run(b, three, toEnumThree);
}

const Mode16 = enum {
    transaction,
    session,
    statement,
    default,
    local,
    read,
    write,
    commit,
    rollback,
    serializable,
    repeatable,
    readcommitted,
    snapshot,
    readonly,
    deferrable,
    immediate,
    unknown,
};

const sixteen = .{
    .{ "transaction", Mode16.transaction },
    .{ "session", Mode16.session },
    .{ "statement", Mode16.statement },
    .{ "default", Mode16.default },
    .{ "local", Mode16.local },
    .{ "read", Mode16.read },
    .{ "write", Mode16.write },
    .{ "commit", Mode16.commit },
    .{ "rollback", Mode16.rollback },
    .{ "serializable", Mode16.serializable },
    .{ "repeatable", Mode16.repeatable },
    .{ "readcommitted", Mode16.readcommitted },
    .{ "snapshot", Mode16.snapshot },
    .{ "readonly", Mode16.readonly },
    .{ "deferrable", Mode16.deferrable },
    .{ "immediate", Mode16.immediate },
};

const sixteen_names = .{
    "transaction", "session",      "statement",  "default",
    "local",       "read",         "write",      "commit",
    "rollback",    "serializable", "repeatable", "readcommitted",
    "snapshot",    "readonly",     "deferrable", "immediate",
};

fn eqlSixteen(str: []const u8) u8 {
    inline for (sixteen) |kv| {
        if (mem.eql(u8, str, kv[0])) return @intFromEnum(kv[1]);
    }
    return @intFromEnum(Mode16.unknown);
}

const static_sixteen = std.StaticStringMap(Mode16).initComptime(sixteen);

fn staticMapSixteen(str: []const u8) u8 {
    return @intFromEnum(static_sixteen.get(str) orelse Mode16.unknown);
}

const openSixteen = enums.Open(sixteen_names);

fn matchSixteen(str: []const u8) u8 {
    return @intFromEnum(openSixteen.match(str));
}

fn toEnumSixteen(str: []const u8) u8 {
    return @intFromEnum(enums.stringToEnum(Mode16, str) orelse Mode16.unknown);
}

pub fn benchmarkEqlSixteen(b: *testingx.B) !void {
    try run(b, sixteen, eqlSixteen);
}

pub fn benchmarkStaticMapSixteen(b: *testingx.B) !void {
    try run(b, sixteen, staticMapSixteen);
}

pub fn benchmarkOpenSixteen(b: *testingx.B) !void {
    try run(b, sixteen, matchSixteen);
}

pub fn benchmarkToEnumSixteen(b: *testingx.B) !void {
    try run(b, sixteen, toEnumSixteen);
}
