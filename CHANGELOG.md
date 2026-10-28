# Changelog

All notable changes to stdx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
