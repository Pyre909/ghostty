//! ghostty.com, the console front door for ghostty.exe on Windows.
//!
//! ghostty.exe is a GUI-subsystem program. A shell starts one and moves
//! on without waiting or handing over its console, so a CLI action typed
//! at a prompt (`ghostty +list-fonts`) would print after the next prompt,
//! or nowhere, and its exit code would be lost. cmd and PowerShell look a
//! bare `ghostty` up through PATHEXT, which lists .COM before .EXE, so
//! this console-subsystem program installed beside ghostty.exe is what
//! they run, the way Visual Studio pairs devenv.com with devenv.exe.
//!
//! It decides as ghostty.exe will, with the same detection code over the
//! same arguments. A CLI action runs ghostty.exe with this console's std
//! handles and waits for its exit code; ghostty.exe attaches to the
//! console itself when it finds the launcher's process ID in its
//! environment (internal_os.windows.attachLauncherConsole). Anything else
//! starts the terminal and returns at once, as launching any GUI program
//! from a shell does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArgIterator = std.process.Args.Iterator.Windows;
const action = @import("cli/action.zig");
const Action = @import("cli/ghostty.zig").Action;
const windows = @import("os/windows.zig");
const k32 = windows.exp.kernel32;

pub fn main() noreturn {
    const alloc = std.heap.page_allocator;
    const params = std.os.windows.peb().ProcessParameters;
    const cmdline = unicodeSlice(params.CommandLine);

    const exe = exePath(alloc, unicodeSlice(params.ImagePathName)) catch
        fail("out of memory", .{});
    const line = childCommandLine(alloc, exe, argsTail(cmdline)) catch
        fail("out of memory", .{});

    const cli = launcherIsCli(alloc, cmdline) catch
        fail("out of memory", .{});
    if (cli) runCli(exe, line) else startGui(exe, line);
}

/// isCli for the launcher's own command line, after argv[0]. ghostty.exe's
/// argv[0] is the quoted path childCommandLine gives it, which detection
/// never takes for an action or a flag; the launcher's is whatever its
/// caller wrote, even the first argument when the caller left argv[0] out.
fn launcherIsCli(alloc: Allocator, cmdline: []const u16) ArgIterator.InitError!bool {
    var args = try ArgIterator.init(alloc, cmdline);
    _ = args.skip();
    return isCli(&args);
}

/// Whether ghostty.exe will run a CLI action for these arguments rather
/// than open a window: upstream's detection found an action, or failed
/// (MultipleActions, InvalidAction), which ghostty.exe reports on stderr.
fn isCli(iter: anytype) bool {
    const found = action.detectIter(Action, iter) catch return true;
    return found != null;
}

/// Runs the action on this console and exits with its exit code.
fn runCli(exe: [:0]u16, line: [:0]u16) noreturn {
    // Ctrl+C and Ctrl+Break reach ghostty.exe too, attached to this
    // console; the launcher outlives them to report how it ended. A
    // handler routine, unlike SetConsoleCtrlHandler(null, TRUE), is not
    // inherited by the child.
    _ = k32.SetConsoleCtrlHandler(&ignoreCtrlC, windows.TRUE);

    // Ghostty writes UTF-8, which the console decodes with its output
    // code page, by default an OEM one (437, 850, ...) that garbles any
    // non-ASCII font or theme name.
    const console: ConsoleState = .save();
    if (console.cp != 0) _ = k32.SetConsoleOutputCP(windows.CP_UTF8);

    // ghostty.exe attaches to this console only for the launcher that
    // started it (internal_os.windows.attachLauncherConsole).
    var pid: [10:0]u16 = undefined;
    if (k32.SetEnvironmentVariableW(
        windows.launcher_env,
        windows.formatPid(&pid, windows.GetCurrentProcessId()).ptr,
    ) == windows.FALSE) {
        const err = windows.GetLastError();
        console.restore();
        fail("cannot set {f}: Windows error {d}", .{
            std.unicode.fmtUtf16Le(windows.launcher_env),
            @backingInt(err),
        });
    }

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = windows.STARTF_USESTDHANDLES;
    si.hStdInput = inheritable(windows.STD_INPUT_HANDLE);
    si.hStdOutput = inheritable(windows.STD_OUTPUT_HANDLE);
    si.hStdError = inheritable(windows.STD_ERROR_HANDLE);

    var pi: windows.PROCESS_INFORMATION = undefined;
    if (k32.CreateProcessW(
        exe.ptr,
        line.ptr,
        null,
        null,
        windows.TRUE,
        0,
        null,
        null,
        &si,
        &pi,
    ) == windows.FALSE) {
        // Read first: the restore's console calls set the last error.
        const err = windows.GetLastError();
        console.restore();
        failStart(exe, err);
    }

    _ = k32.WaitForSingleObject(pi.hProcess, windows.INFINITE);
    var code: windows.DWORD = 1;
    _ = k32.GetExitCodeProcess(pi.hProcess, &code);
    // An NTSTATUS error code: ended by a Ctrl event or an exception, past
    // a terminal UI's own cleanup. ghostty.exe's own exit codes are small,
    // and a Zig panic's (3) is one of them, so it gets no reset.
    if (code >= 0xC0000000) console.resetTerminal();
    console.restore();
    std.os.windows.ntdll.RtlExitUserProcess(code);
}

