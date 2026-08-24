# hparse

A zero-allocation, streaming HTTP/1.x parser. Zig 0.16. It parses request
and status lines and headers, and **nothing else** — no framing, no body, no
connection state. Those decisions belong to the caller, which is why the whole
of zoxy's framing lives behind `src/http/parser.zig` and not here.

Consumed by the zoxy proxy at ingress, which is the fact that decides most
arguments: this parser sees bytes an attacker chose, in a segmentation an
attacker chose, on a thread that is also serving other connections.

The flip side of "nothing else" is a list of things the caller must therefore do
itself, and it is enumerated in the README under **What hparse does not check** —
framing, case-insensitive field-name comparison, duplicate headers, path
normalization, limits. Keep it current: every time this parser declines to
interpret something, that is not the end of the argument, it is an obligation
moving to the consumer, and the only honest place to record it is where a
consumer will read it. Most of `src/disagreements.zig` is that same boundary
seen from the other side — llhttp refusing messages hparse passes through
because llhttp does framing and hparse does not.

## Gates — run before every commit

- `zig build test` — unit tests.
- `zig build fuzz` — the seed corpus through the fuzz oracles. Deterministic,
  a couple of seconds, and **in CI**. It was not, once, and an accepted empty
  request-target survived for exactly that reason: the oracle that catches it
  already existed and was never executed.
- `zig build fuzz --fuzz` — coverage-guided fuzzing. **This works here**,
  because `src/fuzz_test_runner.zig` is a custom runner; the Zig 0.16.0
  breakage that blocks it in other repos (`compiler/test_runner.zig:566`,
  a StackTrace type mismatch under `-ffuzz`) does not apply. Run it for a few
  minutes on any change to the parser — it has found real bugs in about two
  minutes, twice.
- `zig build test -Duse-vectors=false` — the same unit tests against the
  scalar tier. Nothing else reaches it: `std.simd.suggestVectorLength` is
  non-null on every target this builds for (SSE2 on baseline x86_64, NEON on
  aarch64), so before that option existed the scalar half of every
  `if (comptime use_vectors)` was dead code in every test run.
- `zig build bench` for anything on a scanning path. Compare bands across
  runs, never single numbers.

Style follows [zoxy's docs/TIGER_STYLE.md](../zoxy/docs/TIGER_STYLE.md), and
the `tiger-style-reviewer` agent in this repo reviews a diff against it. Run
it before committing.

## What the fuzz oracles actually check

They are the reason to trust a change here, so know what they cover:

- **Guard page.** Every input is copied so its last byte abuts a `PROT_NONE`
  page. A one-byte overread is a SIGSEGV rather than a silent read of adjacent
  memory — which matters because the parser walks `[*]const u8`, where Zig's
  bounds checking does not help.
- **Consumed-length round-trip.** Re-parsing exactly the N bytes a successful
  parse claims to consume must give a byte-identical result, and every strict
  prefix must return `Incomplete` — never a false accept, and never `Invalid`
  (which would mean the SIMD and scalar tiers disagree about the same
  bytes).
- **Resume equivalence, both directions.** Growing prefixes through
  `parseRequestResume`/`parseResponseResume` must reach the identical answer as
  one shot, AND must never accept a message the one-shot path refuses. The
  second half is the one that matters for a proxy and it is easy to leave out.
- **Reference differential**, against **picohttpparser and llhttp**. Where hparse
  and a reference BOTH accept, every field must match: consumed length, method,
  target, version, each header key and value, and on the response side the status
  code and status message. Only where both accept — they disagree about what is
  legal by design, and those verdict differences are triage material, not
  failures. picohttpparser takes a bare LF, an obs-fold line, a leading empty line
  and any HTTP minor digit; llhttp refuses all of those but also refuses any
  method outside its own table, so every extension method hparse takes is a
  verdict difference too. What this catches is the case self-consistency cannot:
  both parsers agreeing a message is well-formed and then disagreeing about what
  it says. Two references because they are wrong differently — picohttpparser is
  hand-written and block-oriented, llhttp is a generated state machine walking one
  byte at a time — so a bug they would both wave through is unlikely to be the
  same bug. Both are the copies already vendored for the benchmarks, so there is
  one of each in the repo, not two, and `bench/` is outside the published package
  — the fuzz step only ever builds in-tree.

  Two things are normalized before comparing against llhttp, and only two:
  it keeps the trailing OWS on a header value, and it consumes exactly one space
  after the status code where hparse skips the whole run. Both are representation
  differences that cannot hide a disagreement about non-space bytes. Every other
  field is compared raw — normalization is where a real difference gets defined
  away, so anything added there needs the same argument.
- **Path differential.** A second build of the parser with the `@Vector` tier
  forced off parses the same bytes and must reach the same verdict — including
  *which* error. The tier is chosen by how many bytes remain, so the two builds
  run different code over one input by construction; this parser has already
  had one SIMD-vs-scalar divergence (a space in a header key). Injecting a
  vector-only accept of DEL in a header value, the oracle catches it in about a
  minute of `--fuzz`, and the corpus alone does not — the differential earns
  its keep only under coverage-guided fuzzing.

## The disagreement snapshot

`src/disagreements.zig` lists every corpus input where hparse and a reference reach
different verdicts, each with a required one-line `why`. `zig build fuzz` recomputes
the set and fails when it moves — NEW, RESOLVED, CHANGED, ORPHAN, or an entry whose
`why` is still a placeholder.

It exists because the reference differential compares fields only where both parsers
*accept*, and skips everything else. The skipped set is where the tchar bug lived for
eight months: picohttpparser rejected `Fo@:`, hparse accepted it, and the oracle
dropped the disagreement silently. llhttp's own fixture for that exact input was in
the corpus and ran clean. Verified: reintroduce the bug and this test names the input
and warns that hparse is the only parser accepting it.

That signature — `hparse = true` with **both** references false — is the one to fear,
and there are currently zero such entries. One reference disagreeing is usually a
layering difference (llhttp does framing and method-table validation that hparse
deliberately does not; that is most of the file).

Edit it **by hand**. The failure output is a delta, not a regenerated file, because
the `why` lines are the only part that cannot be recomputed and a bulk rewrite would
silently discard them — which is the exact failure this whole thing is here to stop.

## Where the seed corpus comes from

Two arrays, kept apart on purpose. The hand-written seeds at the bottom of
`src/fuzz.zig` pin the shapes this parser's own invariants turn on — the 16-byte
minimum request, a space in a header key, a registered-method prefix collision —
and each is worth reading. `src/corpus_llhttp.zig` is breadth: 211 inputs
harvested from llhttp's markdown fixtures (`test/{request,response}/*.md`, v9.4.3,
the release already vendored under `bench/`), which is hand-written HTTP edge
cases nobody here thought to write down.

