//! The working directory a shell reports on Windows, as the path a new
//! terminal starts in (the `*-inherit-working-directory` options) and the
//! core resolves relative paths against.
//!
//! The OSC parser gives OSC 7 and ConEmu's OSC 9;9 the same command
//! (`report_pwd`), so `StreamHandler.reportPwd` hands either form here:
//!
//! - OSC 7, a URL whose host is this machine, as on other platforms:
//!   `file://host/C:/Users/me%20too` (percent-encoded) or
//!   `kitty-shell-cwd://host/C:/Users/me too` (raw). The path's slash
//!   before the drive letter is dropped (RFC 8089, appendix E.2).
//! - OSC 9;9, a bare Windows path, `C:\Users\me`, or quoted as ConEmu
//!   documents it, `"C:\Users\me"`, or the extended-length `\\?\C:\...`.
//!   A share's path (`\\server\share`) comes this way: under the host
//!   check, OSC 7 has no form for one (RFC 8089's appendix E.3 puts the
//!   server in the host, or leaves the host empty). cmd's `$P` at a
//!   drive's root gives `C:\`.
//!
//! The result is an absolute Windows path with backslashes, a drive's
//! (`C:\...`) or, from OSC 9;9, a share's on this machine. Refused:
//!
//! - a path that does not say where a new terminal should start: a
//!   drive-relative `C:foo`, one from the current drive's root (`\foo`),
//!   or a POSIX one, such as a WSL shell's `/home/me` or MSYS2's
//!   `file://host/c/Users` (`/c/` is MSYS2's mount, not a drive);
//! - a share on another server. OSC 9;9 has no host, so any program's
//!   output can send one, and opening it, as a new terminal's directory
//!   or to resolve a Ctrl+clicked path, connects to that server as the
//!   user, sending their credentials (NTLM), and blocks until it answers.
//!   WSL's shares, which WSL shells send (`wslpath -w`), and this
//!   machine's are taken (`isLocalServer`); a share mapped to a drive
//!   letter is a drive's path. `cygpath -m`'s `//server/share`, with
//!   slashes, is refused whatever the server (`invalid_url`);
//! - a device path, `\\.\pipe\x` or `\\?\GLOBALROOT\...`;
//! - a name no directory can have (`validName`), which std's `access`,
//!   called on the path by `Exec` and `Surface.resolvePathForOpening`,
//!   panics on in a Debug build.
//!
//! A drive's or a share's path is not checked to exist here: that would
//! take the file system on every prompt. A new terminal's directory is
//! checked by the Windows runtime, which takes the configured one instead
//! if it is not a directory (`inheritWorkingDirectory` in
//! src/apprt/windows/Surface.zig). OSC 9;9 has no host, so a remote shell
//! can choose where a new terminal starts, as it can in ConEmu and
//! Windows Terminal. `std.Io.net.HostName` refuses an OSC 7 host with an
//! `_`, so a machine named so is reached through OSC 9;9 only.
//!
//! Pure, so that its tests also run off Windows.
const std = @import("std");
const Allocator = std.mem.Allocator;
const uri = @import("../os/uri.zig");

/// Why a reported value gives no working directory.
pub const Refusal = enum {
    /// Neither a Windows path nor a URL.
    invalid_url,

    /// A URL whose scheme is neither `file` nor `kitty-shell-cwd`.
    scheme,

    /// A URL without a host, which OSC 7 requires, as on other platforms.
    missing_host,

    /// A URL whose host is not a valid host name.
    invalid_host,

    /// A URL's host or a share's server other than this machine: another
    /// machine's directory.
    remote_host,

    /// Neither a drive's nor (from OSC 9;9) a share's absolute path.
    not_absolute,

    /// A device's path from OSC 9;9: `\\.\...`, or `\\?\...` other than
    /// a drive's or a share's.
    device,

    /// A path no directory can have (`validName`).
    invalid_name,
};

pub const Result = union(enum) {
    /// An absolute Windows path, owned by the caller and allocated with the
    /// allocator given to `parse`.
    path: []u8,

    refused: Refusal,
};

/// Whether a URL's host or a share's server names this machine
/// (`os.hostname.isLocal` on Windows; a stand-in in tests).
pub const IsLocal = *const fn (host: []const u8) bool;

