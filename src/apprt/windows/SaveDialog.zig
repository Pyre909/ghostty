//! The Save dialog for a text file: the common item dialog
//! (IFileSaveDialog), which GTK's FileChooserNative shows on Windows too,
//! as the macOS app shows an NSSavePanel. It asks where the inspector's
//! terminal IO events go (`App.exportQueued`).
//!
//! IFileDialog::Show, as MessageBoxW does, disables its owner and runs its
//! own message loop until the dialog ends, so it is run as
//! `dialog.messageBox` runs MessageBoxW: inside `App.beginPrompt` and
//! `App.endPrompt`, owned by `App.promptOwner`, and answered Cancel with
//! no dialog once the windows close for good (`App.terminating`).
//!
//! The interfaces are vtable structs in the order of the mingw header Zig
//! ships (lib/libc/include/any-windows-any/shobjidl.h), as taskbar.zig's
//! is: only the methods called here are typed, every other slot is an
//! untyped pointer, and the tests check the slot counts and the typed
//! slots' indices against the header, and call the typed ones on a dialog
//! that is never shown.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;

const log = std.log.scoped(.win32);

const HRESULT = win32.HRESULT;
const HWND = windows.HWND;
const GUID = windows.GUID;
const LPCWSTR = win32.LPCWSTR;

const CLSID_FileSaveDialog: GUID = GUID.parse("{c0b4e2f3-ba21-4773-8dba-335ec946eb8b}");
const IID_IFileSaveDialog: GUID = GUID.parse("{84bccd23-5fde-4cdb-aea4-af64b83d78ab}");
const IID_IShellItem: GUID = GUID.parse("{43826d1e-e718-42ee-bc55-a1e261c37bfe}");

/// HRESULT_FROM_WIN32(ERROR_CANCELLED) (winerror.h): what Show returns
/// when the user closes the dialog with no file.
const cancelled_hr: HRESULT = @bitCast(@as(u32, 0x800704C7));

/// SIGDN_FILESYSPATH (shobjidl.h): an item's path in the file system. The
/// header's SIGDN is an enum of int; this one does not fit an i32 as a
/// positive number, and only its 32 bits matter.
const SIGDN_FILESYSPATH: u32 = 0x80058000;

/// What the dialog shows.
pub const Spec = struct {
    /// The title bar's text.
    title: LPCWSTR,
    /// The file name it suggests.
    name: LPCWSTR,
    /// The label of the button that saves.
    ok: LPCWSTR,
};

/// The user's answer.
pub const Answer = union(enum) {
    /// The dialog was closed with no file.
    cancelled,
    /// The dialog could not be shown, or gave no path; logged.
    failed,
    /// The file chosen, in the app's allocator, the caller's to free. It
    /// may exist: the dialog has asked whether to replace it.
    path: [:0]u16,
};

/// For tests: answers in place of the dialog in `ask`, given its owner and
/// what it would show, as `dialog.test_message_box` stands for MessageBoxW,
/// so that a test sees the prompt without a modal loop. A path it answers
/// must be in the app's allocator.
pub var test_ask: if (builtin.is_test) ?*const fn (?HWND, Spec) Answer else void =
    if (builtin.is_test) null else {};

/// Ask where to save a text file, from `hwnd`'s window.
pub fn ask(app: *App, hwnd: ?HWND, spec: Spec) Answer {
    if (app.terminating) {
        log.warn("a Save dialog while the windows close is answered Cancel", .{});
        return .cancelled;
    }
    const owner = app.promptOwner(hwnd);
    app.beginPrompt(owner);
    defer app.endPrompt();
    if (builtin.is_test) if (test_ask) |answer| return answer(owner, spec);
    return show(app.core_app.alloc, owner, spec);
}

/// The dialog itself: made, prepared, shown and released.
fn show(alloc: Allocator, owner: ?HWND, spec: Spec) Answer {
    const dlg = create() catch return .failed;
    defer dlg.release();
    dlg.prepare(spec) catch return .failed;
    const shown = dlg.vtable.Show(dlg, owner);
    if (shown < 0) {
        const answer = answerOf(shown);
        if (answer == .failed) log.warn("save dialog: Show failed hr=0x{x}", .{@as(u32, @bitCast(shown))});
        return answer;
    }
    const path = dlg.chosen(alloc) catch |err| switch (err) {
        error.SaveDialogFailed => return .failed,
        error.OutOfMemory => {
            log.warn("save dialog: no memory for the chosen path", .{});
            return .failed;
        },
    };
    return .{ .path = path };
}

