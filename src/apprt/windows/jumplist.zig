//! The taskbar jump list's tasks, New Window and New Tab, as macOS's dock
//! menu has them (AppDelegate.reloadDockMenu). Each is a shell link that
//! runs this exe with the action (`+new-window`, `+new-tab`), which the
//! IPC client carries to the running instance, or starts one with.
//!
//! The list belongs to an AppUserModelID, the one App.init gives the
//! process (`toast.app_id`) and the installer's Start menu shortcut
//! carries: Explorer shows it on the buttons of that ID's windows and on
//! a pin of that shortcut. It is kept by Explorer, so it is committed once
//! per start (`commit`), which also replaces one an older version left.
//!
//! The interfaces are vtable structs in the order of the mingw headers Zig
//! ships (shobjidl.h, objectarray.h, propsys.h), as taskbar.zig's is: only
//! the methods called here are typed, every other slot is an untyped
//! pointer, and com_abi_test.zig checks them against the headers.

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const i18n = @import("../../os/main.zig").i18n;
const win32 = @import("win32.zig");

const HRESULT = win32.HRESULT;
const GUID = windows.GUID;
const LPCWSTR = win32.LPCWSTR;

const CLSID_DestinationList: GUID = GUID.parse("{77f10cf0-3db5-4966-b520-b7c54fd35ed6}");
const CLSID_EnumerableObjectCollection: GUID = GUID.parse("{2d3468c1-36a7-43b6-ac24-d3f02fd9607a}");
const CLSID_ShellLink: GUID = GUID.parse("{00021401-0000-0000-c000-000000000046}");
const IID_ICustomDestinationList: GUID = GUID.parse("{6332debf-87b5-4670-90c0-5e57b408a49e}");
const IID_IObjectArray: GUID = GUID.parse("{92ca9dcd-5622-4bba-a805-5e9f541bd8c9}");
const IID_IObjectCollection: GUID = GUID.parse("{5632b1a4-e38a-400a-928a-d4cd63230295}");
const IID_IShellLinkW: GUID = GUID.parse("{000214f9-0000-0000-c000-000000000046}");
const IID_IPropertyStore: GUID = GUID.parse("{886d8eeb-8cf2-4446-8d02-cdba1dbdcf99}");

/// PKEY_Title (propkey.h): a task's text in the list. A link's description
/// is only its tooltip.
const PKEY_Title: PROPERTYKEY = .{
    .fmtid = GUID.parse("{f29f85e0-4ff9-1068-ab91-08002b27b3d9}"),
    .pid = 2,
};

/// A task: its text, a msgid shown in the user's language, and the action
/// it runs this exe with.
pub const Task = struct {
    title: [:0]const u8,
    action: [:0]const u8,
};

/// The tasks, in the order the list shows them: the dock menu's.
pub const tasks = [_]Task{
    .{ .title = i18n.N_("New Window"), .action = "+new-window" },
    .{ .title = i18n.N_("New Tab"), .action = "+new-tab" },
};

pub const Error = error{ JumpListFailed, OutOfMemory };

/// Replace `app_id`'s jump list with `entries` (`tasks`, but in tests),
/// each running `exe`. On the thread that calls it, which must be in an apartment (CoInitializeEx).
/// A failure is logged by the call that failed and leaves the list as it
/// was.
pub fn commit(alloc: Allocator, app_id: LPCWSTR, exe: [:0]const u16, entries: []const Task) Error!void {
    const list = try create(ICustomDestinationList, &CLSID_DestinationList, "jumplist: CoCreateInstance DestinationList");
    defer list.release();
    try win32.checkHr(list.vtable.SetAppID(list, app_id), error.JumpListFailed, "jumplist: SetAppID");

    // The removed destinations are files and folders a user took out of
    // the list; it has none of those, only tasks.
    var min_slots: win32.UINT = 0;
    var removed: ?*anyopaque = null;
    try win32.checkHr(list.vtable.BeginList(list, &min_slots, &IID_IObjectArray, &removed), error.JumpListFailed, "jumplist: BeginList");
    if (removed) |r| @as(*IObjectArray, @ptrCast(@alignCast(r))).release();
    errdefer win32.checkHr(list.vtable.AbortList(list), error.JumpListFailed, "jumplist: AbortList") catch {};

    const collection = try create(IObjectCollection, &CLSID_EnumerableObjectCollection, "jumplist: CoCreateInstance EnumerableObjectCollection");
    defer collection.release();
    for (entries) |task| {
        const link = try shellLink(alloc, exe, task);
        defer link.release();
        try win32.checkHr(collection.vtable.AddObject(collection, link), error.JumpListFailed, "jumplist: AddObject");
    }

    try win32.checkHr(list.vtable.AddUserTasks(list, collection.array()), error.JumpListFailed, "jumplist: AddUserTasks");
    try win32.checkHr(list.vtable.CommitList(list), error.JumpListFailed, "jumplist: CommitList");
}

