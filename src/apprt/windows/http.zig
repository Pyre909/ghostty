//! HTTP GETs over WinHTTP, for the update check: the system's TLS, its
//! certificate store and its proxy settings, with no library of our own.
//! The calls block, so they run on a worker thread, never the UI thread.
//!
//! WinHTTP follows redirects itself (GitHub's release downloads redirect
//! to another host), and by default never from HTTPS to HTTP. A session
//! that is `https_only` refuses any other URL before connecting.
//!
//! Ref: https://learn.microsoft.com/windows/win32/winhttp/winhttp-sessions-overview

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const win32 = @import("win32.zig");

const L = win32.L;
const log = std.log.scoped(.win32);

pub const Error = error{
    /// Not a URL WinHTTP can parse, or not HTTPS in an `https_only`
    /// session.
    BadUrl,
    /// A WinHTTP call failed: no connection, a TLS failure, a timeout.
    RequestFailed,
    /// The server answered with a status other than 200.
    HttpStatus,
    /// The body is longer than the caller allows.
    TooLarge,
    /// The body's SHA-256 is not the one expected.
    HashMismatch,
    /// The file could not be created or written.
    WriteFailed,
    OutOfMemory,
};

pub const Options = struct {
    /// Refuse any URL that is not HTTPS.
    https_only: bool = true,
    /// Use the system's proxy settings; tests on loopback go direct.
    system_proxy: bool = true,
};