/// The working directory `value` reports, an OSC 7 URL or an OSC 9;9 path.
pub fn parse(alloc: Allocator, value: []const u8, isLocal: IsLocal) Allocator.Error!Result {
    // A bare path first: `C:/Users` would otherwise parse as a URL whose
    // scheme is `C`. A drive letter or a backslash never starts a URL we
    // take, so a value that starts with either is a path or nothing.
    const unquoted = unquote(value);
    if (bare(unquoted)) |path| {
        switch (path.kind) {
            .drive => {},
            .share => |server| if (!isLocalServer(server, isLocal))
                return .{ .refused = .remote_host },
            .device => return .{ .refused = .device },
        }
        return checked(alloc, unquoted, path.name);
    }
    if ((unquoted.len >= 2 and isDrive(unquoted[0..2])) or
        (unquoted.len >= 1 and unquoted[0] == '\\'))
        return .{ .refused = .not_absolute };

    const url = uri.parse(value, .{
        .mac_address = true,
        .raw_path = std.mem.startsWith(u8, value, "kitty-shell-cwd://"),
    }) catch return .{ .refused = .invalid_url };
    if (!std.mem.eql(u8, "file", url.scheme) and
        !std.mem.eql(u8, "kitty-shell-cwd", url.scheme))
        return .{ .refused = .scheme };

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Io.net.HostName.fromUri(url, &host_buffer) catch |err|
        return .{ .refused = switch (err) {
            error.UriMissingHost => .missing_host,
            error.NameTooLong, error.InvalidHostName => .invalid_host,
        } };
    if (!isLocal(host.bytes)) return .{ .refused = .remote_host };

    // Decoded for `file` (`%20` is a space); `kitty-shell-cwd`'s is raw.
    const raw = try alloc.print("{f}", .{std.fmt.alt(url.path, .formatRaw)});
    defer alloc.free(raw);

    // "/C:/Users", or "/C:" for the drive's root.
    if (raw.len >= 3 and raw[0] == '/' and isDrive(raw[1..3]) and
        (raw.len == 3 or isSeparator(raw[3])))
        return checked(alloc, raw[1..], raw[3..]);
    return .{ .refused = .not_absolute };
}

/// `value` without the double quotes ConEmu's OSC 9;9 puts around it.
fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        return value[1 .. value.len - 1];
    return value;
}

/// An absolute Windows path, by how it starts.
const Bare = struct {
    kind: union(enum) {
        /// `C:\...` (or `C:/...`), or `\\?\C:\...`.
        drive,
        /// `\\server\share...` or `\\?\UNC\server\share...`: the server.
        share: []const u8,
        /// `\\.\...`, or another `\\?\...`.
        device,
    },

    /// What follows the drive's colon, the `\\` or the `\\?\UNC\`, for
    /// `validName`.
    name: []const u8,
};

/// How `value` starts if it is an absolute Windows path, as
/// `std.fs.path.getWin32PathType` tells them apart; null if it is not
/// one.
fn bare(value: []const u8) ?Bare {
    if (value.len >= 3 and isDrive(value[0..2]) and isSeparator(value[2]))
        return .{ .kind = .drive, .name = value[2..] };
    if (!std.mem.startsWith(u8, value, "\\\\")) return null;
    if (value.len >= 3 and (value[2] == '.' or value[2] == '?') and
        (value.len == 3 or isSeparator(value[3])))
    {
        // The Win32 device namespace (`\\.\`) or a verbatim path (`\\?\`),
        // whose separators are backslashes only.
        const rest = value[@min(value.len, 4)..];
        if (value[2] == '?') {
            if (rest.len >= 3 and isDrive(rest[0..2]) and rest[2] == '\\')
                return .{ .kind = .drive, .name = rest[2..] };
            if (rest.len >= 4 and std.ascii.eqlIgnoreCase(rest[0..4], "UNC\\"))
                return share(rest[4..]);
        }
        return .{ .kind = .device, .name = rest };
    }
    return share(value[2..]);
}

/// The share `rest`, `server\share...` after a `\\` or a `\\?\UNC\`, names;
/// null if it names a server only.
fn share(rest: []const u8) ?Bare {
    const end = std.mem.indexOfAny(u8, rest, "\\/") orelse return null;
    if (end == 0 or end + 1 == rest.len or isSeparator(rest[end + 1])) return null;
    return .{ .kind = .{ .share = rest[0..end] }, .name = rest };
}

/// Whether a share's server is this machine: WSL's (`wsl.localhost`, and
/// `wsl$`, its name before Windows 11), or a name `isLocal` takes, such as
/// `localhost`. An address (`127.0.0.1`) is not taken.
fn isLocalServer(server: []const u8, isLocal: IsLocal) bool {
    return std.ascii.eqlIgnoreCase(server, "wsl.localhost") or
        std.ascii.eqlIgnoreCase(server, "wsl$") or
        isLocal(server);
}

