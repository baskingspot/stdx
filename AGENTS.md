# AGENTS.md

Working notes for AI coding agents in stdx.

## Environment

Zig 0.16 only. `nix develop` provides zig, zls, ziglint, zigdoc, oxfmt,
just. The site tools (zola, wrangler) live in a second, lighter shell,
`nix develop .#docs`, which the doc recipes enter themselves. The flake is
the tool contract: nothing on PATH outside the devshell.

The justfile is the command interface. Run recipes, not raw zig
commands:

```
just lint test
```

Takes multiple targets — `just lint test` does both. `just ci` is
the full set the test lanes run; the site build is its own CI job
(`just doc`). The darwin cross-compile is the macOS CI lane's job,
not a local one. When the change touches generic code, run the option
matrix too: `just test-release-safe test-release-fast`. Lazy analysis
hides code that only instantiates under a different element type or
build mode; u8-only tests never analyze the struct/slice element
paths.

## Layout and naming

No `x` suffixes inside the package — `stdx` is the only one that
needs it, and `const mem = @import("stdx").mem;` composes without
it.

- Modules mirror the std namespace they extend: `mem` ↔ `std.mem`,
  `fmt` ↔ `std.fmt`, `net` ↔ `std.Io.net`, `posix` ↔ `std.posix`,
  `heap` ↔ `std.heap`.
- Concepts std lacks get concept-named modules, lowercase:
  `bloom`, `swiss`, `hash`, `stdio`.
- Container families follow `std.array_hash_map`'s newer shape: the
  module name carries the concept (`bounded_array_hash_map`), and the
  constructors inside are bare — `Custom(Context, ...)` the underlying
  full form, `Auto(K, ...)` and `String(V, ...)` the friendly ones.
  `stdx.bounded_array_hash_map.Auto(u32, u32, 64)`.
- No type-dependent routing inside the friendly forms. std's
  `autoHash` rejects slices, so `[]const u8` keys get a separate
  `String` entry point — one context per constructor, the std
  `AutoHashMap`/`StringHashMap` split, never a conditional.
- Files: type-constructor functions lowercase
  (`buffer.zig`, `heap/slab_allocator.zig`), single concrete types
  PascalCase (`BoundedWriter.zig`, `Uuid.zig`), file-as-a-struct for
  stateful types. Subdirectory modules (`fmt/`, `heap/`) re-export
  their surface with prefixed names.

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

## Documentation

The voice, the tagline, and the decisions behind the docs are in
`docs/VOICE.md`. Read it before you write or review a doc.

Two surfaces, one job each. `//!` and `///` docs state the contract:
what a symbol does, its invariants, its failure modes. The guide
(`docs/`, a Zola site) says which piece to pick and how pieces combine,
organized by task, not by module.

- The guide is one page: `docs/content/_index.md`. Each `#` is a chapter
  and each `##` a section; Zola builds the sidebar contents from them, and
  a heading's slug is its anchor, so renaming a heading breaks links to it.
  Split into pages only when one page stops being searchable with Cmd+F.
- Guide examples are complete files in `docs/examples/`, listed in
  `docs/examples/root.zig`, and run under `just test`. A page embeds one
  with `load_data(path="examples/x.zig", format="plain")` inside a `zig`
  fence. Never paste a code block into a page that the compiler has not
  seen. Name files `<module>_<topic>.zig`.
- Examples write bindings the way an adopter should: `const timex =
  stdx.time;`, `const fmtx = stdx.fmt;`. The `x` suffix only when std's
  namesake is usually in scope; `buffer`, `stdio`, `net` stay bare.
  Inside `src/` module bindings never take a suffix.
- Example imports: a file that uses one stdx module writes
  `const buffer = @import("stdx").buffer;`. Only a file that uses several
  writes `const stdx = @import("stdx");` first. Bind a module at the top
  and never spell it out inline (`priority_queue.Custom(...)`, not
  `stdx.priority_queue.Custom(...)`). Prefer decl literals and inferred
  types: `.broadcast`, `try .parse("10.1.2.3")`, `.loopback(0)`.
- Examples are generic programs. Never name a downstream project.
- Fence languages are strict (`error_on_missing_language`). The
  highlighter has no `zon` grammar: label `.zon` snippets `zig`.
- Guide prose follows the technical-writing rules: short active
  sentences, no contractions.

## Adding code

The bar: std genuinely lacks it, it is general purpose rather than
project vocabulary, and it tests standalone. Ports of external code go
into `THIRD_PARTY.md` with upstream and license before the first commit.