It is **generated** by `tools/extract_llhttp_corpus.pl`, whose decode replicates
`test/md-test.ts` step for step. The order of those steps is load-bearing:
normalizing line endings *before* expanding backslash escapes is what makes a
blank line a CRLF while leaving an explicit `\n` a bare LF. Doing it the other
way round would silently turn every bare-LF rejection case into an accepted one,
and the corpus would still look fine. The file's header records the one
deliberate deviation and what was dropped.

Only inputs were taken. llhttp pairs each fixture with an expected event trace,
and none of it transfers — hparse returns a consumed length and slices, not
`on_url` callbacks. It does not need to: every oracle here is differential or
self-consistency, so a seed carries its own verdict. That is the reason this
import was cheap, and the reason a corpus from any other parser would be too.

## Invariants worth knowing before editing

- **Never allocates, never copies.** Every returned slice points into the
  caller's buffer.
- **The tier constants are build options, and default to detection.**
  `-Duse-vectors=false` and `-Dvec-size=N` override `use_vectors` / `vec_size`
  in `src/root.zig`; unset, they compute exactly what the hardcoded detection
  used to. They exist for the tests, not for consumers — the detection is what
  makes the parser fast on the machine it was built for. `build.zig` compiles a
  second, vectors-off copy of `src/root.zig` for the fuzz harness to diff
  against, via a generated copy of the file because Zig will not let one file
  root two modules.
- **`min_request_len` is a correctness argument, not a heuristic.** The
  shortest legal request, `A / HTTP/1.1\r\n\r\n`, is exactly 16 bytes, so the
  fast-path length check can never refuse a *complete* request — but only
  because `parsePath` refuses an empty request-target. Those two facts hold
  each other up; changing either means re-checking the other.
- **CRLF only.** A bare LF is `error.Invalid`. Accepting both is how request
  smuggling starts: two intermediaries that disagree about where a line ends
  parse two different messages out of the same bytes. RFC 9112 §2.2 permits
  the leniency; a proxy-grade parser must not take it.
- **The request-target is RFC 3986 `pchar` plus `/?%` and `#[]`, and that is a
  routing decision.** `pchar` alone excludes the delimiters a target is built out
  of, so the table is pchar, the structural `/`, `?` and the `%` of a pct-encoded
  escape, and three tolerated characters. It refuses `"<>\^`{|}` and all of
  0x80-0xff. The one that motivates it is
  `\`: IIS, .NET and browser URL parsing normalize a backslash to `/`, so a
  proxy routing on `/public\..\admin` and an origin resolving `/admin` have read
  two paths out of one target. zoxy routes on paths, which is what makes this
  hparse's problem rather than the caller's. Rejecting 0x80-0xff is the part
  with a real cost — raw UTF-8 in a path is common in the wild and now 400s —
  and it was chosen deliberately. `#`, `[` and `]` are tolerated against the
  grammar: a fragment fails SAFE (an origin truncating there sees *less* path
  than the proxy did), and brackets are everywhere in query strings.
  **This does not make path routing safe on its own.** Percent-encoding and
  dot-segments are the dominant confusions, hparse decodes neither, and a caller
  matching on the target must still normalize first. What the table buys is that
  the proxy and the origin cannot read *different bytes* as different paths.