pub const Session = struct {
    handle: win32.HINTERNET,
    https_only: bool,

    pub fn open(options: Options) Error!Session {
        const access = if (options.system_proxy)
            win32.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
        else
            win32.WINHTTP_ACCESS_TYPE_NO_PROXY;
        const handle = win32.WinHttpOpen(L("Ghostty"), access, null, null, 0) orelse
            return failed("WinHttpOpen");
        // Resolve and connect in 10 s, each send and receive in 30 s:
        // a check never hangs its thread for long.
        if (!win32.WinHttpSetTimeouts(handle, 10_000, 10_000, 30_000, 30_000).toBool()) {
            _ = win32.WinHttpCloseHandle(handle);
            return failed("WinHttpSetTimeouts");
        }
        return .{ .handle = handle, .https_only = options.https_only };
    }

    pub fn close(self: Session) void {
        _ = win32.WinHttpCloseHandle(self.handle);
    }

    /// The body at `url`, the caller's to free; at most `max` bytes.
    pub fn get(self: Session, alloc: Allocator, url: []const u8, max: usize) Error![]u8 {
        var response = try self.request(alloc, url);
        defer response.close();
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(alloc);
        const Sink = struct {
            list: *std.ArrayList(u8),
            alloc: Allocator,
            fn put(sink: @This(), bytes: []const u8) Error!void {
                try sink.list.appendSlice(sink.alloc, bytes);
            }
        };
        try response.read(max, Sink{ .list = &body, .alloc = alloc });
        return body.toOwnedSlice(alloc);
    }

    /// Save the body at `url` to `path`, at most `max` bytes, and check
    /// that its SHA-256 is `sha256`. Any file at `path` is replaced; on
    /// any failure none is left there.
    pub fn download(
        self: Session,
        alloc: Allocator,
        url: []const u8,
        path: [:0]const u16,
        max: usize,
        sha256: [32]u8,
    ) Error!void {
        _ = win32.DeleteFileW(path);
        var response = try self.request(alloc, url);
        defer response.close();

        const file = win32.CreateFileW(
            path,
            win32.GENERIC_WRITE,
            0,
            null,
            win32.CREATE_ALWAYS,
            win32.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (file == win32.INVALID_HANDLE_VALUE) {
            log.warn("update download: CreateFileW failed err={}", .{win32.GetLastError()});
            return error.WriteFailed;
        }
        const saved = save(&response, file, max, sha256);
        _ = win32.CloseHandle(file);
        saved catch |err| {
            _ = win32.DeleteFileW(path);
            return err;
        };
    }

    /// Write the body to `file`, then check its hash.
    fn save(response: *Response, file: win32.HANDLE, max: usize, sha256: [32]u8) Error!void {
        var hash: Sha256 = .init(.{});
        const Sink = struct {
            file: win32.HANDLE,
            hash: *Sha256,
            fn put(sink: @This(), bytes: []const u8) Error!void {
                sink.hash.update(bytes);
                var written: win32.DWORD = 0;
                const ok = win32.WriteFile(sink.file, bytes.ptr, @intCast(bytes.len), &written, null).toBool();
                if (!ok or written != bytes.len) {
                    log.warn("update download: WriteFile failed err={}", .{win32.GetLastError()});
                    return error.WriteFailed;
                }
            }
        };
        try response.read(max, Sink{ .file = file, .hash = &hash });
        var got: [32]u8 = undefined;
        hash.final(&got);
        if (!std.mem.eql(u8, &got, &sha256)) {
            log.warn("update download: SHA-256 {x} is not the feed's {x}", .{ &got, &sha256 });
            return error.HashMismatch;
        }
    }

    /// Send a GET for `url` and wait for its response's headers.
    fn request(self: Session, alloc: Allocator, url: []const u8) Error!Response {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, url) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadUrl,
        };
        defer alloc.free(wide);

        // Pointers into `wide` for the host and the path (with any
        // query), which runs to its end.
        var parts: win32.URL_COMPONENTS = .{
            .dwHostNameLength = std.math.maxInt(win32.DWORD),
            .dwUrlPathLength = std.math.maxInt(win32.DWORD),
        };
        if (!win32.WinHttpCrackUrl(wide.ptr, @intCast(wide.len), 0, &parts).toBool()) return error.BadUrl;
        const secure = switch (parts.nScheme) {
            win32.INTERNET_SCHEME_HTTPS => true,
            win32.INTERNET_SCHEME_HTTP => false,
            else => return error.BadUrl,
        };
        if (self.https_only and !secure) return error.BadUrl;
        const host_ptr = parts.lpszHostName orelse return error.BadUrl;
        if (parts.dwHostNameLength == 0) return error.BadUrl;
        const host = try alloc.dupeSentinel(u16, host_ptr[0..parts.dwHostNameLength], 0);
        defer alloc.free(host);
        const path: [*:0]const u16 = if (parts.lpszUrlPath) |p| @ptrCast(p) else L("/");

        const connect = win32.WinHttpConnect(self.handle, host, parts.nPort, 0) orelse
            return failed("WinHttpConnect");
        errdefer _ = win32.WinHttpCloseHandle(connect);
        const req = win32.WinHttpOpenRequest(
            connect,
            L("GET"),
            path,
            null,
            null,
            null,
            if (secure) win32.WINHTTP_FLAG_SECURE else 0,
        ) orelse return failed("WinHttpOpenRequest");
        errdefer _ = win32.WinHttpCloseHandle(req);
        if (!win32.WinHttpSendRequest(req, null, 0, null, 0, 0, 0).toBool()) return failed("WinHttpSendRequest");
        if (!win32.WinHttpReceiveResponse(req, null).toBool()) return failed("WinHttpReceiveResponse");

        var status: win32.DWORD = 0;
        var len: win32.DWORD = @sizeOf(win32.DWORD);
        if (!win32.WinHttpQueryHeaders(
            req,
            win32.WINHTTP_QUERY_STATUS_CODE | win32.WINHTTP_QUERY_FLAG_NUMBER,
            null,
            &status,
            &len,
            null,
        ).toBool()) return failed("WinHttpQueryHeaders");
        if (status != 200) {
            log.warn("update request: HTTP status {}", .{status});
            return error.HttpStatus;
        }
        return .{ .connect = connect, .request = req };
    }
};

const Response = struct {
    connect: win32.HINTERNET,
    request: win32.HINTERNET,

    fn close(self: *Response) void {
        _ = win32.WinHttpCloseHandle(self.request);
        _ = win32.WinHttpCloseHandle(self.connect);
    }

    /// Hand the body to `sink.put` as it arrives, failing once it passes
    /// `max` bytes, before the bytes past it are handed on.
    fn read(self: *Response, max: usize, sink: anytype) Error!void {
        var buf: [16 * 1024]u8 = undefined;
        var total: usize = 0;
        while (true) {
            var got: win32.DWORD = 0;
            if (!win32.WinHttpReadData(self.request, &buf, buf.len, &got).toBool()) return failed("WinHttpReadData");
            if (got == 0) return;
            total += got;
            if (total > max) return error.TooLarge;
            try sink.put(buf[0..got]);
        }
    }
};

fn failed(comptime what: []const u8) error{RequestFailed} {
    log.warn("update request: " ++ what ++ " failed err={}", .{win32.GetLastError()});
    return error.RequestFailed;
}

