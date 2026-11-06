//! Files dropped on a terminal (WM_DROPFILES): their paths are pasted,
//! each quoted for the shell the terminal starts and joined
//! by spaces with no newline after, as macOS pastes a drop
//! (`getOpinionatedStringContents` in
//! macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift).
//!
//! macOS backslash-escapes every path for a POSIX shell, and GTK does
//! the same (`dtDrop`). On Windows the shell is usually cmd.exe or
//! PowerShell, which read a backslash as a path separator, so each shell
//! gets its own quoting (`appendQuoted`), from the shell the shell
//! integration forces or detects (`shellOf`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const configpkg = @import("../../config.zig");
const shell_integration = @import("../../termio/shell_integration.zig");
const Shell = shell_integration.Shell;

const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// The shell a terminal starts, for quoting what a drop pastes; null when
/// it is not one Ghostty knows. As the core chooses what to run
/// (src/Surface.zig, `init`: `initial-command` for the app's first
/// terminal, `command` otherwise, and without either cmd.exe, as
/// `Subprocess.init` in src/termio/Exec.zig, which runs it as %COMSPEC%,
/// taken here to be cmd), and as the shell integration names it: the
/// shell `shell-integration` forces, else the one it detects from that
/// command. Detected with `shell-integration = none` too: the shell reads
/// the paste either way. A shell started inside it later (`pwsh` typed at
/// cmd's prompt, ssh) reads what is pasted then, quoted for this one.
/// `first` must be read before the core's `init`, which clears it.
pub fn shellOf(
    alloc: Allocator,
    config: *const configpkg.Config,
    first: bool,
) Allocator.Error!?Shell {
    switch (config.@"shell-integration") {
        .none, .detect => {},
        .bash => return .bash,
        .cmd => return .cmd,
        .elvish => return .elvish,
        .fish => return .fish,
        .nushell => return .nushell,
        .powershell => return .powershell,
        .zsh => return .zsh,
    }

    const command: configpkg.Command = command: {
        if (first) if (config.@"initial-command") |command| break :command command;
        break :command config.command orelse .{ .shell = "cmd.exe" };
    };
    if (try shell_integration.detectShell(alloc, command)) |shell| return shell;

    // detectShell ignores case and an `.exe` suffix only for cmd and
    // PowerShell, so it names no shell started as `bash.exe` (System32's
    // is WSL's), `C:\msys64\usr\bin\zsh.exe` or `Nu.EXE`, and the
    // integration leaves those alone. Their quoting is still their shell's,
    // so the name is asked again in lower case without the suffix.
    var args = try command.argIterator(alloc);
    defer args.deinit();
    const exe = std.fs.path.basename(args.next() orelse return null);
    const stem = if (std.ascii.endsWithIgnoreCase(exe, ".exe")) exe[0 .. exe.len - ".exe".len] else exe;
    // A name this long is no shell's.
    var buf: [32]u8 = undefined;
    if (stem.len >= buf.len) return null;
    const name = std.ascii.lowerString(&buf, stem);
    if (std.mem.eql(u8, name, exe)) return null;
    buf[name.len] = 0;
    return try shell_integration.detectShell(alloc, .{ .direct = &.{buf[0..name.len :0]} });
}

/// Whether a drop of `pasted`, quoted for `shell`, is to be confirmed before
/// it is pasted: for a shell Ghostty does not know, when it holds `$`, a
/// backtick or `!`. Such a shell gets cmd's double quotes (`appendQuoted`),
/// which a POSIX shell (WSL's, an ssh session's) also reads as one word,
/// but in which it still expands those three, so a name made to run a
/// command would run it on Enter. The core's paste protection sees nothing
/// unsafe there (no newline), and a bracketed paste does not help either:
/// the shell expands the line when Enter is pressed.
pub fn asks(shell: ?Shell, pasted: []const u8) bool {
    return shell == null and std.mem.indexOfAny(u8, pasted, "$`!") != null;
}

