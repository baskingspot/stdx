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

## ztls

Upstream: https://github.com/mattrobenolt/ztls (Apache-2.0).

`src/array_buffer.zig` and `src/slice_buffer.zig` derive from ztls's
`array_buffer.zig`. Every commit to that file in ztls is by Matt
Robenolt, who is also the stdx copyright holder, so the Apache-2.0
grant places no obligation on this MIT relicensing. Listed for
provenance.
