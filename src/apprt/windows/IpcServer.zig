//! The instance's end of IPC (ipc.zig): a named pipe of the user's
//! session that `ghostty +new-window`, `+new-tab` and
//! `+toggle-quick-terminal` connect to, served by a thread of its own.
//!
//! One client at a time. The thread reads its request, hands it to the UI
//! thread by posting a message to a window there (`take`), waits for the
//! answer (`answer`) and writes it back as the reply. No client is kept
//! longer than the limits (`Limits`), and none can make the thread
//! allocate more than for one request (`ipc.max_request`), nor keep the
//! next client out.
//!
//! The pipe is the user's: its name holds the user's SID and the session
//! id, so that each session has its own, and its DACL allows only the
//! user, and only to read, write and wait (`client_access`). The thread
//! checks each client's user as well, and the pipe refuses remote
//! clients. It is made as the name's first instance and its only one, so
//! that a process that made the name first, to read the requests, makes
//! `start` fail rather than take them.
const IpcServer = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const global = @import("../../global.zig");
const ipc = @import("ipc.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// How long a client is given for each part of its exchange, in
/// milliseconds.
pub const Limits = struct {
    /// To send its whole request, from its connection.
    request_ms: u32 = 2000,

    /// For the UI thread to answer, after which the client is told the
    /// request is pending (`ipc.Status.pending`): the UI thread is busy,
    /// and carries it out when it gets to it.
    answer_ms: u32 = 5000,

    /// To take the reply and close, after which it is disconnected.
    close_ms: u32 = 2000,
};

/// How long a client's WaitNamedPipeW waits for the pipe by default
/// (NMPWAIT_USE_DEFAULT_WAIT), in milliseconds.
pub const default_timeout_ms = 2000;

/// For tests: the limits in place of `Limits`' defaults.
pub var test_limits: if (builtin.is_test) ?Limits else void =
    if (builtin.is_test) null else {};

/// For tests: the user every client is taken to run as, in place of its
/// process's.
pub var test_client_user: if (builtin.is_test) ?Sid else void =
    if (builtin.is_test) null else {};

/// For tests: `start` fails as if the thread could not be had.
pub var test_spawn_fails: if (builtin.is_test) bool else void =
    if (builtin.is_test) false else {};

/// For tests: the post to the UI thread fails, as with its queue full.
pub var test_post_fails: if (builtin.is_test) bool else void =
    if (builtin.is_test) false else {};

/// What a client may do: read and write the pipe, read its security (the
/// client checks its owner), and what CreateFileW asks for with any
/// access, FILE_READ_ATTRIBUTES and SYNCHRONIZE (an open allowed the
/// others alone is refused). Not FILE_WRITE_ATTRIBUTES, which
/// SetNamedPipeHandleState needs, so a client reads the reply as bytes,
/// by the length in its header (`ipc.replyTextLength`).
pub const client_access: win32.DWORD = win32.FILE_READ_DATA |
    win32.FILE_WRITE_DATA |
    win32.FILE_READ_ATTRIBUTES |
    win32.READ_CONTROL |
    win32.SYNCHRONIZE;

/// The pipe's security, as SDDL, around the user's SID: the user owns it,
/// and its DACL, protected so that it inherits nothing, allows the user
/// `client_access` and nothing more.
const sddl_format = "O:{s}D:P(A;;0x" ++ std.fmt.comptimePrint("{x}", .{client_access}) ++ ";;;{s})";

/// The longest pipe name, in UTF-16 code units with `\\.\pipe\` and
/// without the NUL (CreateNamedPipeW).
pub const max_name_len = 256;

const pipe_prefix = "\\\\.\\pipe\\";

/// A SID, copied out of the buffer the system gave it in.
pub const Sid = struct {
    bytes: [win32.SECURITY_MAX_SID_SIZE]u8 align(4) = undefined,
    len: u8 = 0,

    pub fn copy(sid: win32.PSID) error{InvalidSid}!Sid {
        if (!win32.IsValidSid(sid).toBool()) return error.InvalidSid;
        const len = win32.GetLengthSid(sid);
        if (len > win32.SECURITY_MAX_SID_SIZE) return error.InvalidSid;
        var result: Sid = .{ .len = @intCast(len) };
        const from: [*]const u8 = @ptrCast(sid);
        @memcpy(result.bytes[0..len], from[0..len]);
        return result;
    }

    pub fn eql(a: *const Sid, b: *const Sid) bool {
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    /// For calls that take a SID they only read.
    pub fn ptr(self: *const Sid) win32.PSID {
        return @ptrCast(@constCast(&self.bytes));
    }

    /// The SID as text (`S-1-5-21-...`), owned by the caller. The system
    /// writes it in ASCII.
    pub fn string(self: *const Sid, alloc: Allocator) error{ OutOfMemory, InvalidSid }![]u8 {
        var text: ?[*:0]u16 = null;
        if (!win32.ConvertSidToStringSidW(self.ptr(), &text).toBool()) return error.InvalidSid;
        defer _ = win32.LocalFree(text);
        const wide = std.mem.span(text orelse return error.InvalidSid);
        const result = try alloc.alloc(u8, wide.len);
        errdefer alloc.free(result);
        for (wide, result) |unit, *byte| {
            byte.* = std.math.cast(u7, unit) orelse return error.InvalidSid;
        }
        return result;
    }
};

/// Whom a process runs as.
pub const Identity = struct {
    user: Sid,

    /// The Terminal Services session.
    session: u32,

    /// Whether the token is elevated, as an administrator's run as
    /// administrator is.
    elevated: bool,

    pub const Error = error{ TokenUnavailable, InvalidSid };

    /// This process's.
    pub fn ofProcess() Error!Identity {
        var token: win32.HANDLE = undefined;
        if (!win32.OpenProcessToken(win32.current_process, win32.TOKEN_QUERY, &token).toBool()) {
            log.warn("OpenProcessToken failed err={}", .{win32.GetLastError()});
            return error.TokenUnavailable;
        }
        defer _ = win32.CloseHandle(token);
        var buf: TokenBuffer = .{};
        const user = try tokenUser(token, &buf);
        const session = try tokenValue(win32.DWORD, token, .TokenSessionId);
        const elevation = try tokenValue(win32.TOKEN_ELEVATION, token, .TokenElevation);
        return .{
            .user = user,
            .session = session,
            .elevated = elevation.TokenIsElevated != 0,
        };
    }
};

/// Room for a TOKEN_USER with the longest SID.
const TokenBuffer = struct {
    bytes: [128]u8 align(@alignOf(usize)) = undefined,

    comptime {
        std.debug.assert(@sizeOf(win32.TOKEN_USER) + win32.SECURITY_MAX_SID_SIZE <= 128);
    }
};

fn tokenInformation(
    token: win32.HANDLE,
    class: win32.TOKEN_INFORMATION_CLASS,
    buf: *TokenBuffer,
) error{TokenUnavailable}!*anyopaque {
    var len: win32.DWORD = 0;
    if (!win32.GetTokenInformation(token, class, &buf.bytes, buf.bytes.len, &len).toBool()) {
        log.warn("GetTokenInformation failed class={t} err={}", .{ class, win32.GetLastError() });
        return error.TokenUnavailable;
    }
    return &buf.bytes;
}

/// A token information class of a fixed size. Read into a buffer of
/// exactly its size: a longer one is refused for some, as TokenElevation
/// is with ERROR_BAD_LENGTH.
fn tokenValue(
    comptime T: type,
    token: win32.HANDLE,
    class: win32.TOKEN_INFORMATION_CLASS,
) error{TokenUnavailable}!T {
    var value: T = undefined;
    var len: win32.DWORD = 0;
    if (!win32.GetTokenInformation(token, class, &value, @sizeOf(T), &len).toBool()) {
        log.warn("GetTokenInformation failed class={t} err={}", .{ class, win32.GetLastError() });
        return error.TokenUnavailable;
    }
    return value;
}

fn tokenUser(token: win32.HANDLE, buf: *TokenBuffer) Identity.Error!Sid {
    const user: *const win32.TOKEN_USER = @ptrCast(@alignCast(try tokenInformation(token, .TokenUser, buf)));
    return Sid.copy(user.User.Sid);
}

pub const NameError = error{
    OutOfMemory,
    InvalidSid,

    /// An empty base, one that is not UTF-8, or one with a backslash,
    /// which a pipe name cannot hold.
    InvalidName,

    /// Longer than `max_name_len`.
    NameTooLong,
};

/// The pipe's name for `base`: `\\.\pipe\<base>.<user's SID>.<session
/// id>`, owned by the caller. Each session has its own, so that a client
/// reaches its session's instance and not another's, and each user too,
/// so that none is busy with another user's pipe.
pub fn pipeName(alloc: Allocator, base: []const u8, identity: *const Identity) NameError![:0]u16 {
    if (base.len == 0 or std.mem.indexOfScalar(u8, base, '\\') != null) return error.InvalidName;
    const sid = try identity.user.string(alloc);
    defer alloc.free(sid);
    const name = try std.fmt.allocPrint(alloc, pipe_prefix ++ "{s}.{s}.{d}", .{ base, sid, identity.session });
    defer alloc.free(name);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return error.InvalidName,
    };
    if (wide.len > max_name_len) {
        alloc.free(wide);
        return error.NameTooLong;
    }
    return wide;
}

/// The name of the pipe only the instance of process `pid` serves, beside
/// `shared` (`pipeName`), which the session's first instance serves:
/// `shared` with `.<pid>` after it, owned by the caller. Requests made in
/// that instance's terminals reach it by this name
/// (`IpcClient.instance_env`), as every plain launch is a process of its
/// own; and only those of the class that names `shared`, as the
/// instance's own pipe is reached by no other.
pub fn instancePipeName(
    alloc: Allocator,
    shared: []const u16,
    pid: u32,
) error{ OutOfMemory, NameTooLong }![:0]u16 {
    var buf: [16]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf, ".{d}", .{pid}) catch unreachable;
    if (shared.len + suffix.len > max_name_len) return error.NameTooLong;
    const name = try alloc.allocSentinel(u16, shared.len + suffix.len, 0);
    @memcpy(name[0..shared.len], shared);
    for (name[shared.len..], suffix) |*unit, byte| unit.* = byte;
    return name;
}

