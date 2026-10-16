<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="stdx" height="48">
  </picture>
</h1>

Extensions to the Zig 0.16 standard library: fixed-capacity containers, strict parsers, IPv4 types, and the primitives std lacks.

The same helpers kept showing up copy-pasted across projects: strict number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded writer, a slab allocator. stdx is where they live. Each module is tested on its own, and the package has no dependencies.

## What is in it

- [Fixed-capacity containers](https://stdx.withmatt.com/#fixed-capacity-containers): lists, queues, maps, sets, Bloom filters, and comptime lookup tables. The storage lives in the value, with no allocator and no `deinit`.
- [Strict parsing](https://stdx.withmatt.com/#strict-parsing): `fmt.atoi` accepts one grammar for machine-written integers and rejects the rest.
- [Base32](https://stdx.withmatt.com/#base32): a Crockford base32 codec for fixed-shape machine tokens. The decode itself is the validation, and every spelling outside the lowercase alphabet fails.
- [IP addresses](https://stdx.withmatt.com/#ip-addresses): `net.Ip4` and `net.Prefix4`, following Go's `net/netip`: classification, ordering, canonical prefixes, and overlap checks.
- [UUIDs](https://stdx.withmatt.com/#uuids): `Uuid` generates version 4 and version 7 values, formats them, and parses the canonical text form.
- [Timekeeping](https://stdx.withmatt.com/#timekeeping): clock reads with no `Io` value, a per-tick cached clock, wall time for log lines, and a log rate limiter.
- [Logging transport](https://stdx.withmatt.com/#logging-transport): `slot_ring.Mpsc` moves log lines from worker threads to one consumer. Producers never block, and a refused claim drops the new message.
- The [module list](https://stdx.withmatt.com/#modules) covers the rest: Swiss-table maps, a slab allocator, rapidhash, secure random, and buffered stdio.

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
reload, and `just doc` builds the whole site into `zig-out/site/`.

MIT licensed — see `LICENSE`. A few pieces were adapted from other code;
`THIRD_PARTY.md` says which, and under what terms.

## Related projects

stdx is one of several libraries for low-level primitives that Zig lacks:

- [fastmem](https://github.com/mattrobenolt/fastmem-zig): SIMD memcpy, memmove, and memset.
- [ztls](https://github.com/mattrobenolt/ztls): a sans-I/O TLS 1.3 state machine.
- [zcompress](https://github.com/mattrobenolt/zcompress): fast, self-contained compression codecs.
- [ztest](https://github.com/mattrobenolt/ztest): a test runner that writes plain, parseable text instead of a TUI.
- [zig-benchmark](https://github.com/mattrobenolt/zig-benchmark): Go-style benchmarking with allocation metrics.
