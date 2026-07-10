const std = @import("std");

// A single, self-contained build graph for all benchmarks.
//
//   zig build bench                 build every parser + run the comparison
//   zig build bench -Druns=10       more repetitions per parser
//   zig build                       just build the benchmark binaries into zig-out/bin
//
// Parsers compared: hparse, std.http.Server.Request.Head and picohttpparser. The C
// parser is compiled with Zig's bundled clang, so no gcc or make is required — the
// whole flow lives inside `zig build`, no shell or Makefile.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Benchmarks are meaningless in Debug; default to ReleaseFast.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const runs = b.option(usize, "runs", "Repetitions per benchmark (default 5)") orelse 5;
    const iters = b.option(usize, "iters", "Parse iterations per benchmark run (default 1_000_000)") orelse 1_000_000;

    // Compile-time iteration count shared by all three benchmark binaries so the
    // workload stays identical across parsers. std.http is ~30x slower than the rest,
    // so keep the default modest and pass e.g. -Diters=10000000 for a heavier run.
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "iters", iters);
    const options_module = bench_options.createModule();

    // The parser under test, consumed as a normal Zig module from the repo root.
    const hparse = b.dependency("hparse", .{
        .target = target,
        .optimize = optimize,
    }).module("hparse");

    // hparse benchmark (Zig).
    const hparse_bench = b.addExecutable(.{
        .name = "hparse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("hparse/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hparse", .module = hparse },
                .{ .name = "bench_options", .module = options_module },
            },
        }),
    });

    // std.http.Server.Request.Head benchmark (Zig).
    const headparser_bench = b.addExecutable(.{
        .name = "headparser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("headparser/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bench_options", .module = options_module }},
        }),
    });

    // picohttpparser benchmark (C), compiled by `zig cc` — no gcc/make needed.
    const pico_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pico_mod.addCSourceFiles(.{
        .files = &.{ "picohttpparser/main.c", "picohttpparser/picohttpparser.c" },
        .flags = &.{ "-O3", b.fmt("-DITERS={d}", .{iters}) },
    });
    pico_mod.addIncludePath(b.path("picohttpparser"));
    const pico_bench = b.addExecutable(.{
        .name = "picohttpparser",
        .root_module = pico_mod,
    });

    // `zig build` installs the binaries so they can also be fed to poop directly.
    b.installArtifact(hparse_bench);
    b.installArtifact(headparser_bench);
    b.installArtifact(pico_bench);

    // Pure-Zig timing runner (host tool).
    const runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runner/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const run_bench = b.addRunArtifact(runner);
    run_bench.addArgs(&.{ "--runs", b.fmt("{d}", .{runs}) });
    run_bench.addArg("hparse");
    run_bench.addArtifactArg(hparse_bench);
    run_bench.addArg("std.http");
    run_bench.addArtifactArg(headparser_bench);
    run_bench.addArg("picohttpparser");
    run_bench.addArtifactArg(pico_bench);

    const bench_step = b.step("bench", "Build all parsers and run the wall-clock comparison");
    bench_step.dependOn(&run_bench.step);
}
