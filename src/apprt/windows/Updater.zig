//! Update checks against the releases the build names: `check_for_updates`
//! and `auto-update`. A check runs on a thread of its own, as the HTTP
//! calls block (http.zig), and posts its job back to the message window
//! when done, where the app joins the thread and reports what it found.
//!
//! One check runs at a time. A manual check while an automatic one runs
//! makes that one manual: it reports even that there is no update, or
//! that it failed, where an automatic one reports only an update.
//!
//! `auto-update` is off unless set, as it is opt-in on this platform:
//! `check` looks once shortly after start and then daily; `download`
//! also fetches the package before reporting, so that installing it
//! needs no wait.

const Updater = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const http = @import("http.zig");
const update_feed = @import("update_feed.zig");
const win32 = @import("win32.zig");
const dialog = @import("dialog.zig");
const About = @import("About.zig");
const IpcClient = @import("IpcClient.zig");
const i18n = internal_os.i18n;
const App = @import("App.zig").App;
const icon_resource_id = @import("App.zig").icon_resource_id;
const openLink = @import("App.zig").openLink;

const log = std.log.scoped(.win32);

/// Where the feed is, and what its URLs must be under.
pub const Source = struct {
    /// Ends in "/releases/" (`update_feed.parse`).
    releases: []const u8,
    feed: []const u8,
    /// Both true but in tests, whose server is on a loopback port.
    https_only: bool = true,
    system_proxy: bool = true,

    const repo_releases = "https://github.com/Pyre909/ghostty/releases/";
    const feed_name = "ghostty-windows-update.json";

    /// The channel's feed: the latest release's for stable, the rolling
    /// tip release's for tip.
    pub fn of(channel: build_config.ReleaseChannel) Source {
        return .{
            .releases = repo_releases,
            .feed = switch (channel) {
                .stable => repo_releases ++ "latest/download/" ++ feed_name,
                .tip => repo_releases ++ "download/tip-windows/" ++ feed_name,
            },
        };
    }
};

/// The message window's timer for automatic checks.
pub const timer_id: win32.UINT_PTR = 4;
/// The first automatic check, after start or once `auto-update` is set:
/// not at once, so as not to slow the first window.
const first_delay_ms = 10 * std.time.ms_per_s;
const interval_ms = 24 * std.time.ms_per_hour;

/// The feed is small; the cap only bounds a broken or hostile one.
const max_feed = 1024 * 1024;
const max_package = 512 * 1024 * 1024;

pub const Result = union(enum) {
    /// The feed's version is not newer than this build's.
    current,
    /// Its slices are the job's.
    update: struct {
        found: update_feed.Update,
        /// The package's saved path, if it was downloaded.
        path: ?[:0]const u16,
    },
    failed: anyerror,
    /// The package installed, of this version: Ghostty takes it up once
    /// restarted.
    installed: []const u8,
    /// msiexec's exit code, other than success and the user's cancel.
    install_failed: u32,
    /// The user cancelled the install in msiexec's own window.
    install_cancelled,

    /// Whether to tell the user of it: an update, and what came of
    /// installing one, always; that there is none, or that the check
    /// failed, only when asked for (`manual`); a cancel never, as the
    /// user made it.
    pub fn tells(self: Result, manual: bool) bool {
        return switch (self) {
            .update, .installed, .install_failed => true,
            .current, .failed => manual,
            .install_cancelled => false,
        };
    }
};

/// An update to install: its package downloaded first if `path` is null.
/// Its slices are the job's.
const Install = struct {
    version: []const u8,
    url: []const u8,
    sha256: [32]u8,
    path: ?[:0]const u16,
};

