//! The bell's sound (`bell-features` `audio`): `bell-audio-path` played at
//! `bell-audio-volume` through Media Foundation's media engine
//! (IMFMediaEngine), as GTK plays it through a GtkMediaFile
//! (src/apprt/gtk/media.zig) and macOS through an NSSound. One engine for
//! the app, made at the first bell that plays and made again only when the
//! path, or whether it is required, changes, as GTK keeps one GtkMediaFile
//! for the application (`bellMediaFile`, which compares the path alone);
//! each bell rewinds it and plays it again (`playBell`).
//!
//! Media Foundation's functions come from mfplat.dll, loaded at the first
//! bell that plays (`Mf`) rather than imported: the N and KN editions of
//! Windows have no Media Foundation without the Media Feature Pack, and an
//! import would keep ghostty.exe from starting there. Without it, the
//! bell plays nothing, which is logged once.
//!
//! The engine plays what Media Foundation decodes, which on Windows 10 and
//! 11 includes WAV, MP3, AAC and FLAC. PlaySound plays only WAV, at the
//! system's volume; MCI is the API Media Foundation supersedes.
//!
//! Loading and playing happen on Media Foundation's own threads: `SetSource`
//! and `Play` return at once, and the engine reports what happens through
//! `Notify.EventNotify`, on one of those threads. A `required` path that
//! cannot be played is logged there, as GTK logs one; an optional one
//! plays nothing, quietly, as on GTK. A file that cannot be read is
//! logged either way, before an engine is made for it, as GTK's
//! `fromFilename` logs it.
//!
//! The interfaces are vtable structs in the order of the mingw headers Zig
//! ships (lib/libc/include/any-windows-any/mfmediaengine.h and
//! mfobjects.h), as taskbar.zig's: only the methods called here are typed,
//! every other slot is an untyped pointer, and the tests check the slot
//! counts and the typed slots' indices against the headers.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const global = @import("../../global.zig");
const win32 = @import("win32.zig");
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;

const log = std.log.scoped(.win32);

const HRESULT = win32.HRESULT;
const ULONG = windows.ULONG;
const DWORD = windows.DWORD;
const GUID = windows.GUID;

const CLSID_MFMediaEngineClassFactory: GUID = GUID.parse("{b44392da-499b-446b-a4cb-005fead0e6d5}");
const IID_IMFMediaEngineClassFactory: GUID = GUID.parse("{4d645ace-26aa-4688-9be1-df3516990b93}");
const IID_IMFMediaEngineNotify: GUID = GUID.parse("{fee7c112-e776-42b5-9bbf-0048524e2bd5}");

/// The attribute that gives the engine its `Notify`, which it requires.
const MF_MEDIA_ENGINE_CALLBACK: GUID = GUID.parse("{c60381b8-83a4-41f8-a3d0-de05076849a9}");

/// CreateInstance's flag for an engine with no video.
const MF_MEDIA_ENGINE_AUDIOONLY: DWORD = 0x1;

/// MF_VERSION of mfapi.h on Windows 7 and later.
const MF_VERSION: windows.ULONG = 0x0002 << 16 | 0x0070;

/// MFStartup without the sockets a network source needs: the bell plays a
/// local file.
const MFSTARTUP_LITE: DWORD = 0x1;

/// A DLL `Mf.load` loads: its name for the log, and for LoadLibraryExW.
pub const Dll = struct {
    name: []const u8,
    wide: [*:0]const u16,
};

const mfplat: Dll = .{
    .name = "mfplat.dll",
    .wide = std.unicode.utf8ToUtf16LeStringLiteral("mfplat.dll"),
};

/// For tests: the DLL `Mf.load` loads in place of mfplat.dll.
pub var test_dll: if (builtin.is_test) Dll else void =
    if (builtin.is_test) mfplat else {};

