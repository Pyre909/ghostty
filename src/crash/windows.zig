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
//! over its exception pointers and waits, for at most `timeout_ms`, which
//! also bounds a deadlock inside the dump (for example on the loader lock).
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

/// How long a crashing thread waits for its dump before dying anyway.
const timeout_ms = 10_000;

/// The dump by default: every thread's stack and registers, the module
/// list (with the PDB identity a debugger needs), unloaded modules and
/// handles. No other memory: the heap and data sections hold scrollback,
/// which can hold anything that was typed or printed.
const small_type: u32 = 0x1000 | 0x20 | 0x4; // WithThreadInfo, WithUnloadedModules, WithHandleData

/// With GHOSTTY_CRASH_DUMP=full: all of the process's memory, as asked.
const full_type: u32 = small_type | 0x2 | 0x800; // WithFullMemory, WithFullMemoryInfo

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
const GENERIC_WRITE = 0x40000000;
const CREATE_NEW = 1;

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

/// MINIDUMP_STREAM_TYPE's CommentStreamA: text a debugger shows with the
/// dump (cdb prints it as "Comment:").
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

const TopLevelFilter = *const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long;

extern "kernel32" fn SetUnhandledExceptionFilter(
    filter: ?TopLevelFilter,
) callconv(.winapi) ?TopLevelFilter;
extern "kernel32" fn RaiseException(
    code: u32,
    flags: u32,
    count: u32,
    arguments: ?[*]const usize,
) callconv(.winapi) void;
extern "kernel32" fn CreateEventW(
    attributes: ?*windows.SECURITY_ATTRIBUTES,
    manual_reset: windows.BOOL,
    initial_state: windows.BOOL,
    name: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) windows.BOOL;

// --- The dumper ----------------------------------------------------------

pub const Kind = enum { exception, panic };