/// One check, owned by its thread until posted back, then by the UI
/// thread. Everything it holds is in `arena`, so that a job posted when
/// no window is left to take it can be dropped whole.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    hwnd: win32.HWND,
    msg: win32.UINT,
    source: Source,
    /// The directory a package is saved in, or null not to download.
    dir: ?[]const u16,
    /// UI thread only: whether to report every outcome.
    manual: bool,
    /// Install this rather than check.
    install: ?Install = null,
    result: Result = .{ .failed = error.NotRun },

    fn run(job: *Job) void {
        job.result = if (job.install) |install|
            job.installPackage(install) catch |err| .{ .failed = err }
        else
            job.check() catch |err| .{ .failed = err };
        if (!win32.PostMessageW(job.hwnd, job.msg, 0, @bitCast(@intFromPtr(job))).toBool()) {
            // No window to take it: the app is gone, and so is whoever
            // would join this thread.
            log.warn("update check result not posted err={}", .{win32.GetLastError()});
            job.arena.deinit();
        }
    }

    fn check(job: *Job) !Result {
        const arena = job.arena.allocator();
        const arch = update_feed.Arch.native() orelse return error.NoPackage;
        const session = try http.Session.open(.{
            .https_only = job.source.https_only,
            .system_proxy = job.source.system_proxy,
        });
        defer session.close();
        const body = try session.get(arena, job.source.feed, max_feed);
        const found = try update_feed.parse(arena, body, build_config.version_string, arch, job.source.releases) orelse
            return .current;
        const dir = job.dir orelse return .{ .update = .{ .found = found, .path = null } };
        // The package's own name, already checked to be a plain one.
        const name = std.fs.path.basenamePosix(found.url);
        const wide_name = try std.unicode.utf8ToUtf16LeAlloc(arena, name);
        const path = try std.mem.concatWithSentinel(arena, u16, &.{ dir, wide_name }, 0);
        try session.download(arena, found.url, path, max_package, found.sha256);
        return .{ .update = .{ .found = found, .path = path } };
    }

    fn installPackage(job: *Job, install: Install) !Result {
        const path = install.path orelse path: {
            const dir = job.dir orelse return error.NoPackageDir;
            const session = try http.Session.open(.{
                .https_only = job.source.https_only,
                .system_proxy = job.source.system_proxy,
            });
            defer session.close();
            const arena = job.arena.allocator();
            const name = std.fs.path.basenamePosix(install.url);
            const wide_name = try std.unicode.utf8ToUtf16LeAlloc(arena, name);
            const path = try std.mem.concatWithSentinel(arena, u16, &.{ dir, wide_name }, 0);
            try session.download(arena, install.url, path, max_package, install.sha256);
            break :path path;
        };
        return switch (try msiexec(job.arena.allocator(), path)) {
            // ERROR_SUCCESS, ERROR_SUCCESS_REBOOT_REQUIRED: a file in use
            // is replaced at the next start of Windows, which this
            // Ghostty, still running, does not need.
            0, 3010 => .{ .installed = install.version },
            // ERROR_INSTALL_USEREXIT
            1602 => .install_cancelled,
            else => |code| .{ .install_failed = code },
        };
    }
};

/// Install the package at `path` as the user would from Explorer, with
/// msiexec's progress window and no restart of Windows, and wait for it:
/// its exit code. A running Ghostty is not closed (the package sets
/// MSIRESTARTMANAGERCONTROL to DisableShutdown); the files it holds
/// open are replaced as Windows Installer replaces any file in use.
fn msiexec(arena: Allocator, path: [:0]const u16) !u32 {
    if (builtin.is_test) {
        const run = test_msiexec orelse @panic("a test would run msiexec");
        return run(path);
    }
    var system: [win32.MAX_PATH + 1]u16 = undefined;
    const n = win32.GetSystemDirectoryW(&system, system.len);
    if (n == 0 or n >= system.len) return error.SystemDirectory;
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const image = try std.mem.concatWithSentinel(arena, u16, &.{ system[0..n], W("\\msiexec.exe") }, 0);
    // A path holds no quote, so quotes alone keep its spaces.
    const line = try std.mem.concatWithSentinel(arena, u16, &.{
        W("\""), image, W("\" /i \""), path, W("\" /passive /norestart"),
    }, 0);
    var si = std.mem.zeroes(win32.STARTUPINFOW);
    si.cb = @sizeOf(win32.STARTUPINFOW);
    var pi: win32.PROCESS_INFORMATION = undefined;
    if (!win32.CreateProcessW(image.ptr, line.ptr, null, null, .FALSE, 0, null, null, &si, &pi).toBool()) {
        log.warn("msiexec not started err={}", .{win32.GetLastError()});
        return error.MsiexecNotStarted;
    }
    defer _ = win32.CloseHandle(pi.hProcess);
    _ = win32.CloseHandle(pi.hThread);
    _ = win32.WaitForSingleObject(pi.hProcess, win32.INFINITE);
    var code: win32.DWORD = 0;
    if (!win32.GetExitCodeProcess(pi.hProcess, &code).toBool()) {
        log.warn("msiexec's exit code not read err={}", .{win32.GetLastError()});
        return error.MsiexecNotStarted;
    }
    return code;
}

