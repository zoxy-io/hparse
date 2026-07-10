# hparse — code review findings & action plan

Review of `src/root.zig` (zero-alloc streaming HTTP/1.x parser). Each item below was
reproduced against the current code. Ordered by severity.

## 🔴 High — out-of-bounds read one byte past the slice on truncated input — ✅ FIXED

> Fixed: end-of-buffer guards added before every `cursor.char()` that follows a
> match/advance (`parsePath`, `parseHeader` key+value, `parseHeaders` loop head + post-loop
> CRLF, `parseStatusMessage`). Regression tests: "does not read past slice end (OOB
> regression)", "truncated inputs return Incomplete", "parseResponse: truncated
> status/headers return Incomplete".


Every `matchX()` loop stops when `cursor.idx == cursor.end`, but the caller reads
`cursor.char()` (`cursor.idx[0]`) **before** checking for end-of-buffer. `idx` is a
`[*]const u8`, so this dereference is not bounds-checked even in Debug/ReleaseSafe — it
silently reads adjacent memory.

Affected sites in `src/root.zig`:
- `parsePath` — `if (cursor.char() == ' ')` (~line 322)
- `parseHeader` — `switch (cursor.char())` after `matchHeaderKey` (~504) and after
  `matchHeaderValue` (~538)
- `parseHeaders` — loop head (~582) and post-loop CRLF check (~615)
- `parseStatusMessage` — `switch (cursor.char())` (~658)

Trigger is the common streaming case: bytes ending exactly on a CRLF, e.g.
`"GET / HTTP/1.1\r\n"` or a request truncated before the final CRLF. A 16-byte slice
backed by a 17-byte array (`[16] = '\n'`) reports `consumed = 17` — it read past the end.

Consequences: (1) segfault if the slice ends on an allocation/page boundary;
(2) worse — with a reused read buffer, stale trailing bytes can make an *incomplete*
request parse as *complete*, dropping headers (HTTP desync / smuggling class). Directly
contradicts the "handles partial requests / streaming first" guarantee.

**Fix:** before each `cursor.char()` that follows a match/advance, guard with
`if (cursor.idx == cursor.end) return error.Incomplete;` (or add a bounds-checked
`charOrNull`). The `parseHeaders` loop head needs the same guard. Add a regression test
for truncated input (slice shorter than backing array).

## 🟠 Medium — space in header key: SIMD and scalar paths disagree — ✅ FIXED

> Fixed: added `' '` to `key_map`'s invalid set so the scalar fallback rejects space like
> the SIMD path. Regression test: "space in header key is rejected regardless of match
> path" (covers both the short/scalar and long/SIMD tails).


`key_map` invalid set is `0..31, ':', 127` — **space (0x20) is missing**, so
`isValidKeyChar(' ')` is `true`. The SIMD path (`chunk > spaces`, ~line 411) *excludes*
space. So acceptance of a space-containing key depends only on bytes remaining
(≥16 → SIMD rejects, <16 → scalar accepts). Verified: key `"A B"` → scalar `OK`, SIMD
`error.Invalid`.

Whitespace in a field name is malformed (RFC 7230 §3.2.4) and a smuggling vector.

**Fix:** add `' '` to `key_map`'s invalid set so the scalar fallback rejects, matching SIMD.

## 🟡 Low — header-value OWS / HTAB handling diverges from RFC 7230 — ✅ FIXED