/// The text a drop of the files in `hdrop` pastes for `shell`: each
/// file's path quoted, in the drop's order, joined by spaces. Null when
/// no path could be read. The caller still owns `hdrop` and frees the
/// result.
pub fn text(alloc: Allocator, shell: ?Shell, hdrop: win32.HDROP) Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var paths: Paths = .init(hdrop);
    defer paths.deinit(alloc);
    while (try paths.next(alloc)) |path| {
        defer alloc.free(path);
        if (out.items.len != 0) try out.append(alloc, ' ');
        try appendQuoted(alloc, &out, shell, path);
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

/// The paths of the files in `hdrop`, a drop's or the clipboard's
/// CF_HDROP, as UTF-8, in its order. A name that is not valid UTF-16
/// (NTFS allows an unpaired surrogate) is left out and logged: as U+FFFD
/// it would name another file, or none. So is one that cannot be read.
pub const Paths = struct {
    hdrop: win32.HDROP,
    count: win32.UINT,
    index: win32.UINT = 0,
    wide: std.ArrayList(u16) = .empty,

    pub fn init(hdrop: win32.HDROP) Paths {
        return .{ .hdrop = hdrop, .count = win32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0) };
    }

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        self.wide.deinit(alloc);
    }

    /// The next path, which the caller frees; null after the last.
    pub fn next(self: *Paths, alloc: Allocator) Allocator.Error!?[]u8 {
        while (self.index < self.count) {
            const i = self.index;
            self.index += 1;
            // The length without the NUL, which the buffer must also hold.
            const len = win32.DragQueryFileW(self.hdrop, i, null, 0);
            if (len == 0) continue;
            try self.wide.resize(alloc, @as(usize, len) + 1);
            if (win32.DragQueryFileW(self.hdrop, i, self.wide.items.ptr, len + 1) != len) {
                log.warn("a file list's name could not be read index={d}", .{i});
                continue;
            }
            return std.unicode.utf16LeToUtf8Alloc(alloc, self.wide.items[0..len]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| {
                    log.warn("a file list's name is not valid UTF-16, left out index={d} err={}", .{ i, e });
                    continue;
                },
            };
        }
        return null;
    }
};

/// Appends `path` to `out` written so that `shell` reads it back as one
/// word that is `path` unchanged. A Win32 name cannot hold `"`, `*`, `?`,
/// `<`, `>`, `|`, a control character or `/` (Microsoft's "Naming Files,
/// Paths, and Namespaces"), so the quoting below needs none of them.
///
/// Exceptions, none of which the quoting can stop: cmd.exe expands
/// `%name%` inside quotes, so a name with a defined variable's name
/// between two `%` pastes that variable's value; with delayed expansion
/// on (`cmd /V:ON`) it expands `!name!` too, and a line with a `!` loses
/// its carets. A shell Ghostty does not know gets cmd's double quotes,
/// always, which C runtimes' argument parsing and POSIX shells also read
/// as one word, though a POSIX shell expands `$`, a backtick and `!` in
/// them (such a drop asks first, `asks`) and reads `\\` as one backslash.
/// And "unchanged" is what the shell reads: a program it starts that was
/// built for an ANSI code page gets a best-fit conversion of its command
/// line, in which a character a name may hold, such as the fullwidth
/// quotation mark, can become ASCII quoting.
fn appendQuoted(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    shell: ?Shell,
    path: []const u8,
) Allocator.Error!void {
    const known = shell orelse return appendDoubleQuoted(alloc, out, path);
    switch (known) {
        .cmd => if (plain(path)) {
            try out.appendSlice(alloc, path);
        } else {
            try appendDoubleQuoted(alloc, out, path);
        },

        // Single quotes take everything literally but a single quote,
        // which is doubled; PowerShell's tokenizer takes the typographic
        // single quotes U+2018 to U+201B as single quotes too
        // (about_Quoting_Rules), so each of them is doubled as well.
        .powershell => if (plain(path)) {
            try out.appendSlice(alloc, path);
        } else {
            try out.append(alloc, '\'');
            var i: usize = 0;
            while (i < path.len) {
                const n: usize = if (powerShellQuote(path[i..])) |n| n else 1;
                try out.appendSlice(alloc, path[i..][0..n]);
                if (n > 1 or path[i] == '\'') try out.appendSlice(alloc, path[i..][0..n]);
                i += n;
            }
            try out.append(alloc, '\'');
        },

        // Elvish's single quotes are the same, with only `'` to double.
        .elvish => {
            try out.append(alloc, '\'');
            for (path) |c| {
                try out.append(alloc, c);
                if (c == '\'') try out.append(alloc, '\'');
            }
            try out.append(alloc, '\'');
        },

        // Nushell's single quotes have no escape at all, so a path with
        // one goes in a raw string, `r#'...'#`, with one `#` more on each
        // side than follows any `'` inside. Its double quotes would not
        // do: an escape it does not know, such as the `\U` of `C:\Users`,
        // is a parse error.
        .nushell => if (std.mem.indexOfScalar(u8, path, '\'') == null) {
            try out.append(alloc, '\'');
            try out.appendSlice(alloc, path);
            try out.append(alloc, '\'');
        } else {
            var hashes: usize = 1;
            var it = std.mem.splitScalar(u8, path, '\'');
            _ = it.first();
            while (it.next()) |after| {
                const run = after.len - std.mem.trimStart(u8, after, "#").len;
                hashes = @max(hashes, run + 1);
            }
            try out.append(alloc, 'r');
            try out.appendNTimes(alloc, '#', hashes);
            try out.append(alloc, '\'');
            try out.appendSlice(alloc, path);
            try out.append(alloc, '\'');
            try out.appendNTimes(alloc, '#', hashes);
        },

        // macOS's escaping (`Ghostty.Shell.escape`), not GTK's
        // (`ShellEscapeWriter` in src/os/shell.zig), which leaves `&` and
        // `;` as they are; both are allowed in a Windows name.
        .bash, .zsh, .fish => for (path) |c| {
            if (std.mem.indexOfScalar(u8, "\\ ()[]{}<>\"'`!#$&;|*?\t", c) != null) {
                try out.append(alloc, '\\');
            }
            try out.append(alloc, c);
        },
    }
}

