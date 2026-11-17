//! For tests, of http.zig and of the updater: an HTTP/1.1 server on a
//! loopback port, and temporary files to download to. Only tests import
//! this, so none of it reaches a build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ws2_32 = std.os.windows.ws2_32;

const win32 = @import("win32.zig");

/// An HTTP/1.1 server on a loopback port that answers each request by its
/// path from `routes`, one connection at a time, until `stop`.
pub const TestServer = struct {
    const SOCKET = usize;
    const invalid: SOCKET = std.math.maxInt(usize);
    const SockaddrIn = ws2_32.sockaddr.in;
    /// shutdown's `how`: no more sends.
    const SD_SEND = 1;
    /// std declares Winsock's types but not these functions.
    const ws = struct {
        extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
        extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SOCKET;
        extern "ws2_32" fn bind(s: SOCKET, addr: *const SockaddrIn, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getsockname(s: SOCKET, addr: *SockaddrIn, len: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn accept(s: SOCKET, addr: ?*SockaddrIn, len: ?*c_int) callconv(.winapi) SOCKET;
        extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
        extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    };

    /// The whole response, status line to body, for a request's path.
    pub const Route = struct { path: []const u8, response: []const u8 };

    listener: SOCKET,
    port: u16,
    routes: []const Route,
    thread: std.Thread,
    requests: std.atomic.Value(usize) = .init(0),
    /// Requests per route, by the route's index in `routes`.
    route_hits: [max_routes]std.atomic.Value(usize) = @splat(.init(0)),

    const max_routes = 8;

    /// Listen on a free port and serve `routes`, which the caller may
    /// change between requests.
    pub fn start(self: *TestServer, routes: []const Route) !void {
        std.debug.assert(routes.len <= max_routes);
        var data: [512]u8 align(8) = undefined;
        if (ws.WSAStartup(0x0202, &data) != 0) return error.WSAStartup;
        const s = ws.socket(ws2_32.AF.INET, ws2_32.SOCK.STREAM, ws2_32.IPPROTO.TCP);
        if (s == invalid) return error.Socket;
        errdefer _ = ws.closesocket(s);
        var addr: SockaddrIn = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (ws.bind(s, &addr, @sizeOf(SockaddrIn)) != 0) return error.Bind;
        if (ws.listen(s, 4) != 0) return error.Listen;
        var len: c_int = @sizeOf(SockaddrIn);
        if (ws.getsockname(s, &addr, &len) != 0) return error.Name;
        self.* = .{
            .listener = s,
            .port = std.mem.bigToNative(u16, addr.port),
            .routes = routes,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Close the listener, which ends the pending accept, and wait.
    pub fn stop(self: *TestServer) void {
        _ = ws.closesocket(self.listener);
        self.thread.join();
        _ = ws.WSACleanup();
    }

    fn serve(self: *TestServer) void {
        while (true) {
            const c = ws.accept(self.listener, null, null);
            if (c == invalid) return;
            defer _ = ws.closesocket(c);
            var buf: [4096]u8 = undefined;
            var n: usize = 0;
            while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null and n < buf.len) {
                const got = ws.recv(c, buf[n..].ptr, @intCast(buf.len - n), 0);
                if (got <= 0) break;
                n += @intCast(got);
            }
            _ = self.requests.fetchAdd(1, .monotonic);
            const line_end = std.mem.indexOf(u8, buf[0..n], "\r\n") orelse n;
            var words = std.mem.splitScalar(u8, buf[0..line_end], ' ');
            _ = words.next();
            const path = words.next() orelse "";
            const response = for (self.routes, 0..) |r, i| {
                if (std.mem.eql(u8, r.path, path)) {
                    _ = self.route_hits[i].fetchAdd(1, .monotonic);
                    break r.response;
                }
            } else "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            var sent: usize = 0;
            while (sent < response.len) {
                const put = ws.send(c, response[sent..].ptr, @intCast(response.len - sent), 0);
                if (put <= 0) break;
                sent += @intCast(put);
            }
            _ = ws.shutdown(c, SD_SEND);
        }
    }

    /// How many requests route `index` has answered.
    pub fn hits(self: *const TestServer, index: usize) usize {
        return self.route_hits[index].load(.monotonic);
    }

    /// `path` on this server, in `buf`.
    pub fn url(self: *const TestServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{}{s}", .{ self.port, path }) catch unreachable;
    }
};

/// A 200 response carrying `body`, for a `TestServer.Route`.
pub fn okResponse(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len}) ++ body;
}

/// The temporary directory's path, ending in a separator, the caller's
/// to free.
pub fn tempDir(alloc: Allocator) ![]u16 {
    var dir: [win32.MAX_PATH + 1]u16 = undefined;
    const n = win32.GetTempPathW(dir.len, @ptrCast(&dir));
    if (n == 0 or n >= dir.len) return error.TempPath;
    return alloc.dupe(u16, dir[0..n]);
}

/// A directory of a test's own in the temporary directory, made empty,
/// and removed with its files by `deinit`: what the updater prunes there
/// is only the test's.
pub const TempDir = struct {
    /// Ends in a separator, as the updater's package directory does.
    path: []u16,

    pub fn init(alloc: Allocator, name: []const u8) !TempDir {
        const base = try tempPath(alloc, name);
        defer alloc.free(base);
        if (!win32.CreateDirectoryW(base, null).toBool() and win32.GetLastError() != .ALREADY_EXISTS)
            return error.CreateDirectory;
        const self: TempDir = .{ .path = try std.mem.concat(alloc, u16, &.{ base, &.{'\\'} }) };
        self.empty(alloc);
        return self;
    }

    pub fn deinit(self: TempDir, alloc: Allocator) void {
        self.empty(alloc);
        const dir = alloc.dupeSentinel(u16, self.path[0 .. self.path.len - 1], 0) catch return;
        defer alloc.free(dir);
        _ = win32.RemoveDirectoryW(dir);
        alloc.free(self.path);
    }

    /// `name` in the directory, the caller's to free.
    pub fn file(self: TempDir, alloc: Allocator, name: []const u8) ![:0]u16 {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, name);
        defer alloc.free(wide);
        return std.mem.concatWithSentinel(alloc, u16, &.{ self.path, wide }, 0);
    }

    fn empty(self: TempDir, alloc: Allocator) void {
        const glob = std.mem.concatWithSentinel(alloc, u16, &.{ self.path, &.{'*'} }, 0) catch return;
        defer alloc.free(glob);
        var data: win32.WIN32_FIND_DATAW = undefined;
        const find = win32.FindFirstFileW(glob, &data);
        if (find == win32.INVALID_HANDLE_VALUE) return;
        defer _ = win32.FindClose(find);
        while (true) {
            if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) {
                const name = std.mem.sliceTo(&data.cFileName, 0);
                if (std.mem.concatWithSentinel(alloc, u16, &.{ self.path, name }, 0)) |path| {
                    _ = win32.DeleteFileW(path);
                    alloc.free(path);
                } else |_| {}
            }
            if (!win32.FindNextFileW(find, &data).toBool()) break;
        }
    }
};