/// `path` as a working directory, unless `name`, the part of it after its
/// drive's colon or its `\\`, holds what no directory's name can.
fn checked(alloc: Allocator, path: []const u8, name: []const u8) Allocator.Error!Result {
    if (!validName(name)) return .{ .refused = .invalid_name };
    return .{ .path = try windowsPath(alloc, path) };
}

/// Whether every component of `name` could name a directory, by Windows'
/// rules (https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file):
/// UTF-8, no control character, none of `< > : " | ? *` (past the drive,
/// a `:` names a stream), at most 255 UTF-16 code units, and not a
/// device's reserved name (`isDeviceName`).
///
/// On Windows 11 (ARM64), std's `access` panicked in a Debug build
/// (`statusBug`, STATUS_OBJECT_NAME_INVALID) on each of `< > " | ? *`,
/// U+0001, a bad stream (`C:\a:b:c`), a 256-unit component and `NUL`.
/// DEL and the C1 controls (U+0080 to U+009F), which a name can hold, are
/// refused too: the path is also the title while no program sets one.
fn validName(name: []const u8) bool {
    var components = std.mem.splitAny(u8, name, "\\/");
    while (components.next()) |component| {
        if (isDeviceName(component)) return false;
        // Also refuses what is not UTF-8, an encoded surrogate included.
        const units = std.unicode.calcUtf16LeLen(component) catch return false;
        if (units > 255) return false;
        var it = std.unicode.Utf8View.initUnchecked(component).iterator();
        while (it.nextCodepoint()) |cp| switch (cp) {
            0x00...0x1F, 0x7F...0x9F => return false,
            '<', '>', ':', '"', '|', '?', '*' => return false,
            else => {},
        };
    }
    return true;
}

/// Whether `component` is a name Windows reserves for a device (the page
/// `validName` cites): CON, PRN, AUX, NUL, COM0 to COM9, LPT0 to LPT9 and
/// COM¹²³, LPT¹²³, in any case, alone or before an extension (`NUL.txt`),
/// and with spaces after it.
fn isDeviceName(component: []const u8) bool {
    const stem = std.mem.trimEnd(
        u8,
        component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len],
        " ",
    );
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    if (stem.len < 4) return false;
    if (!std.ascii.eqlIgnoreCase(stem[0..3], "COM") and
        !std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) return false;
    const n = stem[3..];
    return (n.len == 1 and std.ascii.isDigit(n[0])) or
        std.mem.eql(u8, n, "¹") or std.mem.eql(u8, n, "²") or std.mem.eql(u8, n, "³");
}

