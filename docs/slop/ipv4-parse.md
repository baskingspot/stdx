# IPv4 parsing: why the fast path is SWAR

2026-10-29. The goal was to see whether the AVX-512 dotted-quad algorithm
from Niles Salter's "AVX-512 IPv4 Parsing" presentation
(https://github.com/Validark/presentations) ports to this host and beats
`std.Io.net.Ip4Address.parse`.

Decision: `Ip4.parse` uses the fixed-window SWAR parser in `src/net/ip4.zig`
for canonical input. `diagnose` only names the error for everything else, so
the error set stays std's without pretending the fallback might return a
value.

One-off measurements on an AWS Graviton4 (Neoverse V3), Zig 0.16.0,
ReleaseFast, over 1,048,576 random canonical addresses:

| implementation                    | ns/address |
| --------------------------------- | ---------- |
| SWAR fixed windows                | 6.82       |
| NEON `tbl` + `udot`, SSE family   | 9.83       |
| `std.Io.net.Ip4Address.parse`     | 15.18      |
| unrolled scalar (Lemire 2025)     | 15.88      |
| tight scalar loop                 | 16.93      |

The unrolled scalar is fastest on a repeated handful of inputs (about 6 ns),
but it loses the cold corpus to branch misses. The NEON port of the SSE
family is close but not faster: x86 gets `pshufb`/`pmaddubsw`/`movemask` as
single instructions, while NEON pays for the table lookup and movemask
emulation. The AVX-512 kernel needs `vpcompressd`, which NEON does not have.
The x86 kernels are a separate target-gated project if x86 ever matters.

The valid input space is finite: one canonical text per IPv4 address, 2^32
of them. A one-off exhaustive run parsed all of them in 16 seconds on four
cores; the check was not kept in the repo. Non-canonical and malformed input
cannot be enumerated that way, so the deterministic corpus and fuzz test in
`src/net.zig` compare `Ip4.parse` to std, including every error value.