/// A request read, for the UI thread, with the ticket it answers it by.
pub const Entry = struct {
    request: ipc.Request,
    ticket: u64,
};

alloc: Allocator,
limits: Limits,

/// The window the thread posts `message` to for each request it reads.
hwnd: win32.HWND,
message: win32.UINT,

/// Whom a client must run as.
user: Sid,

pipe: win32.HANDLE,

/// Set by `stop`, and never cleared.
stop_event: win32.HANDLE,

/// The event of the pipe's overlapped operations.
io_event: win32.HANDLE,

/// Set by `answer`, reset for each request.
answered: win32.HANDLE,

/// One request's bytes, read into for each.
request_buf: []u8,

thread: std.Thread,

/// The last ticket given, by the thread only. Tickets start at 1.
last_ticket: u64 = 0,

/// Guards the fields after it, which both threads use.
mutex: std.Io.Mutex = .init,

/// The requests read and not yet taken (`take`), oldest first.
inbox: std.ArrayList(Entry) = .empty,

/// The ticket of the request whose client is waiting for its answer, or
/// zero for none.
waiting: u64 = 0,

/// That answer, once `answer` has given it: never empty, since a reply
/// has a header.
reply: [ipc.max_reply]u8 = undefined,
reply_len: usize = 0,

pub const StartError = error{
    OutOfMemory,
    InvalidSid,

    /// Another pipe has the name: another instance of the user's session,
    /// or a process that made it first.
    NameTaken,

    /// The system refused a pipe, an event or a thread.
    SystemResources,
};

/// Serve the pipe `name` (`pipeName`), allowing clients that run as
/// `identity`'s user and posting `message` to `hwnd` for each request
/// they send, until `stop`.
pub fn start(
    alloc: Allocator,
    name: [:0]const u16,
    identity: *const Identity,
    hwnd: win32.HWND,
    message: win32.UINT,
) StartError!*IpcServer {
    const self = try alloc.create(IpcServer);
    errdefer alloc.destroy(self);
    const request_buf = try alloc.alloc(u8, ipc.max_request);
    errdefer alloc.free(request_buf);

    const pipe = try createPipe(alloc, name, &identity.user);
    errdefer _ = win32.CloseHandle(pipe);
    const stop_event = try createEvent();
    errdefer _ = win32.CloseHandle(stop_event);
    const io_event = try createEvent();
    errdefer _ = win32.CloseHandle(io_event);
    const answered = try createEvent();
    errdefer _ = win32.CloseHandle(answered);

    self.* = .{
        .alloc = alloc,
        .limits = if (builtin.is_test) test_limits orelse .{} else .{},
        .hwnd = hwnd,
        .message = message,
        .user = identity.user,
        .pipe = pipe,
        .stop_event = stop_event,
        .io_event = io_event,
        .answered = answered,
        .request_buf = request_buf,
        .thread = undefined,
    };
    if (builtin.is_test and test_spawn_fails) return error.SystemResources;
    self.thread = std.Thread.spawn(.{}, serve, .{self}) catch |err| {
        log.warn("cannot start the IPC thread err={}", .{err});
        return error.SystemResources;
    };
    return self;
}

