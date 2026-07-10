//! Benchmark driver for picohttpparser. The parser itself stays C (compiled by
//! Zig's bundled clang); only this driver is Zig, matching the other benchmarks.

const std = @import("std");
const iters = @import("bench_options").iters;

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

pub fn main() !void {
    const buffer: []const u8 = "GET /cookies HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nConnection: keep-alive\r\nCache-Control: max-age=0\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17\r\nAccept-Encoding: gzip,deflate,sdch\r\nAccept-Language: en-US,en;q=0.8\r\nAccept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3\r\nCookie: name=wookie\r\n\r\n";

    var i: usize = 0;
    while (i < iters) : (i += 1) {
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
}
