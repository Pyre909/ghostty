//! Ghostty as the terminal of the consoles Windows starts.
//!
//! A console program started without a console gets one from the inbox
//! conhost, which hands it to the console server HKCU\Console\%%Startup's
//! DelegationConsole names. With Windows Terminal's OpenConsole there,
//! that server in turn hands the session to the terminal
//! DelegationTerminal names: a COM class implementing ITerminalHandoff3
//! (microsoft/terminal, src/host/proxy/ITerminalHandoff.idl). This file is
//! that class. Each EstablishPtyHandoff becomes a new window whose
//! terminal talks to the console over pipes of its own (`Pty.openHandoff`)
//! and watches the console's program (`termio.Exec.Handoff`).
//!
//! The class object is registered from a thread of its own in the
//! multithreaded apartment, as the UI thread's is single-threaded: COM
//! calls it on its own threads, so a busy UI thread never holds a console
//! up. A call queues what it got (`take`) and posts a message to a window
//! of the UI thread, as `IpcServer` does with a request.
//!
//! Windows ignores the user's classes for an elevated caller: an elevated
//! console never comes here, and keeps the inbox conhost.
//!
//! ITerminalHandoff3 and TERMINAL_STARTUP_INFO below follow the IDL by
//! hand, unchecked: no header Zig ships declares them. The class factory
//! is IClassFactory, which com_abi_test.zig checks against the headers.
const std = @import("std");
const builtin = @import("builtin");