/// `path` in cmd's double quotes.
fn appendDoubleQuoted(alloc: Allocator, out: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    try out.append(alloc, '"');
    try out.appendSlice(alloc, path);
    // A run of backslashes before the closing quote would escape it for a
    // C runtime (CommandLineToArgvW's rule: 2n backslashes and a quote are
    // n backslashes and the quote's end), so the run is doubled: a root
    // that needs quoting (a share's with a space) ends in one. Windows'
    // path parsing reads the doubled separator as one.
    try out.appendNTimes(alloc, '\\', path.len - std.mem.trimEnd(u8, path, "\\").len);
    try out.append(alloc, '"');
}

/// A path that cmd and PowerShell read as one word as it is: letters,
/// digits, `\`, `:`, `.`, `_` and `-` only, as `C:\Users\x`. Left bare
/// for them, as macOS leaves a path that needs no escaping.
fn plain(path: []const u8) bool {
    for (path) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '\\', ':', '.', '_', '-' => {},
        else => return false,
    };
    return path.len != 0;
}

/// The length of the single quote `s` starts with, for PowerShell: `'`,
/// or one of U+2018 to U+201B in UTF-8 (`IsSingleQuote` in PowerShell's
/// CharTraits.cs); null for anything else.
fn powerShellQuote(s: []const u8) ?usize {
    if (s.len >= 1 and s[0] == '\'') return 1;
    if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x80 and s[2] >= 0x98 and s[2] <= 0x9B) return 3;
    return null;
}

/// For tests: a drop of the files `names` as Windows hands one over, in a
/// moveable global block that starts with DROPFILES and holds the names
/// as UTF-16, each ended by a NUL and the list by another. Freed by
/// DragFinish, as the receiver of WM_DROPFILES frees it.
pub fn testDrop(names: []const []const u16) !win32.HDROP {
    if (!builtin.is_test) @compileError("testDrop is for tests");
    var units: usize = 1;
    for (names) |name| units += name.len + 1;
    const bytes = @sizeOf(win32.DROPFILES) + units * @sizeOf(u16);
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse
        return error.TestUnexpectedResult;
    errdefer _ = win32.GlobalFree(mem);
    const raw: [*]u8 = @ptrCast(win32.GlobalLock(mem) orelse return error.TestUnexpectedResult);
    defer _ = win32.GlobalUnlock(mem);

    const head: *align(1) win32.DROPFILES = @ptrCast(raw);
    head.* = .{
        .pFiles = @sizeOf(win32.DROPFILES),
        .pt = .{ .x = 0, .y = 0 },
        .fNC = .FALSE,
        .fWide = .TRUE,
    };
    const list: [*]align(1) u16 = @ptrCast(raw + @sizeOf(win32.DROPFILES));
    var at: usize = 0;
    for (names) |name| {
        for (name) |unit| {
            list[at] = unit;
            at += 1;
        }
        list[at] = 0;
        at += 1;
    }
    list[at] = 0;
    return @ptrCast(mem);
}

