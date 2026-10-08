//! Application runtime for Windows, built directly on the Win32 API
//! (user32/gdi32), rendering with Direct3D 11.
//!
//! ## What this is
//!
//!   * `App` owns the process lifecycle: the Win32 message loop, a
//!     message-only window used as the wakeup and timer target, and the
//!     loaded configuration.
//!   * `Surface` owns an `HWND` and hosts a real, initialized `CoreSurface`:
//!     a terminal with its own renderer and IO threads.
//!
//! The renderer is `GenericRenderer(D3D11)` (src/renderer/D3D11.zig). It
//! takes only the `HWND`: it creates its device and swap chain in `init`,
//! on the main thread inside `CoreSurface.init`, and resizes and presents
//! the swap chain on the render thread. The main thread makes no graphics
//! calls once a surface exists: WM_PAINT only asks the core for a frame.
//!
//! ## Invariants this file depends on
//!
//!   * **No window is destroyed from inside a core frame.** The core calls
//!     `CoreSurface.close` from its own stack (`Surface.childExited`,
//!     `Surface.keyCallback`), and
//!     `CoreSurface.deinit` would free memory those frames still use. Every
//!     close therefore posts `WM_GHOSTTY_DESTROY` and the teardown runs later,
//!     from a message loop (`Surface.destroyPosted`).
//!   * **`core_app.tick` never reenters itself**, and never runs while a
//!     modal confirmation prompt is up (`App.canReenterCore`).
//!
//! ## What is still missing
//!
//! Not implemented: more than one window (`.new_window`), a context menu,
//! link previews and precision-touchpad scrolling. Without a menu, a right
//! click with the default `right-click-action` only selects the word or
//! link under the pointer.
//! `performAction` returns `false`, the contract's word for "unsupported",
//! for `.new_window`, `.mouse_over_link` and every other action it does not
//! name; this runtime never claims an action it did not carry out.
//!
//! Links open through the shell (`ShellExecuteW`). An OSC 8 target is
//! program output, so only a well-formed http, https or mailto link is
//! opened from one; anything else is refused with a notice (`osc8Allowed`).
//!
//! An IME composition is drawn inline as the core's preedit. The IME's own
//! composition window is therefore turned off (WM_IME_SETCONTEXT), and
//! WM_IME_COMPOSITION is consumed: its result is read once and sent to the
//! core as a text-only key event, and DefWindowProcW never turns it into
//! WM_CHARs. The candidate window is placed at the cursor cell
//! (`Surface.imePlace`). See `Surface.Ime`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const global = @import("../global.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.win32);

pub const resourcesDir = internal_os.resourcesDir;

/// The MIME type we serve and accept for clipboard text. The core's
/// `terminal.clipboard.isTextMime` accepts this spelling.
const text_mime = "text/plain;charset=utf-8";

// -------------------------------------------------------------------------
// Win32 bindings
//
// std.os.windows is in the middle of having most of its Windows API surface
// removed (see the note at the top of src/os/windows.zig). Types that survive
// there are aliased; everything else is declared here. Zig auto-links the
// import library named by an `extern "user32"`-style declaration, so the
// explicit `linkSystemLibrary` calls in src/build/SharedDeps.zig only list
// the same libraries in one place.
// -------------------------------------------------------------------------
const win32 = struct {
    const w = std.os.windows;

    const BOOL = w.BOOL;
    const BYTE = w.BYTE;
    const WORD = w.WORD;
    const DWORD = w.DWORD;
    const HRESULT = c_long;
    const UINT = w.UINT;
    const LONG = w.LONG;
    const WCHAR = w.WCHAR;
    const LPCWSTR = w.LPCWSTR;
    const HANDLE = w.HANDLE;
    const HWND = w.HWND;
    const HDC = w.HDC;
    const HINSTANCE = w.HINSTANCE;
    const HMODULE = w.HMODULE;
    const HICON = w.HICON;
    const HCURSOR = w.HCURSOR;
    const HBRUSH = w.HBRUSH;
    const HMENU = w.HMENU;
    const ATOM = w.ATOM;

    /// Not in std: the message-parameter and return types. On both 32- and
    /// 64-bit Windows these are pointer-sized, unsigned for WPARAM and signed
    /// for LPARAM/LRESULT.
    const WPARAM = usize;
    const LPARAM = isize;
    const LRESULT = isize;
    const UINT_PTR = usize;
    const LONG_PTR = isize;
    const HGLOBAL = *anyopaque;
    const SHORT = w.SHORT;

    /// Keyboard layout handle. Only ever passed back to user32.
    const HKL = *opaque {};

    const WNDPROC = *const fn (
        hwnd: HWND,
        msg: UINT,
        wparam: WPARAM,
        lparam: LPARAM,
    ) callconv(.winapi) LRESULT;

    const POINT = extern struct { x: LONG, y: LONG };
    const TRACKMOUSEEVENT = extern struct {
        cbSize: DWORD,
        dwFlags: DWORD,
        hwndTrack: HWND,
        dwHoverTime: DWORD,
    };
    const RECT = internal_os.windows.RECT;

    const MSG = extern struct {
        hwnd: ?HWND,
        message: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
        time: DWORD,
        pt: POINT,
    };

    const WNDCLASSEXW = extern struct {
        cbSize: UINT,
        style: UINT,
        lpfnWndProc: WNDPROC,
        cbClsExtra: c_int,
        cbWndExtra: c_int,
        hInstance: HINSTANCE,
        hIcon: ?HICON,
        hCursor: ?HCURSOR,
        hbrBackground: ?HBRUSH,
        lpszMenuName: ?LPCWSTR,
        lpszClassName: LPCWSTR,
        hIconSm: ?HICON,
    };

    const CREATESTRUCTW = extern struct {
        lpCreateParams: ?*anyopaque,
        hInstance: ?HINSTANCE,
        hMenu: ?HMENU,
        hwndParent: ?HWND,
        cy: c_int,
        cx: c_int,
        y: c_int,
        x: c_int,
        style: LONG,
        lpszName: ?LPCWSTR,
        lpszClass: ?LPCWSTR,
        dwExStyle: DWORD,
    };

    // Window class styles.
    const CS_VREDRAW: UINT = 0x0001;
    const CS_HREDRAW: UINT = 0x0002;

    const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
    const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
    const SW_SHOWNORMAL: c_int = 1;
    const SW_MAXIMIZE: c_int = 3;
    const SW_RESTORE: c_int = 9;

    /// Parent value that makes CreateWindowExW produce a message-only window:
    /// no pixels, not enumerated, but a valid PostMessage and SetTimer target.
    const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

    /// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. Passed as an opaque handle
    /// whose value is a small negative integer.
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE =
        @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

    const GWLP_USERDATA: c_int = -21;

    const WM_DESTROY: UINT = 0x0002;
    const WM_SIZE: UINT = 0x0005;
    const WM_SETFOCUS: UINT = 0x0007;
    const WM_KILLFOCUS: UINT = 0x0008;
    const WM_CLOSE: UINT = 0x0010;
    const WM_QUIT: UINT = 0x0012;
    const WM_ERASEBKGND: UINT = 0x0014;
    const WM_SETCURSOR: UINT = 0x0020;
    const WM_MOUSEACTIVATE: UINT = 0x0021;
    const WM_PAINT: UINT = 0x000F;
    const WM_NCCREATE: UINT = 0x0081;
    const WM_KEYFIRST: UINT = 0x0100;
    const WM_KEYDOWN: UINT = 0x0100;
    const WM_KEYUP: UINT = 0x0101;
    const WM_CHAR: UINT = 0x0102;
    const WM_DEADCHAR: UINT = 0x0103;
    const WM_SYSKEYDOWN: UINT = 0x0104;
    const WM_SYSKEYUP: UINT = 0x0105;
    const WM_SYSCHAR: UINT = 0x0106;
    const WM_SYSDEADCHAR: UINT = 0x0107;
    /// Windows XP and later; 0x0108 before WM_UNICHAR (0x0109) existed.
    const WM_KEYLAST: UINT = 0x0109;
    const WM_SYSCOMMAND: UINT = 0x0112;
    const WM_TIMER: UINT = 0x0113;
    const WM_MOUSEMOVE: UINT = 0x0200;
    const WM_LBUTTONDOWN: UINT = 0x0201;
    const WM_LBUTTONUP: UINT = 0x0202;
    const WM_RBUTTONDOWN: UINT = 0x0204;
    const WM_RBUTTONUP: UINT = 0x0205;
    const WM_MBUTTONDOWN: UINT = 0x0207;
    const WM_MBUTTONUP: UINT = 0x0208;
    const WM_MOUSEWHEEL: UINT = 0x020A;
    const WM_XBUTTONDOWN: UINT = 0x020B;
    const WM_XBUTTONUP: UINT = 0x020C;
    const WM_MOUSEHWHEEL: UINT = 0x020E;
    const WM_ENTERMENULOOP: UINT = 0x0211;
    const WM_EXITMENULOOP: UINT = 0x0212;
    const WM_ENTERSIZEMOVE: UINT = 0x0231;
    const WM_EXITSIZEMOVE: UINT = 0x0232;
    const WM_MOUSELEAVE: UINT = 0x02A3;
    const WM_DPICHANGED: UINT = 0x02E0;
    const WM_APP: UINT = 0x8000;

    const PM_NOREMOVE: UINT = 0x0000;
    const PM_REMOVE: UINT = 0x0001;

    /// WM_SIZE wParam.
    const SIZE_MINIMIZED: WPARAM = 1;

    /// Mouse message wParam (the low word for the wheel and X-button
    /// messages): the buttons down and the Shift/Ctrl state at the time of
    /// the event. There is no Alt or Windows-key flag. The button bits
    /// follow the left/right swap setting, as the button messages do.
    const MK_LBUTTON: WPARAM = 0x0001;
    const MK_RBUTTON: WPARAM = 0x0002;
    const MK_SHIFT: WPARAM = 0x0004;
    const MK_CONTROL: WPARAM = 0x0008;
    const MK_MBUTTON: WPARAM = 0x0010;
    const MK_XBUTTON1: WPARAM = 0x0020;
    const MK_XBUTTON2: WPARAM = 0x0040;
    /// WM_XBUTTON* wParam high word (GET_XBUTTON_WPARAM).
    const XBUTTON1: u16 = 0x0001;
    const XBUTTON2: u16 = 0x0002;
    /// One wheel notch. High-resolution wheels send fractions of it.
    const WHEEL_DELTA: i32 = 120;
    /// SystemParametersInfoW: lines (vertical) and characters (horizontal)
    /// to scroll per notch, both 3 by default. Lines can instead be
    /// WHEEL_PAGESCROLL, "one screen at a time".
    const SPI_GETWHEELSCROLLLINES: UINT = 0x0068;
    const SPI_GETWHEELSCROLLCHARS: UINT = 0x006C;
    const WHEEL_PAGESCROLL: UINT = std.math.maxInt(UINT);
    const TME_LEAVE: DWORD = 0x00000002;
    /// The client-area hit-test code (WM_NCHITTEST), which is the low word
    /// of WM_MOUSEACTIVATE's and WM_SETCURSOR's lParam.
    const HTCLIENT: u16 = 1;
    /// WM_MOUSEACTIVATE: activate the window and discard the mouse message.
    const MA_ACTIVATEANDEAT: LRESULT = 2;

    /// WM_SYSCOMMAND wParam (low four bits are reserved and must be masked).
    const SC_KEYMENU: WPARAM = 0xF100;

    // Virtual-key codes.
    const VK_SPACE: WPARAM = 0x20;
    const VK_PROCESSKEY: WPARAM = 0xE5;
    const VK_PACKET: WPARAM = 0xE7;
    const VK_CONTROL: WPARAM = 0x11;
    const VK_MENU: WPARAM = 0x12;
    const VK_NUMPAD0: UINT = 0x60;
    const VK_NUMPAD9: UINT = 0x69;
    const VK_DECIMAL: UINT = 0x6E;
    const VK_SHIFT: c_int = 0x10;
    const VK_CAPITAL: c_int = 0x14;
    const VK_NUMLOCK: c_int = 0x90;
    const VK_LWIN: c_int = 0x5B;
    const VK_RWIN: c_int = 0x5C;
    const VK_LSHIFT: c_int = 0xA0;
    const VK_RSHIFT: c_int = 0xA1;
    const VK_LCONTROL: c_int = 0xA2;
    const VK_RCONTROL: c_int = 0xA3;
    const VK_LMENU: c_int = 0xA4;
    const VK_RMENU: c_int = 0xA5;

    /// MapVirtualKeyW mode: VK -> scan code, with the 0xE0/0xE1 prefix
    /// in the high byte for extended keys.
    const MAPVK_VK_TO_VSC_EX: UINT = 4;

    /// ToUnicodeEx flag: do not change the keyboard state, in particular
    /// the pending dead key. Honored from Windows 10 1607.
    const TOUNICODE_NO_STATE_CHANGE: UINT = 0x4;

    // MsgWaitForMultipleObjectsEx.
    const QS_ALLINPUT: DWORD = 0x04FF;
    const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
    const WAIT_OBJECT_0: DWORD = 0x00000000;
    const WAIT_TIMEOUT: DWORD = 0x00000102;
    const WAIT_FAILED: DWORD = 0xFFFFFFFF;

    const SWP_NOMOVE: UINT = 0x0002;
    const SWP_NOZORDER: UINT = 0x0004;
    const SWP_NOACTIVATE: UINT = 0x0010;

    /// A resource name that may be an integer id (MAKEINTRESOURCEW): the
    /// same pointer as LPCWSTR, but without its alignment, since the ids are
    /// odd as often as even. An LPCWSTR still coerces to it.
    const ResourceW = [*:0]align(1) const u16;
    const IDC_ARROW: ResourceW = @ptrFromInt(32512);
    const IDC_IBEAM: ResourceW = @ptrFromInt(32513);
    const IDC_WAIT: ResourceW = @ptrFromInt(32514);
    const IDC_CROSS: ResourceW = @ptrFromInt(32515);
    const IDC_SIZENWSE: ResourceW = @ptrFromInt(32642);
    const IDC_SIZENESW: ResourceW = @ptrFromInt(32643);
    const IDC_SIZEWE: ResourceW = @ptrFromInt(32644);
    const IDC_SIZENS: ResourceW = @ptrFromInt(32645);
    const IDC_SIZEALL: ResourceW = @ptrFromInt(32646);
    const IDC_NO: ResourceW = @ptrFromInt(32648);
    const IDC_HAND: ResourceW = @ptrFromInt(32649);
    const IDC_APPSTARTING: ResourceW = @ptrFromInt(32650);
    const IDC_HELP: ResourceW = @ptrFromInt(32651);

    const CF_UNICODETEXT: UINT = 13;
    const GMEM_MOVEABLE: UINT = 0x0002;
    const CP_UTF8: UINT = 65001;

    const MB_OK: UINT = 0x00000000;
    const MB_OKCANCEL: UINT = 0x00000001;
    const MB_ICONWARNING: UINT = 0x00000030;
    const MB_ICONERROR: UINT = 0x00000010;
    const MB_DEFBUTTON1: UINT = 0x00000000;
    const MB_DEFBUTTON2: UINT = 0x00000100;
    const MB_DEFMASK: UINT = 0x00000F00;
    const IDOK: c_int = 1;

    const MB_ICONASTERISK: UINT = 0x00000040;

    /// GetDeviceCaps index for horizontal DPI. Used as the pre-1607 fallback
    /// for GetDpiForWindow, where it is the correct answer: those versions
    /// have no per-monitor DPI at all.
    const LOGPIXELSX: c_int = 88;
    /// The reference DPI: a scale of 1.
    const USER_DEFAULT_SCREEN_DPI: UINT = 96;

    // Entry points that must NOT be statically imported.
    //
    // SetProcessDpiAwarenessContext is a user32 export only from Windows 10
    // 1703, and GetDpiForWindow only from 1607. Declaring either as
    // `extern "user32"` puts it in the PE import table, and the loader then
    // fails the whole process with STATUS_ENTRY_POINT_NOT_FOUND *before* main
    // runs -- there is no FALSE return to observe and no fallback to take.
    // They are resolved with GetProcAddress in App.init instead.
    const SetProcessDpiAwarenessContextFn = *const fn (
        ctx: HANDLE,
    ) callconv(.winapi) BOOL;
    const GetDpiForWindowFn = *const fn (hwnd: HWND) callconv(.winapi) UINT;
    const GetThreadDpiAwarenessContextFn = *const fn () callconv(.winapi) ?HANDLE;
    const AreDpiAwarenessContextsEqualFn = *const fn (a: HANDLE, b: HANDLE) callconv(.winapi) BOOL;

    extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HMODULE;
    const GetProcAddress = internal_os.windows.exp.kernel32.GetProcAddress;
    extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
    extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
    extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;
    /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-globalsize
    extern "kernel32" fn GlobalSize(mem: HGLOBAL) callconv(.winapi) usize;
    /// https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar
    extern "kernel32" fn MultiByteToWideChar(
        code_page: UINT,
        flags: DWORD,
        src: [*]const u8,
        src_len: c_int,
        dst: ?[*]u16,
        dst_len: c_int,
    ) callconv(.winapi) c_int;

    extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;
    extern "user32" fn UnregisterClassW(name: LPCWSTR, inst: ?HINSTANCE) callconv(.winapi) BOOL;
    extern "user32" fn CreateWindowExW(
        ex_style: DWORD,
        class_name: ?LPCWSTR,
        window_name: ?LPCWSTR,
        style: DWORD,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        parent: ?HWND,
        menu: ?HMENU,
        inst: ?HINSTANCE,
        param: ?*anyopaque,
    ) callconv(.winapi) ?HWND;
    extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn DefWindowProcW(
        hwnd: HWND,
        msg: UINT,
        wparam: WPARAM,
        lparam: LPARAM,
    ) callconv(.winapi) LRESULT;
    extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
    extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetMessageW(
        msg: *MSG,
        hwnd: ?HWND,
        min: UINT,
        max: UINT,
    ) callconv(.winapi) BOOL;
    extern "user32" fn PeekMessageW(
        msg: *MSG,
        hwnd: ?HWND,
        min: UINT,
        max: UINT,
        remove: UINT,
    ) callconv(.winapi) BOOL;
    extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
    extern "user32" fn GetMessageTime() callconv(.winapi) LONG;
    extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
    extern "user32" fn PostMessageW(
        hwnd: ?HWND,
        msg: UINT,
        wparam: WPARAM,
        lparam: LPARAM,
    ) callconv(.winapi) BOOL;
    extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
    extern "user32" fn SetWindowLongPtrW(
        hwnd: HWND,
        index: c_int,
        value: LONG_PTR,
    ) callconv(.winapi) LONG_PTR;
    extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) LONG_PTR;
    extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
    const GetClientRect = internal_os.windows.exp.user32.GetClientRect;
    extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
    extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
    extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
    extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
    extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
    extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
    extern "user32" fn WindowFromPoint(pt: POINT) callconv(.winapi) ?HWND;
    extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
    extern "user32" fn SystemParametersInfoW(
        action: UINT,
        param: UINT,
        value: ?*anyopaque,
        win_ini: UINT,
    ) callconv(.winapi) BOOL;
    extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
    extern "user32" fn SetWindowPos(
        hwnd: HWND,
        after: ?HWND,
        x: c_int,
        y: c_int,
        cx: c_int,
        cy: c_int,
        flags: UINT,
    ) callconv(.winapi) BOOL;
    extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: ResourceW) callconv(.winapi) ?HCURSOR;
    /// Returns an HINSTANCE in name only: a value of 32 or below is an
    /// SE_ERR_* code (0 means out of memory), so it is read as an integer.
    extern "shell32" fn ShellExecuteW(
        hwnd: ?HWND,
        operation: ?LPCWSTR,
        file: LPCWSTR,
        parameters: ?LPCWSTR,
        directory: ?LPCWSTR,
        show: c_int,
    ) callconv(.winapi) usize;
    const COINIT_APARTMENTTHREADED: DWORD = 0x2;
    const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;

    // IMM32. Both forms are in client coordinates of the context's window.
    const HIMC = *opaque {};
    const COMPOSITIONFORM = extern struct { dwStyle: DWORD, ptCurrentPos: POINT, rcArea: RECT };
    const CANDIDATEFORM = extern struct { dwIndex: DWORD, dwStyle: DWORD, ptCurrentPos: POINT, rcArea: RECT };
    const WM_INPUTLANGCHANGE: UINT = 0x0051;
    const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
    const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
    const WM_IME_COMPOSITION: UINT = 0x010F;
    const WM_IME_SETCONTEXT: UINT = 0x0281;
    const WM_IME_CHAR: UINT = 0x0286;
    const WM_IME_REQUEST: UINT = 0x0288;
    const ISC_SHOWUICOMPOSITIONWINDOW: usize = 0x80000000;
    const GCS_COMPREADSTR: u32 = 0x0001;
    const GCS_COMPREADATTR: u32 = 0x0002;
    const GCS_COMPREADCLAUSE: u32 = 0x0004;
    const GCS_COMPSTR: u32 = 0x0008;
    const GCS_COMPATTR: u32 = 0x0010;
    const GCS_COMPCLAUSE: u32 = 0x0020;
    const GCS_CURSORPOS: u32 = 0x0080;
    const GCS_DELTASTART: u32 = 0x0100;
    const GCS_RESULTREADSTR: u32 = 0x0200;
    const GCS_RESULTREADCLAUSE: u32 = 0x0400;
    const GCS_RESULTSTR: u32 = 0x0800;
    const GCS_RESULTCLAUSE: u32 = 0x1000;
    /// Every GCS_* flag. A WM_IME_COMPOSITION with none of them set means
    /// the composition was cancelled.
    const GCS_ALL: u32 = GCS_COMPREADSTR | GCS_COMPREADATTR |
        GCS_COMPREADCLAUSE | GCS_COMPSTR | GCS_COMPATTR | GCS_COMPCLAUSE |
        GCS_CURSORPOS | GCS_DELTASTART | GCS_RESULTREADSTR |
        GCS_RESULTREADCLAUSE | GCS_RESULTSTR | GCS_RESULTCLAUSE;
    const CFS_POINT: DWORD = 0x0002;
    const CFS_EXCLUDE: DWORD = 0x0080;
    const NI_COMPOSITIONSTR: DWORD = 0x0015;
    const CPS_COMPLETE: DWORD = 0x0001;
    const CPS_CANCEL: DWORD = 0x0004;
    const LANG_KOREAN: u16 = 0x12;

    /// PRIMARYLANGID (winnt.h): a LANGID without its sublanguage.
    fn primaryLangId(lgid: u16) u16 {
        return lgid & 0x3FF;
    }

    extern "imm32" fn ImmGetContext(hwnd: HWND) callconv(.winapi) ?HIMC;
    extern "imm32" fn ImmReleaseContext(hwnd: HWND, himc: HIMC) callconv(.winapi) BOOL;
    /// Sizes are in bytes, also for the W form; negative is an error.
    extern "imm32" fn ImmGetCompositionStringW(
        himc: HIMC,
        index: DWORD,
        buf: ?*anyopaque,
        len: DWORD,
    ) callconv(.winapi) LONG;
    extern "imm32" fn ImmSetCompositionWindow(himc: HIMC, form: *COMPOSITIONFORM) callconv(.winapi) BOOL;
    extern "imm32" fn ImmSetCandidateWindow(himc: HIMC, form: *CANDIDATEFORM) callconv(.winapi) BOOL;
    extern "imm32" fn ImmNotifyIME(himc: HIMC, action: DWORD, index: DWORD, value: DWORD) callconv(.winapi) BOOL;
    extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn ValidateRect(hwnd: ?HWND, rect: ?*const RECT) callconv(.winapi) BOOL;
    extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) c_int;
    extern "user32" fn MsgWaitForMultipleObjectsEx(
        count: DWORD,
        handles: ?[*]const HANDLE,
        timeout_ms: DWORD,
        wake_mask: DWORD,
        flags: DWORD,
    ) callconv(.winapi) DWORD;
    extern "user32" fn GetKeyState(vk: c_int) callconv(.winapi) SHORT;
    extern "user32" fn GetKeyboardState(key_state: *[256]BYTE) callconv(.winapi) BOOL;
    extern "user32" fn MapVirtualKeyW(code: UINT, map_type: UINT) callconv(.winapi) UINT;
    extern "user32" fn GetKeyboardLayout(thread_id: DWORD) callconv(.winapi) ?HKL;
    extern "user32" fn ToUnicodeEx(
        vk: UINT,
        scan_code: UINT,
        key_state: *const [256]BYTE,
        buf: [*]WCHAR,
        buf_len: c_int,
        flags: UINT,
        layout: ?HKL,
    ) callconv(.winapi) c_int;
    extern "user32" fn SetTimer(
        hwnd: ?HWND,
        id: UINT_PTR,
        elapse_ms: UINT,
        proc: ?*const anyopaque,
    ) callconv(.winapi) UINT_PTR;
    extern "user32" fn KillTimer(hwnd: ?HWND, id: UINT_PTR) callconv(.winapi) BOOL;
    extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
    extern "user32" fn MessageBeep(type_: UINT) callconv(.winapi) BOOL;
    extern "user32" fn MessageBoxW(
        hwnd: ?HWND,
        text: LPCWSTR,
        caption: LPCWSTR,
        type_: UINT,
    ) callconv(.winapi) c_int;
    extern "user32" fn OpenClipboard(hwnd: ?HWND) callconv(.winapi) BOOL;
    extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
    extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
    extern "user32" fn SetClipboardData(format: UINT, mem: ?HANDLE) callconv(.winapi) ?HANDLE;
    extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HANDLE;
    extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;

    extern "gdi32" fn GetDeviceCaps(hdc: HDC, index: c_int) callconv(.winapi) c_int;

    fn loword(v: LPARAM) u16 {
        return @truncate(@as(usize, @bitCast(v)));
    }

    fn hiword(v: anytype) u16 {
        return @truncate(@as(usize, @bitCast(v)) >> 16);
    }

    /// GET_X_LPARAM / GET_Y_LPARAM (windowsx.h). Signed: while the mouse is
    /// captured, positions above or left of the client area are negative,
    /// which loword/hiword would turn into values near 65535.
    fn xLparam(v: LPARAM) i16 {
        return @bitCast(loword(v));
    }

    fn yLparam(v: LPARAM) i16 {
        return @bitCast(hiword(v));
    }

    /// GET_WHEEL_DELTA_WPARAM: the signed high word.
    fn wheelDelta(v: WPARAM) i16 {
        return @bitCast(hiword(v));
    }
};

/// UTF-16 string literal helper for the many `LPCWSTR` constants below.
fn L(comptime s: []const u8) win32.LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Window class names. These are process-global, so they are registered once
/// in `App.init` and unregistered in `App.terminate`.
const surface_class_name = "GhosttySurfaceClass";
const app_class_name = "GhosttyAppClass";

/// Posted by `App.wakeup` from arbitrary threads to break `GetMessageW` out of
/// its block so `run` reaches the next `core_app.tick`.
const WM_GHOSTTY_WAKEUP: win32.UINT = win32.WM_APP + 1;

/// Posted to a surface window by `Surface.close`. Its handler tears the
/// surface down; see `Surface.destroyPosted`. Posting rather than destroying
/// in place is what keeps teardown out of core stack frames.
const WM_GHOSTTY_DESTROY: win32.UINT = win32.WM_APP + 2;

/// Posted to a surface window by `App.openUrl` for a refused OSC 8 link.
/// Its handler shows the notice; `App.openUrl` says why it is posted.
const WM_GHOSTTY_LINK_REFUSED: win32.UINT = win32.WM_APP + 3;

/// Timer id for the quit-after-last-window timer on the app's message-only
/// window. Any non-zero value works; it only has to be unique per window.
const quit_timer_id: win32.UINT_PTR = 1;

