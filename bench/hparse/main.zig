const std = @import("std");
const hparse = @import("hparse");
const workloads = @import("workloads");

const Method = hparse.Method;
const Version = hparse.Version;
const Header = hparse.Header;

pub fn main(init: std.process.Init) !void {
    try workloads.run(init, parseOne);
}

fn parseOne(buffer: []const u8) !void {
    var method: Method = .unknown;
    var method_token: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var http_version: Version = .@"1.0";
    var headers: [32]Header = undefined;
    var header_count: usize = 0;

    const consumed = try hparse.parseRequest(
        buffer,
        &method,
        &method_token,
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
    std.mem.doNotOptimizeAway(method_token);
}