hwnd: win32.HWND,
msg: win32.UINT,
source: Source,
mode: configpkg.Config.AutoUpdate = .off,
running: ?*Job = null,
/// Armed on `hwnd` as `timer_id`.
armed: bool = false,
/// Whether this Ghostty is the package's (`isInstalledCopy`), which an
/// update can replace; else it is only offered on its release page.
installed: bool = false,

/// Follow `auto-update`: arm the first check if it was off, disarm it if
/// it is now off. A change of channel takes a restart, as the docs say.
pub fn configure(self: *Updater, mode: ?configpkg.Config.AutoUpdate) void {
    self.mode = mode orelse .off;
    if (self.mode == .off) {
        if (self.armed) _ = win32.KillTimer(self.hwnd, timer_id);
        self.armed = false;
    } else if (!self.armed) {
        self.arm(first_delay_ms);
    }
}

fn arm(self: *Updater, ms: win32.UINT) void {
    if (win32.SetTimer(self.hwnd, timer_id, ms, null) == 0) {
        log.warn("automatic update check not scheduled err={}", .{win32.GetLastError()});
        self.armed = false;
        return;
    }
    self.armed = true;
}

/// The timer's WM_TIMER: check, and look again a day later.
pub fn timerFired(self: *Updater) void {
    if (!self.armed) return; // a WM_TIMER queued before KillTimer
    self.arm(interval_ms);
    self.start(false);
}

/// Start a check, or make the running one `manual`.
pub fn start(self: *Updater, manual: bool) void {
    if (self.running) |job| {
        job.manual = job.manual or manual;
        return;
    }
    self.spawn(manual, null) catch |err| {
        log.warn("update check not started err={}", .{err});
    };
}

fn spawn(self: *Updater, manual: bool, install: ?Install) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var moved = false;
    errdefer if (!moved) arena.deinit();
    const a = arena.allocator();
    const job = try a.create(Job);
    const download = self.mode == .download or (install != null and install.?.path == null);
    const dir = if (download) try packageDir(a) else null;
    // The install's slices, the UI thread's, copied into the job's own.
    const owned: ?Install = if (install) |i| .{
        .version = try a.dupe(u8, i.version),
        .url = try a.dupe(u8, i.url),
        .sha256 = i.sha256,
        .path = if (i.path) |path| try a.dupeSentinel(u16, path, 0) else null,
    } else null;
    // The arena's state moves into the job before the thread starts, the
    // only allocator either uses from here on.
    job.* = .{
        .arena = arena,
        .hwnd = self.hwnd,
        .msg = self.msg,
        .source = self.source,
        .dir = dir,
        .manual = manual,
        .install = owned,
    };
    moved = true;
    job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
        release(job);
        return err;
    };
    self.running = job;
}

/// The message the job posted: join its thread; the caller reports the
/// result and then `release`s it.
pub fn finished(self: *Updater, lparam: win32.LPARAM) *Job {
    const job: *Job = @ptrFromInt(@as(usize, @bitCast(lparam)));
    std.debug.assert(self.running == job);
    job.thread.join();
    self.running = null;
    return job;
}

