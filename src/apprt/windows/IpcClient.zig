//! The client's end of IPC (ipc.zig): what `ghostty +new-window`,
//! `+new-tab` and `+toggle-quick-terminal` do (`perform`, which
//! `App.performIpc` is), in a process of their own with no App.
//!
//! It opens the pipe the running instance of the user's session serves
//! (IpcServer.zig), checks that the user owns it, lets the instance bring
//! its window forward, writes the request and reads the reply, all within
//! `budget_ms`. What the instance did not do, and why, it says on stderr.
//! Run in a Ghostty terminal, it reaches that terminal's instance, by the
//! pipe that instance serves of its own (`instance_env`), as every plain
//! launch is a process of its own.
//! A new window or tab that no instance can take starts Ghostty instead
//! (`startGhostty`), as D-Bus activation starts GTK's.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const launcher_env = @import("../../os/main.zig").windows.launcher_env;
const parsePid = @import("../../os/main.zig").windows.parsePid;
const unsafeCodepoint = @import("App.zig").unsafeCodepoint;
const ipc = @import("ipc.zig");
const IpcServer = @import("IpcServer.zig");
const toast = @import("toast.zig");
const win32 = @import("win32.zig");

/// How long a client has for its whole exchange, from its first open, in
/// milliseconds: more than a server takes for one client at most
/// (`IpcServer.Limits`), so that a server that keeps its limits is heard
/// unless another client holds the pipe.
pub const budget_ms: u32 = 10_000;

/// For tests: the budget in place of `budget_ms`.
pub var test_budget_ms: if (builtin.is_test) ?u32 else void =
    if (builtin.is_test) null else {};

/// For tests: told the process an exchange would let bring its window
/// forward, which it then does not call AllowSetForegroundWindow for.
pub var test_allow_foreground: if (builtin.is_test) ?*const fn (win32.DWORD) void else void =
    if (builtin.is_test) null else {};

/// For tests: given the command line a client would start Ghostty with,
/// which it then does not start, and what the start ends with in its
/// place (`spawn`). A test build starts no process, as its image is the
/// test runner.
pub var test_spawn: if (builtin.is_test) ?*const fn ([:0]const u16) ?win32.Win32Error else void =
    if (builtin.is_test) null else {};

/// The variable a terminal's environment names its instance by: the
/// process ID of the instance, which serves a pipe of its own for the
/// requests made in its terminals (`IpcServer.instancePipeName`), as
/// GHOSTTY_SURFACE_ID names the terminal for `+new-tab`.
pub const instance_env = "GHOSTTY_IPC_INSTANCE";
const instance_env_w = std.unicode.utf8ToUtf16LeStringLiteral(instance_env);

/// Name in `env` the instance of process `instance` as the one a
/// terminal's requests reach (`instance_env`), or none, dropping a value
/// inherited from the Ghostty this one was started in, which names that
/// other instance.
pub fn nameInstance(env: *std.process.Environ.Map, instance: ?u32) !void {
    _ = env.orderedRemove(instance_env);
    const pid = instance orelse return;
    var buf: [10]u8 = undefined;
    try env.put(instance_env, std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable);
}

/// The instance whose terminal this process runs in (`instance_env`), or
/// null outside one, and for a value that is no process ID.
fn instanceOfTerminal() ?u32 {
    var buf: [16]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(instance_env_w, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    return parsePid(buf[0..len]);
}

/// What `perform` fails with, once it has said why on stderr, as the CLI
/// expects (`apprt.ipc.Errors`).
pub const Error = Allocator.Error || apprt.ipc.Errors;

/// Send `action` with `value` to the running instance that `target` names,
/// or the one whose terminal this process runs in, as this process's
/// user, and say on `stderr` what came of it unless it was done
/// (`performAs`).
pub fn perform(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
    stderr: *std.Io.Writer,
) Error!bool {
    const command = comptime commandName(action);
    const identity = IpcServer.Identity.ofProcess() catch |err|
        return fail(stderr, command, "this process's user cannot be told ({t})", .{err});
    return performAs(alloc, &identity, instanceOfTerminal(), target, action, value, stderr);
}

/// `perform` as `identity`, run in a terminal of the instance of process
/// `instance`, if not null: true once the instance did it, or will
/// (`ipc.Status.pending`, which it says), or once Ghostty is started for it
/// (`unanswered`), and error.IPCFailed once it has said what came of it
/// otherwise. What it cannot say, as with no console
/// to say it on, it drops.
pub fn performAs(
    alloc: Allocator,
    identity: *const IpcServer.Identity,
    instance: ?u32,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
    stderr: *std.Io.Writer,
) Error!bool {
    const command = comptime commandName(action);
    const surface_id: u64, const arguments: ?[]const [:0]const u8 = switch (action) {
        .new_window => .{ 0, value.arguments },
        .new_tab => .{ value.surface_id, value.arguments },
        .toggle_quick_terminal => .{ 0, null },
    };

    // An elevated client would open its window in the user's instance,
    // which is not elevated, where an administrator's shell asked for one
    // that is; and that instance's pipe is one any of the user's programs
    // could have made first. An elevated instance serves nothing for the
    // same reason (`App.serveIpc`), so one is started, elevated too.
    if (identity.elevated) return unanswered(alloc, action, arguments, stderr, "an elevated process does not reach a running Ghostty");

    // As GTK names its bus (src/apprt/gtk/ipc/DBus.zig): by the class, else
    // by the build's own id.
    const base: []const u8 = switch (target) {
        .class => |class| class,
        .detect => toast.app_id,
    };
    const name = IpcServer.pipeName(alloc, base, identity) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName, error.NameTooLong => return fail(stderr, command, "the class \"{f}\" cannot name a pipe", .{Safe{ .text = base }}),
        error.InvalidSid => return fail(stderr, command, "this process's user cannot be told ({t})", .{err}),
    };
    defer alloc.free(name);

    const request = ipc.encodeRequest(alloc, .fromCore(action), surface_id, arguments) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return fail(stderr, command, "an argument is not valid Unicode", .{}),
        error.TooLarge => return fail(stderr, command, "the arguments are too long", .{}),
        error.EmptyArguments, error.UnexpectedSurfaceId => return fail(stderr, command, "the request cannot be sent ({t})", .{err}),
    };
    defer alloc.free(request);

    var buf: [ipc.max_reply]u8 = undefined;
    const exchanged = exchanged: {
        // The instance whose terminal this runs in, unless it has gone, as
        // a program its terminal started can outlive it; then the shared
        // pipe's.
        if (instance) |pid| own: {
            const own = IpcServer.instancePipeName(alloc, name, pid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // No instance serves one of this class.
                error.NameTooLong => break :own,
            };
            defer alloc.free(own);
            const result = exchange(own, &identity.user, request, &buf);
            if (result != .none) break :exchanged result;
        }
        break :exchanged exchange(name, &identity.user, request, &buf);
    };
    const reply = switch (exchanged) {
        .reply => |reply| reply,
        .none => return unanswered(alloc, action, arguments, stderr, "no running Ghostty was found"),
        .foreign => return fail(stderr, command, "the pipe of its name is another account's, and was sent nothing", .{}),
        .timeout => return fail(stderr, command, "the running Ghostty did not answer in time", .{}),
        .closed => return fail(stderr, command, "the running Ghostty closed the pipe before it answered", .{}),
        .malformed => |err| switch (err) {
            error.VersionMismatch => return fail(stderr, command, "the running Ghostty is another version", .{}),
            else => return fail(stderr, command, "the running Ghostty's reply is malformed ({t})", .{err}),
        },
        .failed => |failure| return fail(stderr, command, "{s} gave error {d}", .{ failure.call, @backingInt(failure.err) }),
    };
    switch (reply.status) {
        .ok => return true,
        .pending => {
            say(stderr, "{s}: {f}\n", .{ command, Safe{ .text = reply.text } });
            return true;
        },
        // Its pipe goes with it, and so would a window or tab it opened.
        .quitting => switch (action) {
            .new_window, .new_tab => return startGhostty(alloc, command, arguments, stderr),
            .toggle_quick_terminal => return fail(stderr, command, "{f}", .{Safe{ .text = reply.text }}),
        },
        .unsupported, .bad_request, .bad_arguments, .failed => {
            return fail(stderr, command, "{f}", .{Safe{ .text = reply.text }});
        },
    }
}