pub const App = struct {
    core_app: *CoreApp,

    /// The configuration. Owned by this struct, freed in `terminate`.
    ///
    /// Every surface's config is derived from this one
    /// (`apprt.surface.newConfig` in `Surface.create`), and the app-scoped key
    /// path (`CoreApp.keyEvent`) reads
    /// `rt_app.config.keybind`.
    config: Config,

    hinstance: win32.HINSTANCE,

    /// GetDpiForWindow, resolved at runtime because it does not exist before
    /// Windows 10 1607. Null means every window reports the system DPI.
    get_dpi_for_window: ?win32.GetDpiForWindowFn,

    /// A message-only window. It is the target for `wakeup` and for the quit
    /// timer. Using a window rather than `PostThreadMessageW` is deliberate:
    /// thread messages are silently dropped by the nested modal loops that
    /// Win32 runs during window drags, menus and dialogs, so a wakeup could be
    /// lost exactly when the mailbox needs draining.
    msg_hwnd: win32.HWND,

    /// The windows this runtime owns. See `surfaceDestroyed` for the
    /// ownership invariant. Each one whose `CoreSurface` is initialized is
    /// also registered with `CoreApp.addSurface`, which is what drives the
    /// quit timer; this list and the core's can differ only while a surface
    /// is being created or torn down.
    surfaces: std.ArrayListUnmanaged(*Surface),

    /// Set when the loop should stop. Written only on the main thread.
    quit: bool,

    /// The quit-after-last-window timer, in the GTK `Application`'s form
    /// (its `quit_timer`). `run` quits once this is `expired` and no surface
    /// is left.
    ///
    /// Expiry is recorded rather than acted on where it happens. `main` in
    /// main_ghostty.zig calls `startQuitTimer` *before* it calls `run`, and
    /// `quit-after-last-window-closed-delay` is unset by default
    /// (`Config.@"quit-after-last-window-closed-delay"`), i.e. zero delay.
    /// Quitting synchronously at that point would set `quit` before the loop
    /// ever began and the process would exit with its window still on screen.
    quit_timer: enum {
        off,

        /// Armed on `msg_hwnd` as `quit_timer_id`. GTK's carries the glib
        /// source; a window timer is named by its fixed id, so this carries
        /// nothing.
        active,

        expired,
    },

    /// True while `core_app.tick` is on the stack. See `tick`.
    ticking: bool,

    /// Number of modal confirmation prompts (`confirm`) currently open.
    ///
    /// A prompt runs a nested message loop, often with a core frame beneath
    /// it (`CoreSurface.close` from `keyCallback`, a clipboard confirmation
    /// from `tick`). Neither ticking nor surface teardown may run inside that
    /// loop; see `canReenterCore`.
    prompt_depth: u32,

    /// Number of system modal loops (window size/move, window menu) the main
    /// thread is currently inside. `run` does not get control back until such
    /// a loop ends, so while this is non-zero the wakeup handler ticks
    /// instead; see `wndProc`.
    modal_loop_depth: u32,

    /// Set for the whole of `terminate`. Teardown is driven from there
    /// synchronously, so posted closes and destroys are ignored meanwhile.
    terminating: bool,

    pub const Error = error{
        Win32ClassRegistrationFailed,
        Win32WindowCreationFailed,
        Win32MessageLoopFailed,
        /// A Win32 call that should not fail for a live window did.
        Win32CallFailed,
    };

    /// Always false: this runtime has no IPC channel to an already-running
    /// instance, so every CLI action that would need one honestly reports
    /// "not supported on this platform".
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    /// `main` in main_ghostty.zig declares `var app_runtime: apprt.App =
    /// undefined` on its stack, so this initializes in place and never returns
    /// a value. The App therefore has a stable address for the process
    /// lifetime, which is what lets `Surface.rtApp` hand out a pointer derived
    /// from it.
    pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
        _ = opts;

        const alloc = core_app.alloc;

        // Win32 defines HMODULE as HINSTANCE (minwindef.h); std types them
        // as distinct opaques, so the module handle is cast once, here,
        // where it becomes the window classes' instance.
        const hinstance: win32.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null) orelse
            return Error.Win32WindowCreationFailed);

        // Per-monitor DPI v2, so the DPI query reports the real value and
        // WM_DPICHANGED arrives with a usable suggested rect.
        //
        // Both DPI entry points are resolved through GetProcAddress rather
        // than statically imported; see the note on
        // win32.SetProcessDpiAwarenessContextFn for why a static import would
        // be a load-time process failure on older Windows rather than a
        // runtime fallback. GetModuleHandleW rather than LoadLibraryW because
        // user32 is already in this binary's import table.
        const user32 = win32.GetModuleHandleW(L("user32.dll"));
        if (user32) |m| {
            if (win32.GetProcAddress(m, "SetProcessDpiAwarenessContext")) |p| {
                const f: win32.SetProcessDpiAwarenessContextFn = @ptrCast(@alignCast(p));
                if (!f(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).toBool()) {
                    // FALSE alone does not mean per-monitor awareness is unavailable.
                    // ERROR_ACCESS_DENIED means the awareness was already set
                    // before this call -- in a normal build by the manifest
                    // embedded from dist/windows/ghostty.manifest, which
                    // declares PerMonitorV2. That is the expected path, so it
                    // is not reported; logEffectiveDpiAwareness states what is
                    // actually in effect either way.
                    const err = std.os.windows.GetLastError();
                    if (err != .ACCESS_DENIED) {
                        log.warn("SetProcessDpiAwarenessContext failed err={}", .{err});
                    }
                }
            } else {
                log.info("SetProcessDpiAwarenessContext missing (pre-1703 Windows)", .{});
            }
            logEffectiveDpiAwareness(m);
        }

        const get_dpi_for_window: ?win32.GetDpiForWindowFn = dpi: {
            const m = user32 orelse break :dpi null;
            const p = win32.GetProcAddress(m, "GetDpiForWindow") orelse {
                log.info("GetDpiForWindow missing (pre-1607 Windows), using system DPI", .{});
                break :dpi null;
            };
            break :dpi @ptrCast(@alignCast(p));
        };

        var config = try Config.load(alloc);
        errdefer config.deinit();

        try registerClasses(hinstance);
        errdefer unregisterClasses(hinstance);

        const msg_hwnd = win32.CreateWindowExW(
            0,
            L(app_class_name),
            null,
            0,
            0,
            0,
            0,
            0,
            win32.HWND_MESSAGE,
            null,
            hinstance,
            null,
        ) orelse {
            log.err("failed to create the message-only window", .{});
            return Error.Win32WindowCreationFailed;
        };
        errdefer _ = win32.DestroyWindow(msg_hwnd);

        self.* = .{
            .core_app = core_app,
            .config = config,
            .hinstance = hinstance,
            .get_dpi_for_window = get_dpi_for_window,
            .msg_hwnd = msg_hwnd,
            .surfaces = .empty,
            .quit = false,
            .quit_timer = .off,
            .ticking = false,
            .prompt_depth = 0,
            .modal_loop_depth = 0,
            .terminating = false,
        };

        // The app pointer has to be reachable from the message-only window's
        // wndproc. Unlike surface windows (which receive it via CREATESTRUCTW
        // in WM_NCCREATE) the App does not exist yet at CreateWindowExW time,
        // so it is attached here. No message can be dispatched in between:
        // dispatching only happens in `run`.
        _ = win32.SetWindowLongPtrW(
            msg_hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(self)),
        );
    }

    pub fn terminate(self: *App) void {
        // Every remaining surface is destroyed as destroyPosted does it
        // (Surface.destroy), so that CoreApp.deinit -- which runs after this
        // (in `main`) -- finds an empty surface list and its
        // `font_grid_set.count() == 0` assert holds (`CoreApp.deinit`).
        //
        // `terminating` makes destroyPosted and close ignore anything still
        // queued: stopCore pumps messages, and a WM_GHOSTTY_DESTROY or
        // WM_CLOSE dispatched there must not start a second teardown (or a
        // confirmation prompt) for a surface this loop is about to handle.
        self.terminating = true;

        // Windows are destroyed before the classes they belong to are
        // unregistered; UnregisterClassW fails while a window of the class
        // still exists.
        //
        // Each destroy removes and frees the surface (WM_DESTROY ->
        // surfaceDestroyed). A window that could not be destroyed gets no
        // WM_DESTROY, so it is released here the same way, or this loop
        // would not end.
        while (self.surfaces.getLastOrNull()) |surface| {
            if (!surface.destroy()) {
                log.err("failed to destroy a surface window err={}", .{
                    std.os.windows.GetLastError(),
                });
                self.surfaceDestroyed(surface);
            }
        }
        self.surfaces.deinit(self.core_app.alloc);

        self.stopQuitTimer();

        _ = win32.DestroyWindow(self.msg_hwnd);
        unregisterClasses(self.hinstance);
        self.config.deinit();
    }

    /// The Win32 message loop.
    pub fn run(self: *App) !void {
        // Create the initial window.
        //
        // In a complete runtime this belongs in the `.new_window` action,
        // driven by `CoreApp.newWindow` through the mailbox. `.new_window` is
        // still refused by this runtime (multi-window lifecycle, placement
        // and the quit policy for it are not implemented), so the initial
        // window is created directly here. When `.new_window` is supported,
        // this block moves into `performAction`.
        if (self.config.@"initial-window") {
            _ = self.newSurface() catch |err| {
                log.err("failed to create the initial window err={}", .{err});
                fatalNotice(err);
                return err;
            };
        }

        var msg: win32.MSG = undefined;
        while (!self.quit) {
            // Act on an expired quit timer here rather than where it expired
            // (see `quit_timer`): only here is it known both that the loop
            // has started and that no window is on screen.
            if (self.quit_timer == .expired and self.surfaces.items.len == 0) {
                self.logQuitOverride();
                self.quit = true;
                break;
            }

            // Block until something arrives. `wakeup` posts
            // WM_GHOSTTY_WAKEUP to msg_hwnd, so a mailbox push on any thread
            // breaks this out promptly. A wakeup that lands while we are
            // inside tick() is not lost: it sits in the queue and makes the
            // next GetMessageW return immediately.
            const ret = win32.GetMessageW(&msg, null, 0, 0);
            switch (@intFromEnum(ret)) {
                // GetMessageW reports failure as -1, distinct from the 0 that
                // means WM_QUIT. Treating -1 as "quit" would mask a real bug.
                -1 => {
                    log.err("GetMessageW failed", .{});
                    return Error.Win32MessageLoopFailed;
                },
                0 => break,
                else => {
                    _ = win32.TranslateMessage(&msg);
                    _ = win32.DispatchMessageW(&msg);
                },
            }

            // Drain whatever else is pending so a burst (a resize drag, a
            // flood of wakeups) costs one tick rather than one per message.
            while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
                if (msg.message == win32.WM_QUIT) {
                    self.quit = true;
                    break;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            if (self.quit) break;

            // drainMailbox returns early after dispatching `.quit`, so the
            // queue is not necessarily empty here. The next loop iteration
            // ticks again; `.quit` will have set self.quit if it was seen.
            //
            // `run` is never itself inside a core frame, so `ticking` is
            // always false here and this tick always runs.
            try self.tick();

            // Teardowns that were refused while a core frame or a prompt was
            // on the stack are retried now that neither is.
            self.repostDeferredDestroys();

            // Likewise mouse events a prompt held back, and capture that was
            // lost without a message (Surface.syncMouse).
            self.syncDeferredMouse();

            // And IME work that could not run where it arose (Surface.syncIme).
            self.syncDeferredIme();
        }
    }

    /// Tick the core, unless a tick is already on the stack.
    ///
    /// Reentrancy is possible because a tick can open a modal prompt
    /// (a clipboard confirmation, `Surface.close`), and a prompt's nested
    /// message loop dispatches WM_GHOSTTY_WAKEUP and WM_GHOSTTY_DESTROY.
    /// `drainMailbox` is not written to be reentered, so a nested request is
    /// dropped; the outer tick, or the next one, drains whatever it wanted.
    fn tick(self: *App) !void {
        if (self.ticking) return;
        self.ticking = true;
        defer self.ticking = false;
        try self.core_app.tick(self);
    }

    /// Tick from inside a message handler, where there is no caller to
    /// return an error to. Does nothing unless `canReenterCore`.
    fn tickFromHandler(self: *App) void {
        if (!self.canReenterCore()) return;
        self.tick() catch |err| log.warn("core tick failed err={}", .{err});
    }

    /// Whether a message handler may tick the core or tear a surface down
    /// right now.
    ///
    /// Not while a tick is on the stack (see `tick`). Not while a
    /// confirmation prompt is open either: a prompt usually has a core frame
    /// beneath it, and the teardown a tick can start would free that frame's
    /// surface. The cost is a stall, not a deadlock: output pauses until the
    /// user answers, because nothing drains the app mailbox meanwhile. Surface
    /// teardown is deferred rather than refused (`Surface.destroyPosted`), so
    /// it cannot wait on threads that are blocked on that undrained mailbox.
    fn canReenterCore(self: *const App) bool {
        return !self.ticking and self.prompt_depth == 0;
    }

    /// Re-post WM_GHOSTTY_DESTROY for every surface whose teardown was
    /// deferred. Called by `run` at a point where `canReenterCore` holds.
    fn repostDeferredDestroys(self: *App) void {
        for (self.surfaces.items) |surface| {
            if (!surface.destroy_deferred) continue;
            surface.destroy_deferred = false;
            surface.postDestroy();
        }
    }

    /// Bring every live core surface up to date with the mouse
    /// (`Surface.syncMouse`). A prompt answered from the keyboard then does
    /// not leave a button pressed until the next mouse message, and a drag
    /// whose capture ended without a message ends here. Called by `run`,
    /// where `canReenterCore` holds. The list cannot change during the loop:
    /// no mouse callback creates or destroys a surface (`Surface.close` only
    /// posts).
    fn syncDeferredMouse(self: *App) void {
        for (self.surfaces.items) |surface| {
            const core_surface = surface.liveCore() orelse continue;
            _ = surface.syncMouse(core_surface, null);
        }
    }

    /// Finish the IME work of every live core surface (`Surface.syncIme`).
    /// Called by `run`, where `canReenterCore` holds. A result delivered
    /// here can close a surface, but `Surface.close` only posts, so the
    /// list does not change during the loop.
    fn syncDeferredIme(self: *App) void {
        for (self.surfaces.items) |surface| {
            const core_surface = surface.liveCore() orelse continue;
            surface.syncIme(core_surface);
        }
    }

    /// Wait until the thread `handle` has exited, while keeping the main
    /// thread responsive: messages are dispatched and the core ticked
    /// between wakeups.
    ///
    /// Pumping is required, not cosmetic. The render and IO threads push into
    /// the app mailbox with `.forever` (e.g. the renderer's `frameCompleted`),
    /// and only a tick on this thread drains it; a plain WaitForSingleObject
    /// here could wait on a thread that is waiting on us.
    ///
    /// A WM_QUIT pulled out of the queue while pumping is re-posted
    /// afterwards, so a quit requested meanwhile still ends `run`.
    fn waitForThread(self: *App, handle: win32.HANDLE) void {
        var quit_seen = false;
        defer if (quit_seen) win32.PostQuitMessage(0);

        // One-second slices only so that a stuck thread is reported once;
        // the wait itself is unbounded, as the join after it would be.
        var slices: u32 = 0;
        while (true) {
            // Tick before every wait, not only after new input. A wakeup
            // may already have been consumed without a tick (`wndProc`
            // outside a modal loop, or a prompt's message loop), and a
            // producer blocked in a `.forever` push posts no new one until
            // the mailbox is drained, so waiting for input alone could wait
            // forever. An empty mailbox makes this a single locked pop.
            self.tickFromHandler();

            switch (win32.MsgWaitForMultipleObjectsEx(
                1,
                @ptrCast(&handle),
                1000,
                win32.QS_ALLINPUT,
                // Return for input already in the queue too, not only for
                // input that arrives after the call. Without it a message
                // that was peeked but not removed would not wake us.
                win32.MWMO_INPUTAVAILABLE,
            )) {
                // The thread has exited.
                win32.WAIT_OBJECT_0 => return,

                // Input. The tick at the top of the loop drains whatever
                // the dispatched messages left in the mailbox.
                win32.WAIT_OBJECT_0 + 1 => {
                    var msg: win32.MSG = undefined;
                    while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
                        if (msg.message == win32.WM_QUIT) {
                            quit_seen = true;
                            continue;
                        }
                        _ = win32.TranslateMessage(&msg);
                        _ = win32.DispatchMessageW(&msg);
                    }
                },

                win32.WAIT_TIMEOUT => {
                    slices += 1;
                    if (slices == 5) log.warn(
                        "surface thread has not exited after 5s; still waiting",
                        .{},
                    );
                },

                // WAIT_FAILED (a bad handle). There is nothing to wait on
                // reliably any more; the joins in CoreSurface.deinit that
                // follow will block or fail loudly on their own.
                else => |r| {
                    log.err(
                        "MsgWaitForMultipleObjectsEx failed r={x} err={}",
                        .{ r, std.os.windows.GetLastError() },
                    );
                    return;
                },
            }
        }
    }

    /// Called from the renderer and IO threads via `App.Mailbox.push`
    /// (`CoreApp.Mailbox.push`), so this must be thread-safe and must not
    /// block.
    /// PostMessageW is both.
    pub fn wakeup(self: *App) void {
        _ = win32.PostMessageW(self.msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
    }

    /// `main` in main_ghostty.zig calls this before `run` because a freshly
    /// started app has no surfaces yet.
    pub fn startQuitTimer(self: *App) void {
        // The result is dropped because `main` has nothing to do
        // with it; a failure to arm is already logged by setQuitTimer.
        _ = self.setQuitTimer(.start);
    }

    /// Keyboard layout detection exists only on macOS: `input.Keymap` is
    /// `KeymapNoop` everywhere else (`input.Keymap`). `.unknown` is the
    /// honest answer, and it maps to option-as-alt `.false` at the one call
    /// site (`Surface.encodeKeyOpts`).
    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        _ = self;
        return .unknown;
    }

    /// Actions this runtime actually performs. Anything not named here
    /// returns `false`, which is the contract's word for "unsupported" -- see
    /// the `apprt.Action` docs (actions are OPTIONAL). Returning `true` for an
    /// action that did not
    /// happen would be a lie the core cannot detect.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        return switch (action) {
            .quit => self.requestQuit(),

            // Reports whether the timer actually reached the requested
            // state. A SetTimer that failed means the app will never quit on
            // its own, and `true` would hide that from the core.
            .quit_timer => self.setQuitTimer(value),

            .set_title => self.setTitle(target, value),
            .close_window => self.closeWindow(target),
            .present_terminal => presentTerminal(target),
            .toggle_maximize => toggleMaximize(target),
            .render => render(target),
            .mouse_visibility => mouseVisibility(target, value),
            .mouse_shape => mouseShape(target, value),
            .open_url => self.openUrl(target, value),
            .initial_size => initialSize(target, value),

            .ring_bell => ring_bell: {
                _ = win32.MessageBeep(win32.MB_ICONASTERISK);
                break :ring_bell true;
            },

            // Everything else, including `.new_window` (see `run`),
            // `.cell_size` and `.size_limit` (sent during CoreSurface.init;
            // `false` is a valid answer to each), and
            // `.mouse_over_link` (a link-preview UI this runtime lacks; the
            // core tracks the link itself and ignores the result,
            // `Surface.mouseRefreshLinks`, `Surface.cursorPosCallback`).
            else => false,
        };
    }

    /// The `.quit` action (the `quit` binding, Ctrl+Shift+Q by default).
    /// As on GTK (`Application.quit`), the user is asked first when any
    /// surface would ask before closing (`CoreApp.needsConfirmQuit`): a
    /// running program, `confirm-close-surface = always`, or a read-only
    /// surface. Declining is still a handled request, so this returns `true`
    /// either way.
    fn requestQuit(self: *App) bool {
        if (self.quit) return true;

        if (self.core_app.needsConfirmQuit()) {
            const owner: ?win32.HWND = if (self.core_app.focusedSurface()) |s|
                s.rt_surface.hwnd
            else
                null;
            if (!confirm(
                self,
                owner,
                L("All terminal sessions will be terminated. Quit Ghostty?"),
                .ok,
            )) return true;
        }

        self.quit = true;
        win32.PostQuitMessage(0);
        return true;
    }

    fn setTitle(
        self: *App,
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        _ = self;
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.setTitle(value.title),
        };
    }

    fn closeWindow(self: *App, target: apprt.Target) bool {
        _ = self;
        return switch (target) {
            .app => false,
            // Never DestroyWindow here: this runs inside a core frame (a
            // keybinding, src/Surface.zig keyCallback -> performBindingAction),
            // and destroying synchronously would free the CoreSurface under
            // it. Surface.close confirms if needed and posts the teardown, so
            // every close path -- the title bar button, Alt+F4 (a default
            // binding to this action, `Config.Keybinds.init`) and a
            // child exit -- converges on Surface.destroyPosted.
            //
            // `true` means the request was handled. The user may still decline
            // the confirmation; that is a completed close request, not an
            // unsupported action.
            .surface => |v| close: {
                v.rt_surface.close(v.needsConfirmQuit());
                break :close true;
            },
        };
    }

    fn presentTerminal(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            // SetForegroundWindow returning FALSE is the documented
            // *normal* outcome under Windows' foreground lock -- the calling
            // process is not foreground and has had no recent input -- so
            // hard-coding true here would lie in the common case rather than
            // the rare one.
            .surface => |v| win32.SetForegroundWindow(v.rt_surface.hwnd).toBool(),
        };
    }

    /// Records the size `window-width`/`window-height` ask for. The core
    /// sends it from CoreSurface.init and again whenever the cell size
    /// changes (`Surface.recomputeInitialSize`); `Surface.create` applies it
    /// once, before the window is first shown. Later values are stored but
    /// never resize a live window, as on GTK (`setDefaultSize` in the
    /// window's surface init) and macOS (`initialSize` on a new window).
    fn initialSize(target: apprt.Target, value: apprt.action.InitialSize) bool {
        return switch (target) {
            .app => false,
            .surface => |v| stored: {
                v.rt_surface.initial_size = value;
                break :stored true;
            },
        };
    }

    fn toggleMaximize(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| maximize: {
                const surface = v.rt_surface;
                surface.maximized = !surface.maximized;
                // ShowWindow's BOOL is the window's *previous* visibility, not
                // whether the call succeeded, so it deliberately is not
                // propagated: a window that was hidden returns zero from a
                // call that worked perfectly.
                _ = win32.ShowWindow(
                    surface.hwnd,
                    if (surface.maximized) win32.SW_MAXIMIZE else win32.SW_RESTORE,
                );
                break :maximize true;
            },
        };
    }

    /// Nothing to do: the render thread presents its own frames
    /// (src/renderer/d3d11/Frame.zig), and the backend does not even send
    /// this action. An InvalidateRect here would only start a WM_PAINT ->
    /// refreshCallback -> frame cycle for a frame already on screen.
    fn render(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => true,
        };
    }

    /// `.mouse_visibility`, per window: the core hides the pointer while
    /// typing and shows it on the next mouse event (`Surface.hideMouse`).
    /// Applied in the window's WM_SETCURSOR rather than with ShowCursor,
    /// whose counter covers the whole thread: it would also hide the pointer
    /// over the title bar and borders, where the core never sees a move that
    /// could show it again, and outlive a window destroyed while hidden.
    fn mouseVisibility(target: apprt.Target, value: apprt.action.MouseVisibility) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.setMouseVisibility(value),
        };
    }

    /// `.mouse_shape`: the pointer shape over the terminal, per window.
    fn mouseShape(target: apprt.Target, shape: terminal.MouseShape) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.setMouseShape(shape),
        };
    }

    /// Open a link with its registered handler, the shell's `open` verb.
    ///
    /// An OSC 8 target is program output, and the shell would pass any
    /// scheme on: `file:` runs executables and a custom scheme starts
    /// whatever registered it. Only a well-formed http, https or mailto
    /// link is opened from one (`osc8Allowed`); anything else is refused
    /// with a notice. The refusal reports `true`: `false` would send the
    /// same link to the core's generic opener (`Surface.openUrl`)
    /// and bypass the policy. The other kinds are link text the user can
    /// see, or paths the core resolved from it, and open unchanged.
    ///
    /// Nothing here may dispatch messages: the core calls this while
    /// holding its renderer lock (`Surface.mouseButtonCallback`), and the next
    /// mouse move dispatched on this thread would take that lock again in
    /// cursorPosCallback. The notice is therefore posted and shown once
    /// this frame has returned, and ShellExecuteW, which blocks until the
    /// handler has started and may dispatch messages while it waits, runs
    /// on its own thread, as the core's opener does (src/os/open.zig).
    fn openUrl(self: *App, target: apprt.Target, value: apprt.action.OpenUrl) bool {
        const hwnd = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.hwnd,
        };

        if (value.kind == .osc8 and !osc8Allowed(value.url)) {
            log.warn("refused an OSC 8 link: not a well-formed http, https or mailto target", .{});
            _ = win32.PostMessageW(hwnd, WM_GHOSTTY_LINK_REFUSED, 0, 0);
            return true;
        }

        const alloc = self.core_app.alloc;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, value.url) catch |err| {
            log.warn("open url: cannot convert the target err={}", .{err});
            return false;
        };
        const thread = std.Thread.spawn(.{}, openUrlThread, .{ alloc, wide }) catch |err| {
            alloc.free(wide);
            log.warn("open url: cannot start the opener thread err={}", .{err});
            return false;
        };
        thread.detach();
        return true;
    }

    /// Arm or cancel the quit-after-last-window timer. Returns whether the
    /// requested state was actually reached; `.quit_timer` reports it to the
    /// core verbatim.
    fn setQuitTimer(self: *App, mode: apprt.action.QuitTimer) bool {
        // Cancel any previous timer first: `.start` can arrive again before
        // `.stop` (the core re-sends it as surfaces come and go).
        self.stopQuitTimer();

        switch (mode) {
            .stop => return true,

            .start => {
                // The apprt owns the quit-after-last-window policy, and this
                // foundation deliberately overrides the configuration.
                //
                // `quit-after-last-window-closed` is `builtin.os.tag == .linux`
                // (`Config.@"quit-after-last-window-closed"`), i.e. false on
                // Windows. But `.new_window` is refused by this runtime (see
                // `run`), so a process that reaches zero windows has no UI left
                // and no way to get one back. Honoring `false` would leave an
                // invisible process with a message-only window that receives
                // nothing and a GetMessageW that blocks forever, endable only
                // from Task Manager.
                //
                // Delete this override -- not the config read -- as soon as
                // `.new_window` can actually create a window.
                //
                // The override is reported by logQuitOverride where the quit is
                // carried out, not here: `.start` also arrives at launch, from
                // startQuitTimer, for a quit that newSurface cancels, so
                // logging here would report quits that never happen.

                const delay_ms: u64 = if (self.config.@"quit-after-last-window-closed-delay") |v|
                    v.asMilliseconds()
                else
                    0;

                // A zero delay must not quit synchronously: startQuitTimer
                // runs before run() does. Record the expiry and let run()
                // decide; see the `quit_timer` field.
                if (delay_ms == 0) {
                    self.quit_timer = .expired;
                    return true;
                }

                if (win32.SetTimer(
                    self.msg_hwnd,
                    quit_timer_id,
                    std.math.cast(win32.UINT, delay_ms) orelse std.math.maxInt(win32.UINT),
                    null,
                ) == 0) {
                    log.warn("failed to arm the quit timer", .{});
                    return false;
                }

                self.quit_timer = .active;
                return true;
            },
        }
    }

    fn stopQuitTimer(self: *App) void {
        switch (self.quit_timer) {
            .off => {},
            .expired => self.quit_timer = .off,
            .active => {
                _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
                self.quit_timer = .off;
            },
        }
    }

    /// The quit timer's WM_TIMER on `msg_hwnd`.
    ///
    /// KillTimer does not remove a WM_TIMER that is already queued, so one
    /// can still arrive after `stopQuitTimer` (a `.stop` from
    /// `CoreApp.addSurface`). Only a timer that is still armed expires;
    /// expiring any other would quit with a window on screen.
    fn quitTimerFired(self: *App) void {
        if (self.quit_timer != .active) return;

        // Window timers repeat until killed.
        _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
        self.quit_timer = .expired;
    }

    /// Report that the process is quitting because of the override in
    /// setQuitTimer rather than because the configuration asked for it.
    /// Called only from `run`, where that quit is carried out.
    fn logQuitOverride(self: *const App) void {
        if (self.config.@"quit-after-last-window-closed") return;
        log.info(
            "quitting despite quit-after-last-window-closed=false: " ++
                "this runtime cannot open a new window",
            .{},
        );
    }

    /// Create a terminal window. See `run` for why this is not driven by
    /// the `.new_window` action.
    fn newSurface(self: *App) !*Surface {
        const alloc = self.core_app.alloc;
        try self.surfaces.ensureUnusedCapacity(alloc, 1);

        // Surface.create registers the surface with the core, and
        // CoreApp.addSurface cancels the startup quit timer
        // itself, so there is no quit-timer handling here.
        const surface = try Surface.create(self);
        errdefer comptime unreachable;
        self.surfaces.appendAssumeCapacity(surface);

        return surface;
    }

    /// Called from the surface's WM_DESTROY handler, and by `terminate` for
    /// a window that could not be destroyed.
    ///
    /// Ownership invariant: **membership in `self.surfaces` is ownership of
    /// the heap allocation.** A window whose Surface is not in the list is
    /// still owned by whoever is constructing or tearing it down, so this
    /// returns without freeing. That is what makes `Surface.create`'s errdefer
    /// chain safe -- DestroyWindow reenters here before the surface is
    /// registered, and a free here would be a double free.
    fn surfaceDestroyed(self: *App, surface: *Surface) void {
        const idx = idx: {
            for (self.surfaces.items, 0..) |s, i| {
                if (s == surface) break :idx i;
            }
            return;
        };

        // The HWND outlives its Surface by one message: WM_NCDESTROY is
        // still to come. Clear the back-pointer so wndProc's `v == 0` guard
        // catches it instead of forming a *Surface into freed memory.
        _ = win32.SetWindowLongPtrW(surface.hwnd, win32.GWLP_USERDATA, 0);

        _ = self.surfaces.swapRemove(idx);
        surface.deinit();
        self.core_app.alloc.destroy(surface);

        // The quit timer is not handled here: CoreApp.deleteSurface, which
        // Surface.stopCore calls before the window is destroyed, starts it
        // when the core's last surface goes (`CoreApp.deleteSurface`).
    }

    /// The message-only window's procedure.
    fn wndProc(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        const self: *App = ptr: {
            const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
            if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
        };

        switch (msg) {
            // Normally there is nothing to do but return: the message
            // existing is the point, and `run` ticks the core after every
            // dispatched message.
            //
            // Inside a system modal loop (a size/move drag, the window menu)
            // `run` does not get control back until the loop ends, so the
            // mailbox would go undrained for the whole drag -- output stops,
            // and the render and IO threads can block on `.forever` pushes.
            // Those loops are entered from DefWindowProcW, never from inside
            // a core frame, so ticking here is safe; canReenterCore still
            // guards against the one exception, a prompt beneath the loop.
            WM_GHOSTTY_WAKEUP => {
                if (self.modal_loop_depth > 0) self.tickFromHandler();
                return 0;
            },

            // `run` quits once the timer has expired, the next time round
            // its loop.
            win32.WM_TIMER => if (wparam == quit_timer_id) {
                self.quitTimerFired();
                return 0;
            },

            else => {},
        }

        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
};