fn testQuoted(shell: ?Shell, path: []const u8, want: []const u8) !void {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendQuoted(alloc, &out, shell, path);
    try std.testing.expectEqualStrings(want, out.items);
}

test "win32: a dropped path is quoted for cmd.exe, and always for a shell Ghostty does not know" {
    for ([_]?Shell{ .cmd, null }) |shell| {
        try testQuoted(shell, "C:\\Program Files\\a&b (1).txt", "\"C:\\Program Files\\a&b (1).txt\"");
        try testQuoted(shell, "C:\\it's ’here’ $x %PATH%", "\"C:\\it's ’here’ $x %PATH%\"");
        try testQuoted(shell, "C:\\Users\\Zoë", "\"C:\\Users\\Zoë\"");
        // A root that needs quotes keeps its separator before the closing
        // quote, for a C runtime's argument parsing.
        try testQuoted(shell, "\\\\server\\my share\\", "\"\\\\server\\my share\\\\\"");
    }
    // A path that needs nothing stays bare for cmd, but not for a shell
    // that may be a POSIX one, which would drop its backslashes.
    try testQuoted(.cmd, "C:\\Users\\me\\notes.txt", "C:\\Users\\me\\notes.txt");
    try testQuoted(.cmd, "D:\\", "D:\\");
    try testQuoted(null, "C:\\Users\\me\\notes.txt", "\"C:\\Users\\me\\notes.txt\"");
    try testQuoted(null, "D:\\", "\"D:\\\\\"");
}

test "win32: a drop asks first when a shell Ghostty does not know would expand it" {
    for ([_][]const u8{ "\"C:\\cost $5\"", "\"C:\\a `b`\"", "\"C:\\hi!\"" }) |pasted| {
        try std.testing.expect(asks(null, pasted));
        for ([_]Shell{ .cmd, .powershell, .bash }) |shell| try std.testing.expect(!asks(shell, pasted));
    }
    try std.testing.expect(!asks(null, "\"C:\\a&b (1) %x% ^~@+ ’q’\""));
}

test "win32: a dropped path is quoted for PowerShell, its typographic single quotes doubled too" {
    try testQuoted(.powershell, "C:\\Users\\me\\notes.txt", "C:\\Users\\me\\notes.txt");
    try testQuoted(.powershell, "C:\\Program Files\\a&b $x (1).txt", "'C:\\Program Files\\a&b $x (1).txt'");
    try testQuoted(.powershell, "C:\\it's", "'C:\\it''s'");
    // U+2018, U+2019, U+201A and U+201B each doubled; U+201C is not a
    // single quote.
    try testQuoted(.powershell, "C:\\‘a’ ‚b‛ “c”", "'C:\\‘‘a’’ ‚‚b‛‛ “c”'");
}

test "win32: a dropped path is quoted for elvish and nushell" {
    try testQuoted(.elvish, "C:\\Users\\me", "'C:\\Users\\me'");
    try testQuoted(.elvish, "C:\\it's here", "'C:\\it''s here'");
    try testQuoted(.nushell, "C:\\Users\\me $x", "'C:\\Users\\me $x'");
    // A single quote takes a raw string, with more `#` than follow any
    // single quote inside.
    try testQuoted(.nushell, "C:\\it's", "r#'C:\\it's'#");
    try testQuoted(.nushell, "C:\\a'#b'##", "r###'C:\\a'#b'##'###");
}

