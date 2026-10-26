# Third-party code

stdx is MIT (`LICENSE`). This file lists every piece adapted from code
under another license, so those terms travel with the package, and it credits
the designs that were reimplemented without code crossing over.

## Zig standard library

Upstream: Zig 0.16.0 `std`.
License: MIT, "Copyright (c) Zig contributors". The full license text is
reproduced in `LICENSE-ZIG`, per its terms.

| File                  | Upstream                                                            | Adaptation                                                                                                                                                                        |
| --------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/multi_array.zig` | `std.MultiArrayList`                                                | The `Element` tagged-union representation, the `SortContext` adapter, and the struct-of-arrays design. Storage here is embedded and comptime-shaped rather than heap-allocated.   |
| `src/posix.zig`       | `std.Io.Threaded` (private `address4FromPosix` / `address4ToPosix`) | The `sockaddr_in` ↔ `Ip4Address` conversion: network-endian port, `@bitCast` octets.                                                                                              |
| `src/stability.zig`   | `std.debug.SafetyLock`, Zig master after 0.16.0                     | Copied, plus a file comment. Two lines move the shared counter with `@intFromEnum` / `@enumFromInt` because 0.16 has no `@backingInt`. 0.16's own `SafetyLock` is exclusive only. |

## rapidhash

Upstream: https://github.com/Nicoshev/rapidhash (`rapidhash.h`, tag `rapidhash_v3`, commit `bc4b4ba`).
License: MIT, Copyright (C) 2025 Nicolas De Carli — notice reproduced below; also carried at the top of the ported file.

The algorithm structure and all constants in `src/hash/rapidhash.zig` are
transcribed verbatim from upstream's `rapidhash.h`. Adaptations: Zig
`readInt(.little)` reads (endian-independent), `u128` multiply for the
64×64→128 fold, per-variant internal functions. The widely mirrored
rapidhash snippet (smhasher, Chromium V8) is an older 3-secret version
that produces different outputs; this port is V3, pinned to the tag.

Copyright (C) 2025 Nicolas De Carli

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## fast_float

Upstream: https://github.com/fastfloat/fast_float
(`src/fast_float/ascii_number.h`).
License: Apache-2.0 OR MIT — stdx takes the MIT option.

The SWAR digit-processing constants and steps in `src/fmt/atoi.zig` are
transcribed from `ascii_number.h` (credit @aqrit; the technique is Daniel
Lemire's SWAR digit parsing, an extension of Wojciech Muła's). The credit
and technique links are kept in the file header.

## bbtree

Upstream: https://github.com/XiangpengHao/bbtree (tag `v0.1.5`), `bbtree/src/tree/node/vector_count.rs`.
License: MIT or Apache-2.0, at our option; stdx takes MIT, "Copyright (c)
2026 Xiangpeng Hao". The MIT terms are those reproduced below for rapidhash,
with that copyright line.

`btree`'s window count follows their `NeonCount` (their decision D56): each
compare yields all-ones lanes, subtracting a lane from a counter adds one, and
the counters are added up once at the end. Zig's `@Vector` over the whole node
compiles the sum into a widening and a shuffle chain, which their note and our
disassembly both describe; the per-register form is the fix.

## Design references

These are designs stdx implemented on its own. No code was copied, so no
license terms from these works attach to stdx; the credit is here because the
ideas are theirs.

`btree` is Xiangpeng Hao's design, from "bbtree: fastest ordered map" at
[bbtree.xiangpeng.systems/post](https://bbtree.xiangpeng.systems/post/), with
the Rust implementation at
[github.com/XiangpengHao/bbtree](https://github.com/XiangpengHao/bbtree). The
cache-miss cost model, inline keys, prefix stripping between a node's fences,
and the rule that the smallest and largest keys fence the spines are his.
Inline keys and prefix keys themselves trace further back, to Graefe and
Larson (ICDE 2001) and Bayer and Unterauer (TODS 1977).

Copyright (c) 2026 Xiangpeng Hao

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
