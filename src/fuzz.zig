//! Fuzzing harness for hparse (issue #2).
//!
//! Run modes:
//! * `zig build fuzz` — replays the seed corpus through the oracles once (regression mode).
//! * `zig build fuzz --fuzz` — coverage-guided fuzzing via Zig's native fuzzer.
//!
//! The parser walks the buffer with `[*]const u8` many-item pointers, which Zig's bounds
//! checking does not cover — a 1-byte overread past the slice does not crash and silently
//! reads adjacent memory. A naive "call it and see if it faults" harness would never catch
//! that class. Two oracles make it visible:
//!
//! 1. Guard-page-backed input: every parse runs on a copy whose last byte abuts a
//!    PROT_NONE page, so any read past the end is an immediate SIGSEGV.
//! 2. Prefix/consumed-length exactness: a successful parse consuming N bytes must
//!    reproduce byte-identical results when re-parsing exactly those N bytes, and every
//!    strict prefix of them must return `error.Incomplete` — never a false accept, and
//!    never `error.Invalid` (which would mean the SIMD/SWAR/scalar matcher tiers, selected
//!    by remaining buffer length, disagree about the same bytes).

const std = @import("std");
const builtin = @import("builtin");
const hparse = @import("hparse");

/// Fuzz inputs are capped at one page so a copy always fits in front of the guard page.
const max_input = 1024;

/// Headers slice size for every parse in the harness. Must be the same for the primary
/// parse and the prefix re-parses: with equal capacity, a strict prefix of a successful
/// parse can never legitimately return `error.TooManyHeaders`.
const max_headers = 16;

/// A page of writable memory directly followed by a PROT_NONE page. Inputs are copied so
/// their last byte abuts the guard page, turning any overread into a SIGSEGV the fuzzer
/// records as a crash.
const GuardedRegion = struct {
    page: ?[]align(std.heap.page_size_min) u8 = null,

    fn copy(region: *GuardedRegion, bytes: []const u8) []const u8 {
        @disableInstrumentation();
        if (region.page == null) region.page = allocGuardedPage();
        const page = region.page.?;
        const dst = page[page.len - bytes.len ..];
        @memcpy(dst, bytes);
        return dst;
    }
};

/// Returns one writable page directly followed by an inaccessible page.
fn allocGuardedPage() []align(std.heap.page_size_min) u8 {
    @disableInstrumentation();
    const page_size = std.heap.pageSize();
    std.debug.assert(max_input <= page_size);

    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const process = windows.GetCurrentProcess();

        var base: ?*anyopaque = null;
        var size: windows.SIZE_T = 2 * page_size;
        if (windows.ntdll.NtAllocateVirtualMemory(
            process,
            @ptrCast(&base),
            0,
            &size,
            .{ .COMMIT = true, .RESERVE = true },
            .{ .READWRITE = true },
        ) != .SUCCESS) @panic("NtAllocateVirtualMemory failed");

        var guard_base: ?*anyopaque = @ptrFromInt(@intFromPtr(base.?) + page_size);
        var guard_size: windows.SIZE_T = page_size;
        var old_protection: windows.PAGE = .{};
        if (windows.ntdll.NtProtectVirtualMemory(
            process,
            &guard_base,
            &guard_size,
            .{ .NOACCESS = true },
            &old_protection,
        ) != .SUCCESS) @panic("NtProtectVirtualMemory failed");

        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(base.?));
        return ptr[0..page_size];
    }

    // POSIX: map both pages PROT_NONE, then remap the first page read/write in place;
    // the second page stays inaccessible as the guard.
    const mem = std.posix.mmap(
        null,
        2 * page_size,
        .{},
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch @panic("mmap failed");
    return std.posix.mmap(
        mem.ptr,
        page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1,
        0,
    ) catch @panic("mmap failed");
}

// Two regions so results of the primary parse (slices into `primary`) stay intact while
// re-parses and prefix probes overwrite `probe`.
var primary: GuardedRegion = .{};
var probe: GuardedRegion = .{};

/// Expects `inner` to be a subslice of `outer` (parsers must never hand out slices that
/// point outside the input buffer).
fn expectWithin(outer: []const u8, inner: []const u8) !void {
    @disableInstrumentation();
    const o_start = @intFromPtr(outer.ptr);
    const i_start = @intFromPtr(inner.ptr);
    try std.testing.expect(i_start >= o_start);
    try std.testing.expect(i_start + inner.len <= o_start + outer.len);
}

