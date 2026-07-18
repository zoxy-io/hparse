//! zero allocation, stateless and streaming HTTP parser module.
//! By streaming, it can parse partially received HTTP requests.
//!
//! Line terminators are strictly CRLF: a bare LF is rejected as
//! `error.Invalid`. Accepting both endings is how request smuggling starts
//! — two intermediaries that disagree about where a line ends parse two
//! different messages out of the same bytes (RFC 9112 §2.2 allows the
//! leniency; a proxy-grade parser must not take it).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

/// Block size of the CPU.
const block_size = @sizeOf(usize);

// If suggested vector length is null, prefer not to use vectors!
const use_vectors = blk: {
    const recommended = std.simd.suggestVectorLength(u8);
    break :blk if (recommended == null) false else true;
};

/// This is what we use for vector sizes in vectored operations.
/// If `use_vectors` is false, this gives the default block size for the CPU.
const vec_size = blk: {
    if (std.simd.suggestVectorLength(u8)) |recommended| {
        // In the future, we can look for ways to utilize 512-bit (AVX-512) or even larger registers.
        break :blk if (recommended >= 64) 32 else recommended;
    } else {
        // If vectors are not recommended, we prefer the default block size.
        break :blk block_size;
    }
};

/// `vec_size` as unsigned integer type.
const VectorInt = std.meta.Int(.unsigned, vec_size);

/// HTTP methods.
///
/// The nine registered methods below are matched as 4-byte magic integers
/// — the fast path that keeps this parser quick. Any other legal RFC 9110
/// token (PROPFIND, MKCOL, ...) parses as `.extension`; the raw bytes of
/// every method, registered or not, are returned through `parseRequest`'s
/// `method_token`.
pub const Method = enum(u8) {
    /// Never produced by the parser; use it as the caller-side initialization
    /// sentinel (a successful `parseRequest` always overwrites it).
    unknown,
    get,
    post,
    head,
    put,
    delete,
    connect,
    options,
    trace,
    patch,
    /// A token that is none of the nine above; the bytes live in
    /// `method_token`.
    extension,
};

/// HTTP versions
pub const Version = enum(u1) { @"1.0", @"1.1" };

/// Represents a single HTTP header.
pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

// HTTP methods interpreted as integers
const GET_: u32 = @bitCast([4]u8{ 'G', 'E', 'T', ' ' });
const HEAD: u32 = @bitCast([4]u8{ 'H', 'E', 'A', 'D' });
const POST: u32 = @bitCast([4]u8{ 'P', 'O', 'S', 'T' });
const PUT_: u32 = @bitCast([4]u8{ 'P', 'U', 'T', ' ' });
const DELE: u32 = @bitCast([4]u8{ 'D', 'E', 'L', 'E' });
const CONN: u32 = @bitCast([4]u8{ 'C', 'O', 'N', 'N' });
const OPTI: u32 = @bitCast([4]u8{ 'O', 'P', 'T', 'I' });
const TRAC: u32 = @bitCast([4]u8{ 'T', 'R', 'A', 'C' });
const PATC: u32 = @bitCast([4]u8{ 'P', 'A', 'T', 'C' });

// HTTP versions interpreted as integers
const HTTP_1_0: u64 = @bitCast([8]u8{ 'H', 'T', 'T', 'P', '/', '1', '.', '0' });
const HTTP_1_1: u64 = @bitCast([8]u8{ 'H', 'T', 'T', 'P', '/', '1', '.', '1' });

/// Minimum bytes required for an HTTP/1.x request line.
///
/// `GET / HTTP/1.1\r\n`
const min_request_len = 0x10;

/// * `error.Incomplete` — caller should read more bytes into the buffer and retry.
/// * `error.Invalid` — the request/response is malformed.
/// * `error.TooManyHeaders` — the provided `headers` slice was too small; caller can
///   retry with a larger slice.
pub const ParseRequestError = error{ Incomplete, Invalid, TooManyHeaders };

