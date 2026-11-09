//! Local crash dumps for the Windows app. When the process dies of an
//! exception or a panic it writes a minidump to the crash directory, beside
//! the Sentry envelopes other platforms write there, and
//! `ghostty +crash-report` lists it. Nothing is sent anywhere.
//!
//! Sentry does not build for Windows, so this is the Windows app's crash
//! capture. How a Zig program dies on Windows decides where it hooks in:
//!
//!   - Debug and ReleaseSafe install Zig's segfault handler, a vectored
//!     exception handler that prints a trace and exits for four exception
//!     codes (see `isZigFatal`), before any unhandled-exception filter could
//!     run. A vectored handler added ahead of it remembers the exception;
//!     Zig's handler then calls `handleSegfault`, which dumps. Dumping there
//!     rather than in our own handler means a handler between the two that
//!     resumes the thread leaves no dump of a crash that did not happen.
//!   - ReleaseFast has no such handler, so an exception reaches the
//!     unhandled-exception filter.
//!   - A panic exits without raising an exception, in every mode; the root
//!     panic handler dumps first.
//!
//! A thread that exists only for that writes the dump, as Microsoft's
//! MiniDumpWriteDump documentation advises: the crashing thread's stack may
//! be exhausted (a stack overflow) or corrupt. The crashing thread hands
//! over its exception record and context and waits, for at most
//! `Dumper.timeout_ms`, which also bounds a deadlock inside the dump (for
//! example on the loader lock).
//!
//! Fast fail (`__fastfail`, /GS checks, heap corruption) runs no handler in
//! the process, so none of this sees it. WER's LocalDumps can capture those;
//! see dist/windows/README.txt.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
const crash = @import("main.zig");

const os_windows = internal_os.windows;
const kernel32 = os_windows.exp.kernel32;
const log = std.log.scoped(.crash);

/// How many of our dumps the crash directory keeps. Older ones are deleted
/// when the app starts, so a crash briefly makes it one more.
pub const keep = 10;

/// The exception codes of dumps made without an exception. Both are
/// customer codes (bit 29 set): "GH" and a letter.
pub const panic_code: u32 = 0xE047_4850; // 'P'
pub const test_code: u32 = 0xE047_4852; // 'R', see crashTest

/// The dump by default: every thread's stack and registers, the module
/// list (with the PDB identity a debugger needs), unloaded modules and
/// handles. No other memory: the heap and data sections hold scrollback,
/// which can hold anything that was typed or printed.
const small_type: u32 = MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpWithHandleData;

/// With GHOSTTY_CRASH_DUMP=full: all of the process's memory, as asked.
const full_type: u32 = small_type | MiniDumpWithFullMemory | MiniDumpWithFullMemoryInfo;

// --- Windows declarations ------------------------------------------------

/// EXCEPTION_RECORD as Windows declares it. std's makes the chained record
/// a non-optional pointer, and a panic's record has none.
pub const ExceptionRecord = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: ?*ExceptionRecord,
    ExceptionAddress: ?*anyopaque,
    NumberParameters: u32,
    ExceptionInformation: [15]usize,
};

pub const ExceptionPointers = extern struct {
    ExceptionRecord: *ExceptionRecord,
    ContextRecord: *windows.CONTEXT,
};

comptime {
    // The handlers @ptrCast std's EXCEPTION_POINTERS to these.
    assert(@sizeOf(ExceptionRecord) == @sizeOf(windows.EXCEPTION_RECORD));
    assert(@sizeOf(ExceptionPointers) == @sizeOf(windows.EXCEPTION_POINTERS));
}

const EXCEPTION_NONCONTINUABLE = 0x1;

// dbghelp declares the minidump structures inside #pragma pack(4)
// (minidumpapiset.h; mingw-w64's psdk_inc/_dbg_common.h). On a 64-bit
// target a pointer after a 4-byte field is therefore at offset 4, not 8,
// and a natural Zig layout would hand MiniDumpWriteDump garbage.
const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: u32,
    ExceptionPointers: *const ExceptionPointers align(4),
    ClientPointers: windows.BOOL,
};

const MINIDUMP_USER_STREAM = extern struct {
    Type: u32,
    BufferSize: u32,
    Buffer: ?*const anyopaque align(4),
};

const MINIDUMP_USER_STREAM_INFORMATION = extern struct {
    UserStreamCount: u32,
    UserStreamArray: [*]const MINIDUMP_USER_STREAM align(4),
};

comptime {
    if (@sizeOf(usize) == 8) {
        assert(@offsetOf(MINIDUMP_EXCEPTION_INFORMATION, "ExceptionPointers") == 4);
        assert(@sizeOf(MINIDUMP_EXCEPTION_INFORMATION) == 16);
        assert(@offsetOf(MINIDUMP_USER_STREAM, "Buffer") == 8);
        assert(@sizeOf(MINIDUMP_USER_STREAM) == 16);
        assert(@offsetOf(MINIDUMP_USER_STREAM_INFORMATION, "UserStreamArray") == 4);
        assert(@sizeOf(MINIDUMP_USER_STREAM_INFORMATION) == 12);
    }
}