const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const Pty = @import("../../pty.zig").Pty;
const termio = @import("../../termio.zig");
const IpcServer = @import("IpcServer.zig");
const registry = @import("registry.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const windows = internal_os.windows;
const GUID = std.os.windows.GUID;
const HANDLE = win32.HANDLE;
const HRESULT = win32.HRESULT;
const ULONG = std.os.windows.ULONG;

/// Ghostty's ITerminalHandoff3 class, the CLSID that
/// HKCU\\Console\\%%Startup's DelegationTerminal holds to make Ghostty the
/// default terminal, as Settings writes a class.
pub const clsid_text = "{73DB5BF6-8DD9-4F9F-85F8-9A05893D71C7}";
pub const clsid: GUID = GUID.parse(clsid_text);

/// ITerminalHandoff3, the only version OpenConsole calls: Windows
/// Terminal 1.22 and later.
pub const iid_handoff3: GUID = GUID.parse("{6f23da90-15c5-4203-9db0-64e73f1b1b00}");

/// Under HKEY_CURRENT_USER: the user's classes, and the class's key,
/// which `default_terminal` writes.
pub const classes_key = "Software\\Classes\\CLSID";
pub const class_key = classes_key ++ "\\" ++ clsid_text;

/// Under HKEY_CURRENT_USER: the command COM runs, with `-Embedding` after
/// it, to start a server of the class when none is running.
pub const server_key = class_key ++ "\\LocalServer32";

/// Whether the class's server command under `root`'s `subkey` starts
/// `exe` (`commandNames`).
pub fn serverNames(root: win32.HKEY, subkey: [*:0]const u16, exe: []const u16) bool {
    var buf: [registry.command_units]u16 = undefined;
    const command = (registry.readString(root, subkey, null, &buf) catch return false) orelse return false;
    return commandNames(command, exe);
}

/// Whether `command`, as COM reads LocalServer32, starts `exe`: its path
/// quoted, or bare and followed by nothing or by arguments. Paths compare
/// as Windows compares them, ignoring case.
fn commandNames(command: []const u16, exe: []const u16) bool {
    const rest = std.mem.trimStart(u16, command, &.{ ' ', '\t' });
    const path = if (rest.len > 0 and rest[0] == '"') quoted: {
        const end = std.mem.indexOfScalarPos(u16, rest, 1, '"') orelse return false;
        break :quoted rest[1..end];
    } else bare: {
        if (rest.len < exe.len) return false;
        if (rest.len > exe.len and rest[exe.len] != ' ' and rest[exe.len] != '\t') return false;
        break :bare rest[0..exe.len];
    };
    return std.os.windows.eqlIgnoreCaseWtf16(path, exe);
}

/// TERMINAL_STARTUP_INFO: what the console's program asked of its window
/// in its STARTUPINFO. The console's host sends the title, the icon and
/// `wShowWindow` only, the last already resolved from the program's
/// STARTF_USESHOWWINDOW, and leaves the rest zero, `dwFlags` included
/// (ConsoleEstablishHandoff in microsoft/terminal's src/host/srvinit.cpp).
pub const StartupInfo = extern struct {
    pszTitle: ?[*:0]const u16,
    pszIconPath: ?[*:0]const u16,
    iconIndex: i32,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
};

/// A console handed off, for the UI thread to open a window for.
pub const Entry = struct {
    handoff: termio.Exec.Handoff,
    /// Whether its program asked to start maximized.
    maximized: bool,
};

/// What the class shares with the UI thread. Process-wide, as the class
/// object is: a call that comes in as the server stops finds it still
/// there, and is refused.
var shared: struct {
    /// Set by the server's thread once it revoked the class (`Watch`).
    revoked: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    /// The server's (`Server.start`): the queue's, set with `hwnd`.
    alloc: std.mem.Allocator = undefined,
    /// Where a call posts `message`; null while no server runs, when a
    /// call is refused.
    hwnd: ?win32.HWND = null,
    message: win32.UINT = 0,
    entries: std.ArrayList(Entry) = .empty,
} = .{};

/// Where a server sees whether the class still starts its executable.
/// COM gives a class object registered for every activation each console
/// while it stays registered, whatever the class's key says, so once
/// another executable's `+default-terminal --enable` points the key at
/// itself, a server of the old one would keep taking its consoles: on
/// the first change that leaves the key naming another executable, the
/// server revokes the class.
pub const Watch = struct {
    /// Under HKEY_CURRENT_USER: a key that holds `server`, watched with
    /// all its subkeys.
    key: []const u16,
    /// Under HKEY_CURRENT_USER: the class's server key (`serverNames`).
    server: []const u16,
    /// This process's image.
    exe: []const u16,

    /// The server thread's own copies.
    const Owned = struct {
        key: [:0]u16,
        server: [:0]u16,
        exe: []u16,

        fn init(alloc: std.mem.Allocator, watch: Watch) !Owned {
            const key = try alloc.dupeSentinel(u16, watch.key, 0);
            errdefer alloc.free(key);
            const server = try alloc.dupeSentinel(u16, watch.server, 0);
            errdefer alloc.free(server);
            return .{ .key = key, .server = server, .exe = try alloc.dupe(u16, watch.exe) };
        }

        fn deinit(self: Owned, alloc: std.mem.Allocator) void {
            alloc.free(self.key);
            alloc.free(self.server);
            alloc.free(self.exe);
        }
    };
};

/// Which callers a server answers.
pub const Context = enum {
    /// Every process: the console servers of the user's consoles.
    local_server,
    /// This process alone, for tests: a test never takes a console of the
    /// user's, whatever the user's default terminal.
    in_process,

    fn clsctx(self: Context) win32.DWORD {
        return switch (self) {
            .local_server => win32.CLSCTX_LOCAL_SERVER,
            .in_process => win32.CLSCTX_INPROC_SERVER,
        };
    }
};

/// The thread the class object is registered from.
pub const Server = struct {
    thread: std.Thread,
    stop_event: HANDLE,

    pub const Error = std.Thread.SpawnError || error{ EventFailed, RegisterFailed, OutOfMemory };

    /// Serve the class to the callers of `context`, posting `message` to
    /// `hwnd` as consoles come (`take`), until stopped or, with `watch`,
    /// until the class names another executable. The queue is allocated
    /// with `alloc`. One server at a time.
    pub fn start(
        alloc: std.mem.Allocator,
        hwnd: win32.HWND,
        message: win32.UINT,
        watch: ?Watch,
        context: Context,
    ) Error!Server {
        const ready = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventFailed;
        defer _ = win32.CloseHandle(ready);
        const stop_event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.EventFailed;
        errdefer _ = win32.CloseHandle(stop_event);

        // Before the class is registered: a console may come at once.
        {
            shared.mutex.lockUncancelable(global.io());
            defer shared.mutex.unlock(global.io());
            std.debug.assert(shared.hwnd == null);
            shared.hwnd = hwnd;
            shared.message = message;
            shared.alloc = alloc;
        }
        errdefer refuse();
        shared.revoked.store(false, .release);

        // The thread's from a successful spawn on.
        const owned: ?Watch.Owned = if (watch) |w| try .init(alloc, w) else null;
        var registration: Registration = .{
            .alloc = alloc,
            .ready = ready,
            .stop_event = stop_event,
            .watch = owned,
            .context = context,
        };
        const thread = std.Thread.spawn(internal_os.thread_config, serve, .{&registration}) catch |err| {
            if (owned) |o| o.deinit(alloc);
            return err;
        };
        _ = win32.WaitForSingleObject(ready, win32.INFINITE);
        if (registration.hr < 0) {
            thread.join();
            log.warn("cannot serve the default terminal's class hr=0x{x}", .{@as(u32, @bitCast(registration.hr))});
            return error.RegisterFailed;
        }
        return .{ .thread = thread, .stop_event = stop_event };
    }

    /// Whether the server revoked the class, as the class names another
    /// executable (`Watch`): consoles go to that one from then on.
    pub fn revoked(self: *const Server) bool {
        _ = self;
        return shared.revoked.load(.acquire);
    }

    /// Stop serving the class. A console queued and not taken is closed,
    /// which ends its program as closing its window would.
    pub fn stop(self: *Server) void {
        _ = win32.SetEvent(self.stop_event);
        self.thread.join();
        _ = win32.CloseHandle(self.stop_event);
        refuse();
    }
};

/// How the thread tells `start` whether the class was registered.
const Registration = struct {
    alloc: std.mem.Allocator,
    ready: HANDLE,
    stop_event: HANDLE,
    /// The thread's, to free.
    watch: ?Watch.Owned,
    context: Context,
    hr: HRESULT = win32.E_FAIL,
};

fn serve(registration: *Registration) void {
    // `registration` is `start`'s, gone once `ready` is set.
    const alloc = registration.alloc;
    const stop_event = registration.stop_event;
    const watch = registration.watch;
    defer if (watch) |w| w.deinit(alloc);
    const init = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
    if (init < 0) {
        registration.hr = init;
        _ = win32.SetEvent(registration.ready);
        return;
    }
    defer win32.CoUninitialize();
    var cookie: win32.DWORD = 0;
    const hr = win32.CoRegisterClassObject(
        &clsid,
        @ptrCast(&factory),
        registration.context.clsctx(),
        win32.REGCLS_MULTIPLEUSE,
        &cookie,
    );
    registration.hr = hr;
    _ = win32.SetEvent(registration.ready);
    if (hr < 0) return;
    if (watch) |w| watchClass(w, stop_event) else {
        _ = win32.WaitForSingleObject(stop_event, win32.INFINITE);
    }
    // Not checked: nothing can act on a failure here, and the deferred
    // CoUninitialize revokes the class anyway.
    _ = win32.CoRevokeClassObject(cookie);
}

/// Return once `stop_event` is set, or once a change to `watch.key` leaves
/// the class naming another executable (`Watch`). Should the key not be
/// watched, only the stop returns.
fn watchClass(watch: Watch.Owned, stop_event: HANDLE) void {
    const changed = win32.CreateEventW(null, .FALSE, .FALSE, null);
    defer if (changed) |e| {
        _ = win32.CloseHandle(e);
    };
    var key: ?win32.HKEY = null;
    if (changed != null) {
        var opened: win32.HKEY = undefined;
        // Made if missing: a class written later then still shows.
        const rc = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, watch.key, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_NOTIFY, null, &opened, null);
        if (rc == 0) key = opened else log.warn("not watching the default terminal's class rc={}", .{rc});
    }
    defer if (key) |k| {
        _ = win32.RegCloseKey(k);
    };
    while (true) {
        if (key) |k| {
            // Once per change: a notification ends with its event.
            const rc = win32.RegNotifyChangeKeyValue(k, .TRUE, win32.REG_NOTIFY_CHANGE_NAME | win32.REG_NOTIFY_CHANGE_LAST_SET, changed, .TRUE);
            if (rc != 0) {
                log.warn("not watching the default terminal's class rc={}", .{rc});
                _ = win32.RegCloseKey(k);
                key = null;
            }
        }
        const handles = [_]HANDLE{ stop_event, changed orelse stop_event };
        const woke = win32.WaitForMultipleObjects(if (key != null) 2 else 1, &handles, .FALSE, win32.INFINITE);
        if (woke != win32.WAIT_OBJECT_0 + 1) return;
        if (!serverNames(win32.HKEY_CURRENT_USER, watch.server, watch.exe)) {
            log.info("the default terminal's class names another executable, no longer serving it", .{});
            shared.revoked.store(true, .release);
            return;
        }
    }
}