/// The action as its command line names it (src/cli/ghostty.zig).
fn commandName(action: apprt.ipc.Action.Key) []const u8 {
    return switch (action) {
        .new_window => "+new-window",
        .new_tab => "+new-tab",
        .toggle_quick_terminal => "+toggle-quick-terminal",
    };
}

/// Say on `stderr` that `command` failed, and why, then fail as the CLI
/// expects once that is said.
fn fail(stderr: *std.Io.Writer, comptime command: []const u8, comptime format: []const u8, args: anytype) Error!bool {
    say(stderr, command ++ " failed: " ++ format ++ "\n", args);
    return error.IPCFailed;
}

/// Write to `stderr`, dropping what cannot be written: the outcome stands
/// whether or not it is told.
fn say(stderr: *std.Io.Writer, comptime format: []const u8, args: anytype) void {
    stderr.print(format, args) catch return;
    stderr.flush() catch {};
}

/// A request that no running instance can take, for `reason`. A new window
/// or tab starts Ghostty instead (`startGhostty`), as D-Bus activation
/// starts GTK's. The quick terminal fails: no option starts Ghostty with
/// it shown, where D-Bus starts GTK's and then asks it to toggle.
fn unanswered(
    alloc: Allocator,
    comptime action: apprt.ipc.Action.Key,
    arguments: ?[]const [:0]const u8,
    stderr: *std.Io.Writer,
    comptime reason: []const u8,
) Error!bool {
    const command = comptime commandName(action);
    return switch (action) {
        .new_window, .new_tab => startGhostty(alloc, command, arguments, stderr),
        .toggle_quick_terminal => fail(stderr, command, reason, .{}),
    };
}

/// Start Ghostty, this process's own image, with `arguments` as its
/// command line, and not wait for it: true once it is started, its own
/// window saying what it makes of them.
fn startGhostty(
    alloc: Allocator,
    comptime command: []const u8,
    arguments: ?[]const [:0]const u8,
    stderr: *std.Io.Writer,
) Error!bool {
    const image = try imagePath(alloc);
    defer alloc.free(image);
    const line = commandLine(alloc, image, arguments orelse &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return fail(stderr, command, "an argument is not valid Unicode", .{}),
    };
    defer alloc.free(line);
    if (spawn(image, line)) |err|
        return fail(stderr, command, "Ghostty cannot be started (error {d})", .{@backingInt(err)});
    return true;
}

/// This process's image, ghostty.exe, as Windows started it.
fn imagePath(alloc: Allocator) Allocator.Error![:0]u16 {
    const name = std.os.windows.peb().ProcessParameters.ImagePathName;
    const buf = name.Buffer orelse return alloc.dupeSentinel(u16, &.{}, 0);
    return alloc.dupeSentinel(u16, buf[0 .. name.Length / 2], 0);
}

/// `image`, quoted, then each of `arguments`, quoted where it needs to be,
/// so that the started process splits the line back into them
/// (std.process.Args.Iterator.Windows, which follows the C runtime). A
/// path cannot hold a quote, so quotes alone keep its spaces.
fn commandLine(
    alloc: Allocator,
    image: []const u16,
    arguments: []const [:0]const u8,
) (Allocator.Error || error{InvalidUtf8})![:0]u16 {
    var line: std.ArrayList(u16) = .empty;
    errdefer line.deinit(alloc);
    try line.append(alloc, '"');
    try line.appendSlice(alloc, image);
    try line.append(alloc, '"');
    for (arguments) |argument| {
        try line.append(alloc, ' ');
        try appendQuoted(alloc, &line, argument);
    }
    return line.toOwnedSliceSentinel(alloc, 0);
}

/// `argument` as one word of a command line: as it is, unless it is empty
/// or has a space, a tab, a newline or a quote. Then it is quoted, and
/// inside the quotes a quote is escaped with a backslash and a run of
/// backslashes doubled where a quote follows it, its own or the closing
/// one, since there 2n backslashes stand for n
/// (https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments).
/// Anywhere else a backslash is itself.
fn appendQuoted(
    alloc: Allocator,
    line: *std.ArrayList(u16),
    argument: []const u8,
) (Allocator.Error || error{InvalidUtf8})!void {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, argument);
    defer alloc.free(wide);
    const plain = wide.len != 0 and std.mem.indexOfAny(u16, wide, &.{ ' ', '\t', '\n', 0x0b, '"' }) == null;
    if (plain) return line.appendSlice(alloc, wide);
    try line.append(alloc, '"');
    var backslashes: usize = 0;
    for (wide) |unit| switch (unit) {
        '\\' => backslashes += 1,
        '"' => {
            try line.appendNTimes(alloc, '\\', 2 * backslashes + 1);
            try line.append(alloc, '"');
            backslashes = 0;
        },
        else => {
            try line.appendNTimes(alloc, '\\', backslashes);
            try line.append(alloc, unit);
            backslashes = 0;
        },
    };
    try line.appendNTimes(alloc, '\\', 2 * backslashes);
    try line.append(alloc, '"');
}

/// Start `line` from `image` with nothing of this process's inherited:
/// neither its handles, among them those of the console it runs a CLI
/// action on, which a pipe at the command line would wait for the started
/// process to close, nor the launcher's process ID, by which the started
/// process would take that console for its own
/// (`internal_os.windows.attachLauncherConsole`). Null once started, else
/// why not.
fn spawn(image: [:0]u16, line: [:0]u16) ?win32.Win32Error {
    // From this process's own environment, which the started one copies:
    // this one ends once its action is done.
    _ = win32.SetEnvironmentVariableW(launcher_env, null);
    if (builtin.is_test) {
        const record = test_spawn orelse @panic("a test would start a process");
        return record(line);
    }
    var si = std.mem.zeroes(win32.STARTUPINFOW);
    si.cb = @sizeOf(win32.STARTUPINFOW);
    var pi: win32.PROCESS_INFORMATION = undefined;
    if (!win32.CreateProcessW(image.ptr, line.ptr, null, null, .FALSE, 0, null, null, &si, &pi).toBool())
        return win32.GetLastError();
    _ = win32.CloseHandle(pi.hThread);
    _ = win32.CloseHandle(pi.hProcess);
    return null;
}

