//! Approximate distinct counting with UltraLogLog (Otmar Ertl, PVLDB 2024):
//! a flat `[1 << precision]u8` register array with no allocator, no
//! initialization failure, and lossless merging across sketches of the same
//! precision (or downsizing to a lower precision).
//!
//! Each byte stores the maximum run length seen in its substream in the high
//! six bits plus two history bits indicating whether the two immediately
//! preceding run lengths also occurred. Compared to HyperLogLog at the same
//! accuracy, UltraLogLog uses about 28% less memory while keeping byte-aligned
//! random access. Cardinality estimation uses the paper's Optimal FGRA
//! estimator, including its small-range and large-range corrections, so one
//! formula covers counts from zero up to 2^64.
//!
//! `Sketch` is the hash-level primitive: it takes pre-hashed 64-bit values
//! directly. `Custom`, `Auto`, and `String` layer key hashing on top using the
//! `std.hash_map` split, delegating every register operation to `Sketch`.
//!
//! Register encoding (the `+4p - 8` byte shift so saturation always lands at
//! 255) and the Optimal FGRA estimator follow Dynatrace's `hash4j` reference
//! implementation (Apache-2.0; see `THIRD_PARTY.md`).

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const Wyhash = std.hash.Wyhash;
const AutoContext = std.hash_map.AutoContext;
const StringContext = std.hash_map.StringContext;

/// Minimum supported precision (`2^3 = 8` registers).
pub const min_precision: u5 = 3;

/// Maximum supported precision (`2^26 = 67,108,864` registers).
pub const max_precision: u5 = 26;

/// Errors returned when validating a serialized register array.
pub const Error = error{
    /// A register byte falls outside the states reachable at this precision.
    InvalidRegister,
};