/// Log the DPI awareness actually in effect for this thread.
///
/// SetProcessDpiAwarenessContext's return value cannot distinguish a manifest
/// that already selected PerMonitorV2 from a genuine failure, so the effective
/// context is queried instead of inferred. Both functions exist only from
/// Windows 10 1607 and are resolved by name for the same reason as the other
/// DPI entry points; see win32.SetProcessDpiAwarenessContextFn.
fn logEffectiveDpiAwareness(user32: win32.HMODULE) void {
    const get_p = win32.GetProcAddress(user32, "GetThreadDpiAwarenessContext") orelse return;
    const eq_p = win32.GetProcAddress(user32, "AreDpiAwarenessContextsEqual") orelse return;
    const get_ctx: win32.GetThreadDpiAwarenessContextFn = @ptrCast(@alignCast(get_p));
    const ctx_eq: win32.AreDpiAwarenessContextsEqualFn = @ptrCast(@alignCast(eq_p));

    // Documented never to return NULL; the optional return type and this
    // branch are defensive, since the declaration is ours rather than the SDK's.
    const current = get_ctx() orelse {
        log.warn("could not query the effective DPI awareness", .{});
        return;
    };
    if (ctx_eq(current, win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).toBool()) {
        log.debug("DPI awareness is per-monitor v2", .{});
    } else {
        log.warn(
            "DPI awareness is not per-monitor v2; the system will scale this " ++
                "window's contents on high-DPI displays",
            .{},
        );
    }
}

