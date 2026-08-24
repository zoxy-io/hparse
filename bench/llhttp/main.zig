//! Benchmark driver for llhttp. The parser itself stays C (compiled by Zig's
//! bundled clang, same as picohttpparser); only this driver is Zig.

const std = @import("std");
const workloads = @import("workloads");

// Manually declared to match include/llhttp.h field-for-field, rather than
// pulling the whole header through @cImport for a struct this small.
const llhttp_t = extern struct {
    _index: i32,
    _span_pos0: ?*anyopaque,
    _span_cb0: ?*anyopaque,
    @"error": i32,
    reason: ?[*:0]const u8,
    error_pos: ?[*:0]const u8,
    data: ?*anyopaque,
    _current: ?*anyopaque,
    content_length: u64,
    @"type": u8,
    method: u8,
    http_major: u8,
    http_minor: u8,
    header_state: u8,
    lenient_flags: u16,
    upgrade: u8,
    finish: u8,
    flags: u16,
    status_code: u16,
    initial_message_completed: u8,
    settings: ?*const anyopaque,
};

const llhttp_cb = ?*const fn (*llhttp_t) callconv(.c) c_int;
const llhttp_data_cb = ?*const fn (*llhttp_t, [*]const u8, usize) callconv(.c) c_int;

const llhttp_settings_t = extern struct {
    on_message_begin: llhttp_cb = null,
    on_protocol: llhttp_data_cb = null,
    on_url: llhttp_data_cb = null,
    on_status: llhttp_data_cb = null,
    on_method: llhttp_data_cb = null,
    on_version: llhttp_data_cb = null,
    on_header_field: llhttp_data_cb = null,
    on_header_value: llhttp_data_cb = null,
    on_chunk_extension_name: llhttp_data_cb = null,
    on_chunk_extension_value: llhttp_data_cb = null,
    on_headers_complete: llhttp_cb = null,
    on_body: llhttp_data_cb = null,
    on_message_complete: llhttp_cb = null,
    on_protocol_complete: llhttp_cb = null,
    on_url_complete: llhttp_cb = null,
    on_status_complete: llhttp_cb = null,
    on_method_complete: llhttp_cb = null,
    on_version_complete: llhttp_cb = null,
    on_header_field_complete: llhttp_cb = null,
    on_header_value_complete: llhttp_cb = null,
    on_chunk_extension_name_complete: llhttp_cb = null,
    on_chunk_extension_value_complete: llhttp_cb = null,
    on_chunk_header: llhttp_cb = null,
    on_chunk_complete: llhttp_cb = null,
    on_reset: llhttp_cb = null,
};

const HTTP_REQUEST: c_int = 1;

extern fn llhttp_init(parser: *llhttp_t, @"type": c_int, settings: *const llhttp_settings_t) void;
extern fn llhttp_execute(parser: *llhttp_t, data: [*]const u8, len: usize) c_int;

// No callbacks: no workload carries a body (none of them set Content-Length or
// Transfer-Encoding), so llhttp reaches message-complete and stops at the end of
// the buffer without one, matching the "headers only" shape of the other
// benchmarks.
const settings: llhttp_settings_t = .{};

pub fn main(init: std.process.Init) !void {
    try workloads.run(init, parseOne);
}

fn parseOne(buffer: []const u8) !void {
    var parser: llhttp_t = undefined;
    llhttp_init(&parser, HTTP_REQUEST, &settings);
    const err = llhttp_execute(&parser, buffer.ptr, buffer.len);
    if (err != 0) return error.ParseFailed;
}