/// The functions of mfplat.dll the bell calls, each named as its export.
const Mf = struct {
    MFStartup: *const fn (version: ULONG, flags: DWORD) callconv(.winapi) HRESULT,
    MFShutdown: *const fn () callconv(.winapi) HRESULT,
    MFCreateAttributes: *const fn (out: *?*IMFAttributes, size: u32) callconv(.winapi) HRESULT,

    /// Load mfplat.dll, from System32 alone, and find its functions, or
    /// log why not. The DLL is never freed: the engine's threads, which
    /// run its code, may outlive the app's last call.
    fn load() ?Mf {
        const dll = if (builtin.is_test) test_dll else mfplat;
        if (builtin.is_test) test_record.loads += 1;
        const module = win32.LoadLibraryExW(dll.wide, null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
            log.warn("bell audio: cannot load {s} err={}", .{ dll.name, win32.GetLastError() });
            return null;
        };
        var mf: Mf = undefined;
        inline for (@typeInfo(Mf).@"struct".field_names) |name| {
            const proc = win32.GetProcAddress(module, name) orelse {
                log.warn("bell audio: {s} has no {s} err={}", .{ dll.name, name, win32.GetLastError() });
                return null;
            };
            @field(mf, name) = @ptrCast(@alignCast(proc));
        }
        return mf;
    }
};

/// MF_MEDIA_ENGINE_EVENT, those `Notify` tells apart.
const Event = enum(DWORD) {
    @"error" = 5,
    playing = 13,
    ended = 19,
    _,
};

/// MF_MEDIA_ENGINE_ERR, the first parameter of an `Event.error`.
const MediaError = enum(usize) {
    aborted = 1,
    network = 2,
    decode = 3,
    src_not_supported = 4,
    encrypted = 5,
    _,
};

fn check(hr: HRESULT, what: []const u8) error{MediaFailed}!void {
    if (hr >= 0) return;
    log.warn("bell audio: {s} failed hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
    return error.MediaFailed;
}

/// An untyped vtable slot, there so that the slots after it keep their
/// index.
const Slot = *const anyopaque;

pub const IMFAttributes = extern struct {
    vtable: *const VTable,

    /// IUnknown's and IMFAttributes', flattened.
    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IMFAttributes) callconv(.winapi) ULONG,
        GetItem: Slot,
        GetItemType: Slot,
        CompareItem: Slot,
        Compare: Slot,
        GetUINT32: Slot,
        GetUINT64: Slot,
        GetDouble: Slot,
        GetGUID: Slot,
        GetStringLength: Slot,
        GetString: Slot,
        GetAllocatedString: Slot,
        GetBlobSize: Slot,
        GetBlob: Slot,
        GetAllocatedBlob: Slot,
        GetUnknown: Slot,
        SetItem: Slot,
        DeleteItem: Slot,
        DeleteAllItems: Slot,
        SetUINT32: Slot,
        SetUINT64: Slot,
        SetDouble: Slot,
        SetGUID: Slot,
        SetString: Slot,
        SetBlob: Slot,
        SetUnknown: *const fn (*IMFAttributes, *const GUID, ?*anyopaque) callconv(.winapi) HRESULT,
        LockStore: Slot,
        UnlockStore: Slot,
        GetCount: Slot,
        GetItemByIndex: Slot,
        CopyAllItems: Slot,
    };
};

pub const IMFMediaEngineClassFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IMFMediaEngineClassFactory) callconv(.winapi) ULONG,
        CreateInstance: *const fn (*IMFMediaEngineClassFactory, DWORD, *IMFAttributes, *?*IMFMediaEngine) callconv(.winapi) HRESULT,
        CreateTimeRange: Slot,
        CreateError: Slot,
    };
};

pub const IMFMediaEngine = extern struct {
    vtable: *const VTable,

    /// IUnknown's and IMFMediaEngine's, flattened.
    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IMFMediaEngine) callconv(.winapi) ULONG,
        GetError: Slot,
        SetErrorCode: Slot,
        SetSourceElements: Slot,
        SetSource: *const fn (*IMFMediaEngine, win32.BSTR) callconv(.winapi) HRESULT,
        GetCurrentSource: Slot,
        GetNetworkState: Slot,
        GetPreload: Slot,
        SetPreload: Slot,
        GetBuffered: Slot,
        Load: Slot,
        CanPlayType: Slot,
        GetReadyState: Slot,
        IsSeeking: Slot,
        GetCurrentTime: Slot,
        SetCurrentTime: *const fn (*IMFMediaEngine, f64) callconv(.winapi) HRESULT,
        GetStartTime: Slot,
        GetDuration: Slot,
        IsPaused: Slot,
        GetDefaultPlaybackRate: Slot,
        SetDefaultPlaybackRate: Slot,
        GetPlaybackRate: Slot,
        SetPlaybackRate: Slot,
        GetPlayed: Slot,
        GetSeekable: Slot,
        IsEnded: Slot,
        GetAutoPlay: Slot,
        SetAutoPlay: Slot,
        GetLoop: Slot,
        SetLoop: Slot,
        Play: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        Pause: Slot,
        GetMuted: Slot,
        SetMuted: Slot,
        GetVolume: Slot,
        SetVolume: *const fn (*IMFMediaEngine, f64) callconv(.winapi) HRESULT,
        HasVideo: Slot,
        HasAudio: Slot,
        GetNativeVideoSize: Slot,
        GetVideoAspectRatio: Slot,
        Shutdown: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        TransferVideoFrame: Slot,
        OnVideoStreamTick: Slot,
    };
};

