# stdx

A small library of Zig standard-library extensions and data structures,
built on Zig 0.16.

The same helpers kept showing up copy-pasted across projects: strict
number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded
writer, a slab allocator. stdx is where they live now — tested
standalone, no dependencies.

The modules mirror the std namespaces they extend (`mem`, `fmt`,
`net`, `posix`, `heap`); concepts std lacks get concept names
(`bloom`, `swiss`, `rapidhash`); container families follow
`std.array_hash_map`'s shape — the module carries the concept
(`bounded_array_hash_map`), the constructors inside are bare
(`Custom`/`Auto`/`String`). The
source is the documentation: every type and function carries doc
comments that render with `zig doc`, alongside its own tests.

## Use it

```
zig fetch --save git+https://github.com/mattrobenolt/stdx.git
```

Then import it as `stdx` in your build, as normal.

## Work on it

```
zig build test
```

Zig 0.16. `nix develop` gives you the toolchain, ziglint, and zigdoc.

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
