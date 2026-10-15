# stdx

Extensions to the Zig 0.16 standard library: fixed-capacity containers, strict parsers, IPv4 types, and the primitives std lacks.

The same helpers kept showing up copy-pasted across projects: strict number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded writer, a slab allocator. stdx is where they live. Each module is tested on its own, and the package has no dependencies.

## What is in it

- [Fixed-capacity containers](https://stdx.withmatt.com/#fixed-capacity-containers): lists, queues, maps, sets, Bloom filters, and comptime lookup tables. The storage lives in the value, with no allocator and no `deinit`.
- [Strict parsers](https://stdx.withmatt.com/#strict-parsing) for machine-written input: `fmt.atoi`, `net.Ip4`, `net.Prefix4`, and `Uuid`.
- [IPv4 and CIDR types](https://stdx.withmatt.com/#ip-addresses) modeled on Go's `net/netip`: classification, ordering, canonical prefixes, and overlap checks.
- [Clocks](https://stdx.withmatt.com/#timekeeping), randomness, and stdio that need no `Io` value: a per-tick cached clock, wall time derived from a monotonic sample, and a log rate limiter.
- A resizable Swiss-table hash map, a slab allocator, and rapidhash.

## Install

```sh
zig fetch --save git+https://github.com/mattrobenolt/stdx
```

Add the module to your build:

```zig
const stdx = b.dependency("stdx", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("stdx", stdx.module("stdx"));
```

stdx builds with Zig 0.16 only.

## Documentation

- The [guide](https://stdx.withmatt.com) says which module to use for a task, with examples that compile.
- The [API reference](https://stdx.withmatt.com/api/) documents every symbol.

## Work on it

```
just test
```

Zig 0.16. `nix develop` gives you the toolchain, ziglint, zigdoc, oxfmt,
and just — the justfile carries the rest (`just ci` for the full set).
The site tools live in a lighter shell, `nix develop .#docs`, which the
doc recipes enter on their own: `just guide` serves the guide with live
reload, and `just doc-serve` builds and serves the whole site.

MIT licensed — see `LICENSE`. A few pieces were adapted from other code;
`THIRD_PARTY.md` says which, and under what terms.

## Related projects

Other pieces of the same effort — low-level primitives Zig is missing:

- [fastmem](https://github.com/mattrobenolt/fastmem-zig) — SIMD
  memcpy, memmove, and memset
- [ztls](https://github.com/mattrobenolt/ztls) — a TLS library
- [zcompress](https://github.com/mattrobenolt/zcompress) — fast,
  self-contained compression codecs
- [ztest](https://github.com/mattrobenolt/ztest) — a test runner that
  writes plain text instead of a TUI
- [zig-benchmark](https://github.com/mattrobenolt/zig-benchmark) — a
  benchmark harness