pub fn release(job: *Job) void {
    var arena = job.arena;
    arena.deinit();
}

/// At exit: the running check, if any, is left to finish on its own.
/// Its post then fails, as the message window is gone, and it frees
/// itself (`Job.run`).
pub fn deinit(self: *Updater) void {
    if (self.armed) _ = win32.KillTimer(self.hwnd, timer_id);
    if (self.running) |job| job.thread.detach();
    self.running = null;
}

fn packageDir(arena: Allocator) ![]const u16 {
    if (builtin.is_test) if (test_package_dir) |dir| return dir;
    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const path = try internal_os.xdg.cache(io, arena, &environ_map, .{ .subdir = "ghostty/updates" });
    if (!std.fs.path.isAbsolute(path)) return error.CacheDirNotAbsolute;
    try std.Io.Dir.cwd().createDirPath(io, path);
    const wide = try std.unicode.utf8ToUtf16LeAlloc(arena, path);
    return std.mem.concat(arena, u16, &.{ wide, &.{'\\'} });
}

/// Tell the user what `job` found, which the app queued only if there is
/// something to tell (`Result.tells`): an update is offered (`offer`),
/// the rest told in a message box. In a prompt outside any core frame,
/// as About is (`About.showQueued`).
pub fn report(app: *App, job: *const Job) void {
    if (app.quit or app.terminating) return;
    const alloc = app.core_app.alloc;
    const text: [:0]const u8 = switch (job.result) {
        .update => |update| return offer(app, update.found, update.path),
        .current => alloc.dupeSentinel(u8, "Ghostty is up to date.", 0) catch return oom(),
        .failed => |err| std.fmt.allocPrintSentinel(
            alloc,
            "Ghostty could not check for updates ({s}).",
            .{@errorName(err)},
            0,
        ) catch return oom(),
        .installed => |version| std.fmt.allocPrintSentinel(
            alloc,
            "Ghostty {s} is installed. Restart Ghostty to use it.",
            .{version},
            0,
        ) catch return oom(),
        .install_failed => |code| std.fmt.allocPrintSentinel(
            alloc,
            "Ghostty's update was not installed (msiexec exit code {d}).",
            .{code},
            0,
        ) catch return oom(),
        // Never queued (`Result.tells`).
        .install_cancelled => unreachable,
    };
    defer alloc.free(text);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return oom();
    defer alloc.free(wide);

    const owner = app.promptOwner(null);
    app.beginUnframedPrompt(owner);
    defer app.endPrompt();
    const icon: win32.UINT = switch (job.result) {
        .failed, .install_failed => win32.MB_ICONWARNING,
        else => win32.MB_ICONINFORMATION,
    };
    _ = dialog.box(owner, win32.L("Ghostty"), wide.ptr, win32.MB_OK, icon);
}

/// The offer's buttons, besides Later (IDCANCEL).
pub const install_id: c_int = 100;
pub const release_page_id: c_int = 101;

/// Offer `found`: Install where this Ghostty is the package's
/// (`installed`), else Open Release Page, as a zip or a build of one's
/// own is not the package's to replace; and Later. The release notes are
/// a link in the dialog. `path` is the package, if already downloaded.
fn offer(app: *App, found: update_feed.Update, path: ?[:0]const u16) void {
    const alloc = app.core_app.alloc;
    const installable = app.updater.installed;
    const available = std.fmt.allocPrint(alloc, "Ghostty {s} is available. You have {s}.", .{
        found.version,
        build_config.version_string,
    }) catch return oom();
    defer alloc.free(available);

    const owner = app.promptOwner(null);
    app.beginUnframedPrompt(owner);
    defer app.endPrompt();
    const chosen = ask(app, owner, available, found.notes, installable) orelse return oom();
    switch (chosen) {
        install_id => app.updater.startInstall(found, path),
        release_page_id => openPage(found.notes orelse app.updater.source.releases),
        else => {},
    }
}