/// Helper for wandering around & parsing things along the way.
const Cursor = struct {
    /// Pointer to current position of cursor.
    idx: [*]const u8,
    /// Pointer to end of the buffer.
    end: [*]const u8,
    /// Pointer to start of the buffer.
    start: [*]const u8,

    /// Returns the current position.
    inline fn current(cursor: *const Cursor) [*]const u8 {
        return cursor.idx;
    }

    /// Returns the current character.
    inline fn char(cursor: *const Cursor) u8 {
        return cursor.idx[0];
    }

    /// Advances the position of the cursor by given value.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn advance(cursor: *Cursor, by: usize) void {
        cursor.idx += by;
    }

    /// Checks if buffer has `len` length of characters.
    /// `(cursor.end - cursor.idx >= len)`
    inline fn hasLength(cursor: *const Cursor, len: usize) bool {
        return cursor.end - cursor.idx >= len;
    }

    /// Loads a `@Vector(len, u8)` from the current position of cursor without advancing.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn asVector(cursor: *const Cursor, len: comptime_int) @Vector(len, u8) {
        return cursor.idx[0..len].*;
    }

    /// Creates an integer from the current position of the cursor without advancing.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    /// SAFETY: T must be an integer with bit size >= @bitSizeOf(u8).
    inline fn asInteger(cursor: *const Cursor, comptime T: type) T {
        return @bitCast(cursor.idx[0 .. @bitSizeOf(T) / @bitSizeOf(u8)].*);
    }

    /// Peek the current character but don't advance.
    inline fn peek(cursor: *const Cursor, c: u8) bool {
        return cursor.idx[0] == c;
    }

    /// Peek the current and the next but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn peek2(cursor: *const Cursor, c0: u8, c1: u8) bool {
        return cursor.asInteger(u16) == @as(u16, @bitCast([2]u8{ c0, c1 }));
    }

    /// Peek the current and next 2 characters but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn peek3(cursor: *const Cursor, c0: u8, c1: u8, c2: u8) bool {
        return cursor.idx[0] == c0 and cursor.idx[1] == c1 and cursor.idx[2] == c2;
    }

    /// Peek the current and next 3 characters but don't advance.
    /// SAFETY: This function doesn't check if out of bounds reachable.
    inline fn peek4(cursor: *const Cursor, c0: u8, c1: u8, c2: u8, c3: u8) bool {
        return cursor.asInteger(u32) == @as(u32, @bitCast([4]u8{ c0, c1, c2, c3 }));
    }

    /// Moves the cursor until no leading spaces there are.
    inline fn skipSpaces(cursor: *Cursor) void {
        while (cursor.end - cursor.current() > 0 and cursor.char() == ' ') : (cursor.advance(1)) {}
    }

    /// Parses one CRLF line terminator. Bare LF — or anything else — is
    /// `error.Invalid` (see the module doc); a CR at the end of the buffer
    /// is `error.Incomplete` so the caller can read the LF and retry.
    /// Callers guarantee at least one readable byte.
    inline fn parseCrlf(cursor: *Cursor) ParseRequestError!void {
        assert(cursor.end - cursor.current() >= 1);
        if (cursor.char() != '\r') {
            return error.Invalid;
        }
        cursor.advance(1);
        if (cursor.current() == cursor.end) {
            return error.Incomplete;
        }
        if (cursor.char() != '\n') {
            @branchHint(.unlikely);
            return error.Invalid;
        }
        cursor.advance(1);
    }

    /// Parses the method and the trailing space into `method` and
    /// `method_token`. The nine registered methods match as 4-byte magic
    /// integers (the fast path); any other RFC 9110 token (PROPFIND,
    /// MKCOL, ...) takes the fallback scan and comes out as `.extension`.
    /// `method_token` receives the raw token bytes on both paths.
    inline fn parseMethod(
        cursor: *Cursor,
        method: *Method,
        method_token: *?[]const u8,
    ) ParseRequestError!void {
        const token_start = cursor.current();
        if (cursor.matchKnownMethod()) |known| {
            // The cursor sits one past the trailing space; the token is
            // everything before that space.
            const consumed = cursor.current() - token_start;
            assert(consumed >= 4);
            method.* = known;
            method_token.* = token_start[0 .. consumed - 1];
            return;
        }

        // Extension method: scan the token (RFC 9110 §9.1: method = token)
        // up to the delimiting space. Bounded by the buffer end.
        while (cursor.end - cursor.idx > 0 and isValidMethodChar(cursor.char())) {
            cursor.advance(1);
        }
        // Ran out of buffer before any delimiter: read more and retry.
        if (cursor.current() == cursor.end) {
            return error.Incomplete;
        }
        const token_end = cursor.current();
        // An empty token, or a token stopped by anything but the single
        // delimiting space, is malformed.
        if (token_end == token_start) {
            return error.Invalid;
        }
        if (cursor.char() != ' ') {
            return error.Invalid;
        }
        cursor.advance(1);
        method.* = .extension;
        method_token.* = token_start[0 .. token_end - token_start];
    }

    /// Matches the nine registered methods, each with its trailing space,
    /// as 4-byte magic integers. Advances past method and space only on a
    /// match; rewinds to the token start otherwise.
    /// SAFETY: requires 8 readable bytes (`min_request_len` covers it).
    inline fn matchKnownMethod(cursor: *Cursor) ?Method {
        assert(cursor.hasLength(8));
        const token_start = cursor.current();
        // create an u32 out of received bytes to match the method
        const m_u32: u32 = cursor.asInteger(u32);
        // advance 4 since we just consumed 4
        cursor.advance(4);

        const known: ?Method = blk: switch (m_u32) {
            GET_ => break :blk .get,
            POST => {
                // expect space after this
                if (cursor.peek(' ')) {
                    cursor.advance(1);
                    break :blk .post;
                }
                break :blk null;
            },
            HEAD => {
                // expect space after this
                if (cursor.peek(' ')) {
                    cursor.advance(1);
                    break :blk .head;
                }
                break :blk null;
            },
            PUT_ => break :blk .put,
            DELE => {
                // expect `TE ` after this
                if (cursor.peek3('T', 'E', ' ')) {
                    cursor.advance(3);
                    break :blk .delete;
                }
                break :blk null;
            },
            CONN => {
                // expect `ECT ` after this
                if (cursor.peek4('E', 'C', 'T', ' ')) {
                    cursor.advance(4);
                    break :blk .connect;
                }
                break :blk null;
            },
            OPTI => {
                // expect `ONS ` after this
                if (cursor.peek4('O', 'N', 'S', ' ')) {
                    cursor.advance(4);
                    break :blk .options;
                }
                break :blk null;
            },
            TRAC => {
                // expect `E ` after this
                if (cursor.peek2('E', ' ')) {
                    cursor.advance(2);
                    break :blk .trace;
                }
                break :blk null;
            },
            PATC => {
                // expect 'H ' after this
                if (cursor.peek2('H', ' ')) {
                    cursor.advance(2);
                    break :blk .patch;
                }
                break :blk null;
            },
            else => break :blk null,
        };
        if (known == null) {
            // Not a registered method: rewind so the extension-token scan
            // starts from the first byte.
            cursor.idx = token_start;
        }
        return known;
    }

    /// Validates path characters and advances the cursor as much as validated.
    inline fn matchPath(cursor: *Cursor) void {
        // SIMD (vectorized) search
        if (comptime use_vectors) {
            // Prefer vectored search as much as possible.
            while (cursor.hasLength(vec_size)) {
                // Fill a vector with DEL.
                const deletes: @Vector(vec_size, u8) = @splat(0x7f);
                // Fill a vector with spaces.
                const spaces: @Vector(vec_size, u8) = @splat(' ');

                // Load the next chunk from the buffer.
                const chunk = cursor.asVector(vec_size);

                // This does couple of things;
                // * If a char in `chunk` is greater than a space character (32), put a `true` at it's index (false otherwise),
                // * If chunk includes a DEL character (127), put a `false` at it's index (true otherwise),
                // * Glue comparisons via AND NOT (a & ~b).
                //
                // In the end, we have a bitmask where invalid chars are represented as zeroes and valid chars as ones.
                const bits = @intFromBool(chunk > spaces) & ~@intFromBool(chunk == deletes);

                // Cursor will be advanced by this value. If this is not equal to `vec_size`, an invalid char is found.
                // Invalid chars include the space char too, which is also the delimiter of path section.
                const adv_by = @ctz(~@as(VectorInt, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // chunk includes an invalid char or space, we're done
                if (adv_by != vec_size) {
                    return;
                }
            }
        }

        // SWAR search
        while (cursor.hasLength(block_size)) {
            // Fill the largest integer with exclamation marks.
            const bangs = comptime broadcast(usize, '!');
            // Fill the largest integer with DEL.
            const del = comptime broadcast(usize, 0x7f);
            // Fill the largest integer with 1.
            const one = comptime broadcast(usize, 0x01);
            // Fill the largest integer with € (128).
            const full_128 = comptime broadcast(usize, 128);
            // Load the next chunk.
            const chunk = cursor.asInteger(usize);

            // * When a byte in `chunk` is less than `!`, subtraction will wrap around and set the high bit.
            // * The AND NOT part is to make sure only the high bits of characters less than `!` be set.
            const lt = (chunk -% bangs) & ~chunk;

            const xor_del = chunk ^ del;
            const eq_del = (xor_del -% one) & ~xor_del; // == DEL

            // * Create a bitmask out of high bits and count trailing zeroes.
            // * Dividing by byte size (>> 3) converts the bit position to byte index.
            const adv_by = @ctz((lt | eq_del) & full_128) >> 3;

            // advance the cursor
            cursor.advance(adv_by);

            // chunk includes an invalid char or space, we're done
            if (adv_by != block_size) {
                return;
            }
        }

        // last resort, scalar search
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidPathChar(cursor.char())) {
                return;
            }
        }
    }

    /// Parses the path, must be called after `parseMethod`.
    inline fn parsePath(cursor: *Cursor, path: *?[]const u8) ParseRequestError!void {
        // We assume this is called after `parseMethod`.
        const path_start = cursor.current();
        // validate path characters
        cursor.matchPath();
        // after `matchPath` returns, we're at where path ends
        const path_end = cursor.current();

        // If `matchPath` consumed the whole buffer, we reached the end before finding the
        // delimiter. Check this *before* dereferencing so we never read past the end; the
        // caller can read more data and retry.
        if (path_end == cursor.end) {
            return error.Incomplete;
        }

        // Make sure the char caused `matchPath` to return is a space.
        if (cursor.char() == ' ') {
            @branchHint(.likely); // likely go down here

            // set path
            path.* = path_start[0 .. path_end - path_start];

            // skip the space
            cursor.advance(1);
            // done
            return;
        }

        // Invalid character that's not a space (32) and not the end of the buffer, so a
        // malformed request. Can't go further.
        return error.Invalid;
    }

    /// Parses the HTTP version and the trailing CRLF, must be called after `parsePath`.
    inline fn parseVersion(cursor: *Cursor, version: *Version) ParseRequestError!void {
        // We need at least 9 chars to parse the version and the first byte
        // of its CRLF terminator: `HTTP/1.1\r` => 9. The LF is checked
        // incrementally by `parseCrlf` (`HTTP/1.1\r\n` => 10).
        if (cursor.end - cursor.current() < 9) {
            return error.Incomplete;
        }

        // Create an integer from current index.
        const chunk = cursor.asInteger(u64);
        // advance as much as consumed
        cursor.advance(8);

        // Match the version with magic integers.
        version.* = blk: switch (chunk) {
            HTTP_1_0 => break :blk .@"1.0",
            HTTP_1_1 => break :blk .@"1.1",
            else => return error.Invalid, // Unknown/unsupported HTTP version.
        };

        // Parse the trailing CRLF (strict; bare LF is invalid).
        try cursor.parseCrlf();
    }

    /// Validates header keys.
    /// Prefers SSE (128-bits) instead since header keys are rather small.
    inline fn matchHeaderKey(cursor: *Cursor) void {
        if (comptime use_vectors) {
            const sse_vec_size = 16;
            const Vec = @Vector(sse_vec_size, u8);
            const Int = std.meta.Int(.unsigned, sse_vec_size);

            while (cursor.hasLength(sse_vec_size)) {
                const spaces: Vec = @splat(' ');
                const colons: Vec = @splat(':');
                const deletes: Vec = @splat(0x7f);

                const chunk = cursor.asVector(sse_vec_size);

                const bits = @intFromBool(chunk > spaces) & ~(@intFromBool(chunk == colons) | @intFromBool(chunk == deletes));

                const adv_by = @ctz(~@as(Int, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // chunk includes an invalid char or CRLF, we're done
                if (adv_by != sse_vec_size) {
                    return;
                }
            }
        }

        // NOTE: SWAR is not preferred here, this might change in the future
        // but honestly header keys are not so long.

        // fallback for len < 16
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidKeyChar(cursor.char())) {
                return;
            }
        }
    }

    /// Validates header values.
    inline fn matchHeaderValue(cursor: *Cursor) void {
        // Unlike headers keys, prefer vectors initially when validating header values if possible.
        if (comptime use_vectors) {
            while (cursor.hasLength(vec_size)) {
                // Fill a vector with TAB (\t, 9).
                const tabs: @Vector(vec_size, u8) = @splat(0x9);
                // Fill a vector with DEL (127).
                const deletes: @Vector(vec_size, u8) = @splat(0x7f);
                // Fill a vector with US (31).
                const full_31: @Vector(vec_size, u8) = @splat(0x1f);
                // Load the next chunk from the buffer.
                const chunk = cursor.asVector(vec_size);

                // A byte is a valid value char if it's greater than US (31) OR is a TAB,
                // and isn't DEL (127). TAB is allowed since it's legal inside field values
                // (RFC 7230 field-content permits SP / HTAB between field-vchars).
                const bits = (@intFromBool(chunk > full_31) | @intFromBool(chunk == tabs)) & ~@intFromBool(chunk == deletes);

                const adv_by = @ctz(~@as(VectorInt, @bitCast(bits)));

                // advance the cursor
                cursor.advance(adv_by);

                // chunk includes an invalid char or CRLF, we're done
                if (adv_by != vec_size) {
                    return;
                }
            }
        }

        // SWAR search
        while (cursor.hasLength(block_size)) {
            const spaces = comptime broadcast(usize, ' ');
            const ones = comptime broadcast(usize, 0x01);
            const dels = comptime broadcast(usize, 0x7f);
            const full_128 = comptime broadcast(usize, 128);

            const chunk = cursor.asInteger(usize);

            const lt = (chunk -% spaces) & ~chunk;

            const xor_dels = chunk ^ dels;
            const eq_del = (xor_dels -% ones) & ~xor_dels;

            const adv_by = @ctz((lt | eq_del) & full_128) >> 3;

            cursor.advance(adv_by);

            // chunk includes a control char, CRLF or DEL, we've stopped on it.
            if (adv_by != block_size) {
                // TAB (9) is a legal value char. We can't mask it out of the less-than
                // detection above — the borrow from a genuine < 32 byte perturbs the next
                // byte's high bit — so instead we handle it here: skip the TAB and keep
                // scanning. `@ctz` gives the *first* stop, so we always land on the TAB
                // itself before any borrow-induced false positive after it.
                if (cursor.char() == '\t') {
                    cursor.advance(1);
                    continue;
                }
                return;
            }
        }

        // fallback, scalar search
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidValueChar(cursor.char())) {
                return;
            }
        }
    }

    /// Parses a single header.
    inline fn parseHeader(cursor: *Cursor, header: *Header) ParseRequestError!void {
        const key_start = cursor.current();
        cursor.matchHeaderKey();
        const key_end = cursor.current();

        // If `matchHeaderKey` consumed the whole buffer, we reached the end before finding
        // the delimiter. Check before dereferencing so we never read past the end; the
        // caller can read more data and retry.
        if (key_end == cursor.end) {
            return error.Incomplete;
        }

        // Make sure the invalid character is a colon (58).
        switch (cursor.char()) {
            ':' => {
                @branchHint(.likely);

                // This means 0 length header key, which is invalid.
                if (key_end == key_start) {
                    return error.Invalid;
                }

                // move forward
                cursor.advance(1);
            },
            // Any character that's not a colon (58), and not the end of the buffer, so a
            // malformed request. Can't go further.
            else => return error.Invalid,
        }

        // Trim leading optional whitespace (OWS = SP / HTAB) per RFC 7230.
        while (cursor.end - cursor.current() > 0 and (cursor.char() == ' ' or cursor.char() == '\t')) : (cursor.advance(1)) {}

        // Found where header value starts.
        const val_start = cursor.current();
        cursor.matchHeaderValue();
        const val_end = cursor.current();

        // Same as the key above: if the value ran to the end of the buffer we need more
        // bytes to find its terminator. Check before dereferencing.
        if (val_end == cursor.end) {
            return error.Incomplete;
        }

        // Only CRLF ends the value (strict; bare LF is invalid).
        try cursor.parseCrlf();

        // Trim trailing optional whitespace (OWS = SP / HTAB) per RFC 7230
        // (field-value = OWS field-content OWS). The cursor already sits on the terminator;
        // we only shrink the recorded slice.
        var value = val_start[0 .. val_end - val_start];
        while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) {
            value.len -= 1;
        }

        // Header is set.
        header.* = .{
            .key = key_start[0 .. key_end - key_start],
            .value = value,
        };
    }

    /// Parses HTTP request headers.
    /// If the `headers` slice fills up before the terminating CRLF and another header
    /// follows, returns `error.TooManyHeaders` so the caller can retry with a larger slice.
    inline fn parseHeaders(cursor: *Cursor, headers: []Header, count: *usize) ParseRequestError!void {
        var i: usize = 0;
        while (i < headers.len) : (i += 1) {
            // We need at least one byte to tell whether the header section has ended or
            // another header follows. Guard before dereferencing so we never read past the
            // end on a truncated request.
            if (cursor.current() == cursor.end) {
                return error.Incomplete;
            }

            // Check if the headers part has finished: only the strict CRLF
            // empty line ends it. A bare LF here falls through into
            // `parseHeader`, which rejects it as an invalid key character.
            if (cursor.char() == '\r') {
                try cursor.parseCrlf();
                // end of headers
                count.* = i;
                return;
            }

            try cursor.parseHeader(&headers[i]);
        }

        // Set count to highest.
        count.* = i;

        // The `headers` slice is full; we still need the terminating CRLF. Guard before
        // dereferencing so we never read past the end.
        if (cursor.current() == cursor.end) {
            return error.Incomplete;
        }

        // We have to check for the ending CRLF, same as what we're doing at top.
        if (cursor.char() == '\r') {
            try cursor.parseCrlf();
            return;
        }
        // The `headers` slice is full and the next byte isn't the terminating CRLF.
        // If it's a valid header-key character, another header follows and the caller
        // needs a larger `headers` slice; otherwise the request is malformed.
        if (isValidKeyChar(cursor.char())) {
            return error.TooManyHeaders;
        }
        return error.Invalid;
    }

    /// Matches status message for valid characters.
    inline fn matchStatusMessage(cursor: *Cursor) void {
        while (cursor.end - cursor.idx > 0) : (cursor.advance(1)) {
            if (!isValidStatusMsgChar(cursor.char())) {
                return;
            }
        }
    }

    /// Parses the status message in HTTP responses.
    inline fn parseStatusMessage(cursor: *Cursor, status_msg: *?[]const u8) ParseRequestError!void {
        const msg_start = cursor.current();
        cursor.matchStatusMessage();
        const msg_end = cursor.current();

        // If `matchStatusMessage` consumed the whole buffer, we reached the end before the
        // terminator. Check before dereferencing so we never read past the end.
        if (msg_end == cursor.end) {
            return error.Incomplete;
        }

        // The character that stopped `matchStatusMessage` must start a
        // strict CRLF (bare LF is invalid).
        try cursor.parseCrlf();

        // set the status message
        status_msg.* = msg_start[0 .. msg_end - msg_start];
    }
};