// MINIDUMP_TYPE (minidumpapiset.h).
const MiniDumpWithFullMemory = 0x2;
const MiniDumpWithHandleData = 0x4;
const MiniDumpWithUnloadedModules = 0x20;
const MiniDumpWithFullMemoryInfo = 0x800;
const MiniDumpWithThreadInfo = 0x1000;

// MINIDUMP_STREAM_TYPE. The dumper writes the comment itself; the tests
// read the others.
const ThreadListStream = 3;
const ModuleListStream = 4;
const ExceptionStream = 6;
/// Text a debugger shows with the dump (cdb prints it as "Comment:").
const CommentStreamA = 10;

const MiniDumpWriteDumpFn = *const fn (
    process: windows.HANDLE,
    process_id: u32,
    file: windows.HANDLE,
    dump_type: u32,
    exception: ?*const MINIDUMP_EXCEPTION_INFORMATION,
    user_streams: ?*const MINIDUMP_USER_STREAM_INFORMATION,
    callback: ?*const anyopaque,
) callconv(.winapi) windows.BOOL;

// --- The dumper ----------------------------------------------------------

pub const Kind = enum { exception, panic };

/// Writes dumps on its own thread. Everything a dump needs is allocated
/// here up front: nothing on the crash path allocates, takes a lock or
/// formats on the crashing thread.
pub const Dumper = struct {
    write: MiniDumpWriteDumpFn,
    dump_type: u32,

    /// How long a crashing thread waits for its dump before dying anyway.
    timeout_ms: u32 = 10_000,

    /// The crash directory, `\\?\`-prefixed, and a separator, UTF-16,
    /// then room for a name.
    path: [windows.PATH_MAX_WIDE + 1]u16 = undefined,
    dir_len: usize = 0,

    /// Auto-reset: a dump is asked for. Manual-reset: it is written.
    request: windows.HANDLE,
    done: windows.HANDLE,
    thread: std.Thread,
    thread_id: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    /// The thread whose crash is being dumped, 0 for none. The first one
    /// wins; a dump is written once per process.
    crasher: std.atomic.Value(u32) = .init(0),

    // The request, written by the crashing thread before `request` is set.
    // The record and context are copies: the crashing thread's own may be
    // gone before they are read, once it has given up waiting.
    record: ExceptionRecord = undefined,
    context: windows.CONTEXT = undefined,
    kind: Kind = .exception,
    thread_type: []const u8 = "",
    message: [512]u8 = undefined,
    message_len: usize = 0,

    // The result, written by the dumper before `done` is set.
    result: Result = .none,
    comment: [768]u8 = undefined,

    comptime {
        // commentText's part before the message always fits.
        assert(build_config.version_string.len <= 256);
    }

    pub const Result = union(enum) {
        none,
        /// The name written, within `path`.
        written: [:0]const u16,
        /// CreateFileW or MiniDumpWriteDump failed with this error.
        failed: windows.Win32Error,
    };

    const thread_name = "crash-dump";

    /// `dir` is the crash directory, which must exist and be absolute.
    /// The dumper is not movable once started: its thread holds a pointer
    /// to it.
    pub fn start(self: *Dumper, io: std.Io, dir: []const u8, dump_type: u32) !void {
        const write = try loadMiniDumpWriteDump();
        const request = kernel32.CreateEventW(null, .FALSE, .FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = kernel32.CloseHandle(request);
        const done = kernel32.CreateEventW(null, .TRUE, .FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = kernel32.CloseHandle(done);

        self.* = .{
            .write = write,
            .dump_type = dump_type,
            .request = request,
            .done = done,
            .thread = undefined,
        };
        // CreateFileW takes a path longer than MAX_PATH only with the
        // `\\?\` prefix. The conversion std's own file functions use
        // (so that this accepts the directories they do) makes the NT form
        // of it, `\??\`: the same path but for its second character.
        const nt = try std.Io.Threaded.sliceToPrefixedFileW(null, dir, .{ .allow_relative = false });
        var n = nt.len;
        if (!std.mem.startsWith(u16, nt.span(), &.{ '\\', '?', '?', '\\' })) return error.BadPathName;
        if (n + 1 + max_name_len + 1 > self.path.len) return error.NameTooLong;
        @memcpy(self.path[0..n], nt.span());
        self.path[1] = '\\';
        if (self.path[n - 1] != '\\') {
            self.path[n] = '\\';
            n += 1;
        }
        self.dir_len = n;

        // MiniDumpWriteDump's own stack use is modest; a megabyte leaves
        // room for the system's stack walking.
        self.thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{self});
        // The name is in every dump: its thread list holds this thread too.
        self.thread.setName(io, thread_name) catch {};
    }

    /// Stops the thread and closes the events. Tests only: the app's dumper
    /// lives as long as the process.
    pub fn stop(self: *Dumper) void {
        self.stopping.store(true, .release);
        _ = kernel32.SetEvent(self.request);
        self.thread.join();
        _ = kernel32.CloseHandle(self.request);
        _ = kernel32.CloseHandle(self.done);
    }

    /// Asks for a dump of the calling thread's crash and waits for it.
    /// The exception is copied: `pointers` need last only for the call.
    /// Returns at once when another thread's dump is under way (after
    /// waiting for it, so that this thread does not end the process
    /// before it is written), or when this thread is the dumper or is
    /// already dumping (a crash while dumping).
    pub fn dump(
        self: *Dumper,
        pointers: *const ExceptionPointers,
        kind: Kind,
        message: []const u8,
    ) Result {
        const me = windows.GetCurrentThreadId();
        if (me == self.thread_id.load(.acquire)) return .none;
        if (self.crasher.cmpxchgStrong(0, me, .acq_rel, .acquire)) |other| {
            if (other != me) _ = kernel32.WaitForSingleObject(self.done, self.timeout_ms);
            return .none;
        }

        self.record = pointers.ExceptionRecord.*;
        self.context = pointers.ContextRecord.*;
        self.kind = kind;
        // The thread's role, which only this thread can read.
        self.thread_type = if (crash.sentry.thread_state) |s| @tagName(s.type) else "other";
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);

        _ = kernel32.SetEvent(self.request);
        return switch (kernel32.WaitForSingleObject(self.done, self.timeout_ms)) {
            os_windows.WAIT_OBJECT_0 => self.result,
            else => .none,
        };
    }

    fn run(self: *Dumper) void {
        self.thread_id.store(windows.GetCurrentThreadId(), .release);
        while (true) {
            _ = kernel32.WaitForSingleObject(self.request, os_windows.INFINITE);
            if (self.stopping.load(.acquire)) return;
            self.result = self.writeDump();
            _ = kernel32.SetEvent(self.done);
        }
    }

    fn writeDump(self: *Dumper) Result {
        const name = self.fileName();
        const file = kernel32.CreateFileW(
            name.ptr,
            os_windows.GENERIC_WRITE | os_windows.DELETE,
            0,
            null,
            os_windows.CREATE_NEW,
            os_windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (file == os_windows.INVALID_HANDLE_VALUE) return .{ .failed = windows.GetLastError() };

        // Marked for deletion until the dump is whole: a partial dump is
        // no use to a debugger. The process can end while this is under
        // way, since the crashing thread waits only so long, and nothing
        // here would run then. But the system closes a dead process's
        // handles, and closing this one removes a file still marked.
        const marked = deleteOnClose(file, true);

        const pointers: ExceptionPointers = .{
            .ExceptionRecord = &self.record,
            .ContextRecord = &self.context,
        };
        const info: MINIDUMP_EXCEPTION_INFORMATION = .{
            .ThreadId = self.crasher.load(.acquire),
            .ExceptionPointers = &pointers,
            .ClientPointers = .FALSE,
        };
        const comment = self.commentText();
        const stream: MINIDUMP_USER_STREAM = .{
            .Type = CommentStreamA,
            .BufferSize = @intCast(comment.len + 1), // with its NUL
            .Buffer = comment.ptr,
        };
        const streams: MINIDUMP_USER_STREAM_INFORMATION = .{
            .UserStreamCount = 1,
            .UserStreamArray = @ptrCast(&stream),
        };
        var ok = self.write(
            windows.GetCurrentProcess(),
            windows.GetCurrentProcessId(),
            file,
            self.dump_type,
            &info,
            &streams,
            null,
        ) != .FALSE;
        var err = windows.GetLastError();
        if (ok and marked and !deleteOnClose(file, false)) {
            ok = false;
            err = windows.GetLastError();
        }
        _ = kernel32.CloseHandle(file);
        if (!ok) {
            // Closing it removed a marked file.
            if (!marked) _ = kernel32.DeleteFileW(name.ptr);
            return .{ .failed = err };
        }
        return .{ .written = name[self.dir_len..] };
    }

    /// Sets or clears the file's delete disposition. While it is set,
    /// closing the last handle to the file deletes it.
    fn deleteOnClose(file: windows.HANDLE, delete: bool) bool {
        var info: os_windows.FILE_DISPOSITION_INFORMATION = .{
            .DeleteFile = if (delete) .TRUE else .FALSE,
        };
        return kernel32.SetFileInformationByHandle(
            file,
            .FileDispositionInfo,
            &info,
            @sizeOf(os_windows.FILE_DISPOSITION_INFORMATION),
        ) != .FALSE;
    }

    /// "ghostty-YYYYMMDD-HHMMSS-<pid>.dmp", UTC, after the directory: the
    /// names sort by time, which `prune` relies on.
    const max_name_len = "ghostty-YYYYMMDD-HHMMSS-4294967295.dmp".len;

    fn fileName(self: *Dumper) [:0]const u16 {
        const now = windows.fromSysTime(windows.ntdll.RtlGetSystemTimePrecise());
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now.toSeconds()) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        var buf: [max_name_len]u8 = undefined;
        const ascii = std.fmt.bufPrint(&buf, "ghostty-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}.dmp", .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
            windows.GetCurrentProcessId(),
        }) catch unreachable;
        for (ascii, self.path[self.dir_len..][0..ascii.len]) |c, *w| w.* = c;
        self.path[self.dir_len + ascii.len] = 0;
        return self.path[0 .. self.dir_len + ascii.len :0];
    }

    /// "ghostty <version> <mode> <arch>-windows thread=<type> <kind>",
    /// then ": <message>" cut to fit.
    fn commentText(self: *Dumper) [:0]const u8 {
        const head = std.fmt.bufPrint(&self.comment, "ghostty {s} {s} {s}-windows thread={s} {t}", .{
            build_config.version_string,
            build_config.mode_string,
            @tagName(builtin.cpu.arch),
            self.thread_type,
            self.kind,
        }) catch unreachable; // bounded: see the assert on `comment`
        var len = head.len;
        const message = self.message[0..self.message_len];
        if (message.len > 0) for ([_][]const u8{ ": ", message }) |part| {
            const n = @min(part.len, self.comment.len - 1 - len);
            @memcpy(self.comment[len..][0..n], part[0..n]);
            len += n;
        };
        self.comment[len] = 0;
        return self.comment[0..len :0];
    }
};

