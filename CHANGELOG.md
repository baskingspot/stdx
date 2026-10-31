# Changelog

All notable changes to stdx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `heap.Bump(.{ ... })`: a single-threaded bump arena over chunks from a
  child allocator, with the chunk sizes fixed at comptime. `allocator()` hands
  out an `Allocator` with no atomics, `free` is a no-op, and `deinit` releases
  every chunk. `reset(.retain_capacity)` keeps the chunks for the next job, and
  a request above `max_chunk` gets a chunk of its own size. The type's `State`
  holds only the chunk list and the cursor, for a struct that stores an arena
  and gets copied.
- `jsonc`: read JSON with `//` and `/* */` comments and a trailing comma.
  `scrub` and `scrubInPlace` blank the comments and the comma to spaces and
  keep every byte offset, so `std.json` parses the copy and reports the
  caller's line and column. `parseFromSlice` returns a value that owns the
  scrubbed copy.
- `dotenv.parse`: a `.env` parser with one documented grammar. Keys match
  `[A-Za-z_][A-Za-z0-9_]*`, an `export` prefix is accepted, and comments and
  the three quoting forms follow one set of rules. Key and value slices are
  borrowed from the caller's source, except the escape bytes of a
  double-quoted value, which go into a caller-owned scratch buffer. A bad line
  returns `Error` and fills the `Diagnostics` the caller passed; `lineText`
  returns that line. Duplicate keys are kept in order and `Doc.get` returns the
  last. No variable expansion.

- `lru.Custom`, `lru.Auto`, and `lru.String`: a fixed-capacity LRU cache.
  `get` and `peek`; `put` returns the replaced value or the evicted entry;
  `remove`, `popLru`, `popMru`, an iterator, and `clear`. No allocator and no
  eviction callback.

- `fmt.parseBool`: the boolean spellings of Go's `strconv.ParseBool` (`1`,
  `t`, `T`, `TRUE`, `true`, `True`, and the false set). Returns null for
  anything else.

- `sort.radix`: a stable LSD radix sort for signed and unsigned integers,
  with a caller-owned scratch slice. `sort.nth` and `sort.select` partition a
  slice around the n-th element with a 3-way quickselect and a depth fallback.

- `once.Cell` and `once.Lazy`: a value set at most once, with `get`,
  `getOrInit`, `getOrTryInit`, `set`, and `take`. `once.SyncCell` and
  `once.SyncLazy` add an atomic fast path and an `Io.Mutex` for the first
  initialization.

- `prefix_map.Map`: a compressed radix tree over byte strings, with `get` and
  `getLongestPrefix`. Build at comptime with `initComptime`, or at runtime with
  `init` and `deinit`. A duplicate key is a compile error at comptime and
  `error.DuplicateKey` at runtime.

- `enums.Open` and `enums.Closed`: turn a comptime list of byte strings into
  an enum, then switch on the tags. `Open` is non-exhaustive with an unnamed
  miss value and an `else` arm. `Closed` adds a named fallback tag and is
  exhaustive. `enums.stringToEnum` matches enum field names like
  `std.meta.stringToEnum`, with fixed-length loads.

- `set.Custom`, `set.Auto`, and `set.String` expose `capacity`, the bound
  every other fixed-capacity container already publishes.

- `btree` and `lru` gain `init`: a value with a default-initialized
  context, beside `empty` (undefined context) and `initContext` (caller's
  context). `priority_queue` keeps `empty` and `initContext`, because its
  usual context is `void`, which has no default to initialize.
  `lru.PutResult.empty` is the result of a put that replaced and evicted
  nothing.

### Changed

- Public structs no longer accept a bare `.{}`. A value type names its
  constructor (`init`, `empty`, `zero`, or `default`) and requires every
  field, so `btree.Iterator`, `slot_ring.Lease`, `stdio.Stream`,
  `time.RateLimit`, `jsonc.Diagnostics`, and `lru.PutResult` lost their
  field defaults. A struct literal must now set every field; use the
  constructor. Options bags (`jsonc.Options`, `dotenv.ParseOptions`) keep
  their defaults, runtime or comptime: a call site overrides one knob and
  leaves the rest.

- `net.Ip4.parse` takes a fixed-window SWAR fast path for canonical dotted
  quads. On a 1M-address random corpus the fast path measured 6.8 ns per
  address against 15.2 ns for the std parser. Results, the error set, and
  non-canonical behavior are unchanged; anything the fast path rejects goes
  through the std parser.
- `dotenv.parse` returns `Error!Doc` instead of a `Result` union with `.doc`
  and `.diagnostic` arms. A failed parse fills a caller-owned `Diagnostics`
  through `ParseOptions.diagnostics`, which gained the column of the offending
  byte. A successful parse leaves that value untouched.

## [0.1.0] - 2026-10-26

The first release. Everything the guide documents ships here.

### Added

- `stdx`: extensions to the Zig 0.16 standard library, as one module with a
  namespace per idea: fixed-capacity containers, a resizable Swiss hash map,
  the ordered `btree`, strict parsing, a forward-only `wire` format, base32,
  IPv4 and CIDR prefixes, UUIDs, timekeeping, a caller-driven timer set, an
  MPSC log ring, and the small pieces (`BoundedWriter`, `hash.RapidHash`, the
  heap pools, `mem` byte values, secure random, and buffered stdio).
- `btree`: an ordered map. `btree.Auto` takes integer keys, `btree.String`
  takes `[]const u8` keys, and `btree.Custom` takes any key type with a
  comparison context. Iteration is in key order. `lockPointers` makes an
  insertion or removal that invalidates a held pointer assert in Debug and
  ReleaseSafe.
- `wire.Reader(.big)` and `wire.Reader(.little)`: forward-only decoding of
  caller-owned bytes, the inverse of `wire.Writer`, with checked and `assume`
  forms.
- `time.writeRfc3339`: UTC RFC 3339 text with the fractional width fixed at
  comptime, from `.seconds` through `.nanoseconds`.
- `net.HostPort.parse`: split `host`, `host:port`, `[host]`, and `[host]:port`
  config text with a default port.
- `bit_set.Scratch(capacity)`: a fixed-capacity bitset for reused workspaces;
  reset clears only the validity map.
- `heap.SizeClassPool`: a fallible byte pool over caller-owned storage, with
  per-class live accounting.