/// Text for the console, with a code point that could start a terminal's
/// control sequence, or reorder or hide text (`App.unsafeCodepoint`),
/// written as "U+XXXX", as the command palette writes one, and a byte that
/// starts no code point written as U+FFFD: the instance's text can quote
/// the client's own arguments, and they and the class can come from
/// anywhere.
const Safe = struct {
    text: []const u8,

    pub fn format(self: Safe, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.text.len) {
            // A lead byte's length, checked whole: utf8Decode asserts both.
            const len = std.unicode.utf8ByteSequenceLength(self.text[i]) catch 0;
            const whole = len != 0 and len <= self.text.len - i;
            const bytes = self.text[i..][0..if (whole) len else 0];
            const decoded: ?u21 = if (whole) std.unicode.utf8Decode(bytes) catch null else null;
            const cp = decoded orelse {
                try writer.writeAll("\u{FFFD}");
                i += 1;
                continue;
            };
            if (unsafeCodepoint(cp)) {
                try writer.print("U+{X:0>4}", .{cp});
            } else {
                try writer.writeAll(bytes);
            }
            i += len;
        }
    }
};

/// How an exchange (`exchange`) ended.
pub const Outcome = union(enum) {
    /// The instance's reply, its text in the caller's buffer.
    reply: ipc.Reply,

    /// No pipe of the name: no instance serves it.
    none,

    /// The pipe is not the user's: its open was refused, or another user
    /// owns it, as when a process of theirs made the name first. Nothing
    /// was written to it.
    foreign,

    /// The budget ran out.
    timeout,

    /// The instance closed the pipe before its reply was read whole.
    closed,

    /// The reply is not one of this format.
    malformed: ipc.DecodeError,

    /// A call failed.
    failed: Failure,

    pub const Failure = struct {
        call: []const u8,
        err: win32.Win32Error,
    };

    fn failure(call: []const u8, err: win32.Win32Error) Outcome {
        return .{ .failed = .{ .call = call, .err = err } };
    }
};

/// Send `request` on the pipe `name` (`IpcServer.pipeName`), once it is
/// known to be `user`'s, and read its reply into `buf`, all within the
/// budget.
pub fn exchange(
    name: [:0]const u16,
    user: *const IpcServer.Sid,
    request: []const u8,
    buf: *[ipc.max_reply]u8,
) Outcome {
    const deadline = win32.GetTickCount64() + budget();
    const pipe = switch (open(name, deadline)) {
        .pipe => |pipe| pipe,
        .outcome => |outcome| return outcome,
    };
    defer _ = win32.CloseHandle(pipe);

    // Before anything is written: another user's pipe would read the
    // arguments, and answer as it liked.
    if (checkOwner(pipe, user)) |outcome| return outcome;
    allowForeground(pipe);

    const event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse
        return .failure("CreateEventW", win32.GetLastError());
    defer _ = win32.CloseHandle(event);

    // One write, as the server reads one message.
    var ov = overlapped(event);
    const started = win32.WriteFile(pipe, request.ptr, @intCast(request.len), null, &ov);
    switch (finish(pipe, &ov, started, deadline, "WriteFile")) {
        .done => |n| if (n != request.len) return .closed,
        .outcome => |outcome| return outcome,
    }

    // As bytes, the fixed part first and then its text
    // (`IpcServer.client_access`).
    const header = buf[0..ipc.reply_header_len];
    if (read(pipe, event, header, deadline)) |outcome| return outcome;
    const len = ipc.replyTextLength(header) catch |err| return .{ .malformed = err };
    if (read(pipe, event, buf[ipc.reply_header_len..][0..len], deadline)) |outcome| return outcome;
    const reply = ipc.decodeReply(buf[0 .. ipc.reply_header_len + len]) catch |err|
        return .{ .malformed = err };
    return .{ .reply = reply };
}

fn budget() u32 {
    if (builtin.is_test) if (test_budget_ms) |ms| return ms;
    return budget_ms;
}

const Opened = union(enum) {
    pipe: win32.HANDLE,
    outcome: Outcome,
};

/// The pipe opened as a client, waiting while another client has its one
/// instance. At the identification level only, so that the server can
/// tell who the client is and not act as it, as one that made the name
/// first could otherwise do
/// (https://learn.microsoft.com/en-us/windows/win32/ipc/impersonating-a-named-pipe-client).
fn open(name: [:0]const u16, deadline: u64) Opened {
    while (true) {
        const pipe = win32.CreateFileW(
            name,
            IpcServer.client_access,
            0,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_OVERLAPPED | win32.SECURITY_SQOS_PRESENT | win32.SECURITY_IDENTIFICATION,
            null,
        );
        if (pipe != win32.INVALID_HANDLE_VALUE) return .{ .pipe = pipe };
        switch (win32.GetLastError()) {
            .FILE_NOT_FOUND => return .{ .outcome = .none },
            .ACCESS_DENIED => return .{ .outcome = .foreign },
            .PIPE_BUSY => {},
            else => |err| return .{ .outcome = .failure("CreateFileW", err) },
        }
        // Never zero, which waits as long as the server's default
        // (NMPWAIT_USE_DEFAULT_WAIT).
        const left = IpcServer.remaining(deadline);
        if (left == 0) return .{ .outcome = .timeout };
        if (!win32.WaitNamedPipeW(name, left).toBool()) switch (win32.GetLastError()) {
            .SEM_TIMEOUT => return .{ .outcome = .timeout },
            // The instance quit meanwhile: WaitNamedPipeW returns at once
            // when no instance of the name is left.
            .FILE_NOT_FOUND => return .{ .outcome = .none },
            else => |err| return .{ .outcome = .failure("WaitNamedPipeW", err) },
        };
        // Free, though another client can take it first: then it waits
        // again.
    }
}

/// Null when `user` owns the pipe, else how the exchange ends. The
/// server's own pipe is the user's (`IpcServer.start`); another is not,
/// even with a DACL that lets the user in.
fn checkOwner(pipe: win32.HANDLE, user: *const IpcServer.Sid) ?Outcome {
    var owner: ?win32.PSID = null;
    var descriptor: ?win32.PSECURITY_DESCRIPTOR = null;
    const err = win32.GetSecurityInfo(
        pipe,
        win32.SE_KERNEL_OBJECT,
        win32.OWNER_SECURITY_INFORMATION,
        &owner,
        null,
        null,
        null,
        &descriptor,
    );
    if (err != 0) return .failure("GetSecurityInfo", @fromBackingInt(@intCast(err)));
    defer _ = win32.LocalFree(descriptor);
    const sid = IpcServer.Sid.copy(owner orelse return .foreign) catch return .foreign;
    return if (sid.eql(user)) null else .foreign;
}

/// Let the instance bring the window it opens forward. Windows lets a
/// process take the foreground only when the one in front allows it
/// (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-allowsetforegroundwindow),
/// and this one runs from the console in front. Where it cannot, the
/// window opens behind, its taskbar button flashing.
fn allowForeground(pipe: win32.HANDLE) void {
    var pid: win32.DWORD = 0;
    if (!win32.GetNamedPipeServerProcessId(pipe, &pid).toBool()) return;
    if (builtin.is_test) if (test_allow_foreground) |allow| return allow(pid);
    _ = win32.AllowSetForegroundWindow(pid);
}