/// What a failed Show means: the user's cancel, or a dialog that failed.
fn answerOf(hr: HRESULT) Answer {
    return if (hr == cancelled_hr) .cancelled else .failed;
}

fn check(hr: HRESULT, what: []const u8) error{SaveDialogFailed}!void {
    if (hr >= 0) return;
    log.warn("save dialog: {s} failed hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
    return error.SaveDialogFailed;
}

/// A Save dialog, one reference, the caller's; on a thread in a
/// single-threaded apartment, as the UI thread is (`App.init`).
fn create() error{SaveDialogFailed}!*IFileSaveDialog {
    var out: ?*anyopaque = null;
    try check(win32.CoCreateInstance(
        &CLSID_FileSaveDialog,
        null,
        win32.CLSCTX_INPROC_SERVER,
        &IID_IFileSaveDialog,
        &out,
    ), "CoCreateInstance");
    return @ptrCast(@alignCast(out orelse return error.SaveDialogFailed));
}

/// COMDLG_FILTERSPEC (shtypes.h): a file type the dialog offers.
const FilterSpec = extern struct {
    name: LPCWSTR,
    spec: LPCWSTR,
};

/// Plain text first, the type the macOS app allows; all files second, for
/// a name with another extension.
const file_types = [_]FilterSpec{
    .{ .name = L("Text files"), .spec = L("*.txt") },
    .{ .name = L("All files"), .spec = L("*.*") },
};

/// An untyped vtable slot, there so that the slots after it keep their
/// index.
const Slot = *const anyopaque;

pub const IFileSaveDialog = extern struct {
    vtable: *const VTable,

    /// IUnknown, IModalWindow, IFileDialog and IFileSaveDialog, flattened.
    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IFileSaveDialog) callconv(.winapi) windows.ULONG,
        Show: *const fn (*IFileSaveDialog, ?HWND) callconv(.winapi) HRESULT,
        SetFileTypes: *const fn (*IFileSaveDialog, windows.UINT, [*]const FilterSpec) callconv(.winapi) HRESULT,
        SetFileTypeIndex: *const fn (*IFileSaveDialog, windows.UINT) callconv(.winapi) HRESULT,
        GetFileTypeIndex: *const fn (*IFileSaveDialog, *windows.UINT) callconv(.winapi) HRESULT,
        Advise: Slot,
        Unadvise: Slot,
        SetOptions: *const fn (*IFileSaveDialog, windows.DWORD) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*IFileSaveDialog, *windows.DWORD) callconv(.winapi) HRESULT,
        SetDefaultFolder: Slot,
        SetFolder: Slot,
        GetFolder: Slot,
        GetCurrentSelection: Slot,
        SetFileName: *const fn (*IFileSaveDialog, LPCWSTR) callconv(.winapi) HRESULT,
        /// The name is the caller's to free (CoTaskMemFree).
        GetFileName: *const fn (*IFileSaveDialog, *?[*:0]u16) callconv(.winapi) HRESULT,
        SetTitle: *const fn (*IFileSaveDialog, LPCWSTR) callconv(.winapi) HRESULT,
        SetOkButtonLabel: *const fn (*IFileSaveDialog, LPCWSTR) callconv(.winapi) HRESULT,
        SetFileNameLabel: Slot,
        GetResult: *const fn (*IFileSaveDialog, *?*IShellItem) callconv(.winapi) HRESULT,
        AddPlace: Slot,
        SetDefaultExtension: *const fn (*IFileSaveDialog, LPCWSTR) callconv(.winapi) HRESULT,
        Close: Slot,
        SetClientGuid: Slot,
        ClearClientData: Slot,
        SetFilter: Slot,
        SetSaveAsItem: Slot,
        SetProperties: Slot,
        SetCollectedProperties: Slot,
        GetProperties: Slot,
        ApplyProperties: Slot,
    };

    pub fn release(self: *IFileSaveDialog) void {
        _ = self.vtable.Release(self);
    }

    /// Give the dialog `spec`'s texts and the text file types, with "txt"
    /// added to a name typed with no extension. No folder is set, as GTK
    /// and the macOS app set none: the dialog opens where it last saved.
    /// The options are a Save dialog's defaults, which ask before
    /// replacing a file, and only items with a path in the file system.
    fn prepare(self: *IFileSaveDialog, spec: Spec) error{SaveDialogFailed}!void {
        var options: windows.DWORD = 0;
        try check(self.vtable.GetOptions(self, &options), "GetOptions");
        try check(self.vtable.SetOptions(self, options | win32.FOS_FORCEFILESYSTEM), "SetOptions");
        try check(self.vtable.SetFileTypes(self, file_types.len, &file_types), "SetFileTypes");
        try check(self.vtable.SetDefaultExtension(self, L("txt")), "SetDefaultExtension");
        try check(self.vtable.SetFileName(self, spec.name), "SetFileName");
        try check(self.vtable.SetTitle(self, spec.title), "SetTitle");
        try check(self.vtable.SetOkButtonLabel(self, spec.ok), "SetOkButtonLabel");
    }

    /// The file the user chose, after a Show that succeeded, in `alloc`.
    fn chosen(self: *IFileSaveDialog, alloc: Allocator) error{ SaveDialogFailed, OutOfMemory }![:0]u16 {
        var out: ?*IShellItem = null;
        try check(self.vtable.GetResult(self, &out), "GetResult");
        const item = out orelse return error.SaveDialogFailed;
        defer item.release();
        return item.path(alloc);
    }
};

