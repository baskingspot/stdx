//! Fixed-capacity Count-Min Sketch (Cormode & Muthukrishnan, 2005):
//! approximate frequency counting in a flat `[depth][width]Counter` grid with
//! no allocator, no initialization failure, and saturating arithmetic so
//! counters never wrap around.
//!
//! `estimate` never undercounts a key whose true frequency fits in `Counter`:
//! with probability at least `1 - delta`, the estimate exceeds the true count
//! by at most `epsilon * total_count`. Both standard updates (`add`) and
//! conservative updates (`addConservative`, Estan & Varghese 2002) are
//! supported; conservative updates raise only the minimum counter(s) for a
//! key, which sharply reduces overestimation on skewed streams while keeping
//! the upper-bound invariant intact across non-negative merges. `halve` shifts
//! every counter right by one bit for sliding-window decay and TinyLFU cache
//! admission.
//!
//! `Sketch` is the hash-level primitive driven directly by uniform 64-bit
//! hashes. `Custom`, `Auto`, and `String` layer key hashing on top using the
//! `std.hash_map` split and delegate every operation to `Sketch`.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const Wyhash = std.hash.Wyhash;
const AutoContext = std.hash_map.AutoContext;
const StringContext = std.hash_map.StringContext;

/// Error-bound sizing parameters for `Config.fromError`.
// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const ErrorBounds = struct {
    /// Additive error bound as a fraction of total added weight: `0 < epsilon < 1`.
    /// Sets `width = ceilPowerOfTwo(ceil(e / epsilon))`.
    epsilon: f64,
    /// Failure probability bound: `0 < delta < 1`.
    /// Sets `depth = ceil(ln(1 / delta))`.
    delta: f64,
    /// Unsigned integer counter type (`u8`, `u16`, `u32`, `u64`, etc.).
    Counter: type = u32,
};

/// Comptime sizing and counter configuration for a Count-Min Sketch.
// ast-grep-ignore: public-struct-field-default -- comptime config: call sites override one knob
pub const Config = struct {
    /// Unsigned integer type stored in each cell (up to 64 bits).
    Counter: type = u32,
    /// Number of independent hash rows (`>= 1`).
    depth: u32 = 4,
    /// Number of counters per row; must be a power of two (`>= 1`).
    width: u32 = 1024,

    /// Derive `depth` and power-of-two `width` from the textbook error bounds
    /// `(epsilon, delta)`. Rounding `width` up to a power of two improves the
    /// delivered `Sketch.epsilon` relative to the requested bound.
    pub fn fromError(comptime bounds: ErrorBounds) Config {
        comptime {
            if (!(bounds.epsilon > 0.0 and bounds.epsilon < 1.0)) {
                @compileError("epsilon must be in the open interval (0, 1)");
            }
            if (!(bounds.delta > 0.0 and bounds.delta < 1.0)) {
                @compileError("delta must be in the open interval (0, 1)");
            }
            const min_width: u32 = @intFromFloat(@ceil(math.e / bounds.epsilon));
            const raw_depth: u32 = @intFromFloat(@ceil(-@log(bounds.delta)));
            return .{
                .Counter = bounds.Counter,
                .depth = @max(1, raw_depth),
                .width = math.ceilPowerOfTwoAssert(u32, @max(1, min_width)),
            };
        }
    }
};