/// Refuse calls from now on, and close what was queued.
fn refuse() void {
    var left, const alloc = left: {
        shared.mutex.lockUncancelable(global.io());
        defer shared.mutex.unlock(global.io());
        shared.hwnd = null;
        const entries = shared.entries;
        shared.entries = .empty;
        break :left .{ entries, shared.alloc };
    };
    for (left.items) |*entry| entry.handoff.deinit();
    left.deinit(alloc);
}

/// The consoles handed off since the last call, for the UI thread. Each
/// entry's handoff is the caller's, to give to a terminal or close; the
/// list too, allocated with the server's allocator (`Server.start`).
pub fn take() std.ArrayList(Entry) {
    shared.mutex.lockUncancelable(global.io());
    defer shared.mutex.unlock(global.io());
    const entries = shared.entries;
    shared.entries = .empty;
    return entries;
}

/// The class's one object: it holds nothing, so it is never freed and
/// counts no references, as a class object of a static class may.
const Handoff = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*Handoff, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Handoff) callconv(.winapi) ULONG,
        Release: *const fn (*Handoff) callconv(.winapi) ULONG,
        EstablishPtyHandoff: *const fn (
            *Handoff,
            in: *HANDLE,
            out: *HANDLE,
            signal: HANDLE,
            reference: HANDLE,
            server: HANDLE,
            client: HANDLE,
            info: *const StartupInfo,
        ) callconv(.winapi) HRESULT,
    };

    fn queryInterface(self: *Handoff, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        for ([_]*const GUID{ &win32.IID_IUnknown, &iid_handoff3 }) |known| {
            if (std.meta.eql(iid.*, known.*)) {
                out.* = self;
                return win32.S_OK;
            }
        }
        out.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(_: *Handoff) callconv(.winapi) ULONG {
        return 2;
    }

    fn release(_: *Handoff) callconv(.winapi) ULONG {
        return 1;
    }
};