/// Table of valid method characters — token (tchar) from RFC 9110 §5.6.2:
/// letters, digits, and "!#$%&'*+-.^_`|~".
const method_map: [256]u1 = blk: {
    var map = [_]u1{0} ** 256;
    for ("!#$%&'*+-.^_`|~") |c| map[c] = 1;
    for ('0'..'9' + 1) |c| map[c] = 1;
    for ('A'..'Z' + 1) |c| map[c] = 1;
    for ('a'..'z' + 1) |c| map[c] = 1;
    break :blk map;
};

/// Checks if a given character is a valid method (token) character.
inline fn isValidMethodChar(c: u8) bool {
    return method_map[c] != 0;
}

/// Table of valid path characters.
const path_map = createCharMap(.{
    // Invalid characters.
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,  16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, ' ', 127,
});

/// Checks if a given character is a valid path character.
inline fn isValidPathChar(c: u8) bool {
    return path_map[c] != 0;
}

/// Table of valid header key characters.
///
/// NOTE: space (' ', 0x20) must be listed as invalid so the scalar fallback agrees with
/// the SIMD path in `matchHeaderKey` (which stops at any byte <= space). Otherwise a key
/// containing a space would be accepted or rejected depending on how many bytes remain.
const key_map = createCharMap(.{
    // Invalid characters.
    0,   1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,  16,
    17,  18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, ' ', ':',
    127,
});