/// MiniDumpWriteDump from System32 only. dbgcore.dll has it on Windows 8
/// and later, without the rest of dbghelp.dll. Loaded at install, not at
/// the crash, which may hold the loader lock.
fn loadMiniDumpWriteDump() !MiniDumpWriteDumpFn {
    for ([_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("dbgcore.dll"),
        std.unicode.utf8ToUtf16LeStringLiteral("dbghelp.dll"),
    }) |name| {
        const module = kernel32.LoadLibraryExW(
            name,
            null,
            os_windows.LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse continue;
        if (kernel32.GetProcAddress(module, "MiniDumpWriteDump")) |proc| {
            return @ptrCast(@alignCast(proc));
        }
    }
    return error.MiniDumpWriteDumpMissing;
}

// --- The app's hooks -----------------------------------------------------

var dumper: Dumper = undefined;
var installed: std.atomic.Value(bool) = .init(false);
var previous_filter: ?os_windows.LPTOP_LEVEL_EXCEPTION_FILTER = null;

/// The exception Zig's segfault handler is about to end the process for,
/// remembered by `remember` on the faulting thread.
threadlocal var pending: ?*const ExceptionPointers = null;

/// Sets up crash dumps for this process: the exe only, never a host that
/// embeds libghostty, whose process-wide handlers are its own. Deletes
/// all but the newest `keep` dumps.
pub fn install(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
) !void {
    comptime assert(build_config.artifact == .exe);
    if (installed.load(.acquire)) return;

    const dir = try crash.defaultDir(io, alloc, environ_map);
    defer alloc.free(dir.path);
    // The directory comes from the environment as it is set. A relative
    // one (the XDG specification calls it invalid) would be another
    // directory whenever the working directory changed, so no dumps then.
    if (!std.fs.path.isAbsolute(dir.path)) return error.CrashDirNotAbsolute;
    try std.Io.Dir.cwd().createDirPath(io, dir.path);
    prune(io, alloc, dir.path) catch |err| {
        log.warn("could not delete old crash dumps err={}", .{err});
    };

    const full = if (environ_map.get("GHOSTTY_CRASH_DUMP")) |v| std.mem.eql(u8, v, "full") else false;
    try dumper.start(io, dir.path, if (full) full_type else small_type);
    installed.store(true, .release);

    previous_filter = kernel32.SetUnhandledExceptionFilter(filter);
    if (std.options.enable_segfault_handler) {
        // First in the chain, ahead of Zig's (added at startup, last).
        _ = windows.ntdll.RtlAddVectoredExceptionHandler(1, remember);
    }
    log.info("crash dumps dir={s} type=0x{x}", .{ dir.path, dumper.dump_type });

    if (comptime builtin.mode == .debug) {
        if (environ_map.get("GHOSTTY_CRASH_TEST")) |what| crashTest(what);
    }
}

/// The four exceptions Zig's segfault handler ends the process for
/// (std/debug.zig, handleSegfaultWindows). Every other code passes it by.
pub fn isZigFatal(code: u32) bool {
    return switch (code) {
        windows.EXCEPTION_DATATYPE_MISALIGNMENT,
        windows.EXCEPTION_ACCESS_VIOLATION,
        windows.EXCEPTION_ILLEGAL_INSTRUCTION,
        windows.EXCEPTION_STACK_OVERFLOW,
        => true,
        else => false,
    };
}

fn remember(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    if (isZigFatal(info.ExceptionRecord.ExceptionCode)) pending = @ptrCast(info);
    return windows.EXCEPTION_CONTINUE_SEARCH;
}

/// `root.debug.handleSegfault`: Zig's segfault handler calls it once it has
/// decided to end the process.
pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
    if (pending) |pointers| {
        pending = null;
        if (installed.load(.acquire)) _ = dumper.dump(pointers, .exception, "");
    }
    std.debug.defaultHandleSegfault(addr, name, ctx);
}