var handoff: Handoff = .{ .vtable = &.{
    .QueryInterface = Handoff.queryInterface,
    .AddRef = Handoff.addRef,
    .Release = Handoff.release,
    .EstablishPtyHandoff = establish,
} };

/// IClassFactory for `handoff`, static as it is.
pub const Factory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Factory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Factory) callconv(.winapi) ULONG,
        Release: *const fn (*Factory) callconv(.winapi) ULONG,
        CreateInstance: *const fn (*Factory, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        LockServer: *const fn (*Factory, win32.BOOL) callconv(.winapi) HRESULT,
    };

    fn queryInterface(self: *Factory, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        for ([_]*const GUID{ &win32.IID_IUnknown, &win32.IID_IClassFactory }) |known| {
            if (std.meta.eql(iid.*, known.*)) {
                out.* = self;
                return win32.S_OK;
            }
        }
        out.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(_: *Factory) callconv(.winapi) ULONG {
        return 2;
    }

    fn release(_: *Factory) callconv(.winapi) ULONG {
        return 1;
    }

    fn createInstance(_: *Factory, outer: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (outer != null) {
            out.* = null;
            return win32.CLASS_E_NOAGGREGATION;
        }
        return Handoff.queryInterface(&handoff, iid, out);
    }

    /// The server lives as long as the app, whatever is locked.
    fn lockServer(_: *Factory, _: win32.BOOL) callconv(.winapi) HRESULT {
        return win32.S_OK;
    }
};

var factory: Factory = .{ .vtable = &.{
    .QueryInterface = Factory.queryInterface,
    .AddRef = Factory.addRef,
    .Release = Factory.release,
    .CreateInstance = Factory.createInstance,
    .LockServer = Factory.lockServer,
} };

/// EstablishPtyHandoff: take the console, queue it for a window, and
/// return the ends of our pipes its server is to use. A failure, refused
/// with E_FAIL, leaves the console's program in the classic conhost's
/// window, as an unregistered class would.
fn establish(
    _: *Handoff,
    in: *HANDLE,
    out: *HANDLE,
    signal: HANDLE,
    reference: HANDLE,
    server: HANDLE,
    client: HANDLE,
    info: *const StartupInfo,
) callconv(.winapi) HRESULT {
    const received = receive(signal, reference, server, client, info) catch |err| {
        log.warn("refused a console handed off err={}", .{err});
        return win32.E_FAIL;
    };
    var entry = received.entry;
    queue(entry) catch |err| {
        log.warn("refused a console handed off err={}", .{err});
        entry.handoff.deinit();
        _ = win32.CloseHandle(received.host_in);
        _ = win32.CloseHandle(received.host_out);
        return win32.E_FAIL;
    };
    // COM owns them from here: it gives copies to the console's server
    // and closes these, as Windows Terminal's own terminal hands its ends
    // over (CTerminalHandoff::EstablishPtyHandoff).
    in.* = received.host_in;
    out.* = received.host_out;
    return win32.S_OK;
}

