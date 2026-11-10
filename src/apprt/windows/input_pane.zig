//! The touch keyboard, for `show_on_screen_keyboard`, through the Windows
//! Runtime's Windows.UI.ViewManagement.InputPane. A desktop program has no
//! view to ask for the pane of, so it asks the class's activation factory
//! for a window's (IInputPaneInterop::GetForWindow, Windows 10 1607 on).
//!
//! The interfaces are vtable structs, IInputPaneInterop in the order of
//! the mingw header Zig ships
//! (lib/libc/include/any-windows-any/inputpaneinterop.h) and IInputPane2
//! in that of the Windows SDK's
//! (Include\<version>\winrt\windows.ui.viewmanagement.h), which mingw does
//! not ship, as the renderer's interfaces are
//! (src/renderer/d3d11/api.zig): only the methods called here are typed,
//! every other slot is an untyped pointer, and the tests check the slot
//! counts and the typed slots' indices against the headers.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const win32 = @import("win32.zig");

const HRESULT = win32.HRESULT;
const ULONG = windows.ULONG;
const HWND = windows.HWND;
const GUID = windows.GUID;

/// An untyped vtable slot, there so that the slots after it keep their
/// index.
const Slot = *const anyopaque;

/// The InputPane class's activation factory, as a desktop program uses
/// it.
const IInputPaneInterop = extern struct {
    vtable: *const VTable,

    const IID: GUID = GUID.parse("{75cf2c57-9195-4931-8332-f0b409e916af}");

    /// IUnknown, IInspectable and IInputPaneInterop, flattened.
    const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IInputPaneInterop) callconv(.winapi) ULONG,
        GetIids: Slot,
        GetRuntimeClassName: Slot,
        GetTrustLevel: Slot,
        GetForWindow: *const fn (*IInputPaneInterop, HWND, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// A window's input pane: the touch keyboard, and the handwriting panel.
const IInputPane2 = extern struct {
    vtable: *const VTable,

    const IID: GUID = GUID.parse("{8a6b3f26-7090-4793-944c-c3f2cde26276}");

    /// IUnknown, IInspectable and IInputPane2, flattened. The results are
    /// the Windows Runtime's boolean, a byte.
    const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IInputPane2) callconv(.winapi) ULONG,
        GetIids: Slot,
        GetRuntimeClassName: Slot,
        GetTrustLevel: Slot,
        TryShow: *const fn (*IInputPane2, *u8) callconv(.winapi) HRESULT,
        TryHide: Slot,
    };
};

/// For tests: what `tryShow` answers for a window. A test never asks
/// Windows, which would show its keyboard over the desktop the tests run
/// on: with no answer set, the call fails.
pub var test_try_show: ?*const fn (HWND) error{InputPaneFailed}!bool = null;

/// Ask Windows to show the touch keyboard for `frame`, a top-level window
/// of the calling thread, which must be in an apartment (CoInitializeEx).
/// Whether Windows says it shows. A call that fails is logged.
pub fn tryShow(frame: HWND) error{InputPaneFailed}!bool {
    if (builtin.is_test) {
        const answer = test_try_show orelse return error.InputPaneFailed;
        return answer(frame);
    }
    return ask(frame);
}

fn ask(frame: HWND) error{InputPaneFailed}!bool {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.ViewManagement.InputPane");
    var name: win32.HSTRING = null;
    try win32.checkHr(
        win32.WindowsCreateString(class.ptr, @intCast(class.len), &name),
        error.InputPaneFailed,
        "input pane: WindowsCreateString",
    );
    defer _ = win32.WindowsDeleteString(name);

    var out: ?*anyopaque = null;
    try win32.checkHr(
        win32.RoGetActivationFactory(name, &IInputPaneInterop.IID, &out),
        error.InputPaneFailed,
        "input pane: RoGetActivationFactory",
    );
    const interop: *IInputPaneInterop = @ptrCast(@alignCast(out orelse return error.InputPaneFailed));
    defer _ = interop.vtable.Release(interop);

    out = null;
    try win32.checkHr(
        interop.vtable.GetForWindow(interop, frame, &IInputPane2.IID, &out),
        error.InputPaneFailed,
        "input pane: GetForWindow",
    );
    const pane: *IInputPane2 = @ptrCast(@alignCast(out orelse return error.InputPaneFailed));
    defer _ = pane.vtable.Release(pane);

    var shown: u8 = 0;
    try win32.checkHr(pane.vtable.TryShow(pane, &shown), error.InputPaneFailed, "input pane: TryShow");
    return shown != 0;
}

test "win32: the input pane's interfaces have the headers' slots" {
    // IInputPaneInteropVtbl in inputpaneinterop.h: IUnknown's 3,
    // IInspectable's 3 and its own 1. IInputPane2's in
    // windows.ui.viewmanagement.h: the same 6 and its own 2.
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(7 * p, @sizeOf(IInputPaneInterop.VTable));
    try testing.expectEqual(2 * p, @offsetOf(IInputPaneInterop.VTable, "Release"));
    try testing.expectEqual(6 * p, @offsetOf(IInputPaneInterop.VTable, "GetForWindow"));
    try testing.expectEqual(8 * p, @sizeOf(IInputPane2.VTable));
    try testing.expectEqual(2 * p, @offsetOf(IInputPane2.VTable, "Release"));
    try testing.expectEqual(6 * p, @offsetOf(IInputPane2.VTable, "TryShow"));
    try testing.expectEqual(7 * p, @offsetOf(IInputPane2.VTable, "TryHide"));
}

test "win32: Windows answers a request for a window's keyboard" {
    // The request itself (`ask`), which no other test makes: every call
    // of it succeeds. For a window that does not show, so the answer is
    // no and nothing appears.
    const testing = std.testing;
    const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
    defer if (hr >= 0) win32.CoUninitialize();
    const hwnd = win32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        null,
        0,
        0,
        0,
        100,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);
    try testing.expect(!try ask(hwnd));
}

test "win32: the input pane's interface ids" {
    // As the headers write them, field by field.
    const testing = std.testing;
    try testing.expectEqual(GUID{
        .Data1 = 0x75cf2c57,
        .Data2 = 0x9195,
        .Data3 = 0x4931,
        .Data4 = .{ 0x83, 0x32, 0xf0, 0xb4, 0x09, 0xe9, 0x16, 0xaf },
    }, IInputPaneInterop.IID);
    try testing.expectEqual(GUID{
        .Data1 = 0x8a6b3f26,
        .Data2 = 0x7090,
        .Data3 = 0x4793,
        .Data4 = .{ 0x94, 0x4c, 0xc3, 0xf2, 0xcd, 0xe2, 0x62, 0x76 },
    }, IInputPane2.IID);
}

test "win32: a test's request for the keyboard is answered by the test" {
    const testing = std.testing;
    const frame: HWND = @ptrFromInt(0x10);
    try testing.expectError(error.InputPaneFailed, tryShow(frame));
    const Answer = struct {
        var asked: ?HWND = null;
        fn yes(of: HWND) error{InputPaneFailed}!bool {
            asked = of;
            return true;
        }
    };
    Answer.asked = null;
    test_try_show = &Answer.yes;
    defer test_try_show = null;
    try testing.expect(try tryShow(frame));
    try testing.expectEqual(frame, Answer.asked.?);
}