/// The offer's dialog: the button chosen, or null without the memory for
/// it. A task dialog, or a message box without TaskDialogIndirect or if
/// that fails, as About's.
fn ask(app: *App, owner: ?win32.HWND, available: []const u8, notes: ?[]const u8, installable: bool) ?c_int {
    const alloc = app.core_app.alloc;
    const action = if (installable) install_id else release_page_id;
    if (About.taskDialog()) |task_dialog| task: {
        const content = if (notes) |url|
            std.fmt.allocPrint(alloc, "{s}\n\n<a href=\"{s}\">Release notes</a>", .{ available, url }) catch return null
        else
            alloc.dupe(u8, available) catch return null;
        defer alloc.free(content);
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, content) catch return null;
        defer alloc.free(wide);
        const notes_wide = if (notes) |url| std.unicode.utf8ToUtf16LeAlloc(alloc, url) catch return null else null;
        defer if (notes_wide) |w| alloc.free(w);
        const link: Link = .{ .url = notes orelse "", .wide = notes_wide orelse &.{} };
        const buttons = [_]About.TASKDIALOG_BUTTON{
            .{ .nButtonID = action, .pszButtonText = if (installable) win32.L("Install") else win32.L("Open Release Page") },
            .{ .nButtonID = win32.IDCANCEL, .pszButtonText = win32.L("Later") },
        };
        const config: About.TASKDIALOGCONFIG = .{
            .cbSize = @sizeOf(About.TASKDIALOGCONFIG),
            .hwndParent = owner,
            .hInstance = app.hinstance,
            .dwFlags = About.TDF_ENABLE_HYPERLINKS | About.TDF_ALLOW_DIALOG_CANCELLATION |
                About.TDF_POSITION_RELATIVE_TO_WINDOW |
                if (i18n.windows.rightToLeft()) About.TDF_RTL_LAYOUT else 0,
            .pszWindowTitle = win32.L("Ghostty"),
            .main_icon = .{ .pszMainIcon = @ptrFromInt(icon_resource_id) },
            .pszMainInstruction = win32.L("An update is available"),
            .pszContent = wide.ptr,
            .cButtons = buttons.len,
            .pButtons = &buttons,
            .nDefaultButton = action,
            .pfCallback = linkClicked,
            .lpCallbackData = @bitCast(@intFromPtr(&link)),
        };
        var button: c_int = 0;
        const hr = task_dialog(&config, &button, null, null);
        if (hr < 0) {
            log.warn("TaskDialogIndirect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            break :task;
        }
        return button;
    }
    const question = std.fmt.allocPrintSentinel(alloc, "{s}\n\n{s}", .{
        available,
        if (installable) "Install it now?" else "Open its release page?",
    }, 0) catch return null;
    defer alloc.free(question);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, question) catch return null;
    defer alloc.free(wide);
    const answer = dialog.box(owner, win32.L("Ghostty"), wide.ptr, win32.MB_YESNO, win32.MB_ICONINFORMATION);
    return if (answer == win32.IDYES) action else win32.IDCANCEL;
}

/// The offer's link, for `linkClicked`: the release notes' URL.
const Link = struct {
    url: []const u8,
    wide: []const u16,
};

/// The offer's link opened in the browser: only the release notes', the
/// feed's URL checked to be under the releases page (`update_feed`).
fn linkClicked(
    _: ?win32.HWND,
    msg: win32.UINT,
    _: win32.WPARAM,
    lparam: win32.LPARAM,
    data: isize,
) callconv(.winapi) win32.HRESULT {
    if (msg != About.TDN_HYPERLINK_CLICKED) return win32.S_OK;
    const link: *const Link = @ptrFromInt(@as(usize, @bitCast(data)));
    const href = std.mem.span(@as([*:0]const u16, @ptrFromInt(@as(usize, @bitCast(lparam)))));
    if (link.wide.len > 0 and std.mem.eql(u16, href, link.wide)) {
        openPage(link.url);
    } else {
        log.warn("the update dialog's link is not the release notes' len={}", .{href.len});
    }
    return win32.S_OK;
}