/// The console of a call, with our copies of its handles: the call's are
/// COM's, closed when it returns. Our pipes' host ends are the caller's
/// to close.
fn receive(
    signal: HANDLE,
    reference: HANDLE,
    server: HANDLE,
    client: HANDLE,
    info: *const StartupInfo,
) !struct { entry: Entry, host_in: HANDLE, host_out: HANDLE } {
    // Each copy is closed should a later step fail; the pty owns three
    // of them once it is opened, the last step that can.
    const client_copy = try windows.duplicateHandle(client);
    errdefer _ = win32.CloseHandle(client_copy);
    const signal_copy = try windows.duplicateHandle(signal);
    errdefer _ = win32.CloseHandle(signal_copy);
    const reference_copy = try windows.duplicateHandle(reference);
    errdefer _ = win32.CloseHandle(reference_copy);
    const server_copy = try windows.duplicateHandle(server);
    errdefer _ = win32.CloseHandle(server_copy);
    const opened = try Pty.openHandoff(.{
        .signal = signal_copy,
        .reference = reference_copy,
        .server = server_copy,
    });
    errdefer comptime unreachable;
    return .{
        .entry = .{
            .handoff = .{ .pty = opened.pty, .client = client_copy },
            // As Windows Terminal reads it (ConptyConnection.cpp), with no
            // flag: the host sends none (`StartupInfo`).
            .maximized = info.wShowWindow == @as(u16, @intCast(win32.SW_SHOWMAXIMIZED)),
        },
        .host_in = opened.host_in,
        .host_out = opened.host_out,
    };
}

/// Hand `entry` to the UI thread, unless no server runs or the UI thread
/// cannot be told: an entry no post announces could wait for a console
/// that never comes, while the refused console stays in conhost's window.
/// The post is made under the lock, so the UI thread cannot take the entry
/// before a failed post withdraws it.
fn queue(entry: Entry) error{ NotServing, OutOfMemory, PostFailed }!void {
    shared.mutex.lockUncancelable(global.io());
    defer shared.mutex.unlock(global.io());
    const hwnd = shared.hwnd orelse return error.NotServing;
    try shared.entries.append(shared.alloc, entry);
    const posted = !(builtin.is_test and test_post_fails) and
        win32.PostMessageW(hwnd, shared.message, 0, 0).toBool();
    if (!posted) {
        log.warn("cannot post a console handed off err={}", .{win32.GetLastError()});
        _ = shared.entries.pop();
        return error.PostFailed;
    }
}

/// For tests: the post to the UI thread fails, as with its queue full.
pub var test_post_fails: if (builtin.is_test) bool else void =
    if (builtin.is_test) false else {};

const test_message: win32.UINT = win32.WM_APP + 0x50;