fn overlapped(event: win32.HANDLE) win32.OVERLAPPED {
    var ov = std.mem.zeroes(win32.OVERLAPPED);
    ov.hEvent = event;
    return ov;
}

/// Read all of `buf`: a read of the pipe as bytes can end short of it.
fn read(pipe: win32.HANDLE, event: win32.HANDLE, buf: []u8, deadline: u64) ?Outcome {
    var at: usize = 0;
    while (at < buf.len) {
        var ov = overlapped(event);
        const rest = buf[at..];
        const started = win32.ReadFile(pipe, rest.ptr, @intCast(rest.len), null, &ov);
        switch (finish(pipe, &ov, started, deadline, "ReadFile")) {
            .done => |n| {
                if (n == 0) return .closed;
                at += n;
            },
            .outcome => |outcome| return outcome,
        }
    }
    return null;
}

const Done = union(enum) {
    /// With this many bytes moved.
    done: u32,
    outcome: Outcome,
};

/// The end of the operation that `started` (its call's return) began on
/// `ov`, waiting until `deadline`. One not done by then is cancelled and
/// waited for, since it writes `ov` and its buffer until it ends.
fn finish(pipe: win32.HANDLE, ov: *win32.OVERLAPPED, started: win32.BOOL, deadline: u64, call: []const u8) Done {
    if (!started.toBool()) switch (win32.GetLastError()) {
        .IO_PENDING => {},
        .BROKEN_PIPE, .NO_DATA, .PIPE_NOT_CONNECTED => return .{ .outcome = .closed },
        else => |err| return .{ .outcome = .failure(call, err) },
    };
    const woke = win32.WaitForSingleObject(ov.hEvent.?, IpcServer.remaining(deadline));
    var n: win32.DWORD = 0;
    if (woke != win32.WAIT_OBJECT_0) {
        const err = win32.GetLastError();
        _ = win32.CancelIoEx(pipe, ov);
        _ = win32.GetOverlappedResult(pipe, ov, &n, .TRUE);
        if (woke == win32.WAIT_TIMEOUT) return .{ .outcome = .timeout };
        return .{ .outcome = .failure("WaitForSingleObject", err) };
    }
    if (!win32.GetOverlappedResult(pipe, ov, &n, .FALSE).toBool()) switch (win32.GetLastError()) {
        .BROKEN_PIPE, .NO_DATA, .PIPE_NOT_CONNECTED => return .{ .outcome = .closed },
        else => |err| return .{ .outcome = .failure(call, err) },
    };
    return .{ .done = n };
}

// Tests. Each serves a pipe of a name of its own (`TestPipe`), made by
// the test rather than by IpcServer, so that it can do what that one
// never does: refuse the user, take a client and not answer, or answer
// in pieces. Clients run on threads of their own (`TestExchange`), as a
// CLI process is one of its own. App.zig tests the client against the
// instance's own server.

/// A pipe of a name of its own, served by the test: of messages, with one
/// instance, as IpcServer's, but read as bytes, so that the test can take
/// a request in parts, and see that one was sent (`sentNothing`) by
/// reading one byte of it, which reading as messages fails with
/// ERROR_MORE_DATA.
const TestPipe = struct {
    identity: IpcServer.Identity,
    /// The pipe's base, as a class names it.
    class: [:0]u8,
    name: [:0]u16,
    pipe: win32.HANDLE,

    /// `sddl` is its security, else the default, which lets the user in.
    fn init(alloc: Allocator, sddl: ?[]const u8) !TestPipe {
        var buf: [64]u8 = undefined;
        return initOf(alloc, try IpcServer.testBase(&buf), null, sddl);
    }

    /// The pipe of `base`, or the one of the instance of process
    /// `instance` beside it (`IpcServer.instancePipeName`).
    fn initOf(alloc: Allocator, base: []const u8, instance: ?u32, sddl: ?[]const u8) !TestPipe {
        const identity = try IpcServer.Identity.ofProcess();
        const class = try alloc.dupeSentinel(u8, base, 0);
        errdefer alloc.free(class);
        const shared = try IpcServer.pipeName(alloc, class, &identity);
        const name = if (instance) |pid| own: {
            defer alloc.free(shared);
            break :own try IpcServer.instancePipeName(alloc, shared, pid);
        } else shared;
        errdefer alloc.free(name);

        var descriptor: ?win32.PSECURITY_DESCRIPTOR = null;
        defer _ = win32.LocalFree(descriptor);
        var attributes: win32.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = .FALSE,
        };
        if (sddl) |text| {
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
            defer alloc.free(wide);
            if (!win32.ConvertStringSecurityDescriptorToSecurityDescriptorW(wide, win32.SDDL_REVISION_1, &descriptor, null).toBool())
                return error.TestUnexpectedResult;
            attributes.lpSecurityDescriptor = descriptor;
        }
        const pipe = win32.CreateNamedPipeW(
            name,
            win32.PIPE_ACCESS_DUPLEX | win32.FILE_FLAG_OVERLAPPED | win32.FILE_FLAG_FIRST_PIPE_INSTANCE,
            win32.PIPE_TYPE_MESSAGE | win32.PIPE_WAIT | win32.PIPE_REJECT_REMOTE_CLIENTS,
            1,
            ipc.max_reply,
            ipc.max_request,
            IpcServer.default_timeout_ms,
            &attributes,
        );
        if (pipe == win32.INVALID_HANDLE_VALUE) return error.TestUnexpectedResult;
        return .{ .identity = identity, .class = class, .name = name, .pipe = pipe };
    }

    fn deinit(self: *TestPipe, alloc: Allocator) void {
        _ = win32.CloseHandle(self.pipe);
        alloc.free(self.name);
        alloc.free(self.class);
    }

    /// Wait up to 5 s for a client.
    fn accept(self: *TestPipe) !void {
        const event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.TestUnexpectedResult;
        defer _ = win32.CloseHandle(event);
        var ov = overlapped(event);
        if (!win32.ConnectNamedPipe(self.pipe, &ov).toBool()) switch (win32.GetLastError()) {
            // Connected before the call, or connected and closed.
            .PIPE_CONNECTED, .NO_DATA => return,
            .IO_PENDING => {},
            else => return error.TestUnexpectedResult,
        };
        if (win32.WaitForSingleObject(event, 5000) != win32.WAIT_OBJECT_0) {
            _ = win32.CancelIoEx(self.pipe, &ov);
            var n: win32.DWORD = 0;
            _ = win32.GetOverlappedResult(self.pipe, &ov, &n, .TRUE);
            return error.TestTimeout;
        }
    }

    /// The client's request, read whole: its fixed part, then the rest by
    /// the length it gives.
    fn take(self: *TestPipe, buf: []u8) ![]u8 {
        try IpcServer.testIo(self.pipe, .read, buf[0..ipc.request_header_len]);
        const len = std.mem.readInt(u32, buf[8..12], .little);
        try IpcServer.testIo(self.pipe, .read, buf[ipc.request_header_len..len]);
        return buf[0..len];
    }

    fn reply(self: *TestPipe, status: ipc.Status, text: []const u8) !void {
        var buf: [ipc.max_reply]u8 = undefined;
        try IpcServer.testIo(self.pipe, .write, @constCast(ipc.encodeReply(&buf, status, text)));
    }

    /// Whether the client wrote anything before it closed.
    fn sentNothing(self: *TestPipe) bool {
        var byte: [1]u8 = undefined;
        IpcServer.testIo(self.pipe, .read, &byte) catch |err| return err == error.TestPipeClosed;
        return false;
    }
};