/// Stop serving and free it all, the name included. A client waiting for
/// its answer is told the instance is quitting. Returns once the thread
/// has: at most `close_ms` later, for a client that does not close after
/// its reply.
pub fn stop(self: *IpcServer) void {
    _ = win32.SetEvent(self.stop_event);
    self.thread.join();
    self.free(&self.inbox);
    _ = win32.CloseHandle(self.pipe);
    _ = win32.CloseHandle(self.stop_event);
    _ = win32.CloseHandle(self.io_event);
    _ = win32.CloseHandle(self.answered);
    self.alloc.free(self.request_buf);
    self.alloc.destroy(self);
}

/// The requests read since the last call, oldest first, for the UI thread
/// to carry out and answer by their tickets (`answer`). Freed with `free`.
pub fn take(self: *IpcServer) std.ArrayList(Entry) {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const entries = self.inbox;
    self.inbox = .empty;
    return entries;
}

pub fn free(self: *IpcServer, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |entry| entry.request.deinit(self.alloc);
    entries.deinit(self.alloc);
    entries.* = .empty;
}

/// Answer the request of `ticket`, if its client is still waiting:
/// whether it was. Once the client has been told the request is pending,
/// or the instance is quitting, its answer is dropped, and so is a second.
pub fn answer(self: *IpcServer, ticket: u64, status: ipc.Status, text: []const u8) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (ticket == 0 or self.waiting != ticket or self.reply_len != 0) return false;
    self.reply_len = ipc.encodeReply(&self.reply, status, text).len;
    _ = win32.SetEvent(self.answered);
    return true;
}

fn createEvent() StartError!win32.HANDLE {
    return win32.CreateEventW(null, .TRUE, .FALSE, null) orelse {
        log.warn("cannot make an event for IPC err={}", .{win32.GetLastError()});
        return error.SystemResources;
    };
}

fn createPipe(alloc: Allocator, name: [:0]const u16, user: *const Sid) StartError!win32.HANDLE {
    const sid = try user.string(alloc);
    defer alloc.free(sid);
    const sddl = try std.fmt.allocPrint(alloc, sddl_format, .{ sid, sid });
    defer alloc.free(sddl);
    // ASCII, as the SID's text is.
    const sddl_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return error.InvalidSid,
    };
    defer alloc.free(sddl_w);
    var descriptor: ?win32.PSECURITY_DESCRIPTOR = null;
    if (!win32.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_w, win32.SDDL_REVISION_1, &descriptor, null).toBool()) {
        log.warn("cannot make the IPC pipe's security err={}", .{win32.GetLastError()});
        return error.SystemResources;
    }
    defer _ = win32.LocalFree(descriptor);
    var attributes: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = descriptor,
        .bInheritHandle = .FALSE,
    };
    const pipe = win32.CreateNamedPipeW(
        name,
        win32.PIPE_ACCESS_DUPLEX | win32.FILE_FLAG_FIRST_PIPE_INSTANCE | win32.FILE_FLAG_OVERLAPPED,
        win32.PIPE_TYPE_MESSAGE | win32.PIPE_READMODE_MESSAGE | win32.PIPE_WAIT | win32.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        ipc.max_reply,
        ipc.max_request,
        default_timeout_ms,
        &attributes,
    );
    if (pipe != win32.INVALID_HANDLE_VALUE) return pipe;
    return switch (win32.GetLastError()) {
        // ACCESS_DENIED for FILE_FLAG_FIRST_PIPE_INSTANCE with the name in
        // use; PIPE_BUSY for a pipe of the name with all its instances.
        .ACCESS_DENIED, .PIPE_BUSY => error.NameTaken,
        else => |err| {
            log.warn("cannot make the IPC pipe err={}", .{err});
            return error.SystemResources;
        },
    };
}

/// The thread: each client in turn, until `stop`, or until the pipe
/// cannot take another.
fn serve(self: *IpcServer) void {
    while (win32.WaitForSingleObject(self.stop_event, 0) != win32.WAIT_OBJECT_0) {
        switch (self.connect()) {
            .connected => self.converse(),
            .closed => {},
            .stopped => return,
            .failed => {
                log.warn("the IPC pipe cannot take a client, serving no more", .{});
                return;
            },
        }
        // A client left connected keeps the next out; this drops what it
        // has not read, so the replies are waited for (`send`).
        _ = win32.DisconnectNamedPipe(self.pipe);
    }
}

fn connect(self: *IpcServer) enum { connected, closed, stopped, failed } {
    var ov = self.overlapped();
    const started = win32.ConnectNamedPipe(self.pipe, &ov);
    if (!started.toBool()) switch (win32.GetLastError()) {
        .IO_PENDING => {},
        // Connected before the call.
        .PIPE_CONNECTED => return .connected,
        // Connected and closed before the call.
        .NO_DATA => return .closed,
        else => |err| {
            log.warn("ConnectNamedPipe failed err={}", .{err});
            return .failed;
        },
    };
    return switch (self.finish(&ov, .FALSE, win32.INFINITE, true)) {
        .done, .more => .connected,
        .stopped => .stopped,
        .timeout => .failed,
        .failed => |err| {
            log.warn("ConnectNamedPipe failed err={}", .{err});
            return .failed;
        },
    };
}

/// One client: its user checked, its request read, handed over and
/// answered.
fn converse(self: *IpcServer) void {
    if (!self.clientAllowed()) return;
    const bytes = switch (self.readRequest()) {
        .request => |bytes| bytes,
        .too_large => return self.send(.bad_request, "the request is too large"),
        .gone, .stopped => return,
    };
    const request = ipc.decodeRequest(self.alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return self.send(.failed, "out of memory"),
        error.VersionMismatch => return self.send(.bad_request, "the running Ghostty is another version"),
        else => {
            log.warn("refused a malformed IPC request err={}", .{err});
            return self.send(.bad_request, "the request is malformed");
        },
    };

    self.last_ticket += 1;
    const ticket = self.last_ticket;
    const queued = queued: {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        self.inbox.append(self.alloc, .{ .request = request, .ticket = ticket }) catch break :queued false;
        self.waiting = ticket;
        self.reply_len = 0;
        _ = win32.ResetEvent(self.answered);
        break :queued true;
    };
    if (!queued) {
        request.deinit(self.alloc);
        return self.send(.failed, "out of memory");
    }

    const posted = !(builtin.is_test and test_post_fails) and
        win32.PostMessageW(self.hwnd, self.message, 0, 0).toBool();
    // Unless the UI thread took it with an earlier request, from that
    // one's post, and answers it with that one.
    if (!posted and self.withdraw(ticket)) {
        log.warn("cannot hand an IPC request to the UI thread err={}", .{win32.GetLastError()});
        return self.send(.failed, "the running Ghostty cannot take the request");
    }

    const handles = [_]win32.HANDLE{ self.answered, self.stop_event };
    const woke = win32.WaitForMultipleObjects(handles.len, &handles, .FALSE, self.limits.answer_ms);
    var reply: [ipc.max_reply]u8 = undefined;
    const len = len: {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        self.waiting = 0;
        if (self.reply_len > 0) {
            @memcpy(reply[0..self.reply_len], self.reply[0..self.reply_len]);
            break :len self.reply_len;
        }
        // Stopped: `stop` frees the request with the inbox.
        if (woke == win32.WAIT_OBJECT_0 + 1)
            break :len ipc.encodeReply(&reply, .quitting, "the running Ghostty is quitting").len;
        break :len ipc.encodeReply(&reply, .pending, "the running Ghostty is busy, and does it once it is free").len;
    };
    self.write(reply[0..len]);
}

