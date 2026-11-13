# Changelog

All notable changes to stdx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `base64`: RFC 4648 encoding and decoding, with a comptime codec (`standard`, `standard_no_pad`, `url_safe`, `url_safe_no_pad`) over caller-owned bytes. `decode` validates padding and the unused trailing bits. The kernel is picked from the target CPU at compile time: NEON on aarch64, AVX2 on `x86_64_v3`, AVX-512 VBMI on `x86_64_v4`. A build for the x86-64 baseline falls back to `std.base64`. No CPUID probe and no run-time dispatch: build with the target you want.
- `fmt.atoi`: `Options` gains `plus_sign` and `negative_zero`. `.plus_sign = .reject` makes `"+1"` an `error.InvalidCharacter`, and `.negative_zero = .reject` does the same for `"-0"`. Both default to today's behavior.
- `intern`: `intern.Pool` keeps one copy of each string in chunk storage and hands out dense `u32` ids. `intern`, `lookup`, `get`, and `deinit` take the allocator, and an id stays valid until `deinit`.
- `slot`: `slot.Pool(Entry, prev_field, next_field)` is a fixed-capacity pool over a caller-owned entry slice, with the two `Handle` links inside the entry. `acquire`, `release`, `get`, and `isLive` are O(1), and `iterator` walks the live entries in acquisition order. Capacity is the slice length, so a local array and an allocated slice both work.
- `swiss`: `rehash` rebuilds the table at its current bucket count and clears every tombstone. Use it on a long-lived map that removes entries without growing. Pointers into the table are invalidated.
- `time.Timestamp`: `Timestamp.now(clock)` reads a clock into the compact value with no error union, so a field takes a decl literal. `Timestamp.elapsed(clock)` returns the `Duration` to a fresh reading, and rejects `.real` at compile time because wall time can step backwards.
- `wire`: `Reader.readUntil(delimiter)` returns the bytes before a delimiter and consumes it, for a field with no length prefix. A missing delimiter is `error.UnexpectedEof`, and the cursor does not move.

## [0.4.0] - 2026-11-12

### Added

- `posix.OptionalFd`: an optional POSIX descriptor in four bytes. `none` stores `-1`, and `get` is explicitly inlined. The value carries no ownership.
- Compact time values provide `fromNanosecondsComptime`, `fromMicrosecondsComptime`, `fromMillisecondsComptime`, and `fromSecondsComptime`. These return plain values and reject out-of-range values at compile time. Optional values expose the same constructors without a sentinel or `try` step.
- `time.Duration` and `time.Timestamp`: nonnegative nanosecond values in eight bytes, with checked arithmetic and lossless conversion to the wider std values.
- `time.OptionalDuration` and `time.OptionalTimestamp`: eight-byte optional values. `none` uses the highest `u64` value without a separate tag.

## [0.3.0] - 2026-11-02

### Changed

- stdx builds with Zig 0.16 and 0.17. `minimum_zig_version` stays `0.16.0`,
  and CI runs the Debug, ReleaseSafe, and ReleaseFast suites on both.

## [0.2.1] - 2026-11-01

### Fixed

- `BoundedWriter`: grow the buffer with the same super-linear growth as
  `ArrayList`, clamped to `limit`, instead of to the exact size of each write.
  Byte-at-a-time writes no longer reallocate and copy the whole buffer per
  byte.
- `BoundedWriter`: a `writeSplat` call with a splat count of zero drops the
  final pattern as specified and no longer copies it into the buffer first.

## [0.2.0] - 2026-10-31

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