> Fixed: TAB (0x09) is now a legal value char (`value_map`, SIMD and SWAR matchers), and
> leading + trailing OWS (SP / HTAB) is trimmed in `parseHeader`. The SWAR path skips TAB
> *after* stopping (the less-than trick's borrow makes masking TAB out unsafe — a genuine
> `<32` byte perturbs the next byte's high bit). Regression test: "OWS/HTAB handling in
> header values (RFC 7230)" covers leading/trailing/internal TAB on scalar, SWAR and SIMD
> paths plus a tab-only value trimming to empty.


- Only leading `' '` is skipped (~line 531), not HTAB; trailing OWS is not trimmed.
  (`"Host: localhost   "` → value `"localhost   "`.)
- HTAB (0x09) is excluded by `value_map`/`matchHeaderValue`, so legal values containing
  tabs are rejected (`"Host:\tlocalhost"` and `"Host: a\tb"` → `error.Invalid`). Note the
  commented-out tab-handling code (~lines 442, 450).

**Fix:** decide policy and document, or trim leading/trailing SP+HTAB and allow internal HTAB.

## 🟡 Low — `parseHeaders` doc/behavior mismatch on overflow — ✅ FIXED

> Fixed by making the code match the promise: added `TooManyHeaders` to `ParseRequestError`.
> When the `headers` slice fills and the next byte is a valid header-key character (another
> header follows), `parseHeaders` returns `error.TooManyHeaders`; genuinely malformed bytes
> still return `error.Invalid`. Public doc comments on `parseRequest`/`parseResponse`
> updated, and `parseResponse` now uses the explicit `ParseRequestError!usize` return type.
> Regression test: "full headers slice with more headers returns TooManyHeaders" (also
> confirms a larger slice parses the same request cleanly).


Comment promises `error.TooManyHeaders`, but `ParseRequestError` is only
`{Incomplete, Invalid}` and overflow returns `error.Invalid` (~line 637). Callers can't
distinguish "headers array too small" (retryable) from "malformed" (fatal).

**Fix:** add the error variant, or correct the comment.

## Nits — ✅ all done
- ~~`parseResponse` uses inferred `!usize`; `parseRequest` uses explicit
  `ParseRequestError!usize` — make consistent.~~ ✅ Done (now `ParseRequestError!usize`).
- ~~`parseResponse` status-code local `dirty` means "valid/all-digits" — confusing
  inverse.~~ ✅ Done (renamed to `all_digits`).
- ~~Non-standard methods (PROPFIND, MKCOL, …) return `error.Invalid`; document as
  intentional.~~ ✅ Done (documented on `Method` and in `parseRequest`'s doc comment).
- ~~`Method.unknown` is never produced by the parser (caller-init sentinel only) —
  document.~~ ✅ Done (doc comment on the enum field).

## What's already good
- Endianness-correct (magic constants and `asInteger` both `@bitCast`).
- SWAR less-than/DEL detection is correct; path and value matching are consistent across
  SIMD/SWAR/scalar — only the key path has the space discrepancy above.
- Tests pass on Zig 0.16; CI covers Linux/macOS/Windows.

## Benchmark status (2026-07-10)

Rebuilt as a pure-Zig harness (`bench/`, `zig build bench` — no Makefile/shell/cargo);
compares hparse, `std.http.Server.Request.Head.parse` and picohttpparser (upstream
`f4d94b48`, C compiled by Zig's clang, Zig driver via extern decls).

Intel Core Ultra 7 258V (AVX2), Zig 0.16.0, ReleaseFast + LLVM backend, 1M parses/run:

```
name                    min       mean        max      rel
----------------------------------------------------------
hparse               0.104s     0.112s     0.117s    1.00x
picohttpparser       0.128s     0.130s     0.134s    1.23x
std.http             0.697s     0.707s     0.721s    6.70x
```

hparse leads (~104 ns/parse), consistent with the project's original claims. Outputs are
consumed via `doNotOptimizeAway` in the Zig drivers, so LLVM can't elide work the extern
C call is forced to do (verified: no elision occurs; numbers hold either way).

Two perf footguns found while redoing these — both worth remembering:
- **Zig 0.16's default self-hosted x86_64 backend scalarizes `@Vector` code** → hparse
  ~11x slower (no `vpcmpgtb`/`vpmovmskb` emitted). Bench forces `use_llvm = true`;
  README tells library consumers to do the same in release builds.
- **`standardOptimizeOption(.{ .preferred_optimize_mode = ... })` still yields Debug**
  unless `-Drelease` is passed — the harness previously ran everything in Debug (C got
  `-O0` + UBSan + stack protector). ReleaseFast is now hardcoded in `bench/build.zig`.