pub const Surface = struct {
    app: *App,

    /// The core surface, embedded by value because the core requires
    /// `core()` to return `&self.core_surface` and because
    /// `apprt.Target.cval` round-trips through `rt_surface`.
    ///
    /// Initialized only while `core_state != .none`; see `CoreState`. Use
    /// `liveCore` from message handlers rather than this field directly.
    core_surface: CoreSurface,

    core_state: CoreState,

    /// The window handle. Written from WM_NCCREATE, which is the first
    /// message this window receives, so it is valid in every other handler.
    hwnd: win32.HWND,

    /// The current window title, owned by this struct. `getTitle` reads it
    /// back to answer CSI 21 t; a native runtime has to store it itself.
    title: ?[:0]u8,

    /// Tracked so `.toggle_maximize` knows which way to toggle.
    maximized: bool,

    /// The client size the core asked for through `.initial_size`, or null
    /// when `window-width`/`window-height` are unset. The core divides the
    /// cell area by the content scale but adds the padding in device pixels
    /// (`CoreSurface.recomputeInitialSize`), so the value is not purely in
    /// 96-DPI units; see `applyInitialSize`.
    initial_size: ?apprt.action.InitialSize,

    /// A close has been requested and WM_GHOSTTY_DESTROY posted (or its
    /// confirmation is on screen). Stops a second WM_CLOSE or close_window
    /// from prompting or posting twice. Cleared only when the user declines
    /// the confirmation.
    closing: bool,

    /// WM_GHOSTTY_DESTROY arrived while teardown was not allowed
    /// (`App.canReenterCore` was false). `App.run` re-posts it.
    destroy_deferred: bool,

    /// Who put the text that is in the core's preedit slot: a dead key
    /// (`keyEvent`) or an IME composition. The core has one slot, keeps no
    /// owner and never clears it itself (`Surface.preeditCallback`), so each
    /// source must only clear what it set. Written by `setPreedit` alone.
    preedit: Ime.Preedit,

    ime: Ime,

    /// A high surrogate that ended the last character text, kept for the
    /// low surrogate the next one starts with. SendInput with
    /// KEYEVENTF_UNICODE sends a character outside the BMP as one
    /// VK_PACKET keystroke per UTF-16 unit, and TranslateMessage posts one
    /// WM_CHAR for each, so the halves arrive with separate keystrokes.
    /// See `Text.finish`.
    high_surrogate: ?u16,

    /// Keys whose last press was AltGr's, by `Ime.scanSlot`. See
    /// `altGrKey`.
    alt_gr: std.StaticBitSet(512),

    /// See `ShiftKeys`.
    shift: ShiftKeys,

    /// Number of WM_PAINTs handled, for the debug log in `paint`.
    paint_count: u64,

    /// This window's share of `App.modal_loop_depth`: system modal loops
    /// (size/move, menu) it has entered and not yet reported leaving. A
    /// window destroyed inside its own loop never receives the matching
    /// WM_EXIT*, so WM_DESTROY hands this back to the app instead.
    modal_loops: u32,

    /// Keyboard focus, from WM_SETFOCUS / WM_KILLFOCUS. See `mouseMods`.
    focused: bool,

    /// Mouse state, and what the core is still owed. See `Mouse`.
    mouse: Mouse,

    /// The lifecycle of `core_surface`.
    ///
    /// A three-state enum rather than a single `initialized` flag because
    /// teardown pumps messages (`App.waitForThread`): between
    /// `deleteSurface` and `CoreSurface.deinit` the core surface is still
    /// initialized memory, but its threads are stopping and the app no longer
    /// knows it, so message handlers must not call into it. `.stopping` makes
    /// that state distinct instead of an implied combination of flags.
    const CoreState = enum {
        /// `core_surface` is undefined memory: before `CoreSurface.init` in
        /// `create`, or after `CoreSurface.deinit` in `stopCore`.
        none,
        /// Initialized and registered with the core app. Callbacks allowed.
        live,
        /// `stopCore` is running. Initialized, not registered, no callbacks.
        stopping,
    };

    /// IME composition state and the decisions that need no window.
    ///
    /// The composition string is drawn by the core as preedit, so the
    /// runtime consumes WM_IME_COMPOSITION instead of letting DefWindowProcW
    /// translate it: the result string is then read exactly once here, and
    /// no WM_IME_CHAR or WM_CHAR is ever generated from it.
    const Ime = struct {
        /// Between WM_IME_STARTCOMPOSITION (or the first composition
        /// string) and WM_IME_ENDCOMPOSITION. It decides whether a
        /// composition has to be ended on focus loss and whether an `.ime`
        /// preedit is stale. It never decides whether a result is
        /// delivered: Korean IMEs can send the last result after the end.
        composing: bool = false,

        /// The forms last given to the IME, or null to issue them again.
        /// Each Imm call sends WM_IME_NOTIFY back into the window
        /// procedure, so unchanged forms are not sent again.
        form: ?Form = null,

        /// Result text, as UTF-8, that arrived while the core could not be
        /// entered (`imeCore`). `flushIme` delivers it before any later
        /// input. Owned; freed in `stopCore` and `deinit`.
        pending: std.ArrayListUnmanaged(u8) = .empty,

        /// Keys whose key-down the core never saw, by `scanSlot`: the IME
        /// claimed it (VK_PROCESSKEY), it was a digit of Alt+numpad entry
        /// (`isAltNumpad`), or it opened the window menu
        /// (`isWindowMenuKey`). Their key-up is kept from the core as well.
        swallow_up: std.StaticBitSet(512) = .initEmpty(),

        const Preedit = enum {
            none,
            dead_key,
            ime,

            /// Whether committed text replaces this preedit. Any preedit
            /// does, as in GTK (src/apprt/gtk/class/surface.zig imCommit):
            /// a dead key's accent is not left drawn after the IME's text.
            fn clearedByCommit(self: Preedit) bool {
                return self != .none;
            }
        };

        const Action = enum {
            /// preeditCallback(null).
            clear_preedit,
            /// Read GCS_RESULTSTR and send it to the core as text.
            commit_result,
            /// Read GCS_RESULTSTR and keep it in `pending`.
            defer_result,
            /// Read GCS_COMPSTR: show it as the preedit, or clear the
            /// preedit if it is empty.
            update_preedit,
        };

        const Plan = struct {
            buf: [3]Action = undefined,
            len: usize = 0,

            fn add(self: *Plan, action: Action) void {
                self.buf[self.len] = action;
                self.len += 1;
            }

            fn actions(self: *const Plan) []const Action {
                return self.buf[0..self.len];
            }
        };

        /// What a WM_IME_COMPOSITION asks for, in order. `bits` is its
        /// lParam, `owner` the current preedit owner, and `core_safe`
        /// whether the core may be entered (`imeCore`).
        ///
        /// `composing` is deliberately not an input: a result is delivered
        /// whether or not a composition is thought to be open.
        ///
        /// Only a message with no GCS flag at all is a cancellation. One
        /// with other flags but neither string flag (a caret or clause
        /// change) is a live update, and IMEs are known to misreport
        /// GCS_COMPSTR, so the string is read again for every message that
        /// is not a bare result, as Firefox and WezTerm do.
        fn plan(bits: u32, owner: Preedit, core_safe: bool) Plan {
            var p: Plan = .{};
            const gcs = bits & win32.GCS_ALL;
            if (gcs == 0) {
                if (core_safe and owner == .ime) p.add(.clear_preedit);
                return p;
            }

            // The result first: it precedes the composition string that
            // may follow it in the same message (Korean commits a syllable
            // and starts the next one at once).
            const result = gcs & win32.GCS_RESULTSTR != 0;
            if (result) {
                if (core_safe) {
                    if (owner.clearedByCommit()) p.add(.clear_preedit);
                    p.add(.commit_result);
                } else {
                    p.add(.defer_result);
                }
            }

            // Without the core the composition string is dropped: the
            // window has lost the focus to a prompt, and the next update
            // after it shows the string again.
            const bare_result = result and gcs & win32.GCS_COMPSTR == 0;
            if (!bare_result and core_safe) p.add(.update_preedit);
            return p;
        }

        const Form = struct {
            /// Bottom-left of the cursor cell, for the composition form: an
            /// IME that anchors its candidate list there opens it below the
            /// row (winit does the same).
            pt: win32.POINT,
            /// The cells of the preedit, for the candidate form: the list
            /// must not cover them.
            rc: win32.RECT,
        };

        /// The forms for the core's IME position. `pos` is in 96-DPI
        /// pixels except for its width, which the core leaves in physical
        /// pixels (`Surface.imePoint`); `scale` is `getContentScale` and
        /// `client` the client rectangle, in physical pixels like the
        /// result. Clamping guards against rounding and against a client
        /// size the core has not caught up with yet.
        fn formFor(pos: apprt.IMEPos, scale: f64, cell_w: u32, client: win32.RECT) Form {
            const cw: f64 = @floatFromInt(cell_w);
            // The core reports the middle of the cursor cell and its bottom.
            const left = @round(pos.x * scale - cw / 2);
            const bottom = @round(pos.y * scale);
            const top = bottom - @round(pos.height * scale);
            const right = left + @max(@round(pos.width), cw);
            // Never inverted, whatever the core reports.
            const l = clampLong(left, client.left, client.right);
            const b = clampLong(bottom, client.top, client.bottom);
            const rc: win32.RECT = .{
                .left = l,
                .top = @min(b, clampLong(top, client.top, client.bottom)),
                .right = @max(l, clampLong(right, client.left, client.right)),
                .bottom = b,
            };
            return .{ .pt = .{ .x = rc.left, .y = rc.bottom }, .rc = rc };
        }

        fn clampLong(v: f64, lo: win32.LONG, hi: win32.LONG) win32.LONG {
            // Written so that NaN takes the first branch.
            if (!(v > @as(f64, @floatFromInt(lo)))) return lo;
            if (v >= @as(f64, @floatFromInt(hi))) return hi;
            return @intFromFloat(v);
        }

        /// A key message's scan code and extended-key flag (lParam bits
        /// 16-24), which identify the physical key on both its messages.
        fn scanSlot(lparam: win32.LPARAM) usize {
            return (@as(usize, @bitCast(lparam)) >> 16) & 0x1FF;
        }

        /// WM_IME_SETCONTEXT's lParam without the request to show the
        /// IME's composition window. The flag is bit 31 of a value that
        /// arrives sign-extended.
        fn setContextLparam(lparam: win32.LPARAM) win32.LPARAM {
            return @bitCast(@as(usize, @bitCast(lparam)) & ~win32.ISC_SHOWUICOMPOSITIONWINDOW);
        }

        const KeyFilter = enum {
            /// Not for the core: an IME-owned keystroke (VK_PROCESSKEY), or
            /// the release of a press the core never saw. A release
            /// without a press would be reported to programs that ask for
            /// key releases.
            withhold,
            /// For the core.
            deliver,
            /// For the core, but the key's previous press was withheld
            /// (`isAltNumpad` decides a repeat from that).
            deliver_withheld,
        };

        /// Whether a key message reaches the core, given `swallow_up`.
        /// The IME claims a keystroke by sending its key-down as
        /// VK_PROCESSKEY; the key-up may come with the real virtual key, so
        /// it is matched by `scanSlot`. A VK_PROCESSKEY key-up leaves the
        /// slot set, and the key's next key-down clears it.
        fn filterKey(
            self: *Ime,
            msg: win32.UINT,
            wparam: win32.WPARAM,
            lparam: win32.LPARAM,
        ) KeyFilter {
            const slot = scanSlot(lparam);
            if (wparam == win32.VK_PROCESSKEY) {
                if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) self.swallow_up.set(slot);
                return .withhold;
            }
            if (!self.swallow_up.isSet(slot)) return .deliver;
            self.swallow_up.unset(slot);
            return if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP)
                .withhold
            else
                .deliver_withheld;
        }

        /// How a composition still open when the window loses the focus
        /// is ended (`syncIme`), for input language `lang`. Korean is
        /// completed, because a Hangul composition string is text the
        /// user already sees as typed, with no conversion step to confirm;
        /// other languages are cancelled, so that half-converted text does
        /// not reach a shell the user is no longer looking at.
        fn focusLossAction(lang: u16) win32.DWORD {
            return if (win32.primaryLangId(lang) == win32.LANG_KOREAN)
                win32.CPS_COMPLETE
            else
                win32.CPS_CANCEL;
        }
    };

    /// What the core has been told about the mouse.
    ///
    /// Invariants:
    ///   * `held`: buttons the core has seen pressed and not released. Only
    ///     non-empty after this window asked for the capture (`mouseButton`).
    ///   * `owed`: disjoint from `held`. Buttons that are no longer down, or
    ///     whose release may not come here, while the core still has them
    ///     pressed. Only `syncMouse` delivers it; `stopCore` discards it with
    ///     the core.
    ///   * `pos`: the last position given to cursorPosCallback, or
    ///     `outside`. `getCursorPos` returns it.
    const Mouse = struct {
        pos: apprt.CursorPos,
        held: Button.Set,
        owed: Button.Set,
        /// A WM_MOUSELEAVE the core has not been told about.
        leave_owed: bool,
        /// TrackMouseEvent(TME_LEAVE) is armed.
        tracking: bool,
        /// Where the left button last went down. `syncMouse` places a
        /// release it has to invent away from it.
        left_press_pos: apprt.CursorPos,
        wheel_x: Notches,
        wheel_y: Notches,
        /// The last `.mouse_shape` and its stock cursor, applied in
        /// WM_SETCURSOR. `cursor` is null only if LoadCursorW failed; the
        /// class arrow shows then.
        shape: terminal.MouseShape,
        cursor: ?win32.HCURSOR,
        /// `.mouse_visibility`: hidden while typing.
        hidden: bool,

        /// "Not over the surface" to cursorPosCallback and link hover, which
        /// treat any negative coordinate that way
        /// (`Surface.cursorPosCallback`, `Surface.mouseRefreshLinks`). Paths
        /// that map a position to a cell clamp it to the nearest cell
        /// instead (the `.grid` arm of `renderer.size.Coordinate.convert`).
        const outside: apprt.CursorPos = .{ .x = -1, .y = -1 };

        fn init() Mouse {
            return .{
                .pos = outside,
                .held = .empty,
                .owed = .empty,
                .leave_owed = false,
                .tracking = false,
                .left_press_pos = outside,
                .wheel_x = .{},
                .wheel_y = .{},
                // The core starts at `.text` and never sends that first
                // shape (`Terminal.mouse_shape`); the GTK runtime
                // starts there too.
                .shape = .text,
                .cursor = win32.LoadCursorW(null, cursorId(.text)),
                .hidden = false,
            };
        }

        /// What `syncMouse` sends the core, from `sync`.
        const Sync = struct {
            /// Releases to send at `releasePoint`.
            release: Button.Set = .empty,
            /// The last held button is now owed while this window still has
            /// the capture, so the capture is released.
            release_capture: bool = false,
            /// A leave, after the releases.
            leave: bool = false,
        };

        /// Take what the core is owed (`syncMouse`). `captured` is whether
        /// this window has the mouse capture, and `down` the buttons the
        /// current message reports down, or null without a message.
        ///
        /// A held button is owed its release once the capture is gone or
        /// `down` says it is up. A leave follows the releases only when no
        /// button is still held, since a position outside would drag to an
        /// edge cell; with no release to send, only an owed leave is sent.
        fn sync(self: *Mouse, captured: bool, down: ?Button.Set) Sync {
            var result: Sync = .{};
            if (self.held.count() != 0) {
                const gone = if (!captured)
                    self.held
                else if (down) |d|
                    self.held.differenceWith(d)
                else
                    Button.Set.empty;
                if (gone.count() != 0) {
                    self.owed.setUnion(gone);
                    self.held = self.held.differenceWith(gone);
                    result.release_capture = captured and self.held.count() == 0;
                }
            }

            result.release = self.owed;
            self.owed = .empty;
            result.leave = if (result.release.count() != 0)
                self.held.count() == 0
            else
                self.leave_owed;
            if (result.leave) self.leave_owed = false;
            return result;
        }

        /// The buttons this runtime reports: a separate enum from
        /// input.MouseButton, so nothing else can be sent.
        ///   * `.unknown` would mask motion reports;
        ///   * `.four`-`.seven` are the wheel, which scrollCallback reports;
        ///   * `.eleven` indexes past the end of the core's click_state
        ///     (`CoreSurface.Mouse.click_state`, indexed in
        ///     `Surface.mouseButtonCallback`).
        /// The last point is checked at comptime at the end of the file.
        const Button = enum {
            left,
            right,
            middle,
            x1,
            x2,

            const Set = std.EnumSet(Button);

            fn fromMessage(msg: win32.UINT, wparam: win32.WPARAM) ?Button {
                return switch (msg) {
                    win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
                    win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .right,
                    win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => .middle,
                    // GET_XBUTTON_WPARAM. Any other value is left to
                    // DefWindowProcW.
                    win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => switch (win32.hiword(wparam)) {
                        win32.XBUTTON1 => .x1,
                        win32.XBUTTON2 => .x2,
                        else => null,
                    },
                    else => null,
                };
            }

            /// The buttons a mouse message's wParam reports as down.
            fn downIn(wparam: win32.WPARAM) Set {
                var set: Set = .empty;
                if (wparam & win32.MK_LBUTTON != 0) set.insert(.left);
                if (wparam & win32.MK_RBUTTON != 0) set.insert(.right);
                if (wparam & win32.MK_MBUTTON != 0) set.insert(.middle);
                if (wparam & win32.MK_XBUTTON1 != 0) set.insert(.x1);
                if (wparam & win32.MK_XBUTTON2 != 0) set.insert(.x2);
                return set;
            }

            /// Back and forward are X11 buttons 8 and 9, as GTK and macOS
            /// map them.
            fn core(self: Button) input.MouseButton {
                return switch (self) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    .x1 => .eight,
                    .x2 => .nine,
                };
            }
        };

        /// Whole core scroll ticks out of wheel deltas.
        ///
        /// A notch (WHEEL_DELTA) scrolls the system's lines per notch, or
        /// characters per notch for the horizontal wheel (`wheelSetting`).
        /// Windows' default of 3 is one tick, which the default
        /// mouse-scroll-multiplier also scrolls as 3 rows
        /// (`Surface.scrollCallback`), and other settings scale the ticks:
        /// 6 is two ticks a notch, 1 is one tick every third notch.
        ///
        /// The core cannot take fractions of a tick
        /// (`Surface.scrollCallback`): for x it rounds each event and keeps
        /// no remainder, and for y it drops the remainder whenever an event
        /// crosses a row (it stores `poff - amount * cell_size` with the
        /// untruncated `amount`). A high-resolution wheel's small deltas, and
        /// settings that are not a multiple of 3, would lose rows either
        /// way, so only whole ticks are passed on. A change of direction
        /// drops the remainder, so a reversal counts from its own first
        /// delta.
        const Notches = struct {
            /// In 1/WHEEL_DELTA of a line (or character).
            rem: i64 = 0,

            /// Windows' default lines and characters per notch.
            const per_tick = 3;

            fn add(self: *Notches, delta: i32, per_notch: u32) ?i64 {
                if (delta == 0 or per_notch == 0) return null;
                if (self.rem != 0 and (self.rem < 0) != (delta < 0)) self.rem = 0;
                self.rem += @as(i64, delta) * per_notch;
                const tick = win32.WHEEL_DELTA * per_tick;
                const whole = @divTrunc(self.rem, tick);
                if (whole == 0) return null;
                self.rem -= whole * tick;
                return whole;
            }
        };
    };

    /// Heap-allocate and initialize, including the core surface. The address
    /// must be stable: the core stores raw `*apprt.Surface` pointers
    /// (see `CoreSurface.init`), and the wndproc recovers this pointer from
    /// GWLP_USERDATA.
    fn create(app: *App) !*Surface {
        const alloc = app.core_app.alloc;
        const self = try alloc.create(Surface);
        errdefer alloc.destroy(self);

        self.* = .{
            .app = app,
            .core_surface = undefined,
            .core_state = .none,
            // `hwnd` is written from WM_NCCREATE, the first message this
            // window receives, so it is set before anything can read it.
            .hwnd = undefined,
            .title = null,
            .maximized = false,
            .initial_size = null,
            .closing = false,
            .destroy_deferred = false,
            .preedit = .none,
            .ime = .{},
            .high_surrogate = null,
            .alt_gr = .initEmpty(),
            .shift = .{},
            .paint_count = 0,
            .modal_loops = 0,
            .focused = false,
            .mouse = .init(),
        };

        const hwnd = win32.CreateWindowExW(
            0,
            L(surface_class_name),
            L("Ghostty"),
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            null,
            null,
            app.hinstance,
            self,
        ) orelse {
            log.err("CreateWindowExW failed for a surface window", .{});
            return App.Error.Win32WindowCreationFailed;
        };
        // Safe alongside the errdefer above only because of the ownership
        // invariant on App.surfaceDestroyed: WM_DESTROY reenters the app but
        // will not free a surface that is not yet in App.surfaces.
        errdefer _ = win32.DestroyWindow(hwnd);

        // Registration comes before init: every surface message the core
        // routes is checked with `CoreApp.hasSurface`, so a
        // message queued before registration would be dropped. addSurface
        // also cancels the startup quit timer.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Preconditions CoreSurface.init relies on, both true here: the HWND
        // exists at CW_USEDEFAULT size so getSize is non-zero
        // (`CoreSurface.init` reads it), and getContentScale works on it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
        defer config.deinit();
        // A failing CoreSurface.init joins any thread it started (unpumped,
        // as CoreSurface.deinit does), so the errdefers above run with no
        // core thread left using this surface or its window.
        try self.core_surface.init(alloc, &config, app.core_app, app, self);

        // Nothing below can fail, so the core surface needs no errdefer.
        errdefer comptime unreachable;
        self.core_state = .live;

        // Size the still-hidden window to `window-width`/`window-height`
        // before it is first shown, so it never appears at the default size.
        if (self.initial_size) |size| self.applyInitialSize(size);

        // The first WM_SETFOCUS and WM_PAINT (and the first WM_SIZE, unless
        // applyInitialSize already sent one) reach the core from here, now
        // that `core_state` is `.live`.
        _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);
        _ = win32.UpdateWindow(hwnd);

        return self;
    }

    /// Release everything except the window and the allocation itself.
    ///
    /// Public because `CoreApp.deinit` calls it on every surface the core
    /// still tracks -- an apprt contract method the rt_surface list does not
    /// name. Like the embedded runtime's deinit, this removes the surface
    /// from that list while the core iterates it (stopCore's
    /// `deleteSurface`). In this runtime the list is empty by then, since
    /// `App.terminate` destroys every surface first.
    pub fn deinit(self: *Surface) void {
        self.stopCore();
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.title = null;
        self.ime.pending.clearAndFree(self.app.core_app.alloc);
    }

    /// Stop the core surface, then destroy the window. Returns whether the
    /// window was destroyed; **when it was, `self` has been freed**
    /// (WM_DESTROY -> App.surfaceDestroyed) and nothing may touch it.
    fn destroy(self: *Surface) bool {
        self.stopCore();
        return win32.DestroyWindow(self.hwnd).toBool();
    }

    /// The core surface, if message handlers may call into it.
    fn liveCore(self: *Surface) ?*CoreSurface {
        return switch (self.core_state) {
            .live => &self.core_surface,
            .none, .stopping => null,
        };
    }

    /// Stop and deinitialize the core surface, keeping the main thread
    /// responsive while its threads wind down. A no-op unless `.live`.
    ///
    /// The order is load-bearing:
    ///
    ///   1. `deleteSurface` first, so the ticks in steps 2-4 drop any message
    ///      still addressed to this surface instead of calling into it
    ///      (`CoreApp.hasSurface`). It also starts the quit timer when this was
    ///      the last surface.
    ///   2. Stop the search thread, if any, and wait for it as in step 3,
    ///      while the render thread is still draining its mailbox.
    ///      `CoreSurface.deinit` would do this first too, but with an
    ///      unpumped join, and by then the render thread is gone. The search
    ///      thread pushes with `.forever` into both the renderer mailbox and
    ///      the app mailbox (`Surface.searchCallback_`, including the `.quit`
    ///      event it sends on exit), and only a tick on this thread drains the
    ///      app mailbox, which the still running IO thread can keep full.
    ///      Clearing `search` makes deinit skip it.
    ///   3. Stop the IO thread and wait for it (`App.waitForThread`, which
    ///      pumps messages and ticks), still before the renderer. Its reader
    ///      can also block on a `.forever` renderer mailbox push
    ///      (`StreamHandler.rendererMessageWriter`), and `Exec.threadExit`
    ///      cannot cancel a thread that is not in I/O. Upstream
    ///      `CoreSurface.deinit` stops the renderer first; this order is
    ///      deliberately the reverse. Nothing the render thread does waits on
    ///      the IO thread (it only pushes to the app mailbox, which the ticks
    ///      drain), and the terminal state both share is freed only in step 5.
    ///   4. Stop the render thread and wait for it the same way. Its exit
    ///      marks the display unrealized and releases the shaders and the
    ///      swap chain (`threadExit` in src/renderer/generic.zig), so no
    ///      unrealize is needed first.
    ///   5. `CoreSurface.deinit`. Its notifications repeat harmlessly (an
    ///      xev Async notify on a stopped loop only posts an unread
    ///      completion) and its joins return at once.
    ///
    /// Steps 2-4 reach into CoreSurface fields rather than adding a core
    /// API. That duplicates a few statements of `CoreSurface.deinit`, which
    /// is the least invasive option: the alternative, joining inside deinit
    /// on the main thread, is exactly the unpumped wait steps 2-4 exist to
    /// avoid. If those fields are renamed this stops compiling, which is the
    /// desired failure.
    fn stopCore(self: *Surface) void {
        if (self.core_state != .live) return;
        self.core_state = .stopping;

        // A drag in progress ends with the core. Button messages for a
        // `.stopping` surface are not handled, so nothing else would release
        // the capture while this pumps messages (App.waitForThread).
        if (self.mouse.held.count() != 0) {
            self.mouse.held = .empty;
            if (self.hasCapture()) _ = win32.ReleaseCapture();
        }
        self.mouse.owed = .empty;
        self.mouse.leave_owed = false;

        // No mouse event reaches the core from here on, so the core cannot
        // show a pointer it hid while typing; WM_SETCURSOR would keep it
        // hidden over the window for the rest of the teardown.
        self.mouse.hidden = false;
        self.applyCursor();

        // A composition ends with the core too: nothing is left to draw its
        // preedit or to take its result. The IME is not told; the window is
        // about to be destroyed, and ImmNotifyIME would send its messages
        // back into this teardown.
        self.ime.pending.clearAndFree(self.app.core_app.alloc);
        self.ime.composing = false;
        self.ime.form = null;
        self.preedit = .none;

        const app = self.app;
        const cs = &self.core_surface;

        app.core_app.deleteSurface(self);

        if (cs.search) |*s| {
            s.state.stop.notify() catch |err|
                log.err("error notifying search thread to stop err={}", .{err});
            app.waitForThread(s.thread.getHandle());

            // The thread has exited, so the join in deinit returns at once
            // and its repeated notify only posts an unread completion.
            s.deinit();
            cs.search = null;
        }

        cs.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop err={}", .{err});
        app.waitForThread(cs.io_thr.getHandle());

        cs.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop err={}", .{err});
        app.waitForThread(cs.renderer_thr.getHandle());

        cs.deinit();
        self.core_state = .none;
    }

    /// Ask for this window to be torn down from a message loop.
    fn postDestroy(self: *Surface) void {
        if (!win32.PostMessageW(self.hwnd, WM_GHOSTTY_DESTROY, 0, 0).toBool()) {
            // Only fails when the queue is full (10,000 messages). The window
            // stays open; the user can close it again.
            log.err("failed to post the surface teardown err={}", .{
                std.os.windows.GetLastError(),
            });
            self.closing = false;
        }
    }

    /// WM_GHOSTTY_DESTROY: the one place a live surface is torn down.
    ///
    /// Runs from a message loop -- `run`'s, a system modal loop's, or
    /// `App.waitForThread` -- never directly inside a core frame, because
    /// the message is only ever posted. When a core frame or prompt is
    /// nonetheless beneath that loop (`App.canReenterCore`), the teardown is
    /// deferred to `run` instead: its pump would tick, and waiting there
    /// could wait on threads blocked behind the undrained mailbox.
    ///
    /// **`self` is freed by the `destroy` at the end**. Nothing may touch it
    /// afterwards, which is why the function ends at that call.
    fn destroyPosted(self: *Surface) void {
        const app = self.app;

        // terminate drives teardown itself; see App.terminate.
        if (app.terminating) return;

        if (!app.canReenterCore()) {
            self.destroy_deferred = true;
            return;
        }

        _ = self.destroy();
    }

    // ---------------------------------------------------------------------
    // The rt_surface contract
    // ---------------------------------------------------------------------

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    /// The core asks the runtime to close this surface. `process_alive` means
    /// a child process is still running and the user should be asked.
    ///
    /// This is called from inside core frames (`Surface.childExited`,
    /// `Surface.keyCallback`) and so must never destroy
    /// anything itself: it posts WM_GHOSTTY_DESTROY and returns. That is also
    /// why a `.closed` InputEffect leaves `self` valid in `keyEvent`.
    ///
    /// `*Surface` rather than `*const`: the core calls this through a mutable
    /// `rt_surface` (`CoreSurface.close`).
    pub fn close(self: *Surface, process_alive: bool) void {
        if (self.app.terminating) return;

        // A second WM_CLOSE while the prompt below is up, or a close_window
        // binding after the teardown was already posted.
        if (self.closing) return;
        self.closing = true;

        if (process_alive and !confirm(
            self.app,
            self.hwnd,
            L("A process is still running in this terminal. Close it anyway?"),
            .ok,
        )) {
            // `self` is still valid: `confirm` raises `prompt_depth`, so no
            // teardown can run inside its modal loop (destroyPosted defers),
            // and nothing but destroyPosted destroys a surface window.
            self.closing = false;
            return;
        }

        self.postDestroy();
    }

    /// Resize the window so its client area is `size` scaled to this
    /// window's DPI. The whole value is scaled, as macOS and GTK also treat
    /// it, so the core's device-pixel padding comes out larger by the scale
    /// factor: the grid is never smaller than requested, at most a little
    /// larger. The frame is measured from the window itself rather than with
    /// AdjustWindowRectExForDpi, which does not exist before Windows 10 1607
    /// (see the dynamic imports in App.init): the window already exists at
    /// its final DPI, so its window rect minus its client rect is exactly the
    /// frame. The sizes saturate, since `window-width` is only clamped from
    /// below; Windows then clamps an oversized request to the maximum track
    /// size as it does any other.
    fn applyInitialSize(self: *Surface, size: apprt.action.InitialSize) void {
        const scale = (self.getContentScale() catch unreachable).x;
        const client_w = std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(size.width)) * scale));
        const client_h = std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(size.height)) * scale));
        var window: win32.RECT = undefined;
        var client: win32.RECT = undefined;
        if (!win32.GetWindowRect(self.hwnd, &window).toBool() or
            !win32.GetClientRect(self.hwnd, &client).toBool())
        {
            log.warn("unable to read the window frame, initial size not applied", .{});
            return;
        }
        const frame_w = (window.right - window.left) - (client.right - client.left);
        const frame_h = (window.bottom - window.top) - (client.bottom - client.top);
        // SetWindowPos sends WM_SIZE synchronously; the core is live, so it
        // sees the new size before the first paint. That WM_SIZE also reports
        // the window visible (occlusionCallback) while it is still hidden,
        // which is harmless only because ShowWindow follows immediately.
        if (!win32.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            client_w +| frame_w,
            client_h +| frame_h,
            win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        ).toBool()) log.warn("unable to apply initial window size err={}", .{std.os.windows.GetLastError()});
    }

    /// The ratio of this window's DPI to the Windows reference DPI of 96.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        const scale: f32 = @as(f32, @floatFromInt(self.dpi())) /
            @as(f32, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
        return .{ .x = scale, .y = scale };
    }

    /// This window's DPI, falling back to the reference 96 when it cannot be
    /// determined. Never returns 0: scaling by zero would silently produce a
    /// zero-size grid rather than an error anybody could see.
    fn dpi(self: *const Surface) u32 {
        // Resolved at runtime, not statically imported -- GetDpiForWindow does
        // not exist before Windows 10 1607 and a static import would stop the
        // binary loading there at all. See App.init.
        if (self.app.get_dpi_for_window) |f| {
            // Returns 0 for an invalid window.
            const v = f(self.hwnd);
            if (v != 0) return v;
        }

        // Pre-1607 fallback. This is the *correct* answer on those versions:
        // they have no per-monitor DPI, so the system-wide value is the only
        // one there is.
        if (win32.GetDC(null)) |screen| {
            defer _ = win32.ReleaseDC(null, screen);
            const v = win32.GetDeviceCaps(screen, win32.LOGPIXELSX);
            if (v > 0) return @intCast(v);
        }

        return win32.USER_DEFAULT_SCREEN_DPI;
    }

    /// Client area in physical pixels.
    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        var rect: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &rect).toBool()) {
            return App.Error.Win32CallFailed;
        }

        return .{
            .width = @intCast(@max(0, rect.right - rect.left)),
            .height = @intCast(@max(0, rect.bottom - rect.top)),
        };
    }

    /// The pointer position of the mouse event being delivered, in client
    /// device pixels: the last position given to cursorPosCallback, or
    /// `Mouse.outside`. Negative values mean "outside the viewport" to
    /// `Surface.cursorPosCallback` and are passed through unclamped.
    ///
    /// Cached rather than read live, because the core reads a button or
    /// wheel event's position back through here (`Surface.scrollCallback`,
    /// `Surface.mouseButtonCallback`) after the live pointer may have moved
    /// on. After a leave, a live read would also give a point beyond the
    /// window, which the core clamps to an edge cell instead of treating as
    /// outside. The embedded runtime caches it the same way.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.mouse.pos;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    /// Windows has exactly one system clipboard. There is no X11-style
    /// primary selection and no separate selection clipboard.
    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => false,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        // The Kitty protocol requests own an arena that holds the request
        // struct itself (`KittyRead.destroy`, `KittyWrite.destroy` in
        // apprt/structs.zig) -- but the apprt does
        // NOT own that arena here, and destroying it would be a double free.
        //
        // The core destroys the request itself for every answer other than
        // `.started`: `Surface.kittyClipboardRead` and
        // `Surface.kittyClipboardWrite` both `defer req.destroy()`. Worse,
        // the ENOSYS reply it builds reads `req.id` and `req.terminator`,
        // which live *in* that arena, after we return. Ownership only
        // transfers on `.started`, and then only to
        // `Surface.completeClipboardRequest` or
        // `Surface.denyClipboardRequest`, which destroy it themselves.
        switch (state) {
            .kitty_read, .kitty_write => return .unsupported,

            // The core routes OSC 52 writes straight to setClipboard; they
            // never reach this function (`Surface.startClipboardRequest`).
            .osc_52_write => return .unsupported,

            .paste, .osc_52_read, .list => {},
        }

        if (!self.supportsClipboard(clipboard_type)) return .unsupported;

        const alloc = self.app.core_app.alloc;

        if (state == .list) {
            if (!win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT).toBool()) {
                return .unavailable;
            }

            try self.core_surface.completeClipboardRequest(state, .{
                .available = &.{text_mime},
            });
            return .started;
        }

        const text = (try readClipboardText(alloc, self.hwnd)) orelse return .unavailable;
        defer alloc.free(text);

        const contents: []const terminal.clipboard.Content = &.{.{
            .mime = text_mime,
            .data = text,
        }};

        self.core_surface.completeClipboardRequest(state, .{
            .contents = contents,
        }) catch |err| switch (err) {
            // The request is still alive in this case and the apprt owns the
            // confirmation flow.
            //
            // MessageBoxW runs a nested modal loop. Win32 messages keep
            // pumping, but `core_app.tick` does not (`confirm` raises
            // App.prompt_depth), so the mailbox goes undrained for as long as
            // the prompt is up and renderer and IO output stalls behind it.
            // That is deliberate: this runs inside a tick, and the same guard
            // defers any surface teardown dispatched meanwhile, so `self` is
            // still valid for the completeClipboardRequest calls below. The
            // stall goes away when this becomes an in-window prompt driven
            // from the core's own confirmation UI.
            error.UnsafePaste, error.UnauthorizedPaste => {
                if (confirm(
                    self.app,
                    self.hwnd,
                    clipboardReadPrompt(state),
                    .cancel,
                )) {
                    try self.core_surface.completeClipboardRequest(state, .{
                        .contents = contents,
                        .confirmed = true,
                    });
                } else {
                    self.core_surface.denyClipboardRequest(state);
                }
            },
            else => return err,
        };

        return .started;
    }

    /// Write text to the clipboard.
    ///
    /// `confirm` means the configuration asked for the write to be approved by
    /// the user. This runtime has no in-window prompt, so it uses a modal
    /// MessageBoxW rather than writing unasked -- crude, but it does not
    /// quietly drop the user's configured safeguard.
    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm_write: bool,
    ) !void {
        if (!self.supportsClipboard(clipboard_type)) return;

        const text: []const u8 = text: {
            for (contents) |c| {
                if (terminal.clipboard.isTextMime(c.mime)) break :text c.data;
            }

            // Nothing text-like to write. Silently doing nothing is correct:
            // Windows has no way to hold the other representations here.
            log.debug("clipboard write had no text representation", .{});
            return;
        };

        if (confirm_write and !confirm(
            self.app,
            self.hwnd,
            L("An application wants to write to the clipboard. Allow it?"),
            .cancel,
        )) return;

        // An error, not a bare `return`, on every failure: the core must not
        // believe a copy landed when it did not.
        try writeClipboardText(self.hwnd, text);
    }

    /// The environment the child process starts from. The caller takes
    /// ownership and then mutates it (`CoreSurface.init`).
    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        return try global.environMap();
    }

    // ---------------------------------------------------------------------
    // Win32 message handling
    // ---------------------------------------------------------------------

    /// Set the window title and remember it for `getTitle`. Returns false if
    /// the title could not be applied, which is what `.set_title` reports.
    ///
    /// The core validates only OSC titles; one from the `title` config, a
    /// keybinding or a command's argv[0] can be any bytes. Invalid UTF-8 is
    /// shown as U+FFFD, as macOS does, and the title is stored as given.
    fn setTitle(self: *Surface, title: [:0]const u8) bool {
        const alloc = self.app.core_app.alloc;

        const wide = wideFromUtf8(alloc, title) catch |err| {
            log.warn("failed to encode the window title err={}", .{err});
            return false;
        };
        defer alloc.free(wide);

        if (!win32.SetWindowTextW(self.hwnd, wide.ptr).toBool()) {
            log.warn("SetWindowTextW failed", .{});
            return false;
        }

        // Stored only after SetWindowTextW succeeds: this returns bool, so an
        // errdefer would never run.
        const copy = alloc.dupeZ(u8, title) catch |err| {
            log.warn("failed to store the window title err={}", .{err});
            return false;
        };

        if (self.title) |old| alloc.free(old);
        self.title = copy;
        return true;
    }

    /// WM_PAINT. The render thread draws and presents on its own; all the
    /// main thread does is clear the update region and ask the core for a
    /// frame.
    fn paint(self: *Surface) void {
        // ValidateRect, not BeginPaint/EndPaint: the update region still has
        // to be cleared -- otherwise Windows re-posts WM_PAINT forever and the
        // loop spins at 100% CPU -- and nothing here draws, so no DC is
        // needed.
        _ = win32.ValidateRect(self.hwnd, null);

        // Every paint is logged at debug level, which is compiled out of
        // release builds (`std_options.log_level` in main_ghostty.zig). Without
        // it a stale frame on screen cannot be told apart from a repaint that
        // never ran. The present side (count, dropped stale frames) is logged
        // by src/renderer/D3D11.zig.
        self.paint_count += 1;
        const n = self.paint_count;
        const id = @intFromPtr(self.hwnd);

        // A paint can arrive from inside CreateWindowExW, before the core
        // surface exists; `create` shows the window only after it does.
        const core_surface = self.liveCore() orelse {
            log.debug("paint #{d} hwnd={x}: validated, no live core surface", .{ n, id });
            return;
        };

        // refreshCallback, not CoreSurface.draw: WM_PAINT only needs the
        // render thread woken, as embedded's `ghostty_surface_refresh` does.
        // A synchronous draw from this thread is still allowed, since every
        // renderer must permit `CoreSurface.draw` from the apprt's thread,
        // and is what a live-resize path would use.
        core_surface.refreshCallback() catch |err| {
            log.warn("paint #{d} hwnd={x}: refresh failed err={}", .{ n, id, err });
            return;
        };
        log.debug("paint #{d} hwnd={x}: refresh requested", .{ n, id });
    }

    fn handleMessage(
        self: *Surface,
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) win32.LRESULT {
        // Until `core_state` is `.live` every handler below keeps the
        // pre-core behaviour. That matters: messages arrive inside
        // CreateWindowExW, long before CoreSurface.init. Callback errors are
        // logged and never propagated; there is no caller to take them.
        switch (msg) {
            win32.WM_CLOSE => {
                // The title bar button, Alt+F4 when no binding consumed it,
                // and the window menu's Close.
                if (self.app.terminating) return 0;
                switch (self.core_state) {
                    // CoreSurface.close -> Surface.close applies
                    // needsConfirmQuit and posts the teardown.
                    .live => self.core_surface.close(),
                    // Already going away.
                    .stopping => {},
                    // No core surface, so nothing to confirm or stop. This
                    // frees `self` (WM_DESTROY); nothing follows it.
                    .none => _ = win32.DestroyWindow(hwnd),
                }
                return 0;
            },

            WM_GHOSTTY_LINK_REFUSED => {
                // Dropped once the surface is going away: the notice would
                // only hold up the teardown that pumps this message.
                if (self.core_state == .live) {
                    notice(self.app, hwnd, L(
                        "Ghostty did not open this link.\n\n" ++
                            "A link printed by a program is only opened when it is an http, https or mailto link.",
                    ));
                }
                return 0;
            },

            WM_GHOSTTY_DESTROY => {
                // Frees `self` unless deferred; nothing may follow it.
                self.destroyPosted();
                return 0;
            },

            win32.WM_DESTROY => {
                // Every path that destroys a live surface stops the core
                // first (Surface.destroy), so this is only
                // defensive: tear down now, late but in the right order,
                // rather than delete a context the render thread still has
                // current. `.stopping` cannot be seen here: nothing destroys
                // the window while stopCore is pumping.
                if (self.core_state == .live) {
                    log.warn("surface window destroyed with a live core surface", .{});
                    self.stopCore();
                }

                // Destroyed inside its own size/move or menu loop (e.g. the
                // child exited mid-drag): the WM_EXIT* for that loop will not
                // come, so return this window's share of the depth now.
                // Otherwise every later wakeup would tick from whatever loop
                // dispatched it.
                self.app.modal_loop_depth -|= self.modal_loops;
                self.modal_loops = 0;

                self.app.surfaceDestroyed(self);
                return 0;
            },

            win32.WM_SIZE => {
                self.ime.form = null;
                const core_surface = self.liveCore() orelse return 0;
                const change: SizeChange = .init(wparam, lparam);

                // Every WM_SIZE but a minimize means visible. Sent
                // unconditionally; the core ignores repeats
                // (`Surface.occlusionCallback`).
                core_surface.occlusionCallback(change != .minimized) catch |err|
                    log.warn("occlusion callback failed err={}", .{err});

                switch (change) {
                    .minimized, .empty => {},
                    .resize => |size| core_surface.sizeCallback(size) catch |err|
                        log.warn("size callback failed err={}", .{err}),
                }
                return 0;
            },

            win32.WM_DPICHANGED => {
                self.ime.form = null;
                // The new scale first: SetWindowPos below sends WM_SIZE
                // synchronously, so the core sees the scale before the size
                // computed for it. wParam carries the new DPI in both words;
                // they are always equal for a window.
                if (self.liveCore()) |core_surface| {
                    const scale = @as(f32, @floatFromInt(win32.hiword(wparam))) /
                        @as(f32, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
                    core_surface.contentScaleCallback(.{ .x = scale, .y = scale }) catch |err|
                        log.warn("content scale callback failed err={}", .{err});
                }

                // lParam carries the suggested new window rect. Not honoring
                // it leaves the window the wrong physical size on the new
                // monitor, so it is applied verbatim.
                const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = win32.SetWindowPos(
                    hwnd,
                    null,
                    rect.left,
                    rect.top,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
                );
                return 0;
            },

            win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
                self.focused = msg == win32.WM_SETFOCUS;

                if (!self.focused) {
                    // A drag does not survive losing focus (Alt+Tab, a
                    // dialog, the Start menu). The capture may outlive the
                    // focus change, and the button-up then goes to another
                    // window. Releasing it lets syncMouse send the core that
                    // release. Only a Win32 call here: this message is sent,
                    // possibly from inside a core frame (a paste
                    // confirmation taking focus).
                    const dragging = self.mouse.held.count() != 0;
                    if (dragging and self.hasCapture()) _ = win32.ReleaseCapture();

                    // An open composition does not survive it either, but
                    // ending one makes the IME send its messages straight
                    // back into this window procedure.
                    const composing = self.ime.composing or self.preedit == .ime;

                    // Both wait for `App.run` (syncDeferredMouse,
                    // syncDeferredIme). The wakeup makes `run` come round
                    // now, since a sent message does not; otherwise the
                    // release waits for some later message to this thread.
                    if (dragging or composing) self.app.wakeup();
                }
                self.ime.form = null;

                if (self.liveCore()) |core_surface| {
                    core_surface.focusCallback(msg == win32.WM_SETFOCUS) catch |err|
                        log.warn("focus callback failed err={}", .{err});
                }
                return 0;
            },

            // The system modal loops. See App.wndProc's WM_GHOSTTY_WAKEUP.
            win32.WM_ENTERSIZEMOVE, win32.WM_ENTERMENULOOP => {
                self.modal_loops += 1;
                self.app.modal_loop_depth += 1;
                return 0;
            },
            win32.WM_EXITSIZEMOVE, win32.WM_EXITMENULOOP => {
                // Only undo what this window added, so a stray EXIT can
                // never take another window's loop out of the count.
                if (self.modal_loops > 0) {
                    self.modal_loops -= 1;
                    self.app.modal_loop_depth -|= 1;
                }
                return 0;
            },

            win32.WM_IME_SETCONTEXT => {
                // The composition string is drawn as the core's preedit, so
                // the IME must not show its own composition window. The
                // message is still forwarded: the default IME window needs
                // it to activate the context, and keeps the candidate list.
                if (comptime std.log.logEnabled(.debug, .win32)) {
                    log.debug("ime setcontext active={} lang=0x{x}", .{ wparam != 0, inputLanguage() });
                }
                return win32.DefWindowProcW(hwnd, msg, wparam, Ime.setContextLparam(lparam));
            },

            // Not forwarded: DefWindowProcW would open the composition
            // window (start) and turn the result into WM_IME_CHARs and
            // then WM_CHARs (composition), delivering the text twice.
            win32.WM_IME_STARTCOMPOSITION => {
                self.imeStart();
                return 0;
            },
            win32.WM_IME_COMPOSITION => {
                self.imeComposition(lparam);
                return 0;
            },

            // Forwarded, so the default IME window releases what it holds.
            // A change of input language ends a composition too, and the
            // outgoing IME is not required to say so.
            win32.WM_IME_ENDCOMPOSITION, win32.WM_INPUTLANGCHANGE => {
                self.imeEnd();
            },

            // Neither is answered: WM_IME_CHAR only comes from a forwarded
            // WM_IME_COMPOSITION, which never happens here, and the
            // Microsoft IMEs work without WM_IME_REQUEST answers even though
            // they send one (IMR_* in wParam) on nearly every keystroke.
            win32.WM_IME_CHAR, win32.WM_IME_REQUEST => {
                // log.debug("ime message=0x{x} wparam=0x{x}", .{ msg, wparam });
            },

            win32.WM_KEYDOWN,
            win32.WM_SYSKEYDOWN,
            win32.WM_KEYUP,
            win32.WM_SYSKEYUP,
            => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);

                const slot = Ime.scanSlot(lparam);
                const withheld = switch (self.ime.filterKey(msg, wparam, lparam)) {
                    .withhold => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
                    .deliver => false,
                    .deliver_withheld => true,
                };

                // The synthetic Left Ctrl of AltGr. The core still sees Ctrl
                // held (GetKeyState) and keyEvent's AltGr rule handles that.
                if (isAltGrFakeCtrl(wparam, lparam)) {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                const mods = currentMods();

                // Alt+Space (Alt alone) opens the window menu, as in every
                // Windows app, unless a binding claims it. The menu must
                // bypass the core entirely: DefWindowProcW opens it from the
                // WM_SYSCHAR ' ' that TranslateMessage posted, so keyEvent
                // must not remove that message either. This has to be
                // decided before keyEvent, not from an `.ignored` result.
                // The key-up is withheld like an IME key's.
                menu: {
                    const vk: win32.UINT = @truncate(wparam);
                    const action = keyAction(msg, lparam);
                    if (!isWindowMenuKey(action, vk, mods)) break :menu;

                    const scan = scanCode(vk, lparam);
                    const bound = core_surface.keyEventIsBinding(.{
                        .action = action,
                        .key = keyFromScan(scan),
                        .mods = mods,
                        .unshifted_codepoint = unshiftedCodepoint(vk, scan),
                    });
                    if (bound != null) break :menu;

                    self.ime.swallow_up.set(slot);
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                // Alt+numpad entry: TranslateMessage collects the digits and
                // posts the character as WM_CHAR when Alt is released, which
                // reaches strayChar. The digits themselves must not reach the
                // core, or the encoder would send them ahead of the
                // character. The key-up is withheld like an IME key's.
                if (isAltNumpad(keyAction(msg, lparam), @truncate(wparam), mods, withheld)) {
                    self.ime.swallow_up.set(slot);
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                const effect = self.keyEvent(core_surface, msg, wparam, lparam, mods) catch |err| {
                    log.warn("key callback failed err={}", .{err});
                    return 0;
                };
                return switch (effect) {
                    // `.closed` only posted WM_GHOSTTY_DESTROY (Surface.close),
                    // so `self` is still valid -- but nothing here needs it.
                    .consumed, .closed => 0,
                    // Unhandled keys keep their system meaning: Alt and F10
                    // reach WM_SYSCOMMAND (suppressed below), Alt+F4 becomes
                    // SC_CLOSE if no binding took it.
                    .ignored => win32.DefWindowProcW(hwnd, msg, wparam, lparam),
                };
            },

            win32.WM_CHAR,
            win32.WM_DEADCHAR,
            win32.WM_SYSCHAR,
            win32.WM_SYSDEADCHAR,
            => {
                // Normally never seen: keyEvent removes the characters its
                // keydown produced. What arrives here came without a keydown
                // to attach it to: a character produced on a key-up (Alt+
                // numpad entry posts its WM_CHAR when Alt is released, and
                // keyEvent collects text only for presses), a character
                // another program posted, or a keydown the core surface did
                // not exist for yet.

                // Alt+Space's WM_SYSCHAR, deliberately left in the queue by
                // the keydown handler: DefWindowProcW turns it into
                // SC_KEYMENU with lParam ' ', which opens the window menu.
                if (msg == win32.WM_SYSCHAR and wparam == ' ') {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                if (self.liveCore()) |core_surface| {
                    self.strayChar(core_surface, msg, wparam);
                }

                // Always handled. For WM_SYSCHAR this is also what stops
                // DefWindowProcW from beeping about a missing menu mnemonic.
                return 0;
            },

            win32.WM_SYSCOMMAND => {
                // A bare Alt or F10 released without being consumed arrives
                // as SC_KEYMENU with lParam 0 and would put the window into
                // menu mode, swallowing the next keystroke. The window has no
                // menu bar, so that mode is never wanted. Alt+Space arrives
                // with lParam ' ' and still opens the window menu.
                if (wparam & 0xFFF0 == win32.SC_KEYMENU and lparam == 0) return 0;
            },

            win32.WM_MOUSEMOVE => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                if (!self.syncMouse(core_surface, Mouse.Button.downIn(wparam))) return 0;
                self.armLeave();
                self.movePointer(core_surface, clientPos(lparam), self.mouseMods(wparam));
                return 0;
            },

            win32.WM_MOUSELEAVE => {
                // Win32 has cancelled the tracking.
                self.mouse.tracking = false;
                if (self.liveCore()) |core_surface| {
                    // During a drag the captured moves keep the core
                    // informed, negative positions included, which drag
                    // autoscroll needs. The release re-arms tracking to learn
                    // where the drag ended.
                    if (self.mouse.held.count() == 0) self.mouse.leave_owed = true;
                    _ = self.syncMouse(core_surface, null);
                }
                return 0;
            },

            win32.WM_LBUTTONDOWN,
            win32.WM_LBUTTONUP,
            win32.WM_RBUTTONDOWN,
            win32.WM_RBUTTONUP,
            win32.WM_MBUTTONDOWN,
            win32.WM_MBUTTONUP,
            win32.WM_XBUTTONDOWN,
            win32.WM_XBUTTONUP,
            => {
                const button = Mouse.Button.fromMessage(msg, wparam) orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                const state: input.MouseButtonState = switch (msg) {
                    win32.WM_LBUTTONDOWN,
                    win32.WM_RBUTTONDOWN,
                    win32.WM_MBUTTONDOWN,
                    win32.WM_XBUTTONDOWN,
                    => .press,
                    else => .release,
                };
                self.mouseButton(
                    core_surface,
                    button,
                    state,
                    wparam,
                    clientPos(lparam),
                    self.mouseMods(wparam),
                );

                // Never DefWindowProcW once a button is handled: for X
                // buttons it sends WM_APPCOMMAND (browser back/forward), and
                // a handled X button must return TRUE; for WM_RBUTTONUP its
                // only default is WM_CONTEXTMENU, and there is no menu. The
                // class has no CS_DBLCLKS, so no *BUTTONDBLCLK arrives: the
                // core counts clicks itself, within click-repeat-interval,
                // which defaults to the system double-click time
                // (`internal_os.clickInterval`).
                const is_x = msg == win32.WM_XBUTTONDOWN or msg == win32.WM_XBUTTONUP;
                return @intFromBool(is_x);
            },

            win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                if (!self.syncMouse(core_surface, Mouse.Button.downIn(wparam))) return 0;

                // Programs with mouse reporting get the wheel at the
                // position getCursorPos returns, and drop a report at
                // `outside` (`mouse_encode.encode`), while without reporting
                // the same wheel scrolls the viewport. When the pointer is
                // over this client area the message is a move like any
                // other: after a capture loss the cache says `outside` until
                // the next move. Otherwise (the pointer is over the frame, or
                // elsewhere and the wheel came by focus) the report goes to
                // the nearest client cell for this message only. That is not
                // a move, so link hover and the leave stand.
                var kept: ?apprt.CursorPos = null;
                defer if (kept) |pos| {
                    self.mouse.pos = pos;
                };
                if (self.wheelPoint(lparam)) |point| {
                    if (point.over) {
                        self.armLeave();
                        self.movePointer(core_surface, point.pos, self.mouseMods(wparam));
                    } else {
                        kept = self.mouse.pos;
                        self.mouse.pos = point.pos;
                    }
                }

                const delta: i32 = win32.wheelDelta(wparam);
                if (msg == win32.WM_MOUSEWHEEL) {
                    // "One screen at a time" is as many lines as the screen
                    // has rows.
                    const lines = wheelSetting(win32.SPI_GETWHEELSCROLLLINES);
                    const per_notch: u32 = if (lines == win32.WHEEL_PAGESCROLL)
                        core_surface.size.grid().rows
                    else
                        lines;

                    // Positive is away from the user: the core's "up"
                    // (`Surface.scrollCallback`'s doc comment).
                    if (self.mouse.wheel_y.add(delta, per_notch)) |ticks| {
                        core_surface.scrollCallback(0, @floatFromInt(ticks), .{}) catch |err|
                            log.warn("scroll callback failed err={}", .{err});
                    }
                } else if (self.mouse.wheel_x.add(
                    delta,
                    wheelSetting(win32.SPI_GETWHEELSCROLLCHARS),
                )) |ticks| {
                    // Positive is to the right here. The core's positive x
                    // is reported as button 6, X11's scroll-left
                    // (`Surface.scrollCallback`), and GTK negates its
                    // rightward delta to match; so does this.
                    core_surface.scrollCallback(@floatFromInt(-ticks), 0, .{}) catch |err|
                        log.warn("scroll callback failed err={}", .{err});
                }
                return 0;
            },

            win32.WM_SETCURSOR => {
                // Client area only. Elsewhere DefWindowProcW sets the arrow
                // or a resize arrow, which also keeps a pointer hidden while
                // typing visible over the frame. Over the client area it
                // would restore the class arrow on every move.
                if (win32.loword(lparam) == win32.HTCLIENT and
                    (self.mouse.hidden or self.mouse.cursor != null))
                {
                    _ = win32.SetCursor(self.clientCursor());
                    return 1;
                }
            },

            win32.WM_MOUSEACTIVATE => {
                // A click on an inactive window only activates it, as on
                // macOS: it must not clear the selection, move the prompt
                // cursor, or reach a program that reads the mouse. Client
                // area only, so an inactive window can still be dragged by
                // its caption. The button-up that may follow is dropped by
                // mouseButton, because the press was never recorded.
                if (win32.loword(lparam) == win32.HTCLIENT) return win32.MA_ACTIVATEANDEAT;
            },

            win32.WM_PAINT => {
                self.paint();
                return 0;
            },

            // The render thread presents every pixel of the client area, so
            // letting GDI erase first would only produce a flash of the class
            // background. The first real frame follows the first WM_PAINT's
            // refresh.
            win32.WM_ERASEBKGND => return 1,

            else => {},
        }

        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    /// Translate a key message into a core KeyEvent and deliver it.
    ///
    /// Win32 splits one keystroke across two messages: the WM_(SYS)KEYDOWN
    /// being handled, and the WM_(SYS)CHAR / WM_(SYS)DEADCHAR that
    /// TranslateMessage posted *before* that keydown was dispatched
    /// (App.run, waitForThread). The core wants both in one event, so the
    /// characters are pulled out of the queue here.
    fn keyEvent(
        self: *Surface,
        core_surface: *CoreSurface,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
        mods_in: input.Mods,
    ) !CoreSurface.InputEffect {
        const vk: win32.UINT = @truncate(wparam);
        const scan = scanCode(vk, lparam);
        const action = keyAction(msg, lparam);

        // VK_PACKET is injected text (SendInput with KEYEVENTF_UNICODE: on-
        // screen keyboards, some remote-desktop clients). It is not a
        // physical key, and its lParam scan field is not guaranteed to be
        // zero, so it must not be matched against the keycode table, where
        // it could alias a real key and fire that key's bindings. Its text
        // still arrives through the WM_CHAR collected below.
        const is_packet = wparam == win32.VK_PACKET;

        const key: input.Key = if (is_packet) .unidentified else numpadKey(keyFromScan(scan), vk);

        // Collected before `keyText` flushes the IME's text, so that
        // nothing the flush triggers can dispatch the queued WM_CHAR out of
        // turn.
        var text: Text = .{};
        if (action != .release) text.collect(self.hwnd, &self.high_surrogate);

        const unshifted: u21 = if (is_packet) 0 else unshiftedCodepoint(vk, scan);
        const shiftless: u21 = if (is_packet or !mods_in.shift) unshifted else shiftless: {
            // The state as of this message, like currentMods. On failure
            // the unshifted codepoint is the best guess left.
            var state: [256]win32.BYTE = undefined;
            if (!win32.GetKeyboardState(&state).toBool()) break :shiftless unshifted;
            break :shiftless shiftlessCodepoint(vk, scan, &state);
        };

        const alt_gr = altGrKey(&self.alt_gr, Ime.scanSlot(lparam), action, mods_in, &text);
        const effect = try self.keyText(core_surface, .{
            .action = action,
            .key = key,
            .mods = mods_in,
            .unshifted_codepoint = unshifted,
        }, &text, shiftless, alt_gr);
        self.shift.sent(key, action);

        // With both Shift keys held, Windows sends no key-up for the first
        // one released, only for the last (GLFW's win32_window.c releases
        // both Shift keys on any Shift key-up for this reason). The core is
        // owed the missing release, or a program that asks for modifier key
        // events holds that Shift down forever.
        if (vk == win32.VK_SHIFT and action == .release and effect != .closed) {
            const owed = self.shift.owed(
                win32.GetKeyState(win32.VK_LSHIFT) < 0,
                win32.GetKeyState(win32.VK_RSHIFT) < 0,
            );
            if (owed) |other| {
                _ = try core_surface.keyCallback(.{
                    .action = .release,
                    .key = other,
                    .mods = currentMods(),
                });
                self.shift.sent(other, .release);
            }
        }

        return effect;
    }

    /// Send the core a key event carrying `text`, for `keyEvent` and
    /// `strayChar`. `event.mods` is the state the key was read with; the
    /// mods reported are `keyMods`'s, given the key's codepoint with Shift
    /// released (`shiftless`) and whether the keystroke is AltGr's.
    fn keyText(
        self: *Surface,
        core_surface: *CoreSurface,
        event: input.KeyEvent,
        text: *const Text,
        shiftless: u21,
        alt_gr: bool,
    ) !CoreSurface.InputEffect {
        // Text the IME committed earlier comes first.
        if (self.app.canReenterCore()) self.flushIme(core_surface);

        // A dead key shows its accent as preedit until the next committed
        // text replaces it. The core does not track this itself
        // (`Surface.preeditCallback`).
        if (text.composing) {
            try self.setPreedit(core_surface, text.utf8(), .dead_key);
        } else if (self.preedit == .dead_key and text.len > 0) {
            try self.setPreedit(core_surface, null, .none);
        }

        const mods = keyMods(event.mods, text, shiftless, alt_gr);
        var ev = event;
        ev.mods = mods.mods;
        ev.consumed_mods = mods.consumed;
        ev.composing = text.composing;
        ev.utf8 = text.utf8();
        return try core_surface.keyCallback(ev);
    }

    const KeyMods = struct {
        mods: input.Mods,
        consumed: input.Mods = .{},
    };

    /// The modifiers to report for a keystroke that produced `text`, given
    /// the state the key message was read with, the key's codepoint in
    /// that state with Shift released (shiftlessCodepoint), and whether the
    /// keystroke is AltGr's (`isAltGr`, `altGrKey`).
    fn keyMods(mods_in: input.Mods, text: *const Text, shiftless: u21, alt_gr: bool) KeyMods {
        var result: KeyMods = .{ .mods = mods_in };

        // AltGr's Ctrl+Alt is taken out of mods. Marking it consumed, as
        // macOS does for Option, would not work: the legacy encoding gives
        // `ctrlSeq` the full mods and modifyOtherKeys 2 encodes
        // `event.mods`, so German AltGr+Q ('@') would still be sent as NUL
        // or CSI 27;7;64~. GTK reaches the same mods because XKB reports
        // AltGr as a level shift, which `translateMods` does not map.
        if (alt_gr) {
            result.mods.ctrl = false;
            result.mods.alt = false;
        }

        // Win32 has no consumed-modifiers report. Shift is the only one that
        // can be inferred: it was consumed if it changed the character. The
        // comparison is with the rest of the state kept: with Caps Lock on,
        // Shift+A gives "a", the same as with no modifiers at all, but
        // Shift still changed it from "A".
        if (result.mods.shift and text.len > 0) {
            var buf: [4]u8 = undefined;
            const n = if (shiftless != 0)
                std.unicode.utf8Encode(shiftless, &buf) catch 0
            else
                0;
            result.consumed.shift = !std.mem.eql(u8, buf[0..n], text.utf8());
        }

        return result;
    }

    /// Whether a keystroke read with `mods` that produced `text` is AltGr.
    ///
    /// Windows reports AltGr as LCtrl+RAlt, and a Ctrl+Alt chord that
    /// produces a character is AltGr by definition on Windows (it is the
    /// documented substitute on keyboards without the key). Only characters
    /// that came through WM_CHAR count: Alt without Ctrl produces
    /// WM_SYSCHAR, and Alt+letter must keep its Alt so the encoder prefixes
    /// ESC.
    fn isAltGr(mods: input.Mods, text: *const Text) bool {
        return text.from_char and mods.ctrl and mods.alt and text.len > 0;
    }

    /// Whether a key event is AltGr's, recording the verdict in `held`
    /// under the key's `Ime.scanSlot`. A release produces no text to judge,
    /// so it takes the verdict of the key's press: Ctrl+Alt is still down,
    /// and reported on the release alone it would pair a plain '@' with the
    /// release of Ctrl+Alt+Q.
    fn altGrKey(
        held: *std.StaticBitSet(512),
        slot: usize,
        action: input.Action,
        mods: input.Mods,
        text: *const Text,
    ) bool {
        const alt_gr = switch (action) {
            .press, .repeat => isAltGr(mods, text),
            .release => held.isSet(slot),
        };
        held.setValue(slot, action != .release and alt_gr);
        return alt_gr;
    }

    /// The Shift keys the core was sent a press for and no release since.
    /// See `keyEvent`, which owes the core the release Windows drops.
    const ShiftKeys = struct {
        left: bool = false,
        right: bool = false,

        /// Record that the core was sent `action` for `key`.
        fn sent(self: *ShiftKeys, key: input.Key, action: input.Action) void {
            const down = action != .release;
            switch (key) {
                .shift_left => self.left = down,
                .shift_right => self.right = down,
                else => {},
            }
        }

        /// The Shift key whose release the core is owed, given whether
        /// each one is down as of the message being handled.
        fn owed(self: ShiftKeys, left_down: bool, right_down: bool) ?input.Key {
            if (self.left and !left_down) return .shift_left;
            if (self.right and !right_down) return .shift_right;
            return null;
        }
    };

    /// Set or clear the core's preedit and record its owner, together.
    fn setPreedit(
        self: *Surface,
        core_surface: *CoreSurface,
        text: ?[]const u8,
        owner: Ime.Preedit,
    ) !void {
        std.debug.assert((text == null) == (owner == .none));

        // The core drops the old preedit before anything in it can fail
        // (`Surface.preeditCallback`), so a failure leaves none.
        self.preedit = .none;
        try core_surface.preeditCallback(text);
        self.preedit = owner;
    }

    /// The core, if an IME handler may call into it.
    ///
    /// Stricter than the key path, which only asks for `liveCore`. IME
    /// messages are mostly *sent*, so they also arrive inside a prompt's
    /// message loop with a core frame beneath it: the composition ends
    /// because the prompt took the focus. Key messages are posted to a
    /// window the prompt has disabled, and never get there.
    fn imeCore(self: *Surface) ?*CoreSurface {
        if (!self.app.canReenterCore()) return null;
        return self.liveCore();
    }

    fn imeStart(self: *Surface) void {
        if (comptime std.log.logEnabled(.debug, .win32)) {
            log.debug("ime start lang=0x{x}", .{inputLanguage()});
        }
        self.ime.composing = true;
        self.ime.form = null;

        const core_surface = self.imeCore() orelse return;
        self.flushIme(core_surface);

        // The IME takes the preedit slot from a pending dead key. The
        // system's own dead-key state cannot be reset from here; the next
        // key the IME declines still combines with it.
        if (self.preedit == .dead_key) {
            self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err});
        }

        const himc = win32.ImmGetContext(self.hwnd) orelse return;
        defer _ = win32.ImmReleaseContext(self.hwnd, himc);
        self.imePlace(core_surface, himc);
    }

    fn imeComposition(self: *Surface, lparam: win32.LPARAM) void {
        // Without a core there is no pty to write a result to.
        const core_surface = self.liveCore() orelse return;
        const core_safe = self.app.canReenterCore();
        const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
        // log.debug("ime composition gcs=0x{x} core_safe={}", .{ bits, core_safe });

        // The context's strings are gone once it is released, so it is held
        // for the whole plan. Setting the forms below sends WM_IME_NOTIFY
        // back into the window procedure; nothing here is borrowed then.
        const hwnd = self.hwnd;
        const himc = win32.ImmGetContext(hwnd) orelse return;
        defer _ = win32.ImmReleaseContext(hwnd, himc);
        const alloc = self.app.core_app.alloc;

        // The result is read before the core is entered: it is this
        // message's, whatever the flush below causes the context to report.
        const result: ?[]u8 = if (bits & win32.GCS_RESULTSTR != 0)
            self.imeString(himc, win32.GCS_RESULTSTR)
        else
            null;
        defer if (result) |v| alloc.free(v);

        // Results keep their order: earlier deferred text goes first.
        if (core_safe) self.flushIme(core_surface);

        for (Ime.plan(bits, self.preedit, core_safe).actions()) |action| switch (action) {
            .clear_preedit => self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err}),

            .commit_result => if (result) |v| imeCommit(core_surface, v),

            .defer_result => if (result) |v| self.ime.pending.appendSlice(alloc, v) catch |err|
                log.warn("ime result dropped err={}", .{err}),

            .update_preedit => {
                const text = self.imeString(himc, win32.GCS_COMPSTR);
                defer if (text) |v| alloc.free(v);
                if (text) |v| {
                    self.setPreedit(core_surface, v, .ime) catch |err|
                        log.warn("preedit callback failed err={}", .{err});
                    // Not every input service announces a composition.
                    self.ime.composing = true;
                    self.imePlace(core_surface, himc);
                } else if (self.preedit == .ime) {
                    // Backspaced to nothing. Never the empty string: the
                    // core would keep an empty preedit and hide the cursor.
                    self.setPreedit(core_surface, null, .none) catch |err|
                        log.warn("preedit callback failed err={}", .{err});
                }
            },
        };
    }

    /// WM_IME_ENDCOMPOSITION, or anything else that ends a composition.
    /// The preedit is cleared by `flushIme`, here or as soon as the core
    /// can be entered again.
    fn imeEnd(self: *Surface) void {
        log.debug("ime end", .{});
        self.ime.composing = false;
        self.ime.form = null;
        if (self.imeCore()) |core_surface| self.flushIme(core_surface);
    }

    /// Deliver deferred result text and clear a preedit whose composition
    /// has ended. Requires `imeCore`'s conditions. Called before every
    /// input that reaches the core, so text keeps its order, and from
    /// `syncIme`.
    fn flushIme(self: *Surface, core_surface: *CoreSurface) void {
        if (self.ime.pending.items.len != 0) {
            const alloc = self.app.core_app.alloc;
            if (self.preedit.clearedByCommit()) {
                self.setPreedit(core_surface, null, .none) catch |err|
                    log.warn("preedit callback failed err={}", .{err});
            }
            // Taken out first: the commit can reach a prompt, whose
            // message loop may bring the next result here.
            var pending = self.ime.pending;
            self.ime.pending = .empty;
            defer pending.deinit(alloc);
            imeCommit(core_surface, pending.items);
        }

        if (self.preedit == .ime and !self.ime.composing) {
            self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err});
        }
    }

    /// Send committed text to the core the way the other runtimes do: a
    /// text-only key press with no physical key. `textCallback` is the
    /// paste path and is not for this (it would bracket and confirm).
    fn imeCommit(core_surface: *CoreSurface, utf8: []const u8) void {
        // log.debug("ime commit bytes={d}", .{utf8.len});
        // `.closed` only posted WM_GHOSTTY_DESTROY (Surface.close), so the
        // surface stays valid for the caller.
        _ = core_surface.keyCallback(.{
            .action = .press,
            .key = .unidentified,
            .mods = .{},
            .consumed_mods = .{},
            .composing = false,
            .utf8 = utf8,
        }) catch |err| log.warn("key callback failed err={}", .{err});
    }

    /// One of the input context's strings as UTF-8, or null if it is empty
    /// or cannot be read. The caller frees it.
    fn imeString(self: *Surface, himc: win32.HIMC, index: win32.DWORD) ?[]u8 {
        const alloc = self.app.core_app.alloc;

        // Sizes are in bytes, and the string is not terminated.
        const size = win32.ImmGetCompositionStringW(himc, index, null, 0);
        if (size <= 0 or @rem(size, 2) != 0) return null;
        var stack = std.heap.stackFallback(512, alloc);
        const units_alloc = stack.get();
        const units = units_alloc.alloc(u16, @intCast(@divExact(size, 2))) catch |err| {
            log.warn("ime string dropped err={}", .{err});
            return null;
        };
        defer units_alloc.free(units);

        const got = win32.ImmGetCompositionStringW(himc, index, units.ptr, @intCast(size));
        if (got <= 0) return null;
        const len: usize = @intCast(@divTrunc(@min(got, size), 2));

        const utf8 = utf8FromWide(alloc, units[0..len]) catch |err| {
            log.warn("ime string dropped err={}", .{err});
            return null;
        };
        if (utf8.len == 0) {
            alloc.free(utf8);
            return null;
        }
        return utf8;
    }

    /// Put the IME's candidate window at the cursor cell. `imePoint` takes
    /// the renderer lock, so this needs `imeCore`'s conditions.
    ///
    /// Two forms, as in winit: the candidate form keeps the list off the
    /// preedit, and the composition form is what some IMEs anchor the list
    /// to instead. Which one a given IME honours is not documented.
    fn imePlace(self: *Surface, core_surface: *CoreSurface, himc: win32.HIMC) void {
        if (win32.GetFocus() != self.hwnd) return;

        var client: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &client).toBool()) return;
        const pos = core_surface.imePoint();
        // The scale imePoint divided by, so that this undoes it exactly.
        const scale = (self.getContentScale() catch unreachable).x;
        const form = Ime.formFor(pos, scale, core_surface.size.cell.width, client);
        if (self.ime.form) |last| if (std.meta.eql(last, form)) return;
        self.ime.form = form;
        log.debug("ime place scale={d} pos={d:.1},{d:.1} {d:.1}x{d:.1} rc={d},{d},{d},{d}", .{
            scale,        pos.x,       pos.y,         pos.width,      pos.height,
            form.rc.left, form.rc.top, form.rc.right, form.rc.bottom,
        });

        var candidate: win32.CANDIDATEFORM = .{
            .dwIndex = 0,
            .dwStyle = win32.CFS_EXCLUDE,
            .ptCurrentPos = .{ .x = form.rc.left, .y = form.rc.top },
            .rcArea = form.rc,
        };
        _ = win32.ImmSetCandidateWindow(himc, &candidate);

        var composition: win32.COMPOSITIONFORM = .{
            .dwStyle = win32.CFS_POINT,
            .ptCurrentPos = form.pt,
            .rcArea = std.mem.zeroes(win32.RECT),
        };
        _ = win32.ImmSetCompositionWindow(himc, &composition);
    }

    /// Finish what the IME handlers could not do where they ran. Called
    /// from `App.run`, never inside a core frame or a prompt.
    ///
    /// A composition does not outlive the focus: its preedit would stay
    /// drawn over the cursor of a window the user has left. How it ends
    /// depends on the language (`Ime.focusLossAction`).
    fn syncIme(self: *Surface, core_surface: *CoreSurface) void {
        self.flushIme(core_surface);

        // The fields first: this runs for every surface on every pass of
        // `App.run`, and almost never has anything to do.
        if (self.focused) return;
        if (!self.ime.composing and self.preedit != .ime) return;

        // Another of this thread's windows has the focus. No prompt is
        // open here (`canReenterCore` holds), so it is another surface.
        // Every window of the thread shares the default input context,
        // which is that window's now: ending the composition through it
        // could end one the user is typing there. Only this window's own
        // state is dropped.
        if (win32.GetFocus() != null) {
            self.ime.composing = false;
            self.flushIme(core_surface);
            return;
        }

        if (win32.ImmGetContext(self.hwnd)) |himc| {
            const how = Ime.focusLossAction(inputLanguage());
            log.debug("ime ends with the focus how={d}", .{how});
            // Sends the IME's messages to this window before it returns.
            _ = win32.ImmNotifyIME(himc, win32.NI_COMPOSITIONSTR, how, 0);
            _ = win32.ImmReleaseContext(self.hwnd, himc);
        }

        // No document promises an end message on this path. A completion
        // above may also have closed the surface.
        const core_now = self.liveCore() orelse return;
        self.ime.composing = false;
        self.flushIme(core_now);
    }

    /// A character message with no keydown in this process to attach it to.
    /// Delivered as a text-only key event with no physical key.
    fn strayChar(
        self: *Surface,
        core_surface: *CoreSurface,
        msg: win32.UINT,
        wparam: win32.WPARAM,
    ) void {
        var text: Text = .{};
        text.add(msg, @truncate(wparam));
        text.finish(&self.high_surrogate);
        if (text.len == 0) return;

        // With no key there is no Shift-less character to compare the
        // text with (0), so a held Shift counts as consumed: the text is
        // final, as an IME commit's is.
        const mods = currentMods();
        _ = self.keyText(core_surface, .{
            .action = .press,
            .key = .unidentified,
            .mods = mods,
        }, &text, 0, isAltGr(mods, &text)) catch |err| log.warn("key callback failed err={}", .{err});
    }

    /// Bring the core up to date with what Win32 could not tell it in time,
    /// and report whether a mouse event may reach the core now.
    ///
    /// Owed events are:
    ///   * a release for each held button that is no longer down according
    ///     to the current message (`down`), or whose capture is gone: its
    ///     WM_*BUTTONUP may then go to another window, and if it does come
    ///     here, mouseButton drops it;
    ///   * a WM_MOUSELEAVE that arrived while a prompt was open.
    ///
    /// Capture ends without a button-up when a message box takes it
    /// (WM_CANCELMODE -> DefWindowProcW), for instance the paste
    /// confirmation inside mouseButtonCallback, or when focus moves away
    /// (WM_KILLFOCUS). `down` covers a capture that survives while the
    /// button was released elsewhere. `null` when there is no message to
    /// read it from.
    ///
    /// Nothing reaches the core unless App.canReenterCore: while a prompt is
    /// open, a core frame may be beneath us. Returns false when the caller
    /// must drop its own event for that reason.
    fn syncMouse(self: *Surface, core_surface: *CoreSurface, down: ?Mouse.Button.Set) bool {
        if (!self.app.canReenterCore()) return false;
        const m = &self.mouse;

        // The capture only matters while a button is held, and this runs
        // for every move.
        const sync = m.sync(m.held.count() != 0 and self.hasCapture(), down);
        if (sync.release_capture) _ = win32.ReleaseCapture();

        if (sync.release.count() != 0) {
            // Where the user let go is unknown, and the click must not
            // complete. The core treats a release on another cell than the
            // press as the end of a drag (SelectionGesture.release), so no
            // link opens and the prompt cursor does not move. The release is
            // therefore placed beyond the client corner farthest from the
            // left press, which the core clamps to that corner's cell: a
            // different cell unless the grid is one row or one column.
            // Programs with mouse reporting receive the release at that
            // edge cell.
            const last = m.pos;
            m.pos = releasePoint(core_surface.size.screen, m.left_press_pos);

            // The mods the core already has, so the release is judged like
            // the events before it: a Shift drag in a program with mouse
            // reporting stays a Ghostty selection
            // (`Surface.mouseButtonCallback`).
            const mods = core_surface.mouse.mods;
            var it = sync.release.iterator();
            while (it.next()) |button| {
                _ = core_surface.mouseButtonCallback(.release, button.core(), mods) catch |err|
                    log.warn("mouse button callback failed err={}", .{err});
            }

            // No leave (`Mouse.sync`): the next captured move supplies the
            // real position.
            if (!sync.leave) m.pos = last;
        }

        // Then the leave. If the pointer is in fact over the window, the
        // next WM_MOUSEMOVE re-enters and re-arms tracking.
        if (sync.leave) {
            m.pos = Mouse.outside;
            m.tracking = false;
            core_surface.cursorPosCallback(Mouse.outside, null) catch |err|
                log.warn("cursor pos callback failed err={}", .{err});
        }
        return true;
    }

    /// A wheel message's screen point as a client position, clamped into
    /// the client area, and whether the pointer is over this window's
    /// client area with nothing covering it there. Null only if Win32
    /// cannot say.
    fn wheelPoint(self: *const Surface, lparam: win32.LPARAM) ?struct {
        pos: apprt.CursorPos,
        over: bool,
    } {
        const screen: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
        var pt = screen;
        if (!win32.ScreenToClient(self.hwnd, &pt).toBool()) return null;
        var rect: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &rect).toBool()) return null;
        const in = clampToRect(pt, rect);
        const under = win32.WindowFromPoint(screen);
        return .{
            .pos = .{ .x = @floatFromInt(in.x), .y = @floatFromInt(in.y) },
            .over = in.x == pt.x and in.y == pt.y and under == self.hwnd,
        };
    }

    /// Give the core a real pointer position, unless it already has it.
    ///
    /// Repeats are dropped, as GTK drops sub-pixel moves: Win32 sends
    /// WM_MOUSEMOVE without movement when windows appear, disappear or move,
    /// and every cursorPosCallback shows a mouse hidden while typing
    /// (`Surface.cursorPosCallback`).
    fn movePointer(
        self: *Surface,
        core_surface: *CoreSurface,
        pos: apprt.CursorPos,
        mods: input.Mods,
    ) void {
        const m = &self.mouse;
        // A real position replaces a leave that could not be delivered.
        m.leave_owed = false;
        if (pos.x == m.pos.x and pos.y == m.pos.y) return;
        m.pos = pos;
        core_surface.cursorPosCallback(pos, mods) catch |err|
            log.warn("cursor pos callback failed err={}", .{err});
    }

    /// A client-area button message, after handleMessage has mapped it.
    fn mouseButton(
        self: *Surface,
        core_surface: *CoreSurface,
        button: Mouse.Button,
        state: input.MouseButtonState,
        wparam: win32.WPARAM,
        pos: apprt.CursorPos,
        mods: input.Mods,
    ) void {
        const m = &self.mouse;
        const down = Mouse.Button.downIn(wparam);
        switch (state) {
            .press => {
                // Dropped entirely, capture included, so its release is
                // dropped too (below).
                if (!self.syncMouse(core_surface, down)) return;

                // Capture on the first button, so the release comes here
                // even when it happens outside the window. Without it the
                // core would keep the button pressed and report every later
                // move as a drag.
                if (m.held.count() == 0) _ = win32.SetCapture(self.hwnd);
                m.held.insert(button);
                if (button == .left) m.left_press_pos = pos;
            },
            .release => {
                // The core never saw this press: an activation click eaten
                // by WM_MOUSEACTIVATE, a press dropped above, one from before
                // the core existed, or one whose release syncMouse already
                // sent. A lone release is not harmless: a left one can open
                // a link (`Surface.mouseButtonCallback`).
                if (!m.held.contains(button)) return;
                m.held.remove(button);
                if (m.held.count() == 0) _ = win32.ReleaseCapture();

                if (!self.syncMouse(core_surface, down)) {
                    m.owed.insert(button);
                    return;
                }
            },
        }

        // The core reads the event position back through getCursorPos, so it
        // must be current first. Link hover and the drag state also change
        // only in cursorPosCallback.
        self.movePointer(core_surface, pos, mods);

        // The result (false = "show your context menu" for a right press)
        // has no consumer: there is no menu. With the default
        // right-click-action, a right click therefore only selects the word
        // or link under the pointer (`Surface.mouseButtonCallback`).
        _ = core_surface.mouseButtonCallback(state, button.core(), mods) catch |err|
            log.warn("mouse button callback failed err={}", .{err});

        // `self` and `core_surface` are still valid here. A press can open a
        // paste confirmation (clipboardRequest -> confirm), but a prompt only
        // defers teardown (destroyPosted), and no mouse callback closes the
        // surface. If that prompt took the capture, `held` still names the
        // button and the next syncMouse releases it.

        if (state == .release and m.held.count() == 0) {
            // Released outside the window: arming now posts WM_MOUSELEAVE at
            // once, and its handler reports the leave. Released inside: this
            // is the tracking the drag skipped.
            self.trackLeave();
        }
    }

    /// Arm leave tracking when the pointer comes over the client area, but
    /// not during a drag: the pointer may be outside then, and arming there
    /// posts a WM_MOUSELEAVE at once, on every move. The final release arms
    /// it instead (mouseButton).
    fn armLeave(self: *Surface) void {
        if (self.mouse.tracking or self.mouse.held.count() != 0) return;
        self.trackLeave();
    }

    /// Ask for WM_MOUSELEAVE when the pointer leaves the client area.
    /// One-shot: Win32 cancels tracking when it posts the leave, and posts it
    /// at once if the pointer is not over the window now.
    fn trackLeave(self: *Surface) void {
        var tme: win32.TRACKMOUSEEVENT = .{
            .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
            .dwFlags = win32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        if (!win32.TrackMouseEvent(&tme).toBool()) {
            log.warn("TrackMouseEvent failed err={}", .{std.os.windows.GetLastError()});
        }
        // Set even on failure: retrying on every move cannot help, and a
        // missed leave only leaves hover state stale until the next one.
        self.mouse.tracking = true;
    }

    fn hasCapture(self: *const Surface) bool {
        const capture = win32.GetCapture() orelse return false;
        return capture == self.hwnd;
    }

    /// `.mouse_shape`. Called while the core may hold the renderer mutex
    /// (from `Surface.mouseRefreshLinks`), so this must not call
    /// back into the core or run a message loop, and must not fail: an error
    /// would abort cursorPosCallback. It does neither.
    fn setMouseShape(self: *Surface, shape: terminal.MouseShape) bool {
        const m = &self.mouse;
        // Modifier keys resend the current shape on every key event
        // (`Surface.keyCallback`).
        if (shape == m.shape and m.cursor != null) return true;
        const cursor = win32.LoadCursorW(null, cursorId(shape)) orelse {
            log.warn("LoadCursorW failed shape={}", .{shape});
            return false;
        };
        m.shape = shape;
        m.cursor = cursor;
        self.applyCursor();
        return true;
    }

    /// `.mouse_visibility`. Same constraints as `setMouseShape`.
    fn setMouseVisibility(self: *Surface, value: apprt.action.MouseVisibility) bool {
        const hidden = value == .hidden;
        if (hidden == self.mouse.hidden) return true;
        self.mouse.hidden = hidden;
        self.applyCursor();
        return true;
    }

    /// The pointer this window wants over its client area: none while
    /// hidden, otherwise the current shape.
    fn clientCursor(self: *const Surface) ?win32.HCURSOR {
        return if (self.mouse.hidden) null else self.mouse.cursor;
    }

    /// Apply `clientCursor` now if the pointer is this window's: over its
    /// client area (leave tracking is armed) or captured for its own drag.
    /// WM_SETCURSOR would otherwise apply it only on the next move, and is
    /// not sent at all while the mouse is captured. SetCursor is documented
    /// for exactly these two cases.
    ///
    /// Not during a system size/move or menu loop: that loop holds the
    /// capture on this window and sets its own cursor, which nothing would
    /// restore while captured.
    fn applyCursor(self: *Surface) void {
        if (self.modal_loops != 0) return;
        const own_drag = self.mouse.held.count() != 0 and self.hasCapture();
        if (!self.mouse.tracking and !own_drag) return;
        if (self.mouse.hidden or self.mouse.cursor != null) {
            _ = win32.SetCursor(self.clientCursor());
        }
    }

    /// Modifiers for a mouse message, binding modifiers only.
    ///
    /// Shift and Ctrl come from the message's own MK_ flags, which describe
    /// the state at the time of the event. Alt and the Windows key have no
    /// flag and come from GetKeyState, which only follows key messages this
    /// thread has read: with the keyboard focus elsewhere it can report a
    /// key as still down (an Alt+Tab whose Alt-up went to another window),
    /// so they are left out then.
    ///
    /// binding() because the core compares its stored mods with each event's
    /// (`Surface.modsChanged`): lock and side bits would make every mouse
    /// event a mods change, which redraws every row.
    fn mouseMods(self: *const Surface, wparam: win32.WPARAM) input.Mods {
        var mods: input.Mods = if (self.focused) currentMods().binding() else .{};
        mods.shift = wparam & win32.MK_SHIFT != 0;
        mods.ctrl = wparam & win32.MK_CONTROL != 0;
        return mods;
    }

    /// The text a keystroke produced, collected from WM_(SYS)(DEAD)CHAR.
    const Text = struct {
        /// UTF-16 code units as received. One keystroke yields at most a few
        /// (a surrogate pair, or a layout's ligature); extra units past the
        /// buffer are still removed from the queue, just not kept.
        units: [16]u16 = undefined,
        units_len: usize = 0,

        /// The UTF-8 result, valid after `finish`.
        bytes: [64]u8 = undefined,
        len: usize = 0,

        /// A WM_DEADCHAR / WM_SYSDEADCHAR was seen: this is preedit.
        composing: bool = false,

        /// At least one unit came from WM_CHAR / WM_DEADCHAR (as opposed to
        /// the WM_SYS* variants, which mean Alt without Ctrl).
        from_char: bool = false,

        fn utf8(self: *const Text) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Remove every pending character message for `hwnd` and convert.
        ///
        /// Two separate peeks, never one over 0x0102-0x0107: that range
        /// also contains WM_SYSKEYDOWN (0x0104) and WM_SYSKEYUP (0x0105),
        /// which a single peek would swallow.
        fn collect(self: *Text, hwnd: win32.HWND, carry: *?u16) void {
            const ranges = [_][2]win32.UINT{
                .{ win32.WM_CHAR, win32.WM_DEADCHAR },
                .{ win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR },
            };
            var m: win32.MSG = undefined;
            for (ranges) |r| {
                while (win32.PeekMessageW(&m, hwnd, r[0], r[1], win32.PM_REMOVE).toBool()) {
                    self.add(m.message, @truncate(m.wParam));
                }
            }
            self.finish(carry);
        }

        fn add(self: *Text, msg: win32.UINT, unit: u16) void {
            if (msg == win32.WM_DEADCHAR or msg == win32.WM_SYSDEADCHAR) {
                self.composing = true;
            }
            if (msg == win32.WM_CHAR or msg == win32.WM_DEADCHAR) {
                self.from_char = true;
            }
            if (self.units_len == self.units.len) return;
            self.units[self.units_len] = unit;
            self.units_len += 1;
        }

        /// Decode the units, dropping C0 controls and DEL as GTK does
        /// (the GTK `Surface.keyEvent` IM filter): the encoder derives
        /// Ctrl+letter, Enter, Tab, Backspace and Esc from the physical key
        /// and the unshifted codepoint, and would double them otherwise.
        ///
        /// `carry` holds a surrogate pair split between two texts (see
        /// `Surface.high_surrogate`): a high surrogate the previous text
        /// ended with is decoded ahead of these units, and one these units
        /// end with is left in `carry` for the next text instead. Other
        /// unpaired surrogates are dropped rather than failing the
        /// keystroke; a carried one that no low surrogate follows is too.
        fn finish(self: *Text, carry: *?u16) void {
            var units: [self.units.len + 1]u16 = undefined;
            var end: usize = 0;
            if (carry.*) |unit| {
                units[0] = unit;
                end = 1;
            }
            @memcpy(units[end..][0..self.units_len], self.units[0..self.units_len]);
            end += self.units_len;

            carry.* = null;
            if (end > 0 and std.unicode.utf16IsHighSurrogate(units[end - 1])) {
                end -= 1;
                carry.* = units[end];
            }

            self.len = 0;
            var it = std.unicode.Utf16LeIterator.init(units[0..end]);
            while (true) {
                const cp = it.nextCodepoint() catch continue orelse break;
                if (cp < 0x20 or cp == 0x7F) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                if (self.len + n > self.bytes.len) break;
                @memcpy(self.bytes[self.len..][0..n], buf[0..n]);
                self.len += n;
            }
        }
    };

    fn wndProc(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        // WM_NCCREATE is the first message that carries the CREATESTRUCTW, so
        // it is the earliest point at which the Surface pointer can be
        // attached. Messages that arrive before it (WM_GETMINMAXINFO does)
        // find a zero GWLP_USERDATA and fall through to DefWindowProcW, which
        // is why the null check below is not optional.
        if (msg == win32.WM_NCCREATE) {
            const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (cs.lpCreateParams) |param| {
                const self: *Surface = @ptrCast(@alignCast(param));
                self.hwnd = hwnd;
                _ = win32.SetWindowLongPtrW(
                    hwnd,
                    win32.GWLP_USERDATA,
                    @bitCast(@intFromPtr(self)),
                );
            }

            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        }

        const self: *Surface = ptr: {
            const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
            if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
        };

        return self.handleMessage(hwnd, msg, wparam, lparam);
    }
};