/// Optimal FGRA parameters for UltraLogLog (`b = 2, d = 2`), Ertl 2024 §3.3.
const fgra = struct {
    const eta_0: f64 = 4.663135422063788;
    const eta_1: f64 = 2.1378502137958524;
    const eta_2: f64 = 2.781144650979996;
    const eta_3: f64 = 0.9824082545153715;
    const tau: f64 = 0.8194911375910897;
    const variance_factor: f64 = 0.6118931496978437;

    const pow_2_tau: f64 = @exp(tau * @log(2.0));
    const pow_2_minus_tau: f64 = @exp(-tau * @log(2.0));
    const pow_4_minus_tau: f64 = pow_2_minus_tau * pow_2_minus_tau;
    const minus_inv_tau: f64 = -1.0 / tau;
    const eta_x: f64 = eta_0 - eta_1 - eta_2 + eta_3;
    const eta23x: f64 = (eta_2 - eta_3) / eta_x;
    const eta13x: f64 = (eta_1 - eta_3) / eta_x;
    const eta3012xx: f64 = (eta_3 * eta_0 - eta_1 * eta_2) / (eta_x * eta_x);
    const pow_4_minus_tau_eta_23: f64 = pow_4_minus_tau * (eta_2 - eta_3);
    const pow_4_minus_tau_eta_01: f64 = pow_4_minus_tau * (eta_0 - eta_1);
    const pow_4_minus_tau_eta_3: f64 = pow_4_minus_tau * eta_3;
    const pow_4_minus_tau_eta_1: f64 = pow_4_minus_tau * eta_1;
    const pow_2_minus_tau_eta_x: f64 = pow_2_minus_tau * eta_x;
    const phi_1: f64 = eta_0 / (pow_2_tau * (2.0 * pow_2_tau - 1.0));
    const p_initial: f64 = eta_x * (pow_4_minus_tau / (2.0 - pow_2_minus_tau));
    const pow_2_minus_tau_eta_02: f64 = pow_2_minus_tau * (eta_0 - eta_2);
    const pow_2_minus_tau_eta_13: f64 = pow_2_minus_tau * (eta_1 - eta_3);
    const pow_2_minus_tau_eta_2: f64 = pow_2_minus_tau * eta_2;
    const pow_2_minus_tau_eta_3: f64 = pow_2_minus_tau * eta_3;

    fn smallRangeEstimate(c0: u64, c4: u64, c8: u64, c10: u64, m: u64) f64 {
        const alpha: f64 = @floatFromInt(m + 3 * (c0 + c4 + c8 + c10));
        const beta: f64 = @floatFromInt(m - c0 - c4);
        const gamma: f64 = @floatFromInt(4 * c0 + 2 * c4 + 3 * c8 + c10);
        const quad_root_z = (@sqrt(beta * beta + 4.0 * alpha * gamma) - beta) / (2.0 * alpha);
        const root_z = quad_root_z * quad_root_z;
        return root_z * root_z;
    }

    fn largeRangeEstimate(c4w0: u64, c4w1: u64, c4w2: u64, c4w3: u64, m: u64) f64 {
        const alpha: f64 = @floatFromInt(m + 3 * (c4w0 + c4w1 + c4w2 + c4w3));
        const beta: f64 = @floatFromInt(c4w0 + c4w1 + 2 * (c4w2 + c4w3));
        const gamma: f64 = @floatFromInt(m + 2 * c4w0 + c4w2 - c4w3);
        return @sqrt((@sqrt(beta * beta + 4.0 * alpha * gamma) - beta) / (2.0 * alpha));
    }

    fn psiPrime(z: f64, z_square: f64) f64 {
        return (z + eta23x) * (z_square + eta13x) + eta3012xx;
    }

    fn sigma(z: f64) f64 {
        if (z <= 0.0) return eta_3;
        if (z >= 1.0) return math.inf(f64);

        var pow_z = z;
        var next_pow_z = pow_z * pow_z;
        var s: f64 = 0.0;
        var pow_tau = eta_x;
        while (true) {
            const old_s = s;
            const next_next_pow_z = next_pow_z * next_pow_z;
            s += pow_tau * (pow_z - next_pow_z) * psiPrime(next_pow_z, next_next_pow_z);
            if (!(s > old_s)) return s / z;
            pow_z = next_pow_z;
            next_pow_z = next_next_pow_z;
            pow_tau *= pow_2_tau;
        }
    }

    fn phi(z: f64, z_square: f64) f64 {
        if (z <= 0.0) return 0.0;
        if (z >= 1.0) return phi_1;

        var prev_pow_z = z_square;
        var pow_z = z;
        var next_pow_z = @sqrt(pow_z);
        var p = p_initial / (1.0 + next_pow_z);
        var ps = psiPrime(pow_z, prev_pow_z);
        var s = next_pow_z * (ps + ps) * p;
        while (true) {
            prev_pow_z = pow_z;
            pow_z = next_pow_z;
            const old_s = s;
            next_pow_z = @sqrt(pow_z);
            const next_ps = psiPrime(pow_z, prev_pow_z);
            p *= pow_2_minus_tau / (1.0 + next_pow_z);
            s += next_pow_z * ((next_ps + next_ps) - (pow_z + next_pow_z) * ps) * p;
            if (!(s > old_s)) return s;
            ps = next_ps;
        }
    }

    fn largeRangeContribution(
        c4w0: u64,
        c4w1: u64,
        c4w2: u64,
        c4w3: u64,
        m: u64,
        comptime w: comptime_int,
    ) f64 {
        const z = largeRangeEstimate(c4w0, c4w1, c4w2, c4w3, m);
        const root_z = @sqrt(z);
        const f0: f64 = @floatFromInt(c4w0);
        const f1: f64 = @floatFromInt(c4w1);
        const f2: f64 = @floatFromInt(c4w2);
        const f3: f64 = @floatFromInt(c4w3);

        var s = phi(root_z, z) * (f0 + f1 + f2 + f3);
        s += z * (1.0 + root_z) * (f0 * eta_0 + f1 * eta_1 + f2 * eta_2 + f3 * eta_3);
        s += root_z * ((f0 + f1) * (z * pow_2_minus_tau_eta_02 + pow_2_minus_tau_eta_2) +
            (f2 + f3) * (z * pow_2_minus_tau_eta_13 + pow_2_minus_tau_eta_3));

        const scale: f64 = comptime @exp(-tau * @as(comptime_float, w) * @log(2.0));
        return s * scale / ((1.0 + root_z) * (1.0 + z));
    }
};

/// Unpack a shifted register byte into its 64-bit bitmask of observed update
/// values. Returns 0 for an empty register.
fn unpack(reg: u8) u64 {
    if (reg == 0) return 0;
    const top = reg >> 2;
    assert(top >= 2);
    const shift: u6 = @intCast(top - 2);
    return (@as(u64, 4) | (reg & 3)) << shift;
}

