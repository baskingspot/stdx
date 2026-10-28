+++
title = "stdx"
+++

Extensions to the Zig 0.16 standard library: fixed-capacity containers, strict parsers, IPv4 types, and the primitives std lacks.

The same helpers kept showing up copy-pasted across projects: strict number parsing, IPv4 and CIDR handling, fixed-capacity buffers, a bounded writer, a slab allocator. stdx is where they live. Each module is tested on its own, and the package has no dependencies.

- [Modules](#modules): every export of `src/root.zig`, one row each, with the reason to reach for it.
- [Choosing a container](#choosing-a-container): which fixed-capacity type fits a need, and when to use std or `swiss` instead.
- [Fixed-capacity containers](#fixed-capacity-containers): lists, queues, maps, sets, Bloom filters, and comptime lookup tables. The storage lives in the value, with no allocator and no `deinit`.
- [Ordered maps](#ordered-maps): `btree` keeps the keys sorted for iteration and range scans, with cache-sized nodes and a stripped prefix at every node.
- [Strict parsing](#strict-parsing): `fmt.atoi` accepts one grammar for machine-written integers and rejects the rest.
- [String dispatch](#string-dispatch): `enums.Open` and `enums.Closed` turn a byte-string list into an enum for a `switch`. `stringToEnum` matches an existing enum with fixed-length compares.
- [Prefix matching](#match-a-prefix): `prefix_map.Map` stores byte prefixes in a compressed radix tree and returns the longest match.
- [Initialize once](#initialize-once): `once.Cell` and `once.Lazy` set a value at most once. The `Sync` variants share it across threads.
- [Sort](#sort): `sort.radix` is a stable integer radix sort, and `sort.nth`/`sort.select` find the k-th element without sorting the rest.
- [Binary encoding](#binary-encoding): `wire.Writer` writes integers, enums, and slices into caller-owned bytes, with the byte order fixed at comptime and a slot for a length or checksum written later.
- [Base32](#base32): a Crockford base32 codec for fixed-shape machine tokens. The decode itself is the validation, and every spelling outside the lowercase alphabet fails.
- [IP addresses](#ip-addresses): `net.Ip4` and `net.Prefix4`, following Go's `net/netip`: classification, ordering, canonical prefixes, and overlap checks.
- [UUIDs](#uuids): `Uuid` generates version 4 and version 7 values, formats them, and parses the canonical text form.
- [Timekeeping](#timekeeping): clock reads with no `Io` value, a per-tick cached clock, wall time for log lines, and a log rate limiter.
- [Timers](#timers): a caller-driven set of deadlines over `Io.Timestamp`, with callbacks, removal by handle, and period re-arm without drift.
- [Logging transport](#logging-transport): `slot_ring.Mpsc` moves log lines from worker threads to one consumer. Producers never block, and a refused claim drops the new message.
- [Small modules](#small-modules): a bounded writer, rapidhash, the heap pools, fixed-size byte values, secure random, and buffered stdio.

This guide explains how to choose modules and combine them. The [API reference](api/) documents every symbol.

# Getting started

## Install

Add stdx to your project:

```sh
zig fetch --save https://baskingspot.dev/stdx/v0.1.0.tar.gz
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

The [API reference](api/) has the contract for each symbol. This guide has the recipes.

# Modules

A module that extends a std namespace takes its name: `mem`, `fmt`, `net`, `posix`, `heap`, `hash`. A concept std lacks gets its own: `bloom`, `once`, `swiss`, `set`. A container family follows `std.array_hash_map`. The module names the concept, and the constructors inside are `Custom`, `Auto`, and `String`.

| Module                                                       | Use it for                                                                                                                                                                        |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`base32`](api/#stdx.base32)                                 | Crockford base32 codec for fixed-shape machine tokens: lowercase-only `encode` and `decode`, where the decode is the validation.                                                  |
| [`bit_set`](api/#stdx.bit_set)                               | Fixed-capacity bitsets. `Scratch` resets without clearing the dirty backing words.                                                                                                |
| [`bloom`](api/#stdx.bloom)                                   | Bloom filters with a fixed capacity.                                                                                                                                              |
| [`bounded_array_hash_map`](api/#stdx.bounded_array_hash_map) | An insertion-ordered hash map with a fixed capacity and no allocator.                                                                                                             |
| [`btree`](api/#stdx.btree)                                   | An ordered map that grows: sorted iteration, and lookups by key.                                                                                                                  |
| [`BoundedWriter`](api/#stdx.BoundedWriter)                   | An `Io.Writer` over an allocated buffer with a hard byte limit. It fails at the limit instead of growing.                                                                         |
| [`buffer`](api/#stdx.buffer)                                 | Fixed-capacity buffers. `Array` owns its storage. `Slice` and `Queue` borrow it, and `Queue` consumes from the front.                                                             |
| [`enums`](api/#stdx.enums)                                   | Switch on a byte string: generate an open or closed enum from a list, or look up an existing enum.                                                                                |
| [`fmt`](api/#stdx.fmt)                                       | Strict number parsing (`atoi`) and comptime hex decoding.                                                                                                                         |
| [`hash`](api/#stdx.hash)                                     | `RapidHash`: rapidhash V3, plus std-style hash-map contexts.                                                                                                                      |
| [`heap`](api/#stdx.heap)                                     | `SlabAllocator` and `SizeClassPool`.                                                                                                                                              |
| [`mem`](api/#stdx.mem)                                       | Fixed-size byte values and memory scans.                                                                                                                                          |
| [`multi_array`](api/#stdx.multi_array)                       | Struct-of-arrays types with the storage inside the value.                                                                                                                         |
| [`net`](api/#stdx.net)                                       | IPv4 addresses and CIDR prefixes, after Go's `net/netip`: parse, classify, order, step, and test containment. `Ip4Endpoint` holds octets and port; `HostPort` splits config text. |
| [`once`](api/#stdx.once)                                     | Set-once values and lazy initialization, single-threaded and thread-safe.                                                                                                         |
| [`pages`](api/#stdx.pages)                                   | Release whole kernel pages back to the OS. API reference only. Linux only.                                                                                                        |
| [`posix`](api/#stdx.posix)                                   | `getsockname`, `getpeername`, `setsockopt`, and `getsockopt` on raw socket handles. See [Work with a raw socket fd](#work-with-a-raw-socket-fd).                                  |
| [`prefix_map`](api/#stdx.prefix_map)                         | A compressed radix tree for exact and longest-prefix lookups.                                                                                                                     |
| [`priority_queue`](api/#stdx.priority_queue)                 | A priority queue with a fixed capacity.                                                                                                                                           |
| [`random`](api/#stdx.random)                                 | Secure random bytes without an `Io` value.                                                                                                                                        |
| [`set`](api/#stdx.set)                                       | A bounded set with set algebra.                                                                                                                                                   |
| [`slot_ring`](api/#stdx.slot_ring)                           | A bounded MPSC ring for log lines: producers never block, and one consumer drains. Linux only.                                                                                    |
| [`sort`](api/#stdx.sort)                                     | A stable integer radix sort, and selection of the k-th element.                                                                                                                   |
| [`static_map`](api/#stdx.static_map)                         | Lookup tables that the compiler builds from a literal.                                                                                                                            |
| [`stdio`](api/#stdx.stdio)                                   | Buffered stderr and stdout streams that never return an error.                                                                                                                    |
| [`swiss`](api/#stdx.swiss)                                   | Resizable Swiss-table hash maps.                                                                                                                                                  |
| [`time`](api/#stdx.time)                                     | Clock reads without an `Io` value, a cached clock, RFC 3339 formatting, and a log rate limiter.                                                                                   |
| [`timers`](api/#stdx.timers)                                 | A caller-driven set of timers over `Io.Timestamp`: arm and stop entries by handle, fire callbacks, and repeat on a period.                                                        |
| [`Uuid`](api/#stdx.Uuid)                                     | UUID v4 and v7. Generate, parse, and format.                                                                                                                                      |
| [`wire`](api/#stdx.wire)                                     | A forward-only writer over caller-owned bytes, with the byte order fixed at comptime. Integers, enums, slices, and backpatch slots.                                               |

# Choosing a container

Most stdx containers have a fixed capacity. The capacity is part of the type, the storage is inside the value, and no allocator is involved. One container, `swiss`, grows at runtime and uses an allocator.

Find the need in the table. Then read the section for that type in [Fixed-capacity containers](#fixed-capacity-containers).

| You need                                              | Use                                        | Notes                                                                                   |
| ----------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------- |
| A list with a known maximum length                    | `buffer.Array`                             | Storage inside the value.                                                               |
| The same list over memory you already own             | `buffer.Slice`                             | Same methods. The capacity is the slice length.                                         |
| A buffer that a transport refills and a parser drains | `buffer.Queue`                             | Borrows storage. `rebase` compacts the consumed front.                                  |
| One array per struct field                            | `multi_array.Buffer`                       | Runtime length. `multi_array.Array` has a fixed length.                                 |
| The smallest item first                               | `priority_queue.Custom`                    | A binary heap. You supply the comparison.                                               |
| A map that keeps insertion order                      | `bounded_array_hash_map.Auto` or `.String` | Fixed capacity.                                                                         |
| A set                                                 | `set.Auto` or `.String`                    | A map with no values, plus set algebra.                                                 |
| A set of indices in a reused workspace                | `bit_set.Scratch`                          | Reset clears only a validity map.                                                       |
| A constant lookup table                               | `static_map.Auto` or `.String`             | Built at compile time from a literal. Not the same as `std.StaticStringMap`: see below. |
| A cheap "have I seen this" test                       | `bloom.Auto`                               | Can report a key that was never added.                                                  |
| A map that grows                                      | `swiss.Auto` or `.String`                  | Uses an allocator. Order is not insertion order.                                        |
| Keys kept in sorted order                             | `btree.Auto` or `.String`                  | Uses an allocator. Iteration is in key order, not insertion order.                      |

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

A fixed-capacity container never allocates and never grows. `buffer.Array` stores its elements inside the value, so the capacity is a comptime parameter: `buffer.Array(u8, 16)` and `buffer.Array(u8, 32)` are different types. `buffer.Slice` and `buffer.Queue` borrow storage that the caller owns, so a copy of either copies the reference, not the storage.

Two rules hold for every type on this page except `swiss`, which the last section covers:

- No method takes an allocator, and no value needs a `deinit`.
- Nothing grows. An operation that does not fit returns `error.NoSpaceLeft`, and a cursor operation that oversteps the storage panics.

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

## Refill and drain

`buffer.Queue` borrows storage like `Slice`, but it also reads from the front. Use it when a transport delivers arbitrary chunks and a parser needs complete messages.

```zig
{{ load_data(path="examples/containers_buffer_queue.zig", format="plain") | trim_end }}
```

`buffered` returns the unconsumed elements. `take` returns a prefix and drops it, and `toss` drops a prefix without returning it. `unusedCapacitySlice` returns the free tail, and `advance` commits the count written there. `rebase` moves the unconsumed elements to the front and invalidates every slice into the backing that an earlier call returned. Call it when the tail is too small for the next read, not after every read. The method names follow `std.Io.Reader` and `std.Io.Writer`.

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

## Reuse a bitset

`bit_set.Scratch(capacity)` is a fixed-capacity set of indices for a workspace that runs many requests. It has no by-value constructor: declare it `undefined` and call `clear` once, because returning or copying the value would copy the whole backing. The same call starts each later generation. A data word is zeroed the first time `set` touches it, so a reset costs the words a request touched, not the whole capacity.

```zig
{{ load_data(path="examples/containers_bit_set_scratch.zig", format="plain") | trim_end }}
```

`unset` clears a bit. A word that was never touched reads as unset, so `unset` on it is a no-op.

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

# Ordered maps

Zig has no ordered map that owns its nodes. `std.Treap` orders keys, but it
takes a node from the caller for each element and chases pointers down the
tree. `btree` is the ordered map: it grows, it takes the allocator per call,
and it iterates in key order.

A lookup reads a few cache lines, not one per key compared. A node holds a
couple of dozen keys, and the search compares one short window of every key
with a single vector compare. The window starts where the keys a node routes already share
their first bytes, so a common prefix costs nothing. Keys that are slices stay on the heap, and a comparison reads their bytes
only when two windows tie.

## Keep keys in order

Iteration is in key order. A repeated key replaces its value and keeps its
place in the order. `iteratorFrom` starts the walk at any key, so a range is
one iterator with a stop condition.

```zig
{{ load_data(path="examples/btree_ordered_map.zig", format="plain") | trim_end }}
```

## Hold a pointer safely

The map grows and owns its entries, so a value pointer or an iterator does
not survive every call: an insertion or removal in the same leaf shifts
entries, and a split or a merge frees the node. `lockPointers` brackets the
use of such a pointer. While a borrow is outstanding, every call that could
move or free an entry fails an assertion in Debug and ReleaseSafe, and does
nothing in ReleaseFast.

```zig
map.lockPointers();
defer map.unlockPointers();
const value = map.getPtr(key).?;
// An insertion or removal from here would invalidate `value`. While the
// lock is held, the map asserts instead of running it.
```

## Use it from one thread

The map is not thread safe. Use it from one thread at a time, and do not read
it from two threads at once either. The pointer guard that catches invalidated
pointers is a plain counter, and an insertion or removal moves or frees nodes.

The original also ships a concurrent map. It puts a version lock on every node,
reads inner nodes optimistically, and recycles freed nodes through a free list.
This one does not; that is a separate design.

## Pick a key type

`btree.Auto` takes integer keys, ordered numerically. `btree.String` takes
`[]const u8` keys, ordered by bytes. `btree.Custom` takes any key type with a
context that declares `compare`, and it uses inline keys when that context
also declares `inlineKey`.

An ordered map is the wrong choice when the order is not needed. `swiss` and
the fixed-capacity maps find a key without comparing keys at all, and they are
much faster for that. Reach for `btree` when the program reads keys in order,
looks for the nearest key on either side, or must iterate a table in a stable
sorted order.

The design is Xiangpeng Hao's, from
[bbtree: fastest ordered map](https://bbtree.xiangpeng.systems/post/). The Rust
implementation is at [XiangpengHao/bbtree](https://github.com/XiangpengHao/bbtree).
This module reimplements the ideas in Zig; none of that code is here.

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

# String dispatch

`enums.Open` turns a list of byte strings into a non-exhaustive enum. Switch on the tags, and put the miss in `else`:

```zig
{{ load_data(path="examples/enums_classify.zig", format="plain") | trim_end }}
```

`enums.Closed` takes the name of a fallback tag and generates an exhaustive enum. The compiler then checks that every tag has an arm. Use `Open` when `else` is the simplest way to handle the miss, and `Closed` when the fallback deserves a name in the switch.

The compiler switches on the byte length first. A value whose length no tag has costs one test. Each arm compares only the tags of that length, with a fixed-length compare at compile time. The compare is byte-exact. The input does not have to be text.

A tag is any non-empty byte string without a null byte. Write a tag that is not an identifier as `.@"content-type"`. For keys that cannot be tag names, use `static_map.String` or `std.StaticStringMap`.

`enums.stringToEnum(E, value)` matches the field names of an existing enum, like `std.meta.stringToEnum`. It compares each candidate with fixed-length loads.

# Match a prefix

`prefix_map.Map(V)` is a compressed radix tree over byte strings. `get` is an exact lookup. `getLongestPrefix` returns the value of the longest stored key that is a prefix of the input.

```zig
{{ load_data(path="examples/prefix_map_routes.zig", format="plain") | trim_end }}
```

The keys are copied into the tree, so the input slices do not need to outlive `init`. `initComptime` puts the tree in the binary. `init` builds the same four slices with an allocator, and `deinit` releases them. A duplicate key is a compile error at comptime and `error.DuplicateKey` at runtime.

The tree stores each shared prefix once and branches on the next byte, so a lookup walks one node per branch, not one node per byte. Children sit in a sorted range. A node with more than eight children uses a binary search.

Use it for route tables, layered configuration, or a set of byte prefixes. For exact keys at scale, use `static_map.String`. A hash is faster when you do not need prefix semantics. `std.StaticStringMap.getLongestPrefix` probes the map once per prefix length. This tree walks one node per branch, so the gap grows with the key count.

# Initialize once

`once.Cell(T)` holds a value that is set at most once. `get` returns null until the value exists. `getOrInit` initializes it on the first call. `once.Lazy(T, init)` fixes the initializer at compile time, so `get` is the cell call.

```zig
{{ load_data(path="examples/once_lazy.zig", format="plain") | trim_end }}
```

`Cell` and `Lazy` are single-threaded. `SyncCell` and `SyncLazy` share the value across threads. The fast path is one acquire load. The first initialization takes an `Io.Mutex`, and threads that arrive together wait for the winner. `SyncCell.get` never blocks. `getOrInit` does.

`set` returns `error.AlreadySet` when a value exists. `take` moves the value out of an unsync cell. A failed `getOrTryInit` leaves the cell empty, so a later call can try again. Do not copy a cell after use.

# Sort

`std.mem.sort` is the stable WikiSort/block sort, and `std.mem.sortUnstable` is pdqsort. `sort` adds the cases those do not cover.

`sort.radix` is a stable LSD radix sort for signed and unsigned integers. It makes one pass per digit, so its cost does not depend on comparisons. The caller supplies a scratch slice at least as long as the items, and it must not overlap them. Use it for large, unordered integer arrays. `std.mem.sortUnstable` wins on sorted or nearly sorted input; at small sizes the fixed passes do not pay off.

```zig
{{ load_data(path="examples/sort_radix.zig", format="plain") | trim_end }}
```

`sort.nth` partitions a slice so the value at `n` is the n-th smallest, in expected O(n). `sort.select` returns that value. Both take a comparison context, like `std.mem.sort`, and a depth limit falls back to `std.mem.sortUnstable` on the active range.

`radix` is ascending only. For a descending integer order, sort ascending and reverse, or use a comparison sort. `radix` is stable; `nth` and `select` are not.

# Binary encoding

A binary format fixes the width and byte order of each field. `wire.Writer` writes both into storage that the caller owns. The writer moves forward only, and it never allocates.

## Write a message

`wire.Writer(.big)` writes big-endian integers, enums, and byte slices. It writes integers of any byte width, including `u24`, `u48`, and `u128`. Signed values are two's complement, and an enum is written as its backing integer. `buffered` returns the bytes written so far. To write a range out of band, take `unusedCapacitySlice`, write into it, and call `advance` with the count.

`reserve` returns a slot that the caller fills later. Use it for a length or checksum that is not known until the body is written. The example reserves a 24-bit body length, writes the body, and fills the slot with `std.mem.writeInt`.

```zig
{{ load_data(path="examples/wire_backpatch.zig", format="plain") | trim_end }}
```

## Choose the byte order

The byte order is a comptime parameter, so `wire.Writer(.big)` and `wire.Writer(.little)` are different types. Each fixed-width store compiles to its own order, and the choice costs nothing at runtime. The example's second test writes a little-endian field.

Byte slices and reserved slots are order-agnostic. A protocol with a mixed byte order writes the exceptional field with `std.mem.writeInt` directly.

## Handle a full buffer

Every fallible method has two forms. The checked form returns `error.NoSpaceLeft`. The `AssumeCapacity` form asserts the bound: it panics in Debug and ReleaseSafe, and ReleaseFast removes the check. Use the checked form when the size depends on input. Use the unchecked form when a prior check or a fixed maximum proves the fit.

## Know the limits

The writer writes fixed-width integers and enums, byte slices, and slots. It does not write varints, bit-packed fields, or a different byte order per field. A protocol that needs those writes the field with `std.mem` or its own codec.

# Base32

`base32` is a Crockford base32 codec for fixed-shape machine tokens. std has base64 and no base32. A token carries a binary key whose length is a positive multiple of 5 bytes. The token is exactly `8 * N / 5` lowercase symbols for `N` bytes, so it has no padding and a fixed length.

Both directions take the byte count as a comptime parameter. `base32.encode(10, &key)` returns a `[16]u8`, and `base32.decode(10, &token)` returns a `[10]u8`. `base32.SymbolCount(N)` names the token type for a field declaration. It rejects a count that is not a positive multiple of 5 at compile time.

The wire form is lowercase only. `encode` emits the lowercase Crockford alphabet, which excludes `i`, `l`, `o`, and `u`. `decode` rejects every byte outside that alphabet: uppercase letters fail, and the excluded letters fail in lowercase too. There is no case folding and no `O`/`I`/`L` alias table, so two spellings never decode to one key.

`decode` returns `error.InvalidSymbol` on the first bad byte. A token that decodes is valid by construction, so the decode itself is the validation. The caller runs no separate symbol check, and the fixed shape means the decode needs no length check either.

```zig
{{ load_data(path="examples/base32_token.zig", format="plain") | trim_end }}
```

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

## Carry an address and a port

`net.Ip4Endpoint` is four octets and a port in 6 bytes: the value shape without the sockaddr padding that std's `Ip4Address` carries. Use it in per-connection records and in code that owns a raw fd and calls `bind(2)` or `connect(2)` directly. `toSockaddrIn` returns the kernel struct with the port in network order. `parse` takes the address text and the port separately. `HostPort.parse` handles config text that carries both. `toStd` and `fromStd` convert to and from `Ip4Address`.

## Parse a host and port

`net.HostPort.parse` splits endpoint text such as `example.com`, `10.0.0.1:853`, or `[2001:db8::1]:853`, with a caller-supplied default port. It removes the brackets from an IPv6 host. It rejects an empty host, an empty port, port 0, a port above 65535, and an unbracketed IPv6 address. The host is not validated as a name or an address; that stays caller policy.

```zig
{{ load_data(path="examples/net_host_port.zig", format="plain") | trim_end }}
```

## Work with a raw socket fd

`posix.setsockopt` and `posix.getsockopt` set and read a one-`c_int` socket option on a raw fd. Both decode errno to named errors. `error.InvalidOptionValue` is EINVAL. std's own `posix.setsockopt` maps EINVAL to `unreachable`, so a bad option value from configuration has no error path. The stdx wrapper returns `error.InvalidOptionValue` instead. `posix.getsockname` and `posix.getpeername` return the local and peer `net.Ip4Address` of a socket, with no caller-supplied `sockaddr` buffer.

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

## Write an RFC 3339 timestamp

`time.writeRfc3339` writes an `Io.Timestamp` as UTC RFC 3339 text. The fractional width is a comptime parameter: `.seconds`, `.milliseconds`, `.microseconds`, or `.nanoseconds`. The value is truncated to that width, so the output has a fixed shape that sorts and parses without a variable fraction.

```zig
{{ load_data(path="examples/time_rfc3339.zig", format="plain") | trim_end }}
```

The full 0000-9999 year range is supported, including dates before 1970. A year outside the range returns `error.TimestampOutOfRange`.

## Limit a repeated log line

A failure that repeats for each connection can write one line per event. `RateLimit` admits one line per interval. It returns the number of lines that it held back, so the one line can report them.

```zig
{{ load_data(path="examples/time_rate_limit.zig", format="plain") | trim_end }}
```

`admit` returns `null` when the caller must hold the line back. Pass it a monotonic sample, such as `clock.now()` from a `CachedClock(.awake)`.

`RateLimit.default` has a one-second interval. `RateLimit.init` takes any `Io.Duration`.

# Timers

One operation does not need a set: every std wait already takes an `Io.Timeout`, and a `.deadline` in that value is the whole story. Use `timers.Timers` when one loop owns many deadlines. Each entry carries a calflback, removal is by handle, and a period repeats the fire.

The collection owns no clock and no wake machinery. The loop samples the clock with `timex.now(.awake)`, calls `expire(now)` to fire everything due, and sleeps until `next()`. The entries are caller-owned: the caller constructs a `Timer`, standalone or embedded in a connection record, and `arm` links it. Nothing is allocated, and the node pointer is the handle. One loop owns the set: no method is thread-safe, and no atomics are involved.

## Drive the loop

`expire(now)` fires every timer due at or before `now`, earliest first. The loop then sleeps toward `next()` with `Io.Timeout{ .deadline = wake }`. A null `next()` means nothing is armed, and the loop sleeps on its other events. A callback runs after the tree surgery on its own entry, so it can arm, reset, or stop any timer, including its own. After every callback, `expire` re-checks the minimum, so a past-due timer armed from inside a callback fires in the same drain.

`stop` and `reset` follow Go's `Timer`: each returns false for a timer that already fired or was stopped. Nothing is delivered outside `expire`, so there is no channel to drain and no stale delivery to reason about.

```zig
{{ load_data(path="examples/timers_loop.zig", format="plain") | trim_end }}
```

## Repeat on a period

A `Timer` with a `period` is Go's `Ticker`: it re-arms on every fire. The next deadline is the fired deadline plus the period, never the wake time. A late `expire` does not shift the schedule, so drift does not accumulate.

The callback decides the next fire: return `.rearm` to keep the timer going, or `.disarm` to let it die from inside its own fire. The callback runs between the fire and the re-arm, so it sees the entry disarmed and the decision pending. A callback that re-arms its own timer wins over its returned `.rearm`.

## Recover the record

A callback is typed. Its first parameter is a pointer to the record that embeds the `Timer`. The wrapper recovers the record with `@fieldParentPtr`, so the record's field must be named `timer`. A `void` first parameter arms a bare timer. `Timer.disarm` is the ready-made callback for a timer whose fire is observed through `armed` and `next()`.

The wrapper inlines the typed body into the erased callback, so a fire costs one function-pointer indirection. A callback that frees its own record must return `.disarm`.

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

# Small modules

These modules are small enough that the contract fits in a paragraph. The [module list](#modules) has the one-line summary, and the [API reference](api/) has every symbol.

## Bound a response

`BoundedWriter` is an accumulating `Io.Writer` over a buffer that it allocates from your allocator. It has the semantics of `Io.Writer.Allocating` with a ceiling: a write that would push the buffered bytes past `limit` returns `error.WriteFailed`. The bytes written before it stay, and the buffer never holds more than the limit.

Use it when input that you do not control feeds a fixed-size response, such as a JSON body. `written` returns the buffered bytes, and `deinit` frees the buffer.

```zig
{{ load_data(path="examples/bounded_writer_response.zig", format="plain") | trim_end }}
```

## Hash a key

`hash.RapidHash` is rapidhash V3: 64-bit, non-cryptographic, and seeded. Its output reproduces upstream's reference values on every host, so a hash is stable across builds.

`hash(seed, input)` is the 7-lane variant and a drop-in for `std.hash.Wyhash.hash`. `hashMicro` and `hashNano` are the smaller variants for short inputs. They return the same value as `hash` up to 80 and 48 bytes, and diverge after that.

`RapidHash.StringContext` and `RapidHash.AutoContext(T)` are std-style contexts. Pass one as the context of `swiss`, `bounded_array_hash_map`, or any std map. `StringContext` hashes string contents. `AutoContext` walks a key the way `std.hash.autoHash` does, and it rejects slices.

```zig
{{ load_data(path="examples/hash_keyed_map.zig", format="plain") | trim_end }}
```

## Pool fixed-size records

`heap` has two pools for records that come in known sizes.

`SlabAllocator(.{ .size_classes = ... })` has the allocator shape. `alloc` takes the gpa and a size, rounds the size up to the first class that fits, and returns a pointer. `free` takes the same size back. A size above every class is a normal allocation from the same gpa, and `free` returns it the same way. `deinit` takes the gpa, and in Debug and ReleaseSafe it asserts that every allocation was freed first. `queryCapacity` reports the pooled capacity.

`alloc` panics when the gpa cannot serve it. It has no error return, so a caller that must handle allocation failure uses `SizeClassPool` or a plain allocator.

`SizeClassPool(&.{ 16, 64, 256 })` carves its classes, free lists, and metadata from one caller-owned backing. `create` returns a byte slice of the requested length, and a request above the largest class returns `error.OutOfMemory`. `destroy` takes the slice back unchanged.

```zig
{{ load_data(path="examples/heap_slab_records.zig", format="plain") | trim_end }}
```

## Fixed-size byte values

`mem.Array(N)` wraps `[N]u8`, with the length in the type. `init` takes the bytes, `zero` is an initialized all-zero value, and `secureZero` clears the bytes in a way that the optimizer cannot remove. Use it for keys and other secrets.

The module also adds vectorized scans. `findScalarLast` walks backwards and `findAny` walks forwards; both match the std function of the same name and return the same index. `lastIndexOfNonZero` has no std equivalent.

```zig
{{ load_data(path="examples/mem_secret.zig", format="plain") | trim_end }}
```

## Random bytes

`random.fill` writes secure random bytes with no `Io` value and no error. Each thread owns a ChaCha generator, seeded on its first call from the platform's secure source: `getrandom` on Linux, `arc4random_buf` on macOS. Later calls take no syscall and no lock. A failed seed panics, because no fallback keeps the guarantee.

The module compiles on Linux and macOS only.

```zig
{{ load_data(path="examples/random_token.zig", format="plain") | trim_end }}
```

## Write to stdio

`stdio.err` and `stdio.out` are ready on import. There is no init and no allocator. `print` formats like `Io.Writer.print` and appends no newline. No method returns an error: the first failed write latches, and later writes on that stream drop.

Output is buffered, so call `stdio.flush()` before exit. A panic never reaches the buffer, so panic reporting stays with `std.debug.print`. The streams ride `std.Options.debug_io`, which supports one thread only.

```zig
{{ load_data(path="examples/stdio_stream.zig", format="plain") | trim_end }}
```

## API reference only

Two modules in the table have no example here. `posix` is described under [Work with a raw socket fd](#work-with-a-raw-socket-fd). `pages` is API reference only: it releases whole kernel pages with `MADV_DONTNEED`, and it depends on the Linux zero-fill guarantee for the next touch. That guarantee has no Darwin equivalent, so the module is Linux only by design.
