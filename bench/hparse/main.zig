const std = @import("std");
const hparse = @import("hparse");
const iters = @import("bench_options").iters;

pub fn main() !void {
    const buffer: []const u8 = "GET /cookies HTTP/1.1\r\nHost: 127.0.0.1:8090\r\nConnection: keep-alive\r\nCache-Control: max-age=0\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nUser-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.56 Safari/537.17\r\nAccept-Encoding: gzip,deflate,sdch\r\nAccept-Language: en-US,en;q=0.8\r\nAccept-Charset: ISO-8859-1,utf-8;q=0.7,*;q=0.3\r\nCookie: name=wookie\r\n\r\n";

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var method: hparse.Method = .unknown;
        var path: ?[]const u8 = null;
        var http_version: hparse.Version = .@"1.0";
        var headers: [32]hparse.Header = undefined;
        var header_count: usize = 0;

        const consumed = try hparse.parseRequest(
            buffer[0..],
            &method,
            &path,
            &http_version,
            &headers,
            &header_count,
        );

        // hparse compiles in the same compilation unit as this driver, so without
        // consuming the outputs LLVM dead-code-eliminates parts of the parse. The
        // extern picohttpparser call can't be elided, so eliding here would skew
        // the comparison in hparse's favor.
        std.mem.doNotOptimizeAway(consumed);
        std.mem.doNotOptimizeAway(header_count);
        std.mem.doNotOptimizeAway(&headers);
        std.mem.doNotOptimizeAway(path);
    }
}
