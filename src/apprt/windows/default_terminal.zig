//! Ghostty as the terminal Windows opens consoles in (`handoff` serves
//! them): `ghostty +default-terminal` and the command palette's entry.
//!
//! Windows reads the choice from HKCU\Console\%%Startup: DelegationConsole
//! names the console server the inbox conhost hands a console to, and
//! DelegationTerminal the terminal that server hands it on to. Only an
//! OpenConsole hands one on, so Ghostty pairs itself with Windows
//! Terminal's, whose package registers its class (PackagedCom\ClassIndex).
//! It must call ITerminalHandoff3, the only version Ghostty's class
//! answers: Windows Terminal 1.22 and later, whose package registers that
//! interface (PackagedCom\InterfaceIndex) where older ones registered
//! ITerminalHandoff2 (microsoft/terminal#17575).
//! Settings' "Default terminal application" lists packaged apps only, so
//! Ghostty writes the two values itself, as Settings writes them, and
//! saves those it replaces to put them back.
//!
//! Consoles started as administrator keep the console host: Windows
//! ignores the user's classes for an elevated caller.
const std = @import("std");

const IpcClient = @import("IpcClient.zig");
const handoff = @import("handoff.zig");
const registry = @import("registry.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// Windows Terminal's OpenConsole: the console server Ghostty pairs with.
const open_console = "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}";

/// ITerminalHandoff3 (`handoff.iid_handoff3`), as the package index names
/// it.
const handoff3 = "{6F23DA90-15C5-4203-9DB0-64E73F1B1B00}";

/// Ghostty's class (`handoff.clsid`), as Settings writes a class.
const ghostty = handoff.clsid_text;

const console_name = W("DelegationConsole");
const terminal_name = W("DelegationTerminal");

const error_file_not_found: win32.LONG = 2;

pub const Error = error{
    /// Windows Terminal's console server is not installed.
    NoWindowsTerminal,
    /// A value to save is not a string, or is too long to keep exactly.
    UnexpectedValue,
    RegistryFailed,
};

/// Where the choice is read and written: the user's keys, or a test's.
pub const Place = struct {
    /// Every key below is under it, but `console_class`.
    root: win32.HKEY,
    /// Console\%%Startup.
    startup: [*:0]const u16,
    /// The user's classes, which hold Ghostty's (`handoff.Watch`), and
    /// Ghostty's class (`handoff.class_key`) and its server command.
    classes: [*:0]const u16,
    class: [*:0]const u16,
    server: [*:0]const u16,
    /// The %%Startup values Ghostty replaced, until it puts them back.
    /// The key's presence is the record: a value absent from it was
    /// absent from %%Startup.
    saved: [*:0]const u16,
    /// Under `packaged_root`: OpenConsole's packaged class, which says it
    /// is installed, and the packaged ITerminalHandoff3, which says it is
    /// recent enough to hand a console to Ghostty.
    packaged_root: win32.HKEY,
    console_class: [*:0]const u16,
    console_interface: [*:0]const u16,

    pub const user = at(
        win32.HKEY_CURRENT_USER,
        "",
        win32.HKEY_CLASSES_ROOT,
        "PackagedCom\\",
    );

    /// Every key under `root`, `prefix` before its path, and the packages'
    /// index under `packaged_root`, `packaged` before its path; for tests,
    /// keys of their own.
    pub fn at(
        root: win32.HKEY,
        comptime prefix: []const u8,
        packaged_root: win32.HKEY,
        comptime packaged: []const u8,
    ) Place {
        // The paths' UTF-16 forms are made at compile time.
        @setEvalBranchQuota(20_000);
        return .{
            .root = root,
            .startup = W(prefix ++ "Console\\%%Startup"),
            .classes = W(prefix ++ handoff.classes_key),
            .class = W(prefix ++ handoff.class_key),
            .server = W(prefix ++ handoff.server_key),
            .saved = W(prefix ++ "Software\\Ghostty\\DefaultTerminal"),
            .packaged_root = packaged_root,
            .console_class = W(packaged ++ "ClassIndex\\" ++ open_console),
            .console_interface = W(packaged ++ "InterfaceIndex\\" ++ handoff3),
        };
    }
};

/// Whether Windows hands consoles to Ghostty: %%Startup names its class.
pub fn isDefault(place: Place) Error!bool {
    const value = try read(place.root, place.startup, terminal_name);
    const terminal = value.slice() orelse return false;
    return std.os.windows.eqlIgnoreCaseWtf16(terminal, W(ghostty));
}

/// Whether Ghostty can be the default terminal: Windows Terminal's
/// console server is installed, one that calls ITerminalHandoff3.
pub fn available(place: Place) bool {
    return exists(place.packaged_root, place.console_class) and
        exists(place.packaged_root, place.console_interface);
}

/// Make Ghostty the default terminal, its class starting `exe` (this
/// process's image, `IpcClient.imagePath`), and save the %%Startup values
/// it replaces, unless it is the default already: those saved then are
/// the ones to put back.
pub fn enable(place: Place, exe: []const u16) Error!void {
    if (!available(place)) return error.NoWindowsTerminal;
    // Read before anything is written: values that cannot be saved
    // exactly leave everything as it was.
    const replacing = !try isDefault(place);
    const console: Value = if (replacing) try read(place.root, place.startup, console_name) else .{};
    const terminal: Value = if (replacing) try read(place.root, place.startup, terminal_name) else .{};
    try writeClass(place, exe);
    if (replacing) {
        // A record left by a choice made in Settings since is stale.
        try deleteTree(place.root, place.saved);
        try createKey(place.root, place.saved);
        try put(place.root, place.saved, console_name, console);
        try put(place.root, place.saved, terminal_name, terminal);
    }
    // DelegationTerminal first: it alone makes Ghostty the default
    // (`isDefault`), so a failure writing the console after it leaves
    // Ghostty the default with the record saved, which `disable` puts
    // back whole, rather than a pair naming another terminal's console
    // and no record.
    try write(place.root, place.startup, terminal_name, W(ghostty));
    try write(place.root, place.startup, console_name, W(open_console));
}

/// What `disable` did.
pub const Disabled = enum {
    /// The values Ghostty replaced are back, or with none saved, Windows
    /// decides again.
    restored,
    /// Another terminal was chosen since Ghostty was: kept.
    kept,
    /// Ghostty was not the default terminal: nothing changed.
    not_default,
};

/// Stop Ghostty being the default terminal: put back the %%Startup values
/// `enable` saved, if Ghostty is still the one there; never undo a choice
/// made since. The record goes once nothing is left to put back, and
/// stays if putting it back fails, for another try. The class stays,
/// inert without %%Startup naming it.
pub fn disable(place: Place) Error!Disabled {
    const saved = exists(place.root, place.saved);
    if (!try isDefault(place)) {
        try deleteTree(place.root, place.saved);
        return if (saved) .kept else .not_default;
    }
    if (saved) {
        const console = try read(place.root, place.saved, console_name);
        const terminal = try read(place.root, place.saved, terminal_name);
        try put(place.root, place.startup, console_name, console);
        try put(place.root, place.startup, terminal_name, terminal);
    } else {
        try remove(place.root, place.startup, console_name);
        try remove(place.root, place.startup, terminal_name);
    }
    try deleteTree(place.root, place.saved);
    return .restored;
}

fn writeClass(place: Place, exe: []const u16) Error!void {
    var buf: [registry.command_units]u16 = undefined;
    if (exe.len + 3 > buf.len) return error.UnexpectedValue;
    buf[0] = '"';
    @memcpy(buf[1..][0..exe.len], exe);
    buf[exe.len + 1] = '"';
    buf[exe.len + 2] = 0;
    try write(place.root, place.class, null, W("Ghostty"));
    try write(place.root, place.server, null, buf[0 .. exe.len + 2 :0]);
}

/// What `ghostty +default-terminal` was asked: to say whether Ghostty is
/// the default terminal, to make it the default, or to put the previous
/// default back.
pub const Request = enum { status, enable, disable };

/// `ghostty +default-terminal`: carry out `request` on the user's keys and
/// say what came of it on `out`; the exit code.
pub fn command(alloc: std.mem.Allocator, request: Request, out: *std.Io.Writer) std.Io.Writer.Error!u8 {
    const place: Place = .user;
    switch (request) {
        .status => {
            const is = isDefault(place) catch |err| {
                try out.print("Cannot read the default terminal ({s}).\n", .{@errorName(err)});
                return 1;
            };
            if (is) {
                try out.writeAll("Ghostty is the default terminal.\n");
            } else if (available(place)) {
                try out.writeAll("Ghostty is not the default terminal. " ++
                    "`ghostty +default-terminal --enable` makes it the default.\n");
            } else {
                try out.writeAll(unavailable);
            }
            return 0;
        },
        .enable => {
            const exe = IpcClient.imagePath(alloc) catch {
                try out.writeAll("Out of memory.\n");
                return 1;
            };
            defer alloc.free(exe);
            enable(place, exe) catch |err| {
                switch (err) {
                    error.NoWindowsTerminal => try out.writeAll(unavailable),
                    else => try out.print("Ghostty could not be made the default terminal ({s}).\n", .{@errorName(err)}),
                }
                return 1;
            };
            try out.writeAll("Ghostty is now the default terminal. Consoles started as administrator " ++
                "still open in the console host. `ghostty +default-terminal --disable` " ++
                "puts the previous default back.\n");
            return 0;
        },
        .disable => {
            const result = disable(place) catch |err| {
                try out.print("The previous default terminal could not be put back ({s}).\n", .{@errorName(err)});
                return 1;
            };
            try out.writeAll(switch (result) {
                .restored => "The previous default terminal is back.\n",
                .kept => "Another default terminal was chosen since Ghostty was; it is kept.\n",
                .not_default => "Ghostty is not the default terminal; nothing changed.\n",
            });
            return 0;
        },
    }
}

const unavailable = "Ghostty can be the default terminal only with Windows Terminal 1.22 " ++
    "or later installed: it uses Windows Terminal's console server.\n";

/// A string value as read, or absent.
const Value = struct {
    buf: [256]u16 = undefined,
    len: ?usize = null,

    fn slice(self: *const Value) ?[:0]const u16 {
        const len = self.len orelse return null;
        return self.buf[0..len :0];
    }
};

fn read(root: win32.HKEY, subkey: [*:0]const u16, name: [*:0]const u16) Error!Value {
    var value: Value = .{};
    const text = try registry.readString(root, subkey, name, &value.buf);
    value.len = if (text) |t| t.len else null;
    return value;
}

/// `value` written, or removed if it was absent.
fn put(root: win32.HKEY, subkey: [*:0]const u16, name: [*:0]const u16, value: Value) Error!void {
    if (value.slice()) |text| return write(root, subkey, name, text);
    return remove(root, subkey, name);
}

fn write(root: win32.HKEY, subkey: [*:0]const u16, name: ?[*:0]const u16, text: [:0]const u16) Error!void {
    return registry.writeString(root, subkey, name, text);
}

fn remove(root: win32.HKEY, subkey: [*:0]const u16, name: [*:0]const u16) Error!void {
    const rc = win32.RegDeleteKeyValueW(root, subkey, name);
    if (rc != 0 and rc != error_file_not_found) {
        log.warn("cannot remove a default terminal value err={d}", .{rc});
        return error.RegistryFailed;
    }
}

fn createKey(root: win32.HKEY, subkey: [*:0]const u16) Error!void {
    var key: win32.HKEY = undefined;
    const rc = win32.RegCreateKeyExW(root, subkey, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_SET_VALUE, null, &key, null);
    if (rc != 0) {
        log.warn("cannot make a default terminal key err={d}", .{rc});
        return error.RegistryFailed;
    }
    _ = win32.RegCloseKey(key);
}

fn deleteTree(root: win32.HKEY, subkey: [*:0]const u16) Error!void {
    const rc = win32.RegDeleteTreeW(root, subkey);
    if (rc != 0 and rc != error_file_not_found) {
        log.warn("cannot remove a default terminal key err={d}", .{rc});
        return error.RegistryFailed;
    }
}

fn exists(root: win32.HKEY, subkey: [*:0]const u16) bool {
    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(root, subkey, 0, win32.KEY_QUERY_VALUE, &key) != 0) return false;
    _ = win32.RegCloseKey(key);
    return true;
}