/// The console state an action changes. ghostty.exe turns on VT output
/// (attachLauncherConsole), and a terminal UI (+list-themes, +boo) sets
/// raw, VT input; one ended by a Ctrl+Break, which is a signal even in raw
/// mode, or by a crash, never resets them, and the shell would then read
/// its keys as escape sequences. restore puts the modes and the output
/// code page back after every action; resetTerminal undoes what such a
/// UI turns on with escape sequences.
const ConsoleState = struct {
    /// 0 when the launcher has no console.
    cp: windows.UINT,
    handles: [3]?windows.HANDLE = @splat(null),
    modes: [3]windows.DWORD = @splat(0),

    fn save() ConsoleState {
        var state: ConsoleState = .{ .cp = k32.GetConsoleOutputCP() };
        const which = [_]windows.DWORD{
            windows.STD_INPUT_HANDLE,
            windows.STD_OUTPUT_HANDLE,
            windows.STD_ERROR_HANDLE,
        };
        for (which, 0..) |w, i| {
            const h = k32.GetStdHandle(w) orelse continue;
            if (k32.GetConsoleMode(h, &state.modes[i]) == windows.FALSE) continue;
            state.handles[i] = h;
        }
        return state;
    }

    /// Turns off what a terminal UI (vaxis) turns on with escape sequences,
    /// which only its own exit turns off (Vaxis.resetState and deinit,
    /// WindowsTty.deinit): synchronized output, the alternate screen, which
    /// hides the shell's scrollback, a hidden cursor, text attributes, mouse
    /// and focus reports, bracketed paste, colour-scheme and resize
    /// reports, the kitty keyboard flags and win32-input-mode. Only after
    /// an action that ended without that exit (runCli), so the console of
    /// one that ended normally is left as it is.
    fn resetTerminal(self: *const ConsoleState) void {
        const h = self.handles[1] orelse self.handles[2] orelse return;
        var mode: windows.DWORD = 0;
        if (k32.GetConsoleMode(h, &mode) == windows.FALSE) return;
        _ = k32.SetConsoleMode(h, mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        const reset = std.unicode.utf8ToUtf16LeStringLiteral(
            "\x1b[?2026l\x1b[?1049l\x1b[?25h\x1b[m" ++
                "\x1b[?1000;1002;1003;1004;1006;1016l\x1b[?2004l" ++
                "\x1b[?2031l\x1b[?2048l\x1b[<u\x1b[?9001l",
        );
        var written: windows.DWORD = 0;
        _ = k32.WriteConsoleW(h, reset, reset.len, &written, null);
    }

    fn restore(self: *const ConsoleState) void {
        for (self.handles, self.modes) |h, mode| {
            if (h) |handle| _ = k32.SetConsoleMode(handle, mode);
        }
        if (self.cp != 0) _ = k32.SetConsoleOutputCP(self.cp);
    }
};

/// Starts the terminal and exits without waiting for it. ghostty.exe gets
/// the launcher's own startup information, so what its caller asked of
/// the window (a show state, as `start /min ghostty` asks, a position, a
/// shortcut's name) reaches the first one. Only the std handles and the C
/// runtime's inherited descriptors are dropped, as nothing is inherited.
fn startGui(exe: [:0]u16, line: [:0]u16) noreturn {
    var si: windows.STARTUPINFOW = undefined;
    k32.GetStartupInfoW(&si);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.lpReserved = null;
    si.cbReserved2 = 0;
    si.lpReserved2 = null;
    // With STARTF_USEHOTKEY, which cannot come with STARTF_USESTDHANDLES,
    // hStdInput holds a hotkey instead (STARTUPINFOW's dwFlags).
    if (si.dwFlags & windows.STARTF_USESTDHANDLES != 0) {
        si.dwFlags &= ~@as(windows.DWORD, windows.STARTF_USESTDHANDLES);
        si.hStdInput = null;
        si.hStdOutput = null;
        si.hStdError = null;
    }
    var pi: windows.PROCESS_INFORMATION = undefined;
    if (k32.CreateProcessW(
        exe.ptr,
        line.ptr,
        null,
        null,
        windows.FALSE,
        0,
        null,
        null,
        &si,
        &pi,
    ) == windows.FALSE) failStart(exe, windows.GetLastError());
    _ = k32.CloseHandle(pi.hThread);
    _ = k32.CloseHandle(pi.hProcess);
    std.os.windows.ntdll.RtlExitUserProcess(0);
}

/// Keeps the launcher alive through Ctrl+C and Ctrl+Break. Close, logoff
/// and shutdown go on to the default handler, which ends it: the console
/// is going away.
fn ignoreCtrlC(event: windows.DWORD) callconv(.winapi) windows.BOOL {
    return switch (event) {
        windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT => windows.TRUE,
        else => windows.FALSE,
    };
}

/// This process's std handle as an inheritable duplicate for the child,
/// or null when there is none or it names no handle here. A parent can
/// pass one it did not let us inherit (STARTF_USESTDHANDLES with a
/// non-inheritable handle); passed on, that value would be no handle of
/// the child's either, and AttachConsole replaces only a missing one.
/// Null lets ghostty.exe's attach give it the console's. Duplicating also
/// makes a valid handle inheritable, as STARTF_USESTDHANDLES requires.
fn inheritable(which: windows.DWORD) ?windows.HANDLE {
    const h = k32.GetStdHandle(which) orelse return null;
    if (h == windows.INVALID_HANDLE_VALUE) return null;
    const self = std.os.windows.current_process;
    var dup: windows.HANDLE = undefined;
    if (k32.DuplicateHandle(
        self,
        h,
        self,
        &dup,
        0,
        windows.TRUE,
        windows.DUPLICATE_SAME_ACCESS,
    ) == windows.FALSE) return null;
    return dup;
}

fn failStart(exe: []const u16, err: std.os.windows.Win32Error) noreturn {
    fail("cannot start {f}: Windows error {d}", .{
        std.unicode.fmtUtf16Le(exe),
        @backingInt(err),
    });
}

/// Reports a launcher failure on stderr and exits with 1.
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    const message = "ghostty: " ++ fmt ++ "\n";
    if (!writeConsoleError(message, args)) std.debug.print(message, args);
    std.os.windows.ntdll.RtlExitUserProcess(1);
}

