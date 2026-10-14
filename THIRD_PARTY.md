# Third-party code

stdx is MIT (`LICENSE`). This file lists every piece adapted from code
under another license, so those terms travel with the package.

## Zig standard library

Upstream: Zig 0.16.0 `std`.
License: MIT, "Copyright (c) Zig contributors". The full license text is
reproduced in `LICENSE-ZIG`, per its terms.

| File | Upstream | Adaptation |
|---|---|---|
| `src/multi_array.zig` | `std.MultiArrayList` | The `Element` tagged-union representation, the `SortContext` adapter, and the struct-of-arrays design. Storage here is embedded and comptime-shaped rather than heap-allocated. |
| `src/posixx.zig` | `std.Io.Threaded` (private `address4FromPosix` / `address4ToPosix`) | The `sockaddr_in` ↔ `Ip4Address` conversion: network-endian port, `@bitCast` octets. |

## fast_float

Upstream: https://github.com/fastfloat/fast_float
(`src/fast_float/ascii_number.h`).
License: Apache-2.0 OR MIT — stdx takes the MIT option.

The SWAR digit-processing constants and steps in `src/fmtx/atoi.zig` are
transcribed from `ascii_number.h` (credit @aqrit; the technique is Daniel
Lemire's SWAR digit parsing, an extension of Wojciech Muła's). The credit
and technique links are kept in the file header.

