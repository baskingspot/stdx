# Third-party code

stdx is MIT (`LICENSE`). This file lists every piece adapted from code
under another license, so those terms travel with the package, and it credits
the designs that were reimplemented without code crossing over.

## Zig standard library

Upstream: Zig 0.16.0 `std`.
License: MIT, "Copyright (c) Zig contributors". The full license text is
reproduced in `LICENSE-ZIG`, per its terms.

| File                  | Upstream                                                            | Adaptation                                                                                                                                                                                               |
| --------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/multi_array.zig` | `std.MultiArrayList`                                                | The `Element` tagged-union representation, the `SortContext` adapter, and the struct-of-arrays design. Storage here is embedded and comptime-shaped rather than heap-allocated.                          |
| `src/posix.zig`       | `std.Io.Threaded` (private `address4FromPosix` / `address4ToPosix`) | The `sockaddr_in` ↔ `Ip4Address` conversion: network-endian port, `@bitCast` octets.                                                                                                                     |
| `src/stability.zig`   | `std.debug.SafetyLock`, Zig master after 0.16.0                     | Copied, plus a file comment and an `init` constant. Two lines move the shared counter with `@intFromEnum` / `@enumFromInt` because 0.16 has no `@backingInt`. 0.16's own `SafetyLock` is exclusive only. |

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

## swift-endpoint

Upstream: https://github.com/swift-dns/swift-endpoint
(`Sources/IPAddress/IPv4Address/String+IPv4Address.swift`, commit
`c030b658`).
License: Apache-2.0; the full text is in `LICENSE-APACHE`.

`src/net/ip4.zig` ports the fixed-window parser by Mahdi Bahrami, described
in "A Very Fast IPv4 Parser, in Swift"
(https://blog.mahdibm.com/posts/a-very-fast-ipv4-parser-in-swift/). Zig
adaptations: `std.mem.readInt` windows, `@ctz`/`@clz`, the `ParseError`
boundary, and a leading-zero rejection that upstream does not perform. The
SWAR validation, segment folds, and constants are upstream's.

## libbase64

Upstream: https://github.com/aklomp/base64 (`lib/arch/neon64/enc_loop.c`,
`enc_reshuffle.c`, `dec_loop.c`, master, commit `1ac2f0e`).
License: BSD-2-Clause, Copyright (c) 2005-2007 Nick Galbreath, 2015-2018
Wojciech Muła, 2016-2017 Matthieu Darbois, 2013-2022 Alfred Klomp — terms
reproduced below.

`src/base64.zig` reimplements their aarch64 NEON codecs. The instruction
sequence of the block kernels is theirs: `ld3` deinterleave, the shift/insert
reshuffle, a 64-byte `tbl` alphabet translation, `st4` on encode; `ld4`, a
saturating subtract into a second 64-byte `tbx` table, the shift-or pack, and
`st3` on decode, with the split at character 63 that makes one combined value
above 63 mean invalid. Zig adaptations: the tables are generated at comptime
from the alphabet, the tables and the structure loads are pinned to fixed
registers because Zig has no `tbl`/`ld3` builtins, the block loops return the
byte count they consumed so one scalar tail serves every codec, and the
padding and trailing-bit checks are Zig's own.

Copyright (c) 2005-2007, Nick Galbreath
Copyright (c) 2015-2018, Wojciech Muła
Copyright (c) 2016-2017, Matthieu Darbois
Copyright (c) 2013-2022, Alfred Klomp
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## web-platform-tests

Upstream: https://github.com/web-platform-tests/wpt (`url/resources/urltestdata.json`, commit `065d99ab`, 2026-11-12).
License: BSD-3-Clause, "Copyright © web-platform-tests contributors"; the
full text is in `test/urltestdata.LICENSE`.

`test/urltestdata.json` is vendored verbatim as the conformance corpus for
`src/uri.zig`, and copied for no other purpose. It is not in `paths` in
`build.zig.zon`, so it does not ship in the package.

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