/// Take back the request of `ticket` if the UI thread has not taken it:
/// whether it had not.
fn withdraw(self: *IpcServer, ticket: u64) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.waiting = 0;
    for (self.inbox.items, 0..) |entry, i| {
        if (entry.ticket != ticket) continue;
        entry.request.deinit(self.alloc);
        _ = self.inbox.orderedRemove(i);
        return true;
    }
    return false;
}

fn clientAllowed(self: *IpcServer) bool {
    const user = clientUser(self.pipe) catch |err| {
        log.warn("cannot tell an IPC client's user, refused it err={}", .{err});
        return false;
    };
    if (user.eql(&self.user)) return true;
    log.warn("refused an IPC client of another user", .{});
    return false;
}

fn clientUser(pipe: win32.HANDLE) Identity.Error!Sid {
    if (builtin.is_test) if (test_client_user) |user| return user;
    var pid: win32.DWORD = 0;
    if (!win32.GetNamedPipeClientProcessId(pipe, &pid).toBool()) return error.TokenUnavailable;
    const process = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse
        return error.TokenUnavailable;
    defer _ = win32.CloseHandle(process);
    var token: win32.HANDLE = undefined;
    if (!win32.OpenProcessToken(process, win32.TOKEN_QUERY, &token).toBool()) return error.TokenUnavailable;
    defer _ = win32.CloseHandle(token);
    var buf: TokenBuffer = .{};
    return tokenUser(token, &buf);
}

const Read = union(enum) {
    request: []const u8,
    /// Longer than any request, and read to its end.
    too_large,
    /// Closed, too slow, or failed.
    gone,
    stopped,
};

/// The client's request, which is one message, within `request_ms`.
fn readRequest(self: *IpcServer) Read {
    const deadline = win32.GetTickCount64() + self.limits.request_ms;
    var ov = self.overlapped();
    const started = win32.ReadFile(self.pipe, self.request_buf.ptr, @intCast(self.request_buf.len), null, &ov);
    switch (self.finish(&ov, started, remaining(deadline), true)) {
        .done => |n| return .{ .request = self.request_buf[0..n] },
        .more => {},
        .stopped => return .stopped,
        .timeout => {
            log.warn("an IPC client sent no request in time", .{});
            return .gone;
        },
        .failed => |err| {
            if (err != .BROKEN_PIPE) log.warn("cannot read an IPC request err={}", .{err});
            return .gone;
        },
    }
    // The rest is read and dropped, in the same time, so that the client's
    // write ends and it reads the refusal.
    while (true) {
        var rest = self.overlapped();
        const again = win32.ReadFile(self.pipe, self.request_buf.ptr, @intCast(self.request_buf.len), null, &rest);
        switch (self.finish(&rest, again, remaining(deadline), true)) {
            .done => return .too_large,
            .more => {},
            .stopped => return .stopped,
            .timeout, .failed => return .gone,
        }
    }
}

pub fn remaining(deadline: u64) u32 {
    const now = win32.GetTickCount64();
    if (now >= deadline) return 0;
    return @intCast(@min(deadline - now, win32.INFINITE - 1));
}

fn send(self: *IpcServer, status: ipc.Status, text: []const u8) void {
    var reply: [ipc.max_reply]u8 = undefined;
    self.write(ipc.encodeReply(&reply, status, text));
}

/// Write the reply, then wait for the client to close, since the
/// disconnect after drops what it has not read. Neither is cut short by
/// `stop`, so that a quitting instance's reply still arrives: each takes
/// at most `close_ms`.
fn write(self: *IpcServer, reply: []const u8) void {
    var ov = self.overlapped();
    const started = win32.WriteFile(self.pipe, reply.ptr, @intCast(reply.len), null, &ov);
    switch (self.finish(&ov, started, self.limits.close_ms, false)) {
        .done, .more, .stopped => {},
        .timeout => {
            log.warn("an IPC client took no reply in time", .{});
            return;
        },
        .failed => |err| {
            if (err != .BROKEN_PIPE and err != .NO_DATA) log.warn("cannot write an IPC reply err={}", .{err});
            return;
        },
    }
    var byte: [1]u8 = undefined;
    var closed = self.overlapped();
    const reading = win32.ReadFile(self.pipe, &byte, byte.len, null, &closed);
    switch (self.finish(&closed, reading, self.limits.close_ms, false)) {
        // BROKEN_PIPE, as the client closes.
        .failed, .stopped => {},
        .done, .more => log.warn("an IPC client wrote after its request", .{}),
        .timeout => log.warn("an IPC client did not close after its reply", .{}),
    }
}

/// An overlapped operation of the pipe, signalling `io_event`.
fn overlapped(self: *IpcServer) win32.OVERLAPPED {
    _ = win32.ResetEvent(self.io_event);
    var ov = std.mem.zeroes(win32.OVERLAPPED);
    ov.hEvent = self.io_event;
    return ov;
}

const Io = union(enum) {
    /// Done, with this many bytes moved.
    done: u32,
    /// A read that filled its buffer before the message's end.
    more: u32,
    failed: win32.Win32Error,
    timeout,
    stopped,
};

/// The end of the pipe operation that `started` (its call's return) began
/// on `ov`, waiting at most `ms` and, if `stoppable`, until `stop`. An
/// operation not done is cancelled and waited for, since it writes `ov`
/// and its buffer until it ends.
fn finish(self: *IpcServer, ov: *win32.OVERLAPPED, started: win32.BOOL, ms: u32, stoppable: bool) Io {
    if (!started.toBool()) switch (win32.GetLastError()) {
        // Pending, or done with more of the message to read, which
        // GetOverlappedResult says again.
        .IO_PENDING, .MORE_DATA => {},
        else => |err| return .{ .failed = err },
    };
    // The operation first: when both are set, it is done.
    const handles = [_]win32.HANDLE{ self.io_event, self.stop_event };
    const count: win32.DWORD = if (stoppable) 2 else 1;
    const woke = win32.WaitForMultipleObjects(count, &handles, .FALSE, ms);
    var n: win32.DWORD = 0;
    if (woke == win32.WAIT_OBJECT_0) {
        if (win32.GetOverlappedResult(self.pipe, ov, &n, .FALSE).toBool()) return .{ .done = n };
        return switch (win32.GetLastError()) {
            .MORE_DATA => .{ .more = n },
            else => |err| .{ .failed = err },
        };
    }
    const err = win32.GetLastError();
    _ = win32.CancelIoEx(self.pipe, ov);
    _ = win32.GetOverlappedResult(self.pipe, ov, &n, .TRUE);
    if (woke == win32.WAIT_OBJECT_0 + 1) return .stopped;
    if (woke == win32.WAIT_TIMEOUT) return .timeout;
    return .{ .failed = err };
}

