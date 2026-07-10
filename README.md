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

This builds and compares three parsers on the same request workload: **hparse**, **std.http** (`std.http.Server.Request.Head.parse`) and **picohttpparser** (compiled from C by Zig's bundled clang).

Current numbers on an Intel Core Ultra 7 258V (AVX2), Zig 0.16.0, 1M parses per run:

```
name                    min       mean        max      rel
----------------------------------------------------------
picohttpparser       0.199s     0.201s     0.206s    1.00x
hparse               0.429s     0.441s     0.450s    2.15x
std.http             6.131s     6.407s     6.844s   30.82x
```

Closing the remaining gap to picohttpparser on current Zig is ongoing work. For deeper per-metric analysis (cycles, instructions, cache), point [POOP](https://github.com/andrewrk/poop) at the binaries in `bench/zig-out/bin/` after `zig build`.

> [!IMPORTANT]
> **Zig 0.16's default self-hosted x86_64 backend scalarizes `@Vector` code** — no SIMD instructions are emitted and hparse runs ~11x slower. The benchmarks force the LLVM backend (`use_llvm = true`), and you should do the same in release builds that consume this library (see Installation below) until the self-hosted backend learns vector lowering.

## Usage

```zig
const buffer: []const u8 = "GET /hello-world HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

// initialize with default values
var method: Method = .unknown;
var path: ?[]const u8 = null;
var http_version: Version = .@"1.0";
var headers: [32]Header = undefined;
var header_count: usize = 0;

// parse the request
_ = try hparse.parseRequest(buffer[0..], &method, &path, &http_version, &headers, &header_count);
```

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
* [seanmonstar/httparse](https://github.com/seanmonstar/httparse)
* [SIMD with Zig by Karl Seguin](https://www.openmymind.net/SIMD-With-Zig/)
* [SWAR explained: parsing eight digits by Daniel Lemire](https://lemire.me/blog/2022/01/21/swar-explained-parsing-eight-digits/)
* [Bit Twiddling Hacks by Sean Eron Anderson](https://graphics.stanford.edu/~seander/bithacks.html)

## License

MIT.