/// Pack a non-empty 64-bit bitmask of observed update values back into a
/// shifted register byte, keeping the highest set bit and the two bits below it.
fn pack(hash_prefix: u64) u8 {
    assert(hash_prefix >= 4);
    const lz: u6 = @intCast(@clz(hash_prefix));
    const top: u8 = (63 - @as(u8, lz)) << 2;
    const low: u8 = @intCast(((hash_prefix << lz) >> 61) & 3);
    return top | low;
}

/// An UltraLogLog sketch that hashes keys with `std.hash_map.AutoContext`.
/// Slices — including `[]const u8` — are rejected by `std.hash.autoHash`;
/// string keys use `String`.
pub fn Auto(comptime T: type, comptime p: comptime_int) type {
    return Custom(T, AutoContext(T), p);
}

/// An UltraLogLog sketch for string keys (`[]const u8`), using
/// `std.hash_map.StringContext`. Key memory is managed by the caller.
pub fn String(comptime p: comptime_int) type {
    return Custom([]const u8, StringContext, p);
}

/// An UltraLogLog sketch over keys of type `T`, hashing through `Context`
/// (which must provide `hash(Context, T) u64`) and delegating all register
/// work to `Sketch(p)`.
pub fn Custom(comptime T: type, comptime Context: type, comptime p: comptime_int) type {
    const Raw = Sketch(p);

    return struct {
        const Self = @This();

        /// Precision parameter `p`; the sketch holds `2^p` byte registers.
        pub const precision: u5 = Raw.precision;

        /// Number of byte registers (`1 << precision`).
        pub const register_count: usize = Raw.register_count;

        /// Asymptotic relative standard error (`sqrt(v / 2^p)`, about `0.782 / sqrt(2^p)`).
        pub const relative_standard_error: f64 = Raw.relative_standard_error;

        /// Underlying hash-level sketch.
        sketch: Raw,

        /// An empty sketch with all registers zeroed.
        pub const empty: Self = .{ .sketch = .empty };

        /// Hash `key` with `Context` and insert it into the sketch.
        pub fn add(self: *Self, key: T) void {
            self.sketch.addHash(Context.hash(.{}, key));
        }

        /// Insert a pre-hashed uniform 64-bit value directly.
        pub fn addHash(self: *Self, hash: u64) void {
            self.sketch.addHash(hash);
        }

        /// Estimate the number of distinct keys added to this sketch.
        pub fn estimate(self: *const Self) f64 {
            return self.sketch.estimate();
        }

        /// Fold `other` into `self`. The result matches inserting the union of
        /// both streams into one sketch.
        pub fn merge(self: *Self, other: *const Self) void {
            self.sketch.merge(&other.sketch);
        }

        /// Return an equivalent sketch at `target_precision <= precision`.
        pub fn downsize(
            self: *const Self,
            comptime target_precision: comptime_int,
        ) Custom(T, Context, target_precision) {
            return .{ .sketch = self.sketch.downsize(target_precision) };
        }

        /// Whether no keys have been added since initialization or `clear`.
        pub fn isEmpty(self: *const Self) bool {
            return self.sketch.isEmpty();
        }

        /// Reset all registers to zero.
        pub fn clear(self: *Self) void {
            self.sketch.clear();
        }

        /// Borrow the raw byte registers for serialization.
        pub fn asBytes(self: *const Self) *const [register_count]u8 {
            return self.sketch.asBytes();
        }

        /// Reconstruct a sketch from serialized register bytes, validating
        /// that every byte is reachable at `precision`.
        pub fn fromBytes(bytes: [register_count]u8) Error!Self {
            return .{ .sketch = try .fromBytes(bytes) };
        }
    };
}