// Tests. Each server has a name of its own (`testName`), a window
// standing in for the UI thread's (`testWindow`), and clients on threads
// of their own (`TestClient`), as `ghostty +new-window` is a process of
// its own.

const test_message: win32.UINT = win32.WM_APP + 0x40;

var test_names: std.atomic.Value(u32) = .init(0);

/// For tests: a base no other test's pipe has, nor another test run's.
pub fn testBase(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "ghostty-test-{d}-{d}", .{
        std.os.windows.GetCurrentProcessId(),
        test_names.fetchAdd(1, .monotonic),
    });
}

fn testName(alloc: Allocator, identity: *const Identity) ![:0]u16 {
    var buf: [64]u8 = undefined;
    return pipeName(alloc, try testBase(&buf), identity);
}

/// A message-only window, standing in for the UI thread's.
fn testWindow() !win32.HWND {
    return win32.CreateWindowExW(
        0,
        win32.L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse error.TestUnexpectedResult;
}

/// For tests: wait up to 5 s for a server's post to `hwnd`, as the UI
/// thread gets it. A WM_QUIT is taken whatever the filter, and fails it.
pub fn testAwaitPost(hwnd: win32.HWND, message: win32.UINT) !void {
    const deadline = win32.GetTickCount64() + 5000;
    var msg: win32.MSG = undefined;
    while (!win32.PeekMessageW(&msg, hwnd, message, message, win32.PM_REMOVE).toBool()) {
        if (win32.GetTickCount64() > deadline) return error.TestNoPost;
        win32.Sleep(1);
    }
    if (msg.message != message) return error.TestUnexpectedMessage;
}

/// Whether a post to `hwnd` is waiting, taking it.
fn testPosted(hwnd: win32.HWND) bool {
    var msg: win32.MSG = undefined;
    return win32.PeekMessageW(&msg, hwnd, test_message, test_message, win32.PM_REMOVE).toBool();
}

/// For tests: a client on a thread of its own, as a CLI process is: it
/// opens the pipe, writes `request` and reads the reply, as its header
/// says to.
pub const TestClient = struct {
    name: [:0]const u16,
    request: []const u8,
    /// How long it waits between its write and its read.
    delay_ms: u32 = 0,
    reply: [ipc.max_reply]u8 = undefined,
    reply_len: usize = 0,
    err: ?anyerror = null,
    thread: std.Thread = undefined,

    pub fn start(self: *TestClient) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *TestClient) void {
        self.reply_len = testExchange(self.name, self.request, self.delay_ms, &self.reply) catch |err| {
            self.err = err;
            return;
        };
    }

    /// The reply, once the client is done.
    pub fn finish(self: *TestClient) !ipc.Reply {
        self.thread.join();
        if (self.err) |err| return err;
        return ipc.decodeReply(self.reply[0..self.reply_len]);
    }
};

fn testExchange(name: [:0]const u16, request: []const u8, delay_ms: u32, reply: *[ipc.max_reply]u8) !usize {
    const pipe = try testOpen(name, client_access);
    defer _ = win32.CloseHandle(pipe);
    try testIo(pipe, .write, @constCast(request));
    win32.Sleep(delay_ms);
    try testIo(pipe, .read, reply[0..ipc.reply_header_len]);
    const len = ipc.reply_header_len + try ipc.replyTextLength(reply[0..ipc.reply_header_len]);
    try testIo(pipe, .read, reply[ipc.reply_header_len..len]);
    return len;
}

/// For tests: open the pipe as a client, waiting up to 5 s while another
/// client has it.
pub fn testOpen(name: [:0]const u16, access: win32.DWORD) !win32.HANDLE {
    const deadline = win32.GetTickCount64() + 5000;
    while (true) {
        const pipe = win32.CreateFileW(name, access, 0, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OVERLAPPED, null);
        if (pipe != win32.INVALID_HANDLE_VALUE) return pipe;
        const err = win32.GetLastError();
        if (err != .PIPE_BUSY or win32.GetTickCount64() > deadline) {
            return if (err == .ACCESS_DENIED) error.AccessDenied else error.TestOpenFailed;
        }
        win32.Sleep(1);
    }
}

/// For tests: read or write all of `buf` on a pipe's handle within 5 s.
pub fn testIo(pipe: win32.HANDLE, comptime kind: enum { read, write }, buf: []u8) !void {
    const event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.TestUnexpectedResult;
    defer _ = win32.CloseHandle(event);
    var at: usize = 0;
    while (at < buf.len) {
        var ov = std.mem.zeroes(win32.OVERLAPPED);
        ov.hEvent = event;
        const rest = buf[at..];
        const started = switch (kind) {
            .read => win32.ReadFile(pipe, rest.ptr, @intCast(rest.len), null, &ov),
            .write => win32.WriteFile(pipe, rest.ptr, @intCast(rest.len), null, &ov),
        };
        if (!started.toBool() and win32.GetLastError() != .IO_PENDING) return error.TestPipeClosed;
        if (win32.WaitForSingleObject(event, 5000) != win32.WAIT_OBJECT_0) {
            _ = win32.CancelIoEx(pipe, &ov);
            var n: win32.DWORD = 0;
            _ = win32.GetOverlappedResult(pipe, &ov, &n, .TRUE);
            return error.TestTimeout;
        }
        var n: win32.DWORD = 0;
        if (!win32.GetOverlappedResult(pipe, &ov, &n, .FALSE).toBool()) return error.TestPipeClosed;
        if (n == 0) return error.TestPipeClosed;
        at += n;
    }
}