/// Checks if a given character is a valid header key character.
inline fn isValidKeyChar(c: u8) bool {
    return key_map[c] != 0;
}

/// Table of valid header value characters.
///
/// NOTE: TAB (0x09) is intentionally *not* listed as invalid — it's a legal character
/// inside field values (RFC 7230). Leading/trailing TAB is trimmed as OWS in `parseHeader`.
const value_map = createCharMap(.{
    // Invalid characters (control chars except TAB, plus DEL).
    0,  1,  2,  3,  4,  5,  6,  7,  8,  10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127,
});

/// Checks if a given character is a valid header value character.
inline fn isValidValueChar(c: u8) bool {
    return value_map[c] != 0;
}

/// Table of valid status message characters.
const status_msg_map = createCharMap(.{
    // Invalid characters.
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,  16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127,
});

/// Checks if a given character is a valid statuss message character.
inline fn isValidStatusMsgChar(c: u8) bool {
    return status_msg_map[c] != 0;
}

/// Returns an integer filled with a given byte.
inline fn broadcast(comptime T: type, byte: u8) T {
    comptime {
        const bits = @ctz(@as(T, 0));
        const b = @as(T, byte);

        return switch (bits) {
            8 => b * 0x01,
            16 => b * 0x01_01,
            32 => b * 0x01_01_01_01,
            64 => b * 0x01_01_01_01_01_01_01_01,
            else => @compileError("unexpected broadcast size"),
        };
    }
}