/// Writes the message to stderr as UTF-16 when it is a console, so a path
/// outside the console's code page (an install under C:\Users\Jörg) shows
/// as it is; false otherwise, and a file or a pipe gets UTF-8.
fn writeConsoleError(comptime fmt: []const u8, args: anytype) bool {
    const h = k32.GetStdHandle(windows.STD_ERROR_HANDLE) orelse return false;
    var mode: windows.DWORD = 0;
    if (k32.GetConsoleMode(h, &mode) == windows.FALSE) return false;
    const alloc = std.heap.page_allocator;
    const utf8 = std.fmt.allocPrint(alloc, fmt, args) catch return false;
    const text = std.unicode.utf8ToUtf16LeAlloc(alloc, utf8) catch return false;
    var written: windows.DWORD = 0;
    return k32.WriteConsoleW(h, text.ptr, @intCast(text.len), &written, null) != windows.FALSE;
}

fn unicodeSlice(s: windows.UNICODE_STRING) []const u16 {
    const buf = s.Buffer orelse return &.{};
    return buf[0 .. s.Length / 2];
}

/// The arguments after argv[0] in a Windows command line, with the
/// whitespace before them. argv[0] is split as the MSVC runtime and Zig's
/// iterator split it: quotes group and are not escapes, and an unquoted
/// space or tab ends it. Passed on unchanged after a new argv[0], the
/// child parses the same arguments the launcher did.
fn argsTail(cmdline: []const u16) []const u16 {
    var quoted = false;
    for (cmdline, 0..) |c, i| switch (c) {
        '"' => quoted = !quoted,
        ' ', '\t' => if (!quoted) return cmdline[i..],
        else => {},
    };
    return cmdline[cmdline.len..];
}