/// A server of a name of its own, posting `test_message` to a window of
/// its own, with `limits`.
const TestServer = struct {
    identity: Identity,
    name: [:0]u16,
    hwnd: win32.HWND,
    server: *IpcServer,

    fn init(alloc: Allocator, limits: Limits) !TestServer {
        const identity = try Identity.ofProcess();
        const name = try testName(alloc, &identity);
        errdefer alloc.free(name);
        const hwnd = try testWindow();
        errdefer _ = win32.DestroyWindow(hwnd);
        test_limits = limits;
        defer test_limits = null;
        const server = try start(alloc, name, &identity, hwnd, test_message);
        return .{ .identity = identity, .name = name, .hwnd = hwnd, .server = server };
    }

    fn deinit(self: *TestServer, alloc: Allocator) void {
        self.server.stop();
        alloc.free(self.name);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Send `request` from a client, and wait for the server's post.
    fn send(self: *TestServer, client: *TestClient, request: []const u8) !void {
        client.* = .{ .name = self.name, .request = request };
        try client.start();
        testAwaitPost(self.hwnd, test_message) catch |err| {
            _ = client.finish() catch {};
            return err;
        };
    }

    /// Take the one request the server has read.
    fn takeOne(self: *TestServer) !Entry {
        var entries = self.server.take();
        defer entries.deinit(self.server.alloc);
        if (entries.items.len != 1) {
            self.server.free(&entries);
            return error.TestExpectedOneRequest;
        }
        return entries.items[0];
    }
};

fn testRequest(
    alloc: Allocator,
    action: ipc.Action,
    surface_id: u64,
    arguments: ?[]const [:0]const u8,
) ![]u8 {
    return ipc.encodeRequest(alloc, action, surface_id, arguments);
}

test "win32: this process's IPC identity is its token's user and session" {
    const identity = try Identity.ofProcess();
    var session: win32.DWORD = 0;
    try std.testing.expect(win32.ProcessIdToSessionId(std.os.windows.GetCurrentProcessId(), &session).toBool());
    try std.testing.expectEqual(session, identity.session);
    try std.testing.expect(win32.IsValidSid(identity.user.ptr()).toBool());
    const sid = try identity.user.string(std.testing.allocator);
    defer std.testing.allocator.free(sid);
    try std.testing.expectStringStartsWith(sid, "S-1-5-");
}

test "win32: the IPC pipe's name is the base's, the user's and the session's, and no other" {
    const alloc = std.testing.allocator;
    const identity = try Identity.ofProcess();
    const sid = try identity.user.string(alloc);
    defer alloc.free(sid);

    const name = try pipeName(alloc, "com.example.\u{e9}", &identity);
    defer alloc.free(name);
    const expected = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\com.example.\u{e9}.{s}.{d}", .{ sid, identity.session });
    defer alloc.free(expected);
    const got = try std.unicode.utf16LeToUtf8Alloc(alloc, name);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(expected, got);

    // Another session's is another name.
    var other = identity;
    other.session +%= 1;
    const other_name = try pipeName(alloc, "com.example.\u{e9}", &other);
    defer alloc.free(other_name);
    try std.testing.expect(!std.mem.eql(u16, name, other_name));

    try std.testing.expectError(error.InvalidName, pipeName(alloc, "", &identity));
    try std.testing.expectError(error.InvalidName, pipeName(alloc, "a\\b", &identity));
    try std.testing.expectError(error.InvalidName, pipeName(alloc, "\xff", &identity));

    // The longest base: the name is `max_name_len` units long, and one
    // more is refused.
    const fixed = pipe_prefix.len + 1 + sid.len + 1 + std.fmt.count("{d}", .{identity.session});
    const base = try alloc.alloc(u8, max_name_len - fixed + 1);
    defer alloc.free(base);
    @memset(base, 'a');
    try std.testing.expectError(error.NameTooLong, pipeName(alloc, base, &identity));
    const longest = try pipeName(alloc, base[1..], &identity);
    defer alloc.free(longest);
    try std.testing.expectEqual(max_name_len, longest.len);
}

test "win32: an instance's own IPC pipe is the shared one's name and its process ID" {
    const alloc = std.testing.allocator;
    const identity = try Identity.ofProcess();
    const shared = try pipeName(alloc, "com.example", &identity);
    defer alloc.free(shared);
    const own = try instancePipeName(alloc, shared, std.math.maxInt(u32));
    defer alloc.free(own);
    const shared_text = try std.unicode.utf16LeToUtf8Alloc(alloc, shared);
    defer alloc.free(shared_text);
    const expected = try std.fmt.allocPrint(alloc, "{s}.4294967295", .{shared_text});
    defer alloc.free(expected);
    const got = try std.unicode.utf16LeToUtf8Alloc(alloc, own);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(expected, got);

    // Kept to the longest name, as the shared one is.
    const long: [max_name_len - 2]u16 = @splat('a');
    const longest = try instancePipeName(alloc, &long, 7);
    defer alloc.free(longest);
    try std.testing.expectEqual(max_name_len, longest.len);
    try std.testing.expectError(error.NameTooLong, instancePipeName(alloc, &long, 10));
}

test "win32: the IPC pipe is the user's, who may only read, write and wait" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);

    // An open asking for more is refused, as one that would set the
    // pipe's read mode.
    try std.testing.expectError(
        error.AccessDenied,
        testOpen(t.name, client_access | win32.FILE_WRITE_ATTRIBUTES),
    );

    const pipe = try testOpen(t.name, client_access);
    defer _ = win32.CloseHandle(pipe);
    var owner: ?win32.PSID = null;
    var dacl: ?*win32.ACL = null;
    var descriptor: ?win32.PSECURITY_DESCRIPTOR = null;
    try std.testing.expectEqual(0, win32.GetSecurityInfo(
        pipe,
        win32.SE_KERNEL_OBJECT,
        win32.OWNER_SECURITY_INFORMATION | win32.DACL_SECURITY_INFORMATION,
        &owner,
        null,
        &dacl,
        null,
        &descriptor,
    ));
    defer _ = win32.LocalFree(descriptor);

    const owner_sid = try Sid.copy(owner orelse return error.TestNoOwner);
    try std.testing.expect(owner_sid.eql(&t.identity.user));

    var control: u16 = 0;
    var revision: win32.DWORD = 0;
    try std.testing.expect(win32.GetSecurityDescriptorControl(descriptor.?, &control, &revision).toBool());
    try std.testing.expect(control & win32.SE_DACL_PROTECTED != 0);

    var size: win32.ACL_SIZE_INFORMATION = undefined;
    try std.testing.expect(win32.GetAclInformation(dacl.?, &size, @sizeOf(win32.ACL_SIZE_INFORMATION), win32.AclSizeInformation).toBool());
    try std.testing.expectEqual(1, size.AceCount);
    var ace_ptr: ?*anyopaque = null;
    try std.testing.expect(win32.GetAce(dacl.?, 0, &ace_ptr).toBool());
    const ace: *const win32.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(ace_ptr.?));
    try std.testing.expectEqual(win32.ACCESS_ALLOWED_ACE_TYPE, ace.Header.AceType);
    // FILE_READ_DATA, FILE_WRITE_DATA, FILE_READ_ATTRIBUTES, READ_CONTROL
    // and SYNCHRONIZE.
    try std.testing.expectEqual(@as(win32.DWORD, 0x0012_0083), ace.Mask);
    const ace_sid = try Sid.copy(@ptrCast(@constCast(&ace.SidStart)));
    try std.testing.expect(ace_sid.eql(&t.identity.user));
}