/// Returns a table of 8-bit characters where zeros are invalid and ones are valid.
inline fn createCharMap(comptime invalids: anytype) [256]u1 {
    comptime {
        var map: [256]u1 = undefined;
        // Set each index initially.
        @memset(&map, 1);

        // Unset invalid characters.
        for (invalids) |c| map[c] = 0;

        return map;
    }
}

// Public API

/// Parses an HTTP request.
/// * `error.Incomplete` indicates more data is needed to complete the request.
/// * `error.Invalid` indicates request is invalid/malformed.
/// * `error.TooManyHeaders` indicates `headers` was too small; retry with a larger slice.
pub fn parseRequest(
    // Slice we want to parse.
    slice: []const u8,
    /// Parsed method will be stored here. Extension methods (PROPFIND,
    /// MKCOL, ...) come out as `.extension`.
    method: *Method,
    /// The method's raw token bytes ("GET", "PROPFIND", ...) will be
    /// stored here for every successful parse.
    method_token: *?[]const u8,
    /// Parsed path will be stored here.
    path: *?[]const u8,
    /// Parsed HTTP version will be stored here.
    version: *Version,
    /// Parsed headers will be stored here.
    headers: []Header,
    /// Count of parsed headers will be set here.
    header_count: *usize,
) ParseRequestError!usize {
    // We expect at least 15 bytes to start processing.
    if (slice.len < min_request_len) {
        return error.Incomplete;
    }

    // Pointer to start of the buffer.
    const slice_start = slice.ptr;
    // Pointer to end of the buffer
    const slice_end = slice.ptr + slice.len;

    // The cursor helps walking through bytes and parsing things.
    // I should better rename it to `Parser` since it's use cases are more similar to it.
    var cursor = Cursor{ .idx = slice_start, .end = slice_end, .start = slice_start };

    // parse the method
    try cursor.parseMethod(method, method_token);
    // parse the path
    try cursor.parsePath(path);
    // parse the HTTP version
    try cursor.parseVersion(version);
    // parse HTTP headers
    try cursor.parseHeaders(headers, header_count);

    // Return the total consumed length to caller.
    return cursor.current() - cursor.start;
}

/// Minimum response len.
///
/// `HTTP/1.1 200\r\n`
/// Status message (OK) is optional.
const min_res_len = 14;