// -------------------------------------------------------------------------
// Win32 helpers
// -------------------------------------------------------------------------

/// A point beyond the client area, past the corner farthest from `press`
/// on each axis. The core clamps it to that corner's cell
/// (the `.grid` arm of `renderer.size.Coordinate.convert`).
fn releasePoint(screen: renderer.ScreenSize, press: apprt.CursorPos) apprt.CursorPos {
    const w: f32 = @floatFromInt(screen.width);
    const h: f32 = @floatFromInt(screen.height);
    return .{
        .x = if (press.x < w / 2) w + 1 else -1,
        .y = if (press.y < h / 2) h + 1 else -1,
    };
}

/// The client-area position in a mouse message's lParam. These are already
/// device pixels, because the process is per-monitor-v2 DPI aware
/// (dist/windows/ghostty.manifest), and that is the unit the core expects
/// (the GTK runtime scales to it).
fn clientPos(lparam: win32.LPARAM) apprt.CursorPos {
    return .{
        .x = @floatFromInt(win32.xLparam(lparam)),
        .y = @floatFromInt(win32.yLparam(lparam)),
    };
}

/// What a WM_SIZE tells the core.
const SizeChange = union(enum) {
    /// Occluded, and not resized. A minimized window reports a 0x0 client
    /// area, and the grid is clamped to at least 1x1
    /// (`renderer.size.GridSize.update`), so passing it on would reflow
    /// every line to one column and back on restore.
    minimized,

    /// Visible, but not resized: a zero dimension can also occur without
    /// minimizing (a window dragged to zero height), and would clamp the
    /// grid the same way.
    empty,

    /// Visible, at this client size in physical pixels (PerMonitorV2).
    resize: apprt.SurfaceSize,

    fn init(wparam: win32.WPARAM, lparam: win32.LPARAM) SizeChange {
        if (wparam == win32.SIZE_MINIMIZED) return .minimized;
        const width = win32.loword(lparam);
        const height = win32.hiword(lparam);
        if (width == 0 or height == 0) return .empty;
        return .{ .resize = .{ .width = width, .height = height } };
    }
};

