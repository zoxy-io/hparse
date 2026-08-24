//! Minimal, dependency-free benchmark runner.
//!
//! Spawns each benchmark binary `--runs` times and prints one comparison table
//! per workload. This keeps the whole benchmark flow inside `zig build` — no
//! shell, Makefile, hyperfine or poop required.
//!
//! The timing is done *inside* each benchmark binary and reported back on stderr
//! as `<workload> <iters> <nanoseconds>` lines, which this runner parses. It used
//! to wall-clock `spawn`-to-`wait` instead; that folded process startup and
//! scheduler luck into every measurement, and at ~70 ns/parse those are not small
//! enough to ignore. Every line a driver writes is accounted for: one that does
//! not parse as a result is forwarded with the driver's name in front of it, on
//! either stream, so a panic or a rejected workload stays visible rather than
//! being silently dropped.
//!
//! Wall-clock is still a coarser signal than perf counters; for cycles,
//! instructions and cache, run `poop` over the installed binaries in `zig-out/bin/`
//! (each takes an optional workload name as its one argument).
//!
//! Usage: bench-runner [--runs N] [--workload NAME] <name> <path> [<name> <path> ...]

const std = @import("std");
const Io = std.Io;
const workloads = @import("workloads");
const assert = std.debug.assert;

/// Enough for the four parsers `build.zig` passes, with room to add. A real
/// bound rather than an assert: this binary is built `.optimize = .ReleaseFast`,
/// where assertions are gone and an out-of-range write would be silent
/// corruption instead of a panic. Same reasoning the parser applies to `Resume`.
const max_parsers = 16;

const workload_count = workloads.all.len;

/// One parser's timings for one workload, across all runs. `runs == 0` means the
/// parser reported nothing for this workload, which is the normal case when
/// `--workload` selected a different one.
const Result = struct {
    name: []const u8,
    runs: usize,
    min_ns_per_parse: f64,
    mean_ns_per_parse: f64,
    max_ns_per_parse: f64,
};

/// Running min/mean/max for one (parser, workload) pair.
const Accumulator = struct {
    min: f64 = std.math.floatMax(f64),
    max: f64 = 0,
    sum: f64 = 0,
    runs: usize = 0,

    fn add(acc: *Accumulator, ns_per_parse: f64) void {
        acc.min = @min(acc.min, ns_per_parse);
        acc.max = @max(acc.max, ns_per_parse);
        acc.sum += ns_per_parse;
        acc.runs += 1;
    }

    fn result(acc: Accumulator, name: []const u8) Result {
        if (acc.runs == 0) return .{ .name = name, .runs = 0, .min_ns_per_parse = 0, .mean_ns_per_parse = 0, .max_ns_per_parse = 0 };

        return .{
            .name = name,
            .runs = acc.runs,
            .min_ns_per_parse = acc.min,
            .mean_ns_per_parse = acc.sum / @as(f64, @floatFromInt(acc.runs)),
            .max_ns_per_parse = acc.max,
        };
    }
};

const Options = struct {
    runs: usize = 5,
    /// Passed through to each driver as its one argument. Null runs them all.
    workload: ?[]const u8 = null,
    /// Index in argv of the first `<name> <path>` pair.
    first_parser: usize = 1,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    const opts = try parseArgs(args);

    var table: [max_parsers][workload_count]Result = undefined;
    var parsers: usize = 0;

    var i = opts.first_parser;
    while (i + 1 < args.len) : (i += 2) {
        if (parsers == max_parsers) return error.TooManyParsers;

        table[parsers] = try measure(alloc, io, args[i], args[i + 1], opts);
        parsers += 1;
    }
    assert(parsers <= max_parsers);

    for (workloads.all, 0..) |workload, w| {
        printTable(workload, table[0..parsers], w);
    }
}

fn parseArgs(args: []const []const u8) !Options {
    assert(args.len >= 1);

    var opts: Options = .{};
    var i: usize = 1;
    while (i + 1 < args.len) {
        if (std.mem.eql(u8, args[i], "--runs")) {
            opts.runs = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 2;
        } else {
            if (std.mem.eql(u8, args[i], "--workload")) {
                opts.workload = args[i + 1];
                i += 2;
            } else {
                break;
            }
        }
    }

    // Zero runs would leave every accumulator empty and print nothing at all,
    // which reads as "the parsers reported nothing" rather than as a bad flag.
    if (opts.runs == 0) return error.ZeroRuns;

    opts.first_parser = i;
    return opts;
}