/// The hash-level UltraLogLog primitive: a flat `[1 << p]u8` array driven
/// directly by uniform 64-bit hashes.
///
/// Typical precisions: `p = 10` (1 KiB, ~2.4% RSE), `p = 12` (4 KiB, ~1.2%
/// RSE), `p = 14` (16 KiB, ~0.61% RSE), `p = 16` (64 KiB, ~0.31% RSE).
pub fn Sketch(comptime p: comptime_int) type {
    comptime {
        if (p < min_precision or p > max_precision) {
            @compileError("precision must be in the range [3, 26]");
        }
    }

    return struct {
        const Self = @This();

        /// Precision parameter `p`; the sketch holds `2^p` byte registers.
        pub const precision: u5 = p;

        /// Number of byte registers (`1 << precision`).
        pub const register_count: usize = @as(usize, 1) << p;

        /// Asymptotic relative standard error (`sqrt(v / 2^p)`, about `0.782 / sqrt(2^p)`).
        pub const relative_standard_error: f64 = @sqrt(
            fgra.variance_factor / @as(comptime_float, register_count),
        );

        /// Remaining hash bits after consuming `p` bits for the register index.
        const q_bits: u6 = 64 - p;
        const w_max: comptime_int = 65 - p;
        const reg_offset: u8 = @as(u8, p) * 4 + 4;

        /// Precomputed FGRA scaling factor `lambda_p` (Ertl 2024 eq. 12).
        const estimation_factor: f64 = blk: {
            const m: comptime_float = @floatFromInt(register_count);
            const num = @exp((1.0 + 1.0 / fgra.tau) * @log(m));
            const den = 1.0 + 0.5 * (1.0 + fgra.tau) * fgra.variance_factor / m;
            break :blk num / den;
        };

        /// Precomputed 256-entry register contribution table `g(r)` for
        /// intermediate registers `[reg_offset, 252)`, with `0.0` at special
        /// small-range and saturated positions so the main sweep is branchless.
        const register_lut: [256]f64 = blk: {
            @setEvalBranchQuota(10_000);
            const etas = [4]f64{ fgra.eta_0, fgra.eta_1, fgra.eta_2, fgra.eta_3 };
            var table: [256]f64 = @splat(0.0);
            for (reg_offset..252) |r| {
                const idx = r - reg_offset;
                const u_paper: comptime_float = @floatFromInt((idx / 4) + 3);
                table[r] = @exp(-fgra.tau * u_paper * @log(2.0)) * etas[idx % 4];
            }
            break :blk table;
        };

        registers: [register_count]u8,

        /// An empty sketch with all registers zeroed.
        pub const empty: Self = .{ .registers = @splat(0) };

        /// Insert a uniform 64-bit hash into the sketch. Requires a
        /// high-quality hash (such as `std.hash.Wyhash` or `stdx.hash.RapidHash`)
        /// whose bits are uniformly distributed.
        pub fn addHash(self: *Self, hash: u64) void {
            const idx: usize = @intCast(hash >> q_bits);
            // Shift the low (64 - p) bits to the top and fill the bottom p bits
            // with 1s so `@clz` stops at `64 - p`.
            const nlz: u6 = @intCast(@clz(~(~hash << @as(u6, p))));
            const bit_pos: u6 = nlz + @as(u6, p - 1);
            const prefix = unpack(self.registers[idx]) | (@as(u64, 1) << bit_pos);
            self.registers[idx] = pack(prefix);
        }

        /// Estimate the number of distinct hashes added using the Optimal FGRA
        /// estimator (Ertl 2024 Algorithm 6). Returns `0.0` for an empty sketch
        /// and `+inf` if every register is saturated at `255`.
        pub fn estimate(self: *const Self) f64 {
            const bounds = self.minMaxRegisters();
            if (bounds.max == 0) return 0.0;
            if (bounds.min == 255) return math.inf(f64);

            // Branchless 8-way unrolled LUT sweep loaded 8 bytes at a time to
            // break FP accumulator dependencies and cut byte-load pressure.
            var s0: f64 = 0.0;
            var s1: f64 = 0.0;
            var s2: f64 = 0.0;
            var s3: f64 = 0.0;
            var s4: f64 = 0.0;
            var s5: f64 = 0.0;
            var s6: f64 = 0.0;
            var s7: f64 = 0.0;

            var i: usize = 0;
            while (i < register_count) : (i += 8) {
                const w = mem.readInt(u64, self.registers[i..][0..8], .little);
                s0 += register_lut[@as(u8, @truncate(w))];
                s1 += register_lut[@as(u8, @truncate(w >> 8))];
                s2 += register_lut[@as(u8, @truncate(w >> 16))];
                s3 += register_lut[@as(u8, @truncate(w >> 24))];
                s4 += register_lut[@as(u8, @truncate(w >> 32))];
                s5 += register_lut[@as(u8, @truncate(w >> 40))];
                s6 += register_lut[@as(u8, @truncate(w >> 48))];
                s7 += register_lut[@as(u8, @truncate(w >> 56))];
            }

            var sum = ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7));

            if (bounds.min < reg_offset) {
                const counts = self.countFour(.{
                    0,
                    reg_offset - 8,
                    reg_offset - 4,
                    reg_offset - 2,
                });
                const c0 = counts[0];
                const c4 = counts[1];
                const c8 = counts[2];
                const c10 = counts[3];
                if (c0 > 0 or c4 > 0 or c8 > 0 or c10 > 0) {
                    const z = fgra.smallRangeEstimate(c0, c4, c8, c10, register_count);
                    if (c0 > 0) sum += @as(f64, @floatFromInt(c0)) * fgra.sigma(z);
                    if (c4 > 0) {
                        const fc4: f64 = @floatFromInt(c4);
                        sum += fc4 * fgra.pow_2_minus_tau_eta_x * fgra.psiPrime(z, z * z);
                    }
                    if (c8 > 0) {
                        const fc8: f64 = @floatFromInt(c8);
                        sum += fc8 *
                            (z * fgra.pow_4_minus_tau_eta_01 + fgra.pow_4_minus_tau_eta_1);
                    }
                    if (c10 > 0) {
                        const fc10: f64 = @floatFromInt(c10);
                        sum += fc10 *
                            (z * fgra.pow_4_minus_tau_eta_23 + fgra.pow_4_minus_tau_eta_3);
                    }
                }
            }

            if (bounds.max >= 252) {
                const counts = self.countFour(.{ 252, 253, 254, 255 });
                const c4w0 = counts[0];
                const c4w1 = counts[1];
                const c4w2 = counts[2];
                const c4w3 = counts[3];
                if (c4w0 > 0 or c4w1 > 0 or c4w2 > 0 or c4w3 > 0) {
                    sum += fgra.largeRangeContribution(
                        c4w0,
                        c4w1,
                        c4w2,
                        c4w3,
                        register_count,
                        w_max,
                    );
                }
            }

            if (sum == 0.0) return math.inf(f64);
            return estimation_factor * math.pow(f64, sum, fgra.minus_inv_tau);
        }

        fn minMaxRegisters(self: *const Self) struct { min: u8, max: u8 } {
            const lanes = if (register_count >= 16) 16 else 8;
            const Vec = @Vector(lanes, u8);
            if (comptime register_count >= 32) {
                var mn0: Vec = @splat(255);
                var mx0: Vec = @splat(0);
                var mn1: Vec = @splat(255);
                var mx1: Vec = @splat(0);
                var i: usize = 0;
                while (i < register_count) : (i += 32) {
                    const v0: Vec = self.registers[i..][0..16].*;
                    const v1: Vec = self.registers[i + 16 ..][0..16].*;
                    mn0 = @min(mn0, v0);
                    mx0 = @max(mx0, v0);
                    mn1 = @min(mn1, v1);
                    mx1 = @max(mx1, v1);
                }
                return .{
                    .min = @reduce(.Min, @min(mn0, mn1)),
                    .max = @reduce(.Max, @max(mx0, mx1)),
                };
            }
            var mn: Vec = @splat(255);
            var mx: Vec = @splat(0);
            var i: usize = 0;
            while (i < register_count) : (i += lanes) {
                const v: Vec = self.registers[i..][0..lanes].*;
                mn = @min(mn, v);
                mx = @max(mx, v);
            }
            return .{ .min = @reduce(.Min, mn), .max = @reduce(.Max, mx) };
        }

        /// SIMD-count occurrences of four target register bytes in one pass.
        /// Accumulates in `u8` lane counters over 255-vector chunks so lane
        /// counters never overflow and horizontal reductions run rarely.
        fn countFour(self: *const Self, comptime targets: [4]u8) [4]u64 {
            const lanes = if (register_count >= 16) 16 else 8;
            const Vec = @Vector(lanes, u8);
            const ones: Vec = @splat(1);
            const zeros: Vec = @splat(0);
            const t0: Vec = @splat(targets[0]);
            const t1: Vec = @splat(targets[1]);
            const t2: Vec = @splat(targets[2]);
            const t3: Vec = @splat(targets[3]);

            var totals: [4]u64 = @splat(0);
            var i: usize = 0;
            while (i < register_count) {
                var a0: Vec = zeros;
                var a1: Vec = zeros;
                var a2: Vec = zeros;
                var a3: Vec = zeros;
                const chunk_end = @min(i + lanes * 255, register_count);
                while (i < chunk_end) : (i += lanes) {
                    const v: Vec = self.registers[i..][0..lanes].*;
                    a0 +%= @select(u8, v == t0, ones, zeros);
                    a1 +%= @select(u8, v == t1, ones, zeros);
                    a2 +%= @select(u8, v == t2, ones, zeros);
                    a3 +%= @select(u8, v == t3, ones, zeros);
                }
                totals[0] += @reduce(.Add, @as(@Vector(lanes, u32), a0));
                totals[1] += @reduce(.Add, @as(@Vector(lanes, u32), a1));
                totals[2] += @reduce(.Add, @as(@Vector(lanes, u32), a2));
                totals[3] += @reduce(.Add, @as(@Vector(lanes, u32), a3));
            }
            return totals;
        }

        /// Branchless SIMD register merge: for `hi = max(a, b)` and
        /// `lo = min(a, b)`, `lo` can only contribute to `hi`'s two history
        /// bits when `diff = (hi >> 2) - (lo >> 2) <= 2` and `lo != 0`.
        /// Shifting `((lo & 3) | 4)` right by `min(diff, 3)` covers all four
        /// cases (`diff = 0, 1, 2, >= 3`) in one vector shift.
        fn mergeVec(
            comptime lanes: comptime_int,
            a: @Vector(lanes, u8),
            b: @Vector(lanes, u8),
        ) @Vector(lanes, u8) {
            const Vec = @Vector(lanes, u8);
            const Shift = @Vector(lanes, u3);
            const zeros: Vec = @splat(0);
            const twos: Shift = @splat(2);
            const threes: Vec = @splat(3);
            const fours: Vec = @splat(4);

            const hi = @max(a, b);
            const lo = @min(a, b);
            const diff = @min((hi >> twos) -% (lo >> twos), threes);
            const bits = @select(u8, lo != zeros, (lo & threes) | fours, zeros);
            const shift: Shift = @intCast(diff);
            return hi | ((bits >> shift) & threes);
        }

        /// Fold `other` into `self`. Idempotent, commutative, and associative.
        pub fn merge(self: *Self, other: *const Self) void {
            const lanes = if (register_count >= 16) 16 else 8;
            if (comptime register_count >= 32) {
                var i: usize = 0;
                while (i < register_count) : (i += 32) {
                    const a0: @Vector(16, u8) = self.registers[i..][0..16].*;
                    const b0: @Vector(16, u8) = other.registers[i..][0..16].*;
                    const a1: @Vector(16, u8) = self.registers[i + 16 ..][0..16].*;
                    const b1: @Vector(16, u8) = other.registers[i + 16 ..][0..16].*;
                    self.registers[i..][0..16].* = mergeVec(16, a0, b0);
                    self.registers[i + 16 ..][0..16].* = mergeVec(16, a1, b1);
                }
                return;
            }
            var i: usize = 0;
            while (i < register_count) : (i += lanes) {
                const a: @Vector(lanes, u8) = self.registers[i..][0..lanes].*;
                const b: @Vector(lanes, u8) = other.registers[i..][0..lanes].*;
                self.registers[i..][0..lanes].* = mergeVec(lanes, a, b);
            }
        }

        /// Produce an equivalent sketch at a smaller (or equal) precision
        /// `target_precision`. The result is bit-for-bit identical to inserting
        /// the original hashes directly at `target_precision`.
        pub fn downsize(
            self: *const Self,
            comptime target_precision: comptime_int,
        ) Sketch(target_precision) {
            comptime {
                if (target_precision < min_precision or target_precision > p) {
                    @compileError("target_precision must be in [min_precision, precision]");
                }
            }
            if (target_precision == p) return self.*;

            const Target = Sketch(target_precision);
            var out: Target = .empty;
            const stride: usize = @as(usize, 1) << (p - target_precision);

            var j: usize = 0;
            for (&out.registers) |*dst| {
                var prefix = unpack(self.registers[j]);
                j += 1;
                for (1..stride) |k| {
                    if (self.registers[j] != 0) {
                        const bit_pos: u6 = @intCast(@clz(@as(u64, k)) + @as(u32, p) - 65);
                        prefix |= @as(u64, 1) << bit_pos;
                    }
                    j += 1;
                }
                if (prefix != 0) {
                    dst.* = pack(prefix);
                }
            }
            return out;
        }

        /// Whether all registers are zero.
        pub fn isEmpty(self: *const Self) bool {
            for (self.registers) |r| {
                if (r != 0) return false;
            }
            return true;
        }

        /// Reset all registers to zero.
        pub fn clear(self: *Self) void {
            @memset(&self.registers, 0);
        }

        /// Borrow the raw register bytes for serialization.
        pub fn asBytes(self: *const Self) *const [register_count]u8 {
            return &self.registers;
        }

        /// Reconstruct a sketch from serialized register bytes. Returns
        /// `error.InvalidRegister` if any byte is not a reachable state at
        /// `precision`.
        pub fn fromBytes(bytes: [register_count]u8) Error!Self {
            for (bytes) |r| {
                if (!isValidRegister(r)) return error.InvalidRegister;
            }
            return .{ .registers = bytes };
        }

        fn isValidRegister(r: u8) bool {
            return r == 0 or
                r == reg_offset - 8 or
                r == reg_offset - 4 or
                r == reg_offset - 2 or
                r >= reg_offset;
        }
    };
}