/// ghostty.exe beside the launcher: the launcher's own image path with
/// the extension replaced, so a renamed pair (ghostty-dev.com and
/// ghostty-dev.exe) keeps working.
fn exePath(alloc: Allocator, image: []const u16) Allocator.Error![:0]u16 {
    const name = if (std.mem.lastIndexOfAny(u16, image, &.{ '\\', '/' })) |i|
        i + 1
    else
        0;
    const stem = if (std.mem.lastIndexOfScalar(u16, image[name..], '.')) |dot|
        image[0 .. name + dot]
    else
        image;
    const ext = std.unicode.utf8ToUtf16LeStringLiteral(".exe");
    return std.mem.concatWithSentinel(alloc, u16, &.{ stem, ext }, 0);
}

/// The command line for ghostty.exe: its path, quoted (a Windows path
/// cannot contain a quote), then the launcher's arguments as typed.
fn childCommandLine(
    alloc: Allocator,
    exe: []const u16,
    tail: []const u16,
) Allocator.Error![:0]u16 {
    const q: []const u16 = &.{'"'};
    return std.mem.concatWithSentinel(alloc, u16, &.{ q, exe, q, tail }, 0);
}

const testing = std.testing;

fn testArgs(alloc: Allocator, cmdline: []const u16) ![]const []const u8 {
    var it = try ArgIterator.init(alloc, cmdline);
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| try list.append(alloc, try alloc.dupe(u8, arg));
    return list.items;
}

/// The child's arguments, parsed as ghostty.exe will parse them, against
/// the launcher's own: the same after argv[0], which is ghostty.exe. And
/// the same decision: the launcher's against ghostty.exe's detection over
/// its whole command line, its path included.
fn expectForwarded(cmdline: []const u16) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const exe = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Ghostty\\ghostty.exe");
    const line = try childCommandLine(alloc, exe, argsTail(cmdline));
    const want = try testArgs(alloc, cmdline);
    const got = try testArgs(alloc, line);
    try testing.expectEqualStrings("C:\\Program Files\\Ghostty\\ghostty.exe", got[0]);
    // An empty command line has no argv[0] either.
    const rest = if (want.len == 0) want else want[1..];
    try testing.expectEqual(rest.len + 1, got.len);
    for (rest, got[1..]) |w, g| try testing.expectEqualStrings(w, g);

    var child = try ArgIterator.init(alloc, line);
    try testing.expectEqual(isCli(&child), try launcherIsCli(alloc, cmdline));
}

test "argsTail" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqualSlices(u16, L(" +version"), argsTail(L("ghostty +version")));
    try testing.expectEqualSlices(u16, L(" +list-fonts --family=\"A B\""), argsTail(
        L("\"C:\\Program Files\\Ghostty\\ghostty.com\" +list-fonts --family=\"A B\""),
    ));
    // A quote inside argv[0] still groups, and a tab ends it.
    try testing.expectEqualSlices(u16, L("\t+help"), argsTail(L("C:\\\"a b\"\\ghostty\t+help")));
    try testing.expectEqualSlices(u16, L(""), argsTail(L("ghostty")));
    // An unclosed quote runs argv[0] to the end.
    try testing.expectEqualSlices(u16, L(""), argsTail(L("\"C:\\a b\\ghostty +version")));
}