pub const IShellItem = extern struct {
    vtable: *const VTable,

    /// IUnknown and IShellItem, flattened.
    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IShellItem) callconv(.winapi) windows.ULONG,
        BindToHandler: Slot,
        GetParent: Slot,
        /// The name is the caller's to free (CoTaskMemFree).
        GetDisplayName: *const fn (*IShellItem, u32, *?[*:0]u16) callconv(.winapi) HRESULT,
        GetAttributes: Slot,
        Compare: Slot,
    };

    pub fn release(self: *IShellItem) void {
        _ = self.vtable.Release(self);
    }

    /// The item's path in the file system, in `alloc`.
    fn path(self: *IShellItem, alloc: Allocator) error{ SaveDialogFailed, OutOfMemory }![:0]u16 {
        var name: ?[*:0]u16 = null;
        try check(self.vtable.GetDisplayName(self, SIGDN_FILESYSPATH, &name), "GetDisplayName");
        const got = name orelse return error.SaveDialogFailed;
        defer win32.CoTaskMemFree(@ptrCast(got));
        return alloc.dupeSentinel(u16, std.mem.span(got), 0);
    }
};

test "win32: IFileSaveDialog and IShellItem have the header's slots" {
    // IFileSaveDialogVtbl in shobjidl.h: IUnknown's 3, IModalWindow's 1,
    // IFileDialog's 23 and its own 5. IShellItemVtbl: IUnknown's 3 and its
    // own 5.
    const testing = std.testing;
    const p = @sizeOf(usize);
    const V = IFileSaveDialog.VTable;
    try testing.expectEqual(32 * p, @sizeOf(V));
    try testing.expectEqual(2 * p, @offsetOf(V, "Release"));
    try testing.expectEqual(3 * p, @offsetOf(V, "Show"));
    try testing.expectEqual(4 * p, @offsetOf(V, "SetFileTypes"));
    try testing.expectEqual(5 * p, @offsetOf(V, "SetFileTypeIndex"));
    try testing.expectEqual(6 * p, @offsetOf(V, "GetFileTypeIndex"));
    try testing.expectEqual(9 * p, @offsetOf(V, "SetOptions"));
    try testing.expectEqual(10 * p, @offsetOf(V, "GetOptions"));
    try testing.expectEqual(15 * p, @offsetOf(V, "SetFileName"));
    try testing.expectEqual(16 * p, @offsetOf(V, "GetFileName"));
    try testing.expectEqual(17 * p, @offsetOf(V, "SetTitle"));
    try testing.expectEqual(18 * p, @offsetOf(V, "SetOkButtonLabel"));
    try testing.expectEqual(20 * p, @offsetOf(V, "GetResult"));
    try testing.expectEqual(22 * p, @offsetOf(V, "SetDefaultExtension"));

    try testing.expectEqual(8 * p, @sizeOf(IShellItem.VTable));
    try testing.expectEqual(2 * p, @offsetOf(IShellItem.VTable, "Release"));
    try testing.expectEqual(5 * p, @offsetOf(IShellItem.VTable, "GetDisplayName"));

    // COMDLG_FILTERSPEC in shtypes.h: two strings.
    try testing.expectEqual(2 * p, @sizeOf(FilterSpec));
}