/// A client's exchange on a thread of its own.
const TestExchange = struct {
    name: [:0]const u16,
    user: IpcServer.Sid,
    request: []const u8,
    buf: [ipc.max_reply]u8 = undefined,
    outcome: Outcome = .none,
    thread: std.Thread = undefined,

    fn start(self: *TestExchange) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *TestExchange) void {
        self.outcome = exchange(self.name, &self.user, self.request, &self.buf);
    }

    fn finish(self: *TestExchange) Outcome {
        self.thread.join();
        return self.outcome;
    }
};

/// The reply an exchange ended with, else a failure of the test.
fn testReply(outcome: Outcome) !ipc.Reply {
    return switch (outcome) {
        .reply => |reply| reply,
        else => error.TestUnexpectedResult,
    };
}

fn testRequest(alloc: Allocator) ![]u8 {
    return ipc.encodeRequest(alloc, .new_window, 0, &.{"--title=a"});
}

test "win32: an IPC client with no instance to reach starts Ghostty for a window or tab, and says so for the quick terminal" {
    const alloc = std.testing.allocator;
    const identity = try IpcServer.Identity.ofProcess();
    var buf: [64]u8 = undefined;
    const base = try IpcServer.testBase(&buf);
    const class = try alloc.dupeSentinel(u8, base, 0);
    defer alloc.free(class);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.testing.expectError(
        error.IPCFailed,
        performAs(alloc, &identity, null, .{ .class = class }, .toggle_quick_terminal, {}, &out.writer),
    );
    try std.testing.expectEqualStrings("+toggle-quick-terminal failed: no running Ghostty was found\n", out.written());

    // Started with the arguments as given, and without the launcher's
    // process ID, which this process has when ghostty.com runs it.
    TestSpawn.start();
    defer TestSpawn.stop();
    try std.testing.expect(win32.SetEnvironmentVariableW(launcher_env, std.unicode.utf8ToUtf16LeStringLiteral("1")).toBool());
    defer _ = win32.SetEnvironmentVariableW(launcher_env, null);
    out.clearRetainingCapacity();
    var arguments = [_][:0]const u8{ "--working-directory=C:\\a b\\", "-e", "cmd.exe", "/k", "echo \"hi\"" };
    try std.testing.expect(try performAs(alloc, &identity, null, .{ .class = class }, .new_tab, .{ .surface_id = 0x11, .arguments = &arguments }, &out.writer));
    try std.testing.expectEqualStrings("", out.written());
    try TestSpawn.expectStarted(&arguments);

    // One that cannot be started fails, saying so.
    TestSpawn.fails = .FILE_NOT_FOUND;
    out.clearRetainingCapacity();
    try std.testing.expectError(
        error.IPCFailed,
        performAs(alloc, &identity, null, .{ .class = class }, .new_window, .{ .arguments = &arguments }, &out.writer),
    );
    try std.testing.expectEqualStrings("+new-window failed: Ghostty cannot be started (error 2)\n", out.written());
}

test "win32: an IPC client refuses a class that cannot name a pipe, and arguments a request cannot carry" {
    const alloc = std.testing.allocator;
    const identity = try IpcServer.Identity.ofProcess();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.testing.expectError(
        error.IPCFailed,
        performAs(alloc, &identity, null, .{ .class = "a\\b" }, .new_window, .{ .arguments = null }, &out.writer),
    );
    try std.testing.expectEqualStrings("+new-window failed: the class \"a\\b\" cannot name a pipe\n", out.written());

    // A class from anywhere, said safely: here with what a terminal would
    // take for a clear, a byte that starts no code point, and one that
    // starts a code point the text ends before.
    out.clearRetainingCapacity();
    try std.testing.expectError(
        error.IPCFailed,
        performAs(alloc, &identity, null, .{ .class = "a\\\x1b[2J\xff\xe2\x80" }, .new_window, .{ .arguments = null }, &out.writer),
    );
    try std.testing.expectEqualStrings("+new-window failed: the class \"a\\U+001B[2J\u{FFFD}\u{FFFD}\u{FFFD}\" cannot name a pipe\n", out.written());

    // Arguments a request cannot carry, to a class that names a pipe.
    var base_buf: [64]u8 = undefined;
    const base = try alloc.dupeSentinel(u8, try IpcServer.testBase(&base_buf), 0);
    defer alloc.free(base);
    var invalid = [_][:0]const u8{"a\xffb"};
    const long = try alloc.allocSentinel(u8, ipc.max_request, 0);
    defer alloc.free(long);
    @memset(long, 'x');
    var too_long = [_][:0]const u8{long};
    const Unsent = struct { arguments: [][:0]const u8, said: []const u8 };
    for ([_]Unsent{
        .{ .arguments = &invalid, .said = "+new-window failed: an argument is not valid Unicode\n" },
        .{ .arguments = &too_long, .said = "+new-window failed: the arguments are too long\n" },
    }) |case| {
        out.clearRetainingCapacity();
        try std.testing.expectError(
            error.IPCFailed,
            performAs(alloc, &identity, null, .{ .class = base }, .new_window, .{ .arguments = case.arguments }, &out.writer),
        );
        try std.testing.expectEqualStrings(case.said, out.written());
    }
}

test "win32: an IPC client sends nothing to a pipe that is not its user's" {
    const alloc = std.testing.allocator;
    const request = try testRequest(alloc);
    defer alloc.free(request);
    test_budget_ms = 200;
    defer test_budget_ms = null;

    // Owned by another: here, a user other than the one it runs as.
    {
        var t: TestPipe = try .init(alloc, null);
        defer t.deinit(alloc);
        var system: [win32.SECURITY_MAX_SID_SIZE]u8 align(4) = undefined;
        var system_len: win32.DWORD = system.len;
        try std.testing.expect(win32.CreateWellKnownSid(win32.WinLocalSystemSid, null, &system, &system_len).toBool());
        const other = try IpcServer.Sid.copy(@ptrCast(&system));
        var buf: [ipc.max_reply]u8 = undefined;
        try std.testing.expectEqual(.foreign, exchange(t.name, &other, request, &buf));
        try t.accept();
        try std.testing.expect(t.sentNothing());
    }

    // A pipe that refuses the user is not waited for, nor taken for a
    // failure: a DACL that allows nobody.
    {
        var t: TestPipe = try .init(alloc, "D:P");
        defer t.deinit(alloc);
        var buf: [ipc.max_reply]u8 = undefined;
        try std.testing.expectEqual(.foreign, exchange(t.name, &t.identity.user, request, &buf));
    }
}