/// The unhandled-exception filter (ReleaseFast, and a fault while
/// panicking). Windows' own handling follows: the process ends with the
/// exception's code and an Application Error event.
fn filter(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) os_windows.LONG {
    if (installed.load(.acquire)) _ = dumper.dump(@ptrCast(info), .exception, "");
    if (previous_filter) |f| return f(info);
    return windows.EXCEPTION_CONTINUE_SEARCH;
}

/// The root panic handler: dump, then panic as usual.
pub fn panic(message: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (installed.load(.acquire)) _ = dumpHere(&dumper, panic_code, message, ret_addr orelse @returnAddress());
    std.debug.defaultPanic(message, ret_addr);
}

/// Dumps the calling thread as it is, with `code` as the exception.
noinline fn dumpHere(d: *Dumper, code: u32, message: []const u8, addr: usize) Dumper.Result {
    var context: windows.CONTEXT = undefined;
    windows.ntdll.RtlCaptureContext(&context);
    var record: ExceptionRecord = .{
        .ExceptionCode = code,
        .ExceptionFlags = EXCEPTION_NONCONTINUABLE,
        .ExceptionRecord = null,
        .ExceptionAddress = @ptrFromInt(addr),
        .NumberParameters = 0,
        .ExceptionInformation = @splat(0),
    };
    const pointers: ExceptionPointers = .{ .ExceptionRecord = &record, .ContextRecord = &context };
    return d.dump(&pointers, .panic, message);
}