/// Remove `app_id`'s jump list, as a test does after committing one.
pub fn delete(app_id: LPCWSTR) Error!void {
    const list = try create(ICustomDestinationList, &CLSID_DestinationList, "jumplist: CoCreateInstance DestinationList");
    defer list.release();
    try win32.checkHr(list.vtable.DeleteList(list, app_id), error.JumpListFailed, "jumplist: DeleteList");
}

/// A new object of class `clsid`, as its interface `T`; one reference,
/// the caller's.
fn create(comptime T: type, clsid: *const GUID, comptime what: []const u8) Error!*T {
    var out: ?*anyopaque = null;
    try win32.checkHr(win32.CoCreateInstance(clsid, null, win32.CLSCTX_INPROC_SERVER, &T.IID, &out), error.JumpListFailed, what);
    return @ptrCast(@alignCast(out orelse return error.JumpListFailed));
}

/// `task` as a shell link running `exe` with its action, with the exe's
/// icon and its title in the user's language.
fn shellLink(alloc: Allocator, exe: [:0]const u16, task: Task) Error!*IShellLinkW {
    const link = try create(IShellLinkW, &CLSID_ShellLink, "jumplist: CoCreateInstance ShellLink");
    errdefer link.release();

    const action = try wide(alloc, task.action);
    defer alloc.free(action);
    const title = try wide(alloc, std.mem.span(i18n._(task.title)));
    defer alloc.free(title);

    try win32.checkHr(link.vtable.SetPath(link, exe.ptr), error.JumpListFailed, "jumplist: SetPath");
    try win32.checkHr(link.vtable.SetArguments(link, action.ptr), error.JumpListFailed, "jumplist: SetArguments");
    try win32.checkHr(link.vtable.SetIconLocation(link, exe.ptr, 0), error.JumpListFailed, "jumplist: SetIconLocation");
    try win32.checkHr(link.vtable.SetDescription(link, title.ptr), error.JumpListFailed, "jumplist: SetDescription");

    var out: ?*anyopaque = null;
    try win32.checkHr(link.vtable.QueryInterface(link, &IID_IPropertyStore, &out), error.JumpListFailed, "jumplist: QueryInterface IPropertyStore");
    const store: *IPropertyStore = @ptrCast(@alignCast(out orelse return error.JumpListFailed));
    defer store.release();
    // The value points at `title`, which outlives the store's copy of it:
    // SetValue copies, so it is not cleared (PropVariantClear) here.
    const value: PROPVARIANT = .{ .vt = VT_LPWSTR, .value = .{ .pwszVal = title.ptr } };
    try win32.checkHr(store.vtable.SetValue(store, &PKEY_Title, &value), error.JumpListFailed, "jumplist: SetValue PKEY_Title");
    try win32.checkHr(store.vtable.Commit(store), error.JumpListFailed, "jumplist: Commit");
    return link;
}

/// `text` as UTF-16. Valid UTF-8: the source's is, and a catalog is not
/// used unless all of it is (`i18n.windows.use`).
fn wide(alloc: Allocator, text: []const u8) error{OutOfMemory}![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => unreachable,
    };
}

/// An untyped vtable slot, there so that the slots after it keep their
/// index.
const Slot = *const anyopaque;