test "win32: an IPC pipe of the name already made, ours or another's, keeps a server from it" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);
    const hwnd = try testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    try std.testing.expectError(error.NameTaken, start(alloc, t.name, &t.identity, hwnd, test_message));
    // Nor can another process add an instance of its own to it, one made
    // as the server's is, which a client could reach in its place,
    // whatever number of instances it gives.
    for ([_]win32.DWORD{ 1, win32.PIPE_UNLIMITED_INSTANCES }) |instances| {
        const pipe = win32.CreateNamedPipeW(
            t.name,
            win32.PIPE_ACCESS_DUPLEX | win32.FILE_FLAG_OVERLAPPED,
            win32.PIPE_TYPE_MESSAGE | win32.PIPE_READMODE_MESSAGE | win32.PIPE_WAIT | win32.PIPE_REJECT_REMOTE_CLIENTS,
            instances,
            ipc.max_reply,
            ipc.max_request,
            default_timeout_ms,
            null,
        );
        if (pipe != win32.INVALID_HANDLE_VALUE) {
            _ = win32.CloseHandle(pipe);
            return error.TestUnexpectedResult;
        }
    }

    // A pipe made first by another, with more instances and the default
    // security.
    const name = try testName(alloc, &t.identity);
    defer alloc.free(name);
    const squatter = win32.CreateNamedPipeW(
        name,
        win32.PIPE_ACCESS_DUPLEX,
        win32.PIPE_TYPE_BYTE,
        win32.PIPE_UNLIMITED_INSTANCES,
        0,
        0,
        0,
        null,
    );
    try std.testing.expect(squatter != win32.INVALID_HANDLE_VALUE);
    try std.testing.expectError(error.NameTaken, start(alloc, name, &t.identity, hwnd, test_message));
    _ = win32.CloseHandle(squatter);

    // Once it is gone, the name is free.
    const server = try start(alloc, name, &t.identity, hwnd, test_message);
    server.stop();
}

test "win32: an IPC request is handed to the UI thread, and its answer is the reply, for every action" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);

    const Case = struct { action: ipc.Action, surface_id: u64, arguments: ?[]const [:0]const u8 };
    const cases = [_]Case{
        .{ .action = .new_window, .surface_id = 0, .arguments = &.{ "--title=a", "-e", "cmd.exe" } },
        .{ .action = .new_tab, .surface_id = 7, .arguments = null },
        .{ .action = .toggle_quick_terminal, .surface_id = 0, .arguments = null },
    };
    comptime std.debug.assert(cases.len == std.enums.values(ipc.Action).len);
    // No request waits: no ticket is answered, zero neither.
    try std.testing.expect(!t.server.answer(0, .ok, ""));
    for (cases, 0..) |case, i| {
        const bytes = try testRequest(alloc, case.action, case.surface_id, case.arguments);
        defer alloc.free(bytes);
        var client: TestClient = undefined;
        try t.send(&client, bytes);
        const entry = try t.takeOne();
        defer entry.request.deinit(alloc);
        try std.testing.expectEqual(case.action, entry.request.action);
        try std.testing.expectEqual(case.surface_id, entry.request.surface_id);
        if (case.arguments) |arguments| {
            const got = entry.request.arguments orelse return error.TestExpectedArguments;
            try std.testing.expectEqual(arguments.len, got.len);
            for (arguments, got) |a, b| try std.testing.expectEqualStrings(a, b);
        } else try std.testing.expectEqual(null, entry.request.arguments);

        var text_buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "done {d}", .{i});
        try std.testing.expect(t.server.answer(entry.ticket, .ok, text));
        // Answered once.
        try std.testing.expect(!t.server.answer(entry.ticket, .failed, "again"));
        const reply = try client.finish();
        try std.testing.expectEqual(ipc.Status.ok, reply.status);
        try std.testing.expectEqualStrings(text, reply.text);
    }
}

test "win32: an IPC request not answered in time is pending, and its late answer dropped" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{ .answer_ms = 1000 });
    defer t.deinit(alloc);
    const bytes = try testRequest(alloc, .toggle_quick_terminal, 0, null);
    defer alloc.free(bytes);

    var late: TestClient = undefined;
    try t.send(&late, bytes);
    const reply = try late.finish();
    try std.testing.expectEqual(ipc.Status.pending, reply.status);

    // Both are carried out, the first late; only the second's client hears.
    var next: TestClient = undefined;
    try t.send(&next, bytes);
    var entries = t.server.take();
    defer t.server.free(&entries);
    try std.testing.expectEqual(2, entries.items.len);
    try std.testing.expect(!t.server.answer(entries.items[0].ticket, .ok, "late"));
    try std.testing.expect(t.server.answer(entries.items[1].ticket, .ok, "now"));
    const now = try next.finish();
    try std.testing.expectEqual(ipc.Status.ok, now.status);
    try std.testing.expectEqualStrings("now", now.text);
}

test "win32: an IPC client slow to read its reply still gets it" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);
    const bytes = try testRequest(alloc, .toggle_quick_terminal, 0, null);
    defer alloc.free(bytes);
    var client: TestClient = .{ .name = t.name, .request = bytes, .delay_ms = 300 };
    try client.start();
    testAwaitPost(t.hwnd, test_message) catch |err| {
        _ = client.finish() catch {};
        return err;
    };
    const entry = try t.takeOne();
    defer entry.request.deinit(alloc);
    try std.testing.expect(t.server.answer(entry.ticket, .ok, "slow"));
    const reply = try client.finish();
    try std.testing.expectEqualStrings("slow", reply.text);
}

test "win32: an IPC client that sends too much, a malformed request or another version's is refused, and the next served" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);

    const valid = try testRequest(alloc, .new_window, 0, &.{"--title=a"});
    defer alloc.free(valid);
    // Past what the pipe holds, so that the client's write ends only as
    // the server reads.
    const too_large = try alloc.alloc(u8, 4 * ipc.max_request + 1);
    defer alloc.free(too_large);
    @memset(too_large, 'x');
    const other_version = try alloc.dupe(u8, valid);
    defer alloc.free(other_version);
    std.mem.writeInt(u16, other_version[4..6], ipc.version + 1, .little);
    const zeros: [ipc.request_header_len]u8 = @splat(0);

    const Case = struct { bytes: []const u8, text: []const u8 };
    const cases = [_]Case{
        .{ .bytes = too_large[0 .. ipc.max_request + 1], .text = "the request is too large" },
        .{ .bytes = too_large, .text = "the request is too large" },
        .{ .bytes = &zeros, .text = "the request is malformed" },
        .{ .bytes = valid[0 .. valid.len - 1], .text = "the request is malformed" },
        .{ .bytes = other_version, .text = "the running Ghostty is another version" },
    };
    for (cases) |case| {
        var client: TestClient = .{ .name = t.name, .request = case.bytes };
        try client.start();
        const reply = try client.finish();
        try std.testing.expectEqual(ipc.Status.bad_request, reply.status);
        try std.testing.expectEqualStrings(case.text, reply.text);
        try std.testing.expect(!testPosted(t.hwnd));
    }

    var client: TestClient = undefined;
    try t.send(&client, valid);
    const entry = try t.takeOne();
    defer entry.request.deinit(alloc);
    try std.testing.expect(t.server.answer(entry.ticket, .ok, ""));
    try std.testing.expectEqual(ipc.Status.ok, (try client.finish()).status);
}

