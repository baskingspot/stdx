# stdx

A small library of Zig standard-library extensions and data structures,
built on Zig 0.16.

The same helpers kept showing up copy-pasted across projects: strict
number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded
writer, a slab allocator. stdx is where they live now — tested
standalone, no dependencies.

The modules mirror the std namespaces they extend (`memx`, `fmtx`,
`netx`, `posixx`, `simdx`, `heapx`); the data structures (`ArrayBuffer`,
`SliceBuffer`, `BoundedWriter`, `multi_array`) sit at the top level. The
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