test "win32: an IPC client connects so that the server can identify it, not act as it" {
    const alloc = std.testing.allocator;
    var t: TestPipe = try .init(alloc, null);
    defer t.deinit(alloc);
    const request = try testRequest(alloc);
    defer alloc.free(request);

    const Foreground = struct {
        var pid: ?win32.DWORD = null;
        fn allow(p: win32.DWORD) void {
            pid = p;
        }
    };
    Foreground.pid = null;
    test_allow_foreground = &Foreground.allow;
    defer test_allow_foreground = null;

    var client: TestExchange = .{ .name = t.name, .user = t.identity.user, .request = request };
    try client.start();
    const level = level: {
        errdefer _ = client.finish();
        try t.accept();
        var buf: [ipc.max_request]u8 = undefined;
        try std.testing.expectEqualSlices(u8, request, try t.take(&buf));
        // Once it has read from the client, as ImpersonateNamedPipeClient
        // asks.
        try std.testing.expect(win32.ImpersonateNamedPipeClient(t.pipe).toBool());
        defer _ = win32.RevertToSelf();
        var token: win32.HANDLE = undefined;
        try std.testing.expect(win32.OpenThreadToken(win32.current_thread, win32.TOKEN_QUERY, .TRUE, &token).toBool());
        defer _ = win32.CloseHandle(token);
        var level: win32.SECURITY_IMPERSONATION_LEVEL = undefined;
        var len: win32.DWORD = 0;
        try std.testing.expect(win32.GetTokenInformation(token, .TokenImpersonationLevel, &level, @sizeOf(win32.SECURITY_IMPERSONATION_LEVEL), &len).toBool());
        break :level level;
    };
    try t.reply(.ok, "");
    const outcome = client.finish();
    try std.testing.expectEqual(.SecurityIdentification, level);
    try std.testing.expectEqual(ipc.Status.ok, (try testReply(outcome)).status);
    // And it let the instance, here this process, bring its window
    // forward.
    try std.testing.expectEqual(@as(?win32.DWORD, std.os.windows.GetCurrentProcessId()), Foreground.pid);
}

test "win32: an IPC client waits while another client has the pipe, until its budget runs out" {
    const alloc = std.testing.allocator;
    var t: TestPipe = try .init(alloc, null);
    defer t.deinit(alloc);
    const request = try testRequest(alloc);
    defer alloc.free(request);

    defer test_budget_ms = null;

    // Held by another client: it waits its budget, then says so.
    const other = try IpcServer.testOpen(t.name, IpcServer.client_access);
    var other_open = true;
    defer if (other_open) {
        _ = win32.CloseHandle(other);
    };
    test_budget_ms = 200;
    var buf: [ipc.max_reply]u8 = undefined;
    const started = win32.GetTickCount64();
    try std.testing.expectEqual(.timeout, exchange(t.name, &t.identity.user, request, &buf));
    try std.testing.expect(win32.GetTickCount64() - started >= 150);

    // Freed while it waits: it gets through.
    test_budget_ms = 5000;
    var client: TestExchange = .{ .name = t.name, .user = t.identity.user, .request = request };
    try client.start();
    {
        errdefer _ = client.finish();
        win32.Sleep(100);
        _ = win32.CloseHandle(other);
        other_open = false;
        try std.testing.expect(win32.DisconnectNamedPipe(t.pipe).toBool());
        try t.accept();
        var request_buf: [ipc.max_request]u8 = undefined;
        _ = try t.take(&request_buf);
        try t.reply(.ok, "");
    }
    try std.testing.expectEqual(ipc.Status.ok, (try testReply(client.finish())).status);
}

test "win32: an IPC client reads a reply that comes in pieces, and tells one cut short or not answered" {
    const alloc = std.testing.allocator;
    const request = try testRequest(alloc);
    defer alloc.free(request);
    var request_buf: [ipc.max_request]u8 = undefined;
    var reply_buf: [ipc.max_reply]u8 = undefined;
    const whole = ipc.encodeReply(&reply_buf, .failed, "in pieces");

    // In pieces: the fixed part and some of the text, then the rest.
    {
        var t: TestPipe = try .init(alloc, null);
        defer t.deinit(alloc);
        var client: TestExchange = .{ .name = t.name, .user = t.identity.user, .request = request };
        try client.start();
        {
            errdefer _ = client.finish();
            try t.accept();
            _ = try t.take(&request_buf);
            try IpcServer.testIo(t.pipe, .write, @constCast(whole[0 .. ipc.reply_header_len + 3]));
            win32.Sleep(50);
            try IpcServer.testIo(t.pipe, .write, @constCast(whole[ipc.reply_header_len + 3 ..]));
        }
        const reply = try testReply(client.finish());
        try std.testing.expectEqual(ipc.Status.failed, reply.status);
        try std.testing.expectEqualStrings("in pieces", reply.text);
    }

    // Cut short: the server closes partway.
    {
        var t: TestPipe = try .init(alloc, null);
        defer t.deinit(alloc);
        var client: TestExchange = .{ .name = t.name, .user = t.identity.user, .request = request };
        try client.start();
        {
            errdefer _ = client.finish();
            try t.accept();
            _ = try t.take(&request_buf);
            try IpcServer.testIo(t.pipe, .write, @constCast(whole[0 .. ipc.reply_header_len + 3]));
            try std.testing.expect(win32.DisconnectNamedPipe(t.pipe).toBool());
        }
        try std.testing.expectEqual(.closed, client.finish());
    }

    // Not answered: the budget runs out.
    {
        var t: TestPipe = try .init(alloc, null);
        defer t.deinit(alloc);
        test_budget_ms = 200;
        defer test_budget_ms = null;
        var client: TestExchange = .{ .name = t.name, .user = t.identity.user, .request = request };
        try client.start();
        {
            errdefer _ = client.finish();
            try t.accept();
            _ = try t.take(&request_buf);
        }
        try std.testing.expectEqual(.timeout, client.finish());
    }
}

/// For tests: `performAs` on a thread of its own, reaching the pipe of
/// `class` as a CLI process does, keeping what it says.
pub const TestCli = struct {
    identity: IpcServer.Identity,
    class: [:0]const u8,
    action: ipc.Action,
    surface_id: u64 = 0,
    arguments: ?[][:0]const u8 = null,
    /// The instance whose terminal it runs in, if any.
    instance: ?u32 = null,
    buf: [512]u8 = undefined,
    out: std.Io.Writer = undefined,
    result: Error!bool = false,
    thread: std.Thread = undefined,

    pub fn start(self: *TestCli) !void {
        self.out = .fixed(&self.buf);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *TestCli) void {
        const alloc = std.testing.allocator;
        const target: apprt.ipc.Target = .{ .class = self.class };
        self.result = switch (self.action) {
            .new_window => performAs(alloc, &self.identity, self.instance, target, .new_window, .{ .arguments = self.arguments }, &self.out),
            .new_tab => performAs(alloc, &self.identity, self.instance, target, .new_tab, .{ .surface_id = self.surface_id, .arguments = self.arguments }, &self.out),
            .toggle_quick_terminal => performAs(alloc, &self.identity, self.instance, target, .toggle_quick_terminal, {}, &self.out),
        };
    }

    /// What it returned, once done.
    pub fn finish(self: *TestCli) Error!bool {
        self.thread.join();
        return self.result;
    }

    /// What it said, once done.
    pub fn said(self: *const TestCli) []const u8 {
        return self.out.buffered();
    }
};

