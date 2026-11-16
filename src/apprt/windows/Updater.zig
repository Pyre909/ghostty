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
const App = @import("App.zig").App;

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
    result: Result = .{ .failed = error.NotRun },

    fn run(job: *Job) void {
        job.result = job.check() catch |err| .{ .failed = err };
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
};

hwnd: win32.HWND,
msg: win32.UINT,
source: Source,
mode: configpkg.Config.AutoUpdate = .off,
running: ?*Job = null,
/// Armed on `hwnd` as `timer_id`.
armed: bool = false,

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
    self.spawn(manual) catch |err| {
        log.warn("update check not started err={}", .{err});
    };
}

fn spawn(self: *Updater, manual: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const job = arena.allocator().create(Job) catch |err| {
        arena.deinit();
        return err;
    };
    const dir = if (self.mode == .download) packageDir(arena.allocator()) catch |err| {
        arena.deinit();
        return err;
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
    };
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
/// something to tell (`App.updateFinished`): an update, whatever the
/// check; for a manual one also that there is none, or that it failed.
/// In a prompt outside any core frame, as About is (`About.showQueued`).
pub fn report(app: *App, job: *const Job) void {
    if (app.quit or app.terminating) return;
    const alloc = app.core_app.alloc;
    const text: [:0]const u8 = switch (job.result) {
        .update => |update| std.fmt.allocPrintSentinel(
            alloc,
            "Ghostty {s} is available. You have {s}.",
            .{ update.found.version, build_config.version_string },
            0,
        ) catch return oom(),
        .current => alloc.dupeSentinel(u8, "Ghostty is up to date.", 0) catch return oom(),
        .failed => |err| std.fmt.allocPrintSentinel(
            alloc,
            "Ghostty could not check for updates ({s}).",
            .{@errorName(err)},
            0,
        ) catch return oom(),
    };
    defer alloc.free(text);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return oom();
    defer alloc.free(wide);

    const owner = app.promptOwner(null);
    app.beginUnframedPrompt(owner);
    defer app.endPrompt();
    const icon: win32.UINT = if (job.result == .failed) win32.MB_ICONWARNING else win32.MB_ICONINFORMATION;
    _ = dialog.box(owner, win32.L("Ghostty"), wide.ptr, win32.MB_OK, icon);
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
