<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="stdx" height="48">
  </picture>
</h1>

Extensions to the Zig 0.16 standard library: fixed-capacity containers, strict parsers, IPv4 types, and the primitives std lacks.

The same helpers kept showing up copy-pasted across projects: strict number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded writer, a slab allocator. stdx is where they live. Each module is tested on its own, and the library imports only `std`.

## What is in it

- [Fixed-capacity containers](https://baskingspot.dev/stdx/#fixed-capacity-containers): lists, queues, maps, sets, Bloom filters, and comptime lookup tables. The storage lives in the value, with no allocator and no `deinit`.
- [Strict parsing](https://baskingspot.dev/stdx/#strict-parsing): `fmt.atoi` accepts one grammar for machine-written integers and rejects the rest.
- [Base32](https://baskingspot.dev/stdx/#base32): a Crockford base32 codec for fixed-shape machine tokens. The decode itself is the validation, and every spelling outside the lowercase alphabet fails.
- [IP addresses](https://baskingspot.dev/stdx/#ip-addresses): `net.Ip4` and `net.Prefix4`, following Go's `net/netip`: classification, ordering, canonical prefixes, and overlap checks.
- [UUIDs](https://baskingspot.dev/stdx/#uuids): `Uuid` generates version 4 and version 7 values, formats them, and parses the canonical text form.
- [Timekeeping](https://baskingspot.dev/stdx/#timekeeping): clock reads with no `Io` value, a per-tick cached clock, wall time for log lines, and a log rate limiter.
- [Logging transport](https://baskingspot.dev/stdx/#logging-transport): `slot_ring.Mpsc` moves log lines from worker threads to one consumer. Producers never block, and a refused claim drops the new message.
- The [module list](https://baskingspot.dev/stdx/#modules) covers the rest: Swiss-table maps, a slab allocator, rapidhash, secure random, and buffered stdio.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/stdx
```

Add the module to your build:

```zig
const stdx = b.dependency("stdx", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("stdx", stdx.module("stdx"));
```

stdx builds with Zig 0.16 only.

## Documentation

- The [guide](https://baskingspot.dev/stdx/) says which piece to use for a task, with examples that compile.
- The [API reference](https://baskingspot.dev/stdx/api/) documents every symbol.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the recipes, and `just ci` runs what CI runs. `just guide` serves the guide with live reload, and `just doc` builds the whole site into `zig-out/site/stdx/`.

## License

MIT. See `LICENSE`. Parts are adapted from other code; `THIRD_PARTY.md` says which, and under what terms. The logo files in `docs/static/` are baskingspot marks and are not covered by it. See `docs/static/LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
