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
  runs, never single numbers. `-Dworkload=all` runs six request shapes instead of
  the one browser request that used to be the whole benchmark; use it whenever a
  change touches a single scan, because `chrome` alone hides a change confined to
  one of them inside its own band. `-Duse-vectors=false` now reaches the parser
  from here too, so the two tiers can finally be compared.

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
  is deleted — so they are the reason the code looks like this, not a number to
  re-run. `bench/` does now isolate this function: `-Dworkload=long-keys` is
  8 x 41-byte field names, and it is the **one workload where picohttpparser is
  faster than hparse** (96.6 ns/parse against 166.8, Core Ultra 7 258V, 5 runs,
  minima).

  That last sentence used to read "picohttpparser and httparse both scan field
  names byte at a time for the same reason", and for picohttpparser it was simply
  wrong. `parse_token` calls `findchar_fast` first — SSE4.2 `pcmpestri` in
  `_SIDD_CMP_RANGES` mode over eight ranges approximating non-tchar — and only
  then walks `token_char_map` a byte at a time from wherever the vector scan
  stopped. Approximate wide, verify narrow. The reason that shape is hard to copy
  here is specific and worth knowing: one `pcmpestri` tests eight ranges, which is
  why picohttpparser pays no per-range cost, while the portable `@Vector`
  formulation needs six subtract-and-compares plus three equalities to say the
  same thing. So the measurement above stands, the explanation for it does not,
  and the gap is now visible in the tree instead of being asserted in a comment.
  Reach for SIMD here again only with your own benchmark — but there is now a
  workload that would show it working.
- **The vector loops advance by a constant, and only the chunk that stops a scan
  pays for a position.** This is the single biggest thing in the scanning code.
  Both loops used to end `cursor.advance(firstRejected(bad))` unconditionally, so
  every iteration's next load address waited on the whole classify -> mask ->
  `@ctz` chain even when nothing was rejected — latency-bound where it should have
  been throughput-bound. Asking `@reduce(.Or, bad)` first and advancing by a
  literal `vec_size` on the clean path moves that chain off the loop-carried
  dependency and onto a predicted-not-taken branch. On the `bench/` request, M3
  Max, five interleaved runs comparing minima: 141-142 -> 79-81 ns/parse, and
  193-194 -> 88-89 on a 127-byte request-target, against picohttpparser's 125-127
  and 171-172, and reproducible from the tree by rebuilding at the parent commit.
  It is not an AArch64 fix: the same data dependency was on the x86 path, just
  shorter, and the restructure removes `tzcnt` and the pointer update from that
  loop body too (checked by cross-compiling to `x86_64_v3` and diffing).
  picohttpparser has had this shape all along and for the same reason — `pcmpestri`
  costs about ten cycles, so it advances `buf += 16` on the clean path and reads
  the returned index only on the way out.
- **Lane masks are extracted two different ways, and the split is load-bearing.**
  `firstRejected` answers "which lane rejected first" twice. x86 has `pmovmskb`, so
  bitcasting the compare result to a bit-per-lane integer is one instruction and
  already optimal. AArch64 has no such instruction: LLVM lowers
  `@bitCast(@Vector(N, u1))` into `and`/`ext`/`zip1`/`addv` plus a cross-domain
  `fmov`. `shrn`, narrowing each pair of 16-bit lanes down four bits, leaves one
  nibble per input byte in a single 64-bit register instead. Four interleaved runs,
  minima: 91-93 ns/parse portable, 79-82 split — 13%, down from the 20% the same
  split was worth against the old loop shape (a separate five-run set, 162-168 ->
  130-133). It shrank but did not vanish, because header values are short enough
  that most scans stop inside their first chunk, so the position lookup runs about
  as often as the loop does. Unlike the bullet above, this pair is **not**
  reproducible from the tree: it needs a build with the arch branch taken out, and
  no build option reaches that. Do not collapse the branches — the nibble form on
  x86 costs a `psrlw` and a `pshufb` on top of the `pmovmskb` it cannot avoid.
- **`std.simd.firstTrue` is not the shortcut it looks like.** It does
  `@reduce(.Or, vec)` and then `@select` plus `@reduce(.Min, indices)` — two
  horizontal reductions, which is worse on AArch64 than either form above.
- **The scalar tier is benchmarkable now, and the first run found something.**
  `-Duse-vectors=false` was 19% *faster* than the shipped build on aarch64 before
  the two loop fixes above, and for months nothing could have shown that:
  `bench/build.zig` did not forward the option to the `hparse` dependency. It does
  now. The first comparison it made possible, Core Ultra 7 258V, 3 runs, minima:

  | workload | vectors on | vectors off |
  |---|---|---|
  | `chrome` | **68.1 ns** | 137.4 ns |
  | `long-path` | **9.4 ns** | 43.9 ns |
  | `long-values` | **52.2 ns** | 432.3 ns |
  | `long-keys` | 166.8 ns | **116.5 ns** |
  | `many-tiny` | 134.1 ns | **60.3 ns** |

  The last two rows are the finding: on requests whose header values are a few
  bytes long, turning the vector tier **off** is up to 2.2x faster. The mechanism
  is that `matchHeaderValue` gates its vector loop on `hasLength(vec_size)`, which
  asks how much *buffer* remains, not how long the value is — so a 1-byte value
  sitting anywhere but the very end of the head still pays a 32-byte load, five
  vector ops, a `pmovmskb` and a `@ctz` to find a CR one byte away. `chrome` hides
  it because its two long values (71 and 120 bytes) more than pay for the seven
  short ones. Real traffic has a lot of short header values, so this is worth
  fixing rather than filing; the obvious shape is a few scalar iterations before
  entering the vector loop, which costs long values almost nothing. Not attempted
  yet — measure it, do not assume it. A vectorized scan is a hypothesis about the
  target, not a win, and this one is wrong for a whole class of input.
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
