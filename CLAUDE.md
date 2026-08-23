# hparse

A zero-allocation, streaming HTTP/1.x parser. Zig 0.16. It parses request
and status lines and headers, and **nothing else** — no framing, no body, no
connection state. Those decisions belong to the caller, which is why the whole
of zoxy's framing lives behind `src/http/parser.zig` and not here.

Consumed by the zoxy proxy at ingress, which is the fact that decides most
arguments: this parser sees bytes an attacker chose, in a segmentation an
attacker chose, on a thread that is also serving other connections.

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
  SWAR/scalar tier. Nothing else reaches it: `std.simd.suggestVectorLength` is
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
  (which would mean the SIMD, SWAR and scalar tiers disagree about the same
  bytes).
- **Resume equivalence, both directions.** Growing prefixes through
  `parseRequestResume`/`parseResponseResume` must reach the identical answer as
  one shot, AND must never accept a message the one-shot path refuses. The
  second half is the one that matters for a proxy and it is easy to leave out.
- **Reference differential.** Where hparse and picohttpparser BOTH accept, every
  field must match: consumed length, method, target, version, each header key
  and value, and on the response side the status code and status message. Only where both accept — they disagree about what is legal by
  design (picohttpparser takes a bare LF, an obs-fold line, a leading empty line
  and any HTTP minor digit), and those verdict differences are triage material,
  not failures. What it catches is the case self-consistency cannot: both
  parsers agreeing a message is well-formed and then disagreeing about what it
  says. The reference is the copy already vendored for the benchmarks, so there
  is one picohttpparser in the repo, not two, and `bench/` is outside the
  published package — the fuzz step only ever builds in-tree.
- **Path differential.** A second build of the parser with the `@Vector` tier
  forced off parses the same bytes and must reach the same verdict — including
  *which* error. The tier is chosen by how many bytes remain, so the two builds
  run different code over one input by construction; this parser has already
  had one SIMD-vs-scalar divergence (a space in a header key). Injecting a
  vector-only accept of DEL in a header value, the oracle catches it in about a
  minute of `--fuzz`, and the corpus alone does not — the differential earns
  its keep only under coverage-guided fuzzing.

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