/// Deletes all but the newest `keep` of our dumps. Leaves every other
/// file: WER's LocalDumps (ghostty.exe.<pid>.dmp) keeps its own count.
fn prune(io: std.Io, alloc: Allocator, path: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isOurs(entry.name)) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    if (names.items.len <= keep) return;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn newer(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.newer);
    for (names.items[keep..]) |n| dir.deleteFile(io, n) catch |err| {
        log.warn("could not delete old crash dump name={s} err={}", .{ n, err });
    };
}

fn isOurs(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "ghostty-") and std.mem.endsWith(u8, name, ".dmp");
}

/// GHOSTTY_CRASH_TEST, Debug builds only: crash now, to test the dumps.
/// `raise` uses a code Zig's handler passes by, so it reaches the
/// unhandled-exception filter, the route every exception takes in
/// ReleaseFast.
fn crashTest(what: []const u8) void {
    log.warn("GHOSTTY_CRASH_TEST={s}", .{what});
    if (std.mem.eql(u8, what, "av")) {
        const p: *volatile u32 = @ptrFromInt(0x10);
        p.* = 1;
    } else if (std.mem.eql(u8, what, "stack")) {
        _ = recurse(0);
    } else if (std.mem.eql(u8, what, "raise")) {
        kernel32.RaiseException(test_code, EXCEPTION_NONCONTINUABLE, 0, null);
    }
}