test "pack and unpack roundtrip" {
    try testing.expectEqual(@as(u64, 0), unpack(0));

    // Every shifted register with top >= 2 (reg >= 8) roundtrips cleanly.
    var reg: u16 = 8;
    while (reg <= 255) : (reg += 1) {
        const r: u8 = @intCast(reg);
        const unpacked = unpack(r);
        try testing.expect(unpacked >= 4);
        try testing.expectEqual(r, pack(unpacked));
    }
}

test "SIMD merge matches pack/unpack for every valid register pair" {
    const S = Sketch(3);
    // Test every pair (a, b) with a, b in {0} U [8, 255] in batches of 8 lanes.
    var valid: [249]u8 = undefined;
    valid[0] = 0;
    for (8..256, 1..) |v, idx| valid[idx] = @intCast(v);

    for (valid) |a| {
        var idx: usize = 0;
        while (idx < valid.len) {
            const va: @Vector(8, u8) = @splat(a);
            var b_arr: [8]u8 = @splat(0);
            const batch = @min(8, valid.len - idx);
            for (0..batch) |lane| {
                b_arr[lane] = valid[idx + lane];
            }
            const got: [8]u8 = S.mergeVec(8, va, b_arr);
            for (0..batch) |lane| {
                const b = b_arr[lane];
                const prefix = unpack(a) | unpack(b);
                const expected: u8 = if (prefix == 0) 0 else pack(prefix);
                try testing.expectEqual(expected, got[lane]);
            }
            idx += batch;
        }
    }
}

