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

    /// The channel's feed, each at a rolling release of its own (not
    /// GitHub's latest, which is whatever release was made last, of
    /// anything the repository publishes); the packages it names are on
    /// their own release's tag (dist/windows/make_feed.py).
    pub fn of(channel: build_config.ReleaseChannel) Source {
        return .{
            .releases = repo_releases,
            .feed = switch (channel) {
                .stable => repo_releases ++ "download/stable-windows/" ++ feed_name,
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
/// The next try of an automatic check the app was busy for.
const busy_retry_ms = std.time.ms_per_min;

/// How long a job waits to post its result again after a post failed.
const repost_ms = if (builtin.is_test) 10 else 1000;

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
    /// The check failed.
    failed: anyerror,
    /// The install failed before msiexec ran: its package not downloaded,
    /// or msiexec not started.
    install_error: anyerror,
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
            .update, .installed, .install_failed, .install_error => true,
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

/// One check, owned by the UI thread from `spawn` until it `release`s it
/// or abandons it at exit (`deinit`); its thread only fills in `result`
/// and posts it back. Everything it holds is in `arena`, so that an
/// abandoned job can drop itself whole.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    /// Set by the UI thread at exit, read by the job's thread when its post
    /// fails: only then is the job its thread's to free.
    state: std.atomic.Value(State) = .init(.owned),
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

    const State = enum(u8) { owned, abandoned };

    fn run(job: *Job) void {
        job.result = if (job.install) |install|
            job.installPackage(install) catch |err| .{ .install_error = err }
        else
            job.check() catch |err| .{ .failed = err };
        // A post fails when the UI thread's queue is full, as well as once
        // the message window is gone: only in the second case, which
        // `deinit` marks, is no one left to take the job.
        while (!job.post()) {
            if (job.state.load(.acquire) == .abandoned) {
                log.warn("update check result not posted err={}", .{win32.GetLastError()});
                job.arena.deinit();
                return;
            }
            win32.Sleep(repost_ms);
        }
    }

    fn post(job: *Job) bool {
        if (builtin.is_test and test_post_failures.load(.monotonic) > 0) {
            _ = test_post_failures.fetchSub(1, .monotonic);
            return false;
        }
        return win32.PostMessageW(job.hwnd, job.msg, 0, @bitCast(@intFromPtr(job))).toBool();
    }

    fn check(job: *Job) !Result {
        const arena = job.arena.allocator();
        const arch = update_feed.Arch.native() orelse return error.NoPackage;
        const session = try job.openSession();
        defer session.close();
        const body = try session.get(arena, job.source.feed, max_feed);
        const found = try update_feed.parse(arena, body, build_config.version_string, arch, job.source.releases) orelse
            return .current;
        const dir = job.dir orelse return .{ .update = .{ .found = found, .path = null } };
        const path = try packagePath(arena, dir, found.url);
        prune(arena, dir, path);
        // One saved by an earlier check of this release is kept, if it
        // is still the package.
        const file = http.openVerified(path, max_package, found.sha256) orelse
            (downloadVerified(arena, session, found.url, path, found.sha256) catch |err| {
                // Offered all the same: Install downloads it again, and
                // tells if that fails too.
                log.warn("update package not downloaded err={}", .{err});
                return .{ .update = .{ .found = found, .path = null } };
            });
        _ = win32.CloseHandle(file);
        return .{ .update = .{ .found = found, .path = path } };
    }

    fn installPackage(job: *Job, install: Install) !Result {
        const arena = job.arena.allocator();
        const dir = job.dir orelse return error.NoPackageDir;
        const path = install.path orelse try packagePath(arena, dir, install.url);
        // The package is checked again, as anything could have changed
        // it since its check, and held open, read-only to everyone, until
        // msiexec is done: what it installs is what was checked.
        const file = http.openVerified(path, max_package, install.sha256) orelse file: {
            const session = try job.openSession();
            defer session.close();
            prune(arena, dir, path);
            break :file try downloadVerified(arena, session, install.url, path, install.sha256);
        };
        defer _ = win32.CloseHandle(file);
        return switch (try msiexec(arena, path)) {
            // ERROR_SUCCESS, ERROR_SUCCESS_REBOOT_REQUIRED: a file in use
            // is replaced at the next start of Windows, which this
            // Ghostty, still running, does not need.
            0, 3010 => .{ .installed = install.version },
            // ERROR_INSTALL_USEREXIT
            1602 => .install_cancelled,
            else => |code| .{ .install_failed = code },
        };
    }

    fn openSession(job: *const Job) http.Error!http.Session {
        return http.Session.open(.{
            .https_only = job.source.https_only,
            .system_proxy = job.source.system_proxy,
        });
    }
};

/// Where the package at `url` is saved in `dir`: under its own name,
/// which the feed's parser checked to be a plain one.
fn packagePath(arena: Allocator, dir: []const u16, url: []const u8) ![:0]u16 {
    const name = std.fs.path.basenamePosix(url);
    const wide_name = try std.unicode.utf8ToUtf16LeAlloc(arena, name);
    return std.mem.concatWithSentinel(arena, u16, &.{ dir, wide_name }, 0);
}

/// Download the package to `path`, and open it as `http.openVerified`
/// does: it is checked once saved and again once opened.
fn downloadVerified(
    arena: Allocator,
    session: http.Session,
    url: []const u8,
    path: [:0]const u16,
    sha256: [32]u8,
) !win32.HANDLE {
    try session.download(arena, url, path, max_package, sha256);
    return http.openVerified(path, max_package, sha256) orelse error.HashMismatch;
}

/// Delete the packages in `dir` other than `keep`, and the part files
/// downloads left there: only the latest package is kept. One in use (a
/// download of another Ghostty, a package msiexec reads) is left.
fn prune(arena: Allocator, dir: []const u16, keep: [:0]const u16) void {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    for ([_][]const u16{ W(package_glob), W("*" ++ http.part_suffix) }) |glob| {
        const pattern = std.mem.concatWithSentinel(arena, u16, &.{ dir, glob }, 0) catch return;
        var data: win32.WIN32_FIND_DATAW = undefined;
        const find = win32.FindFirstFileW(pattern, &data);
        if (find == win32.INVALID_HANDLE_VALUE) continue;
        defer _ = win32.FindClose(find);
        while (true) {
            const name = std.mem.sliceTo(&data.cFileName, 0);
            // A wildcard also matches a file's 8.3 short name ("*.msi"
            // matches "a.msix" as A~1.MSI), so the name is checked again.
            if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0 and
                (isPackageName(name) or std.mem.endsWith(u16, name, W(http.part_suffix))))
            {
                const path = std.mem.concatWithSentinel(arena, u16, &.{ dir, name }, 0) catch return;
                if (!std.os.windows.eqlIgnoreCaseWtf16(path, keep)) _ = win32.DeleteFileW(path);
            }
            if (!win32.FindNextFileW(find, &data).toBool()) break;
        }
    }
}

/// The packages' names (dist/windows/make_msi.py): this, wildcards and all.
const package_glob = "ghostty-*-windows-*.msi";

fn isPackageName(name: []const u16) bool {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    return std.mem.startsWith(u16, name, W("ghostty-")) and
        std.mem.indexOf(u16, name, W("-windows-")) != null and
        std.mem.endsWith(u16, name, W(".msi"));
}

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

/// The timer's WM_TIMER: check, and look again a day later. Not while
/// the app is `busy` (a prompt open, whose loop dispatches this; or
/// quitting): then it tries again shortly. A check started under the
/// offer's dialog would be running when the user chose Install.
pub fn timerFired(self: *Updater, busy: bool) void {
    if (!self.armed) return; // a WM_TIMER queued before KillTimer
    if (busy) return self.arm(busy_retry_ms);
    self.arm(interval_ms);
    _ = self.start(false); // automatic: a failure is not told
}

/// No more automatic checks: at exit, before anything that runs a
/// message loop.
pub fn disarm(self: *Updater) void {
    if (self.armed) _ = win32.KillTimer(self.hwnd, timer_id);
    self.armed = false;
}

/// Start a check, or make the running one `manual`. A manual one that
/// could not start is returned, failed, for the app to tell as any other
/// (`App.tellUpdate`).
pub fn start(self: *Updater, manual: bool) ?*Job {
    if (self.running) |job| {
        job.manual = job.manual or manual;
        return null;
    }
    self.spawn(manual, null) catch |err| {
        log.warn("update check not started err={}", .{err});
        if (manual) return self.failedJob(.{ .failed = err });
    };
    return null;
}

/// A job that never ran, with `result`, to be told as a finished one is;
/// null without the memory for it.
fn failedJob(self: *Updater, result: Result) ?*Job {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const job = arena.allocator().create(Job) catch {
        arena.deinit();
        oom();
        return null;
    };
    job.* = .{
        .arena = arena,
        .hwnd = self.hwnd,
        .msg = self.msg,
        .source = self.source,
        .dir = null,
        .manual = true,
        .result = result,
    };
    return job;
}

fn spawn(self: *Updater, manual: bool, install: ?Install) !void {
    if (builtin.is_test and test_spawn_fails) return error.SystemResources;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var moved = false;
    errdefer if (!moved) arena.deinit();
    const a = arena.allocator();
    const job = try a.create(Job);
    // A package is downloaded ahead only where Install is offered
    // (`installed`); an install always wants the directory, to prune and
    // to download to again if its package changed. Without it a check
    // goes on, and an install tells why it failed (`error.NoPackageDir`).
    const wants_dir = install != null or (self.mode == .download and self.installed);
    const dir = if (!wants_dir) null else packageDir(a) catch |err| dir: {
        log.warn("update directory not found err={}", .{err});
        break :dir null;
    };
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

/// The message a job posted: join its thread, and the job is the
/// caller's to report and then `release`. Null for a message that is not
/// the running job's, which any process on the desktop could post: its
/// LPARAM is only compared, never followed.
pub fn finished(self: *Updater, lparam: win32.LPARAM) ?*Job {
    const job = self.running orelse return null;
    if (@intFromPtr(job) != @as(usize, @bitCast(lparam))) {
        log.warn("update message not the running check's", .{});
        return null;
    }
    job.thread.join();
    self.running = null;
    return job;
}

/// Free a job `finished` returned, and everything it holds: `job` is
/// invalid afterwards. (`deinit` takes the arena by value, so nothing is
/// read from the job once its memory is freed.)
pub fn release(job: *Job) void {
    job.arena.deinit();
}

/// At exit: the running check, if any, is abandoned to finish on its own.
/// If it ends before the message window is destroyed, its post succeeds
/// but is never dispatched, and its arena goes with the process; after
/// that its post fails and it frees itself (`Job.run`).
pub fn deinit(self: *Updater) void {
    self.disarm();
    if (self.running) |job| {
        // Read before the store: from then on the job may free itself.
        const thread = job.thread;
        job.state.store(.abandoned, .release);
        thread.detach();
    }
    self.running = null;
}

/// %LOCALAPPDATA%\ghostty\updates\, made if need be: the user's own,
/// as the installed Ghostty is, and found from the known folder rather
/// than the environment, which an inherited variable could point
/// anywhere.
fn packageDir(arena: Allocator) ![]const u16 {
    if (builtin.is_test) if (test_package_dir) |dir| return if (dir.len == 0) error.PackageDir else dir;
    var local: ?[*:0]u16 = null;
    defer win32.CoTaskMemFree(local);
    if (win32.SHGetKnownFolderPath(&win32.FOLDERID_LocalAppData, 0, null, &local) < 0)
        return error.LocalAppData;
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const ghostty = try std.mem.concatWithSentinel(arena, u16, &.{ std.mem.span(local.?), W("\\ghostty") }, 0);
    try makeDir(ghostty);
    const updates = try std.mem.concatWithSentinel(arena, u16, &.{ ghostty, W("\\updates") }, 0);
    try makeDir(updates);
    return std.mem.concat(arena, u16, &.{ updates, W("\\") });
}

fn makeDir(path: [:0]const u16) !void {
    if (win32.CreateDirectoryW(path, null).toBool()) return;
    if (win32.GetLastError() == .ALREADY_EXISTS) return;
    log.warn("update directory not made err={}", .{win32.GetLastError()});
    return error.PackageDir;
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
        .install_error => |err| std.fmt.allocPrintSentinel(
            alloc,
            "Ghostty's update could not be installed ({s}).",
            .{@errorName(err)},
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
        // Not once the app quits under the dialog: the install would be
        // cut off at exit.
        install_id => if (!app.quit and !app.terminating) {
            if (app.updater.startInstall(found, path)) |job| app.tellUpdate(job);
        },
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
/// `path` has it, and tell what came of it. Not while a check runs: only
/// a manual one can have started under the offer (a global keybind's;
/// the timer waits out prompts, `timerFired`), which the user then sees
/// end, offering the update again if it finds one. One that could not
/// start is returned, failed, as `start` returns a check.
pub fn startInstall(self: *Updater, found: update_feed.Update, path: ?[:0]const u16) ?*Job {
    if (self.running != null) {
        log.warn("update not installed: a check is running", .{});
        return null;
    }
    self.spawn(true, .{ .version = found.version, .url = found.url, .sha256 = found.sha256, .path = path }) catch |err| {
        log.warn("update install not started err={}", .{err});
        return self.failedJob(.{ .install_error = err });
    };
    return null;
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

/// For tests: where a package is saved, ending in a separator, in place
/// of the user's; empty, the directory cannot be made.
pub var test_package_dir: if (builtin.is_test) ?[]const u16 else void =
    if (builtin.is_test) null else {};

/// For tests: stands for msiexec, given the package's path, on the
/// job's thread; its answer is the exit code.
pub var test_msiexec: if (builtin.is_test) ?*const fn ([:0]const u16) u32 else void =
    if (builtin.is_test) null else {};

/// For tests: whether a job's thread fails to start.
pub var test_spawn_fails = false;

/// For tests: how many of the next posts of a job's result fail, as
/// they would with the UI thread's queue full.
pub var test_post_failures: std.atomic.Value(u32) = .init(0);

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
