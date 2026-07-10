//! Minimal, dependency-free benchmark runner.
//!
//! Spawns each benchmark binary `--runs` times, measures wall-clock time per run
//! and prints a comparison table. This keeps the whole benchmark flow inside
//! `zig build` — no shell, Makefile, hyperfine or poop required.
//!
//! Wall-clock is a coarser signal than poop's perf counters; for a deeper look
//! (cycles/instructions/cache) run `poop` over the installed binaries in
//! `zig-out/bin/` instead.
//!
//! Usage: bench-runner [--runs N] <name> <path> [<name> <path> ...]

const std = @import("std");
const Io = std.Io;

const Result = struct {
    name: []const u8,
    min_ns: u64,
    mean_ns: u64,
    max_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);

    var runs: usize = 5;
    var i: usize = 1;
    if (i + 1 < args.len and std.mem.eql(u8, args[i], "--runs")) {
        runs = try std.fmt.parseInt(usize, args[i + 1], 10);
        i += 2;
    }

    var results: [16]Result = undefined;
    var n: usize = 0;

    while (i + 1 < args.len) : (i += 2) {
        const name = args[i];
        const path = args[i + 1];

        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;
        var sum_ns: u128 = 0;

        std.debug.print("running {s} ({d} runs)...\n", .{ name, runs });

        var r: usize = 0;
        while (r < runs) : (r += 1) {
            const start = Io.Clock.awake.now(io).nanoseconds;

            var child = try std.process.spawn(io, .{
                .argv = &[_][]const u8{path},
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try child.wait(io);

            const ns: u64 = @intCast(Io.Clock.awake.now(io).nanoseconds - start);

            if (term != .exited or term.exited != 0) {
                std.debug.print("  warning: {s} exited abnormally: {any}\n", .{ name, term });
            }

            min_ns = @min(min_ns, ns);
            max_ns = @max(max_ns, ns);
            sum_ns += ns;
        }

        results[n] = .{
            .name = name,
            .min_ns = min_ns,
            .mean_ns = @intCast(sum_ns / runs),
            .max_ns = max_ns,
        };
        n += 1;
    }

    const items = results[0..n];
    std.mem.sort(Result, items, {}, lessByMin);

    const fastest: f64 = if (n > 0) @floatFromInt(items[0].min_ns) else 1;

    std.debug.print("\n{s:<16} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{ "name", "min", "mean", "max", "rel" });
    std.debug.print("{s}\n", .{"-" ** 58});
    for (items) |res| {
        std.debug.print("{s:<16} {d:>9.3}s {d:>9.3}s {d:>9.3}s {d:>7.2}x\n", .{
            res.name,
            secs(res.min_ns),
            secs(res.mean_ns),
            secs(res.max_ns),
            @as(f64, @floatFromInt(res.min_ns)) / fastest,
        });
    }
}

fn secs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn lessByMin(_: void, a: Result, b: Result) bool {
    return a.min_ns < b.min_ns;
}