/// For tests: a console's server, as OpenConsole is to the class. It gets
/// the class's object through COM, on a thread of the multithreaded
/// apartment (`run`), and hands it handles of its own, closed once the
/// call returns, as COM closes a call's (`establish`).
pub const TestCaller = struct {
    /// The read ends of the signal, reference and server pipes, which show
    /// what the class's copies of the write ends sent, and when they
    /// closed.
    reads: [3]?HANDLE = .{ null, null, null },
    info: StartupInfo,
    hr: HRESULT = win32.E_FAIL,
    host_in: ?HANDLE = null,
    host_out: ?HANDLE = null,
    /// A caller of a program started maximized or not, with what the
    /// console's host sends (`StartupInfo`).
    pub fn init(maximized: bool) TestCaller {
        return .{ .info = std.mem.zeroInit(StartupInfo, .{
            .wShowWindow = @as(u16, @intCast(if (maximized) win32.SW_SHOWMAXIMIZED else win32.SW_SHOWNORMAL)),
        }) };
    }

    /// Hand the class a console, which it must take.
    pub fn call(self: *TestCaller) !void {
        const thread = try std.Thread.spawn(.{}, run, .{self});
        thread.join();
        try std.testing.expectEqual(win32.S_OK, self.hr);
    }

    /// That the class's copies of the console's handles are closed, with
    /// nothing left unread. A peek, not a read: a copy left open fails the
    /// test rather than hanging it.
    pub fn expectClosed(self: *const TestCaller) !void {
        for (self.reads) |r| {
            try std.testing.expect(windows.exp.kernel32.PeekNamedPipe(r.?, null, 0, null, null, null) == windows.FALSE);
            try std.testing.expectEqual(std.os.windows.Win32Error.BROKEN_PIPE, windows.GetLastError());
        }
    }

    pub fn deinit(self: *TestCaller) void {
        for (self.reads) |r| if (r) |h| {
            _ = win32.CloseHandle(h);
        };
        if (self.host_in) |h| _ = win32.CloseHandle(h);
        if (self.host_out) |h| _ = win32.CloseHandle(h);
    }

    fn run(self: *TestCaller) void {
        const init_hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (init_hr < 0) {
            self.hr = init_hr;
            return;
        }
        defer win32.CoUninitialize();
        // In process: a class registered for every activation serves its
        // own process's too, through COM's table, with no registry entry.
        var object: ?*anyopaque = null;
        self.hr = win32.CoCreateInstance(&clsid, null, win32.CLSCTX_INPROC_SERVER, &iid_handoff3, &object);
        if (self.hr < 0) return;
        const h: *Handoff = @ptrCast(@alignCast(object.?));
        defer _ = h.vtable.Release(h);
        self.establish(h);
    }

    /// Hand `h` a console on this thread.
    fn establish(self: *TestCaller, h: *Handoff) void {
        const k32 = windows.exp.kernel32;
        var writes: [3]?HANDLE = .{ null, null, null };
        defer for (writes) |wr| if (wr) |x| {
            _ = win32.CloseHandle(x);
        };
        for (&self.reads, &writes) |*r, *wr| {
            var read: HANDLE = undefined;
            var write: HANDLE = undefined;
            if (k32.CreatePipe(&read, &write, null, 0) == windows.FALSE) {
                self.hr = win32.E_FAIL;
                return;
            }
            r.* = read;
            wr.* = write;
        }
        const client = windows.duplicateHandle(std.os.windows.GetCurrentProcess()) catch {
            self.hr = win32.E_FAIL;
            return;
        };
        defer _ = win32.CloseHandle(client);
        var in: HANDLE = undefined;
        var out: HANDLE = undefined;
        self.hr = h.vtable.EstablishPtyHandoff(h, &in, &out, writes[0].?, writes[1].?, writes[2].?, client, &self.info);
        if (self.hr < 0) return;
        self.host_in = in;
        self.host_out = out;
    }
};

test "win32: a console handed off reaches the UI thread, with its handles kept past the call" {
    const testing = std.testing;
    const k32 = windows.exp.kernel32;
    const hwnd = try IpcServer.testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    var server = try Server.start(testing.allocator, hwnd, test_message, null, .in_process);
    defer server.stop();

    var caller: TestCaller = .init(true);
    defer caller.deinit();
    try caller.call();

    try IpcServer.testAwaitPost(hwnd, test_message);
    var entries = take();
    defer entries.deinit(testing.allocator);
    try testing.expectEqual(1, entries.items.len);
    var entry = &entries.items[0];
    try testing.expect(entry.maximized);

    // The caller closed its handles: the entry's copies still reach the
    // console's server.
    try entry.handoff.pty.setSize(.{ .ws_row = 40, .ws_col = 120, .ws_xpixel = 0, .ws_ypixel = 0 });
    var message: [3]u16 = undefined;
    var got: windows.DWORD = 0;
    try testing.expect(k32.ReadFile(caller.reads[0].?, &message, @sizeOf(@TypeOf(message)), &got, null) != windows.FALSE);
    try testing.expectEqual([3]u16{ 8, 120, 40 }, message);

    // What the console's server writes on the end it got, the terminal
    // reads.
    const text = "handed off";
    try testing.expect(k32.WriteFile(caller.host_out.?, text, text.len, &got, null) != windows.FALSE);
    var buf: [32]u8 = undefined;
    try testing.expect(k32.ReadFile(entry.handoff.pty.out_pipe, &buf, buf.len, &got, null) != windows.FALSE);
    try testing.expectEqualStrings(text, buf[0..got]);

    // Closing the entry closes the copies, the last write ends.
    entry.handoff.deinit();
    try caller.expectClosed();
}