noinline fn recurse(n: usize) usize {
    var pad: [4096]u8 = undefined;
    std.mem.doNotOptimizeAway(&pad);
    pad[n % pad.len] = @truncate(n);
    return recurse(n + 1) + pad[0];
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

/// A record and context for the calling thread, as `dumpHere` makes them.
fn testPointers(context: *windows.CONTEXT, record: *ExceptionRecord) ExceptionPointers {
    windows.ntdll.RtlCaptureContext(context);
    record.* = .{
        .ExceptionCode = test_code,
        .ExceptionFlags = EXCEPTION_NONCONTINUABLE,
        .ExceptionRecord = null,
        .ExceptionAddress = @ptrFromInt(@returnAddress()),
        .NumberParameters = 0,
        .ExceptionInformation = @splat(0),
    };
    return .{ .ExceptionRecord = record, .ContextRecord = context };
}

/// A MiniDumpWriteDump that the tests steer, in place of dbgcore's. It
/// writes "hello".
const TestWrite = struct {
    /// What the write answers. FALSE comes with ERROR_DISK_FULL.
    var succeed: bool = true;
    /// Whether the file was marked for deletion while being written.
    var delete_pending: bool = false;
    /// When set, the write sets it once the file is there, to say that
    /// it has begun.
    var started: ?windows.HANDLE = null;
    /// When set, the write waits for it before it reads the exception.
    var release: ?windows.HANDLE = null;
    /// The exception code the write was given.
    var code: u32 = 0;

    fn reset() void {
        succeed = true;
        delete_pending = false;
        started = null;
        release = null;
        code = 0;
    }

    fn write(
        _: windows.HANDLE,
        _: u32,
        file: windows.HANDLE,
        _: u32,
        exception: ?*const MINIDUMP_EXCEPTION_INFORMATION,
        _: ?*const MINIDUMP_USER_STREAM_INFORMATION,
        _: ?*const anyopaque,
    ) callconv(.winapi) windows.BOOL {
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        var info: os_windows.FILE_STANDARD_INFORMATION = undefined;
        delete_pending = os_windows.exp.ntdll.NtQueryInformationFile(
            file,
            &io_status,
            &info,
            @sizeOf(os_windows.FILE_STANDARD_INFORMATION),
            .Standard,
        ) == .SUCCESS and info.DeletePending != .FALSE;
        _ = kernel32.WriteFile(file, "hello", 5, null, null);
        if (started) |event| _ = kernel32.SetEvent(event);
        if (release) |event| _ = kernel32.WaitForSingleObject(event, os_windows.INFINITE);
        code = exception.?.ExceptionPointers.ExceptionRecord.ExceptionCode;
        if (succeed) return .TRUE;
        kernel32.SetLastError(.DISK_FULL);
        return .FALSE;
    }
};

/// The parts of a minidump file the tests read (minidumpapiset.h).
const TestDump = struct {
    bytes: []const u8,

    fn u32At(self: TestDump, at: usize) u32 {
        return std.mem.readInt(u32, self.bytes[at..][0..4], .little);
    }

    /// The stream of `kind`, or null.
    fn stream(self: TestDump, kind: u32) ?[]const u8 {
        const count = self.u32At(8);
        const dir = self.u32At(12);
        for (0..count) |i| {
            const entry = dir + i * 12; // sizeof(MINIDUMP_DIRECTORY)
            if (self.u32At(entry) != kind) continue;
            const size = self.u32At(entry + 4);
            const rva = self.u32At(entry + 8);
            return self.bytes[rva..][0..size];
        }
        return null;
    }
};

fn testDumps(dir: std.Io.Dir, alloc: Allocator) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (!isOurs(entry.name)) continue;
        try names.ensureUnusedCapacity(alloc, 1);
        names.appendAssumeCapacity(try alloc.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(alloc);
}

/// The one dump in `dir`, read whole; fails if there is not exactly one.
fn testOnlyDump(dir: std.Io.Dir, alloc: Allocator) ![]u8 {
    const names = try testDumps(dir, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    try testing.expectEqual(1, names.len);
    return dir.readFileAlloc(testing.io, names[0], alloc, .unlimited);
}

/// The exception stream's thread id and exception code.
fn testException(dump: TestDump) !struct { u32, u32 } {
    const exception = dump.stream(ExceptionStream) orelse return error.NoExceptionStream;
    return .{
        std.mem.readInt(u32, exception[0..4], .little),
        std.mem.readInt(u32, exception[8..12], .little),
    };
}

test "win32: a panic's crash dump holds its code, thread and message" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    defer d.stop();

    var name_buf: [std.Thread.max_name_len:0]u8 = undefined;
    try testing.expectEqualStrings(Dumper.thread_name, (try d.thread.getName(&name_buf)).?);

    // The thread's role is a threadlocal, which the dumper's thread
    // cannot read: the panicking thread hands it over.
    crash.sentry.thread_state = .{ .type = .io, .surface = undefined };
    defer crash.sentry.thread_state = null;
    try testing.expect(dumpHere(&d, panic_code, "the message", @returnAddress()) == .written);

    const bytes = try testOnlyDump(tmp.dir, alloc);
    defer alloc.free(bytes);
    const dump: TestDump = .{ .bytes = bytes };

    // MINIDUMP_HEADER: "MDMP", then MINIDUMP_VERSION in the low word.
    try testing.expectEqualSlices(u8, "MDMP", bytes[0..4]);
    try testing.expectEqual(0xA793, dump.u32At(4) & 0xffff);

    // MINIDUMP_EXCEPTION_STREAM: this thread, the panic's code.
    const thread, const code = try testException(dump);
    try testing.expectEqual(windows.GetCurrentThreadId(), thread);
    try testing.expectEqual(panic_code, code);

    // Every thread, this one and the dumper's at least, and the modules.
    const threads = dump.stream(ThreadListStream) orelse return error.NoThreadList;
    try testing.expect(std.mem.readInt(u32, threads[0..4], .little) >= 2);
    const modules = dump.stream(ModuleListStream) orelse return error.NoModuleList;
    try testing.expect(std.mem.readInt(u32, modules[0..4], .little) >= 1);

    const comment = dump.stream(CommentStreamA) orelse return error.NoComment;
    try testing.expect(std.mem.indexOf(u8, comment, "thread=io panic: the message") != null);
    try testing.expect(std.mem.indexOf(u8, comment, build_config.version_string) != null);
}

test "win32: a crash directory longer than MAX_PATH takes a dump" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(base);

    // Five 50-letter directories: past MAX_PATH wherever the tests run.
    const name: [50]u8 = @splat('d');
    const sub = try std.fs.path.join(alloc, &.{ &name, &name, &name, &name, &name });
    defer alloc.free(sub);
    try tmp.dir.createDirPath(testing.io, sub);
    var long = try tmp.dir.openDir(testing.io, sub, .{ .iterate = true });
    defer long.close(testing.io);
    const dir = try std.fs.path.join(alloc, &.{ base, sub });
    defer alloc.free(dir);
    try testing.expect(dir.len > windows.MAX_PATH);

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    defer d.stop();
    // The documented prefix, not its NT form, which CreateFileW also
    // takes on Windows 11.
    try testing.expectEqualSlices(u16, &.{ '\\', '\\', '?', '\\' }, d.path[0..4]);

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    const pointers = testPointers(&context, &record);
    try testing.expect(d.dump(&pointers, .exception, "") == .written);

    const bytes = try testOnlyDump(long, alloc);
    defer alloc.free(bytes);
    try testing.expectEqualSlices(u8, "MDMP", bytes[0..4]);
}

test "win32: a dump is marked for deletion until it is whole" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    defer d.stop();
    TestWrite.reset();
    d.write = TestWrite.write;

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    const pointers = testPointers(&context, &record);
    try testing.expect(d.dump(&pointers, .exception, "") == .written);

    // Marked while it was written, so that a process ending then would
    // have left nothing, and kept once written.
    try testing.expect(TestWrite.delete_pending);
    const bytes = try testOnlyDump(tmp.dir, alloc);
    defer alloc.free(bytes);
    try testing.expectEqualStrings("hello", bytes);
}

test "win32: a dump that fails leaves no file" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    defer d.stop();
    TestWrite.reset();
    TestWrite.succeed = false;
    d.write = TestWrite.write;

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    const pointers = testPointers(&context, &record);
    const result = d.dump(&pointers, .exception, "");
    try testing.expect(result == .failed);
    try testing.expectEqual(windows.Win32Error.DISK_FULL, result.failed);

    const names = try testDumps(tmp.dir, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    try testing.expectEqual(0, names.len);
}