/// The point of `rect` nearest to `pt`. A RECT excludes its right and bottom
/// edges; an empty one gives its top-left corner.
fn clampToRect(pt: win32.POINT, rect: win32.RECT) win32.POINT {
    return .{
        .x = @max(rect.left, @min(pt.x, rect.right - 1)),
        .y = @max(rect.top, @min(pt.y, rect.bottom - 1)),
    };
}

/// SPI_GETWHEELSCROLLLINES or SPI_GETWHEELSCROLLCHARS, read for every wheel
/// message so a change in Settings applies at once without tracking
/// WM_SETTINGCHANGE. Windows' default if the call fails.
fn wheelSetting(action: win32.UINT) u32 {
    var value: win32.UINT = Surface.Mouse.Notches.per_tick;
    if (!win32.SystemParametersInfoW(action, 0, &value, 0).toBool()) {
        log.warn("SystemParametersInfoW failed action=0x{x} err={}", .{
            action,
            std.os.windows.GetLastError(),
        });
        return Surface.Mouse.Notches.per_tick;
    }
    return value;
}

/// The stock cursor for a W3C cursor shape. Win32 has no cell,
/// vertical-text, alias, copy, grab, zoom or context-menu cursor; those use
/// the nearest stock cursor or the arrow. An exhaustive switch, so a new
/// shape does not compile until it is mapped.
fn cursorId(shape: terminal.MouseShape) win32.ResourceW {
    return switch (shape) {
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => win32.IDC_ARROW,
        .text, .vertical_text => win32.IDC_IBEAM,
        .pointer, .grab, .grabbing => win32.IDC_HAND,
        .help => win32.IDC_HELP,
        .progress => win32.IDC_APPSTARTING,
        .wait => win32.IDC_WAIT,
        .crosshair, .cell => win32.IDC_CROSS,
        .move, .all_scroll => win32.IDC_SIZEALL,
        .no_drop, .not_allowed => win32.IDC_NO,
        .col_resize, .ew_resize, .e_resize, .w_resize => win32.IDC_SIZEWE,
        .row_resize, .ns_resize, .n_resize, .s_resize => win32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => win32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => win32.IDC_SIZENWSE,
    };
}

/// The modifier state for the key message being handled.
///
/// GetKeyState, not GetAsyncKeyState: it reports the state as of the message
/// being processed, which is what a queued keystroke must be judged by. The
/// high bit is "down", the low bit is the toggle state for the lock keys.
fn currentMods() input.Mods {
    const down = struct {
        fn f(vk: c_int) bool {
            return win32.GetKeyState(vk) < 0;
        }
    }.f;
    const toggled = struct {
        fn f(vk: c_int) bool {
            return win32.GetKeyState(vk) & 1 != 0;
        }
    }.f;

    const lshift = down(win32.VK_LSHIFT);
    const rshift = down(win32.VK_RSHIFT);
    const lctrl = down(win32.VK_LCONTROL);
    const rctrl = down(win32.VK_RCONTROL);
    const lalt = down(win32.VK_LMENU);
    const ralt = down(win32.VK_RMENU);
    const lwin = down(win32.VK_LWIN);
    const rwin = down(win32.VK_RWIN);

    // `sides` only means something for a modifier that is down
    // (`input.Mods.sides`). With both keys of a pair down, left is
    // reported.
    return .{
        .shift = lshift or rshift,
        .ctrl = lctrl or rctrl,
        .alt = lalt or ralt,
        .super = lwin or rwin,
        .caps_lock = toggled(win32.VK_CAPITAL),
        .num_lock = toggled(win32.VK_NUMLOCK),
        .sides = .{
            .shift = if (rshift and !lshift) .right else .left,
            .ctrl = if (rctrl and !lctrl) .right else .left,
            .alt = if (ralt and !lalt) .right else .left,
            .super = if (rwin and !lwin) .right else .left,
        },
    };
}

/// True for the Left Ctrl message Windows synthesizes in front of AltGr.
///
/// On layouts with AltGr, pressing (or releasing) it sends a Left Ctrl
/// down (up) immediately followed by the Right Alt down (up), both stamped
/// with the same message time. Reported as-is, the core would see a real
/// Left Ctrl press and release, which the kitty keyboard protocol's
/// report-all-keys mode forwards to the application. The test is GLFW's
/// (win32_window.c, WM_KEYDOWN handling): a non-extended VK_CONTROL whose
/// next key message is an extended VK_MENU with the same time. Only a peek,
/// so the Right Alt is still delivered normally.
///
/// Two details matter, both measured on Windows 11 with SendInput pairs
/// carrying explicit timestamps:
///
///   * The time is read before peeking. A PM_NOREMOVE peek sets
///     GetMessageTime to the peeked message's time, so reading it afterwards
///     compares that time with itself, and a real Left Ctrl release with a
///     Right Alt queued behind it was taken for AltGr in every trial.
///   * The peek is limited to the key messages. An unfiltered peek returns
///     posted messages before input, so a message posted in the meantime
///     (here, a WM_GHOSTTY_WAKEUP from the render or IO thread) hid the
///     Right Alt in every trial. PM_QS_INPUT is no substitute: it found no
///     input in half of the handler calls although the Right Alt was still
///     queued. Posted character messages are inside the range, but none can
///     be pending here: posted messages are retrieved before input, and
///     TranslateMessage posts nothing for Ctrl.
///
/// A PM_NOREMOVE peek leaves GetKeyState unchanged, so the currentMods call
/// that follows still sees the state as of this message.
fn isAltGrFakeCtrl(wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    if (wparam != win32.VK_CONTROL) return false;
    const l: usize = @bitCast(lparam);
    // lParam bit 24: extended key, i.e. Right Ctrl, which is always real.
    if ((l >> 24) & 1 != 0) return false;

    // GetMessageTime is the time of the message being handled; MSG.time is
    // the same clock (a DWORD of the LONG value).
    const time: win32.DWORD = @bitCast(win32.GetMessageTime());

    var next: win32.MSG = undefined;
    if (!win32.PeekMessageW(
        &next,
        null,
        win32.WM_KEYFIRST,
        win32.WM_KEYLAST,
        win32.PM_NOREMOVE,
    ).toBool()) return false;
    return isAltGrRightAlt(&next, time);
}

/// Whether `next`, the key message queued behind a Left Ctrl message read
/// at `time`, is the Right Alt half of an AltGr press or release.
fn isAltGrRightAlt(next: *const win32.MSG, time: win32.DWORD) bool {
    switch (next.message) {
        win32.WM_KEYDOWN,
        win32.WM_SYSKEYDOWN,
        win32.WM_KEYUP,
        win32.WM_SYSKEYUP,
        => {},
        else => return false,
    }
    const nl: usize = @bitCast(next.lParam);
    return next.wParam == win32.VK_MENU and
        (nl >> 24) & 1 != 0 and
        next.time == time;
}

/// The core's action for a WM_(SYS)KEYDOWN or WM_(SYS)KEYUP.
fn keyAction(msg: win32.UINT, lparam: win32.LPARAM) input.Action {
    if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP) return .release;

    // lParam bit 30: the key was already down, i.e. autorepeat.
    const l: usize = @bitCast(lparam);
    return if ((l >> 30) & 1 != 0) .repeat else .press;
}

/// The key's scan code in the form of the Windows column of
/// src/input/keycodes.zig: the 8-bit code from lParam bits 16-23, with 0xE0
/// in the high byte when lParam bit 24 (extended key) is set. Keys injected
/// without a scan code (lParam 0, e.g. some SendInput callers) fall back to
/// the layout's mapping of the virtual key.
fn scanCode(vk: win32.UINT, lparam: win32.LPARAM) u32 {
    const sc = lparamScanCode(lparam) orelse
        win32.MapVirtualKeyW(vk, win32.MAPVK_VK_TO_VSC_EX);

    // Three keys arrive with a scan code that is not their own, and that
    // keycodes.zig does not list. The corrections are GLFW's
    // (win32_window.c, WM_KEYDOWN handling).
    return switch (sc) {
        // Alt+PrintScreen reports SysRq.
        0x0054 => 0xE037,
        // Ctrl+Pause reports Break.
        0xE046 => 0x0045,
        // CJK IMEs set the extended bit on Right Shift.
        0xE036 => 0x0036,
        else => sc,
    };
}

/// The scan code `lparam` carries, as `scanCode` describes, or null if it
/// carries none.
fn lparamScanCode(lparam: win32.LPARAM) ?u32 {
    const l: usize = @bitCast(lparam);
    var sc: u32 = @intCast((l >> 16) & 0xFF);
    if (sc == 0) return null;
    if ((l >> 24) & 1 != 0) sc |= 0xE000;
    return sc;
}

/// The physical key for a `scanCode` result.
fn keyFromScan(scan: u32) input.Key {
    for (input.keycodes.entries) |entry| {
        if (entry.native == scan) return entry.key;
    }
    return .unidentified;
}

/// The keypad key for `key`, the `keyFromScan` result of a message for
/// virtual key `vk`.
///
/// The keypad's digit and decimal keys keep their scan codes whatever the
/// NumLock state, so `keyFromScan` reports them as digits. With NumLock
/// off, or with Shift held while it is on, Windows sends the navigation
/// virtual key (VK_END, VK_UP, VK_CLEAR and so on) in place of VK_NUMPAD0
/// to VK_NUMPAD9 or VK_DECIMAL. The core then expects the navigation key,
/// which the encoder sends as a cursor or editing key (`pcStyleFunctionKey`
/// in input/key_encode.zig), as GTK reports it from KP_End and the other
/// keypad keysyms.
fn numpadKey(key: input.Key, vk: win32.UINT) input.Key {
    if (vk >= win32.VK_NUMPAD0 and vk <= win32.VK_NUMPAD9) return key;
    if (vk == win32.VK_DECIMAL) return key;
    return switch (key) {
        .numpad_0 => .numpad_insert,
        .numpad_1 => .numpad_end,
        .numpad_2 => .numpad_down,
        .numpad_3 => .numpad_page_down,
        .numpad_4 => .numpad_left,
        .numpad_5 => .numpad_begin,
        .numpad_6 => .numpad_right,
        .numpad_7 => .numpad_home,
        .numpad_8 => .numpad_up,
        .numpad_9 => .numpad_page_up,
        .numpad_decimal => .numpad_delete,
        else => key,
    };
}

/// Whether a key message of virtual key `vk` is Alt+Space, which opens the
/// window menu if no binding claims it. Presses and repeats only: a release
/// follows what happened to its press, through `swallow_up`, so that the
/// core never sees a release without the press or a press without the
/// release.
fn isWindowMenuKey(action: input.Action, vk: win32.UINT, mods: input.Mods) bool {
    if (vk != win32.VK_SPACE) return false;
    return switch (action) {
        .press, .repeat => mods.binding().equal(.{ .alt = true }),
        .release => false,
    };
}

/// Whether a key-down of virtual key `vk` is a digit of Alt+numpad entry:
/// with Alt held alone, the keypad's digit keys type a decimal character
/// code, and TranslateMessage posts the character as WM_CHAR when Alt is
/// released. The digits produce no character of their own.
///
/// A repeat follows its press rather than the modifiers, so that the core
/// sees every key it is told about from press to release: it is a digit of
/// the entry when the press was withheld (`withheld`, from `swallow_up`),
/// even if Alt has since been released, and it is not when the press
/// reached the core before Alt went down.
///
/// Only VK_NUMPAD0 to VK_NUMPAD9 match, so NumLock must be on. With NumLock
/// off the same keys arrive as VK_INSERT, VK_END and the other navigation
/// keys (`numpadKey`), which stay Alt-modified navigation keys for the core.
/// AltGr is Ctrl+Alt and does not start an entry.
fn isAltNumpad(
    action: input.Action,
    vk: win32.UINT,
    mods: input.Mods,
    withheld: bool,
) bool {
    if (vk < win32.VK_NUMPAD0 or vk > win32.VK_NUMPAD9) return false;
    return switch (action) {
        .press => mods.binding().equal(.{ .alt = true }),
        .repeat => withheld,
        .release => false,
    };
}

/// The character the key produces with no modifiers in the current layout,
/// or 0. Used by the encoder for Ctrl/Alt sequences and by bindings.
fn unshiftedCodepoint(vk: win32.UINT, scan: u32) u21 {
    return layoutCodepoint(vk, scan, &std.mem.zeroes([256]win32.BYTE));
}

/// The character the key produces in the current layout with `state`
/// (GetKeyboardState) but Shift released, or 0. Unlike unshiftedCodepoint,
/// Caps Lock and AltGr stay applied, so keyMods can tell what Shift itself
/// changed.
fn shiftlessCodepoint(vk: win32.UINT, scan: u32, state: *const [256]win32.BYTE) u21 {
    var shiftless = state.*;
    for ([_]c_int{ win32.VK_SHIFT, win32.VK_LSHIFT, win32.VK_RSHIFT }) |shift| {
        shiftless[@intCast(shift)] = 0;
    }
    return layoutCodepoint(vk, scan, &shiftless);
}

/// The character the key produces with `state` in the current layout, or 0.
///
/// TOUNICODE_NO_STATE_CHANGE keeps this query from consuming a pending dead
/// key; on Windows before 10 1607, which ignores the flag, a dead key
/// followed by another key can lose its accent.
fn layoutCodepoint(vk: win32.UINT, scan: u32, state: *const [256]win32.BYTE) u21 {
    var buf: [4]win32.WCHAR = undefined;
    const n = win32.ToUnicodeEx(
        vk,
        // Only the low byte. ToUnicodeEx reads bit 15 of the scan code as
        // "key is up", and the 0xE0 extended prefix sets exactly that bit.
        scan & 0xFF,
        state,
        &buf,
        buf.len,
        win32.TOUNICODE_NO_STATE_CHANGE,
        win32.GetKeyboardLayout(0),
    );
    // Negative: a dead key, whose spacing form is in buf[0]. Zero: nothing.
    if (n == 0) return 0;
    const unit = buf[0];
    if (std.unicode.utf16IsHighSurrogate(unit) or std.unicode.utf16IsLowSurrogate(unit)) {
        return 0;
    }
    return unit;
}

fn registerClasses(hinstance: win32.HINSTANCE) !void {
    const arrow = win32.LoadCursorW(null, win32.IDC_ARROW);

    const surface_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = &Surface.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = arrow,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(surface_class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&surface_class) == 0) {
        log.err("failed to register the surface window class", .{});
        return App.Error.Win32ClassRegistrationFailed;
    }
    errdefer _ = win32.UnregisterClassW(L(surface_class_name), hinstance);

    const app_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &App.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(app_class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&app_class) == 0) {
        log.err("failed to register the app window class", .{});
        return App.Error.Win32ClassRegistrationFailed;
    }
}

fn unregisterClasses(hinstance: win32.HINSTANCE) void {
    _ = win32.UnregisterClassW(L(app_class_name), hinstance);
    _ = win32.UnregisterClassW(L(surface_class_name), hinstance);
}

/// Read CF_UNICODETEXT as UTF-8. Returns null when the clipboard holds no
/// text. The caller owns the result.
fn readClipboardText(alloc: Allocator, hwnd: win32.HWND) !?[]u8 {
    if (!win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT).toBool()) return null;

    // OpenClipboard takes a process-wide lock; the defer guarantees no path
    // out of this function leaves it held.
    if (!win32.OpenClipboard(hwnd).toBool()) {
        log.warn("failed to open the clipboard for reading", .{});
        return null;
    }
    defer _ = win32.CloseClipboard();

    // The handle belongs to the clipboard, not to us: it must not be freed,
    // and it is only valid until CloseClipboard.
    const mem = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;
    const raw = win32.GlobalLock(mem) orelse return null;
    defer _ = win32.GlobalUnlock(mem);

    // Another process wrote this block, so only its size bounds it.
    const units: [*]const u16 = @ptrCast(@alignCast(raw));
    return try utf8FromClipboard(alloc, units[0 .. win32.GlobalSize(mem) / @sizeOf(u16)]);
}

/// Replace the clipboard's contents with `text` as CF_UNICODETEXT.
///
/// Bytes that are not valid UTF-8 become U+FFFD rather than failing the
/// write: an OSC 52 payload is whatever the program sent, and macOS stores it
/// as given.
fn writeClipboardText(hwnd: win32.HWND, text: []const u8) App.Error!void {
    const len = std.math.cast(c_int, text.len) orelse {
        log.warn("clipboard text too long len={d}", .{text.len});
        return App.Error.Win32CallFailed;
    };

    // Without MB_ERR_INVALID_CHARS, MultiByteToWideChar replaces invalid
    // sequences with U+FFFD. std has no lossy UTF-8 to UTF-16 conversion.
    // A zero length is an error to MultiByteToWideChar, hence the guard.
    const units: usize = if (len == 0) 0 else units: {
        const n = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, null, 0);
        if (n == 0) {
            log.warn("MultiByteToWideChar failed err={}", .{std.os.windows.GetLastError()});
            return App.Error.Win32CallFailed;
        }
        break :units @intCast(n);
    };

    // The buffer is built before the clipboard is opened, so the only failure
    // after EmptyClipboard is SetClipboardData itself, and the process-wide
    // clipboard lock is held for as short a time as possible.
    const bytes = (units + 1) * @sizeOf(u16);
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse {
        log.warn("GlobalAlloc failed bytes={d} err={}", .{ bytes, std.os.windows.GetLastError() });
        return App.Error.Win32CallFailed;
    };
    // SetClipboardData takes ownership on success; freeing it after that
    // would be a double free the moment anything pastes.
    errdefer _ = win32.GlobalFree(mem);

    {
        const raw = win32.GlobalLock(mem) orelse {
            log.warn("GlobalLock failed err={}", .{std.os.windows.GetLastError()});
            return App.Error.Win32CallFailed;
        };
        defer _ = win32.GlobalUnlock(mem);

        const dst: [*]u16 = @ptrCast(@alignCast(raw));
        if (units > 0) {
            // The same input as the measuring call, so the same count.
            const n = win32.MultiByteToWideChar(
                win32.CP_UTF8,
                0,
                text.ptr,
                len,
                dst,
                @intCast(units),
            );
            std.debug.assert(n == units);
        }
        dst[units] = 0;
    }

    if (!win32.OpenClipboard(hwnd).toBool()) {
        log.warn("OpenClipboard failed err={}", .{std.os.windows.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    defer _ = win32.CloseClipboard();

    if (!win32.EmptyClipboard().toBool()) {
        log.warn("EmptyClipboard failed err={}", .{std.os.windows.GetLastError()});
        return App.Error.Win32CallFailed;
    }

    if (win32.SetClipboardData(win32.CF_UNICODETEXT, mem) == null) {
        log.warn("SetClipboardData failed err={}", .{std.os.windows.GetLastError()});
        return App.Error.Win32CallFailed;
    }
}

/// UTF-8 for a CF_UNICODETEXT block. The text ends at the first NUL, or at
/// the end of the block: Windows does not enforce the terminator, so an
/// owner that leaves it out must not make us read past the block. The text
/// is WTF-16, so an unpaired surrogate becomes U+FFFD, as
/// WideCharToMultiByte does, instead of failing the whole paste.
fn utf8FromClipboard(alloc: Allocator, block: []const u16) Allocator.Error![]u8 {
    return try utf8FromWide(alloc, block[0 .. std.mem.indexOfScalar(u16, block, 0) orelse block.len]);
}

/// UTF-8 for text from Windows, which is WTF-16: an unpaired surrogate
/// becomes U+FFFD, as WideCharToMultiByte does, instead of failing. The
/// caller frees the result.
fn utf8FromWide(alloc: Allocator, units: []const u16) Allocator.Error![]u8 {
    const buf = try std.unicode.wtf16LeToWtf8Alloc(alloc, units);
    // In place: a surrogate's WTF-8 and U+FFFD are both three bytes, and
    // wtf16LeToWtf8 never produces invalid WTF-8.
    std.unicode.wtf8ToUtf8Lossy(buf, buf) catch unreachable;
    return buf;
}

/// NUL-terminated UTF-16 for `text`: each invalid UTF-8 sequence becomes
/// U+FFFD instead of failing, as in writeClipboardText. The caller frees
/// the result.
fn wideFromUtf8(alloc: Allocator, text: []const u8) (Allocator.Error || App.Error)![:0]u16 {
    // A zero length is an error to MultiByteToWideChar.
    if (text.len == 0) return try alloc.allocSentinel(u16, 0, 0);
    const len = std.math.cast(c_int, text.len) orelse {
        log.warn("text too long to convert len={d}", .{text.len});
        return App.Error.Win32CallFailed;
    };

    // Without MB_ERR_INVALID_CHARS, MultiByteToWideChar replaces invalid
    // sequences with U+FFFD. std has no lossy UTF-8 to UTF-16 conversion.
    const n = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, null, 0);
    if (n == 0) {
        log.warn("MultiByteToWideChar failed err={}", .{std.os.windows.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    const wide = try alloc.allocSentinel(u16, @intCast(n), 0);
    // The same input as the measuring call, so the same count.
    const written = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, wide.ptr, n);
    std.debug.assert(written == n);
    return wide;
}

/// The text of the prompt for a clipboard read the core would not complete
/// unasked. A paste puts the text into the terminal; a read hands the
/// clipboard to whatever program is running, which can send it anywhere.
/// The two must not share wording, or the user approves the second believing
/// it is the first. The GTK and macOS confirmation dialogs word them apart
/// too.
fn clipboardReadPrompt(state: apprt.ClipboardRequestType) win32.LPCWSTR {
    return switch (state) {
        .paste => L("Pasting this text could be unsafe. Paste anyway?"),
        .osc_52_read, .kitty_read => L("An application wants to read the clipboard. Allow it?"),

        // Writes go to setClipboard and lists never need consent.
        .osc_52_write, .kitty_write, .list => unreachable,
    };
}

/// The button of a `confirm` prompt that Enter and Space press.
///
/// Prompts that grant access default to Cancel, as GTK's clipboard
/// confirmation dialog does (`default-response: "cancel"`): a program can
/// raise one at any moment, so a key the user was already typing must not
/// answer it.
const ConfirmDefault = enum {
    ok,
    cancel,

    fn style(self: ConfirmDefault) win32.UINT {
        // MB_OKCANCEL places OK first and Cancel second.
        return switch (self) {
            .ok => win32.MB_DEFBUTTON1,
            .cancel => win32.MB_DEFBUTTON2,
        };
    }
};

/// A modal yes/no prompt. This is the only confirmation UI this runtime has.
///
/// MessageBoxW runs a nested message loop. `prompt_depth` tells every
/// handler dispatched inside it that a core frame is probably beneath: no
/// ticks and no surface teardown until it returns (`App.canReenterCore`).
/// Output from every surface pauses while a prompt is open.
fn confirm(
    app: *App,
    hwnd: ?win32.HWND,
    text: win32.LPCWSTR,
    default: ConfirmDefault,
) bool {
    app.prompt_depth += 1;
    defer app.prompt_depth -= 1;
    return win32.MessageBoxW(
        hwnd,
        text,
        L("Ghostty"),
        win32.MB_OKCANCEL | win32.MB_ICONWARNING | default.style(),
    ) == win32.IDOK;
}

/// The LANGID of this thread's input language, or 0.
fn inputLanguage() u16 {
    const hkl = win32.GetKeyboardLayout(0) orelse return 0;
    return @truncate(@intFromPtr(hkl));
}

/// The OK-only form of `confirm`, with the same nesting rules.
fn notice(app: *App, hwnd: win32.HWND, text: win32.LPCWSTR) void {
    app.prompt_depth += 1;
    defer app.prompt_depth -= 1;
    _ = win32.MessageBoxW(hwnd, text, L("Ghostty"), win32.MB_OK | win32.MB_ICONWARNING);
}

/// A failure that ends the process before any window exists. The
/// executable runs in the Windows subsystem, where stderr reaches nobody
/// when it was launched from Explorer or the Start menu, so the error is
/// shown in a message box as well. Nothing is beneath it yet, so the
/// nesting rules of `notice` do not apply.
fn fatalNotice(err: anyerror) void {
    const what: []const u8 = switch (err) {
        error.D3D11DeviceFailed => "Direct3D 11 feature level 11_0 is not available, not even through WARP",
        error.D3D11SwapChainFailed => "Direct3D 11 could not create a swap chain for the window",
        error.D3DCompilerMissing => "d3dcompiler_47.dll could not be loaded",
        else => @errorName(err),
    };
    var buf: [192]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "Ghostty could not create its window: {s}.",
        .{what},
    ) catch "Ghostty could not create its window.";
    // On the stack, so that OutOfMemory can still be reported. `text` is
    // valid UTF-8 no longer than `buf`, so its UTF-16 fits and cannot fail.
    var wide: [buf.len + 1]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text) catch unreachable;
    wide[n] = 0;
    _ = win32.MessageBoxW(null, wide[0..n :0], L("Ghostty"), win32.MB_OK | win32.MB_ICONERROR);
}

/// Opens `wide` with the shell, then frees it. COM is initialized for the
/// thread first, as ShellExecuteW documents: a shell extension it delegates
/// to may need a single-threaded apartment.
fn openUrlThread(alloc: Allocator, wide: [:0]u16) void {
    defer alloc.free(wide);
    const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) win32.CoUninitialize();
    const rc = win32.ShellExecuteW(null, L("open"), wide.ptr, null, null, win32.SW_SHOWNORMAL);
    if (rc <= 32) log.warn("ShellExecuteW failed code={}", .{rc});
}