fn checkRequest(input: []const u8) !void {
    @disableInstrumentation();
    const g = primary.copy(input);

    var method: hparse.Method = .unknown;
    var method_token: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var version: hparse.Version = .@"1.0";
    var headers: [max_headers]hparse.Header = undefined;
    var count: usize = 0;

    // Memory-safety oracle: any overread during this call faults on the guard page.
    const n = hparse.parseRequest(g, &method, &method_token, &path, &version, &headers, &count) catch return;

    // Cheap invariants on every successful parse.
    try std.testing.expect(n <= g.len);
    try std.testing.expect(count <= max_headers);
    try std.testing.expect(method != .unknown);
    try std.testing.expect(method_token != null);
    try std.testing.expect(method_token.?.len >= 1);
    try expectWithin(g, method_token.?);
    try std.testing.expect(path != null);
    try expectWithin(g, path.?);
    for (headers[0..count]) |h| {
        try expectWithin(g, h.key);
        try expectWithin(g, h.value);
    }

    // Consumed-length round-trip: re-parsing exactly the N consumed bytes must give a
    // byte-identical result — proves the parse never depended on bytes past what it
    // claims to consume.
    {
        const g2 = probe.copy(input[0..n]);
        var method2: hparse.Method = .unknown;
        var method_token2: ?[]const u8 = null;
        var path2: ?[]const u8 = null;
        var version2: hparse.Version = .@"1.0";
        var headers2: [max_headers]hparse.Header = undefined;
        var count2: usize = 0;

        const n2 = try hparse.parseRequest(g2, &method2, &method_token2, &path2, &version2, &headers2, &count2);
        try std.testing.expectEqual(n, n2);
        try std.testing.expectEqual(method, method2);
        try std.testing.expectEqualStrings(method_token.?, method_token2.?);
        try std.testing.expectEqual(version, version2);
        try std.testing.expect(path2 != null);
        try std.testing.expectEqualStrings(path.?, path2.?);
        try std.testing.expectEqual(count, count2);
        for (headers[0..count], headers2[0..count]) |h1, h2| {
            try std.testing.expectEqualStrings(h1.key, h2.key);
            try std.testing.expectEqualStrings(h1.value, h2.value);
        }
    }

    // No false accept on truncation: every strict prefix of the consumed bytes must be
    // `error.Incomplete`. `error.Invalid` here means the matcher tier picked for the
    // shorter tail (SIMD vs SWAR vs scalar) judged the same bytes differently.
    for (0..n) |k| {
        const gk = probe.copy(input[0..k]);
        var mk: hparse.Method = .unknown;
        var mtk: ?[]const u8 = null;
        var pk: ?[]const u8 = null;
        var vk: hparse.Version = .@"1.0";
        var hk: [max_headers]hparse.Header = undefined;
        var ck: usize = 0;

        try std.testing.expectError(
            error.Incomplete,
            hparse.parseRequest(gk, &mk, &mtk, &pk, &vk, &hk, &ck),
        );
    }
}

fn checkResponse(input: []const u8) !void {
    @disableInstrumentation();
    const g = primary.copy(input);

    var version: hparse.Version = .@"1.0";
    var status_code: u16 = 0;
    var status_msg: ?[]const u8 = null;
    var headers: [max_headers]hparse.Header = undefined;
    var count: usize = 0;

    // Memory-safety oracle: any overread during this call faults on the guard page.
    const n = hparse.parseResponse(g, &version, &status_code, &status_msg, &headers, &count) catch return;

    // Cheap invariants on every successful parse.
    try std.testing.expect(n <= g.len);
    try std.testing.expect(count <= max_headers);
    try std.testing.expect(status_code <= 999);
    if (status_msg) |msg| try expectWithin(g, msg);
    for (headers[0..count]) |h| {
        try expectWithin(g, h.key);
        try expectWithin(g, h.value);
    }

    // Consumed-length round-trip (see checkRequest).
    {
        const g2 = probe.copy(input[0..n]);
        var version2: hparse.Version = .@"1.0";
        var status_code2: u16 = 0;
        var status_msg2: ?[]const u8 = null;
        var headers2: [max_headers]hparse.Header = undefined;
        var count2: usize = 0;

        const n2 = try hparse.parseResponse(g2, &version2, &status_code2, &status_msg2, &headers2, &count2);
        try std.testing.expectEqual(n, n2);
        try std.testing.expectEqual(version, version2);
        try std.testing.expectEqual(status_code, status_code2);
        try std.testing.expectEqual(status_msg == null, status_msg2 == null);
        if (status_msg) |msg| try std.testing.expectEqualStrings(msg, status_msg2.?);
        try std.testing.expectEqual(count, count2);
        for (headers[0..count], headers2[0..count]) |h1, h2| {
            try std.testing.expectEqualStrings(h1.key, h2.key);
            try std.testing.expectEqualStrings(h1.value, h2.value);
        }
    }

    // No false accept on truncation (see checkRequest).
    for (0..n) |k| {
        const gk = probe.copy(input[0..k]);
        var vk: hparse.Version = .@"1.0";
        var sck: u16 = 0;
        var smk: ?[]const u8 = null;
        var hk: [max_headers]hparse.Header = undefined;
        var ck: usize = 0;

        try std.testing.expectError(
            error.Incomplete,
            hparse.parseResponse(gk, &vk, &sck, &smk, &hk, &ck),
        );
    }
}

