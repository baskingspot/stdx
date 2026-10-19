# Changelog

All notable changes to stdx are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `wire.Reader(.big)` and `wire.Reader(.little)`: forward-only decoding of
  caller-owned bytes, the inverse of `wire.Writer`, with checked and `assume`
  forms.
- `time.writeRfc3339`: UTC RFC 3339 text with the fractional width fixed at
  comptime, from `.seconds` through `.nanoseconds`.
- `net.HostPort.parse`: split `host`, `host:port`, `[host]`, and `[host]:port`
  config text with a default port.
- `bitset.Scratch(capacity)`: a fixed-capacity bitset for reused workspaces;
  reset clears only the validity map.