test "win32: a server stops serving once the class names another executable" {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const testing = std.testing;
    const talloc = testing.allocator;
    // Keys of the test's own process, which it removes, not the user's
    // class: the watch is the same on either.
    const root = try std.fmt.allocPrint(talloc, "Software\\GhosttyTest\\{d}\\hs", .{windows.GetCurrentProcessId()});
    defer talloc.free(root);
    const root_z = try std.unicode.utf8ToUtf16LeAllocZ(talloc, root);
    defer talloc.free(root_z);
    const sub = try std.fmt.allocPrint(talloc, "{s}\\LocalServer32", .{root});
    defer talloc.free(sub);
    const sub_z = try std.unicode.utf8ToUtf16LeAllocZ(talloc, sub);
    defer talloc.free(sub_z);
    defer _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, root_z);
    var key: win32.HKEY = undefined;
    try testing.expectEqual(0, win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, sub_z, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_SET_VALUE, null, &key, null));
    defer _ = win32.RegCloseKey(key);
    const set = struct {
        fn set(k: win32.HKEY, value: [:0]const u16) !void {
            const bytes = std.mem.sliceAsBytes(value[0 .. value.len + 1]);
            try std.testing.expectEqual(0, win32.RegSetValueExW(k, null, 0, win32.REG_SZ, bytes.ptr, @intCast(bytes.len)));
        }
    }.set;
    try set(key, W("\"C:\\Ghostty\\ghostty.exe\""));

    const hwnd = try IpcServer.testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    var server = try Server.start(talloc, hwnd, test_message, .{
        .key = root_z,
        .server = sub_z,
        .exe = W("C:\\Ghostty\\ghostty.exe"),
    }, .in_process);
    defer server.stop();

    // A change that still names it keeps it serving.
    try set(key, W("C:\\Ghostty\\ghostty.exe -Embedding"));
    try std.Io.sleep(testing.io, .fromMilliseconds(300), .awake);
    try testing.expect(!server.revoked());
    {
        var caller: TestCaller = .init(false);
        defer caller.deinit();
        try caller.call();
        try IpcServer.testAwaitPost(hwnd, test_message);
        var entries = take();
        defer entries.deinit(testing.allocator);
        for (entries.items) |*entry| entry.handoff.deinit();
        try testing.expectEqual(1, entries.items.len);
    }

    // Another install takes the class: the server revokes it, and a
    // console is no longer this process's.
    try set(key, W("\"D:\\Other\\ghostty.exe\""));
    const deadline = win32.GetTickCount64() + 5000;
    while (!server.revoked()) {
        if (win32.GetTickCount64() > deadline) return error.TestNotRevoked;
        win32.Sleep(1);
    }
    var caller: TestCaller = .init(false);
    defer caller.deinit();
    const thread = try std.Thread.spawn(.{}, TestCaller.run, .{&caller});
    thread.join();
    try testing.expect(caller.hr < 0);
}

test "win32: a console handed off is refused when the UI thread cannot be told" {
    const testing = std.testing;
    const hwnd = try IpcServer.testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    var server = try Server.start(testing.allocator, hwnd, test_message, null, .in_process);
    defer server.stop();

    test_post_fails = true;
    defer test_post_fails = false;
    var caller: TestCaller = .init(false);
    defer caller.deinit();
    const thread = try std.Thread.spawn(.{}, TestCaller.run, .{&caller});
    thread.join();
    try testing.expectEqual(win32.E_FAIL, caller.hr);

    // Nothing waits for a window, and the class's copies are closed, so
    // the console stays with its own host.
    var entries = take();
    defer entries.deinit(testing.allocator);
    try testing.expectEqual(0, entries.items.len);
    try caller.expectClosed();
}

test "win32: a console handed off with no server running is refused, and its handles left alone" {
    const testing = std.testing;
    const k32 = windows.exp.kernel32;
    var read: HANDLE = undefined;
    var write: HANDLE = undefined;
    try testing.expect(k32.CreatePipe(&read, &write, null, 0) != windows.FALSE);
    defer _ = win32.CloseHandle(read);
    defer _ = win32.CloseHandle(write);
    const current = std.os.windows.GetCurrentProcess();
    const info = std.mem.zeroes(StartupInfo);
    var in: HANDLE = undefined;
    var out: HANDLE = undefined;
    try testing.expectEqual(win32.E_FAIL, handoff.vtable.EstablishPtyHandoff(&handoff, &in, &out, write, write, current, current, &info));
    // The call's own write end still works.
    var got: windows.DWORD = 0;
    try testing.expect(k32.WriteFile(write, "x", 1, &got, null) != windows.FALSE);
}

