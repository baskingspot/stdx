# Changelog

All notable changes to stdx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