test "win32: a crash's record outlives a thread that gave up waiting" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    const release = kernel32.CreateEventW(null, .TRUE, .FALSE, null) orelse
        return error.TestUnexpectedResult;
    defer _ = kernel32.CloseHandle(release);

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    {
        // Last first: the write is let go, then the dumper is joined.
        defer d.stop();
        defer _ = kernel32.SetEvent(release);
        TestWrite.reset();
        TestWrite.release = release;
        d.write = TestWrite.write;
        d.timeout_ms = 50;

        // The thread panics, gives up on its dump and is gone, stack and
        // all, while the dump is still being written.
        const Crasher = struct {
            fn run(dd: *Dumper, out: *Dumper.Result) void {
                out.* = dumpHere(dd, panic_code, "gone", @returnAddress());
            }
        };
        var result: Dumper.Result = .{ .failed = .SUCCESS };
        const t = try std.Thread.spawn(.{}, Crasher.run, .{ &d, &result });
        t.join();
        try testing.expect(result == .none);
    }

    // Only then did the write read the exception it was given.
    try testing.expectEqual(panic_code, TestWrite.code);
}

test "win32: only a process's first crash is dumped" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    defer d.stop();

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    const pointers = testPointers(&context, &record);
    try testing.expect(d.dump(&pointers, .exception, "") == .written);

    // Again on this thread (a crash while dumping), then on another.
    try testing.expect(d.dump(&pointers, .exception, "") == .none);
    const Other = struct {
        fn run(dd: *Dumper, p: *const ExceptionPointers, out: *Dumper.Result) void {
            out.* = dd.dump(p, .exception, "");
        }
    };
    var other: Dumper.Result = .{ .failed = .SUCCESS };
    const t = try std.Thread.spawn(.{}, Other.run, .{ &d, &pointers, &other });
    t.join();
    try testing.expect(other == .none);

    const names = try testDumps(tmp.dir, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    try testing.expectEqual(1, names.len);
}

test "win32: a relative crash directory installs nothing" {
    const alloc = testing.allocator;
    // A relative path, then a drive-relative one.
    for ([_][]const u8{ "state", "C:state" }) |home| {
        var environ_map: std.process.Environ.Map = .init(alloc);
        defer environ_map.deinit();
        try environ_map.put("XDG_STATE_HOME", home);
        try testing.expectError(
            error.CrashDirNotAbsolute,
            install(testing.io, alloc, &environ_map),
        );
        try testing.expect(!installed.load(.acquire));
    }
}

test "win32: a second crashing thread waits for the first one's dump" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var events: [3]windows.HANDLE = undefined;
    for (&events, 0..) |*event, i| {
        errdefer for (events[0..i]) |made| {
            _ = kernel32.CloseHandle(made);
        };
        event.* = kernel32.CreateEventW(null, .TRUE, .FALSE, null) orelse
            return error.TestUnexpectedResult;
    }
    defer for (events) |event| {
        _ = kernel32.CloseHandle(event);
    };
    const started, const release, const entered = events;

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    const pointers = testPointers(&context, &record);

    const Crasher = struct {
        dumper: *Dumper,
        pointers: *const ExceptionPointers,
        /// Whether the first thread's write has been let go.
        released: *const std.atomic.Value(bool),
        /// Set when the thread runs, if not null.
        entered: ?windows.HANDLE = null,
        result: Dumper.Result = .{ .failed = .SUCCESS },
        /// What `released` was when `dump` returned.
        saw_released: bool = false,

        fn run(self: *@This()) void {
            if (self.entered) |event| _ = kernel32.SetEvent(event);
            self.result = self.dumper.dump(self.pointers, .exception, "");
            self.saw_released = self.released.load(.acquire);
        }
    };

    var d: Dumper = undefined;
    try d.start(testing.io, dir, small_type);
    var released: std.atomic.Value(bool) = .init(false);
    var first: Crasher = .{ .dumper = &d, .pointers = &pointers, .released = &released };
    var second: Crasher = .{ .dumper = &d, .pointers = &pointers, .released = &released, .entered = entered };
    {
        // Last first: the write is let go, then the dumper is joined.
        defer d.stop();
        defer _ = kernel32.SetEvent(release);
        TestWrite.reset();
        TestWrite.started = started;
        TestWrite.release = release;
        d.write = TestWrite.write;

        // The first thread's dump is under way and held there.
        const a = try std.Thread.spawn(.{}, Crasher.run, .{&first});
        _ = kernel32.WaitForSingleObject(started, d.timeout_ms);

        // The second crashes meanwhile. A thread that did not wait would
        // be back well within the pause, before the write is let go.
        const b = std.Thread.spawn(.{}, Crasher.run, .{&second}) catch |err| {
            _ = kernel32.SetEvent(release);
            a.join();
            return err;
        };
        _ = kernel32.WaitForSingleObject(entered, d.timeout_ms);
        std.Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
        released.store(true, .release);
        _ = kernel32.SetEvent(release);
        a.join();
        b.join();
    }

    try testing.expect(first.result == .written);
    try testing.expect(second.result == .none);
    try testing.expect(second.saw_released);
}