/// A place of the test's own under HKCU\Software\GhosttyTest\dt, removed
/// by `testCleanup`, never the user's %%Startup: every App a test makes
/// has it (`App.default_terminal_place`). A test that uses it holds
/// `testLock`.
const test_prefix = "Software\\GhosttyTest\\dt\\";
pub const test_place: Place = .at(
    win32.HKEY_CURRENT_USER,
    test_prefix,
    win32.HKEY_CURRENT_USER,
    test_prefix ++ "PackagedCom\\",
);
const test_exe = W("C:\\Program Files\\Ghostty\\ghostty.exe");
/// Windows Terminal's pair, as Settings writes it.
const wt_console = W(open_console);
const wt_terminal = W("{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}");
/// The console host's.
const conhost = W("{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}");

pub fn testCleanup() void {
    _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, W(test_prefix[0 .. test_prefix.len - 1]));
}

/// Held while a test uses `test_place`: every test process of this user
/// shares it, as two test executables run at once would.
pub const TestLock = struct {
    mutex: win32.HANDLE,

    pub fn release(self: TestLock) void {
        _ = win32.ReleaseMutex(self.mutex);
        _ = win32.CloseHandle(self.mutex);
    }
};

pub fn testLock() !TestLock {
    const mutex = win32.CreateMutexW(null, .FALSE, W("Local\\GhosttyTestDefaultTerminal")) orelse
        return error.TestUnexpectedResult;
    switch (win32.WaitForSingleObject(mutex, win32.INFINITE)) {
        // Abandoned: a test process died holding it; the keys are
        // cleaned up before use anyway.
        win32.WAIT_OBJECT_0, win32.WAIT_ABANDONED => return .{ .mutex = mutex },
        else => {
            _ = win32.CloseHandle(mutex);
            return error.TestUnexpectedResult;
        },
    }
}