test "win32: an IPC client that sends nothing, or closes at once, is let go, and the next served" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{ .request_ms = 200 });
    defer t.deinit(alloc);

    // Silent: disconnected once `request_ms` has passed, so its read ends.
    {
        const pipe = try testOpen(t.name, client_access);
        defer _ = win32.CloseHandle(pipe);
        var byte: [1]u8 = undefined;
        try std.testing.expectError(error.TestPipeClosed, testIo(pipe, .read, &byte));
    }
    // Closed at once.
    _ = win32.CloseHandle(try testOpen(t.name, client_access));

    const bytes = try testRequest(alloc, .toggle_quick_terminal, 0, null);
    defer alloc.free(bytes);
    var client: TestClient = undefined;
    try t.send(&client, bytes);
    const entry = try t.takeOne();
    defer entry.request.deinit(alloc);
    try std.testing.expect(t.server.answer(entry.ticket, .ok, ""));
    try std.testing.expectEqual(ipc.Status.ok, (try client.finish()).status);
}

test "win32: an IPC client of another user is refused unread, and the next served" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);
    const bytes = try testRequest(alloc, .toggle_quick_terminal, 0, null);
    defer alloc.free(bytes);

    // LocalSystem, S-1-5-18.
    var system: Sid = .{ .len = 12 };
    @memcpy(system.bytes[0..12], &[_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 });
    try std.testing.expect(win32.IsValidSid(system.ptr()).toBool());
    test_client_user = system;
    {
        defer test_client_user = null;
        var client: TestClient = .{ .name = t.name, .request = bytes };
        try client.start();
        try std.testing.expectError(error.TestPipeClosed, client.finish());
    }
    try std.testing.expect(!testPosted(t.hwnd));

    var client: TestClient = undefined;
    try t.send(&client, bytes);
    const entry = try t.takeOne();
    defer entry.request.deinit(alloc);
    try std.testing.expect(t.server.answer(entry.ticket, .ok, ""));
    try std.testing.expectEqual(ipc.Status.ok, (try client.finish()).status);
}

test "win32: stopping the IPC server tells a waiting client it is quitting, and frees the name" {
    const alloc = std.testing.allocator;
    const identity = try Identity.ofProcess();
    const name = try testName(alloc, &identity);
    defer alloc.free(name);
    const hwnd = try testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    const bytes = try testRequest(alloc, .new_window, 0, &.{"--title=a"});
    defer alloc.free(bytes);

    // The request is left in the inbox, which `stop` frees: the testing
    // allocator finds anything left.
    const server = try start(alloc, name, &identity, hwnd, test_message);
    var stopped = false;
    defer if (!stopped) server.stop();
    var client: TestClient = .{ .name = name, .request = bytes };
    try client.start();
    testAwaitPost(hwnd, test_message) catch |err| {
        _ = client.finish() catch {};
        return err;
    };
    server.stop();
    stopped = true;
    const reply = try client.finish();
    try std.testing.expectEqual(ipc.Status.quitting, reply.status);

    const again = try start(alloc, name, &identity, hwnd, test_message);
    again.stop();
}

test "win32: an IPC server without its thread frees what it made, and the name" {
    const alloc = std.testing.allocator;
    const identity = try Identity.ofProcess();
    const name = try testName(alloc, &identity);
    defer alloc.free(name);
    const hwnd = try testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    test_spawn_fails = true;
    try std.testing.expectError(error.SystemResources, start(alloc, name, &identity, hwnd, test_message));
    test_spawn_fails = false;
    const server = try start(alloc, name, &identity, hwnd, test_message);
    server.stop();
}

test "win32: an IPC request the UI thread cannot be told of is answered failed, and taken back" {
    const alloc = std.testing.allocator;
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);
    const bytes = try testRequest(alloc, .new_window, 0, &.{"--title=a"});
    defer alloc.free(bytes);
    test_post_fails = true;
    defer test_post_fails = false;
    var client: TestClient = .{ .name = t.name, .request = bytes };
    try client.start();
    const reply = try client.finish();
    try std.testing.expectEqual(ipc.Status.failed, reply.status);
    var entries = t.server.take();
    defer t.server.free(&entries);
    try std.testing.expectEqual(0, entries.items.len);
}

test "win32: an IPC request memory runs out for is answered failed, and the next served" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var t: TestServer = try .init(alloc, .{});
    defer t.deinit(alloc);
    const with_arguments = try testRequest(std.testing.allocator, .new_window, 0, &.{"--title=a"});
    defer std.testing.allocator.free(with_arguments);
    const without = try testRequest(std.testing.allocator, .toggle_quick_terminal, 0, null);
    defer std.testing.allocator.free(without);

    // Reading the arguments; queueing them, after the two allocations
    // reading them makes (`ipc.decodeRequest`), so that what was read is
    // to be freed; and queueing a request with none, which reading
    // allocates nothing for. The server's thread allocates only once a
    // client has connected, and nothing is queued before.
    const Case = struct { bytes: []const u8, after: usize };
    for ([_]Case{
        .{ .bytes = with_arguments, .after = 0 },
        .{ .bytes = with_arguments, .after = 2 },
        .{ .bytes = without, .after = 0 },
    }) |case| {
        failing.fail_index = failing.alloc_index + case.after;
        var client: TestClient = .{ .name = t.name, .request = case.bytes };
        try client.start();
        const reply = try client.finish();
        try std.testing.expectEqual(ipc.Status.failed, reply.status);
        try std.testing.expectEqualStrings("out of memory", reply.text);
        try std.testing.expect(!testPosted(t.hwnd));
    }
    failing.fail_index = std.math.maxInt(usize);

    var client: TestClient = undefined;
    try t.send(&client, with_arguments);
    const entry = try t.takeOne();
    defer entry.request.deinit(alloc);
    try std.testing.expect(t.server.answer(entry.ticket, .ok, ""));
    try std.testing.expectEqual(ipc.Status.ok, (try client.finish()).status);
}