/// The engine's IMFMediaEngineNotify, which it calls on Media Foundation's
/// threads: it logs what a bell's sound did, and, for a `required` path,
/// an error, naming the path. It is agile (IAgileObject) and its reference
/// count, the only thing that changes, is atomic, as toast.zig's handler.
pub const Notify = extern struct {
    vtable: *const VTable,
    refs: std.atomic.Value(u32),
    required: bool,
    path_ptr: [*]u8,
    path_len: usize,

    pub const IID = IID_IMFMediaEngineNotify;

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Notify, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Notify) callconv(.winapi) ULONG,
        Release: *const fn (*Notify) callconv(.winapi) ULONG,
        EventNotify: *const fn (*Notify, DWORD, usize, DWORD) callconv(.winapi) HRESULT,
    };

    /// The process's own, thread-safe, rather than the app's: the engine
    /// may release its reference on one of its threads, after the app.
    const alloc = std.heap.smp_allocator;

    const notify_vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = releaseRef,
        .EventNotify = eventNotify,
    };

    /// One reference, the caller's, for `path`, which it copies.
    pub fn create(path: []const u8, required: bool) Allocator.Error!*Notify {
        const copy = try alloc.dupe(u8, path);
        errdefer alloc.free(copy);
        const self = try alloc.create(Notify);
        self.* = .{
            .vtable = &notify_vtable,
            .refs = .init(1),
            .required = required,
            .path_ptr = copy.ptr,
            .path_len = copy.len,
        };
        return self;
    }

    fn sourcePath(self: *const Notify) []const u8 {
        return self.path_ptr[0..self.path_len];
    }

    fn queryInterface(self: *Notify, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        for ([_]*const GUID{ &IID, &win32.IID_IUnknown, &win32.IID_IAgileObject }) |known| {
            if (std.meta.eql(iid.*, known.*)) {
                _ = addRef(self);
                out.* = self;
                return win32.S_OK;
            }
        }
        out.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(self: *Notify) callconv(.winapi) ULONG {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseRef(self: *Notify) callconv(.winapi) ULONG {
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) {
            alloc.free(self.sourcePath());
            alloc.destroy(self);
        }
        return left;
    }

    fn eventNotify(self: *Notify, event: DWORD, param1: usize, param2: DWORD) callconv(.winapi) HRESULT {
        switch (@as(Event, @fromBackingInt(@intCast(event)))) {
            .playing => log.debug("bell audio: playing {s}", .{self.sourcePath()}),
            .ended => log.debug("bell audio: ended {s}", .{self.sourcePath()}),
            // The error's code, and the HRESULT that caused it.
            .@"error" => {
                const code = std.enums.tagName(MediaError, @fromBackingInt(@intCast(param1))) orelse "unknown";
                if (self.required) {
                    log.warn("error playing sound from {s}: {s} hr=0x{x}", .{ self.sourcePath(), code, param2 });
                } else {
                    log.debug("error playing sound from {s}: {s} hr=0x{x}", .{ self.sourcePath(), code, param2 });
                }
            },
            _ => {},
        }
        return win32.S_OK;
    }
};

/// For tests: what `Bell` did, with an engine's player standing in for
/// each (`Player`): Media Foundation loaded, started and shut down, players
/// made and destroyed, and the last one played. `fail_init`, if set, is
/// what the next players' `init` fails with.
pub const TestRecord = struct {
    loads: usize = 0,
    startups: usize = 0,
    shutdowns: usize = 0,
    inits: usize = 0,
    deinits: usize = 0,
    plays: usize = 0,
    path: [512]u8 = undefined,
    path_len: usize = 0,
    required: bool = false,
    volume: f64 = 0,
    fail_init: ?Player.InitError = null,

    pub fn lastPath(self: *const TestRecord) []const u8 {
        return self.path[0..self.path_len];
    }
};
pub var test_record: if (builtin.is_test) TestRecord else void =
    if (builtin.is_test) .{} else {};