/// Parses an HTTP response.
/// * `error.Incomplete` indicates more data is needed to complete the response.
/// * `error.Invalid` indicates response is invalid/malformed.
/// * `error.TooManyHeaders` indicates `headers` was too small; retry with a larger slice.
pub fn parseResponse(
    // Slice we want to parse.
    slice: []const u8,
    /// Parsed HTTP version will be stored here.
    version: *Version,
    /// Parsed status code will be stored here.
    status_code: *u16,
    /// Parsed status message will be stored here.
    status_msg: *?[]const u8,
    /// Parsed headers will be stored here.
    headers: []Header,
    /// Count of parsed headers will be set here.
    header_count: *usize,
) ParseRequestError!usize {
    // We need at least `min_res_len` bytes to start parsing.
    if (slice.len < min_res_len) {
        return error.Incomplete;
    }

    const slice_start = slice.ptr;
    const slice_end = slice.ptr + slice.len;

    var cursor = Cursor{ .idx = slice_start, .start = slice_start, .end = slice_end };

    // Parse HTTP version.
    // Request and response differ in this sense so we can't use `Cursor.parseVersion` here.
    {
        const chunk = cursor.asInteger(u64);
        // advance as much as consumed
        cursor.advance(8);

        // Match the version with magic integers.
        version.* = blk: switch (chunk) {
            HTTP_1_0 => break :blk .@"1.0",
            HTTP_1_1 => break :blk .@"1.1",
            else => return error.Invalid, // Unknown/unsupported HTTP version.
        };

        // Parse the space afterwards.
        if (cursor.char() != ' ') {
            @branchHint(.unlikely);
            return error.Invalid;
        }

        // Consume the space.
        cursor.advance(1);
    }

    // Parse status code.
    {
        // Make sure next 3 bytes are numeric (0-9).
        const all_digits = cursor.idx[0] > 47 and cursor.idx[0] < 58 and
            cursor.idx[1] > 47 and cursor.idx[1] < 58 and
            cursor.idx[2] > 47 and cursor.idx[2] < 58;

        if (!all_digits) {
            @branchHint(.unlikely);
            return error.Invalid;
        }

        // Parse the status code.
        const hundreds: u16 = @as(u16, @intCast(cursor.idx[0] - '0')) * 100;
        const tens: u16 = @as(u16, @intCast(cursor.idx[1] - '0')) * 10;
        const ones: u16 = @as(u16, @intCast(cursor.idx[2] - '0'));

        // Set the status code.
        status_code.* = hundreds + tens + ones;

        // eat bytes
        cursor.advance(3);
    }

    // Parse status message if exists, otherwise, parse CRLF and continue.
    switch (cursor.char()) {
        ' ' => {
            // Skip spaces if there are more.
            cursor.skipSpaces();
            // Get status message after.
            try cursor.parseStatusMessage(status_msg);
        },
        // No status message: the next bytes must be the strict CRLF
        // (anything else, bare LF included, is invalid).
        else => try cursor.parseCrlf(),
    }

    // Parse headers.
    try cursor.parseHeaders(headers, header_count);

    // Return the total consumed length to caller.
    return cursor.current() - cursor.start;
}

const testing = std.testing;

/// Testing only.
fn cursorFromBuffer(buf: []const u8) Cursor {
    return .{ .idx = buf.ptr, .start = buf.ptr, .end = buf.ptr + buf.len };
}

test "cursor: parse method/path/version" {
    const check = struct {
        fn func(req: []const u8, expected: Method) !void {
            var cursor = Cursor{ .idx = req.ptr, .start = req.ptr, .end = req.ptr + req.len };

            // test method
            var method = Method.unknown;
            var method_token: ?[]const u8 = null;
            try cursor.parseMethod(&method, &method_token);
            try testing.expectEqual(expected, method);
            try testing.expect(method_token != null);

            // test path
            var path: ?[]const u8 = null;
            try cursor.parsePath(&path);
            try testing.expectEqualStrings("/", path.?);

            // test version
            var version = Version.@"1.0";
            try cursor.parseVersion(&version);
            try testing.expectEqual(.@"1.1", version);
        }
    }.func;

    try check("GET / HTTP/1.1\r\n\r\n", .get);
    try check("POST / HTTP/1.1\r\n\r\n", .post);
    try check("HEAD / HTTP/1.1\r\n\r\n", .head);
    try check("PUT / HTTP/1.1\r\n\r\n", .put);
    try check("DELETE / HTTP/1.1\r\n\r\n", .delete);
    try check("CONNECT / HTTP/1.1\r\n\r\n", .connect);
    try check("OPTIONS / HTTP/1.1\r\n\r\n", .options);
    try check("TRACE / HTTP/1.1\r\n\r\n", .trace);
    try check("PATCH / HTTP/1.1\r\n\r\n", .patch);
}

test "parseRequest: extension methods parse as tokens" {
    const Case = struct { req: []const u8, token: []const u8 };
    const cases = [_]Case{
        .{ .req = "PROPFIND /dav HTTP/1.1\r\nDepth: 1\r\n\r\n", .token = "PROPFIND" },
        .{ .req = "MKCOL /new HTTP/1.1\r\n\r\n", .token = "MKCOL" },
        .{ .req = "M-SEARCH * HTTP/1.1\r\n\r\n", .token = "M-SEARCH" },
        .{ .req = "VERSION-CONTROL /r HTTP/1.1\r\n\r\n", .token = "VERSION-CONTROL" },
        // Registered-method prefixes must fall back to the token scan,
        // not get rejected by the failed magic match.
        .{ .req = "POSTER /x HTTP/1.1\r\n\r\n", .token = "POSTER" },
        .{ .req = "GETX /x HTTP/1.1\r\n\r\n", .token = "GETX" },
        // Tokens are case-sensitive; lowercase is a different (legal) token.
        .{ .req = "get /x HTTP/1.1\r\n\r\n", .token = "get" },
    };

    for (cases) |case| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        const len = try parseRequest(
            case.req,
            &method,
            &method_token,
            &path,
            &version,
            &headers,
            &header_count,
        );
        try testing.expectEqual(case.req.len, len);
        try testing.expectEqual(Method.extension, method);
        try testing.expectEqualStrings(case.token, method_token.?);
        try testing.expectEqual(.@"1.1", version);
    }
}

test "parseRequest: known methods also expose their token" {
    const Case = struct { req: []const u8, method: Method, token: []const u8 };
    const cases = [_]Case{
        .{ .req = "GET / HTTP/1.1\r\n\r\n", .method = .get, .token = "GET" },
        .{ .req = "DELETE / HTTP/1.1\r\n\r\n", .method = .delete, .token = "DELETE" },
        .{ .req = "CONNECT host:443 HTTP/1.1\r\n\r\n", .method = .connect, .token = "CONNECT" },
    };

    for (cases) |case| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        _ = try parseRequest(
            case.req,
            &method,
            &method_token,
            &path,
            &version,
            &headers,
            &header_count,
        );
        try testing.expectEqual(case.method, method);
        try testing.expectEqualStrings(case.token, method_token.?);
    }
}