test "win32: an IPC client says what the instance did not do, its text made safe to print" {
    const alloc = std.testing.allocator;
    var t: TestPipe = try .init(alloc, null);
    defer t.deinit(alloc);
    const identity = t.identity;
    var request_buf: [ipc.max_request]u8 = undefined;

    const Case = struct {
        status: ipc.Status,
        text: []const u8,
        result: Error!bool,
        said: []const u8,
        started: bool = false,
    };
    const cases = [_]Case{
        .{ .status = .ok, .text = "unsaid", .result = true, .said = "" },
        .{ .status = .pending, .text = "later", .result = true, .said = "+new-window: later\n" },
        // What a terminal would take for a colour, and a reversal.
        .{
            .status = .bad_arguments,
            .text = "a\x1b[31mb\u{202E}c",
            .result = error.IPCFailed,
            .said = "+new-window failed: aU+001B[31mbU+202Ec\n",
        },
        // Its window would go with it: one of its own is started instead.
        .{ .status = .quitting, .text = "it quits", .result = true, .said = "", .started = true },
        .{ .status = .failed, .text = "it failed", .result = error.IPCFailed, .said = "+new-window failed: it failed\n" },
    };
    TestSpawn.start();
    defer TestSpawn.stop();
    for (cases) |case| {
        var arguments = [_][:0]const u8{"--title=a"};
        var cli: TestCli = .{ .identity = identity, .class = t.class, .action = .new_window, .arguments = &arguments };
        try cli.start();
        {
            errdefer _ = cli.finish() catch {};
            try t.accept();
            const request = try ipc.decodeRequest(alloc, try t.take(&request_buf));
            defer request.deinit(alloc);
            try std.testing.expectEqual(.new_window, request.action);
            const arguments_sent = request.arguments orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(1, arguments_sent.len);
            try std.testing.expectEqualStrings("--title=a", arguments_sent[0]);
            try t.reply(case.status, case.text);
        }
        try std.testing.expectEqual(case.result, cli.finish());
        try std.testing.expectEqualStrings(case.said, cli.said());
        if (case.started) {
            try TestSpawn.expectStarted(&arguments);
        } else {
            try std.testing.expectEqual(null, TestSpawn.len);
        }
        try std.testing.expect(t.sentNothing());
        try std.testing.expect(win32.DisconnectNamedPipe(t.pipe).toBool());
    }

    // Of another version, not of this format, or not answered.
    test_budget_ms = 200;
    defer test_budget_ms = null;
    var other: [ipc.max_reply]u8 = undefined;
    const other_version = ipc.encodeReply(&other, .ok, "");
    std.mem.writeInt(u16, other[4..6], ipc.version + 1, .little);
    const garbage: [ipc.reply_header_len]u8 = @splat('x');
    const Unread = struct { reply: ?[]const u8, said: []const u8 };
    for ([_]Unread{
        .{ .reply = other_version, .said = "+new-window failed: the running Ghostty is another version\n" },
        .{ .reply = &garbage, .said = "+new-window failed: the running Ghostty's reply is malformed (BadMagic)\n" },
        .{ .reply = null, .said = "+new-window failed: the running Ghostty did not answer in time\n" },
    }) |case| {
        var cli: TestCli = .{ .identity = identity, .class = t.class, .action = .new_window };
        try cli.start();
        {
            errdefer _ = cli.finish() catch {};
            try t.accept();
            _ = try t.take(&request_buf);
            if (case.reply) |bytes| try IpcServer.testIo(t.pipe, .write, @constCast(bytes));
        }
        try std.testing.expectError(error.IPCFailed, cli.finish());
        try std.testing.expectEqualStrings(case.said, cli.said());
        try std.testing.expect(win32.DisconnectNamedPipe(t.pipe).toBool());
    }
}

test "win32: an IPC client's budget outlasts a server that keeps its limits" {
    const limits: IpcServer.Limits = .{};
    try std.testing.expect(budget_ms > limits.request_ms + limits.answer_ms + limits.close_ms);
}

test "win32: an IPC client names its command as the command line does" {
    const CliAction = @import("../../cli/ghostty.zig").Action;
    for (std.enums.values(apprt.ipc.Action.Key)) |action| {
        const name = commandName(action);
        try std.testing.expectEqual('+', name[0]);
        try std.testing.expect(std.meta.stringToEnum(CliAction, name[1..]) != null);
    }
}

/// For tests: records the command line a client would start Ghostty with
/// (`test_spawn`), and whether the launcher's process ID was gone from the
/// environment by then.
pub const TestSpawn = struct {
    var line: [2048]u16 = undefined;
    var len: ?usize = null;
    var launcher_gone: bool = false;
    /// What the start ends with, null for started.
    pub var fails: ?win32.Win32Error = null;

    pub fn start() void {
        len = null;
        launcher_gone = false;
        fails = null;
        test_spawn = &record;
    }

    pub fn stop() void {
        test_spawn = null;
    }

    fn record(started: [:0]const u16) ?win32.Win32Error {
        // One too long to keep is kept as none, which fails the test.
        if (started.len <= line.len) {
            @memcpy(line[0..started.len], started);
            len = started.len;
        }
        var value: [1]u16 = undefined;
        launcher_gone = win32.GetEnvironmentVariableW(launcher_env, &value, value.len) == 0 and
            win32.GetLastError() == .ENVVAR_NOT_FOUND;
        return fails;
    }

    /// That Ghostty was started, from an image, with `arguments`, and no
    /// launcher's process ID; and forget it.
    pub fn expectStarted(arguments: []const [:0]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const started = len orelse return error.TestUnexpectedResult;
        len = null;
        const got = try testSplit(arena.allocator(), line[0..started]);
        try std.testing.expect(launcher_gone);
        try std.testing.expectEqual(arguments.len + 1, got.len);
        try std.testing.expect(std.ascii.endsWithIgnoreCase(got[0], ".exe"));
        for (arguments, got[1..]) |want, have| try std.testing.expectEqualStrings(want, have);
    }
};

/// The words of `line`, split as Zig splits ghostty.exe's own command line.
fn testSplit(alloc: Allocator, line: []const u16) ![]const []const u8 {
    var it = try std.process.Args.Iterator.Windows.init(alloc, line);
    var words: std.ArrayList([]const u8) = .empty;
    while (it.next()) |word| try words.append(alloc, try alloc.dupe(u8, word));
    return words.items;
}