/// SplitMix64 mixing step used only when `depth * log2(width) > 64` exhausts
/// the initial 64-bit hash.
fn mix64(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// A Count-Min Sketch that hashes keys with `std.hash_map.AutoContext`.
/// Slices — including `[]const u8` — are rejected by `std.hash.autoHash`;
/// string keys use `String`.
pub fn Auto(comptime T: type, comptime config: Config) type {
    return Custom(T, AutoContext(T), config);
}

/// A Count-Min Sketch for string keys (`[]const u8`), using
/// `std.hash_map.StringContext`. Key memory is managed by the caller.
pub fn String(comptime config: Config) type {
    return Custom([]const u8, StringContext, config);
}

/// A Count-Min Sketch over keys of type `T`, hashing through `Context`
/// (which must provide `hash(Context, T) u64`) and delegating all counter
/// operations to `Sketch(config)`.
pub fn Custom(comptime T: type, comptime Context: type, comptime config: Config) type {
    const Raw = Sketch(config);

    return struct {
        const Self = @This();

        /// Unsigned integer type stored in each cell.
        pub const Counter = Raw.Counter;

        /// Number of hash rows.
        pub const depth: u32 = Raw.depth;

        /// Number of counters per row (power of two).
        pub const width: u32 = Raw.width;

        /// Delivered additive error factor `e / width`.
        pub const epsilon: f64 = Raw.epsilon;

        /// Delivered failure probability bound `exp(-depth)`.
        pub const delta: f64 = Raw.delta;

        /// Underlying hash-level sketch.
        sketch: Raw,

        /// An empty sketch with every counter at zero.
        pub const empty: Self = .{ .sketch = .empty };

        /// Add `amount` to `key` across all `depth` rows (saturating).
        pub fn add(self: *Self, key: T, amount: Counter) void {
            self.sketch.addHash(Context.hash(.{}, key), amount);
        }

        /// Conservatively add `amount` to `key`: raise each row's counter only
        /// up to `estimate(key) +| amount`, reducing overestimation on skewed
        /// streams.
        pub fn addConservative(self: *Self, key: T, amount: Counter) void {
            self.sketch.addHashConservative(Context.hash(.{}, key), amount);
        }

        /// Estimate the frequency of `key`. Never undercounts unless a counter
        /// saturated or `halve` decayed past counts.
        pub fn estimate(self: *const Self, key: T) Counter {
            return self.sketch.estimateHash(Context.hash(.{}, key));
        }

        /// Total added weight since initialization or `clear` (saturating).
        pub fn count(self: *const Self) u64 {
            return self.sketch.count();
        }

        /// Add `other`'s counters into `self` cell-by-cell (saturating).
        pub fn merge(self: *Self, other: *const Self) void {
            self.sketch.merge(&other.sketch);
        }

        /// Right-shift every counter and the total count by one bit for
        /// exponential aging / TinyLFU decay.
        pub fn halve(self: *Self) void {
            self.sketch.halve();
        }

        /// Reset every counter and the total count to zero.
        pub fn clear(self: *Self) void {
            self.sketch.clear();
        }
    };
}

/// The hash-level Count-Min Sketch primitive: a flat `[depth][width]Counter`
/// matrix driven directly by uniform 64-bit hashes.
///
/// Row column indices are sliced from disjoint `log2(width)`-bit fields of the
/// 64-bit hash so rows remain independent even at small widths; if
/// `depth * log2(width) > 64`, a SplitMix64 refill supplies fresh bits.
pub fn Sketch(comptime config: Config) type {
    comptime {
        const info = @typeInfo(config.Counter);
        if (info != .int or info.int.signedness != .unsigned or
            info.int.bits == 0 or info.int.bits > 64)
        {
            @compileError("Counter must be an unsigned integer type with 1..64 bits");
        }
        if (config.depth == 0) {
            @compileError("depth must be at least 1");
        }
        if (config.width == 0 or !math.isPowerOfTwo(config.width)) {
            @compileError("width must be a power of two >= 1");
        }
    }

    return struct {
        const Self = @This();

        /// Unsigned integer type stored in each cell.
        pub const Counter = config.Counter;

        /// Number of hash rows.
        pub const depth: u32 = config.depth;

        /// Number of counters per row (power of two).
        pub const width: u32 = config.width;

        /// Delivered additive error factor `e / width`.
        pub const epsilon: f64 = math.e / @as(f64, @floatFromInt(width));

        /// Delivered failure probability bound `exp(-depth)`.
        pub const delta: f64 = @exp(-@as(f64, @floatFromInt(depth)));

        const Index = math.IntFittingRange(0, width - 1);
        const width_bits: u6 = @intCast(@ctz(width));
        const width_mask: u64 = width - 1;

        rows: [depth][width]Counter,
        total: u64,

        /// An empty sketch with every counter at zero.
        pub const empty: Self = .{
            .rows = @splat(@splat(0)),
            .total = 0,
        };

        /// Derive one column index per row from a uniform 64-bit hash.
        fn columns(hash: u64) [depth]Index {
            var cols: [depth]Index = undefined;
            if (width == 1) {
                @memset(&cols, 0);
                return cols;
            }
            var state = hash;
            var word = state;
            comptime var bits_left: u7 = 64;
            inline for (0..depth) |row| {
                if (bits_left < width_bits) {
                    state = mix64(state);
                    word = state;
                    bits_left = 64;
                }
                cols[row] = @intCast(word & width_mask);
                word >>= width_bits;
                bits_left -= width_bits;
            }
            return cols;
        }

        /// Add `amount` to the counters selected by `hash` (saturating).
        pub fn addHash(self: *Self, hash: u64, amount: Counter) void {
            const cols = columns(hash);
            inline for (0..depth) |row| {
                self.rows[row][cols[row]] +|= amount;
            }
            self.total +|= amount;
        }

        /// Conservatively add `amount` to the counters selected by `hash`:
        /// raise each counter only to `min_counter +| amount`.
        pub fn addHashConservative(self: *Self, hash: u64, amount: Counter) void {
            const cols = columns(hash);
            var min_val: Counter = math.maxInt(Counter);
            inline for (0..depth) |row| {
                const v = self.rows[row][cols[row]];
                if (v < min_val) min_val = v;
            }
            const target = min_val +| amount;
            inline for (0..depth) |row| {
                const cell = &self.rows[row][cols[row]];
                if (cell.* < target) cell.* = target;
            }
            self.total +|= amount;
        }

        /// Estimate the frequency associated with `hash` as the minimum across
        /// all `depth` rows.
        pub fn estimateHash(self: *const Self, hash: u64) Counter {
            const cols = columns(hash);
            var min_val: Counter = math.maxInt(Counter);
            inline for (0..depth) |row| {
                const v = self.rows[row][cols[row]];
                if (v < min_val) min_val = v;
            }
            return min_val;
        }

        /// Total added weight since initialization or `clear` (saturating).
        pub fn count(self: *const Self) u64 {
            return self.total;
        }

        /// Fold `other` into `self` by saturating elementwise addition.
        pub fn merge(self: *Self, other: *const Self) void {
            for (&self.rows, other.rows) |*dst_row, src_row| {
                for (dst_row, src_row) |*dst, src| {
                    dst.* +|= src;
                }
            }
            self.total +|= other.total;
        }

        /// Halve every counter and the total count (integer shift right by 1).
        pub fn halve(self: *Self) void {
            for (&self.rows) |*row| {
                for (row) |*cell| {
                    cell.* >>= 1;
                }
            }
            self.total >>= 1;
        }

        /// Reset every counter and the total count to zero.
        pub fn clear(self: *Self) void {
            self.* = .empty;
        }
    };
}

test "fromError sizing" {
    const cfg: Config = .fromError(.{ .epsilon = 0.01, .delta = 0.01 });
    // ceil(e / 0.01) = 272 -> next power of two = 512.
    // ceil(-ln(0.01)) = ceil(4.605) = 5.
    try testing.expectEqual(@as(u32, 512), cfg.width);
    try testing.expectEqual(@as(u32, 5), cfg.depth);

    const S = Sketch(cfg);
    try testing.expect(S.epsilon <= 0.01);
    try testing.expect(S.delta <= 0.01);
}

test Sketch {
    const S = Sketch(.fromError(.{ .epsilon = 0.005, .delta = 0.01 }));
    var sketch: S = .empty;
    try testing.expectEqual(@as(u64, 0), sketch.count());

    // Skewed stream: key 0..9 are heavy hitters, 10..509 are light noise.
    var true_counts: [510]u32 = @splat(0);
    for (0..10) |k| {
        const w: u32 = @intCast((10 - k) * 100);
        const h = Wyhash.hash(0, mem.asBytes(&k));
        sketch.addHash(h, w);
        true_counts[k] = w;
    }
    for (10..510) |k| {
        const h = Wyhash.hash(0, mem.asBytes(&k));
        sketch.addHash(h, 1);
        true_counts[k] = 1;
    }

    const expected_total: u64 = 5500 + 500;
    try testing.expectEqual(expected_total, sketch.count());

    // Invariant: estimate never undercounts, and stays tight on heavy hitters.
    const max_err: u32 = @intFromFloat(@ceil(S.epsilon * @as(f64, @floatFromInt(expected_total))));
    var within_bound: usize = 0;
    for (0..510) |k| {
        const h = Wyhash.hash(0, mem.asBytes(&k));
        const est = sketch.estimateHash(h);
        try testing.expect(est >= true_counts[k]);
        if (est - true_counts[k] <= max_err) within_bound += 1;
    }
    // With delta < 0.01, well over 95% of keys must satisfy the epsilon bound.
    try testing.expect(within_bound >= 490);
}

test "conservative update beats or matches standard" {
    const cfg: Config = .{ .depth = 4, .width = 256 };
    var standard: Sketch(cfg) = .empty;
    var conservative: Sketch(cfg) = .empty;

    for (0..1000) |i| {
        const key: u64 = i % 200;
        const h = Wyhash.hash(42, mem.asBytes(&key));
        standard.addHash(h, 1);
        conservative.addHashConservative(h, 1);
    }

    var std_err_sum: u64 = 0;
    var cons_err_sum: u64 = 0;
    for (0..200) |k| {
        const key: u64 = k;
        const h = Wyhash.hash(42, mem.asBytes(&key));
        const s_est = standard.estimateHash(h);
        const c_est = conservative.estimateHash(h);
        try testing.expect(s_est >= 5);
        try testing.expect(c_est >= 5);
        std_err_sum += s_est - 5;
        cons_err_sum += c_est - 5;
    }
    try testing.expect(cons_err_sum <= std_err_sum);
}

test "saturation, merge, halve, and clear" {
    const S = Sketch(.{ .Counter = u8, .depth = 3, .width = 64 });
    var a: S = .empty;
    var b: S = .empty;

    const h1 = Wyhash.hash(0, "hot");
    const h2 = Wyhash.hash(0, "warm");

    a.addHash(h1, 200);
    a.addHash(h1, 200);
    // Counter saturates at 255 rather than wrapping around.
    try testing.expectEqual(@as(u8, 255), a.estimateHash(h1));

    b.addHash(h2, 40);
    a.merge(&b);
    try testing.expectEqual(@as(u8, 255), a.estimateHash(h1));
    try testing.expect(a.estimateHash(h2) >= 40);
    try testing.expectEqual(@as(u64, 440), a.count());

    a.halve();
    try testing.expectEqual(@as(u8, 127), a.estimateHash(h1));
    try testing.expectEqual(@as(u64, 220), a.count());

    a.clear();
    try testing.expectEqual(@as(u8, 0), a.estimateHash(h1));
    try testing.expectEqual(@as(u64, 0), a.count());
}

test "multi-word hash refill when depth * log2(width) > 64" {
    // 6 * 12 = 72 bits > 64 -> triggers SplitMix64 refill cleanly.
    const S = Sketch(.{ .depth = 6, .width = 4096 });
    var sketch: S = .empty;

    for (0..500) |i| {
        const h = Wyhash.hash(9, mem.asBytes(&i));
        sketch.addHash(h, 3);
    }
    for (0..500) |i| {
        const h = Wyhash.hash(9, mem.asBytes(&i));
        try testing.expect(sketch.estimateHash(h) >= 3);
    }
}

test "Auto and String delegate identically to Sketch" {
    const cfg: Config = .{ .depth = 4, .width = 128 };
    var typed: Auto(u64, cfg) = .empty;
    var raw: Sketch(cfg) = .empty;

    for (0..100) |i| {
        const k: u64 = i;
        typed.add(k, 2);
        raw.addHash(AutoContext(u64).hash(.{}, k), 2);
    }
    try testing.expectEqual(raw.count(), typed.count());
    try testing.expectEqual(raw.rows, typed.sketch.rows);

    var strs: String(cfg) = .empty;
    strs.add("GET /health", 10);
    strs.addConservative("GET /metrics", 4);
    try testing.expect(strs.estimate("GET /health") >= 10);
    try testing.expect(strs.estimate("GET /metrics") >= 4);
}
