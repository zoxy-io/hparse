const std = @import("std");

// A single, self-contained build graph for all benchmarks.
//
//   zig build bench                 build every parser + run the comparison
//   zig build bench -Druns=10       more repetitions per parser
//   zig build                       just build the benchmark binaries into zig-out/bin
//
// Parsers compared: hparse, std.http.Server.Request.Head, picohttpparser and
// llhttp. The C parsers are compiled with Zig's bundled clang, so no gcc or make
// is required — the whole flow lives inside `zig build`, no shell or Makefile.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Benchmarks are meaningless in Debug, so ReleaseFast is hardcoded rather than
    // offered as an option. Note standardOptimizeOption's preferred_optimize_mode
    // does NOT do this: it still yields Debug unless -Drelease is passed, which
    // silently compiled the C parser with -O0 + UBSan + stack protector.
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const runs = b.option(usize, "runs", "Repetitions per benchmark (default 5)") orelse 5;
    const iters = b.option(usize, "iters", "Parse iterations per workload per run (default 1_000_000)") orelse 1_000_000;

    // Which workload shape to run. Defaults to `chrome` — the single request every
    // number in this repo was measured on — so `zig build bench` stays the quick,
    // historically comparable command it has always been. `-Dworkload=all` runs the
    // whole suite, which is what to use when attributing a change to one scan.
    const workload = b.option([]const u8, "workload", "Workload to run: a name from bench/workloads.zig, or `all` (default: chrome)") orelse "chrome";

    // The scan tier the parser compiles, forwarded to the hparse dependency.
    //
    // These existed in the root build.zig from the start but stopped here, so no
    // `zig build bench` run had ever compared the two tiers the parser actually
    // chooses between. That is not hypothetical: on aarch64 the scalar tier was 19%
    // FASTER than the shipped vector build for months, and nothing in this directory
    // could have shown it.
    const use_vectors = b.option(bool, "use-vectors", "Force the @Vector scan tier on or off in hparse (default: detect from the target CPU)");
    const vec_size = b.option(u16, "vec-size", "Force hparse's vector width in bytes (default: detect from the target CPU)");

    // Compile-time iteration count shared by every benchmark binary so the workload
    // stays identical across parsers. std.http is ~10x slower than the rest, so keep
    // the default modest and pass e.g. -Diters=10000000 for a heavier run.
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "iters", iters);
    const options_module = bench_options.createModule();

    // The request shapes, shared by every driver. They used to be one buffer
    // copy-pasted into each of them, which is how four drivers stayed in sync by
    // luck. This module also owns the in-process timing loop.
    const workloads_module = b.createModule(.{
        .root_source_file = b.path("workloads.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bench_options", .module = options_module }},
    });

    // The parser under test, consumed as a normal Zig module from the repo root.
    //
    // The tier options are only passed when set, because a dependency's option set
    // is part of its cache key: passing `.@"use-vectors" = null` is not the same as
    // not passing it, and would recompile hparse under a different key than a plain
    // `zig build` in the repo root.
    const hparse_dep = if (use_vectors) |uv|
        if (vec_size) |vs|
            b.dependency("hparse", .{ .target = target, .optimize = optimize, .@"use-vectors" = uv, .@"vec-size" = vs })
        else
            b.dependency("hparse", .{ .target = target, .optimize = optimize, .@"use-vectors" = uv })
    else if (vec_size) |vs|
        b.dependency("hparse", .{ .target = target, .optimize = optimize, .@"vec-size" = vs })
    else
        b.dependency("hparse", .{ .target = target, .optimize = optimize });

    const hparse = hparse_dep.module("hparse");

    // hparse benchmark (Zig).
    //
    // use_llvm matters: Zig 0.16's default self-hosted x86_64 backend scalarizes
    // @Vector compares, making hparse ~11x slower. The C parser always goes through
    // clang/LLVM, so without this flag the comparison is meaningless.
    const hparse_bench = b.addExecutable(.{
        .name = "hparse",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("hparse/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hparse", .module = hparse },
                .{ .name = "workloads", .module = workloads_module },
            },
        }),
    });

    // std.http.Server.Request.Head benchmark (Zig).
    const headparser_bench = b.addExecutable(.{
        .name = "headparser",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("headparser/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "workloads", .module = workloads_module }},
        }),
    });

    // picohttpparser benchmark: Zig driver + the C parser compiled by Zig's bundled
    // clang — no gcc/make needed.
    const pico_mod = b.createModule(.{
        .root_source_file = b.path("picohttpparser/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "workloads", .module = workloads_module }},
    });
    pico_mod.addCSourceFiles(.{
        .files = &.{"picohttpparser/picohttpparser.c"},
        .flags = &.{"-O3"},
    });
    const pico_bench = b.addExecutable(.{
        .name = "picohttpparser",
        .use_llvm = true,
        .root_module = pico_mod,
    });

    // llhttp benchmark: Zig driver + the vendored generated C parser, compiled
    // the same way as picohttpparser above.
    const llhttp_mod = b.createModule(.{
        .root_source_file = b.path("llhttp/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "workloads", .module = workloads_module }},
    });
    llhttp_mod.addIncludePath(b.path("llhttp"));
    llhttp_mod.addCSourceFiles(.{
        .files = &.{ "llhttp/api.c", "llhttp/http.c", "llhttp/llhttp.c" },
        .flags = &.{"-O3"},
    });
    const llhttp_bench = b.addExecutable(.{
        .name = "llhttp",
        .use_llvm = true,
        .root_module = llhttp_mod,
    });

    // `zig build` installs the binaries so they can also be fed to poop directly.
    b.installArtifact(hparse_bench);
    b.installArtifact(headparser_bench);
    b.installArtifact(pico_bench);
    b.installArtifact(llhttp_bench);

    // Pure-Zig timing runner (host tool).
    const runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runner/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            // For the workload table: the runner labels each table with the shape's
            // description and size, and rejects result lines naming a shape that is
            // not in it.
            .imports = &.{.{ .name = "workloads", .module = workloads_module }},
        }),
    });

    const run_bench = b.addRunArtifact(runner);
    run_bench.addArgs(&.{ "--runs", b.fmt("{d}", .{runs}) });
    if (!std.mem.eql(u8, workload, "all")) run_bench.addArgs(&.{ "--workload", workload });
    run_bench.addArg("hparse");
    run_bench.addArtifactArg(hparse_bench);
    run_bench.addArg("std.http");
    run_bench.addArtifactArg(headparser_bench);
    run_bench.addArg("picohttpparser");
    run_bench.addArtifactArg(pico_bench);
    run_bench.addArg("llhttp");
    run_bench.addArtifactArg(llhttp_bench);

    const bench_step = b.step("bench", "Build all parsers and run the wall-clock comparison");
    bench_step.dependOn(&run_bench.step);
}