pub const ICustomDestinationList = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ICustomDestinationList;

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*ICustomDestinationList) callconv(.winapi) windows.ULONG,
        SetAppID: *const fn (*ICustomDestinationList, LPCWSTR) callconv(.winapi) HRESULT,
        BeginList: *const fn (*ICustomDestinationList, *win32.UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AppendCategory: Slot,
        AppendKnownCategory: Slot,
        AddUserTasks: *const fn (*ICustomDestinationList, *IObjectArray) callconv(.winapi) HRESULT,
        CommitList: *const fn (*ICustomDestinationList) callconv(.winapi) HRESULT,
        GetRemovedDestinations: Slot,
        DeleteList: *const fn (*ICustomDestinationList, LPCWSTR) callconv(.winapi) HRESULT,
        AbortList: *const fn (*ICustomDestinationList) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICustomDestinationList) void {
        _ = self.vtable.Release(self);
    }
};

pub const IObjectArray = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IObjectArray;

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IObjectArray) callconv(.winapi) windows.ULONG,
        GetCount: Slot,
        GetAt: Slot,
    };

    pub fn release(self: *IObjectArray) void {
        _ = self.vtable.Release(self);
    }
};

pub const IObjectCollection = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IObjectCollection;

    /// IObjectArray's slots, then its own.
    pub const VTable = extern struct {
        base: IObjectArray.VTable,
        AddObject: *const fn (*IObjectCollection, *anyopaque) callconv(.winapi) HRESULT,
        AddFromArray: Slot,
        RemoveObjectAt: Slot,
        Clear: Slot,
    };

    pub fn release(self: *IObjectCollection) void {
        self.array().release();
    }

    /// The same object as the IObjectArray it derives from: its vtable
    /// begins with that one's.
    pub fn array(self: *IObjectCollection) *IObjectArray {
        return @ptrCast(self);
    }
};

pub const IShellLinkW = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IShellLinkW;

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Slot,
        Release: *const fn (*IShellLinkW) callconv(.winapi) windows.ULONG,
        GetPath: Slot,
        GetIDList: Slot,
        SetIDList: Slot,
        GetDescription: Slot,
        SetDescription: *const fn (*IShellLinkW, LPCWSTR) callconv(.winapi) HRESULT,
        GetWorkingDirectory: Slot,
        SetWorkingDirectory: Slot,
        GetArguments: Slot,
        SetArguments: *const fn (*IShellLinkW, LPCWSTR) callconv(.winapi) HRESULT,
        GetHotkey: Slot,
        SetHotkey: Slot,
        GetShowCmd: Slot,
        SetShowCmd: Slot,
        GetIconLocation: Slot,
        SetIconLocation: *const fn (*IShellLinkW, LPCWSTR, c_int) callconv(.winapi) HRESULT,
        SetRelativePath: Slot,
        Resolve: Slot,
        SetPath: *const fn (*IShellLinkW, LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IShellLinkW) void {
        _ = self.vtable.Release(self);
    }
};

pub const IPropertyStore = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IPropertyStore;

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IPropertyStore) callconv(.winapi) windows.ULONG,
        GetCount: Slot,
        GetAt: Slot,
        GetValue: Slot,
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
        Commit: *const fn (*IPropertyStore) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IPropertyStore) void {
        _ = self.vtable.Release(self);
    }
};

pub const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: windows.DWORD,
};

/// VARENUM's VT_LPWSTR (wtypes.h): a PROPVARIANT holding a string.
const VT_LPWSTR: u16 = 31;

/// PROPVARIANT (propidl.h), with the one member of its value union used
/// here. Not public, so com_abi does not compare it with the header's,
/// whose nesting of nameless unions and structs it cannot follow; the
/// tests below check its size and the string's offset instead. The
/// union's largest members (a DECIMAL, which overlays the whole value, and
/// the counted arrays: a count and a pointer) make it 16 bytes on a 64-bit
/// target, 8 on a 32-bit one.
const PROPVARIANT = extern struct {
    vt: u16,
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    value: extern union {
        pwszVal: LPCWSTR,
        size: [2]usize,
    },
};

test "win32: the jump list's interfaces have the header's slots" {
    // The Vtbl structs of shobjidl.h, objectarray.h and propsys.h:
    // IUnknown's 3 and each interface's own.
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(12 * p, @sizeOf(ICustomDestinationList.VTable));
    try testing.expectEqual(5 * p, @sizeOf(IObjectArray.VTable));
    try testing.expectEqual(9 * p, @sizeOf(IObjectCollection.VTable));
    try testing.expectEqual(21 * p, @sizeOf(IShellLinkW.VTable));
    try testing.expectEqual(8 * p, @sizeOf(IPropertyStore.VTable));
    try testing.expectEqual(5 * p, @offsetOf(IObjectCollection.VTable, "AddObject"));
}