/// The app's bell sound (`App.bell_audio`): an engine for the path last
/// played, made at the first bell that plays one, and Media Foundation
/// loaded and started for it, until `deinit`.
pub const Bell = struct {
    player: ?Player = null,
    mf: union(enum) {
        /// Until the first bell that plays.
        unloaded,
        /// mfplat.dll, or one of its functions, is not there, which was
        /// logged: no bell plays.
        missing,
        /// Loaded, and not started, or no longer: MFStartup failed, which
        /// was logged, and is tried again at the next bell; or `deinit`.
        loaded: Mf,
        /// Started, until `deinit`.
        started: Mf,
    } = .unloaded,

    /// Stop the sound and Media Foundation, as the app quits.
    pub fn deinit(self: *Bell, alloc: Allocator) void {
        if (self.player) |*p| p.deinit(alloc);
        self.player = null;
        switch (self.mf) {
            .started => |mf| {
                check(mf.MFShutdown(), "MFShutdown") catch {};
                if (builtin.is_test) test_record.shutdowns += 1;
                self.mf = .{ .loaded = mf };
            },
            .unloaded, .missing, .loaded => {},
        }
    }

    /// Media Foundation, loaded and started, or null if it cannot be.
    fn start(self: *Bell) ?Mf {
        if (self.mf == .unloaded) self.mf = if (Mf.load()) |mf| .{ .loaded = mf } else .missing;
        switch (self.mf) {
            .unloaded, .missing => return null,
            .started => |mf| return mf,
            .loaded => |mf| {
                check(mf.MFStartup(MF_VERSION, MFSTARTUP_LITE), "MFStartup") catch return null;
                if (builtin.is_test) test_record.startups += 1;
                self.mf = .{ .started = mf };
                return mf;
            },
        }
    }

    /// Play `path`, an absolute path as the config gives it, at `volume`,
    /// clamped to 0 to 1: from the start, though it still plays from a
    /// bell before. An engine is made first if there is none for `path`,
    /// or the one there is was made for another, or for the same path the
    /// other way `required`. Nothing plays if it cannot be, which is
    /// logged.
    pub fn ring(self: *Bell, alloc: Allocator, path: [:0]const u8, required: bool, volume: f64) void {
        if (self.player) |*p| {
            if (p.required != required or !std.mem.eql(u8, p.path, path)) {
                p.deinit(alloc);
                self.player = null;
            }
        }
        if (self.player == null) {
            // A path the config could not resolve is left blank, its error
            // reported then (`Path.expand`).
            if (!std.fs.path.isAbsolute(path)) return;
            // As GTK's `fromFilename`: a file that cannot be read is
            // logged, whether or not it is required, and nothing plays.
            std.Io.Dir.accessAbsolute(global.io(), path, .{ .read = true }) catch |err| {
                log.warn("unable to access {s} err={t}", .{ path, err });
                return;
            };
            const mf = self.start() orelse return;
            self.player = Player.init(alloc, mf, path, required) catch |err| {
                log.warn("bell audio: cannot play {s} err={t}", .{ path, err });
                return;
            };
        }
        self.player.?.play(std.math.clamp(volume, 0.0, 1.0));
    }
};