test "win32: the exceptions Zig's segfault handler ends the process for" {
    for ([_]u32{ 0x80000002, 0xC0000005, 0xC000001D, 0xC00000FD }) |code| {
        try testing.expect(isZigFatal(code));
    }
    // Integer division by zero, a breakpoint, and our own codes.
    for ([_]u32{ 0xC0000094, 0x80000003, panic_code, test_code }) |code| {
        try testing.expect(!isZigFatal(code));
    }
}

test "win32: pruning keeps the newest crash dumps and nothing else" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    // Oldest first, which is also the order a directory lists them in
    // (NTFS by name, a file system without an index as they were made):
    // a prune that skipped its sort would delete the newest.
    for (1..keep + 4) |day| {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "ghostty-202611{d:0>2}-120000-7.dmp", .{day});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }
    const others = [_][]const u8{ "ghostty.exe.1234.dmp", "0c9f.ghosttycrash", "notes.txt" };
    for (others) |name| try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });

    try prune(testing.io, alloc, dir);

    // The three oldest are gone and the rest are left, each looked up by
    // name: counting through isOurs, which prune uses too, would not see
    // it take another file for one of ours.
    for (1..keep + 4) |day| {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "ghostty-202611{d:0>2}-120000-7.dmp", .{day});
        const found = tmp.dir.access(testing.io, name, .{});
        if (day > 3) try found else try testing.expectError(error.FileNotFound, found);
    }
    for (others) |name| try tmp.dir.access(testing.io, name, .{});
}

test "win32: the unhandled-exception filter dumps, then lets Windows end the process" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    var pointers = testPointers(&context, &record);
    const info: *windows.EXCEPTION_POINTERS = @ptrCast(&pointers);

    // Not installed (a host's process, or install failed): nothing.
    try testing.expectEqual(windows.EXCEPTION_CONTINUE_SEARCH, filter(info));

    // The app's own dumper, as `install` starts it.
    try dumper.start(testing.io, dir, small_type);
    installed.store(true, .release);
    defer {
        installed.store(false, .release);
        dumper.stop();
    }
    try testing.expectEqual(windows.EXCEPTION_CONTINUE_SEARCH, filter(info));

    const bytes = try testOnlyDump(tmp.dir, alloc);
    defer alloc.free(bytes);
    const dump: TestDump = .{ .bytes = bytes };
    const thread, const code = try testException(dump);
    try testing.expectEqual(windows.GetCurrentThreadId(), thread);
    try testing.expectEqual(test_code, code);
    const comment = dump.stream(CommentStreamA) orelse return error.NoComment;
    try testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(comment, 0), "thread=other exception"));
}

/// An unhandled-exception filter from before ours, for the tests.
const TestFilter = struct {
    /// A verdict ours never gives itself: the Windows SDK's value for
    /// "run the handler".
    const EXCEPTION_EXECUTE_HANDLER = 1;

    var calls: usize = 0;
    var info: ?*windows.EXCEPTION_POINTERS = null;
    /// Whether the dump was written by the time it was called.
    var dumped: bool = false;

    fn filter(i: *windows.EXCEPTION_POINTERS) callconv(.winapi) os_windows.LONG {
        calls += 1;
        info = i;
        dumped = installed.load(.acquire) and dumper.result == .written;
        return EXCEPTION_EXECUTE_HANDLER;
    }
};

test "win32: the unhandled-exception filter passes on the previous filter's verdict" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    var pointers = testPointers(&context, &record);
    const info: *windows.EXCEPTION_POINTERS = @ptrCast(&pointers);

    TestFilter.calls = 0;
    previous_filter = TestFilter.filter;
    defer previous_filter = null;

    // Without a dumper there is no dump, and the verdict is still the
    // previous filter's.
    try testing.expectEqual(TestFilter.EXCEPTION_EXECUTE_HANDLER, filter(info));
    try testing.expectEqual(1, TestFilter.calls);
    try testing.expect(!TestFilter.dumped);

    try dumper.start(testing.io, dir, small_type);
    installed.store(true, .release);
    defer {
        installed.store(false, .release);
        dumper.stop();
    }

    // The dump first: what the previous filter then does with the
    // exception may leave no other record of it.
    try testing.expectEqual(TestFilter.EXCEPTION_EXECUTE_HANDLER, filter(info));
    try testing.expectEqual(2, TestFilter.calls);
    try testing.expect(TestFilter.info == info);
    try testing.expect(TestFilter.dumped);
    const bytes = try testOnlyDump(tmp.dir, alloc);
    defer alloc.free(bytes);
}

test "win32: the first vectored handler remembers only what Zig's ends the process for" {
    defer pending = null;
    var context: windows.CONTEXT = undefined;
    var record: ExceptionRecord = undefined;
    var pointers = testPointers(&context, &record);
    const info: *windows.EXCEPTION_POINTERS = @ptrCast(&pointers);

    try testing.expectEqual(windows.EXCEPTION_CONTINUE_SEARCH, remember(info));
    try testing.expect(pending == null);

    record.ExceptionCode = windows.EXCEPTION_ACCESS_VIOLATION;
    try testing.expectEqual(windows.EXCEPTION_CONTINUE_SEARCH, remember(info));
    try testing.expectEqual(@as(*const ExceptionPointers, &pointers), pending.?);
}