const testing = @import("http_testing.zig");
const TestServer = testing.TestServer;
const okResponse = testing.okResponse;

const update_body = "the update's bytes";
/// "0123456789" ten times.
const hundred_bytes: [100]u8 = @bitCast(@as([10][10]u8, @splat("0123456789".*)));

test "win32: an HTTP GET returns the body, follows a redirect and refuses others" {
    const alloc = std.testing.allocator;
    var server: TestServer = undefined;
    // The redirect's target names the server's port, known once it runs.
    var moved_buf: [256]u8 = undefined;
    var routes = [_]TestServer.Route{
        .{ .path = "/feed", .response = okResponse("{\"version\":\"1.0.0\"}") },
        .{ .path = "/big", .response = okResponse(&hundred_bytes) },
        .{ .path = "/moved", .response = "" },
    };
    try server.start(&routes);
    defer server.stop();
    routes[2].response = std.fmt.bufPrint(&moved_buf, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{}/feed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{server.port}) catch unreachable;

    const session: Session = try .open(.{ .https_only = false, .system_proxy = false });
    defer session.close();
    var buf: [128]u8 = undefined;

    const body = try session.get(alloc, server.url(&buf, "/feed"), 1024);
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"version\":\"1.0.0\"}", body);

    const moved = try session.get(alloc, server.url(&buf, "/moved"), 1024);
    defer alloc.free(moved);
    try std.testing.expectEqualStrings("{\"version\":\"1.0.0\"}", moved);

    // At the limit, then one past it.
    const hundred = try session.get(alloc, server.url(&buf, "/big"), 100);
    alloc.free(hundred);
    try std.testing.expectError(error.TooLarge, session.get(alloc, server.url(&buf, "/big"), 99));
    try std.testing.expectError(error.HttpStatus, session.get(alloc, server.url(&buf, "/missing"), 1024));
    try std.testing.expectError(error.BadUrl, session.get(alloc, "not a url", 1024));
    try std.testing.expectError(error.BadUrl, session.get(alloc, "ftp://127.0.0.1/feed", 1024));

    // An HTTPS-only session refuses plain HTTP without a request.
    const before = server.requests.load(.monotonic);
    const strict: Session = try .open(.{ .system_proxy = false });
    defer strict.close();
    try std.testing.expectError(error.BadUrl, strict.get(alloc, server.url(&buf, "/feed"), 1024));
    try std.testing.expectEqual(before, server.requests.load(.monotonic));
}

test "win32: an HTTP download is saved when its hash is the feed's, and removed when not" {
    const alloc = std.testing.allocator;
    var server: TestServer = undefined;
    const routes = [_]TestServer.Route{
        .{ .path = "/update.msi", .response = okResponse(update_body) },
    };
    try server.start(&routes);
    defer server.stop();
    const session: Session = try .open(.{ .https_only = false, .system_proxy = false });
    defer session.close();
    var buf: [128]u8 = undefined;
    const path = try testing.tempPath(alloc, "update.msi");
    defer alloc.free(path);
    defer _ = win32.DeleteFileW(path);

    var sha: [32]u8 = undefined;
    Sha256.hash(update_body, &sha, .{});
    try session.download(alloc, server.url(&buf, "/update.msi"), path, 1024, sha);
    const saved = (try testing.read(alloc, path)).?;
    defer alloc.free(saved);
    try std.testing.expectEqualStrings(update_body, saved);

    // Not found: the earlier file is gone, none saved in its place.
    try std.testing.expectError(error.HttpStatus, session.download(alloc, server.url(&buf, "/nothing.msi"), path, 1024, sha));
    try std.testing.expect(try testing.read(alloc, path) == null);

    // Another hash: refused, and the earlier file is gone too.
    try session.download(alloc, server.url(&buf, "/update.msi"), path, 1024, sha);
    var wrong = sha;
    wrong[0] ^= 1;
    try std.testing.expectError(error.HashMismatch, session.download(alloc, server.url(&buf, "/update.msi"), path, 1024, wrong));
    try std.testing.expect(try testing.read(alloc, path) == null);

    // Too large: no file either.
    try std.testing.expectError(error.TooLarge, session.download(alloc, server.url(&buf, "/update.msi"), path, update_body.len - 1, sha));
    try std.testing.expect(try testing.read(alloc, path) == null);
}