/// One engine, with its source set to `path`; in tests, a record of one
/// (`test_record`).
const Player = struct {
    engine: if (builtin.is_test) void else *IMFMediaEngine,
    path: [:0]u8,
    required: bool,

    /// MediaFailed: a call that failed, logged with its HRESULT;
    /// Win32CallFailed: the path could not be made UTF-16, logged too.
    const InitError = error{ MediaFailed, OutOfMemory, Win32CallFailed };

    fn init(alloc: Allocator, mf: Mf, path: [:0]const u8, required: bool) InitError!Player {
        const copy = try alloc.dupeSentinel(u8, path, 0);
        errdefer alloc.free(copy);
        if (builtin.is_test) {
            test_record.inits += 1;
            if (test_record.fail_init) |err| return err;
            return .{ .engine = {}, .path = copy, .required = required };
        }

        const notify = try Notify.create(path, required);
        // The engine's attributes hold it from here, and the engine.
        defer _ = notify.vtable.Release(notify);

        var attrs_out: ?*IMFAttributes = null;
        try check(mf.MFCreateAttributes(&attrs_out, 1), "MFCreateAttributes");
        const attrs = attrs_out orelse return error.MediaFailed;
        defer _ = attrs.vtable.Release(attrs);
        try check(attrs.vtable.SetUnknown(attrs, &MF_MEDIA_ENGINE_CALLBACK, notify), "SetUnknown");

        var factory_out: ?*anyopaque = null;
        try check(win32.CoCreateInstance(
            &CLSID_MFMediaEngineClassFactory,
            null,
            win32.CLSCTX_INPROC_SERVER,
            &IID_IMFMediaEngineClassFactory,
            &factory_out,
        ), "CoCreateInstance");
        const factory: *IMFMediaEngineClassFactory = @ptrCast(@alignCast(factory_out orelse return error.MediaFailed));
        defer _ = factory.vtable.Release(factory);

        var engine_out: ?*IMFMediaEngine = null;
        try check(factory.vtable.CreateInstance(factory, MF_MEDIA_ENGINE_AUDIOONLY, attrs, &engine_out), "CreateInstance");
        const engine = engine_out orelse return error.MediaFailed;
        errdefer {
            _ = engine.vtable.Shutdown(engine);
            _ = engine.vtable.Release(engine);
        }

        // The engine copies the URL: a path is one, as a file's.
        const wide = wideFromUtf8(alloc, path) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Win32CallFailed,
        };
        defer alloc.free(wide);
        const url = win32.SysAllocString(wide.ptr) orelse return error.OutOfMemory;
        defer win32.SysFreeString(url);
        try check(engine.vtable.SetSource(engine, url), "SetSource");

        log.debug("bell audio: source {s} required={}", .{ path, required });
        return .{ .engine = engine, .path = copy, .required = required };
    }

    fn deinit(self: *Player, alloc: Allocator) void {
        alloc.free(self.path);
        if (builtin.is_test) {
            test_record.deinits += 1;
            return;
        }
        _ = self.engine.vtable.Shutdown(self.engine);
        _ = self.engine.vtable.Release(self.engine);
    }

    /// From the start at `volume`. Before the source has loaded there is
    /// no time to seek to, and the engine plays it from the start once it
    /// has, so a failed seek is not a failure.
    fn play(self: *Player, volume: f64) void {
        if (builtin.is_test) {
            const t = &test_record;
            t.plays += 1;
            t.path_len = @min(self.path.len, t.path.len);
            @memcpy(t.path[0..t.path_len], self.path[0..t.path_len]);
            t.required = self.required;
            t.volume = volume;
            return;
        }
        const e = self.engine;
        check(e.vtable.SetVolume(e, volume), "SetVolume") catch {};
        _ = e.vtable.SetCurrentTime(e, 0);
        check(e.vtable.Play(e), "Play") catch {};
    }
};

test "win32: the media engine's interfaces have the headers' slots" {
    // mfobjects.h: IMFAttributesVtbl, IUnknown's 3 and its own 30.
    // mfmediaengine.h: IMFMediaEngineClassFactoryVtbl, 3 and 3;
    // IMFMediaEngineVtbl, 3 and 42; IMFMediaEngineNotifyVtbl, 3 and 1.
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(33 * p, @sizeOf(IMFAttributes.VTable));
    try testing.expectEqual(2 * p, @offsetOf(IMFAttributes.VTable, "Release"));
    try testing.expectEqual(27 * p, @offsetOf(IMFAttributes.VTable, "SetUnknown"));

    try testing.expectEqual(6 * p, @sizeOf(IMFMediaEngineClassFactory.VTable));
    try testing.expectEqual(2 * p, @offsetOf(IMFMediaEngineClassFactory.VTable, "Release"));
    try testing.expectEqual(3 * p, @offsetOf(IMFMediaEngineClassFactory.VTable, "CreateInstance"));

    try testing.expectEqual(45 * p, @sizeOf(IMFMediaEngine.VTable));
    try testing.expectEqual(2 * p, @offsetOf(IMFMediaEngine.VTable, "Release"));
    try testing.expectEqual(6 * p, @offsetOf(IMFMediaEngine.VTable, "SetSource"));
    try testing.expectEqual(17 * p, @offsetOf(IMFMediaEngine.VTable, "SetCurrentTime"));
    try testing.expectEqual(32 * p, @offsetOf(IMFMediaEngine.VTable, "Play"));
    try testing.expectEqual(37 * p, @offsetOf(IMFMediaEngine.VTable, "SetVolume"));
    try testing.expectEqual(42 * p, @offsetOf(IMFMediaEngine.VTable, "Shutdown"));

    try testing.expectEqual(4 * p, @sizeOf(Notify.VTable));
    try testing.expectEqual(3 * p, @offsetOf(Notify.VTable, "EventNotify"));
}