test "win32: a dropped path is backslash-escaped for bash, zsh and fish, as macOS escapes it" {
    for ([_]Shell{ .bash, .zsh, .fish }) |shell| {
        try testQuoted(shell, "C:\\Users\\me", "C:\\\\Users\\\\me");
        try testQuoted(
            shell,
            "C:\\a b(1)[2]{3}'`!#$&;",
            "C:\\\\a\\ b\\(1\\)\\[2\\]\\{3\\}\\'\\`\\!\\#\\$\\&\\;",
        );
        try testQuoted(shell, "C:\\%x%_~^ü", "C:\\\\%x%_~^ü");
    }
}

test "win32: a drop's text is each file's quoted path, in order, joined by spaces" {
    const alloc = std.testing.allocator;
    const u = std.unicode.utf8ToUtf16LeStringLiteral;
    const hdrop = try testDrop(&.{ u("C:\\a b.txt"), u("C:\\c.txt"), u("C:\\é") });
    defer win32.DragFinish(hdrop);

    const got = (try text(alloc, .powershell, hdrop)).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("'C:\\a b.txt' C:\\c.txt 'C:\\é'", got);
}

fn testTextFreed(alloc: Allocator, hdrop: win32.HDROP) !void {
    const got = try text(alloc, .powershell, hdrop);
    if (got) |t| alloc.free(t);
}

test "win32: a drop's text frees what it took when memory runs out" {
    const u = std.unicode.utf8ToUtf16LeStringLiteral;
    const hdrop = try testDrop(&.{ u("C:\\a b.txt"), u("C:\\it's"), u("C:\\é") });
    defer win32.DragFinish(hdrop);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testTextFreed, .{hdrop});
}

test "win32: a dropped name that is not valid UTF-16 is left out" {
    const alloc = std.testing.allocator;
    const u = std.unicode.utf8ToUtf16LeStringLiteral;
    // An unpaired high surrogate, which NTFS allows in a name.
    const bad = [_]u16{ 'C', ':', '\\', 0xD800, 'x' };
    {
        const hdrop = try testDrop(&.{ u("C:\\a"), &bad, u("C:\\b") });
        defer win32.DragFinish(hdrop);
        const got = (try text(alloc, .cmd, hdrop)).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("C:\\a C:\\b", got);
    }
    {
        const hdrop = try testDrop(&.{&bad});
        defer win32.DragFinish(hdrop);
        try std.testing.expect(try text(alloc, .cmd, hdrop) == null);
    }
}

test "win32: a drop is quoted for the shell the integration forces, else the one it detects" {
    const alloc = std.testing.allocator;
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    // Neither `command` nor `initial-command`: cmd.exe, as Exec runs.
    try std.testing.expectEqual(.cmd, try shellOf(alloc, &config, true));

    config.command = .{ .shell = "pwsh -NoLogo" };
    try std.testing.expectEqual(.powershell, try shellOf(alloc, &config, false));
    config.command = .{ .direct = &.{ "nu", "-l" } };
    try std.testing.expectEqual(.nushell, try shellOf(alloc, &config, false));
    config.command = .{ .shell = "python" };
    try std.testing.expect(try shellOf(alloc, &config, false) == null);
    config.command = .{ .shell = "python.exe" };
    try std.testing.expect(try shellOf(alloc, &config, false) == null);

    // Any case, with or without `.exe`, as Windows finds a program.
    const names = [_]struct { [:0]const u8, Shell }{
        .{ "bash.exe", .bash },
        .{ "C:\\msys64\\usr\\bin\\zsh.exe", .zsh },
        .{ "Fish", .fish },
        .{ "Nu.EXE", .nushell },
        .{ "elvish.exe", .elvish },
        .{ "CMD.EXE", .cmd },
    };
    for (names) |name| {
        config.command = .{ .direct = &.{name[0]} };
        try std.testing.expectEqual(name[1], try shellOf(alloc, &config, false));
    }
    config.command = .{ .shell = "python" };

    // `initial-command` only for the app's first terminal.
    config.@"initial-command" = .{ .shell = "powershell.exe" };
    try std.testing.expectEqual(.powershell, try shellOf(alloc, &config, true));
    try std.testing.expect(try shellOf(alloc, &config, false) == null);

    // Detected without the integration too; forced over the detection.
    config.@"shell-integration" = .none;
    try std.testing.expectEqual(.powershell, try shellOf(alloc, &config, true));
    config.@"shell-integration" = .fish;
    try std.testing.expectEqual(.fish, try shellOf(alloc, &config, true));
}
