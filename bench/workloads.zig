//! The request shapes every driver parses, and the timing loop that runs them.
//!
//! Two jobs, both of which used to be missing.
//!
//! **One request was not enough.** Every number this repo has ever recorded came
//! from the `chrome` buffer below, which was copy-pasted verbatim into all four
//! drivers. A parse of it is a request line, nine header keys totalling ~93 bytes
//! and nine values totalling ~350 — so a change that halves the cost of scanning
//! header keys moves it by a few percent, which is inside the run-to-run band.
//! The other shapes exist to make one scan dominate, so a change to that scan
//! shows up as a number larger than the noise. They are not realistic traffic and
//! are not meant to be; `chrome` is the one that stands in for that.
//!
//! **Wall-clocking the process was not enough.** The runner used to time
//! `spawn`-to-`wait`, which folds process startup and scheduler luck into a
//! measurement of a parse loop. Timing inside the process and dividing by the
//! iteration count gives ns/parse directly — the unit the parser's own notes are
//! written in — and drops the band by enough to see a single-digit change.
//!
//! Every workload must be *accepted* by all four parsers. A parser that rejects a
//! buffer stops early and posts a fast time for work it did not do, so each driver
//! fails loudly on a parse error rather than counting it. That constraint is why
//! `minimal` still carries a Host header and why no workload uses `Content-Length`
//! or `Transfer-Encoding`: llhttp does framing, and a framing header would have it
//! waiting for a body the other three do not know about.

const std = @import("std");
const Io = std.Io;
const iters = @import("bench_options").iters;

pub const Workload = struct {
    name: []const u8,
    /// A complete request head, CRLF-terminated. Never a partial one: three of
    /// the four parsers here have no resume API, so an incomplete buffer would
    /// compare a restart against a continuation.
    request: []const u8,
    /// What this shape is for. The runner prints it above the table.
    loads: []const u8,
};

/// The request every historical number in this repo was measured on. Keep it
/// byte-identical: it is the only workload whose timings can be compared against
/// numbers recorded before this file existed.
const chrome =
    "GET /cookies HTTP/1.1\r\n" ++
    "Host: 127.0.0.1:8090\r\n" ++
    "Connection: keep-alive\r\n" ++
    "Cache-Control: max-age=0\r\n" ++
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" ++
    "User-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17\r\n" ++
    "Accept-Encoding: gzip,deflate,sdch\r\n" ++
    "Accept-Language: en-US,en;q=0.8\r\n" ++
    "Accept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3\r\n" ++
    "Cookie: name=wookie\r\n" ++
    "\r\n";

/// 127 bytes of request-target, the length the parser's own notes already quote
/// for `matchPath` ("193-194 -> 88-89 on a 127-byte request-target"). Asserted
/// rather than commented, because the comment is the part that rots.
const long_target = "/" ++ ("abcdefghij/" ** 11) ++ "?q=12";

comptime {
    if (long_target.len != 127) @compileError("long_target must stay 127 bytes to match the recorded matchPath numbers");
}

/// 40 bytes of `token`, all of it tchar. Long enough that the scalar key loop's
/// per-byte cost dominates the per-header overhead around it.
const long_key = "X-" ++ ("Long-" ** 7) ++ "Key";

comptime {
    if (long_key.len != 40) @compileError("long_key must stay 40 bytes");
}

/// 390 bytes of field-content, no OWS inside, so the value scan runs its vector
/// loop about twelve times per header at 32 bytes wide.
const long_value = "abcdefghijklmnopqrstuvwxyz0123456789-_." ** 10;

comptime {
    if (long_value.len != 390) @compileError("long_value must stay 390 bytes");
}

pub const all = [_]Workload{
    .{
        .name = "chrome",
        .request = chrome,
        .loads = "everything at once; the historical baseline",
    },
    .{
        .name = "long-path",
        .request = "GET " ++ long_target ++ " HTTP/1.1\r\nHost: h\r\n\r\n",
        .loads = "matchPath, 127-byte target",
    },
    .{
        .name = "long-keys",
        .request = "GET / HTTP/1.1\r\n" ++
            (long_key ++ "1: v\r\n") ++ (long_key ++ "2: v\r\n") ++
            (long_key ++ "3: v\r\n") ++ (long_key ++ "4: v\r\n") ++
            (long_key ++ "5: v\r\n") ++ (long_key ++ "6: v\r\n") ++
            (long_key ++ "7: v\r\n") ++ (long_key ++ "8: v\r\n") ++
            "\r\n",
        .loads = "matchHeaderKey, 8 x 41-byte name, 1-byte values",
    },
    .{
        .name = "long-values",
        .request = "GET / HTTP/1.1\r\n" ++
            ("A: " ++ long_value ++ "\r\n") ++ ("B: " ++ long_value ++ "\r\n") ++
            ("C: " ++ long_value ++ "\r\n") ++ ("D: " ++ long_value ++ "\r\n") ++
            "\r\n",
        .loads = "matchHeaderValue, 4 x 390-byte value",
    },
    .{
        .name = "many-tiny",
        .request = "GET / HTTP/1.1\r\n" ++
            ("A: b\r\n" ** 24) ++
            "\r\n",
        .loads = "per-header overhead: colon, OWS, CRLF, slice stores",
    },
    .{
        // Host is here so llhttp and std.http both accept it, which costs a
        // header but leaves this the shortest buffer of the set — what is left
        // is the fixed cost of a parse: request line, version, terminator.
        .name = "minimal",
        .request = "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
        .loads = "fixed per-parse overhead",
    },
};

// The runner parses driver output as three space-separated fields, so a name
// carrying a space would be read back as a malformed line and reported as noise
// instead of a timing. Checked here rather than trusted, because the failure is
// silent at the far end.
comptime {
    for (all) |w| {
        for (w.name) |c| {
            if (c == ' ') @compileError("workload names must not contain a space: the runner's line protocol splits on it");
        }
    }
}

pub fn indexOf(name: []const u8) ?usize {
    for (all, 0..) |w, i| {
        if (std.mem.eql(u8, w.name, name)) return i;
    }
    return null;
}

/// Times `parseOne` over the selected workloads and prints one
/// `<name> <iters> <nanoseconds>` line each for the runner to aggregate.
///
/// `parseOne` is a comptime parameter so it inlines: a benchmark that measured an
/// indirect call through a function pointer would be measuring the call.
///
/// Results go to stderr, matching the runner's own table. Nothing here writes to
/// stdout.
pub fn run(init: std.process.Init, comptime parseOne: fn ([]const u8) anyerror!void) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // argv[1] is a workload name, or absent for all of them. The build passes
    // `-Dworkload` through to here.
    const selected: []const Workload = if (args.len > 1) blk: {
        const i = indexOf(args[1]) orelse {
            std.debug.print("unknown workload '{s}'; known:", .{args[1]});
            for (all) |k| std.debug.print(" {s}", .{k.name});
            std.debug.print("\n", .{});
            return error.UnknownWorkload;
        };
        break :blk all[i .. i + 1];
    } else &all;

    for (selected) |w| {
        const start = Io.Clock.awake.now(io).nanoseconds;

        var i: usize = 0;
        while (i < iters) : (i += 1) {
            try parseOne(w.request);
        }

        const ns: u64 = @intCast(Io.Clock.awake.now(io).nanoseconds - start);
        std.debug.print("{s} {d} {d}\n", .{ w.name, iters, ns });
    }
}