test "win32: the media engine's class and interface ids" {
    const testing = std.testing;
    try testing.expectEqual(0xb44392da, CLSID_MFMediaEngineClassFactory.Data1);
    try testing.expectEqual(0xd5, CLSID_MFMediaEngineClassFactory.Data4[7]);
    try testing.expectEqual(0x4d645ace, IID_IMFMediaEngineClassFactory.Data1);
    try testing.expectEqual(0x93, IID_IMFMediaEngineClassFactory.Data4[7]);
    try testing.expectEqual(0xfee7c112, IID_IMFMediaEngineNotify.Data1);
    try testing.expectEqual(0xd5, IID_IMFMediaEngineNotify.Data4[7]);
    try testing.expectEqual(0xc60381b8, MF_MEDIA_ENGINE_CALLBACK.Data1);
    try testing.expectEqual(0xa9, MF_MEDIA_ENGINE_CALLBACK.Data4[7]);
    try testing.expectEqual(0x00020070, MF_VERSION);
}

test "win32: the bell's engine callback counts its references" {
    const testing = std.testing;
    const notify = try Notify.create("C:\\bell.wav", true);
    var out: ?*anyopaque = null;
    try testing.expectEqual(win32.S_OK, notify.vtable.QueryInterface(notify, &Notify.IID, &out));
    try testing.expectEqual(@as(?*anyopaque, notify), out);
    try testing.expectEqual(win32.S_OK, notify.vtable.QueryInterface(notify, &win32.IID_IAgileObject, &out));
    try testing.expectEqual(3, notify.refs.load(.monotonic));
    // An engine's own interface is not the callback's.
    try testing.expectEqual(win32.E_NOINTERFACE, notify.vtable.QueryInterface(notify, &IID_IMFMediaEngineClassFactory, &out));
    try testing.expectEqual(null, out);
    try testing.expectEqualStrings("C:\\bell.wav", notify.sourcePath());
    // Every event is taken, those it does not know too.
    for ([_]DWORD{ 5, 13, 19, 1, 1016 }) |event| {
        try testing.expectEqual(win32.S_OK, notify.vtable.EventNotify(notify, event, 4, 0x80070002));
    }
    try testing.expectEqual(2, notify.vtable.Release(notify));
    try testing.expectEqual(1, notify.vtable.Release(notify));
    try testing.expectEqual(0, notify.vtable.Release(notify));
}

/// For tests: a directory with `names` in it, empty files, and their
/// absolute paths.
const TestFiles = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,

    fn init(alloc: Allocator, names: []const []const u8) !TestFiles {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (names) |name| try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "" });
        return .{ .tmp = tmp, .dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc) };
    }

    fn deinit(self: *TestFiles, alloc: Allocator) void {
        alloc.free(self.dir);
        self.tmp.cleanup();
    }

    fn path(self: *const TestFiles, alloc: Allocator, name: []const u8) ![:0]u8 {
        return std.fs.path.joinZ(alloc, &.{ self.dir, name });
    }
};