/// Whether an OSC 8 target may be opened: an http or https link with a
/// host, or a mailto link with an address, containing nothing that could
/// display differently from what the handler receives. This is the allow
/// branch of the macOS policy (macos/Sources/Helpers/UntrustedURL.swift);
/// what that policy confirms or inspects (`file:`, custom schemes) is
/// refused here outright.
fn osc8Allowed(url: []const u8) bool {
    // Control, bidirectional and zero-width code points can hide part of
    // the target or add a display line; invalid UTF-8 cannot be shown.
    var it = (std.unicode.Utf8View.init(url) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        const unsafe = switch (cp) {
            0x00...0x1F, 0x7F...0x9F => true, // C0 and C1 controls
            0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069 => true, // bidi, zero width
            0x2028, 0x2029, 0x2060, 0xFEFF => true, // line separators, word joiner, BOM
            else => false,
        };
        if (unsafe) return false;
    }

    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..colon];
    const rest = url[colon + 1 ..];

    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        // "https:relative" has a scheme but no authority, and consumers
        // resolve it against different bases.
        if (!std.mem.startsWith(u8, rest, "//")) return false;
        const authority = rest[2 .. 2 + (std.mem.indexOfAny(u8, rest[2..], "/?#") orelse rest.len - 2)];
        // The host follows the user info and precedes the port.
        const after_user = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
        const host = if (std.mem.indexOfScalar(u8, after_user, ':')) |i| after_user[0..i] else after_user;
        return host.len != 0;
    }

    if (std.ascii.eqlIgnoreCase(scheme, "mailto")) {
        // The address is the path; a bare "mailto:" opens an empty message.
        return (std.mem.indexOfScalar(u8, rest, '?') orelse rest.len) != 0;
    }

    return false;
}

comptime {
    // Zig only analyzes function bodies it reaches. A Windows exe reaches
    // the contract through CoreSurface, but only for the methods and action
    // keys the core actually calls in that configuration; these references
    // keep the whole contract type-checked (and every performAction key
    // instantiated) whenever this file is the selected runtime, so it cannot
    // rot silently against core changes.
    //
    // Guarded on this file being the selected runtime, not merely on the
    // target. src/apprt.zig imports it unconditionally on every platform,
    // and a Windows library build resolves it as soon as anything names
    // `apprt.windows`, while that build's surfaces are
    // `apprt.embedded.Surface`, which this contract does not describe.
    if (apprt.runtime == @This()) {
        _ = &App.performIpc;
        _ = &App.keyboardLayout;
        _ = &App.wakeup;
        _ = &App.startQuitTimer;

        _ = &Surface.core;
        _ = &Surface.rtApp;
        _ = &Surface.close;
        _ = &Surface.getContentScale;
        _ = &Surface.getSize;
        _ = &Surface.getCursorPos;
        _ = &Surface.getTitle;
        _ = &Surface.supportsClipboard;
        _ = &Surface.clipboardRequest;
        _ = &Surface.setClipboard;
        _ = &Surface.defaultTermioEnv;

        // Every button this runtime reports must index the core's
        // click_state (`CoreSurface.Mouse.click_state`, indexed in
        // `Surface.mouseButtonCallback`); input.MouseButton.eleven
        // does not, since the array has `max` (= 11) entries.
        const click_states = @typeInfo(
            @FieldType(@FieldType(CoreSurface, "mouse"), "click_state"),
        ).array.len;
        for (std.enums.values(Surface.Mouse.Button)) |b| {
            if (@intFromEnum(b.core()) >= click_states) {
                @compileError("mouse button " ++ @tagName(b) ++ " is outside the core's click_state");
            }
        }

        // performAction is comptime-dispatched per key, so each of the 69
        // keys is a separate instantiation and a separate chance to be wrong.
        for (@typeInfo(apprt.Action.Key).@"enum".fields) |field| {
            const key = @field(apprt.Action.Key, field.name);
            _ = &struct {
                fn thunk(
                    app: *App,
                    target: apprt.Target,
                    value: apprt.Action.Value(key),
                ) !bool {
                    return app.performAction(target, key, value);
                }
            }.thunk;
        }
    }
}

test "win32: waiting for a thread drains a full mailbox without input" {
    // Only what this tick touches: the mailbox, and the surface list that
    // `.close` is checked against (empty, so every message is a no-op).
    var core_app: CoreApp = undefined;
    core_app.mailbox = .{};
    core_app.surfaces = .empty;

    var app: App = undefined;
    app.core_app = &core_app;
    app.ticking = false;
    app.prompt_depth = 0;

    // Never dereferenced; static so it costs no stack.
    const gone = struct {
        var surface: CoreSurface = undefined;
    };

    // A full mailbox whose wakeups were already consumed by a loop that did
    // not tick, as a prompt's loop does: nothing is left in the queue.
    while (core_app.mailbox.push(
        global.io(),
        .{ .close = &gone.surface },
        .instant,
    ) != 0) {}

    // A producer such as the IO thread's reader, blocked on the full
    // mailbox and posting no wakeup until its push succeeds. A timeout
    // rather than `.forever` makes a wait that never drains fail the test
    // instead of hanging it.
    const Producer = struct {
        fn run(mailbox: *CoreApp.Mailbox.Queue, pushed: *bool) void {
            pushed.* = mailbox.push(
                global.io(),
                .{ .close = &gone.surface },
                .{ .ns = 3 * std.time.ns_per_s },
            ) != 0;
        }
    };
    var pushed = false;
    const thread = try std.Thread.spawn(.{}, Producer.run, .{ &core_app.mailbox, &pushed });
    app.waitForThread(thread.getHandle());
    thread.join();
    try std.testing.expect(pushed);
}

test "win32: mouse lParam coordinates are signed" {
    // (-5, -7) as the system packs it: MAKELPARAM of two shorts.
    const pos = clientPos(@bitCast(@as(usize, 0xFFF9_FFFB)));
    try std.testing.expectEqual(@as(f32, -5), pos.x);
    try std.testing.expectEqual(@as(f32, -7), pos.y);
}

test "win32: wheel deltas add up to whole notches" {
    const thirds = [_]i32{40} ** 9;
    const ones = [_]i32{1} ** 360;
    const cases = [_][]const i32{ &.{ 120, 120, 120 }, &thirds, &.{ 90, 90, 90, 90 }, &ones };
    for (cases) |deltas| {
        for ([_]i32{ 1, -1 }) |sign| {
            var n: Surface.Mouse.Notches = .{};
            var total: i64 = 0;
            for (deltas) |d| total += n.add(sign * d, 3) orelse 0;
            try std.testing.expectEqual(3 * sign, total);
            try std.testing.expectEqual(0, n.rem);
        }
    }

    // A reversal is not absorbed by the other direction's remainder.
    var n: Surface.Mouse.Notches = .{};
    try std.testing.expectEqual(null, n.add(60, 3));
    try std.testing.expectEqual(-1, n.add(-120, 3));
}

test "win32: wheel ticks follow the lines to scroll per notch" {
    const Case = struct { per_notch: u32, ticks: []const ?i64 };
    const cases = [_]Case{
        // A tick is three lines, so these scroll 1, 6 and 10 per notch.
        .{ .per_notch = 1, .ticks = &.{ null, null, 1 } },
        .{ .per_notch = 6, .ticks = &.{ 2, 2 } },
        .{ .per_notch = 10, .ticks = &.{ 3, 3, 4 } },
        // Zero turns the wheel off.
        .{ .per_notch = 0, .ticks = &.{ null, null, null } },
    };
    for (cases) |c| {
        var n: Surface.Mouse.Notches = .{};
        for (c.ticks) |ticks| try std.testing.expectEqual(ticks, n.add(120, c.per_notch));
        try std.testing.expectEqual(0, n.rem);
    }

    // A screen's worth of lines, or any other UINT, does not overflow.
    var n: Surface.Mouse.Notches = .{};
    try std.testing.expectEqual(1_431_655_764, n.add(120, std.math.maxInt(u32) - 1).?);
}

test "win32: wheel points off the client area clamp to its edge" {
    const rect: win32.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const Case = struct { pt: win32.POINT, in: win32.POINT };
    const cases = [_]Case{
        .{ .pt = .{ .x = 10, .y = 20 }, .in = .{ .x = 10, .y = 20 } },
        // The caption and the left border: above and left of the client.
        .{ .pt = .{ .x = 300, .y = -15 }, .in = .{ .x = 300, .y = 0 } },
        .{ .pt = .{ .x = -4, .y = 200 }, .in = .{ .x = 0, .y = 200 } },
        // Right and bottom are outside the RECT.
        .{ .pt = .{ .x = 800, .y = 600 }, .in = .{ .x = 799, .y = 599 } },
        .{ .pt = .{ .x = 5000, .y = -5000 }, .in = .{ .x = 799, .y = 0 } },
    };
    for (cases) |c| try std.testing.expectEqual(c.in, clampToRect(c.pt, rect));

    // A minimized window's empty client area.
    const empty: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    try std.testing.expectEqual(win32.POINT{ .x = 0, .y = 0 }, clampToRect(.{ .x = 9, .y = -9 }, empty));
}

test "win32: mouse message button bits" {
    // Raw wParams as the system packs them, so a wrong MK_ or XBUTTON
    // constant fails here: MK_LBUTTON 0x01, MK_RBUTTON 0x02, MK_SHIFT 0x04,
    // MK_CONTROL 0x08, MK_MBUTTON 0x10, MK_XBUTTON1 0x20, MK_XBUTTON2 0x40.
    const Button = Surface.Mouse.Button;
    try std.testing.expect(Button.downIn(0).eql(.empty));
    try std.testing.expect(Button.downIn(0x0045).eql(.initMany(&.{ .left, .x2 })));
    try std.testing.expect(Button.downIn(0x003A).eql(.initMany(&.{ .right, .middle, .x1 })));

    // GET_XBUTTON_WPARAM: XBUTTON1 is 1 and XBUTTON2 is 2 in the high
    // word; the low word holds the MK_ bits.
    try std.testing.expectEqual(Button.x2, Button.fromMessage(win32.WM_XBUTTONUP, 0x0002_0000).?);
    try std.testing.expectEqual(Button.x1, Button.fromMessage(win32.WM_XBUTTONDOWN, 0x0001_0020).?);
    try std.testing.expectEqual(null, Button.fromMessage(win32.WM_XBUTTONDOWN, 0x0003_0000));
}

test "win32: wheel deltas are the signed high word" {
    // One notch toward the user is -120 (0xFF88), here with MK_CONTROL in
    // the low word.
    try std.testing.expectEqual(-120, win32.wheelDelta(0xFF88_0008));
    try std.testing.expectEqual(120, win32.wheelDelta(0x0078_0000));
}

test "win32: mouse sync owes a release for each button no longer down" {
    const Mouse = Surface.Mouse;
    const Set = Mouse.Button.Set;
    const Case = struct {
        held: Set,
        owed: Set = .empty,
        leave_owed: bool = false,
        captured: bool,
        down: ?Set,
        want: Mouse.Sync,
        held_after: Set,
    };
    const cases = [_]Case{
        // The capture was taken away (a prompt, the focus) with two
        // buttons held: both are released, then the pointer leaves.
        .{
            .held = .initMany(&.{ .left, .right }),
            .captured = false,
            .down = null,
            .want = .{ .release = .initMany(&.{ .left, .right }), .leave = true },
            .held_after = .empty,
        },
        // One of two buttons let go elsewhere: no leave, since the other
        // button is still dragging.
        .{
            .held = .initMany(&.{ .left, .right }),
            .captured = true,
            .down = .initOne(.right),
            .want = .{ .release = .initOne(.left) },
            .held_after = .initOne(.right),
        },
        // The last button let go elsewhere while captured.
        .{
            .held = .initOne(.left),
            .captured = true,
            .down = .empty,
            .want = .{ .release = .initOne(.left), .release_capture = true, .leave = true },
            .held_after = .empty,
        },
        // Captured, and no message to say otherwise: still held.
        .{
            .held = .initOne(.left),
            .captured = true,
            .down = null,
            .want = .{},
            .held_after = .initOne(.left),
        },
        // A button the core never saw pressed is not released.
        .{
            .held = .initOne(.left),
            .captured = true,
            .down = .initMany(&.{ .left, .right }),
            .want = .{},
            .held_after = .initOne(.left),
        },
        // A release and a leave that came while a prompt was open.
        .{
            .held = .empty,
            .owed = .initOne(.middle),
            .captured = false,
            .down = .empty,
            .want = .{ .release = .initOne(.middle), .leave = true },
            .held_after = .empty,
        },
        .{
            .held = .empty,
            .leave_owed = true,
            .captured = false,
            .down = null,
            .want = .{ .leave = true },
            .held_after = .empty,
        },
    };
    for (cases) |c| {
        var m: Mouse = .init();
        m.held = c.held;
        m.owed = c.owed;
        m.leave_owed = c.leave_owed;
        const got = m.sync(c.captured, c.down);
        try std.testing.expect(got.release.eql(c.want.release));
        try std.testing.expectEqual(c.want.release_capture, got.release_capture);
        try std.testing.expectEqual(c.want.leave, got.leave);
        try std.testing.expect(m.held.eql(c.held_after));
        try std.testing.expect(m.owed.eql(.empty));
        try std.testing.expectEqual(c.leave_owed and !got.leave, m.leave_owed);
    }

    // For every held set, every `down` and either capture state: a button
    // ends up still held or released, never both, never lost, and never
    // one that was not held.
    const buttons = comptime std.enums.values(Mouse.Button);
    const all = 1 << buttons.len;
    const setOf = struct {
        fn f(bits: usize) Set {
            var set: Set = .empty;
            for (buttons, 0..) |b, i| {
                if (bits & (@as(usize, 1) << @intCast(i)) != 0) set.insert(b);
            }
            return set;
        }
    }.f;
    for (0..all) |held_bits| {
        // One past the last set stands for no message (`down == null`).
        for (0..all + 1) |down_bits| {
            for ([_]bool{ false, true }) |captured| {
                var m: Mouse = .init();
                m.held = setOf(held_bits);
                const down: ?Set = if (down_bits == all) null else setOf(down_bits);
                const got = m.sync(captured, down);
                try std.testing.expect(got.release.intersectWith(m.held).eql(.empty));
                try std.testing.expect(got.release.unionWith(m.held).eql(setOf(held_bits)));
            }
        }
    }
}

test "win32: an invented release lands on another cell than the press" {
    // An 80x24 grid of 10x20 cells with 2 px of padding, and the leftover
    // pixels at the right and bottom, as without padding balance.
    const size: renderer.Size = .{
        .screen = .{ .width = 805, .height = 489 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{ .top = 2, .bottom = 2, .left = 2, .right = 2 },
    };
    const grid = size.grid();
    try std.testing.expectEqual(80, grid.columns);
    try std.testing.expectEqual(24, grid.rows);

    const cell = struct {
        fn at(pos: apprt.CursorPos, s: renderer.Size) renderer.Coordinate.Grid {
            const surface: renderer.Coordinate = .{ .surface = .{ .x = pos.x, .y = pos.y } };
            return surface.convert(.grid, s).grid;
        }
    }.at;

    var y: u32 = 0;
    while (y < size.screen.height) : (y += 1) {
        var x: u32 = 0;
        while (x < size.screen.width) : (x += 1) {
            const press: apprt.CursorPos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
            const release = releasePoint(size.screen, press);

            // Outside the client area on both axes.
            try std.testing.expect(release.x < 0 or release.x >= 805);
            try std.testing.expect(release.y < 0 or release.y >= 489);

            // A corner cell, in another column and another row than the
            // press: the corner farthest from it.
            const p = cell(press, size);
            const r = cell(release, size);
            try std.testing.expect(r.x == 0 or r.x == grid.columns - 1);
            try std.testing.expect(r.y == 0 or r.y == grid.rows - 1);
            try std.testing.expect(p.x != r.x);
            try std.testing.expect(p.y != r.y);
        }
    }
}

test "win32: a minimized or empty window is not resized" {
    // wParam SIZE_RESTORED 0, SIZE_MINIMIZED 1, SIZE_MAXIMIZED 2; lParam
    // MAKELPARAM(width, height).
    try std.testing.expectEqual(SizeChange.minimized, SizeChange.init(1, 0));
    try std.testing.expectEqual(SizeChange.minimized, SizeChange.init(1, 0x0438_0780));
    try std.testing.expectEqual(SizeChange.empty, SizeChange.init(0, 0x0190_0000));
    try std.testing.expectEqual(SizeChange.empty, SizeChange.init(0, 0x0000_0280));
    try std.testing.expectEqual(
        SizeChange{ .resize = .{ .width = 1920, .height = 1080 } },
        SizeChange.init(2, 0x0438_0780),
    );

    // Unsigned: a client size is never negative, unlike a mouse position.
    try std.testing.expectEqual(
        SizeChange{ .resize = .{ .width = 0x9000, .height = 0x8000 } },
        SizeChange.init(0, 0x8000_9000),
    );
}

test "win32: key messages decode lParam" {
    const testing = std.testing;
    const lp = struct {
        fn of(v: usize) win32.LPARAM {
            return @bitCast(v);
        }
    }.of;

    // Right Arrow is scan 0x4D with the extended bit (24); Numpad 6 is the
    // same scan without it.
    try testing.expectEqual(0xE04D, lparamScanCode(lp(0x014D_0001)).?);
    try testing.expectEqual(.arrow_right, keyFromScan(0xE04D));
    try testing.expectEqual(0x004D, lparamScanCode(lp(0x004D_0001)).?);
    try testing.expectEqual(.numpad_6, keyFromScan(0x004D));
    try testing.expectEqual(.control_right, keyFromScan(lparamScanCode(lp(0x011D_0001)).?));
    try testing.expectEqual(.control_left, keyFromScan(lparamScanCode(lp(0x001D_0001)).?));

    // No scan field, extended or not: the caller asks the layout instead.
    try testing.expectEqual(null, lparamScanCode(lp(0x0000_0001)));
    try testing.expectEqual(null, lparamScanCode(lp(0x0100_0001)));
    try testing.expectEqual(.unidentified, keyFromScan(0));

    // Scan codes that are not the key's own: Alt+PrintScreen (VK_SNAPSHOT)
    // reports SysRq 0x54, Ctrl+Pause (VK_CANCEL) an extended 0x46, and Right
    // Shift (VK_SHIFT) under a CJK IME an extended 0x36. Scroll Lock (0x46)
    // and Right Shift without the extended bit are unchanged.
    try testing.expectEqual(.print_screen, keyFromScan(scanCode(0x2C, lp(0x2054_0001))));
    try testing.expectEqual(.pause, keyFromScan(scanCode(0x03, lp(0x0146_0001))));
    try testing.expectEqual(.shift_right, keyFromScan(scanCode(0x10, lp(0x0136_0001))));
    try testing.expectEqual(.scroll_lock, keyFromScan(scanCode(0x91, lp(0x0046_0001))));
    try testing.expectEqual(.shift_right, keyFromScan(scanCode(0x10, lp(0x0036_0001))));

    // Bit 30 is the previous key state, bit 31 the transition state, which
    // the message already says. Bit 29 is the Alt context of WM_SYS*.
    try testing.expectEqual(.press, keyAction(win32.WM_KEYDOWN, lp(0x001E_0001)));
    try testing.expectEqual(.repeat, keyAction(win32.WM_KEYDOWN, lp(0x401E_0001)));
    try testing.expectEqual(.press, keyAction(win32.WM_SYSKEYDOWN, lp(0x201E_0001)));
    try testing.expectEqual(.repeat, keyAction(win32.WM_SYSKEYDOWN, lp(0x601E_0001)));
    try testing.expectEqual(.release, keyAction(win32.WM_KEYUP, lp(0xC01E_0001)));
    try testing.expectEqual(.release, keyAction(win32.WM_SYSKEYUP, lp(0xE01E_0001)));
}

test "win32: keypad keys follow NumLock" {
    const testing = std.testing;
    const Case = struct { scan: u32, vk: win32.UINT, want: input.Key };
    const cases = [_]Case{
        // NumLock on: the digit's VK.
        .{ .scan = 0x0048, .vk = 0x68, .want = .numpad_8 }, // VK_NUMPAD8
        .{ .scan = 0x0052, .vk = 0x60, .want = .numpad_0 }, // VK_NUMPAD0
        .{ .scan = 0x0053, .vk = 0x6E, .want = .numpad_decimal }, // VK_DECIMAL

        // NumLock off, or Shift with it on: the navigation VK, same scan.
        .{ .scan = 0x0048, .vk = 0x26, .want = .numpad_up }, // VK_UP
        .{ .scan = 0x004F, .vk = 0x23, .want = .numpad_end }, // VK_END
        .{ .scan = 0x004C, .vk = 0x0C, .want = .numpad_begin }, // VK_CLEAR
        .{ .scan = 0x0052, .vk = 0x2D, .want = .numpad_insert }, // VK_INSERT
        .{ .scan = 0x0053, .vk = 0x2E, .want = .numpad_delete }, // VK_DELETE

        // The dedicated arrow and the keypad's other keys stay as they are.
        .{ .scan = 0xE048, .vk = 0x26, .want = .arrow_up }, // VK_UP
        .{ .scan = 0x004E, .vk = 0x6B, .want = .numpad_add }, // VK_ADD
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, numpadKey(keyFromScan(c.scan), c.vk));
    }
}

test "win32: Alt+Space is the window menu on press and repeat" {
    const testing = std.testing;
    const alt: input.Mods = .{ .alt = true };
    const space: win32.UINT = 0x20; // VK_SPACE

    // Either Alt, alone, presses or repeats.
    try testing.expect(isWindowMenuKey(.press, space, alt));
    try testing.expect(isWindowMenuKey(.repeat, space, alt));
    try testing.expect(isWindowMenuKey(.press, space, .{ .alt = true, .sides = .{ .alt = .right } }));
    try testing.expect(isWindowMenuKey(.press, space, .{ .alt = true, .caps_lock = true }));

    // The release follows its press through `swallow_up` instead, so a
    // bound press's release reaches the core.
    try testing.expect(!isWindowMenuKey(.release, space, alt));

    // Not Alt alone (AltGr's Ctrl+Alt among them), or not Space.
    try testing.expect(!isWindowMenuKey(.press, space, .{}));
    try testing.expect(!isWindowMenuKey(.press, space, .{ .alt = true, .ctrl = true }));
    try testing.expect(!isWindowMenuKey(.press, space, .{ .alt = true, .shift = true }));
    try testing.expect(!isWindowMenuKey(.press, 0x0D, alt)); // VK_RETURN
}

test "win32: Alt+numpad digits are text entry" {
    const testing = std.testing;
    const alt: input.Mods = .{ .alt = true };
    const Case = struct {
        action: input.Action = .press,
        vk: win32.UINT,
        mods: input.Mods = alt,
        withheld: bool = false,
        want: bool,
    };
    const cases = [_]Case{
        // The digits with NumLock on, from either Alt.
        .{ .vk = 0x60, .want = true }, // VK_NUMPAD0
        .{ .vk = 0x69, .want = true }, // VK_NUMPAD9
        .{ .vk = 0x60, .mods = .{ .alt = true, .num_lock = true }, .want = true },
        .{ .vk = 0x60, .mods = .{ .alt = true, .sides = .{ .alt = .right } }, .want = true },

        // A repeat follows its press: withheld while the press was, even
        // after Alt is released, and passed on when the press reached the
        // core before Alt went down.
        .{ .vk = 0x61, .action = .repeat, .withheld = true, .want = true },
        .{ .vk = 0x61, .action = .repeat, .mods = .{}, .withheld = true, .want = true },
        .{ .vk = 0x61, .action = .repeat, .want = false },

        // Not an entry: the release, no Alt, AltGr, Alt with another
        // modifier, the keypad with NumLock off, the keypad's other keys,
        // and the main keyboard's digits.
        .{ .vk = 0x60, .action = .release, .withheld = true, .want = false },
        .{ .vk = 0x60, .mods = .{}, .want = false },
        .{ .vk = 0x60, .mods = .{ .alt = true, .ctrl = true }, .want = false },
        .{ .vk = 0x60, .mods = .{ .alt = true, .super = true }, .want = false },
        .{ .vk = 0x2D, .want = false }, // VK_INSERT
        .{ .vk = 0x23, .want = false }, // VK_END
        .{ .vk = 0x6E, .want = false }, // VK_DECIMAL
        .{ .vk = 0x6B, .want = false }, // VK_ADD
        .{ .vk = 0x30, .want = false }, // 0 on the main keyboard
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, isAltNumpad(c.action, c.vk, c.mods, c.withheld));
    }
}