test "reference FGRA constants match hash4j" {
    const S3 = Sketch(3);
    const S12 = Sketch(12);
    const S14 = Sketch(14);

    // Reference values from Dynatrace hash4j UltraLogLog.OptimalFGRAEstimator.
    try testing.expectApproxEqRel(94.59941722950778, S3.estimation_factor, 1e-12);
    try testing.expectApproxEqRel(1.0479810199493326e8, S12.estimation_factor, 1e-12);
    try testing.expectApproxEqRel(2.275794725435168e9, S14.estimation_factor, 1e-12);

    try testing.expectApproxEqRel(0.8484061093359406, S3.register_lut[S3.reg_offset], 1e-12);
    try testing.expectApproxEqRel(0.38895829052007685, S3.register_lut[S3.reg_offset + 1], 1e-12);
    try testing.expectApproxEqRel(0.5059986252327467, S3.register_lut[S3.reg_offset + 2], 1e-12);
    try testing.expectApproxEqRel(0.17873835725405993, S3.register_lut[S3.reg_offset + 3], 1e-12);
    try testing.expectApproxEqRel(8.792568765435867e-16, S3.register_lut[251], 1e-12);
    try testing.expectEqual(@as(f64, 0.0), S3.register_lut[0]);
    try testing.expectEqual(@as(f64, 0.0), S3.register_lut[252]);
}