fn openPage(url: []const u8) void {
    if (builtin.is_test) {
        // A copy: `url` is the job's, freed once the report is done.
        const n = @min(url.len, test_opened_buf.len);
        @memcpy(test_opened_buf[0..n], url[0..n]);
        test_opened = test_opened_buf[0..n];
        return;
    }
    // A link of our own, not a program's, so `.html` rather than one of
    // the untrusted kinds, as About's.
    _ = openLink(.html, url); // logs its own failures
}

/// Install `found` (`Job.installPackage`), downloading it first unless
/// `path` has it, and tell what came of it. Not while a check runs, which
/// the user then sees end on its own.
pub fn startInstall(self: *Updater, found: update_feed.Update, path: ?[:0]const u16) void {
    if (self.running != null) {
        log.warn("update not installed: a check is running", .{});
        return;
    }
    self.spawn(true, .{ .version = found.version, .url = found.url, .sha256 = found.sha256, .path = path }) catch |err| {
        log.warn("update install not started err={}", .{err});
    };
}

/// Whether this process's image is the package's: ghostty.exe in its
/// fixed folder, %LOCALAPPDATA%\Programs\Ghostty\bin (dist/windows/
/// make_msi.py). Compared without case, as the file system does, by
/// CompareStringOrdinal.
pub fn isInstalledCopy(alloc: Allocator) bool {
    const image = IpcClient.imagePath(alloc) catch return false;
    defer alloc.free(image);
    var environ_map = global.environMap() catch return false;
    defer environ_map.deinit();
    const local = environ_map.get("LOCALAPPDATA") orelse return false;
    const want = std.fmt.allocPrint(alloc, "{s}\\Programs\\Ghostty\\bin\\ghostty.exe", .{local}) catch return false;
    defer alloc.free(want);
    const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, want) catch return false;
    defer alloc.free(wide);
    return win32.CompareStringOrdinal(image.ptr, @intCast(image.len), wide.ptr, @intCast(wide.len), .TRUE) == win32.CSTR_EQUAL;
}

fn oom() void {
    log.warn("update check result not shown err={}", .{error.OutOfMemory});
}

/// For tests: a source no check gets an answer from, the discard port.
pub const test_source: Source = .{
    .releases = "http://127.0.0.1:9/owner/repo/releases/",
    .feed = "http://127.0.0.1:9/owner/repo/releases/feed.json",
    .https_only = false,
    .system_proxy = false,
};

/// For tests: where `download` saves a package, ending in a separator,
/// in place of the cache directory.
pub var test_package_dir: if (builtin.is_test) ?[]const u16 else void =
    if (builtin.is_test) null else {};

/// For tests: stands for msiexec, given the package's path, on the
/// job's thread; its answer is the exit code.
pub var test_msiexec: if (builtin.is_test) ?*const fn ([:0]const u16) u32 else void =
    if (builtin.is_test) null else {};

/// For tests: the page last opened (`openPage`), in place of the browser.
pub var test_opened: if (builtin.is_test) ?[]const u8 else void =
    if (builtin.is_test) null else {};
var test_opened_buf: if (builtin.is_test) [256]u8 else void = undefined;

/// For tests, at cleanup: wait for the running check, and drop it with
/// the message it posted, so that none reaches a later test's window.
pub fn testDrop(self: *Updater) void {
    if (self.armed) _ = win32.KillTimer(self.hwnd, timer_id);
    self.armed = false;
    const job = self.running orelse return;
    self.running = null;
    job.thread.join();
    var posted: win32.MSG = undefined;
    while (win32.PeekMessageW(&posted, self.hwnd, self.msg, self.msg, win32.PM_REMOVE).toBool()) {}
    release(job);
}
