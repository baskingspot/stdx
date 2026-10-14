# IDEAS

Parking lot for stdx candidates. The bar (AGENTS.md): std genuinely
lacks it, general purpose, pasted in ≥2 projects. An idea leaves this
file when it ships or dies.

## Queues (current focus)

The one family std has nothing for — verified against 0.16: `std`
has priority queues and nothing concurrent.

### MPSC slot ring — port candidate

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
  `IoBuffer` shape), `SliceBuffer`'s cousin. Mechanical port when
  wanted.
- base32: a general Crockford codec — std has base64 only. The
  harness one is stable-token-specific; a rewrite, not a port.
- Ip6 variant of netx: open, deliberately deferred.
- Compile-fail test steps for the `@compileError` paths (build
  test infra, not a data structure).
- Publish docs to Cloudflare Pages from CI (`just doc` exists;
  assets are static, `sources.tar` 16.2MB near the 25MB per-file
  limit).

## memchr (the Rust crate) — split verdict

Checked against 0.16: std's `findScalarPos` is already vectorized for
int/float elements (the block-loop `@Vector` pattern), so the crate's
headliners are half covered.

- memrchr: real gap — std's `findScalarLast` is a scalar backwards
  loop. Same std pattern as `trimEnd`/`lastIndexOfNonZero`: forward
  vectorized, backwards forgotten. A vectorized memrchr is
  `lastIndexOfNonZero` with the predicate generalized to
  equals-this-byte. memx-sized.
- memchr2/memchr3 (first of 2-3 alternative bytes, the parser-delimiter
  workhorse): verified gap — std's `findAnyPos` is a nested scalar
  loop, O(n·k). The general vectorization: per block, one broadcast
  compare per alternative, OR the masks — works for any k, not just
  2-3; the crate special-cases 2-3 because that is what parsers need.
- memmem (substring search, SIMD prefilters, Two-Way fallback):
  fastmem-shaped — arch-named impls, thin dispatch, the bench/asm
  infrastructure fastmem already has. Belongs beside memcpy/memset,
  not in memx.

License check if ported: BurntSushi's memchr is permissive dual
(verify the exact pair before transcribing any constants).

## Allocators (checked)

std 0.16 covers the C canon already: `DebugAllocator` (GPA —
malloc-with-debugging), `ArenaAllocator` (region), `FixedBufferAllocator`
(bump over caller storage), `PageAllocator`, `MemoryPool` (fixed-T
pools), and `SmpAllocator` — the important one: tcmalloc-shaped, so
the fast-general-purpose lane is std's, not ours. heapx.SlabAllocator
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
  kernel mappings), not a divergent copy of heapx.SlabAllocator — no
  rot to converge.

## Swiss hash map — hashbrown / Go 1.24 / Abseil lineage

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
- Bounded (the array_hash_map.Bounded sibling): fixed capacity — but
  Swiss has no distance field, so backward-shift deletion is
  impossible and tombstones would rot a never-rehashed table; the
  bounded variant needs in-place rebuild-on-tombstone-threshold.
  That rebuild policy is the genuinely new design work.
- Resizable (unmanaged, allocator-per-call, the std.hash_map
  sibling).

The bar before shipping: differential anchors vs std (behavioral)
and a probe-bound bench vs array_hash_map.Bounded (performance) —
group screening has to beat the Robin Hood walks we already have,
measured, not assumed. Composes with the repo's existing SIMD
idioms — the compare-and-find-bits pattern already shipped in memx
three times.

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
  the comptime-tier granularity complaint against heapx.SlabAllocator.
- Per-page free lists threaded through free chunks; per-page live
  counts; page becomes reclaimable at count zero. No per-chunk
  headers needed for routing — Zig's typed `free` hands back size and
  alignment; `page_id` from address math (the SlotSpace trick).
- Self-hosted tables: the page table lives in the first pages of the
  region. Zero external state, no retained allocator, no deinit story.
- Alignment manufactured, not inherited: comptime alignment param,
  strides rounded to it, storage declared `align(N)` — the
  ArrayBufferAligned pattern at allocator scale. Page size a comptime
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
- BinaryHeap: SHIPPED as `priority_queue.Bounded` — std.PriorityQueue's
  exact surface (Order comparator + context, pop/popIndex/update,
  storage-order iterator) with the capacity comptime and the array
  embedded; `NoSpaceLeft` on full. Differential anchors against
  std.PriorityQueue drain identically, min and max comparators.
- IndexMap/IndexSet: SHIPPED as `array_hash_map.Bounded` (auto
  context) and `array_hash_map.BoundedWith` (custom context) — a
  faithful Robin Hood port of std.ArrayHashMap: same index-slot
  layout, backward-shift deletion, ordered/swap entry compaction,
  insertion-order iteration; `V = void` covers the set. Differential
  anchors run identical op sequences against std's and assert
  equivalence after every step.