test Sketch {
    const S = Sketch(12);
    var sketch: S = .empty;
    try testing.expect(sketch.isEmpty());
    try testing.expectEqual(@as(f64, 0.0), sketch.estimate());

    // Add distinct hashes across small, medium, and larger ranges and check
    // that the estimate stays within 5x theoretical RSE (~6%).
    const checkpoints = [_]usize{ 1, 10, 100, 1_000, 10_000, 50_000 };
    var inserted: usize = 0;
    for (checkpoints) |target| {
        while (inserted < target) : (inserted += 1) {
            const h = Wyhash.hash(0, mem.asBytes(&inserted));
            sketch.addHash(h);
        }
        try testing.expect(!sketch.isEmpty());
        const est = sketch.estimate();
        const expected: f64 = @floatFromInt(target);
        // At tiny counts (n=1, 10), allow a small absolute margin; at larger
        // counts require relative accuracy within 5 * RSE.
        const tol = @max(2.0, 5.0 * S.relative_standard_error * expected);
        try testing.expectApproxEqAbs(expected, est, tol);
    }

    // Idempotence: re-inserting already-seen hashes changes no register.
    const before = sketch.asBytes().*;
    for (0..1_000) |i| {
        const h = Wyhash.hash(0, mem.asBytes(&i));
        sketch.addHash(h);
    }
    try testing.expectEqualSlices(u8, &before, sketch.asBytes());

    sketch.clear();
    try testing.expect(sketch.isEmpty());
    try testing.expectEqual(@as(f64, 0.0), sketch.estimate());
}