/// A temporary file's path, the caller's to free.
pub fn tempPath(alloc: Allocator, name: []const u8) ![:0]u16 {
    const dir = try tempDir(alloc);
    defer alloc.free(dir);
    const prefix = try std.unicode.utf16LeToUtf8Alloc(alloc, dir);
    defer alloc.free(prefix);
    const full = try alloc.print("{s}ghostty-http-{}-{s}", .{ prefix, std.os.windows.GetCurrentProcessId(), name });
    defer alloc.free(full);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, full);
}

/// The contents of `path`, or null if there is no such file.
pub fn read(alloc: Allocator, path: [:0]const u16) !?[]u8 {
    const file = win32.CreateFileW(path, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) return null;
    defer _ = win32.CloseHandle(file);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        var got: win32.DWORD = 0;
        if (!win32.ReadFile(file, &buf, buf.len, &got, null).toBool()) return error.Read;
        if (got == 0) break;
        try out.appendSlice(alloc, buf[0..got]);
    }
    return try out.toOwnedSlice(alloc);
}

/// How many files match `path` followed by `pattern`, a FindFirstFileW
/// wildcard such as ".*.part".
pub fn countMatching(alloc: Allocator, path: [:0]const u16, pattern: []const u8) !usize {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, pattern);
    defer alloc.free(wide);
    const glob = try std.mem.concatWithSentinel(alloc, u16, &.{ path, wide }, 0);
    defer alloc.free(glob);
    var data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(glob, &data);
    if (find == win32.INVALID_HANDLE_VALUE) return 0;
    defer _ = win32.FindClose(find);
    var n: usize = 1;
    while (win32.FindNextFileW(find, &data).toBool()) n += 1;
    return n;
}

/// Whether `path` could be opened for writing now. Sharing everything,
/// so that only the share modes of the handles open on it decide.
pub fn writable(path: [:0]const u16) bool {
    const share = win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE;
    const file = win32.CreateFileW(path, win32.GENERIC_WRITE, share, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) return false;
    _ = win32.CloseHandle(file);
    return true;
}

/// Write `bytes` to `path`, replacing any file there.
pub fn write(path: [:0]const u16, bytes: []const u8) !void {
    const file = win32.CreateFileW(path, win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) return error.Create;
    defer _ = win32.CloseHandle(file);
    var written: win32.DWORD = 0;
    if (!win32.WriteFile(file, bytes.ptr, @intCast(bytes.len), &written, null).toBool() or written != bytes.len) return error.Write;
}