/// Bias the generator toward HTTP's structural bytes, not uniform noise.
const byte_weights = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, 0x00, 0xff, 1), // any byte
    .rangeAtMost(u8, 0x20, 0x7e, 4), // printable ASCII
    .value(u8, '\r', 4),
    .value(u8, '\n', 4),
    .value(u8, ':', 3),
    .value(u8, ' ', 3),
    .value(u8, '\t', 2),
    .value(u8, '/', 2),
};

fn fuzzParseRequest(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [max_input]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &byte_weights);
    try checkRequest(buf[0..len]);
}

fn fuzzParseResponse(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [max_input]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &byte_weights);
    try checkResponse(buf[0..len]);
}

/// Corpus entries are consumed in Smith's serialized form: `sliceWeightedBytes` reads a
/// 4-byte little-endian length before the bytes. Raw HTTP text as a corpus entry would
/// have its first 4 bytes eaten as that length, so encode seeds explicitly.
fn seed(comptime s: []const u8) []const u8 {
    comptime {
        var out: [4 + s.len]u8 = undefined;
        std.mem.writeInt(u32, out[0..4], s.len, .little);
        @memcpy(out[4..], s);
        const final = out;
        return &final;
    }
}

const request_corpus = [_][]const u8{
    seed("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
    seed("GET / HTTP/1.1\n\n"), // bare LF terminators (must reject)
    seed("OPTIONS /hey-this-is-kinda-long-path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"),
    seed("POST /submit HTTP/1.0\r\nContent-Length: 5\r\n\r\nhello"),
    seed("DELETE /a/b/c?q=1&r=2#frag HTTP/1.1\r\nAccept: */*\r\n\r\n"),
    seed("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\n"),
    seed("PATCH /x HTTP/1.1\r\nX:\ta\tb \t \r\n\r\n"), // OWS/HTAB edge cases
    seed("GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\nD: 4\r\n\r\n"),
    seed("GET /index.html HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (X11; Linux x86_64) ~zh;q=0.9,*~\r\n\r\n"),
    seed("GET / HTTP/1.1\r\nHost"), // truncated header key
    seed("GET /aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), // truncated path
    seed("TRACE / HTTP/1.1\r\nA B: v\r\n\r\n"), // space in key (must reject)
    seed("PROPFIND /dav HTTP/1.1\r\nDepth: 0\r\n\r\n"), // extension method
    seed("M-SEARCH * HTTP/1.1\r\n\r\n"), // extension method with tchar '-'
    seed("POSTER /x HTTP/1.1\r\n\r\n"), // registered-method prefix collision
};

const response_corpus = [_][]const u8{
    seed("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"),
    seed("HTTP/1.1 418 I'm a teapot\r\nHost: localhost\r\nSome-Number-Sequence: 123291429\r\n\r\n"),
    seed("HTTP/1.0 204\r\n\r\n"), // no status message
    seed("HTTP/1.1 301   Moved Permanently\n\n"), // multiple spaces + bare LF (must reject)
    seed("HTTP/1.1 200 OK\r\nHost: x"), // truncated header value
};

test "fuzz parseRequest" {
    return std.testing.fuzz({}, fuzzParseRequest, .{ .corpus = &request_corpus });
}

test "fuzz parseResponse" {
    return std.testing.fuzz({}, fuzzParseResponse, .{ .corpus = &response_corpus });
}
