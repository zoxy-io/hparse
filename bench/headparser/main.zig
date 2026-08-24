const std = @import("std");
const workloads = @import("workloads");

const Head = std.http.Server.Request.Head;

pub fn main(init: std.process.Init) !void {
    try workloads.run(init, parseOne);
}

fn parseOne(buffer: []const u8) !void {
    const head = try Head.parse(buffer);
    // Same compilation unit as the parser — consume the result so LLVM can't
    // elide parts of the parse (see hparse/main.zig).
    std.mem.doNotOptimizeAway(head);
}