test "win32: the bell keeps one player while its path and required stay, and starts Media Foundation once" {
    // GTK's `bellMediaFile` keeps one file for the path it played; here a
    // change to `required` makes another too, as it is the player's
    // callback that logs a required file's errors. A path that is not
    // absolute, as the config leaves one it could not resolve, or that
    // cannot be read, plays nothing, and makes nothing.
    const testing = std.testing;
    const alloc = testing.allocator;
    var files: TestFiles = try .init(alloc, &.{ "a.wav", "b.mp3" });
    defer files.deinit(alloc);
    const a = try files.path(alloc, "a.wav");
    defer alloc.free(a);
    const b = try files.path(alloc, "b.mp3");
    defer alloc.free(b);
    const missing = try files.path(alloc, "missing.wav");
    defer alloc.free(missing);
    test_record = .{};

    var bell: Bell = .{};
    defer bell.deinit(alloc);
    bell.ring(alloc, a, true, 0.5);
    try testing.expectEqual(0.5, test_record.volume);
    bell.ring(alloc, a, true, 2);
    try testing.expectEqual(1, test_record.loads);
    try testing.expectEqual(1, test_record.startups);
    try testing.expectEqual(1, test_record.inits);
    try testing.expectEqual(0, test_record.deinits);
    try testing.expectEqual(2, test_record.plays);
    try testing.expectEqualStrings(a, test_record.lastPath());
    try testing.expect(test_record.required);
    try testing.expectEqual(1.0, test_record.volume);

    // Another path: another player, the old one destroyed first.
    bell.ring(alloc, b, true, -1);
    try testing.expectEqual(2, test_record.inits);
    try testing.expectEqual(1, test_record.deinits);
    try testing.expectEqual(3, test_record.plays);
    try testing.expectEqualStrings(b, test_record.lastPath());
    try testing.expectEqual(0.0, test_record.volume);

    // The same path, optional now: another.
    bell.ring(alloc, b, false, 1);
    try testing.expectEqual(3, test_record.inits);
    try testing.expectEqual(2, test_record.deinits);
    try testing.expect(!test_record.required);

    // Not absolute, or not there: the last player goes, none is made.
    bell.ring(alloc, "a.wav", false, 1);
    try testing.expectEqual(3, test_record.deinits);
    try testing.expect(bell.player == null);
    bell.ring(alloc, missing, false, 1);
    try testing.expectEqual(3, test_record.inits);
    try testing.expectEqual(4, test_record.plays);
    try testing.expect(bell.player == null);
    try testing.expectEqual(1, test_record.startups);

    // Quitting stops the player and Media Foundation, which a bell after
    // starts again, from the DLL loaded before.
    bell.ring(alloc, a, false, 1);
    bell.deinit(alloc);
    try testing.expectEqual(4, test_record.deinits);
    try testing.expectEqual(1, test_record.shutdowns);
    bell.ring(alloc, a, false, 1);
    try testing.expectEqual(1, test_record.loads);
    try testing.expectEqual(2, test_record.startups);
    try testing.expectEqual(5, test_record.inits);
    try testing.expectEqual(6, test_record.plays);
}

test "win32: without mfplat.dll, or a function of it, the bell plays nothing and tries once" {
    // The N and KN editions of Windows have no Media Foundation without
    // the Media Feature Pack: the bell is quiet there, and logs it once.
    const testing = std.testing;
    const alloc = testing.allocator;
    var files: TestFiles = try .init(alloc, &.{"a.wav"});
    defer files.deinit(alloc);
    const a = try files.path(alloc, "a.wav");
    defer alloc.free(a);
    test_record = .{};
    defer test_dll = mfplat;

    test_dll = .{ .name = "ghostty-no-such.dll", .wide = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-no-such.dll") };
    var none: Bell = .{};
    defer none.deinit(alloc);
    none.ring(alloc, a, true, 1);
    none.ring(alloc, a, true, 1);
    try testing.expect(none.mf == .missing);
    try testing.expectEqual(1, test_record.loads);

    // kernel32.dll, which every process has, has none of them.
    test_dll = .{ .name = "kernel32.dll", .wide = std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll") };
    var other: Bell = .{};
    defer other.deinit(alloc);
    other.ring(alloc, a, true, 1);
    other.ring(alloc, a, true, 1);
    try testing.expect(other.mf == .missing);
    try testing.expectEqual(2, test_record.loads);

    try testing.expectEqual(0, test_record.startups);
    try testing.expectEqual(0, test_record.inits);
    try testing.expectEqual(0, test_record.plays);
}

test "win32: a player that cannot be made plays nothing, and is made at the next bell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var files: TestFiles = try .init(alloc, &.{"a.wav"});
    defer files.deinit(alloc);
    const a = try files.path(alloc, "a.wav");
    defer alloc.free(a);
    test_record = .{ .fail_init = error.MediaFailed };

    var bell: Bell = .{};
    defer bell.deinit(alloc);
    bell.ring(alloc, a, true, 1);
    test_record.fail_init = error.OutOfMemory;
    bell.ring(alloc, a, true, 1);
    try testing.expectEqual(2, test_record.inits);
    try testing.expectEqual(0, test_record.plays);
    try testing.expect(bell.player == null);

    test_record.fail_init = null;
    bell.ring(alloc, a, true, 1);
    try testing.expectEqual(3, test_record.inits);
    try testing.expectEqual(1, test_record.plays);
    try testing.expectEqual(1, test_record.startups);
}