/// Windows Terminal's console server, as installed, for `test_place`:
/// 1.22 or later, or with `old`, an earlier one, which calls
/// ITerminalHandoff2.
pub fn testInstallTerminal(version: enum { current, old }) !void {
    try createKey(test_place.packaged_root, test_place.console_class);
    switch (version) {
        .current => try createKey(test_place.packaged_root, test_place.console_interface),
        .old => try deleteTree(test_place.packaged_root, test_place.console_interface),
    }
}

/// %%Startup's two values: each a string, or null for absent.
fn testSet(console: ?[:0]const u16, terminal: ?[:0]const u16) !void {
    if (console) |v| try write(test_place.root, test_place.startup, console_name, v) else try remove(test_place.root, test_place.startup, console_name);
    if (terminal) |v| try write(test_place.root, test_place.startup, terminal_name, v) else try remove(test_place.root, test_place.startup, terminal_name);
}

fn testExpect(console: ?[:0]const u16, terminal: ?[:0]const u16) !void {
    const pairs = [_]struct { [*:0]const u16, ?[:0]const u16 }{ .{ console_name, console }, .{ terminal_name, terminal } };
    for (pairs) |pair| {
        const got = try read(test_place.root, test_place.startup, pair[0]);
        if (pair[1]) |want| {
            try std.testing.expectEqualSlices(u16, want, got.slice() orelse return error.TestExpectedValue);
        } else {
            try std.testing.expectEqual(null, got.slice());
        }
    }
}