/// Writes dumps on its own thread. Everything a dump needs is allocated
/// here up front: nothing on the crash path allocates, takes a lock or
/// formats on the crashing thread.
pub const Dumper = struct {
    write: MiniDumpWriteDumpFn,
    dump_type: u32,

    /// The crash directory and a separator, UTF-16, then room for a name.
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
    pointers: *const ExceptionPointers = undefined,
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

    /// `dir` is the crash directory, which must exist. The dumper is not
    /// movable once started: its thread holds a pointer to it.
    pub fn start(self: *Dumper, dir: []const u8, dump_type: u32) !void {
        const write = try loadMiniDumpWriteDump();
        const request = CreateEventW(null, .FALSE, .FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = kernel32.CloseHandle(request);
        const done = CreateEventW(null, .TRUE, .FALSE, null) orelse
            return windows.unexpectedError(windows.GetLastError());
        errdefer _ = kernel32.CloseHandle(done);

        self.* = .{
            .write = write,
            .dump_type = dump_type,
            .request = request,
            .done = done,
            .thread = undefined,
        };
        // std's paths are WTF-8 on Windows.
        if (try std.unicode.calcWtf16LeLen(dir) + 1 + max_name_len + 1 > self.path.len) return error.NameTooLong;
        const n = try std.unicode.wtf8ToWtf16Le(&self.path, dir);
        self.path[n] = '\\';
        self.dir_len = n + 1;

        // MiniDumpWriteDump's own stack use is modest; a megabyte leaves
        // room for the system's stack walking.
        self.thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{self});
    }

    /// Stops the thread and closes the events. Tests only: the app's dumper
    /// lives as long as the process.
    pub fn stop(self: *Dumper) void {
        self.stopping.store(true, .release);
        _ = SetEvent(self.request);
        self.thread.join();
        _ = kernel32.CloseHandle(self.request);
        _ = kernel32.CloseHandle(self.done);
    }

    /// Asks for a dump of the calling thread's crash and waits for it.
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
            if (other != me) _ = kernel32.WaitForSingleObject(self.done, timeout_ms);
            return .none;
        }

        self.pointers = pointers;
        self.kind = kind;
        // The thread's role, which only this thread can read.
        self.thread_type = if (crash.sentry.thread_state) |s| @tagName(s.type) else "other";
        self.message_len = @min(message.len, self.message.len);
        @memcpy(self.message[0..self.message_len], message[0..self.message_len]);

        _ = SetEvent(self.request);
        return switch (kernel32.WaitForSingleObject(self.done, timeout_ms)) {
            os_windows.WAIT_OBJECT_0 => self.result,
            else => .none,
        };
    }

    /// Lets the next crash dump again. Tests only.
    pub fn reset(self: *Dumper) void {
        _ = ResetEvent(self.done);
        self.result = .none;
        self.crasher.store(0, .release);
    }

    fn run(self: *Dumper) void {
        self.thread_id.store(windows.GetCurrentThreadId(), .release);
        while (true) {
            _ = kernel32.WaitForSingleObject(self.request, os_windows.INFINITE);
            if (self.stopping.load(.acquire)) return;
            self.result = self.writeDump();
            _ = SetEvent(self.done);
        }
    }

    fn writeDump(self: *Dumper) Result {
        const name = self.fileName();
        const file = kernel32.CreateFileW(
            name.ptr,
            GENERIC_WRITE,
            0,
            null,
            CREATE_NEW,
            os_windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (file == os_windows.INVALID_HANDLE_VALUE) return .{ .failed = windows.GetLastError() };

        const info: MINIDUMP_EXCEPTION_INFORMATION = .{
            .ThreadId = self.crasher.load(.acquire),
            .ExceptionPointers = self.pointers,
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
        const ok = self.write(
            windows.GetCurrentProcess(),
            windows.GetCurrentProcessId(),
            file,
            self.dump_type,
            &info,
            &streams,
            null,
        );
        const err = windows.GetLastError();
        _ = kernel32.CloseHandle(file);
        if (ok == .FALSE) {
            // A partial dump is no use to a debugger.
            _ = DeleteFileW(name.ptr);
            return .{ .failed = err };
        }
        return .{ .written = name[self.dir_len..] };
    }

    /// "ghostty-YYYYMMDD-HHMMSS-<pid>.dmp", UTC, after the directory: the
    /// names sort by time, which `prune` relies on.
    const max_name_len = "ghostty-YYYYMMDD-HHMMSS-4294967295.dmp".len;

    fn fileName(self: *Dumper) [:0]const u16 {
        // 100 ns intervals since 1601 to seconds since 1970.
        const since_1601: u64 = @intCast(@divFloor(windows.ntdll.RtlGetSystemTimePrecise(), 10_000_000));
        const es: std.time.epoch.EpochSeconds = .{ .secs = since_1601 - -std.time.epoch.windows };
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
var previous_filter: ?TopLevelFilter = null;

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
    try std.Io.Dir.cwd().createDirPath(io, dir.path);
    prune(io, alloc, dir.path) catch |err| {
        log.warn("could not delete old crash dumps err={}", .{err});
    };

    const full = if (environ_map.get("GHOSTTY_CRASH_DUMP")) |v| std.mem.eql(u8, v, "full") else false;
    try dumper.start(dir.path, if (full) full_type else small_type);
    installed.store(true, .release);

    previous_filter = SetUnhandledExceptionFilter(filter);
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
fn filter(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
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
        RaiseException(test_code, EXCEPTION_NONCONTINUABLE, 0, null);
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
            const entry = dir + i * 12;
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
    errdefer names.deinit(alloc);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (isOurs(entry.name)) try names.append(alloc, try alloc.dupe(u8, entry.name));
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
    const exception = dump.stream(6) orelse return error.NoExceptionStream;
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
    try d.start(dir, small_type);
    defer d.stop();

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
    const threads = dump.stream(3) orelse return error.NoThreadList;
    try testing.expect(std.mem.readInt(u32, threads[0..4], .little) >= 2);
    const modules = dump.stream(4) orelse return error.NoModuleList;
    try testing.expect(std.mem.readInt(u32, modules[0..4], .little) >= 1);

    const comment = dump.stream(CommentStreamA) orelse return error.NoComment;
    try testing.expect(std.mem.indexOf(u8, comment, "thread=io panic: the message") != null);
    try testing.expect(std.mem.indexOf(u8, comment, build_config.version_string) != null);
}

test "win32: only a process's first crash is dumped" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    var d: Dumper = undefined;
    try d.start(dir, small_type);
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

    // Written newest first, so that the directory's order is not the names'.
    var i: usize = keep + 3;
    while (i > 0) : (i -= 1) {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "ghostty-202611{d:0>2}-120000-7.dmp", .{i});
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
    try dumper.start(dir, small_type);
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
