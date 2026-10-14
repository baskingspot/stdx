# AGENTS.md

Working notes for AI coding agents in stdx.

## Environment

Zig 0.16 only. `nix develop` provides zig, zls, ziglint, zigdoc. The
flake is the tool contract: nothing on PATH outside the devshell.

Before calling work done, run and show:

```
zig build test
ziglint
zig fmt --check src build.zig
```

When the change touches generic code, run the option matrix too:
`zig build test -Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast`.
Lazy analysis hides code that only instantiates under a different
element type or build mode; u8-only tests never analyze the
struct/slice element paths.

## Layout

Modules mirror the std namespace they extend: `mem` ↔ `std.mem`,
`fmt` ↔ `std.fmt`, `net` ↔ `std.Io.net`, `posix` ↔ `std.posix`,
`heap` ↔ `std.heap`. Single data structures lift
to top-level names (`ArrayBuffer`, `BoundedWriter`, `SliceBuffer`);
concepts with multiple flavors get a package of short names
(`multi_array.{Array, Buffer}`), like `std.array_hash_map.Auto`.
Subdirectory modules (`fmt/`, `heap/`) re-export their surface with
prefixed names.

## Conventions

- Commit messages: one line, `area: summary`, like `time: rework in
  Io.Timestamp values`. No essays, no narrative, no "rides along" notes.
  A short body only when the why genuinely needs it.

- Tests attach to symbols (`test atoi { ... }`); a type with many
  aspects gets one merged topical test. Module roots use
  `std.testing.refAllDecls(@This())`, never itemized `_ =` lists.
- Tests assert behavior, not implementation details. Never derive
  expectations from the implementation's internal choices (chunk
  widths, private constants) — outputs must not depend on them.
- Module-level `//!` docs state the concept and why it exists. The
  target is `zig doc`, which renders symbol docs; a member inventory
  in the module doc is redundant.
- Every claim in a comment must be true on this toolchain. Read the std
  source before writing "std doesn't have X" — the `mem.cut*` family
  and `fmt.comptimePrint` were both cases where std had the answer.
- Before hand-rolling something std has, check the std function and,
  for hot paths, the disassembly. If std's version loses on codegen,
  keep the hand-roll and cite the evidence in a comment
  (`mem.lastIndexOfNonZero` is the precedent: four instructions vs
  std's scalarized ~85 on aarch64).
- Error sets are named, documented per member, and pass underlying
  parse errors through rather than collapsing them.
- Comptime options over runtime flags when they change code shape
  (`fmt.AtoiOptions`); each configuration compiles to its own loop.

## Adding code

The bar: std genuinely lacks it, it is general purpose rather than
project vocabulary, and it tests standalone. Ports of external code go
into `THIRD_PARTY.md` with upstream and license before the first commit.
