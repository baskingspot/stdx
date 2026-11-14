# A URL parser: what std.Uri is, what ada-url gives, and what a port costs

2026-11-14. The question: is a better URL parser than `std.Uri` worth
building, with ada-url (<https://github.com/ada-url/ada>, MIT/Apache-2.0) as
the model?

Short answer: `std.Uri` is not a worse version of ada; it is a different
contract, deliberately. The contract it does not implement is worth having,
and a port of ada's algorithm is cheap — the prototype in `src/uri.zig` is
677 lines of code. The parts worth stealing are smaller than the parser, and
the part that makes full conformance expensive is IDNA, not the state
machine.

## Two contracts, not two implementations

`std.Uri` says so itself: parsing "roughly adhering to RFC 3986. Does not do
perfect grammar and character class checking, but should be robust against
URIs in the wild."

Upstream is deliberate about this. `std.Uri` came from zig-uri, which was
built from RFC 3986 step by step (ziglang/zig#14176). When asked to make
`std.Uri` node-shaped, its author answered: "we should not replicate nodejs,
but stick closely to the RFC terms... Using `std.Uri` for HTTP is only one use
case of many" (ziglang/zig#14512). That is the RFC contract: split the
reference into components, leave the bytes alone, allocate nothing, accept
what RFC grammars allow.

The WHATWG contract is the other one, and it is not a superset:

- The output is a **serialization**, not the input. Scheme and host are
  lowercased, the default port disappears, dot segments are removed, unsafe
  bytes are percent-encoded, IPv4 hosts are canonicalized, IPv6 hosts are
  compressed.
- Input that is not a URL is an error, not a best-effort split.
- Special schemes (`http`, `https`, `ws`, `wss`, `ftp`, `file`) have their own
  grammar: backslash is a separator, `//` is optional after the scheme, an
  empty host is fatal.
- Resolution against a base is part of the parser, not a separate function.

Both are legitimate. They disagree on input people actually send, and when
two parsers in one system disagree, the disagreement is the vulnerability.
Four cases, measured with `std.Uri` on Zig 0.17.0 and Node 24 (`new URL`):

| input                           | `std.Uri` host | browser host  | browser href                    |
| ------------------------------- | -------------- | ------------- | ------------------------------- |
| `http://example.com\@evil.com/` | `evil.com`     | `example.com` | `http://example.com/@evil.com/` |
| `http://0x7f.1/`                | `0x7f.1`       | `127.0.0.1`   | `http://127.0.0.1/`             |
| `http://münchen.de/`            | `münchen.de`   | punycode      | `http://xn--mnchen-3ya.de/`     |
| `http://example.com/%2e%2e/x`   | path as sent   | `/x`          | `http://example.com/x`          |

The first is the allowlist bypass: a server that checks the host against a
list, and a browser that navigates the same string, name different hosts. The
second is the SSRF variant: any allowlist that special-cases `127.0.0.1`
misses `0x7f.1`, `127.1`, and `2130706433`, all of which resolve there. The
third is the opposite failure: a legitimate URL the client cannot use at all,
because `std.Io.net.HostName.validate` rejects non-ASCII.

## Conformance, measured

The WHATWG test corpus (`urltestdata.json`) is 904 cases, 270 of which must
fail to parse. Run each case, compare the expected `href` byte for byte.

| parser                                      | exact | wrong serialization | rejected valid | accepted invalid |
| ------------------------------------------- | ----- | ------------------- | -------------- | ---------------- |
| ada 4.0.0 (C API, `-O2`)                    | 904   | 0                   | 0              | 0                |
| `std.Uri` + a faithful component serializer | 287   | 364                 | 19             | 228              |

The 228 accepted-invalid inputs, by what the spec rejects:

| count | class                                                                    |
| ----: | ------------------------------------------------------------------------ |
|    68 | a percent escape in the host, or a byte it decodes to, that is forbidden |
|    38 | a C0 control or space anywhere in the input                              |
|    33 | an invalid IPv6 literal (`[1::2]:3:4`, `[::127.0.0.1.]`, `[]`)           |
|    28 | other (mostly `%` in a host, and `[`/`]` outside a literal)              |
|    20 | a relative reference with no valid base                                  |
|    14 | an IPv4 host out of range (`192.168.0.257`, `1.2.3.4.5`)                 |
|    10 | a raw forbidden host code point (`<`, `>`, `\`, `^`, `\|`)               |
|     9 | a non-ASCII host that must fail (`\ufdd0`, fullwidth `％`)               |
|     6 | an empty host with credentials or a port (`http://user:pass@/`)          |
|     2 | `file:` rules (a port, a percent escape)                                 |

The 364 serialization differences are the normalization list: scheme case,
default ports, dot segments including `%2e` forms (30), bytes that need
percent-encoding (37), tabs and newlines (17), host case (6), IPv4
canonicalization (11), IPv6 compression, empty userinfo, and relative-path
merging (127).

The 19 valid inputs `std.Uri` refuses are a short list: `http://f:/c` (an
empty port), `foo://` (an empty non-special host), `file://`, and input with
tabs, newlines, or a leading control byte.

None of this is a bug report against `std.Uri`. It is the size of the other
contract.

## The prototype

`src/uri.zig` implements the algorithm from scratch, following the spec that
ada implements: one pass over the input, writing the serialization into the
caller's buffer and returning spans into it. It is 677 lines of code,
including the IPv4 number parser, the IPv6 parser and serializer, the six
percent-encode sets as comptime byte tables, and the path shortener.

Not implemented, on purpose: IDNA (a non-ASCII host is
`error.IdnaUnsupported`), base resolution, `file:`, and the non-special `..`
rule that inserts `.` so a path cannot start with `//`.

Against the 701 WPT cases with an absolute input: 655 pass, 6 are rejected
that should parse, 27 differ in serialization, and 13 are IDNA. The residue
is `file:` and the `..` rule. Every case that motivated the exercise behaves
like a browser, including the four in the table above.

## Performance

aarch64-linux, Neoverse V3, Zig 0.17.0 `ReleaseFast`; ada 4.0.0 amalgamation,
g++ `-O2`, through its C API. hyperfine, 10 runs, 3 warmups, times divided by
the parse count.

Corpus A: the 446 WPT inputs the prototype parses, plus 11 realistic URLs.
Corpus B: 10 realistic URLs. Both corpora are the same for all three parsers.

| parser                  | A, ns/URL | B, ns/URL | allocates per URL |
| ----------------------- | --------: | --------: | ----------------- |
| `std.Uri.parse`         |      19.1 |      33.0 | no                |
| prototype `uri.parse`   |      58.4 |     100.5 | no                |
| ada C API (`ada_parse`) |     122.5 |     114.5 | yes, and frees    |

So the WHATWG contract costs about **3x** `std.Uri` on the same input, and the
Zig port is 1.1-2.1x faster than ada's C API depending on URL length. Ada's
number includes a heap allocation and free per URL; its own benchmark
excludes that, so the C API is not the fairest possible opponent. It is the
fair one for a Zig package, which would not allocate either.

Two measurements that changed the prototype:

- The first version ran at 152 ns/URL on corpus B, slower than ada. The cost
  was not the state machine: `isDoubleDot` was nine `mem.eql` calls per path
  segment, and `isForbiddenHost` was a 13-way switch per host byte. A length
  switch, a two-byte scan, and a byte table took it to 100 ns. A naive port
  of the spec text is the slow one; the algorithm is not what costs.
- Ada's canonical-path fast path, copied in, made it _slower_ on corpus A
  (73 to 89 ms): the predicate costs more than the copy it saves when paths
  are short. It pays on corpus B (about 3%) and on long paths. It is not in
  the prototype.

## What ada has that is useful without the parser

Ada is a URL library, but the pieces are separable, and several are more
generally useful than the parser they were written for.

| piece                             | ada lines | what it is                                                     | reuse verdict                                                                        |
| --------------------------------- | --------: | -------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `url_ip-inl.h` IPv4 number parser |      ~250 | hex, octal, 1-4 parts, last-part bit budget                    | **yes** — a separate lenient entry point on `net.Ip4`; this is the SSRF-relevant gap |
| IPv6 parser and serializer        |      ~150 | WHATWG grammar (no zone ids) and the compressed canonical form | **yes** — `net.Ip6` has a parser via std but no WHATWG serializer; 30 lines          |
| percent-encode sets and codecs    |      ~840 | six sets, encode, decode, "percent-decode after encoding"      | **yes** — the sets are policy; the loops are a table lookup                          |
| scheme table + default ports      |      ~210 | perfect-hash lookup over the six special schemes               | trivial, but belongs with the parser                                                 |
| `url_search_params`               |      ~565 | `application/x-www-form-urlencoded` parse and serialize        | **yes**, separate module; not URL-specific                                           |
| `url_aggregator`                  |     1,700 | serialized URL plus component offsets, one allocation          | design, not code: buffer + spans                                                     |
| SIMD host/path scanners           |      ~300 | 16-byte nibble tables for the canonical-run fast path          | optional; measurable only on long URLs                                               |
| `ada::idna` (UTS #46 + punycode)  |     6,857 | the mapping tables                                             | **yes, elsewhere**: this belongs in `utf`, not `stdx`                                |

The IDNA table is the single largest artifact in ada, seven times the state
machine. It is also the only part that requires generated data rather than
logic. That is the scope cliff.

## Prior art

- `nektro/zig-whatwg-url`: 2,011 lines, spec-compliant WHATWG, Zig 0.17,
  allocator API. MPL-2.0, and it depends on a separate `unicode-idna` package
  for domain-to-ASCII. So a Zig WHATWG parser exists, but not one that is
  zero-alloc, and its license is not stdx's.
- `std.Uri` itself, which is the RFC contract and is not going anywhere.

## Recommendation

1. Build it, as `stdx.uri`, not as a port of ada. The state machine is spec
   text, so a from-scratch implementation carries no license obligation; the
   prototype is that. Ada's code is MIT/Apache-2.0 and could be copied, but
   then `THIRD_PARTY.md` grows for no gain over the spec.
2. Take the primitives first, because they pay off even if the parser does
   not ship: `net.Ip4` gains a lenient parse for the WHATWG number forms, and
   `net.Ip6` gains the canonical serializer. Those two close the host-confusion
   and address-canonicalization gaps; the parser is what composes them.
3. Treat IDNA as a caller-supplied hook now. `parse` can take a
   `domainToAscii` function pointer (or a comptime parameter), with
   `error.IdnaUnsupported` as the default. If UTS #46 ever ships, it ships in
   `utf`, where the Unicode tables already live, and `stdx.uri` stays a
   parser.
4. Do not ship without base resolution. 203 of the 904 corpus cases are
   relative references, and most URLs a program sees are hrefs from a
   document. The absolute-only prototype is evidence, not a release.
5. Expect 3x `std.Uri` and say so in the README. A caller who only needs the
   components, and trusts the input, should keep `std.Uri`.

The smallest version that is worth having: `uri.parse` (absolute) plus
`uri.resolve` (base), IDNA off by default, the two `net` primitives in the
same change. That is roughly 900 lines plus tests, one conformance corpus
(wpt `urltestdata.json`), and no generated tables.

## Open questions

- Should `Url` hold spans (`u32` offsets) instead of slices? Spans survive a
  buffer copy and make the type smaller; slices are easier to use. Ada chose
  offsets.
- Where do query params live? `http` already owns field values and has no
  allocator in its API; `x-www-form-urlencoded` decoding needs a destination
  buffer, so it fits either.
- Does the org want a conformance corpus vendored, or fetched by CI? The
  corpus is 227 KB of JSON and is the only way to keep the claim true.

## Reproducing

The conformance numbers above come from this probe. It runs the corpus
against `src/uri.zig` and prints the four counts.

```
mkdir -p /tmp/url-wpt && cd /tmp/url-wpt
curl -sSLO https://raw.githubusercontent.com/web-platform-tests/wpt/master/url/resources/urltestdata.json
cp ~/code/baskingspot/stdx/src/uri.zig .
# save the probe below as wpt.zig
zig build-exe wpt.zig -O ReleaseSafe && ./wpt
```

```zig
const std = @import("std");
const uri = @import("uri.zig");

fn hasScheme(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return false;
}

/// A special scheme with no `//` after the colon is relative to a base that
/// has the same scheme.
fn needsBase(input: []const u8, base: ?[]const u8) bool {
    const b = base orelse return false;
    const colon = std.mem.findScalar(u8, input, ':') orelse return false;
    const bcolon = std.mem.findScalar(u8, b, ':') orelse return false;
    if (!std.ascii.eqlIgnoreCase(input[0..colon], b[0..bcolon])) return false;
    return !std.mem.startsWith(u8, input[colon + 1 ..], "//");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const doc = try std.json.parseFromSlice(std.json.Value, a, @embedFile("urltestdata.json"), .{});
    defer doc.deinit();

    var ok: usize = 0;
    var bad: usize = 0;
    var skipped: usize = 0;
    var idna: usize = 0;
    var buf: [16384]u8 = undefined;

    for (doc.value.array.items) |v| {
        if (v != .object) continue;
        const iv = v.object.get("input") orelse continue;
        if (iv != .string) continue;
        const input = iv.string;
        const failure = if (v.object.get("failure")) |x| (x == .bool and x.bool) else false;
        const want = if (v.object.get("href")) |x| (if (x == .string) x.string else "") else "";
        const base = if (v.object.get("base")) |x| (if (x == .string) x.string else null) else null;

        if (!hasScheme(input) or needsBase(input, base)) {
            skipped += 1;
            continue;
        }
        const got = uri.parse(input, &buf) catch |e| {
            if (failure) ok += 1 else if (e == error.IdnaUnsupported) {
                idna += 1;
            } else {
                bad += 1;
                std.debug.print("REJECT {s}\n", .{input});
            }
            continue;
        };
        if (failure or !std.mem.eql(u8, got.bytes, want)) {
            bad += 1;
            std.debug.print("DIFF {s}\n  got  {s}\n  want {s}\n", .{ input, got.bytes, want });
        } else ok += 1;
    }
    std.debug.print(
        "ok={d} bad={d} idna_unsupported={d} skipped_relative={d}\n",
        .{ ok, bad, idna, skipped },
    );
}
```

For the `std.Uri` side, the same loop with `std.Uri.parse` in place of
`uri.parse` and `std.Uri.resolveInPlace` for the cases with a base; that is
the harness that produced the 287 / 364 / 19 / 228 row. The ada side is
`ada_parse` and `ada_get_href` from `ada_c.h` over the same corpus, which
returns the expected href for all 904.