- **The header-key scan is scalar on purpose, and it is the fast one.**
  `matchHeaderKey` walks `key_map` a byte at a time while `matchPath` and
  `matchHeaderValue` vectorize. That looks like an oversight and is not. A field
  name is `token` (RFC 9110 §5.6.2), and tchar is not a range, so a vector path
  has to classify it exactly — six wrapping subtract-and-compare ranges plus
  three equalities, since Zig exposes no portable runtime byte shuffle and
  `@shuffle` needs a comptime mask. Measured on the `bench/` request at
  `-Diters=10000000`, 11 interleaved runs, comparing minima: that exact vector
  path is **1.24x slower** than the broken range compare it replaced, while the
  scalar loop is **0.85x** — faster than the code it replaced, while also being
  correct. Header keys are short, so a 16-byte-wide setup never amortizes;
  re-measured with 40-byte keys, where SIMD should win if it ever does, and it
  still loses. Those ratios are **not reproducible from the tree** — the variant
  is deleted and nothing in `bench/` isolates this function — so they are the
  reason the code looks like this, not a number to re-run. picohttpparser and
  httparse both scan field names byte at a time for the same reason. Reach for
  SIMD here again only with your own benchmark.
- **Lane masks are extracted two different ways, and the split is load-bearing.**
  Every vector loop ends by asking "which lane rejected first", and `firstRejected`
  answers it twice. x86 has `pmovmskb`, so bitcasting the compare result to a
  bit-per-lane integer is one instruction and already optimal. AArch64 has no such
  instruction: LLVM lowers `@bitCast(@Vector(N, u1))` into `and`/`ext`/`zip1`/`addv`
  plus a cross-domain `fmov` — a horizontal reduction sitting inside a
  loop-carried dependency chain, because the reduction's result *is* the next
  chunk's address. `matchHeaderValue` got a second one on top (`uminv`+`fmov`,
  purely to evaluate `adv_by != vec_size`), which is how a 16-byte NEON step ended
  up costing more than picohttpparser's 8x-unrolled scalar byte loop, whose loads
  are all independent and therefore throughput-bound rather than latency-bound.
  `shrn`, narrowing each pair of 16-bit lanes down four bits, leaves one nibble per
  input byte in a single 64-bit register instead. On the `bench/` request, M3 Max,
  five interleaved runs comparing minima: 162-168 -> 130-133 ns/parse. Reproducible
  from the tree by rebuilding at the parent commit. Do not collapse the branches —
  the nibble form on x86 costs a `psrlw` and a `pshufb` on top of the `pmovmskb` it
  cannot avoid.
- **This was invisible for as long as it was because nothing benchmarks the scalar
  tier.** `-Duse-vectors=false` was 19% *faster* than the shipped build on aarch64,
  and the option is described above as existing only so the fuzz differential can
  reach an otherwise-unreachable tier. `bench/build.zig` does not forward it to the
  `hparse` dependency, so no `zig build bench` run has ever compared the two tiers
  the parser actually chooses between. A vectorized scan is a hypothesis about the
  target, not a win; on aarch64 `matchPath` still loses to its own scalar tier on a
  long request-target (176-177 vs 168-171 ns/parse on a 127-byte path) even with
  the mask fixed, because pchar takes eight compares per chunk to classify.
- **The path-differential oracle no longer covers header keys.** It diffs a
  vectors-on build against a vectors-off one, and `matchHeaderKey` is now the
  same code in both. That is worth knowing precisely because both bugs this
  function has had — the space-in-key tier split and the tchar gap — lived
  there. Vectorizing it again would restore that coverage; leaving it scalar
  means header-key classification rests on the unit test that walks all 256
  bytes, and on the reference differentials.
- **There are two header parsers on purpose.** `parseHeader`/`parseHeaders`
  are the one-shot hot path for a caller holding a whole head;
  `parseHeaderResume`/`parseHeadersResume` carry the resume state. Threading
  phase bookkeeping through the first would put branches inside the SIMD scans
  for the benefit of callers not using them. They are kept honest by the fuzz
  harness parsing every input both ways, **not** by sharing code — so a change
  to one that is not mirrored in the other must be caught there, and any new
  oracle should exercise both.
- **`Resume` is a contract, and most of it is about the caller's memory.** The
  slice may only grow at the end; bytes already consumed must not move; the
  `headers` array must persist, including `headers[header_count]`, where a
  half-parsed line's key lives between calls. Out-of-range or inconsistent
  state is refused with `error.Invalid` rather than asserted, because
  assertions are gone in the ReleaseFast build a consumer may choose.

## Why the resume API exists

Without it a streaming caller must re-parse the head from byte zero every time
more bytes arrive, and the sender picks the segmentation. Measured against
zoxy's limits, one 64 KiB request head arriving one byte at a time scanned
2.19 GB and burned 371 ms of CPU — inside a proxy event loop that is also
serving other connections. With resume it scans 66,909 bytes for a 66,218-byte
head: one pass plus a byte of look-ahead per call.

A caller that already has the whole head should keep using `parseRequest` /
`parseResponse`; the resumable entry points are for the streaming case.
