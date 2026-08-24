//! Benchmark driver for picohttpparser. The parser itself stays C (compiled by
//! Zig's bundled clang); only this driver is Zig, matching the other benchmarks.

const std = @import("std");
const workloads = @import("workloads");

const phr_header = extern struct {
    name: ?[*]const u8,
    name_len: usize,
    value: ?[*]const u8,
    value_len: usize,
};

extern fn phr_parse_request(
    buf: [*]const u8,
    len: usize,
    method: *?[*]const u8,
    method_len: *usize,
    path: *?[*]const u8,
    path_len: *usize,
    minor_version: *c_int,
    headers: [*]phr_header,
    num_headers: *usize,
    last_len: usize,
) c_int;

pub fn main(init: std.process.Init) !void {
    try workloads.run(init, parseOne);
}

fn parseOne(buffer: []const u8) !void {
    var method: ?[*]const u8 = null;
    var method_len: usize = 0;
    var path: ?[*]const u8 = null;
    var path_len: usize = 0;
    var minor_version: c_int = 0;
    var headers: [32]phr_header = undefined;
    var num_headers: usize = headers.len;

    const rc = phr_parse_request(
        buffer.ptr,
        buffer.len,
        &method,
        &method_len,
        &path,
        &path_len,
        &minor_version,
        &headers,
        &num_headers,
        0,
    );
    if (rc < 0) return error.ParseFailed;
}