test "forwarded arguments match the launcher's" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try expectForwarded(L("ghostty"));
    try expectForwarded(L("ghostty +version"));
    try expectForwarded(L("\"C:\\Program Files\\Ghostty\\ghostty.com\" +list-fonts --family=\"A B\""));
    try expectForwarded(L("C:\\\"a b\"\\ghostty.com\t+help  \"\" x"));
    try expectForwarded(L("ghostty --title=\"a \\\"q\\\" b\" \\\\\"c d\" é"));
    try expectForwarded(L("\"C:\\a b\\ghostty +version"));

    // Every line of up to six of the characters that change the split.
    const alphabet = L("a \t\"\\+");
    var buf: [6]u16 = undefined;
    for (0..buf.len + 1) |len| {
        var digits: [buf.len]usize = @splat(0);
        while (true) {
            for (buf[0..len], digits[0..len]) |*c, d| c.* = alphabet[d];
            try expectForwarded(buf[0..len]);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            }
            if (i == len) break;
        }
    }

    // Longer lines at random, of pieces that change the decision too.
    const pieces = [_][]const u16{
        L("+version"), L("--version"), L("-e"), L("-h"), L("+nope"), L("+"),
        L("a"),        L(" "),         L("\t"), L("\""), L("\\"),
    };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    var line: [8 * "--version".len]u16 = undefined;
    for (0..20_000) |_| {
        var len: usize = 0;
        for (0..rand.uintAtMost(usize, 8)) |_| {
            const piece = pieces[rand.uintLessThan(usize, pieces.len)];
            @memcpy(line[len..][0..piece.len], piece);
            len += piece.len;
        }
        try expectForwarded(line[0..len]);
    }
}

test "exePath" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const alloc = testing.allocator;
    const cases = [_][2][]const u16{
        .{ L("C:\\Program Files\\Ghostty\\ghostty.com"), L("C:\\Program Files\\Ghostty\\ghostty.exe") },
        .{ L("C:\\g\\ghostty-dev.com"), L("C:\\g\\ghostty-dev.exe") },
        // A dot in a directory is not the extension.
        .{ L("C:\\v1.2\\ghostty"), L("C:\\v1.2\\ghostty.exe") },
        // A forward slash separates too.
        .{ L("C:/v1.2/ghostty"), L("C:/v1.2/ghostty.exe") },
        .{ L("ghostty.com"), L("ghostty.exe") },
    };
    for (cases) |c| {
        const got = try exePath(alloc, c[0]);
        defer alloc.free(got);
        try testing.expectEqualSlices(u16, c[1], got);
    }
}

test "isCli" {
    const Iter = struct {
        args: []const []const u8,
        i: usize = 0,
        pub fn next(self: *@This()) ?[]const u8 {
            if (self.i == self.args.len) return null;
            defer self.i += 1;
            return self.args[self.i];
        }
    };
    const cases = [_]struct { []const []const u8, bool }{
        .{ &.{"ghostty"}, false },
        .{ &.{ "ghostty", "--font-size=12" }, false },
        .{ &.{ "ghostty", "+version" }, true },
        .{ &.{ "ghostty", "--version" }, true },
        .{ &.{ "ghostty", "-h" }, true },
        .{ &.{ "ghostty", "+list-fonts", "--help" }, true },
        // ghostty.exe reports these as errors, so they need the console.
        .{ &.{ "ghostty", "+nope" }, true },
        .{ &.{ "ghostty", "+version", "+help" }, true },
        // `-e` before any action: the rest is the command to run.
        .{ &.{ "ghostty", "-e", "ghostty", "+version" }, false },
    };
    for (cases) |c| {
        var it: Iter = .{ .args = c[0] };
        try testing.expectEqual(c[1], isCli(&it));
    }
}

test "launcherIsCli skips argv[0]" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A caller that leaves argv[0] out: the first argument is argv[0], and
    // ghostty.exe gets no arguments, so it opens a window.
    try testing.expect(!try launcherIsCli(alloc, L("+version")));
    try testing.expect(!try launcherIsCli(alloc, L("--version")));
    try testing.expect(try launcherIsCli(alloc, L("ghostty +version")));
    try testing.expect(!try launcherIsCli(alloc, L("")));
}

test "launcher process IDs" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [10:0]u16 = undefined;
    try testing.expectEqualSlices(u16, L("0"), windows.formatPid(&buf, 0));
    try testing.expectEqualSlices(u16, L("4294967295"), windows.formatPid(&buf, std.math.maxInt(windows.DWORD)));
    for ([_]windows.DWORD{ 0, 4, 9, 10, 1234, 65535, 4294967295 }) |pid| {
        const text = windows.formatPid(&buf, pid);
        try testing.expectEqual(@as(u16, 0), text.ptr[text.len]);
        try testing.expectEqual(@as(?windows.DWORD, pid), windows.parsePid(text));
    }
    for ([_][]const u16{ L(""), L("12a"), L("-1"), L(" 12"), L("4294967296"), L("99999999999") }) |text| {
        try testing.expectEqual(@as(?windows.DWORD, null), windows.parsePid(text));
    }
}
