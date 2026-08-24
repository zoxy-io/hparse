# hparse

![GitHub License](https://img.shields.io/github/license/zoxy-io/hparse?color=orange)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hparse/test-x86_64-linux.yml?label=x86_64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hparse/test-x86_64-windows.yml?label=x86_64-windows)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hparse/test-macos.yml?label=macos)

Fast HTTP/1.1 & HTTP/1.0 parser. Powered by Zig ⚡

## Features

* Cross-platform SIMD vectorization through Zig's `@Vector`,
* Streaming first; can be easily integrated to event loops,
* Handles partial requests,
* Never allocates and never copies.
* Similar API to picohttpparser; can be swapped in smoothly.

## Are We Fast?

Benchmarks live under [`bench/`](https://github.com/zoxy-io/hparse/tree/main/bench) and run entirely through the Zig build system — no shell scripts, Makefiles or external benchmark tools required:

```sh
cd bench
zig build bench                     # the `chrome` request, 1M parses per run, 5 runs per parser
zig build bench -Druns=10           # more repetitions
zig build bench -Diters=10000000    # heavier workload per run
zig build bench -Dworkload=all      # every request shape (see below)
zig build bench -Duse-vectors=false # the scalar tier instead of @Vector
```

This builds and compares four parsers on the same request: **hparse**, **std.http** (`std.http.Server.Request.Head.parse`), **picohttpparser** and **llhttp** (both compiled from C by Zig's bundled clang). Timing happens inside each benchmark binary and is reported as ns/parse, so process startup is not folded into the number.

Current numbers on an Intel Core Ultra 7 258V (AVX2), Zig 0.16.0, 1M parses per run, 10 runs per parser:

```
chrome — everything at once; the historical baseline, 430 bytes
name                    min       mean        max      rel
----------------------------------------------------------
hparse              68.9 ns    76.9 ns    80.6 ns    1.00x
picohttpparser     113.3 ns   121.9 ns   125.7 ns    1.64x
llhttp             226.1 ns   238.9 ns   243.5 ns    3.28x
std.http           602.7 ns   606.7 ns   618.5 ns    8.75x
```

Compare bands across runs, never single numbers.

### One request is not enough

`chrome` is a realistic browser request, and for years it was the only thing measured here. It parses a request line, nine header keys totalling ~93 bytes and nine values totalling ~350, so any change confined to one scan moves it by a few percent — inside the run-to-run band. `-Dworkload=all` runs shapes chosen to make one scan dominate, which is what makes a single-digit change visible:

| workload | loads | hparse | picohttpparser |
|---|---|---|---|
| `chrome` | everything at once | **68.1 ns** | 116.7 ns |
| `long-path` | `matchPath`, 127-byte target | **9.4 ns** | 26.4 ns |
| `long-keys` | `matchHeaderKey`, 8 × 41-byte names | 166.8 ns | **96.6 ns** |
| `long-values` | `matchHeaderValue`, 4 × 390-byte values | **52.2 ns** | 237.7 ns |
| `many-tiny` | per-header overhead, 24 headers | **134.1 ns** | 279.4 ns |
| `minimal` | fixed per-parse cost | **4.9 ns** | 17.1 ns |

They are not realistic traffic and are not meant to be — `chrome` is the one that stands in for that. They are instruments. `long-keys` is the shape that matters most: it is the one workload where picohttpparser is faster, because hparse scans field names a byte at a time while picohttpparser vectorizes that scan with SSE4.2 `pcmpestri` over eight ranges and only consults its exact token table at the byte where the scan stopped.

For deeper per-metric analysis (cycles, instructions, cache), point [POOP](https://github.com/andrewrk/poop) at the binaries in `bench/zig-out/bin/` after `zig build`; each takes an optional workload name as its one argument.

> [!IMPORTANT]
> **Zig 0.16's default self-hosted x86_64 backend scalarizes `@Vector` code** — no SIMD instructions are emitted and hparse runs ~45x slower (0.065-0.081s vs 3.17-3.21s over 1M parses of `chrome`, three interleaved runs). The benchmarks force the LLVM backend (`use_llvm = true`), and you should do the same in release builds that consume this library (see Installation below) until the self-hosted backend learns vector lowering.

## Fuzzing

The fuzzing harness in [`src/fuzz.zig`](src/fuzz.zig) uses Zig's native coverage-guided fuzzer:

```sh
zig build fuzz          # replay the seed corpus through the oracles (fast regression check)
zig build fuzz --fuzz   # coverage-guided fuzzing with a live web UI
```

Plain bounds checking can't catch this parser's most likely bug class — it walks the buffer with `[*]` many-item pointers, so a 1-byte overread doesn't fault, it silently reads adjacent memory. The first oracle below makes that class visible; the other four cover what self-consistency alone can't reach:

* **Guard pages** — every parse runs on a copy whose last byte abuts a `PROT_NONE` page, so any overread is an instant segfault.
* **Prefix exactness** — a parse that consumed N bytes must reproduce byte-identical results from exactly those N bytes, and every strict prefix must return `error.Incomplete`. Since shorter tails select different matcher tiers (SIMD → scalar), this also flags tier divergence whenever a scalar tier rejects bytes the vector tier accepted.
* **Path differential** — a second build of the parser with `-Duse-vectors=false` parses the same bytes and must reach the same verdict, including *which* error.
* **Reference differential** — [picohttpparser](https://github.com/h2o/picohttpparser) and [llhttp](https://github.com/nodejs/llhttp) parse the same bytes. Wherever hparse and a reference *both* accept, every field must match: consumed length, method, target, version, each header key and value, and the status code and message. Only where both accept — the three disagree about what is legal by design. Two references because they're wrong differently: picohttpparser is hand-written and block-oriented, llhttp is a generated state machine walking one byte at a time.
* **Disagreement snapshot** — the reference differential compares fields only where both parsers *accept*, so wherever they disagree about legality it stays silent. [`src/disagreements.zig`](src/disagreements.zig) records that skipped set — every input, every verdict, and a required one-line justification — and the build fails when it moves. A parser that starts accepting something both references reject can no longer do it quietly.

The seed corpus is a small hand-written set covering this parser's own invariants, plus 211 inputs harvested from [llhttp's markdown test fixtures](https://github.com/nodejs/llhttp/tree/v9.4.3/test) into [`src/corpus_llhttp.zig`](src/corpus_llhttp.zig). Only the inputs transfer — the oracles above are differential and self-consistency checks, so a seed needs no expected output to be useful.

`zig build test` also replays the fuzz corpus, so CI exercises the oracles on every run.

## Usage

```zig
const buffer: []const u8 = "GET /hello-world HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

// initialize with default values
var method: Method = .unknown;
var method_token: ?[]const u8 = null;
var path: ?[]const u8 = null;
var http_version: Version = .@"1.0";
var headers: [32]Header = undefined;
var header_count: usize = 0;

// parse the request
_ = try hparse.parseRequest(buffer[0..], &method, &method_token, &path, &http_version, &headers, &header_count);
```

The nine registered methods come back as their enum tags; any other RFC 9110
token (`PROPFIND`, `MKCOL`, ...) parses as `.extension`. `method_token` always
carries the method's raw bytes. Line terminators are strictly CRLF — a bare LF
is rejected as `error.Invalid` (accepting both is a request-smuggling
ingredient).

Header field names must be RFC 9110 `token`, and the request-target must be RFC
3986 `pchar` plus the delimiters a target is built from (`/`, `?`, `%`) and a
tolerated `#`, `[`, `]`. Both are stricter than most parsers: a target containing
`"`, `<`, `>`, `\`, `^`, `` ` ``, `{`, `|`, `}` or raw non-ASCII is rejected rather
than passed through. The motivating case is `\`, which some servers normalize to
`/` — a proxy and an origin reading two different paths out of one target is the
same failure as disagreeing about a line terminator. Note this does **not** make
path-based routing safe by itself: hparse never percent-decodes and never resolves
dot-segments, so a caller matching on the target must normalize first.

## What hparse does not check

hparse parses the request/status line and headers and validates their **syntax** —
CRLF terminators, `token` field names, `pchar` targets. It never interprets what it
parsed. A successful parse means "these bytes are well-formed", and nothing else. At
a trust boundary the rest is yours:

* **Framing.** No `Content-Length` or `Transfer-Encoding` handling whatsoever — both
  arrive as ordinary headers, unexamined. `Content-Length: 4 2` parses. So do
  duplicate and mutually contradictory `Content-Length` / `Transfer-Encoding`
  headers. Deriving a body length from them, and rejecting the combinations that
  don't have one, is the caller's job; getting it wrong is request smuggling.
* **Field names are case-preserved.** Slices point into your buffer, so nothing is
  lowercased. Compare case-insensitively: `Content-Length`, `content-length` and
  `CONTENT-LENGTH` are all legal and an attacker picks which to send.
* **Duplicate headers.** Returned once each, in order, unmerged and undeduplicated.
* **Path normalization.** The target comes back as an opaque slice. hparse never
  percent-decodes and never resolves `.` or `..`, so routing or access control on
  the raw bytes is bypassable with `%2e%2e%2f`. Normalize before you match.
  Rejecting `\` and raw non-ASCII (above) closes a *byte-level* divergence between
  you and the origin; it is not a substitute for normalizing.
* **Limits.** Header count is bounded only by the array you pass, which yields
  `error.TooManyHeaders` when full. There is no cap on target length, field length
  or total head size — bound those with your read buffer.

## Installation

Install via Zig package manager (Copy the full SHA of latest commit hash from GitHub):

```sh
zig fetch --save https://github.com/zoxy-io/hparse/archive/<latest-commit-hash>.tar.gz
```

In your `build` function at `build.zig`, make sure your build step and source files are aware of the module:

```zig
const dep_opts = .{ .target = target, .optimize = optimize };

const hparse_dep = b.dependency("hparse", dep_opts);
const hparse_module = hparse_dep.module("hparse");

exe_mod.addImport("hparse", hparse_module);
```

For fast parsing in release builds on x86_64, force the LLVM backend on the executable that links hparse — Zig 0.16's default self-hosted backend does not vectorize `@Vector` code yet:

```zig
const exe = b.addExecutable(.{
    .name = "my-app",
    .use_llvm = true, // hparse relies on SIMD; ~45x faster than the self-hosted backend
    .root_module = exe_mod,
});
```

## Acknowledgements

This project wouldn't be possible without these other projects and posts:

* [h2o/picohttpparser](https://github.com/h2o/picohttpparser)
* [nodejs/llhttp](https://github.com/nodejs/llhttp)
* [seanmonstar/httparse](https://github.com/seanmonstar/httparse)
* [SIMD with Zig by Karl Seguin](https://www.openmymind.net/SIMD-With-Zig/)
* [SWAR explained: parsing eight digits by Daniel Lemire](https://lemire.me/blog/2022/01/21/swar-explained-parsing-eight-digits/)
* [Bit Twiddling Hacks by Sean Eron Anderson](https://graphics.stanford.edu/~seander/bithacks.html)

## License

MIT.