test "win32: the jump list's PROPVARIANT is the header's size" {
    const testing = std.testing;
    try testing.expectEqual(8 + 2 * @sizeOf(usize), @sizeOf(PROPVARIANT));
    try testing.expectEqual(8, @offsetOf(PROPVARIANT, "value"));
    try testing.expectEqual(20, @sizeOf(PROPERTYKEY));
}

test "win32: the jump list's class, interface and property ids" {
    const testing = std.testing;
    try testing.expectEqual(0x77f10cf0, CLSID_DestinationList.Data1);
    try testing.expectEqual(0xd6, CLSID_DestinationList.Data4[7]);
    try testing.expectEqual(0x2d3468c1, CLSID_EnumerableObjectCollection.Data1);
    try testing.expectEqual(0x7a, CLSID_EnumerableObjectCollection.Data4[7]);
    try testing.expectEqual(0x00021401, CLSID_ShellLink.Data1);
    try testing.expectEqual(0x46, CLSID_ShellLink.Data4[7]);
    try testing.expectEqual(0x6332debf, IID_ICustomDestinationList.Data1);
    try testing.expectEqual(0x9e, IID_ICustomDestinationList.Data4[7]);
    try testing.expectEqual(0x92ca9dcd, IID_IObjectArray.Data1);
    try testing.expectEqual(0xc9, IID_IObjectArray.Data4[7]);
    try testing.expectEqual(0x5632b1a4, IID_IObjectCollection.Data1);
    try testing.expectEqual(0x95, IID_IObjectCollection.Data4[7]);
    try testing.expectEqual(0x000214f9, IID_IShellLinkW.Data1);
    try testing.expectEqual(0x46, IID_IShellLinkW.Data4[7]);
    try testing.expectEqual(0x886d8eeb, IID_IPropertyStore.Data1);
    try testing.expectEqual(0x99, IID_IPropertyStore.Data4[7]);
    try testing.expectEqual(0xf29f85e0, PKEY_Title.fmtid.Data1);
    try testing.expectEqual(0xd9, PKEY_Title.fmtid.Data4[7]);
}

/// How many of the files where Explorer keeps the jump lists
/// (%APPDATA%\Microsoft\Windows\Recent\CustomDestinations, one a list)
/// hold `text`, as UTF-16, which is how a link's arguments and its
/// title are stored there. For tests: it reads with `std.testing.io`.
pub fn listsHolding(alloc: Allocator, text: []const u8) !usize {
    const io = std.testing.io;
    var buf: [win32.MAX_PATH]u16 = undefined;
    const len = win32.GetEnvironmentVariableW(win32.L("APPDATA"), &buf, buf.len);
    if (len == 0 or len >= buf.len) return error.NoAppData;
    const appdata = try std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]);
    defer alloc.free(appdata);
    const path = try std.fs.path.join(alloc, &.{ appdata, "Microsoft", "Windows", "Recent", "CustomDestinations" });
    defer alloc.free(path);
    const text16 = try wide(alloc, text);
    defer alloc.free(text16);
    const needle = std.mem.sliceAsBytes(text16);

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        // None committed yet on this account.
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try dir.readFileAlloc(io, entry.name, alloc, .limited(16 << 20));
        defer alloc.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) n += 1;
    }
    return n;
}

test "win32: a jump list is committed for its app id, and deleted" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // An app id no install uses, and a task no list but this one has,
    // whose title and arguments are told apart.
    const id = win32.L("com.mitchellh.ghostty.test-jumplist");
    const title = "ghostty-test-jumplist-title";
    const arg = "ghostty-test-jumplist-arg";
    const entries = [_]Task{.{ .title = title, .action = "+new-window --title=" ++ arg }};
    const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) win32.CoUninitialize();
    const exe = try @import("IpcClient.zig").imagePath(alloc);
    defer alloc.free(exe);

    try delete(id);
    try testing.expectEqual(0, try listsHolding(alloc, arg));
    try commit(alloc, id, exe, &entries);
    try testing.expectEqual(1, try listsHolding(alloc, arg));
    try testing.expectEqual(1, try listsHolding(alloc, title));
    try delete(id);
    try testing.expectEqual(0, try listsHolding(alloc, arg));
}
