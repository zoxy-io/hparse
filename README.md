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
zig build bench                # 1M parses per run, 5 runs per parser
zig build bench -Druns=10      # more repetitions
zig build bench -Diters=10000000  # heavier workload per run
```

This builds and compares four parsers on the same request workload: **hparse**, **std.http** (`std.http.Server.Request.Head.parse`), **picohttpparser** and **llhttp** (both compiled from C by Zig's bundled clang).

Current numbers on an Intel Core Ultra 7 258V (AVX2), Zig 0.16.0, 1M parses per run:

```
name                    min       mean        max      rel
----------------------------------------------------------
hparse               0.084s     0.088s     0.100s    1.00x
picohttpparser       0.116s     0.125s     0.132s    1.37x
llhttp               0.236s     0.242s     0.272s    2.80x
std.http             0.702s     0.704s     0.706s    8.35x
```

For deeper per-metric analysis (cycles, instructions, cache), point [POOP](https://github.com/andrewrk/poop) at the binaries in `bench/zig-out/bin/` after `zig build`.

> [!IMPORTANT]
> **Zig 0.16's default self-hosted x86_64 backend scalarizes `@Vector` code** — no SIMD instructions are emitted and hparse runs ~11x slower. The benchmarks force the LLVM backend (`use_llvm = true`), and you should do the same in release builds that consume this library (see Installation below) until the self-hosted backend learns vector lowering.

## Fuzzing

The fuzzing harness in [`src/fuzz.zig`](src/fuzz.zig) uses Zig's native coverage-guided fuzzer:

```sh
zig build fuzz          # replay the seed corpus through the oracles (fast regression check)
zig build fuzz --fuzz   # coverage-guided fuzzing with a live web UI
```

Plain bounds checking can't catch this parser's most likely bug class — it walks the buffer with `[*]` many-item pointers, so a 1-byte overread doesn't fault, it silently reads adjacent memory. The first oracle below makes that class visible; the other three cover what self-consistency alone can't reach:

* **Guard pages** — every parse runs on a copy whose last byte abuts a `PROT_NONE` page, so any overread is an instant segfault.
* **Prefix exactness** — a parse that consumed N bytes must reproduce byte-identical results from exactly those N bytes, and every strict prefix must return `error.Incomplete`. Since shorter tails select different matcher tiers (SIMD → SWAR → scalar), this also flags tier divergence whenever a scalar tier rejects bytes the vector tier accepted.
* **Path differential** — a second build of the parser with `-Duse-vectors=false` parses the same bytes and must reach the same verdict, including *which* error.
* **Reference differential** — [picohttpparser](https://github.com/h2o/picohttpparser) and [llhttp](https://github.com/nodejs/llhttp) parse the same bytes. Wherever hparse and a reference *both* accept, every field must match: consumed length, method, target, version, each header key and value, and the status code and message. Only where both accept — the three disagree about what is legal by design. Two references because they're wrong differently: picohttpparser is hand-written and block-oriented, llhttp is a generated state machine walking one byte at a time.

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
    .use_llvm = true, // hparse relies on SIMD; ~11x faster than the self-hosted backend
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