test "win32: a console refused for want of a server has the class's copies of its handles closed" {
    var caller: TestCaller = .init(false);
    defer caller.deinit();
    // Straight to the class, as COM would call it: with no server, COM
    // itself refuses.
    caller.establish(&handoff);
    try std.testing.expectEqual(win32.E_FAIL, caller.hr);
    try caller.expectClosed();
}

test "win32: stopping a server closes the consoles it queued and nobody took" {
    const testing = std.testing;
    const hwnd = try IpcServer.testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    var server = try Server.start(testing.allocator, hwnd, test_message, null, .in_process);

    var caller: TestCaller = .init(false);
    defer caller.deinit();
    try caller.call();
    try IpcServer.testAwaitPost(hwnd, test_message);
    server.stop();

    // Ended, as closing its window would end it, and gone from the queue.
    try caller.expectClosed();
    var entries = take();
    defer entries.deinit(testing.allocator);
    try testing.expectEqual(0, entries.items.len);
}

test "win32: the console handoff's declarations have the IDL's layout" {
    // From ITerminalHandoff.idl: IUnknown's three slots, then
    // EstablishPtyHandoff; TERMINAL_STARTUP_INFO's two BSTRs, a LONG,
    // eight DWORDs and a WORD.
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(4 * p, @sizeOf(Handoff.VTable));
    try testing.expectEqual(3 * p, @offsetOf(Handoff.VTable, "EstablishPtyHandoff"));
    try testing.expectEqual(5 * p, @sizeOf(Factory.VTable));
    try testing.expectEqual(2 * p, @offsetOf(StartupInfo, "iconIndex"));
    try testing.expectEqual(2 * p + 4 * 6, @offsetOf(StartupInfo, "dwYCountChars"));
    try testing.expectEqual(2 * p + 4 * 9, @offsetOf(StartupInfo, "wShowWindow"));
    try testing.expectEqual(std.mem.alignForward(usize, 2 * p + 4 * 9 + 2, p), @sizeOf(StartupInfo));
}

test "win32: a server command starts this executable only with its path" {
    @setEvalBranchQuota(10_000);
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const exe = W("C:\\Program Files\\Ghostty\\ghostty.exe");
    const yes = [_][:0]const u16{
        W("\"C:\\Program Files\\Ghostty\\ghostty.exe\""),
        W("  \"c:\\program files\\ghostty\\GHOSTTY.EXE\" --x"),
        W("C:\\Program Files\\Ghostty\\ghostty.exe"),
        W("C:\\Program Files\\Ghostty\\ghostty.exe -Embedding"),
    };
    for (yes) |command| try std.testing.expect(commandNames(command, exe));
    const no = [_][:0]const u16{
        W(""),
        W("\"C:\\Program Files\\Ghostty\\ghostty.exe"),
        W("\"C:\\Program Files\\Ghostty\\ghostty.exe.bak\""),
        W("C:\\Program Files\\Ghostty\\ghostty.exe2"),
        W("C:\\Program Files\\Ghostty"),
        W("\"D:\\Ghostty\\ghostty.exe\""),
    };
    for (no) |command| try std.testing.expect(!commandNames(command, exe));
}

test "win32: the class's server is read from the user's classes" {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const testing = std.testing;
    // A key of the test's own, which it removes, not the user's class.
    var path_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, "Software\\GhosttyTest\\{d}\\class", .{windows.GetCurrentProcessId()});
    var root_w: [96]u16 = undefined;
    var n = try std.unicode.utf8ToUtf16Le(&root_w, root);
    root_w[n] = 0;
    const root_z = root_w[0..n :0];
    var sub_w: [128]u16 = undefined;
    @memcpy(sub_w[0..n], root_z);
    const tail = W("\\LocalServer32");
    @memcpy(sub_w[n..][0..tail.len], tail);
    n += tail.len;
    sub_w[n] = 0;
    const sub_z = sub_w[0..n :0];
    defer _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, root_z);
    const exe = W("C:\\Ghostty\\ghostty.exe");

    // No key, no server.
    try testing.expect(!serverNames(win32.HKEY_CURRENT_USER, sub_z, exe));

    try registry.writeString(win32.HKEY_CURRENT_USER, sub_z, null, W("\"C:\\Ghostty\\ghostty.exe\""));
    try testing.expect(serverNames(win32.HKEY_CURRENT_USER, sub_z, exe));
    try registry.writeString(win32.HKEY_CURRENT_USER, sub_z, null, W("\"C:\\Other\\ghostty.exe\""));
    try testing.expect(!serverNames(win32.HKEY_CURRENT_USER, sub_z, exe));
}