test "win32: making Ghostty the default terminal and undoing it puts %%Startup back exactly" {
    const lock = try testLock();
    defer lock.release();
    defer testCleanup();
    const cases = [_]struct { ?[:0]const u16, ?[:0]const u16 }{
        // Let Windows decide: no values.
        .{ null, null },
        .{ wt_console, wt_terminal },
        .{ conhost, conhost },
        // Half a pair, as a hand edit leaves it.
        .{ conhost, null },
    };
    for (cases) |case| {
        testCleanup();
        try testInstallTerminal(.current);
        try testSet(case[0], case[1]);
        try std.testing.expect(!try isDefault(test_place));

        try enable(test_place, test_exe);
        try std.testing.expect(try isDefault(test_place));
        try testExpect(wt_console, W(ghostty));
        const server = try read(test_place.root, test_place.server, W(""));
        try std.testing.expectEqualSlices(u16, W("\"C:\\Program Files\\Ghostty\\ghostty.exe\""), server.slice().?);
        try std.testing.expect(handoff.serverNames(test_place.root, test_place.server, test_exe));

        try std.testing.expectEqual(.restored, try disable(test_place));
        try testExpect(case[0], case[1]);
        try std.testing.expect(!exists(test_place.root, test_place.saved));
        try std.testing.expect(!try isDefault(test_place));
    }
}