test "win32: key text drops controls and decodes surrogate pairs" {
    const Text = Surface.Text;
    const Case = struct { msg: win32.UINT, units: []const u16, want: []const u8 };
    const cases = [_]Case{
        .{ .msg = win32.WM_CHAR, .units = &.{'a'}, .want = "a" },
        .{ .msg = win32.WM_CHAR, .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}" },
        // Backspace, Enter, Esc, Ctrl+A and Ctrl+Backspace's DEL: the
        // encoder derives these from the key.
        .{ .msg = win32.WM_CHAR, .units = &.{ 0x08, 0x0D, 0x1B, 0x01, 0x7F }, .want = "" },
        // An unpaired surrogate is dropped, not the rest of the keystroke.
        .{ .msg = win32.WM_CHAR, .units = &.{ 0xD800, 'a' }, .want = "a" },
        .{ .msg = win32.WM_CHAR, .units = &.{ 0xDE00, 'a' }, .want = "a" },
        .{ .msg = win32.WM_SYSCHAR, .units = &.{'x'}, .want = "x" },
        .{ .msg = win32.WM_CHAR, .units = &([_]u16{'a'} ** 20), .want = "a" ** 16 },
    };
    for (cases) |c| {
        var text: Text = .{};
        var carry: ?u16 = null;
        for (c.units) |u| text.add(c.msg, u);
        text.finish(&carry);
        try std.testing.expectEqualStrings(c.want, text.utf8());
        try std.testing.expectEqual(null, carry);
    }

    // Dead keys are preedit; only the non-SYS messages mean "not Alt alone".
    const Flags = struct { msg: win32.UINT, composing: bool, from_char: bool };
    const flags = [_]Flags{
        .{ .msg = win32.WM_CHAR, .composing = false, .from_char = true },
        .{ .msg = win32.WM_DEADCHAR, .composing = true, .from_char = true },
        .{ .msg = win32.WM_SYSCHAR, .composing = false, .from_char = false },
        .{ .msg = win32.WM_SYSDEADCHAR, .composing = true, .from_char = false },
    };
    for (flags) |f| {
        var text: Text = .{};
        var carry: ?u16 = null;
        text.add(f.msg, '^');
        text.finish(&carry);
        try std.testing.expectEqualStrings("^", text.utf8());
        try std.testing.expectEqual(f.composing, text.composing);
        try std.testing.expectEqual(f.from_char, text.from_char);
    }
}

test "win32: key text pairs surrogates split between keystrokes" {
    const Text = Surface.Text;
    const t = std.testing;

    // SendInput's U+1F600: one VK_PACKET keystroke per UTF-16 unit, each
    // with its own WM_CHAR. A keystroke with no text in between (a
    // modifier) keeps the high half waiting.
    var carry: ?u16 = null;
    const keystrokes = [_]struct { units: []const u16, want: []const u8, carry: ?u16 }{
        .{ .units = &.{0xD83D}, .want = "", .carry = 0xD83D },
        .{ .units = &.{}, .want = "", .carry = 0xD83D },
        .{ .units = &.{0xDE00}, .want = "\u{1F600}", .carry = null },
        // A high half that no low half follows is dropped, not the text.
        .{ .units = &.{0xD83D}, .want = "", .carry = 0xD83D },
        .{ .units = &.{'a'}, .want = "a", .carry = null },
        // A pair in one keystroke after text that ended with a high half.
        .{ .units = &.{ 'b', 0xD83D }, .want = "b", .carry = 0xD83D },
        .{ .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}", .carry = null },
    };
    for (keystrokes) |k| {
        var text: Text = .{};
        for (k.units) |u| text.add(win32.WM_CHAR, u);
        text.finish(&carry);
        try t.expectEqualStrings(k.want, text.utf8());
        try t.expectEqual(k.carry, carry);
    }
}

test "win32: key modifiers for AltGr and consumed Shift" {
    const Case = struct {
        mods: input.Mods,
        msg: win32.UINT = win32.WM_CHAR,
        units: []const u16,
        shiftless: u21,
        want: input.Mods,
        consumed: input.Mods = .{},
    };
    const cases = [_]Case{
        // German AltGr+Q: '@' arrives as WM_CHAR under LCtrl+RAlt.
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .units = &.{'@'},
            .shiftless = 'q',
            .want = .{},
        },
        // Alt+A keeps its Alt, so the encoder prefixes ESC.
        .{
            .mods = .{ .alt = true },
            .msg = win32.WM_SYSCHAR,
            .units = &.{'a'},
            .shiftless = 'a',
            .want = .{ .alt = true },
        },
        // Text only from WM_SYSCHAR is Alt's, not AltGr's, even with Ctrl
        // down: Ctrl+Alt keeps both.
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .msg = win32.WM_SYSCHAR,
            .units = &.{'a'},
            .shiftless = 'a',
            .want = .{ .ctrl = true, .alt = true },
        },
        // Ctrl+Alt with no text, or only a dropped control character, is
        // a chord, not AltGr.
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .units = &.{},
            .shiftless = 'a',
            .want = .{ .ctrl = true, .alt = true },
        },
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .units = &.{0x01},
            .shiftless = 'a',
            .want = .{ .ctrl = true, .alt = true },
        },
        // Shift that changed the character was consumed; it stays in mods.
        .{
            .mods = .{ .shift = true },
            .units = &.{'A'},
            .shiftless = 'a',
            .want = .{ .shift = true },
            .consumed = .{ .shift = true },
        },
        .{
            .mods = .{ .shift = true },
            .units = &.{'!'},
            .shiftless = '1',
            .want = .{ .shift = true },
            .consumed = .{ .shift = true },
        },
        // Caps Lock+Shift+A gives "a", which Shift changed from "A".
        .{
            .mods = .{ .shift = true, .caps_lock = true },
            .units = &.{'a'},
            .shiftless = 'A',
            .want = .{ .shift = true, .caps_lock = true },
            .consumed = .{ .shift = true },
        },
        // Shift that did not change it, or whose text was dropped
        // (Shift+Enter), was not: the encoder still needs it.
        .{
            .mods = .{ .shift = true },
            .units = &.{' '},
            .shiftless = ' ',
            .want = .{ .shift = true },
        },
        .{
            .mods = .{ .shift = true },
            .units = &.{0x0D},
            .shiftless = 0x0D,
            .want = .{ .shift = true },
        },
    };
    for (cases) |c| {
        var text: Surface.Text = .{};
        var carry: ?u16 = null;
        for (c.units) |u| text.add(c.msg, u);
        text.finish(&carry);
        const got = Surface.keyMods(c.mods, &text, c.shiftless, Surface.isAltGr(c.mods, &text));
        try std.testing.expectEqual(c.want, got.mods);
        try std.testing.expectEqual(c.consumed, got.consumed);
    }
}

test "win32: AltGr's release reports its press's modifiers" {
    const t = std.testing;
    const ctrl_alt: input.Mods = .{ .ctrl = true, .alt = true };
    var held: std.StaticBitSet(512) = .initEmpty();
    const q = 0x10;
    const a = 0x1E;

    // German AltGr+Q: '@' on the press and the repeat, no text on the
    // release, with LCtrl+RAlt down throughout. All three report neither.
    var at: Surface.Text = .{};
    var carry: ?u16 = null;
    at.add(win32.WM_CHAR, '@');
    at.finish(&carry);
    const none: Surface.Text = .{};
    for ([_]struct { input.Action, *const Surface.Text }{
        .{ .press, &at },
        .{ .repeat, &at },
        .{ .release, &none },
    }) |ev| {
        const alt_gr = Surface.altGrKey(&held, q, ev[0], ctrl_alt, ev[1]);
        try t.expect(alt_gr);
        try t.expectEqual(input.Mods{}, Surface.keyMods(ctrl_alt, ev[1], 'q', alt_gr).mods);
    }
    try t.expect(!held.isSet(q));

    // A Ctrl+Alt chord that types nothing keeps both on press and release,
    // and a release whose press was AltGr does not leak to another key.
    _ = Surface.altGrKey(&held, q, .press, ctrl_alt, &at);
    try t.expect(!Surface.altGrKey(&held, a, .press, ctrl_alt, &none));
    try t.expect(!Surface.altGrKey(&held, a, .release, ctrl_alt, &none));
    try t.expect(Surface.altGrKey(&held, q, .release, ctrl_alt, &none));
}

test "win32: the first Shift released of two is owed a release" {
    const t = std.testing;

    // LShift and RShift pressed, then both released: Windows sends a key-up
    // for only one of them.
    var shift: Surface.ShiftKeys = .{};
    shift.sent(.shift_left, .press);
    shift.sent(.shift_right, .press);
    shift.sent(.shift_right, .release);
    try t.expectEqual(input.Key.shift_left, shift.owed(false, false));
    shift.sent(.shift_left, .release);
    try t.expectEqual(null, shift.owed(false, false));

    // Not while that Shift is still down.
    shift.sent(.shift_left, .press);
    shift.sent(.shift_right, .press);
    shift.sent(.shift_right, .release);
    try t.expectEqual(null, shift.owed(true, false));

    // Never for a Shift whose press the core did not see.
    shift = .{};
    shift.sent(.shift_right, .press);
    shift.sent(.shift_right, .release);
    try t.expectEqual(null, shift.owed(false, false));
}

test "win32: Shift is judged with Caps Lock still applied" {
    // The expected characters are the US layout's.
    if (inputLanguage() != 0x0409) return error.SkipZigTest;

    const vk_a = 'A';
    const scan_a = 0x1E;
    var state = std.mem.zeroes([256]win32.BYTE);
    state[@intCast(win32.VK_CAPITAL)] = 0x01;
    state[@intCast(win32.VK_SHIFT)] = 0x80;
    state[@intCast(win32.VK_LSHIFT)] = 0x80;

    // Caps Lock+Shift+A types "a", the same as A with no modifiers, so only
    // the state without Shift shows that Shift changed it.
    try std.testing.expectEqual('a', layoutCodepoint(vk_a, scan_a, &state));
    try std.testing.expectEqual('a', unshiftedCodepoint(vk_a, scan_a));
    try std.testing.expectEqual('A', shiftlessCodepoint(vk_a, scan_a, &state));

    // Without Caps Lock, Shift is all that changed it.
    state[@intCast(win32.VK_CAPITAL)] = 0;
    try std.testing.expectEqual('A', layoutCodepoint(vk_a, scan_a, &state));
    try std.testing.expectEqual('a', shiftlessCodepoint(vk_a, scan_a, &state));
}

test "win32: AltGr is a Left Ctrl followed by an extended Right Alt" {
    const time: win32.DWORD = 1000;
    var next: win32.MSG = std.mem.zeroes(win32.MSG);
    next.message = win32.WM_KEYDOWN;
    next.wParam = win32.VK_MENU;
    next.lParam = @bitCast(@as(usize, 0x0138_0001));
    next.time = time;
    try std.testing.expect(isAltGrRightAlt(&next, time));

    // The release half, and the WM_SYS* forms, pair the same way.
    for ([_]win32.UINT{ win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP }) |m| {
        var n = next;
        n.message = m;
        try std.testing.expect(isAltGrRightAlt(&n, time));
    }

    // A Right Alt pressed later is a separate key: the Ctrl is real.
    var later = next;
    later.time = time + 1;
    try std.testing.expect(!isAltGrRightAlt(&later, time));

    // Left Alt (not extended) and other keys never pair.
    var left_alt = next;
    left_alt.lParam = @bitCast(@as(usize, 0x0038_0001));
    try std.testing.expect(!isAltGrRightAlt(&left_alt, time));
    var other = next;
    other.wParam = 'A';
    try std.testing.expect(!isAltGrRightAlt(&other, time));

    // Character messages share the peeked range but are not key messages.
    var char = next;
    char.message = win32.WM_CHAR;
    try std.testing.expect(!isAltGrRightAlt(&char, time));
}

test "win32: clipboard reads are not worded as pastes and default to Cancel" {
    const paste = std.mem.span(clipboardReadPrompt(.paste));
    for ([_]apprt.ClipboardRequestType{ .osc_52_read, .kitty_read }) |state| {
        const read = std.mem.span(clipboardReadPrompt(state));
        try std.testing.expect(!std.mem.eql(u16, paste, read));
        try std.testing.expect(std.mem.indexOf(
            u16,
            read,
            std.unicode.utf8ToUtf16LeStringLiteral("aste"),
        ) == null);
    }

    try std.testing.expectEqual(
        win32.MB_DEFBUTTON2,
        ConfirmDefault.cancel.style() & win32.MB_DEFMASK,
    );
}

test "win32: clipboard text stops at the block and survives bad surrogates" {
    const alloc = std.testing.allocator;
    const Case = struct { block: []const u16, want: []const u8 };
    const cases = [_]Case{
        .{ .block = &.{}, .want = "" },
        .{ .block = &.{ 'a', 'b', 0 }, .want = "ab" },
        // Text after the terminator, such as the rest of an oversized block,
        // is not part of the text.
        .{ .block = &.{ 'a', 0, 'b', 'c' }, .want = "a" },
        .{ .block = &.{ 0xD83D, 0xDE00, 0 }, .want = "\u{1F600}" },
        .{ .block = &.{ 'a', 'b', 'c', 0xD83D, 0 }, .want = "abc\u{FFFD}" },
        .{ .block = &.{ 0xDE00, 'a' }, .want = "\u{FFFD}a" },
        .{ .block = &.{ 0xD83D, 0xD83D, 0xDE00 }, .want = "\u{FFFD}\u{1F600}" },
    };
    for (cases) |c| {
        const got = try utf8FromClipboard(alloc, c.block);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }

    // No terminator: the block's end is the text's end, even when the
    // memory after it holds more text.
    const backing = [_]u16{ 'x', 'y', 'z', 'q' };
    const got = try utf8FromClipboard(alloc, backing[0..2]);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("xy", got);
}

test "win32: clipboard writes read back, with invalid UTF-8 replaced" {
    const alloc = std.testing.allocator;

    // SetClipboardData fails for a clipboard opened without an owner window,
    // so the test needs one. A message-only STATIC window is enough.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    // Put back whatever text the clipboard held. Other formats are lost,
    // which is acceptable for a test.
    const saved = try readClipboardText(alloc, hwnd);
    defer if (saved) |text| {
        writeClipboardText(hwnd, text) catch {};
        alloc.free(text);
    };

    const Case = struct { text: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .text = "", .want = "" },
        .{ .text = "caf\u{e9} \u{1F600}", .want = "caf\u{e9} \u{1F600}" },
        // Latin-1 from a legacy program, as OSC 52 can deliver it.
        .{ .text = "caf\xe9", .want = "caf\u{FFFD}" },
    };
    for (cases) |c| {
        try writeClipboardText(hwnd, c.text);
        const got = (try readClipboardText(alloc, hwnd)) orelse
            return error.TestUnexpectedResult;
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "win32: OSC 8 links are limited to well-formed http, https and mailto" {
    const allowed = [_][]const u8{
        "https://example.com/path?q=1#f",
        "HTTP://user:pw@example.com:8080/",
        "http://[::1]:8080/",
        "mailto:someone@example.com?subject=hi",
    };
    for (allowed) |url| try std.testing.expect(osc8Allowed(url));

    const refused = [_][]const u8{
        "",
        "example.com",
        "https:relative",
        "https://",
        "https:///path",
        "https://user@/path",
        "https://:8080/",
        "mailto:",
        "mailto:?subject=hi",
        "file:///C:/Windows/System32/calc.exe",
        "ms-settings:display",
        "ftp://example.com/",
        "https://example.com/\u{200B}hidden",
        "https://example.com/\r\n",
        "https://example.com/\xff",
    };
    for (refused) |url| try std.testing.expect(!osc8Allowed(url));
}

test "win32: ime plan for a composition message" {
    const Ime = Surface.Ime;
    const A = Ime.Action;
    const comp = win32.GCS_COMPSTR;
    const result = win32.GCS_RESULTSTR;
    const cursor_pos = win32.GCS_CURSORPOS;
    const attr_clause = win32.GCS_COMPATTR | win32.GCS_COMPCLAUSE;
    const result_clause = win32.GCS_RESULTCLAUSE;

    const Case = struct { bits: u32, owner: Ime.Preedit, safe: bool, want: []const A };
    const cases = [_]Case{
        // No flag at all: cancelled. Only the IME's own preedit is cleared.
        .{ .bits = 0, .owner = .ime, .safe = true, .want = &.{.clear_preedit} },
        .{ .bits = 0, .owner = .dead_key, .safe = true, .want = &.{} },
        .{ .bits = 0, .owner = .none, .safe = true, .want = &.{} },
        // Flags outside GCS_ALL do not make it a live update.
        .{ .bits = 0x4000, .owner = .ime, .safe = true, .want = &.{.clear_preedit} },

        // A caret or clause change is a live update, never a cancel.
        .{ .bits = cursor_pos, .owner = .ime, .safe = true, .want = &.{.update_preedit} },
        .{ .bits = attr_clause, .owner = .ime, .safe = true, .want = &.{.update_preedit} },
        .{ .bits = comp, .owner = .none, .safe = true, .want = &.{.update_preedit} },

        // A result is delivered whatever the owner says, preedit cleared first.
        .{ .bits = result, .owner = .none, .safe = true, .want = &.{.commit_result} },
        .{ .bits = result | result_clause, .owner = .ime, .safe = true, .want = &.{ .clear_preedit, .commit_result } },
        .{ .bits = result, .owner = .dead_key, .safe = true, .want = &.{ .clear_preedit, .commit_result } },
        // Korean: a syllable is committed and the next one starts at once.
        .{ .bits = result | comp, .owner = .ime, .safe = true, .want = &.{ .clear_preedit, .commit_result, .update_preedit } },

        // Without the core nothing calls it: results wait, the rest is dropped.
        .{ .bits = 0, .owner = .ime, .safe = false, .want = &.{} },
        .{ .bits = comp, .owner = .ime, .safe = false, .want = &.{} },
        .{ .bits = result, .owner = .ime, .safe = false, .want = &.{.defer_result} },
        .{ .bits = result | comp, .owner = .none, .safe = false, .want = &.{.defer_result} },
    };
    for (cases) |c| {
        const got = Ime.plan(c.bits, c.owner, c.safe);
        try std.testing.expectEqualSlices(A, c.want, got.actions());
    }

    // A deferred result (`flushIme`) replaces the same preedits.
    try std.testing.expect(!Ime.Preedit.none.clearedByCommit());
    try std.testing.expect(Ime.Preedit.dead_key.clearedByCommit());
    try std.testing.expect(Ime.Preedit.ime.clearedByCommit());

    // Every result is either committed or deferred, for every input.
    for ([_]Ime.Preedit{ .none, .dead_key, .ime }) |owner| {
        for ([_]bool{ false, true }) |safe| {
            for ([_]u32{ result, result | comp, result | cursor_pos, win32.GCS_ALL }) |bits| {
                var delivered: usize = 0;
                for (Ime.plan(bits, owner, safe).actions()) |a| {
                    if (a == .commit_result or a == .defer_result) delivered += 1;
                }
                try std.testing.expectEqual(1, delivered);
            }
        }
    }
}

test "win32: wide strings become UTF-8 with unpaired surrogates replaced" {
    const alloc = std.testing.allocator;
    const Case = struct { units: []const u16, want: []const u8 };
    const cases = [_]Case{
        .{ .units = &.{}, .want = "" },
        .{ .units = &.{ 0x65E5, 0x672C }, .want = "\u{65E5}\u{672C}" },
        .{ .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}" },
        .{ .units = &.{ 'a', 0x000A, 'b' }, .want = "a\nb" },
        .{ .units = &.{ 'a', 0xD83D }, .want = "a\u{FFFD}" },
        .{ .units = &.{ 0xDE00, 'a' }, .want = "\u{FFFD}a" },
        .{ .units = &.{ 0xD83D, 'a', 0xDE00 }, .want = "\u{FFFD}a\u{FFFD}" },
        .{ .units = &.{ 0xD83D, 0xD83D, 0xDE00 }, .want = "\u{FFFD}\u{1F600}" },
    };
    for (cases) |c| {
        const got = try utf8FromWide(alloc, c.units);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "win32: utf-8 becomes wide text with invalid sequences replaced" {
    const alloc = std.testing.allocator;
    const Case = struct { text: []const u8, want: []const u16 };
    const cases = [_]Case{
        .{ .text = "", .want = &.{} },
        .{ .text = "\u{65E5}\u{1F600}", .want = &.{ 0x65E5, 0xD83D, 0xDE00 } },
        // Latin-1, as from a config saved in a legacy code page.
        .{ .text = "caf\xe9", .want = &.{ 'c', 'a', 'f', 0xFFFD } },
    };
    for (cases) |c| {
        const got = try wideFromUtf8(alloc, c.text);
        defer alloc.free(got);
        try std.testing.expectEqualSlices(u16, c.want, got);
        try std.testing.expectEqual(0, got[got.len]);
    }
}

test "win32: ime forms follow the cursor cell" {
    const Ime = Surface.Ime;
    const client: win32.RECT = .{ .left = 0, .top = 0, .right = 2000, .bottom = 1000 };

    // 200% DPI, 20x40 px cells, cursor at column 3, row 2, two cells of
    // preedit. The core reports the cell's middle and bottom in 96-DPI
    // pixels, and the width in physical pixels.
    const pos: apprt.IMEPos = .{ .x = (3 * 20 + 10) / 2.0, .y = (3 * 40) / 2.0, .width = 40, .height = 40 / 2.0 };
    const form = Ime.formFor(pos, 2.0, 20, client);
    try std.testing.expectEqual(win32.RECT{ .left = 60, .top = 80, .right = 100, .bottom = 120 }, form.rc);
    try std.testing.expectEqual(win32.POINT{ .x = 60, .y = 120 }, form.pt);

    // No preedit yet: one cell wide.
    var none = pos;
    none.width = 0;
    try std.testing.expectEqual(@as(win32.LONG, 80), Ime.formFor(none, 2.0, 20, client).rc.right);

    // Never outside the client area, whatever the core reports.
    const wild: apprt.IMEPos = .{ .x = 5000, .y = -50, .width = std.math.nan(f64), .height = 1e12 };
    const clamped = Ime.formFor(wild, 2.0, 20, client).rc;
    try std.testing.expect(clamped.left >= 0 and clamped.right <= 2000 and clamped.left <= clamped.right);
    try std.testing.expect(clamped.top >= 0 and clamped.bottom <= 1000 and clamped.top <= clamped.bottom);
}

test "win32: ime message fields" {
    const Ime = Surface.Ime;

    // ISC_SHOWUICOMPOSITIONWINDOW is bit 31 of a sign-extended value.
    const all: win32.LPARAM = @bitCast(@as(usize, 0xFFFF_FFFF_C000_000F));
    const want: win32.LPARAM = @bitCast(@as(usize, 0xFFFF_FFFF_4000_000F));
    try std.testing.expectEqual(want, Ime.setContextLparam(all));
    try std.testing.expectEqual(@as(win32.LPARAM, 0x4000_000F), Ime.setContextLparam(0x4000_000F));

    // Scan code 0x1E, not extended; then the same with the extended flag.
    try std.testing.expectEqual(@as(usize, 0x01E), Ime.scanSlot(0x001E_0001));
    try std.testing.expectEqual(@as(usize, 0x11E), Ime.scanSlot(@bitCast(@as(usize, 0xC11E_0001))));
}

test "win32: ime withholds the release of a key it claimed" {
    const Ime = Surface.Ime;
    const down = win32.WM_KEYDOWN;
    const up = win32.WM_KEYUP;
    const vk_a: win32.WPARAM = 0x41;
    // Scan code 0x1E (A): its key-down, its key-up, and the same key with
    // the extended flag, which is another slot.
    const a_down: win32.LPARAM = 0x001E_0001;
    const a_up: win32.LPARAM = @bitCast(@as(usize, 0xC01E_0001));
    const ext_up: win32.LPARAM = @bitCast(@as(usize, 0xC11E_0001));

    // A key the IME never claimed reaches the core both ways.
    {
        var ime: Ime = .{};
        try std.testing.expectEqual(.deliver, ime.filterKey(down, vk_a, a_down));
        try std.testing.expectEqual(.deliver, ime.filterKey(up, vk_a, a_up));
    }

    // The IME claims the press; its release comes with the real virtual
    // key and is withheld once. Alt held makes them WM_SYS* messages.
    for ([_][2]win32.UINT{
        .{ win32.WM_KEYDOWN, win32.WM_KEYUP },
        .{ win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP },
    }) |pair| {
        var ime: Ime = .{};
        try std.testing.expectEqual(.withhold, ime.filterKey(pair[0], win32.VK_PROCESSKEY, a_down));
        try std.testing.expectEqual(.deliver, ime.filterKey(pair[1], vk_a, ext_up));
        try std.testing.expectEqual(.withhold, ime.filterKey(pair[1], vk_a, a_up));
        try std.testing.expectEqual(.deliver, ime.filterKey(pair[1], vk_a, a_up));
    }

    // The release comes as VK_PROCESSKEY too: the slot stays set until
    // the key's next press, which reaches the core with its release.
    {
        var ime: Ime = .{};
        try std.testing.expectEqual(.withhold, ime.filterKey(down, win32.VK_PROCESSKEY, a_down));
        try std.testing.expectEqual(.withhold, ime.filterKey(up, win32.VK_PROCESSKEY, a_up));
        try std.testing.expectEqual(.deliver_withheld, ime.filterKey(down, vk_a, a_down));
        try std.testing.expectEqual(.deliver, ime.filterKey(up, vk_a, a_up));
    }
}

test "win32: ime completes Korean on focus loss and cancels the rest" {
    const Ime = Surface.Ime;
    // Any Korean sublanguage, or none.
    try std.testing.expectEqual(win32.CPS_COMPLETE, Ime.focusLossAction(0x0412));
    try std.testing.expectEqual(win32.CPS_COMPLETE, Ime.focusLossAction(0x0812));
    try std.testing.expectEqual(win32.CPS_COMPLETE, Ime.focusLossAction(0x0012));
    // Japanese, Chinese, English, no layout.
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0411));
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0804));
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0409));
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0));
    // The primary language is 10 bits: 0x212 (custom range) is not Korean.
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0212));
}

test "win32: losing focus mid-drag wakes the app loop" {
    // WM_KILLFOCUS is sent, so GetMessageW in `App.run` does not return
    // for it; the release owed for a held button (syncDeferredMouse) is
    // only sent once something is posted. A message-only window stands in
    // for both the app's and the surface's: the handler only needs a
    // queue to post to and a window that does not hold the capture, as
    // after the system has already taken it away.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    var app: App = undefined;
    app.msg_hwnd = hwnd;

    // Only what the focus handler reads, with no core surface. Static
    // because the struct embeds a whole CoreSurface.
    const s = struct {
        var surface: Surface = undefined;
    };
    const surface = &s.surface;
    surface.app = &app;
    surface.hwnd = hwnd;
    surface.core_state = .none;
    surface.ime = .{};
    surface.preedit = .none;

    const Case = struct { held: Surface.Mouse.Button.Set, want: bool };
    const cases = [_]Case{
        .{ .held = .initOne(.left), .want = true },
        // Nothing is owed, so nothing needs the loop.
        .{ .held = .empty, .want = false },
    };
    for (cases) |c| {
        surface.focused = true;
        surface.mouse = .init();
        surface.mouse.held = c.held;
        _ = surface.handleMessage(hwnd, win32.WM_KILLFOCUS, 0, 0);

        var msg: win32.MSG = undefined;
        const woken = win32.PeekMessageW(
            &msg,
            hwnd,
            WM_GHOSTTY_WAKEUP,
            WM_GHOSTTY_WAKEUP,
            win32.PM_REMOVE,
        ).toBool();
        try std.testing.expectEqual(c.want, woken);
    }
}

test "win32: modal loops are counted per window and returned on destroy" {
    // The app ticks the core from its window procedure while any window is
    // in a size/move or menu loop (WM_GHOSTTY_WAKEUP), so the count must
    // not leak past a loop's end or a window's. One message-only window
    // stands in for both surfaces' windows: these handlers never use it.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    var app: App = undefined;
    app.modal_loop_depth = 0;
    // Empty, so WM_DESTROY's surfaceDestroyed frees nothing.
    app.surfaces = .empty;

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var a: Surface = undefined;
        var b: Surface = undefined;
    };
    for ([_]*Surface{ &s.a, &s.b }) |surface| {
        surface.app = &app;
        surface.hwnd = hwnd;
        surface.core_state = .none;
        surface.modal_loops = 0;
    }

    _ = s.a.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    _ = s.a.handleMessage(hwnd, win32.WM_ENTERMENULOOP, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    // An exit with no loop of its own takes nothing from another window.
    _ = s.b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    _ = s.b.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    try std.testing.expectEqual(3, app.modal_loop_depth);

    // Destroyed inside both of its loops, so their exits never come.
    _ = s.a.handleMessage(hwnd, win32.WM_DESTROY, 0, 0);
    try std.testing.expectEqual(1, app.modal_loop_depth);

    _ = s.b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
    _ = s.b.handleMessage(hwnd, win32.WM_EXITMENULOOP, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
}

test "win32: only an armed quit timer expires" {
    // KillTimer leaves a WM_TIMER that is already queued in place, so the
    // quit timer's can arrive after `.stop` has cancelled it. Expiring the
    // timer then would make `run` quit with a window on screen. A
    // message-only window stands in for the app's; the handler only needs
    // the App behind it.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    var app: App = undefined;
    app.msg_hwnd = hwnd;
    _ = win32.SetWindowLongPtrW(
        hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(&app)),
    );

    const State = @TypeOf(app.quit_timer);
    const Case = struct { from: State, want: State };
    const cases = [_]Case{
        .{ .from = .active, .want = .expired },
        // Stopped after the message was queued.
        .{ .from = .off, .want = .off },
    };
    for (cases) |c| {
        app.quit_timer = c.from;
        _ = App.wndProc(hwnd, win32.WM_TIMER, quit_timer_id, 0);
        try std.testing.expectEqual(c.want, app.quit_timer);
    }
}
