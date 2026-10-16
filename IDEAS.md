# IDEAS

Parking lot for stdx candidates. The bar (AGENTS.md): std genuinely
lacks it, general purpose, pasted in ≥2 projects. An idea leaves this
file when it ships or dies.

## Queues

The one family std has nothing for — verified against 0.16: `std`
has priority queues and nothing concurrent.

### MPSC slot ring — SHIPPED as `slot_ring.Mpsc` (2026-10-15)

Landed beyond the port: Vyukov per-slot stamps replace the originals'
fetchAdd+written-word core (a stamp = lap<<32|len is the lease, the
commit, and the release in one word — the originals could hand the same
physical slot to two producers and torn-read a lapped consumer); the
claim is a CAS so a refused claim burns no position; `on_full` is a
comptime policy (.drop_new, .drop_oldest with CAS-before-copy reads —
the two-reviewer consensus, crossbeam pop verbatim); the wake is a
comptime flavor (.none/.eventfd/.futex), and the eventfd poke is gated
on an armed waiter bit (zero syscalls disarmed, ~19ns RMW). Twelve-13ns
round trip, asm-diffed stable across every change; perf stat counters;
44 tests + Smith fuzzers + seeded chaos hammers; two clean 5M soaks.
Integration into handoff (.eventfd, main's poll loop) and exosphere
(.futex, dedicated consumer thread) landed clean on 2026-10-15 —
both consumers integrated without stdx changes, which was the port's
acceptance test.

`AtomicRingBuffer` in exosphere (`src/AtomicRingBuffer.zig`, 633
lines, std-only in that copy), pasted in psbouncer and the red-team
harness. The strongest ≥2-projects case in the package.

Shape: fixed slot array, power of two. Producers acquire a slot by
atomic fetchAdd on a monotonically increasing head, write into the
slot (which hands out an `Io.Writer`), commit with a release store
of the length into the slot's `written` word. One consumer reads
sequentially by slot index, clears slots with release stores. The
wake protocol carries an armed-waiter bit inside the wake generation
word itself — the Linux futex waiter-bit pattern, so wakes cannot be
lost. Hot state gets its own cache-line-aligned struct.

Open questions:

- Allocator retention: the slot array is allocated once at `init`;
  the slab precedent says pass the allocator per call instead.
- Io coupling: futex wait/wake lives behind `Io` in 0.16; the
  exosphere ring takes the caller's `Io.Threaded` at init.
- Naming and home: a queue package with flavors, or one file named
  for the type.

### SPSC ring — design when needed

Single-producer ring with no atomic slot allocation at all (the one
producer owns the head); acquire/release fences only. The MPSC ring
degenerates to this with one producer, but a dedicated SPSC is
faster. No pasted user yet — design it when something needs it.

### MPMC — not yet

Vyukov's bounded MPMC array. Real work, no user. Parked.

## pages — SHIPPED as `pages` (from handoff)

The strongest handoff bring-in: `allocator`/`size`/`reserve`/
`unreserve`/`whole`/`release`, exactly the "low-level primitives Zig
is missing" framing. Four general contracts: page-exact geometry
(no heap header offset, pages share no tenants), lifetime past cleanup
(no state to deinit behind a detached thread), a free that returns pages
(munmap hands a scratch page back; arena frees do nothing non-LIFO),
and ceiling-scale untouched reservation (no allocator undefined-fill
touching a slot-space-sized mapping wholesale). Tests already generic:
4-page block, edge bytes preserved, zero-refill. Composes with
heap.SlabAllocator (page-backed slab story).

Porting: strip the D13/D20/D38/D43/D44 and handoff-specific references
(watchdog, log ring, sink, Server) — state the four contracts in stdx
terms. `release` is raw `linux.madvise(MADV.DONTNEED)` — Linux-only
as written; the portability pass time got: the comptime platform
guard, plus a macOS verification of MADV_DONTNEED's zero-refill
semantics on anonymous memory (Darwin's man page wording needs
checking; if Darwin does not guarantee zero-fill, the doc must say
what it does guarantee per-OS).

## RateLimit — SHIPPED as `time.RateLimit` (from handoff)

`admit(now: Io.Timestamp) ?u32`: null = hold the line, a count = log
it with the lines held back since the last. ~40 lines, saturation
tested (u32 saturating, i64 interval math). Every long-running process
logs recurring conditions; the smallest genuine win. Home: next to
time — `src/time/rate_limit.zig`, re-exported from time.zig; the
`Io.Timestamp` parameter composes with `time.now(.awake)` and
`CachedClock` samples directly. `interval_ms: i64` default 1000,
next_ms/suppressed fields — file-as-a-struct, nearly as-is.

## Set — SHIPPED as `set`

`V = void` works in both maps today; what's missing is set
vocabulary and algebra. Thin wrapper composing
bounded_array_hash_map (the bloom precedent), in-place algebra
needs no allocation: `intersect(other)`, `unite(other)`,
`subtract(other)` — iterate self, contains-check against other.
Queries: `subsetOf` / `supersetOf` / `disjointWith`.
`set.Custom/Auto/String` family shape over the map's primitives.

## Static map — SHIPPED as `static_map`

std covers strings (`StaticStringMap(V)` — `initComptime`, length-
bucketed, comptime-generated, zero runtime init; `StaticStringMap(void)`

- `has` IS the static string set — don't build it) and dense enums
  (`EnumMap`); sparse non-string keys (opcode tables, protocol
  constants) have nothing. The stdx version: a comptime instantiation
  of the bounded map's own Robin Hood probe logic — the table built at
  comptime from a literal, immutable, in `.rodata`, zero init. Same
  algorithm, built during compilation — the StaticBitSet pattern bloom
  already composes with.

## BTree — ordered map, pending a real use case

Rust ships `BTreeMap` for sorted iteration and range queries
(floor/ceiling/range) over a comparator — what neither the robin
(insertion-ordered) nor swiss (slot-ordered) maps give. Biggest item
in this conversation's class; only worth building if a use case
actually wants sorted iteration or range queries. Rust envy is not
a gap.

## Timer set

Not the clock — that's `std.Io.Timestamp`. Not per-op deadlines —
that's `Io.Timeout`, which every std wait already takes. The missing
piece is a collection: insert N deadlines, cancel by handle, pop
expired as the clock advances. Go's runtime carries one internally;
the red-team harness `timer_set` is 18K lines welded to xev. A stdx
version is a pure data structure over `Io.Timestamp` values — the
caller drives ticks from whatever owns the clock. Design from
scratch.

## InternPool — Go `unique` (1.23)

Go added `unique.Handle[T]` for hash-consing: intern a value,
compare handles by identity. The red-team harness has one (fastmem
and tracy coupled). Exosphere's refcounting/unique-ing may not be
general enough to extract — look before deciding.

## Smaller

- Read-cursor buffer: pos+len over caller storage (the harness
  `IoBuffer` shape), `buffer.Slice`'s cousin. Mechanical port when
  wanted.
- base32: SHIPPED as `base32` (2026-10-15) — generalized fixed-shape
  Crockford codec over any positive multiple-of-5 byte count,
  lowercase-only both directions, decode-is-the-validation (#4).
- Ip6 variant of net: open, deliberately deferred.
- Compile-fail test steps for the `@compileError` paths (build
  test infra, not a data structure).

## memchr (the Rust crate) — split verdict

Checked against 0.16: std's `findScalarPos` is already vectorized for
int/float elements (the block-loop `@Vector` pattern), so the crate's
headliners are half covered.

- memrchr: real gap — std's `findScalarLast` is a scalar backwards
  loop. Same std pattern as `trimEnd`/`lastIndexOfNonZero`: forward
  vectorized, backwards forgotten. A vectorized memrchr is
  `lastIndexOfNonZero` with the predicate generalized to
  equals-this-byte. mem-sized.
- memchr2/memchr3 (first of 2-3 alternative bytes, the parser-delimiter
  workhorse): verified gap — std's `findAnyPos` is a nested scalar
  loop, O(n·k). The general vectorization: per block, one broadcast
  compare per alternative, OR the masks — works for any k, not just
  2-3; the crate special-cases 2-3 because that is what parsers need.
- memmem (substring search, SIMD prefilters, Two-Way fallback):
  fastmem-shaped — arch-named impls, thin dispatch, the bench/asm
  infrastructure fastmem already has. Belongs beside memcpy/memset,
  not in mem.

License check if ported: BurntSushi's memchr is permissive dual
(verify the exact pair before transcribing any constants).

## Allocators (checked)

std 0.16 covers the C canon already: `DebugAllocator` (GPA —
malloc-with-debugging), `ArenaAllocator` (region), `FixedBufferAllocator`
(bump over caller storage), `PageAllocator`, `MemoryPool` (fixed-T
pools), and `SmpAllocator` — the important one: tcmalloc-shaped, so
the fast-general-purpose lane is std's, not ours. heap.SlabAllocator
builds on the pools.

Genuine C-classic gaps, zero users — bench-idea parking only:

- TLSF: two-level segregated fit, O(1) alloc/free with fragmentation
  bounds — the embedded/console allocator.
- Buddy: power-of-two split/merge — kernel-shaped.

From our repos:

- handoff `SlotStack` (LIFO free-index stack): clean and tested, but
  `seed`/`retainBelow` are connection-table vocabulary (D42/D43).
  The generalizable core is the pool-bookkeeping primitive slotmap
  wants — revisit with slotmap, not a port now.
- handoff `Slab` is a different concept entirely (page-backed per-slot
  kernel mappings), not a divergent copy of heap.SlabAllocator — no
  rot to converge.

## Swiss hash map — SHIPPED, measured slower than the incumbent

`swiss.Custom`/`Auto` landed: Abseil's control-byte encoding,
comptime group width, triangular probes with mirrored control bytes,
always-tombstone removal, Abseil's swap-and-repeat compaction,
differential anchors vs std. But the bench this entry demanded
measured the opposite of the pitch: at 83% load, u64 and 32-byte
keys, `bounded_array_hash_map.Auto` wins — hit 2.39 vs 2.76 ns, miss
1.59 vs 2.00 ns (u64), same ratios at 32-byte keys. Structural:
robin's index header carries a 64-bit hash fingerprint per slot, so
probes promote to key compares ~never; swiss's 7-bit H2 promotes on
~1/128 candidates and SIMD screening of 16 lanes does not pay for
it. The niches that remain: slot-order iteration (not insertion
order), no per-entry hash storage (less memory), and workloads not
yet measured. Do not assume swiss is the fast one.

std has no SwissTables anywhere (verified): std.hash_map is
tombstone-based open addressing with per-slot fingerprint metadata;
std.array_hash_map is the Robin Hood we just shipped bounded.

The design: control groups (7 bits of hash + state tag per byte),
SIMD byte-match screens a whole group per probe step, tombstone
deletion kept cheap by the same walk. References to pull from:

- hashbrown (Rust std's map — the Group/ctrl SIMD core)
- Go 1.24's runtime swiss map (runtime/internal/swiss — its
  8-byte groups and the reasons for half-size)
- Abseil flat_hash_map (the original — growth and probe policy)

Two variants, both worth having:

- Bounded (the bounded_array_hash_map.Auto sibling): fixed capacity — but
  Swiss has no distance field, so backward-shift deletion is
  impossible and tombstones would rot a never-rehashed table; the
  bounded variant needs in-place rebuild-on-tombstone-threshold.
  That rebuild policy is the genuinely new design work.
- Resizable (unmanaged, allocator-per-call, the std.hash_map
  sibling).

The bar before shipping: differential anchors vs std (behavioral)
and a probe-bound bench vs array_hash_map.Auto (performance) —
group screening has to beat the Robin Hood walks we already have,
measured, not assumed. Composes with the repo's existing SIMD
idioms — the compare-and-find-bits pattern already shipped in mem
three times.

## Bloom filter — SHIPPED as `bloom`

Needed before (real user, predates stdx). Nothing in std (verified
against the container surface audit). The heapless family's purest
member: fixed capacity, allocation-free, and the best comptime
showcase in the pile — optimal-parameter math (`m =
-n·ln p/(ln 2)^2`, `k = (m/n)·ln 2`) computed at comptime from
`Bloom(T, expected_items, false_positive_rate)`, storage an
embedded `std.StaticBitSet(m)` (std composition, not a hand-rolled
bit array). Double hashing (Kirsch–Mitzenmacher: index_i =
h1 + i·h2) for k probes from two hash halves — one Wyhash call,
split. API: `add`, `contains`, `clear`, `count`, comptime `p`
surfaced as a constant. Probabilistic contract documented: no
false negatives, `p` false positives at capacity.

## rapidhash — SHIPPED as stdx.hash.RapidHash

The current fast non-crypto general-purpose hash (wyhash lineage,
SMHasher-verified) — the one projects adopt over xxhash3 when
hash throughput matters. std's default is `std.hash.Wyhash`, and
`AutoContext` hashes everything through it, so the comparison
baseline is in-tree: bench-first — a port must beat Wyhash on the
probe-bound workloads (the swiss maps above are exactly that
consumer) before it earns a hashx module. Verify the upstream
license before porting any constants.

## SlabArena — malloc over a fixed region (memcached's model)

The sharpened spec: a general-purpose `mem.Allocator`-shaped allocator
working entirely from a caller-owned region — "here is `[100MB]u8`,
work with this space." No OS reclamation ever: the economy is closed,
pages move between size classes only, insight comes from exposed
metrics instead. This is memcached's actual model, minus its object
semantics.

Verified shape:

- Class ladder generated at init, runtime not comptime: `chunk =
base × factor^i` (base ~64, factor ~1.25) up to page/2, then
  single-chunk pages; oversize → honest `error.OutOfMemory`. Kills
  the comptime-tier granularity complaint against heap.SlabAllocator.
- Per-page free lists threaded through free chunks; per-page live
  counts; page becomes reclaimable at count zero. No per-chunk
  headers needed for routing — Zig's typed `free` hands back size and
  alignment; `page_id` from address math (the SlotSpace trick).
- Self-hosted tables: the page table lives in the first pages of the
  region. Zero external state, no retained allocator, no deinit story.
- Alignment manufactured, not inherited: comptime alignment param,
  strides rounded to it, storage declared `align(N)` — the
  buffer.Array aligned pattern at allocator scale. Page size a comptime
  param (power-of-two stride over the array).

The fork, stated:

- vtable face is non-moving — the mem.Allocator contract promises
  stable addresses, so evacuation can never happen through it.
  Empty-page reclaim only; the slab trap (immortal sprinkled items
  pinning pages) accepted.
- engine face owns the mover, memcached 2009 inheritance: drain a
  sparse page (free-list walk → bitmap, complement is live), evacuate
  same-class destinations (plain memcpy — every chunk in a page is
  the same size), caller move-hook fixes pointers. The cache engine
  cooperates; the vtable cannot.

Open: mover or empty-pages-only (does the use case churn or
accumulate immortals?); thread model (single-owner first is a very
different cut); metrics surface shape. First cut without the mover is
a few hundred lines in patterns this repo has already shipped.

## testingx — checked off, rejected

std.testing 0.16 already covers the would-be pitch: `tmpDir`, string
diffing inside `expectEqualSlices` (`BytesDiffer`),
`checkAllAllocationFailures` (fault-injection testing, better than
Go's), `Smith` structured fuzz input, and mock `Io.Reader` doubles with
call recording.

The one real gap was benchmarks — no `std.bench` — and that home is
already taken: github.com/mattrobenolt/zig-benchmark (the fastmem
precedent: specialist packages stay separate, stdx stays thin).

testify: rejected — its assert/require split exists because Go's
helpers don't return errors; Zig's `try` is `require`. The mock/suite
machinery fights the inline-test idiom.

## From the Rust ecosystem

Rust's std is thin by design, so the crate ecosystem is a decade's
worth of evidence about what a std lacks. The extraction bar still
applies at port time — most of these have no user in our repos yet.

### Channel family beyond MPSC (tokio)

Once the MPSC slot ring lands, the reference set is tokio's:

- oneshot: single-use, single-value, completes once. The natural
  sibling — every handshake/result-wait shape is a oneshot.
- broadcast: fan-out to many consumers, each with its own cursor;
  slow consumers skip rather than block. The notification pattern
  Go's runtime uses internally.
- watch: single latest value plus change notification — a condvar
  with content. Setters never block, laggards converge.
- crossbeam's ArrayQueue/SegQueue: the parked MPMC, bounded and
  unbounded, Vyukov's flavors.

### once_cell (the sneaky one)

Zig 0.16 removed `std.once` outright. `OnceCell` — set once, read
many — and `Lazy` — init on first use — have no std story at all,
and once_cell is one of the most-downloaded crates in Rust. Design
question: plain single-threaded cells vs thread-safe versions
over `Io.Event`.

### slotmap — generational arena

Key = slot index plus generation, so freed handles can't alias live
ones (no ABA). Fixed capacity, no allocation, fits stdx DNA — and
the style guide already blesses generations as deliberate
wraparound semantics. The games/entity world runs on these.

### Chase-Lev work-stealing deque (crossbeam-deque)

Each worker owns a deque and steals from others' tails — the
worker-pool shape (the red-team harness `worker.zig` is this
shape). Design-heavy, no user yet.

### heapless — fixed-capacity everything

The crate closest to stdx's DNA: fixed-capacity, allocation-free
containers. Status after the std-overlap audit:

- Deque: ABSORBED BY STD — `std.Deque` with `initBuffer` (caller
  storage) plus `pushFrontBounded`/`pushBackBounded` is the whole
  fixed-capacity deque. Do not build a copy.
- BinaryHeap: SHIPPED as `priority_queue.Custom` — std.PriorityQueue's
  exact surface (Order comparator + context, pop/popIndex/update,
  storage-order iterator) with the capacity comptime and the array
  embedded; `NoSpaceLeft` on full. Differential anchors against
  std.PriorityQueue drain identically, min and max comparators.
- IndexMap/IndexSet: SHIPPED as `array_hash_map.Auto` (auto
  context) and `array_hash_map.Custom` (custom context) — a
  faithful Robin Hood port of std.ArrayHashMap: same index-slot
  layout, backward-shift deletion, ordered/swap entry compaction,
  insertion-order iteration; `V = void` covers the set. Differential
  anchors run identical op sequences against std's and assert
  equivalence after every step.