test "parseRequest: malformed method tokens are rejected" {
    const requests = [_][]const u8{
        "P@TCH / HTTP/1.1\r\n\r\n", // '@' is not a tchar
        " GET / HTTP/1.1\r\n\r\n", // empty token (leading space)
        "\x01GET / HTTP/1.1\r\n\r\n", // control byte before the token
    };

    for (requests) |req| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        try testing.expectError(
            error.Invalid,
            parseRequest(req, &method, &method_token, &path, &version, &headers, &header_count),
        );
    }
}

test "parseRequest: method token without its delimiter stays incomplete" {
    // Sixteen tchar bytes and no space yet: the method may continue in the
    // next read, so the caller must be told to retry, not given Invalid.
    const req = "PROPFINDPROPFIND";
    var method: Method = .unknown;
    var method_token: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var version: Version = .@"1.0";
    var headers: [8]Header = undefined;
    var header_count: usize = 0;

    try testing.expectError(
        error.Incomplete,
        parseRequest(req, &method, &method_token, &path, &version, &headers, &header_count),
    );
}

test "parseRequest: bare LF line terminators are rejected" {
    // One bare LF at every structural position. Accepting any of these is
    // a smuggling ingredient (see the module doc); all must be Invalid,
    // never a successful parse.
    const requests = [_][]const u8{
        "GET / HTTP/1.1\n\r\n", // request line
        "GET / HTTP/1.1\n\n", // request line and empty line
        "GET / HTTP/1.1\r\nHost: a\n\r\n", // header line
        "GET / HTTP/1.1\r\nHost: a\r\n\n", // final empty line
        "GET / HTTP/1.1\r\n\nHost: a\r\n\r\n", // empty line instead of headers
    };

    for (requests) |req| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        try testing.expectError(
            error.Invalid,
            parseRequest(req, &method, &method_token, &path, &version, &headers, &header_count),
        );
    }
}

test "parseResponse: bare LF line terminators are rejected" {
    const responses = [_][]const u8{
        "HTTP/1.1 200 OK\n\r\n", // status line with message
        "HTTP/1.1 200\n\r\n", // status line without message
        "HTTP/1.1 200 OK\r\nHost: a\n\r\n", // header line
        "HTTP/1.1 200 OK\r\nHost: a\r\n\n", // final empty line
    };

    for (responses) |res| {
        var version: Version = .@"1.0";
        var status_code: u16 = 0;
        var status_msg: ?[]const u8 = null;
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        try testing.expectError(
            error.Invalid,
            parseResponse(res, &version, &status_code, &status_msg, &headers, &header_count),
        );
    }
}

test "cursor: match path" {
    // control characters (0..32)
    for (0..33) |c| {
        var buf: [47]u8 = undefined;
        @memset(&buf, @intCast(c));

        var cursor = cursorFromBuffer(&buf);
        cursor.matchPath();

        // Top character must be equal to what we currently iterate.
        try testing.expectEqual(c, cursor.char());
        // It should have start right at the beginning.
        try testing.expectEqual(cursor.start, cursor.current());
        try testing.expect(cursor.end - cursor.current() == buf.len);
    }

    // ASCII (33..126)
    for (33..127) |c| {
        var buf: [47]u8 = undefined;
        @memset(&buf, @intCast(c));

        var cursor = cursorFromBuffer(&buf);
        cursor.matchPath();

        // Buffer should be consumed fully.
        try testing.expectEqual(cursor.end, cursor.current());
        try testing.expect(cursor.end - cursor.current() == 0);
    }

    // DEL control character (127)
    {
        var buf: [47]u8 = undefined;
        @memset(&buf, 0x7f);

        var cursor = cursorFromBuffer(&buf);
        cursor.matchPath();

        // Top character must be equal to what we currently iterate.
        try testing.expectEqual(0x7f, cursor.char());
        // It should have start right at the beginning.
        try testing.expectEqual(cursor.start, cursor.current());
        try testing.expect(cursor.end - cursor.current() == buf.len);
    }

    // Extended ASCII (128..255)
    for (128..256) |c| {
        var buf: [47]u8 = undefined;
        @memset(&buf, @intCast(c));

        var cursor = cursorFromBuffer(&buf);
        cursor.matchPath();

        // Buffer should be consumed fully.
        try testing.expectEqual(cursor.end, cursor.current());
        try testing.expect(cursor.end - cursor.current() == 0);
    }
}

test parseRequest {
    const buffer: []const u8 = "OPTIONS /hey-this-is-kinda-long-path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    var method: Method = .unknown;
    var method_token: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var http_version: Version = .@"1.0";
    var headers: [2]Header = undefined;
    var header_count: usize = 0;

    const len = try parseRequest(buffer[0..], &method, &method_token, &path, &http_version, &headers, &header_count);

    try testing.expect(len == buffer.len);
    try testing.expect(method == .options);
    try testing.expectEqualStrings("OPTIONS", method_token.?);
    try testing.expect(path != null);
    try testing.expectEqualStrings("/hey-this-is-kinda-long-path", path.?);
    try testing.expect(http_version == .@"1.1");
    try testing.expect(header_count == 2);
    try testing.expectEqualStrings("Host", headers[0].key);
    try testing.expectEqualStrings("localhost", headers[0].value);
    try testing.expectEqualStrings("Connection", headers[1].key);
    try testing.expectEqualStrings("close", headers[1].value);
}

