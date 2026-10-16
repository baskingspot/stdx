+++
title = "stdx"
+++

Extensions to the Zig 0.16 standard library: fixed-capacity containers, strict parsers, IPv4 types, and the primitives std lacks.

The same helpers kept showing up copy-pasted across projects: strict number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded writer, a slab allocator. stdx is where they live. Each module is tested on its own, and the package has no dependencies.

- [Fixed-capacity containers](#fixed-capacity-containers): lists, queues, maps, sets, Bloom filters, and comptime lookup tables. The storage lives in the value, with no allocator and no `deinit`.
- [Strict parsing](#strict-parsing): `fmt.atoi` accepts one grammar for machine-written integers and rejects the rest.
- [IP addresses](#ip-addresses): `net.Ip4` and `net.Prefix4`, following Go's `net/netip`: classification, ordering, canonical prefixes, and overlap checks.
- [UUIDs](#uuids): `Uuid` generates version 4 and version 7 values, formats them, and parses the canonical text form.
- [Timekeeping](#timekeeping): clock reads with no `Io` value, a per-tick cached clock, wall time for log lines, and a log rate limiter.
- [Logging transport](#logging-transport): `slot_ring.Mpsc` moves log lines from worker threads to one consumer. Producers never block, and a refused claim drops the new message.
- The [module list](#modules) covers the rest: Swiss-table maps, a slab allocator, rapidhash, secure random, and buffered stdio.

This guide explains how to choose modules and combine them. The [API reference](/api/) documents every symbol.

# Getting started

## Install

Add stdx to your project:

```sh
zig fetch --save git+https://github.com/mattrobenolt/stdx
```

Add the module to your build in `build.zig`:

```zig
const stdx = b.dependency("stdx", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("stdx", stdx.module("stdx"));
```

stdx builds with Zig 0.16 only.

## Import it

Import the root module once in each file. Then bind the modules that the file uses:

```zig
const stdx = @import("stdx");
const buffer = stdx.buffer;
const timex = stdx.time;
```

If the file uses only one module, import it directly:

```zig
const timex = @import("stdx").time;
```

## Name the bindings

Name a binding after its module. If the file already has a std module with the same name, add an `x` suffix.

| Binding  | Why                                   |
| -------- | ------------------------------------- |
| `timex`  | `std.time` is in scope in most files. |
| `fmtx`   | `std.fmt` is in scope in most files.  |
| `buffer` | std has no `buffer` module.           |
| `stdio`  | std has no `stdio` module.            |

The suffix keeps both modules readable at the call site. `timex.now(.awake)` is stdx. `time.ns_per_ms` is std.

This rule is for code that uses stdx. Inside stdx, a module binding never has a suffix.

## Choose std or stdx

stdx does not replace std. Use std when std has what you need. Use stdx for the cases where std is too liberal, needs an `Io` value that the code does not have, or has no equivalent, such as a Bloom filter.

Strict parsing is an example. Use `fmt.atoi` for input with a machine grammar, such as an HTTP `Content-Length` header or a line from `/proc`. It rejects bases, underscores, and trailing characters. Use `std.fmt.parseInt` for input that people write, such as command-line flags and config values. There, `1_000_000` is easier to read.

## Read the examples

Every example in this guide is a complete file in `docs/examples/`. The test step compiles and runs each one, so the code in this guide builds. Run them all:

```sh
just test
```

The [API reference](/api/) has the contract for each symbol. This guide has the recipes.

# Modules

A module that extends a std namespace takes its name: `mem`, `fmt`, `net`, `posix`, `heap`, `hash`. A concept std lacks gets its own: `bloom`, `swiss`, `set`. A container family follows `std.array_hash_map`. The module names the concept, and the constructors inside are `Custom`, `Auto`, and `String`.

| Module                                                        | Use it for                                                                                                    |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| [`bloom`](/api/#stdx.bloom)                                   | Bloom filters with a fixed capacity.                                                                          |
| [`bounded_array_hash_map`](/api/#stdx.bounded_array_hash_map) | An insertion-ordered hash map with a fixed capacity and no allocator.                                         |
| [`BoundedWriter`](/api/#stdx.BoundedWriter)                   | An `Io.Writer` over an allocated buffer with a hard byte limit. It fails at the limit instead of growing.     |
| [`buffer`](/api/#stdx.buffer)                                 | Append buffers with a fixed capacity. `Array` owns its storage. `Slice` borrows it.                           |
| [`fmt`](/api/#stdx.fmt)                                       | Strict number parsing (`atoi`) and comptime hex decoding.                                                     |
| [`hash`](/api/#stdx.hash)                                     | `RapidHash`.                                                                                                  |
| [`heap`](/api/#stdx.heap)                                     | `SlabAllocator`.                                                                                              |
| [`mem`](/api/#stdx.mem)                                       | Fixed-size byte values and memory scans.                                                                      |
| [`multi_array`](/api/#stdx.multi_array)                       | Struct-of-arrays types with the storage inside the value.                                                     |
| [`net`](/api/#stdx.net)                                       | IPv4 addresses and CIDR prefixes, after Go's `net/netip`: parse, classify, order, step, and test containment. |
| [`pages`](/api/#stdx.pages)                                   | Release whole kernel pages back to the OS. Linux only.                                                        |
| [`posix`](/api/#stdx.posix)                                   | `getsockname` and `getpeername` on raw socket handles.                                                        |
| [`priority_queue`](/api/#stdx.priority_queue)                 | A priority queue with a fixed capacity.                                                                       |
| [`random`](/api/#stdx.random)                                 | Secure random bytes without an `Io` value.                                                                    |
| [`set`](/api/#stdx.set)                                       | A bounded set with set algebra.                                                                               |
| [`slot_ring`](/api/#stdx.slot_ring)                           | A bounded MPSC ring for log lines: producers never block, and one consumer drains. Linux only.                |
| [`static_map`](/api/#stdx.static_map)                         | Lookup tables that the compiler builds from a literal.                                                        |
| [`stdio`](/api/#stdx.stdio)                                   | Buffered stderr and stdout streams that never return an error.                                                |
| [`swiss`](/api/#stdx.swiss)                                   | Resizable Swiss-table hash maps.                                                                              |
| [`time`](/api/#stdx.time)                                     | Clock reads without an `Io` value, a cached clock, and a log rate limiter.                                    |
| [`Uuid`](/api/#stdx.Uuid)                                     | UUID v4 and v7. Generate, parse, and format.                                                                  |

# Choosing a container

Most stdx containers have a fixed capacity. The capacity is part of the type, the storage is inside the value, and no allocator is involved. One container, `swiss`, grows at runtime and uses an allocator.

Find the need in the table. Then read the section for that type in [Fixed-capacity containers](#fixed-capacity-containers).

| You need                                  | Use                                        | Notes                                                                                   |
| ----------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------- |
| A list with a known maximum length        | `buffer.Array`                             | Storage inside the value.                                                               |
| The same list over memory you already own | `buffer.Slice`                             | Same methods. The capacity is the slice length.                                         |
| One array per struct field                | `multi_array.Buffer`                       | Runtime length. `multi_array.Array` has a fixed length.                                 |
| The smallest item first                   | `priority_queue.Custom`                    | A binary heap. You supply the comparison.                                               |
| A map that keeps insertion order          | `bounded_array_hash_map.Auto` or `.String` | Fixed capacity.                                                                         |
| A set                                     | `set.Auto` or `.String`                    | A map with no values, plus set algebra.                                                 |
| A constant lookup table                   | `static_map.Auto` or `.String`             | Built at compile time from a literal. Not the same as `std.StaticStringMap`: see below. |
| A cheap "have I seen this" test           | `bloom.Auto`                               | Can report a key that was never added.                                                  |
| A map that grows                          | `swiss.Auto` or `.String`                  | Uses an allocator. Order is not insertion order.                                        |

## Pick a fixed capacity when

- The maximum is a real limit that your program already enforces, such as a configured connection count.
- The value must copy freely, such as a configuration struct.
- The code must not allocate, such as a signal handler or an event loop that runs after startup.

## Pick std or swiss when

- The size depends on input that you do not control. A fixed capacity turns a large input into `error.NoSpaceLeft`.
- The container is large and rarely full. A copy moves the whole capacity, used or not.
- You need `std.ArrayList` features that the fixed types lack.

## Check std first

- `std.StaticStringMap` also builds a lookup table at compile time, but only for string keys. [Build a table at compile time](#build-a-table-at-compile-time) lists how `static_map` differs. Use `static_map` when the keys are not strings, or when you want a compile error for a duplicate key.
- `std.EnumMap` covers dense enum keys.
- `std.PriorityQueue`, `std.ArrayList`, and `std.AutoArrayHashMap` allocate. The stdx types of the same shape do not.

# Fixed-capacity containers

A fixed-capacity container stores its elements in an array inside the value. The capacity is a comptime parameter, so it is part of the type. `buffer.Array(u8, 16)` and `buffer.Array(u8, 32)` are different types.

Three rules hold for every type on this page except `swiss`, which the last section covers:

- No method takes an allocator, and no value needs a `deinit`.
- An operation that does not fit returns `error.NoSpaceLeft`. It never grows.
- A copy of the value is a full copy of the storage.

## Build a list

`buffer.Array` is the base type. `append` and `appendSlice` return `error.NoSpaceLeft` when the item does not fit.

```zig
{{ load_data(path="examples/containers_buffer_array.zig", format="plain") | trim_end }}
```

Each fallible method has an `AssumeCapacity` form. Use it only after the code has checked the size. In Debug and ReleaseSafe builds, a wrong assumption is a safety-checked panic.

## Keep it in a struct

A fixed-capacity list is a good field in a configuration struct. The struct copies by value, and nothing needs to be freed.

```zig
{{ load_data(path="examples/containers_config_field.zig", format="plain") | trim_end }}
```

Choose the capacity close to the real maximum. A copy moves every byte of the storage, so a large capacity makes every copy, return, and pass by value expensive. A very large value can also overflow the stack. Put such a value in a global or in a struct that you allocate.

Use one constant for the limit. The command-line check and the type then agree about the maximum.

## Borrow storage

`buffer.Slice` has the methods of `buffer.Array`, but it appends into memory that the caller owns. Use it when the memory already exists, such as a stack array or a region of a larger buffer.

```zig
{{ load_data(path="examples/containers_buffer_slice.zig", format="plain") | trim_end }}
```

The slice stores a pointer. Keep the storage alive for as long as the `Slice` is in use.

## Order by priority

`priority_queue.Custom` is the binary heap of `std.PriorityQueue` with a fixed capacity. The comparison function returns `.lt` when the first argument must pop first.

```zig
{{ load_data(path="examples/containers_priority_queue.zig", format="plain") | trim_end }}
```

A queue made with `.empty` has an undefined context. If the comparison reads the context, make the queue with `initContext`.

## Store key and value pairs

`bounded_array_hash_map` is the data structure of `std.AutoArrayHashMapUnmanaged` with a fixed capacity. Entries keep their insertion order. Use `Auto` for keys that `std.hash.autoHash` accepts and `String` for `[]const u8` keys.

```zig
{{ load_data(path="examples/containers_bounded_map.zig", format="plain") | trim_end }}
```

When the map is full, `put` fails for a new key. It still updates an existing key.

## Store a set

`set` is a map with no values and the usual set operations. The operations work in place and do not allocate. `add` returns `true` for a new key and `false` for a key that is already present. It returns `error.NoSpaceLeft` when a new key does not fit, and `unite` does the same when the union does not fit.

```zig
{{ load_data(path="examples/containers_set.zig", format="plain") | trim_end }}
```

## Build a table at compile time

`static_map` builds a lookup table from a literal during compilation. The table is a constant. It has no startup cost, and a duplicate key is a compile error.

```zig
{{ load_data(path="examples/containers_static_map.zig", format="plain") | trim_end }}
```

`std.StaticStringMap` also builds a table at compile time, for string keys. `static_map` differs in these ways:

- Key types: std takes `[]const u8` only. `static_map.Auto` takes key types that `std.hash.autoHash` accepts, such as `u8`, `u32`, and enums with an explicit `u8` tag. A key with bits narrower than a byte, such as a `u2`, a `bool`, or an enum with three tags, is a compile error, because std hashes those bits differently at comptime than at runtime. Use `static_map.Custom` with your own hash for such keys. `static_map.Custom` takes your own hash and equality context, and `static_map.String` is the string-keyed form.
- Lookup: std finds a key by its length, then compares it against each key of that length. `static_map` hashes the key and probes a table.
- Duplicates: std accepts a duplicate key, and which of its values `get` returns is unspecified. `static_map` rejects a duplicate key at compile time.
- Order: std orders `keys()` and `values()` by key length. `static_map` keeps the order of your literal.
- What only std has: `getLongestPrefix`, which finds the longest key that starts a string, and `init`, which builds the map at runtime with an allocator. `static_map` has neither.

For string keys, use std unless you want one of those properties from `static_map`. For a dense enum key, `std.EnumMap` fits. For any other key type, std has no table of this kind.

## Test membership cheaply

`bloom` is a Bloom filter. `contains` never misses a key that was added. It can report a key that was never added, at a known rate. The rate holds only while the filter holds the number of keys that you sized it for.

```zig
{{ load_data(path="examples/containers_bloom.zig", format="plain") | trim_end }}
```

## Store columns

`multi_array` keeps one array for each field of a struct. A loop over one field reads one contiguous array. `Buffer` has a runtime length. `Array` has a fixed length.

```zig
{{ load_data(path="examples/containers_multi_array.zig", format="plain") | trim_end }}
```

## Grow when you must

`swiss` is the exception. It is a resizable hash map, so every call that can allocate takes the allocator, and the value does not store it. The map keeps the key slices that you give it, so the keys must outlive the map.

```zig
{{ load_data(path="examples/containers_swiss_map.zig", format="plain") | trim_end }}
```

# Strict parsing

The std parsers accept more than one grammar. That is correct for input that people write. For input that a program writes, it hides errors. `fmt.atoi` accepts one grammar and rejects the rest.

Use it at a machine boundary, such as an HTTP header or a line from `/proc`. Use `std.fmt.parseInt` for values that people type, such as command-line flags.

## Parse an integer

`fmt.atoi` accepts an optional sign (for signed types) and decimal digits. The whole string must be the number. It rejects base prefixes, underscores, spaces, and an empty string.

```zig
{{ load_data(path="examples/parsing_atoi.zig", format="plain") | trim_end }}
```

An empty or malformed string returns `error.InvalidCharacter`. A number too large for the type returns `error.Overflow`.

## Choose the grammar

`fmt.atoiWith` takes comptime options. Each set of options compiles to its own loop, so the choice has no runtime cost.

```zig
{{ load_data(path="examples/parsing_leading_zeros.zig", format="plain") | trim_end }}
```

`.overflow = .unchecked` skips the overflow check. The caller promises that the value fits. A value that does not fit is a safety-checked panic in Debug and ReleaseSafe, and undefined behavior in ReleaseFast. `fmt.atoiUnchecked` is the shorthand.

# IP addresses

`net.Ip4` and `net.Prefix4` follow Go's `net/netip`, with Zig names. They have the same semantics for classification, ordering, and prefix masking. They are plain values with no allocation.

`Ip4` is four bytes with no port. std's `Ip4Address` carries a port, which a configuration field or an allow list does not need. `Ip4` converts to and from the std types.

## Parse an address

`Ip4.parse` accepts dotted-quad text and nothing else. Each error names the problem.

For a literal in code, use `Ip4.parseComptime`. It parses at compile time, and a typo is a compile error that quotes the string. `Prefix4` has the same function. `Ip4.init` takes the four bytes directly, and `Prefix4.init` takes an address and a length.

```zig
{{ load_data(path="examples/net_parse.zig", format="plain") | trim_end }}
```

## Classify an address

`Ip4` has the `netip` predicates: `isLoopback`, `isPrivate`, `isMulticast`, `isLinkLocalUnicast`, `isLinkLocalMulticast`, `isBroadcast`, `isUnspecified`, and `isGlobalUnicast`.

`isGlobalUnicast` follows Go. A private or link-local address is global unicast, because it is routable. If the code means "public", it must exclude those classes.

```zig
{{ load_data(path="examples/net_classify.zig", format="plain") | trim_end }}
```

## Compare and step

`order` compares two addresses in numeric order. `next` and `prev` step by one address and return `null` at the ends of the space, so a loop cannot wrap.

```zig
{{ load_data(path="examples/net_range.zig", format="plain") | trim_end }}
```

## Work with prefixes

`Prefix4` is a network address and a length in bits. `parse` is strict. It rejects a missing slash, a length above 32, and a length with leading zeros.

- `contains` tests an address against the prefix.
- `masked` zeroes the host bits and returns the canonical form.
- `overlaps` tests whether two prefixes cover a common address.
- `isSingleIp` tests for a `/32`, a prefix of exactly one address.
- `Ip4.prefix` builds the prefix of a given length around an address.
- A prefix formats with `{f}`, like an address.

```zig
{{ load_data(path="examples/net_prefix.zig", format="plain") | trim_end }}
```

## Convert from std types

`Ip4.fromAny` takes a std `IpAddress` and returns an `Ip4`, or `null` for a real IPv6 address. It also unwraps an IPv4-mapped IPv6 address. A dual-stack listener reports an IPv4 peer in that form, so `fromAny` gives one answer for both.

`withPort` makes an `Ip4Address`. `fromIp4` drops the port. `fromSlice` builds an address from exactly four bytes. `Ip4` formats with `{f}`.

```zig
{{ load_data(path="examples/net_std_types.zig", format="plain") | trim_end }}
```

## Use an address as a key

An `Ip4` is four bytes with no padding. It works as a key in the hash containers without a custom context.

```zig
{{ load_data(path="examples/net_key.zig", format="plain") | trim_end }}
```

## Know the limits

These types are IPv4 only. `Ip4.parse` rejects IPv6 text, and `Prefix4.parse` rejects IPv6 prefixes. For dual-stack matching, keep a second set of rules for IPv6 and test both. Socket calls on raw file descriptors are in `posix`.

# UUIDs

`Uuid` generates version 4 and version 7 values, formats them, and parses the canonical 36-byte text form. Version 7 values are ordered across milliseconds, but not inside one millisecond.

```zig
{{ load_data(path="examples/uuid_roundtrip.zig", format="plain") | trim_end }}
```

# Timekeeping

The `time` module reads clocks without an `Io` value. It returns `std.Io.Timestamp` values, so the std `Duration` conversions work on the result. It runs on Linux and macOS.

## Choose a clock

`time.now` takes an `Io.Clock`. Two clocks cover most code.

| Clock    | Use it for                                                                            |
| -------- | ------------------------------------------------------------------------------------- |
| `.awake` | Elapsed time, deadlines, and timeouts. The value has meaning only inside the process. |
| `.real`  | Timestamps that people read, or that leave the process.                               |

Never send an `.awake` value to another process. It is a number with no meaning there.

## Measure a deadline

A deadline must read the clock directly. A cached sample can lag by one tick, and a timeout must not fire late.

```zig
{{ load_data(path="examples/time_deadline.zig", format="plain") | trim_end }}
```

## Cache the clock in a loop

An event loop reads the time many times in each iteration. Each read is a system call. A `CachedClock` replaces all of them with one call at the top of the iteration.

```zig
{{ load_data(path="examples/time_cached_clock.zig", format="plain") | trim_end }}
```

Follow these rules:

- Give each thread its own cache. A `CachedClock` is not thread-safe.
- Call `refresh` once per iteration. Call `now` for every other read.
- A cached value is never in the future. It lags true time by at most one iteration.
- A clock that was never refreshed reads the real clock directly.

Use the cache for log timestamps, metrics, and rate limits. Do not use it for deadlines.

## Stamp log lines with wall time

A log line needs wall time, but the loop already holds an `.awake` sample. `WallFromAwake` converts the sample. It stores the offset between the two clocks, which the process computes once at startup.

```zig
{{ load_data(path="examples/time_wall_from_awake.zig", format="plain") | trim_end }}
```

The converted time never goes backwards. A clock step from NTP cannot reorder log lines. The cost is that the converted time drifts from true wall time if the system clock steps after startup. For log lines, this is the right trade. Use `.real` when you need true wall time.

## Limit a repeated log line

A failure that repeats for each connection can write one line per event. `RateLimit` admits one line per interval. It returns the number of lines that it held back, so the one line can report them.

```zig
{{ load_data(path="examples/time_rate_limit.zig", format="plain") | trim_end }}
```

`admit` returns `null` when the caller must hold the line back. Pass it a monotonic sample, such as `clock.now()` from a `CachedClock(.awake)`.

`RateLimit.default` has a one-second interval. `RateLimit.init` takes any `Io.Duration`.

# Logging transport

A worker thread that writes a log line cannot block on a slow consumer. `slot_ring.Mpsc` is a bounded, lock-free ring for that shape: many threads `acquire` a slot, write, and `commit`, and one consumer drains in order. Producers never block: a refused `acquire` returns `null` and the new message drops. The module is Linux only: it is `void` on other targets. `slot_size` is a comptime option, and it must be a multiple of the cache line. `init` rounds the slot count up to a power of two.

## Pick the wake flavor

The consumer's shape decides the wake mechanism at compile time.

| Flavor     | Consumer                                                                                                                        |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `.none`    | The caller drives every drain: a test, or a loop that drains on its own schedule.                                               |
| `.eventfd` | A poll loop. `pollFd()` is the doorbell. Call `ackDoorbell()` when the fd reads ready, before the drain.                        |
| `.futex`   | A dedicated consumer thread. `waitForData` parks it until data or shutdown. `requestShutdown` ends it after the producers join. |

## Pick the loss policy

`.drop_new` is the default and the logging choice. A full ring refuses the new message, so the loss is the newest lines. `.drop_oldest` displaces the oldest committed message instead, so the newest line wins. The displacing ring owns the consumer cursor, and the consumer reads through `read(buf)`, which copies the payload into the caller's buffer. A `read(buf)` that loses the cursor to a displacer returns `null`, and the displacer ticks `displacedCount`.

## Drain in order

The consumer stops at the first `null`, which marks a claim that is not committed yet. A consumer that advances past the first uncommitted claim skips the committed messages behind it. Under `.drop_new`, the caller owns the read position and `release` frees the slot. Under `.drop_oldest`, the ring owns the cursor and `read(buf)` frees the slot inside the window it claims.

## Account the loss

`head()` counts the claims handed out. A refused `acquire` is the caller's drop count. Under `.drop_oldest`, `displacedCount()` counts the lines that producers displaced. Every line is delivered, displaced, or refused, so the counts close the total.

```zig
{{ load_data(path="examples/slot_ring_logging.zig", format="plain") | trim_end }}
```

## Tradeoffs

The ring is not a lossless queue. Overflow drops a message under either policy: `.drop_new` refuses the newest, and `.drop_oldest` displaces the oldest committed message when it can. The loss is always accounted (`head()`, a refused `acquire`, `displacedCount()`) but never prevented. A caller that must not lose a message needs a blocking channel, not this ring.

One consumer thread drains by position, in order. A producer stalled mid-write stalls the drain behind its position: the cost is dropped messages, never corrupted ones. There is no out-of-order drain and no parallel drain.

Producers never block. An `acquire` either wins a slot or returns `null`, and the caller drops the message. Under `.drop_oldest`, a full ring displaces the oldest committed message instead, so the newest message wins. A stalled producer still refuses the claim, and so does a displacement that cannot win the cursor.

The policy decides the read shape. Under `.drop_oldest`, the consumer reads through `read(buf)` and gets a copy inside the won cursor window. `.drop_new` hands out a borrowed slice from `read(read_pos)`: the single consumer owns the position, and nothing can take the slot before `release`.

One message costs one CAS on the head, the payload copy into the slot, and one release store of the stamp. The wake flavor adds its own cost. `.none` adds nothing, `.eventfd` writes eight bytes to the fd, and `.futex` bumps the wake word with one RMW. The `.futex` syscall runs only when a waiter is armed. A displacement adds a cursor CAS, a stamp CAS, and one atomic increment of the displaced count. It also wakes the consumer under the two waking flavors.

Linux only. The `.eventfd` and `.futex` flavors wrap Linux syscalls, and the module is `void` on other targets. `slot_size` is comptime and a cache-line multiple. Changing it instantiates a new ring type.

# Related projects

stdx is one of several libraries for low-level primitives that Zig lacks.

- [fastmem](https://github.com/mattrobenolt/fastmem-zig): SIMD memcpy, memmove, and memset.
- [ztls](https://github.com/mattrobenolt/ztls): a sans-I/O TLS 1.3 state machine.
- [zcompress](https://github.com/mattrobenolt/zcompress): fast, self-contained compression codecs.
- [ztest](https://github.com/mattrobenolt/ztest): a test runner that writes plain, parseable text instead of a TUI.
- [zig-benchmark](https://github.com/mattrobenolt/zig-benchmark): Go-style benchmarking with allocation metrics.