/// Runs one benchmark binary `opts.runs` times and folds its reported lines into
/// one `Result` per workload.
fn measure(
    alloc: std.mem.Allocator,
    io: Io,
    name: []const u8,
    path: []const u8,
    opts: Options,
) ![workload_count]Result {
    assert(opts.runs > 0);

    std.debug.print("running {s} ({d} runs)...\n", .{ name, opts.runs });

    const argv: []const []const u8 = if (opts.workload) |w| &.{ path, w } else &.{path};

    var acc: [workload_count]Accumulator = @splat(.{});

    var r: usize = 0;
    while (r < opts.runs) : (r += 1) {
        const res = try std.process.run(alloc, io, .{ .argv = argv });

        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("  warning: {s} exited abnormally: {any}\n", .{ name, res.term });
        }

        collect(name, res.stderr, &acc);
        // Drivers report on stderr and never write stdout, so anything here is
        // something nobody planned for. Show it rather than discard it.
        collect(name, res.stdout, &acc);
    }

    var out: [workload_count]Result = undefined;
    for (acc, 0..) |a, w| {
        out[w] = a.result(name);
    }
    return out;
}

/// Folds one stream of driver output into `acc`, forwarding anything that is not
/// a result line.
fn collect(name: []const u8, stream: []const u8, acc: *[workload_count]Accumulator) void {
    var lines = std.mem.tokenizeScalar(u8, stream, '\n');
    while (lines.next()) |line| {
        const parsed = parseLine(line) orelse {
            // A panic, a warning, an unknown-workload message. Pass it through.
            std.debug.print("  {s}: {s}\n", .{ name, line });
            continue;
        };

        const w = workloads.indexOf(parsed.workload) orelse {
            std.debug.print("  {s}: result for unknown workload '{s}'\n", .{ name, parsed.workload });
            continue;
        };

        // A driver that reported zero iterations would divide to infinity and
        // poison the minimum for every later run.
        if (parsed.iters == 0) {
            std.debug.print("  {s}: zero iterations reported for '{s}'\n", .{ name, parsed.workload });
            continue;
        }

        acc[w].add(@as(f64, @floatFromInt(parsed.ns)) / @as(f64, @floatFromInt(parsed.iters)));
    }
}

fn printTable(workload: workloads.Workload, rows: []const [workload_count]Result, w: usize) void {
    assert(w < workload_count);
    assert(rows.len <= max_parsers);

    var items: [max_parsers]Result = undefined;
    var n: usize = 0;
    for (rows) |row| {
        if (row[w].runs == 0) continue;

        items[n] = row[w];
        n += 1;
    }

    // Nothing reported this workload, because `--workload` selected another one.
    if (n == 0) return;

    const shown = items[0..n];
    std.mem.sort(Result, shown, {}, lessByMin);
    const fastest = shown[0].min_ns_per_parse;

    std.debug.print("\n{s} — {s}, {d} bytes\n", .{ workload.name, workload.loads, workload.request.len });
    std.debug.print("{s:<16} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{ "name", "min", "mean", "max", "rel" });
    std.debug.print("{s}\n", .{"-" ** 58});
    for (shown) |res| {
        std.debug.print("{s:<16} {d:>7.1} ns {d:>7.1} ns {d:>7.1} ns {d:>7.2}x\n", .{
            res.name,
            res.min_ns_per_parse,
            res.mean_ns_per_parse,
            res.max_ns_per_parse,
            res.min_ns_per_parse / fastest,
        });
    }
}

const Line = struct {
    workload: []const u8,
    iters: u64,
    ns: u64,
};

/// `<workload> <iters> <nanoseconds>`, or null for anything else.
///
/// Space-separated, which is only unambiguous because no workload name contains
/// a space — `workloads.all` asserts that at comptime rather than leaving it a
/// convention this parser would silently misread.
fn parseLine(line: []const u8) ?Line {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const name = it.next() orelse return null;
    const iters_str = it.next() orelse return null;
    const ns_str = it.next() orelse return null;
    if (it.next() != null) return null;

    return .{
        .workload = name,
        .iters = std.fmt.parseInt(u64, iters_str, 10) catch return null,
        .ns = std.fmt.parseInt(u64, ns_str, 10) catch return null,
    };
}

fn lessByMin(_: void, a: Result, b: Result) bool {
    return a.min_ns_per_parse < b.min_ns_per_parse;
}