test "win32: the Save dialog's class and interface ids" {
    const testing = std.testing;
    try testing.expectEqual(0xc0b4e2f3, CLSID_FileSaveDialog.Data1);
    try testing.expectEqual(0x8b, CLSID_FileSaveDialog.Data4[7]);
    try testing.expectEqual(0x84bccd23, IID_IFileSaveDialog.Data1);
    try testing.expectEqual(0xab, IID_IFileSaveDialog.Data4[7]);
    try testing.expectEqual(0x43826d1e, IID_IShellItem.Data1);
    try testing.expectEqual(0xfe, IID_IShellItem.Data4[7]);
}

test "win32: the Save dialog keeps what it is given, unshown" {
    // The real object, made and prepared as `show` does, and read back
    // through the typed slots; a wrong slot, id or signature fails here.
    // Show is never called: it would wait for a user. The calls run on a
    // thread of their own, in a single-threaded apartment as the UI
    // thread's is, so that the test runner's thread keeps its own.
    const testing = std.testing;
    const alloc = testing.allocator;
    const marker = "the file the item was made from";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "io.txt", .data = marker });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir);
    const file = try std.fs.path.join(alloc, &.{ dir, "io.txt" });
    defer alloc.free(file);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, file);
    defer alloc.free(wide);

    const Unshown = struct {
        fn run(item_path: [:0]const u16, result: *anyerror!void) void {
            checks(item_path) catch |err| {
                // The trace is this thread's, so it is shown here, as the
                // test runner shows a test's.
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                result.* = err;
            };
        }

        fn checks(item_path: [:0]const u16) !void {
            const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
            try testing.expect(hr >= 0);
            defer win32.CoUninitialize();

            const dlg = try create();
            defer dlg.release();
            const name = L("ghostty-terminal-io.txt");
            try dlg.prepare(.{ .title = L("Title"), .name = name, .ok = L("Export") });

            // A Save dialog's defaults are kept, and only file-system items
            // are offered.
            var options: windows.DWORD = 0;
            try testing.expect(dlg.vtable.GetOptions(dlg, &options) >= 0);
            const defaults = win32.FOS_OVERWRITEPROMPT | win32.FOS_NOCHANGEDIR |
                win32.FOS_PATHMUSTEXIST | win32.FOS_NOREADONLYRETURN;
            try testing.expectEqual(defaults, options & defaults);
            try testing.expect((options & win32.FOS_FORCEFILESYSTEM) != 0);

            var got: ?[*:0]u16 = null;
            try testing.expect(dlg.vtable.GetFileName(dlg, &got) >= 0);
            const named = got orelse return error.TestUnexpectedResult;
            defer win32.CoTaskMemFree(@ptrCast(named));
            try testing.expectEqualSlices(u16, std.mem.span(name), std.mem.span(named));

            // The second of the two types given.
            try testing.expect(dlg.vtable.SetFileTypeIndex(dlg, 2) >= 0);
            var index: windows.UINT = 0;
            try testing.expect(dlg.vtable.GetFileTypeIndex(dlg, &index) >= 0);
            try testing.expectEqual(2, index);

            // An item such as GetResult returns, for an existing file.
            var out: ?*anyopaque = null;
            try testing.expect(win32.SHCreateItemFromParsingName(item_path.ptr, null, &IID_IShellItem, &out) >= 0);
            const item: *IShellItem = @ptrCast(@alignCast(out orelse return error.TestUnexpectedResult));
            defer item.release();
            const back = try item.path(testing.allocator);
            defer testing.allocator.free(back);
            // The shell spells a path its own way: given one with a short
            // (8.3) name in it, as a temporary folder's often is, it gives
            // back the long one. So the file it names is known by what it
            // holds, not by its spelling.
            const back8 = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, back);
            defer testing.allocator.free(back8);
            const held = try std.Io.Dir.cwd().readFileAlloc(testing.io, back8, testing.allocator, .limited(64));
            defer testing.allocator.free(held);
            try testing.expectEqualStrings(marker, held);
        }
    };
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, Unshown.run, .{ wide, &result });
    thread.join();
    try result;
}

test "win32: a cancelled Save dialog is not a failure" {
    const testing = std.testing;
    // HRESULT_FROM_WIN32: the facility, 7, over the Win32 error's code.
    try testing.expectEqual(
        @as(u32, 0x8007_0000) | @backingInt(windows.Win32Error.CANCELLED),
        @as(u32, @bitCast(cancelled_hr)),
    );
    try testing.expect(answerOf(cancelled_hr) == .cancelled);
    try testing.expect(answerOf(@bitCast(@as(u32, 0x80004005))) == .failed); // E_FAIL
}