test parseResponse {
    const buffer = "HTTP/1.1 418 I'm a teapot\r\nHost: localhost\r\nSome-Number-Sequence: 123291429\r\n\r\n";

    var version: Version = .@"1.0";
    var status_code: u16 = 0;
    var status_msg: ?[]const u8 = null;
    var headers: [2]Header = undefined;
    var header_count: usize = 0;

    const len = try parseResponse(buffer[0..], &version, &status_code, &status_msg, &headers, &header_count);

    try testing.expect(buffer.len == len);
    try testing.expect(version == .@"1.1");
    try testing.expect(status_code == 418);
    try testing.expect(status_msg != null);
    try testing.expectEqualStrings("I'm a teapot", status_msg.?);
    try testing.expect(header_count == 2);
    try testing.expectEqualStrings("Host", headers[0].key);
    try testing.expectEqualStrings("localhost", headers[0].value);
    try testing.expectEqualStrings("Some-Number-Sequence", headers[1].key);
    try testing.expectEqualStrings("123291429", headers[1].value);
}

test "parseRequest: does not read past slice end (OOB regression)" {
    // The backing array is one byte longer than the slice we hand to the parser, and that
    // extra byte is `\n`. Before the end-of-buffer guards, `parseHeaders` would read this
    // byte, treat it as end-of-headers, and report a completed parse that consumed *more*
    // bytes than the slice it was given. It must return `error.Incomplete` instead.
    var backing: [17]u8 = undefined;
    const req = "GET / HTTP/1.1\r\n"; // 16 bytes: well-formed request line, header section truncated
    @memcpy(backing[0..16], req);
    backing[16] = '\n';
    const slice: []const u8 = backing[0..16];

    var method: Method = .unknown;
    var method_token: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var version: Version = .@"1.0";
    var headers: [8]Header = undefined;
    var header_count: usize = 0;

    try testing.expectError(
        error.Incomplete,
        parseRequest(slice, &method, &method_token, &path, &version, &headers, &header_count),
    );
}

test "parseRequest: truncated inputs return Incomplete" {
    // Each of these ends right where the parser would otherwise dereference one byte past
    // the buffer (path, header key, header value, and between-headers). All must report
    // `error.Incomplete` so the caller can read more and retry.
    const truncations = [_][]const u8{
        "GET / HTTP/1.1\r\n", // header section not started, ends on CRLF
        "GET /aaaaaaaaaaaa", // path with no delimiter yet (>= min_request_len)
        "GET / HTTP/1.1\r\nHost", // header key not terminated by ':'
        "GET / HTTP/1.1\r\nHost: x", // header value not terminated by CRLF
        "GET / HTTP/1.1\r\nHost: x\r\n", // one full header, missing final CRLF
    };

    for (truncations) |req| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        try testing.expectError(
            error.Incomplete,
            parseRequest(req, &method, &method_token, &path, &version, &headers, &header_count),
        );
    }
}

test "parseRequest: space in header key is rejected regardless of match path" {
    // The same key "A B" must be rejected whether the SIMD matcher (>= 16 bytes remaining)
    // or the scalar fallback (< 16 bytes) runs. Before `key_map` listed space as invalid,
    // the scalar path accepted "A B" while the SIMD path rejected it.
    const reqs = [_][]const u8{
        "GET / HTTP/1.1\r\nA B: v\r\n\r\n", // short tail -> scalar matchHeaderKey
        "GET / HTTP/1.1\r\nA B: valuevaluevaluevalue\r\n\r\n", // long tail -> SIMD matchHeaderKey
    };

    for (reqs) |req| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        try testing.expectError(
            error.Invalid,
            parseRequest(req, &method, &method_token, &path, &version, &headers, &header_count),
        );
    }
}

test "parseResponse: truncated status/headers return Incomplete" {
    const truncations = [_][]const u8{
        "HTTP/1.1 200\r\n", // status line only, missing final CRLF
        "HTTP/1.1 200 OK", // status message not terminated
        "HTTP/1.1 200 OK\r\nHost: x", // header value not terminated
    };

    for (truncations) |res| {
        var version: Version = .@"1.0";
        var status_code: u16 = 0;
        var status_msg: ?[]const u8 = null;
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        try testing.expectError(
            error.Incomplete,
            parseResponse(res, &version, &status_code, &status_msg, &headers, &header_count),
        );
    }
}

test "parseRequest: OWS/HTAB handling in header values (RFC 7230)" {
    const Case = struct { req: []const u8, expected: []const u8 };
    const cases = [_]Case{
        // leading HTAB after the colon is trimmed
        .{ .req = "GET / HTTP/1.1\r\nHost:\tlocalhost\r\n\r\n", .expected = "localhost" },
        // trailing SP + HTAB are trimmed
        .{ .req = "GET / HTTP/1.1\r\nHost: localhost \t \r\n\r\n", .expected = "localhost" },
        // internal HTAB is preserved (scalar path, short value)
        .{ .req = "GET / HTTP/1.1\r\nX: a\tb\r\n\r\n", .expected = "a\tb" },
        // internal HTAB is preserved (SIMD path, long value)
        .{ .req = "GET / HTTP/1.1\r\nX: aaaaaaaa\tbbbbbbbbbbbb\r\n\r\n", .expected = "aaaaaaaa\tbbbbbbbbbbbb" },
    };

    for (cases) |c| {
        var method: Method = .unknown;
        var method_token: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var version: Version = .@"1.0";
        var headers: [8]Header = undefined;
        var header_count: usize = 0;

        _ = try parseRequest(c.req, &method, &method_token, &path, &version, &headers, &header_count);
        try testing.expect(header_count == 1);
        try testing.expectEqualStrings(c.expected, headers[0].value);
    }
}

test "parseRequest: full headers slice with more headers returns TooManyHeaders" {
    // Three headers but room for only two: the caller should be told to grow the slice
    // rather than getting an indistinguishable error.Invalid.
    const req = "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n";

    var method: Method = .unknown;
    var method_token: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var version: Version = .@"1.0";
    var headers: [2]Header = undefined;
    var header_count: usize = 0;

    try testing.expectError(
        error.TooManyHeaders,
        parseRequest(req, &method, &method_token, &path, &version, &headers, &header_count),
    );

    // With a large enough slice the same request parses cleanly.
    var big: [8]Header = undefined;
    const len = try parseRequest(req, &method, &method_token, &path, &version, &big, &header_count);
    try testing.expect(len == req.len);
    try testing.expect(header_count == 3);
}