test "win32: making Ghostty the default terminal twice saves the values it first replaced" {
    const lock = try testLock();
    defer lock.release();
    defer testCleanup();
    testCleanup();
    try testInstallTerminal(.current);
    try testSet(wt_console, wt_terminal);
    try enable(test_place, test_exe);
    try enable(test_place, test_exe);
    try std.testing.expectEqual(.restored, try disable(test_place));
    try testExpect(wt_console, wt_terminal);
    // Undone already: nothing more to do.
    try std.testing.expectEqual(.not_default, try disable(test_place));
    try testExpect(wt_console, wt_terminal);
}

test "win32: a default terminal chosen after Ghostty is kept" {
    const lock = try testLock();
    defer lock.release();
    defer testCleanup();
    testCleanup();
    try testInstallTerminal(.current);
    try testSet(null, null);
    try enable(test_place, test_exe);
    // Settings' choice of Windows Terminal.
    try testSet(wt_console, wt_terminal);
    try std.testing.expectEqual(.kept, try disable(test_place));
    try testExpect(wt_console, wt_terminal);
    try std.testing.expect(!exists(test_place.root, test_place.saved));
}

test "win32: making Ghostty the default terminal again after a choice in Settings saves that choice" {
    const lock = try testLock();
    defer lock.release();
    defer testCleanup();
    testCleanup();
    try testInstallTerminal(.current);
    try testSet(conhost, conhost);
    try enable(test_place, test_exe);
    // Settings' choice of Windows Terminal, then Ghostty again: the
    // record of the console host is stale.
    try testSet(wt_console, wt_terminal);
    try enable(test_place, test_exe);
    try std.testing.expectEqual(.restored, try disable(test_place));
    try testExpect(wt_console, wt_terminal);
}

test "win32: undoing Ghostty as the default terminal with its record gone lets Windows decide" {
    const lock = try testLock();
    defer lock.release();
    defer testCleanup();
    testCleanup();
    try testInstallTerminal(.current);
    try testSet(wt_console, wt_terminal);
    try enable(test_place, test_exe);
    try deleteTree(test_place.root, test_place.saved);
    try std.testing.expectEqual(.restored, try disable(test_place));
    try testExpect(null, null);
    try std.testing.expect(!try isDefault(test_place));
}

test "win32: Ghostty is the default terminal only with Windows Terminal's console server, and only from values it can save" {
    const lock = try testLock();
    defer lock.release();
    defer testCleanup();
    testCleanup();
    try testSet(conhost, conhost);
    try std.testing.expectError(error.NoWindowsTerminal, enable(test_place, test_exe));
    try testExpect(conhost, conhost);
    try std.testing.expect(!exists(test_place.root, test_place.class));
    try std.testing.expect(!available(test_place));

    // Nor with one before 1.22, whose console server asks for
    // ITerminalHandoff2.
    try testInstallTerminal(.old);
    try std.testing.expect(!available(test_place));
    try std.testing.expectError(error.NoWindowsTerminal, enable(test_place, test_exe));
    try testExpect(conhost, conhost);
    try std.testing.expect(!exists(test_place.root, test_place.class));

    // A value that is not a string cannot be put back as it was.
    try testInstallTerminal(.current);
    try std.testing.expect(available(test_place));
    var key: win32.HKEY = undefined;
    try std.testing.expectEqual(0, win32.RegCreateKeyExW(test_place.root, test_place.startup, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_SET_VALUE, null, &key, null));
    defer _ = win32.RegCloseKey(key);
    const one: win32.DWORD = 1;
    try std.testing.expectEqual(0, win32.RegSetValueExW(key, terminal_name, 0, win32.REG_DWORD, std.mem.asBytes(&one), 4));
    try std.testing.expectError(error.UnexpectedValue, enable(test_place, test_exe));
    try std.testing.expect(!exists(test_place.root, test_place.class));
    try std.testing.expect(!exists(test_place.root, test_place.saved));
}

test "win32: the interface the package index names is the one the class answers" {
    try std.testing.expectEqual(handoff.iid_handoff3, std.os.windows.GUID.parse(handoff3));
}
