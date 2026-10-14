//! SIMD extensions to `std.simd`.

const simd = @import("std").simd;

/// `std.simd.suggestVectorLength(T)`, capped at `max`, for loops whose
/// per-iteration cost scales with the block size. Null on targets with no
/// vector width for `T`.
pub fn suggestVectorLengthMax(
    comptime T: type,
    max: comptime_int,
) ?comptime_int {
    return if (simd.suggestVectorLength(T)) |size| @min(size, max) else null;
}