test "merge and downsize match direct insertion" {
    const Big = Sketch(12);
    const Small = Sketch(8);

    var a: Big = .empty;
    var b: Big = .empty;
    var combined_big: Big = .empty;
    var direct_small: Small = .empty;

    for (0..5_000) |i| {
        const h = Wyhash.hash(1, mem.asBytes(&i));
        if (i < 3_000) a.addHash(h);
        if (i >= 2_000) b.addHash(h);
        combined_big.addHash(h);
        direct_small.addHash(h);
    }

    // Same-precision merge is bit-for-bit exact.
    a.merge(&b);
    try testing.expectEqualSlices(u8, combined_big.asBytes(), a.asBytes());

    // Downsizing matches hashing directly at the smaller precision.
    const downsized = a.downsize(8);
    try testing.expectEqualSlices(u8, direct_small.asBytes(), downsized.asBytes());
}

test "large-range saturated registers" {
    const S = Sketch(4);
    var sketch: S = .empty;

    // Force every register to max saturation (nlz = 64 - p = 60, plus the two
    // preceding run lengths) and verify the large-range branch returns +inf.
    for (0..S.register_count) |idx| {
        const prefix_bits: u64 = @as(u64, idx) << (64 - @as(comptime_int, S.precision));
        sketch.addHash(prefix_bits); // nlz = 60 -> bit 63
        sketch.addHash(prefix_bits | 1); // nlz = 59 -> bit 62
        sketch.addHash(prefix_bits | 2); // nlz = 58 -> bit 61
    }
    for (sketch.asBytes()) |r| {
        try testing.expectEqual(@as(u8, 255), r);
    }
    try testing.expect(math.isPositiveInf(sketch.estimate()));

    // Partially saturated sketch (15 saturated registers, 1 high non-saturated
    // register) exercises the large-range correction branch and returns a
    // finite very large cardinality.
    sketch.registers[0] = 250;
    const partial = sketch.estimate();
    try testing.expect(math.isFinite(partial));
    try testing.expect(partial > 1e15);
}

test "fromBytes validation and roundtrip" {
    const S = Sketch(6);
    var sketch: S = .empty;
    for (0..200) |i| {
        sketch.addHash(Wyhash.hash(7, mem.asBytes(&i)));
    }
    const restored = try S.fromBytes(sketch.asBytes().*);
    try testing.expectEqualSlices(u8, sketch.asBytes(), restored.asBytes());
    try testing.expectEqual(sketch.estimate(), restored.estimate());

    // Unreachable register values are rejected.
    var bad = sketch.asBytes().*;
    bad[0] = 1;
    try testing.expectError(error.InvalidRegister, S.fromBytes(bad));
    bad[0] = S.reg_offset - 1;
    try testing.expectError(error.InvalidRegister, S.fromBytes(bad));
    bad[0] = S.reg_offset - 3;
    try testing.expectError(error.InvalidRegister, S.fromBytes(bad));
}

test "Auto and String delegate identically to Sketch" {
    const AutoUll = Auto(u64, 10);
    const Raw = Sketch(10);

    var typed: AutoUll = .empty;
    var raw: Raw = .empty;
    for (0..1_000) |i| {
        const k: u64 = i;
        typed.add(k);
        raw.addHash(AutoContext(u64).hash(.{}, k));
    }
    try testing.expectEqualSlices(u8, raw.asBytes(), typed.asBytes());
    try testing.expectEqual(raw.estimate(), typed.estimate());

    const StrUll = String(8);
    var strs: StrUll = .empty;
    strs.add("alpha");
    strs.add("beta");
    strs.add("alpha");
    strs.add("gamma");
    try testing.expectApproxEqAbs(@as(f64, 3.0), strs.estimate(), 1.5);
}