/// A drive's letter and colon.
fn isDrive(s: []const u8) bool {
    return std.ascii.isAlphabetic(s[0]) and s[1] == ':';
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

/// `path` (a drive's or a share's) with backslashes, and a drive alone
/// (`C:`, which would mean the drive's current directory) as its root.
fn windowsPath(alloc: Allocator, path: []const u8) Allocator.Error![]u8 {
    const result = if (path.len == 2)
        try std.mem.concat(alloc, u8, &.{ path, "\\" })
    else
        try alloc.dupe(u8, path);
    std.mem.replaceScalar(u8, result, '/', '\\');
    return result;
}

const testing = std.testing;

fn localIsMe(host: []const u8) bool {
    return std.mem.eql(u8, host, "ME") or std.mem.eql(u8, host, "localhost");
}

fn expectPath(expected: []const u8, value: []const u8) !void {
    const result = try parse(testing.allocator, value, &localIsMe);
    switch (result) {
        .path => |path| {
            defer testing.allocator.free(path);
            try testing.expectEqualStrings(expected, path);
        },
        .refused => |why| {
            std.debug.print("{s}: refused ({t}), expected {s}\n", .{ value, why, expected });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectRefused(expected: Refusal, value: []const u8) !void {
    const result = try parse(testing.allocator, value, &localIsMe);
    switch (result) {
        .path => |path| {
            defer testing.allocator.free(path);
            std.debug.print("{s}: gave {s}, expected refused ({t})\n", .{ value, path, expected });
            return error.TestUnexpectedResult;
        },
        .refused => |why| try testing.expectEqual(expected, why),
    }
}

test "windows pwd: OSC 7 file URLs on this machine give the drive's path" {
    try expectPath("C:\\Windows", "file://ME/C:/Windows");
    try expectPath("C:\\Users\\me\\a b", "file://ME/C:/Users/me/a%20b");
    try expectPath("d:\\x\\y\\", "file://localhost/d:/x/y/");
    // The drive's root, with and without the slash after the colon.
    try expectPath("C:\\", "file://ME/C:/");
    try expectPath("C:\\", "file://ME/C:");
    // Percent-encoded slashes and colons decode before the drive is found.
    try expectPath("C:\\a\\b", "file://ME/C%3A%2Fa/b");
}

test "windows pwd: kitty-shell-cwd URLs keep their raw path" {
    try expectPath("C:\\Users\\me\\a b", "kitty-shell-cwd://ME/C:/Users/me/a b");
    try expectPath("C:\\100%20", "kitty-shell-cwd://ME/C:/100%20");
    try expectPath("C:\\a#b", "kitty-shell-cwd://ME/C:/a#b");
    // Kept raw, so a '?' is the path's, which no name can hold.
    try expectRefused(.invalid_name, "kitty-shell-cwd://ME/C:/a?b");
}

test "windows pwd: OSC 9;9 paths, bare and quoted" {
    try expectPath("C:\\Users\\me", "C:\\Users\\me");
    try expectPath("C:\\Users\\me two", "\"C:\\Users\\me two\"");
    // cmd's $P at a drive's root.
    try expectPath("C:\\", "C:\\");
    try expectPath("C:\\Users\\me", "C:/Users/me");
    // The extended-length form, and its drive's root.
    try expectPath("\\\\?\\C:\\very\\long", "\\\\?\\C:\\very\\long");
    try expectPath("\\\\?\\C:\\", "\\\\?\\C:\\");
}

test "windows pwd: a share is taken only on this machine or WSL's" {
    // WSL's, as `wslpath -w` writes it, and as Windows 10 named it.
    try expectPath("\\\\wsl.localhost\\Ubuntu\\home\\me", "\\\\wsl.localhost\\Ubuntu\\home\\me");
    try expectPath("\\\\WSL$\\Ubuntu", "\"\\\\WSL$\\Ubuntu\"");
    // This machine's, by a name `isLocal` takes, and its long form.
    try expectPath("\\\\ME\\share\\dir", "\\\\ME\\share\\dir");
    try expectPath("\\\\localhost\\c$\\Windows", "\\\\localhost\\c$\\Windows");
    try expectPath("\\\\?\\unc\\ME\\share", "\\\\?\\unc\\ME\\share");
    // Another server's, however it is written: opening it would send the
    // user's credentials there.
    try expectRefused(.remote_host, "\\\\server\\share\\dir");
    try expectRefused(.remote_host, "\"\\\\server\\share\"");
    try expectRefused(.remote_host, "\\\\server/share");
    try expectRefused(.remote_host, "\\\\attacker@SSL\\x");
    try expectRefused(.remote_host, "\\\\127.0.0.1\\c$");
    try expectRefused(.remote_host, "\\\\?\\UNC\\server\\share");
    // A server with no share.
    try expectRefused(.not_absolute, "\\\\ME");
    try expectRefused(.not_absolute, "\\\\ME\\");
    try expectRefused(.not_absolute, "\\\\?\\UNC\\ME");
}

test "windows pwd: device paths are refused" {
    try expectRefused(.device, "\\\\.\\pipe\\x");
    try expectRefused(.device, "\\\\.\\C:\\Windows");
    try expectRefused(.device, "\\\\?\\GLOBALROOT\\Device\\Null");
    // A verbatim drive without its root is the volume, and a verbatim
    // path takes no forward slash.
    try expectRefused(.device, "\\\\?\\C:");
    try expectRefused(.device, "\\\\?\\C:/Windows");
    try expectRefused(.device, "\\\\?\\");
    try expectRefused(.device, "\\\\.");
}

test "windows pwd: names no directory can have are refused" {
    // Each of these made std's Windows `access` panic in a Debug build.
    for ([_][]const u8{ "C:\\a|b", "C:\\a*b", "C:\\a?b", "C:\\a<b", "C:\\a>b", "\"C:\\a\"b\"", "C:\\a:b:c", "C:\\x\\NUL", "C:\\x\\nUl..", "C:\\x\\NUL ", "\\\\?\\C:\\a|b", "\\\\ME\\share\\a|b" }) |value| {
        try expectRefused(.invalid_name, value);
    }
    try expectRefused(.invalid_name, "C:\\" ++ &@as([256]u8, @splat('a')));
    // Percent-decoded: a '|', a control character, NUL, DEL, a C1
    // control, and bytes that are not UTF-8.
    for ([_][]const u8{ "%7C", "%01", "%00", "%7F", "%C2%85", "%FF", "%ED%A0%80" }) |escaped| {
        var buf: [64]u8 = undefined;
        try expectRefused(.invalid_name, try std.fmt.bufPrint(&buf, "file://localhost/C:/a{s}b", .{escaped}));
    }
    try expectRefused(.invalid_name, "C:\\a\xffb");
    // A stream, and the other reserved names, which `access` only failed.
    for ([_][]const u8{ "C:\\a:b", "C:\\x\\NUL.txt", "C:\\x\\com1", "C:\\x\\LPT²", "C:\\x\\AUX.tar.gz\\y", "C:\\x\\CON" }) |value| {
        try expectRefused(.invalid_name, value);
    }
    // What a name can hold: 255 units, a name a device's starts, a
    // device's name inside a longer one, and a bidi control (the palette
    // escapes it as it draws).
    try expectPath("C:\\" ++ &@as([255]u8, @splat('a')), "C:\\" ++ &@as([255]u8, @splat('a')));
    for ([_][]const u8{ "C:\\x\\NULL", "C:\\x\\COM10", "C:\\x\\CONSOLE", "C:\\x\\a.NUL", "C:\\a\u{202E}b", "C:\\a#b%c" }) |value| {
        try expectPath(value, value);
    }
}

test "windows pwd: another machine's directory is refused" {
    try expectRefused(.remote_host, "file://OTHER/C:/Windows");
    try expectRefused(.remote_host, "kitty-shell-cwd://OTHER/C:/Windows");
    // RFC 8089's share form puts the server in the host.
    try expectRefused(.remote_host, "file://server/share/dir");
    try expectRefused(.missing_host, "file:///C:/Windows");
    try expectRefused(.invalid_host, "file://bad_host/C:/Windows");
}

test "windows pwd: paths that do not say where to start are refused" {
    // A drive-relative path, a drive alone (its current directory), the
    // current drive's root, and a share's prefix with nothing after it.
    try expectRefused(.not_absolute, "C:Windows");
    try expectRefused(.not_absolute, "C:");
    try expectRefused(.not_absolute, "\"C:\"");
    try expectRefused(.not_absolute, "\\Windows");
    try expectRefused(.not_absolute, "\\\\");
    try expectRefused(.not_absolute, "\\\\\\x");
    try expectRefused(.invalid_url, "\"\"");
    try expectRefused(.invalid_url, "Windows");
    // A POSIX path, from a WSL shell on this machine, MSYS2's drive
    // mount, and a share after the host.
    try expectRefused(.not_absolute, "file://ME/home/me");
    try expectRefused(.not_absolute, "file://ME/c/Users/me");
    try expectRefused(.not_absolute, "file://ME//server/share");
    try expectRefused(.not_absolute, "file://ME/C");
    // A drive letter's colon must be followed by a separator or nothing.
    try expectRefused(.not_absolute, "file://ME/C:x");
    try expectRefused(.scheme, "https://ME/C:/Windows");
    // `cygpath -m`'s share.
    try expectRefused(.invalid_url, "//server/share");
}

test "windows pwd: OSC 7 and OSC 9;9 bytes give report_pwd these values" {
    // A stand-in for StreamHandler: what terminal.Stream hands
    // `report_pwd`, which `StreamHandler.reportPwd` passes to `parse`.
    const terminal = @import("../terminal/main.zig");
    const H = struct {
        values: [8][64]u8 = undefined,
        lens: [8]usize = @splat(0),
        count: usize = 0,

        pub fn deinit(_: *@This()) void {}

        pub fn vt(
            self: *@This(),
            comptime action: terminal.StreamAction.Tag,
            value: terminal.StreamAction.Value(action),
        ) void {
            switch (action) {
                .report_pwd => {
                    @memcpy(self.values[self.count][0..value.url.len], value.url);
                    self.lens[self.count] = value.url.len;
                    self.count += 1;
                },
                else => {},
            }
        }
    };

    var s: terminal.Stream(H) = .init(.{ .handler = .{} });
    defer s.deinit();
    // cmd's prompt at a drive's root ends the path in a backslash right
    // before ST (as `PROMPT=...$E]9;9;$P$E\...` writes it), PowerShell's
    // is quoted, and OSC 7 ends in BEL.
    s.nextSlice("\x1b]9;9;C:\\\x1b\\" ++
        "\x1b]9;9;\"C:\\Users\\me two\"\x07" ++
        "\x1b]7;file://ME/C:/Users/me%20two\x07");
    try testing.expectEqual(3, s.handler.count);
    const expected = [_][]const u8{ "C:\\", "C:\\Users\\me two", "C:\\Users\\me two" };
    for (expected, 0..) |want, i| {
        try expectPath(want, s.handler.values[i][0..s.handler.lens[i]]);
    }
}