fn expectSplitsBack(alloc: Allocator, arguments: []const [:0]const u8) !void {
    const image = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Ghostty\\ghostty.exe");
    const line = try commandLine(alloc, image, arguments);
    const got = try testSplit(alloc, line);
    try std.testing.expectEqual(arguments.len + 1, got.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Ghostty\\ghostty.exe", got[0]);
    for (arguments, got[1..]) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "win32: an IPC client starts Ghostty with its arguments as they were given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectSplitsBack(alloc, &.{});
    try expectSplitsBack(alloc, &.{ "--title=a b", "-e", "cmd.exe", "/k", "echo \"hi\"" });
    // Backslashes: before a quote, at the end inside quotes, and bare.
    try expectSplitsBack(alloc, &.{ "--working-directory=C:\\a b\\", "a\\\"b", "C:\\x\\", "\\\\srv\\s", "" });
    try expectSplitsBack(alloc, &.{ "\u{e9}", "\u{1F47B} x", "a\tb", "a\nb" });
    try std.testing.expectError(error.InvalidUtf8, commandLine(alloc, &.{}, &.{"a\xffb"}));

    // Every argument of up to five of the characters that change the
    // split, alone and between two others.
    const alphabet = "a \t\"\\";
    const most = 5;
    var buf: [most + 1]u8 = undefined;
    for (0..most + 1) |len| {
        var digits: [most]usize = @splat(0);
        while (true) {
            for (buf[0..len], digits[0..len]) |*c, d| c.* = alphabet[d];
            buf[len] = 0;
            const argument: [:0]const u8 = buf[0..len :0];
            try expectSplitsBack(alloc, &.{argument});
            try expectSplitsBack(alloc, &.{ "x", argument, "\\" });
            var i: usize = 0;
            while (i < len) : (i += 1) {
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            }
            if (i == len) break;
        }
    }
}

test "win32: an elevated IPC client starts a Ghostty of its own, and sends nothing" {
    const alloc = std.testing.allocator;
    var t: TestPipe = try .init(alloc, null);
    defer t.deinit(alloc);
    var identity = t.identity;
    identity.elevated = true;
    // Were it to open the pipe, it would wait for a reply nobody sends;
    // not for long.
    test_budget_ms = 200;
    defer test_budget_ms = null;
    TestSpawn.start();
    defer TestSpawn.stop();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var arguments = [_][:0]const u8{"--title=a"};
    try std.testing.expect(try performAs(alloc, &identity, null, .{ .class = t.class }, .new_tab, .{ .surface_id = 0, .arguments = &arguments }, &out.writer));
    try std.testing.expectEqualStrings("", out.written());
    try TestSpawn.expectStarted(&arguments);

    out.clearRetainingCapacity();
    try std.testing.expectError(
        error.IPCFailed,
        performAs(alloc, &identity, null, .{ .class = t.class }, .toggle_quick_terminal, {}, &out.writer),
    );
    try std.testing.expectEqualStrings("+toggle-quick-terminal failed: an elevated process does not reach a running Ghostty\n", out.written());

    // Neither opened the pipe.
    var ov = overlapped(win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.TestUnexpectedResult);
    defer _ = win32.CloseHandle(ov.hEvent.?);
    try std.testing.expect(!win32.ConnectNamedPipe(t.pipe, &ov).toBool());
    try std.testing.expectEqual(win32.Win32Error.IO_PENDING, win32.GetLastError());
    _ = win32.CancelIoEx(t.pipe, &ov);
    var n: win32.DWORD = 0;
    _ = win32.GetOverlappedResult(t.pipe, &ov, &n, .TRUE);
}

/// For tests: `cli`, which the pipe `t` takes, answered as failed with
/// `text`; that it says so shows which pipe it reached.
fn testAnsweredBy(cli: *TestCli, t: *TestPipe, text: []const u8) !void {
    var request_buf: [ipc.max_request]u8 = undefined;
    try cli.start();
    {
        errdefer _ = cli.finish() catch {};
        try t.accept();
        _ = try t.take(&request_buf);
        try t.reply(.failed, text);
    }
    try std.testing.expectError(error.IPCFailed, cli.finish());
    var said_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&said_buf, "+new-window failed: {s}\n", .{text}),
        cli.said(),
    );
    try std.testing.expect(win32.DisconnectNamedPipe(t.pipe).toBool());
}

test "win32: an IPC client in a terminal reaches its instance's own pipe, else the shared one" {
    const alloc = std.testing.allocator;
    var shared: TestPipe = try .init(alloc, null);
    defer shared.deinit(alloc);
    const pid: u32 = 4242;
    var own: TestPipe = try .initOf(alloc, shared.class, pid, null);
    var own_open = true;
    defer if (own_open) own.deinit(alloc);

    // From its terminal: the instance's own, though another serves the
    // shared one.
    var cli: TestCli = .{ .identity = shared.identity, .class = shared.class, .action = .new_window, .instance = pid };
    try testAnsweredBy(&cli, &own, "own");
    // From no terminal, or one of an instance that serves none: the shared.
    cli = .{ .identity = shared.identity, .class = shared.class, .action = .new_window };
    try testAnsweredBy(&cli, &shared, "shared");
    cli = .{ .identity = shared.identity, .class = shared.class, .action = .new_window, .instance = pid + 1 };
    try testAnsweredBy(&cli, &shared, "shared");
    // From one whose instance has gone.
    own.deinit(alloc);
    own_open = false;
    cli = .{ .identity = shared.identity, .class = shared.class, .action = .new_window, .instance = pid };
    try testAnsweredBy(&cli, &shared, "shared");

    // Of a class so long that no instance pipe can have it.
    const fixed = shared.name.len - shared.class.len;
    var long_buf: [IpcServer.max_name_len]u8 = undefined;
    const long = long_buf[0 .. IpcServer.max_name_len - fixed];
    @memcpy(long[0..shared.class.len], shared.class);
    @memset(long[shared.class.len..], 'x');
    var longest: TestPipe = try .initOf(alloc, long, null, null);
    defer longest.deinit(alloc);
    try std.testing.expectEqual(IpcServer.max_name_len, longest.name.len);
    cli = .{ .identity = longest.identity, .class = longest.class, .action = .new_window, .instance = pid };
    try testAnsweredBy(&cli, &longest, "shared");
}

test "win32: an IPC client finds its terminal's instance in its environment, and a terminal names only its own" {
    const alloc = std.testing.allocator;

    // A terminal's environment, from one inherited from another Ghostty.
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put(instance_env, "1");
    try nameInstance(&env, null);
    try std.testing.expectEqual(null, env.get(instance_env));
    try env.put(instance_env, "1");
    try nameInstance(&env, 4242);
    try std.testing.expectEqualStrings("4242", env.get(instance_env) orelse return error.TestUnexpectedResult);

    // This process's, put back after: a test run in a Ghostty terminal
    // has one, of 10 digits at most.
    var saved_buf: [16]u16 = undefined;
    const saved_len = win32.GetEnvironmentVariableW(instance_env_w, &saved_buf, saved_buf.len);
    const saved: ?[*:0]const u16 = if (saved_len == 0 or saved_len >= saved_buf.len) null else saved_buf[0..saved_len :0];
    defer _ = win32.SetEnvironmentVariableW(instance_env_w, saved);
    const Case = struct { value: ?[]const u8, instance: ?u32 };
    for ([_]Case{
        .{ .value = "4242", .instance = 4242 },
        .{ .value = "42x", .instance = null },
        .{ .value = "4294967296", .instance = null },
        .{ .value = "123456789012345678", .instance = null },
        .{ .value = null, .instance = null },
    }) |case| {
        var value_buf: [32]u16 = undefined;
        const value: ?[*:0]const u16 = if (case.value) |v| value: {
            const n = try std.unicode.utf8ToUtf16Le(&value_buf, v);
            value_buf[n] = 0;
            break :value value_buf[0..n :0];
        } else null;
        try std.testing.expect(win32.SetEnvironmentVariableW(instance_env_w, value).toBool());
        try std.testing.expectEqual(case.instance, instanceOfTerminal());
    }
}
