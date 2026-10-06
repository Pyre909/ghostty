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
//!     `Surface.close` from its own stack (src/Surface.zig:1316, :2848), and
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
    const RECT = extern struct {
        left: LONG,
        top: LONG,
        right: LONG,
        bottom: LONG,
    };

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

    const MB_OK: UINT = 0x00000000;
    const MB_OKCANCEL: UINT = 0x00000001;
    const MB_ICONWARNING: UINT = 0x00000030;
    const MB_ICONERROR: UINT = 0x00000010;
    const IDOK: c_int = 1;

    const MB_ICONASTERISK: UINT = 0x00000040;

    /// GetDeviceCaps index for horizontal DPI. Used as the pre-1607 fallback
    /// for GetDpiForWindow, where it is the correct answer: those versions
    /// have no per-monitor DPI at all.
    const LOGPIXELSX: c_int = 88;

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

    extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
    extern "kernel32" fn GetProcAddress(
        module: HINSTANCE,
        name: [*:0]const u8,
    ) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
    extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
    extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;

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
    extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
    extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
    extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
    extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
    extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
    extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
    extern "user32" fn WindowFromPoint(pt: POINT) callconv(.winapi) ?HWND;
    extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
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
    const GCS_COMPSTR: u32 = 0x0008;
    const GCS_RESULTSTR: u32 = 0x0800;
    /// Every GCS_* flag. A WM_IME_COMPOSITION with none of them set means
    /// the composition was cancelled.
    const GCS_ALL: u32 = 0x1FBF;
    const CFS_POINT: DWORD = 0x0002;
    const CFS_EXCLUDE: DWORD = 0x0080;
    const NI_COMPOSITIONSTR: DWORD = 0x0015;
    const CPS_COMPLETE: DWORD = 0x0001;
    const CPS_CANCEL: DWORD = 0x0004;
    const LANG_KOREAN: u16 = 0x12;
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
    /// path (`CoreApp.keyEvent`, src/App.zig:359) reads
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

    /// True while the quit timer is armed on `msg_hwnd`.
    quit_timer_active: bool,

    /// A zero-delay quit request that has been recorded but not acted on.
    ///
    /// `main_ghostty.zig:111` calls `startQuitTimer` *before*
    /// `main_ghostty.zig:114` calls `run`, and
    /// `quit-after-last-window-closed-delay` is unset by default
    /// (src/config/Config.zig:2680), i.e. zero delay. Quitting synchronously
    /// at that point would set `quit` before the loop ever began and the
    /// process would exit with its window still on screen. GTK has the same
    /// ordering and resolves it the same way, by recording the expiry and
    /// evaluating it later (apprt/gtk/class/application.zig:864).
    ///
    /// `run` acts on this only when there are genuinely no surfaces left.
    quit_pending: bool,

    /// True while `core_app.tick` is on the stack. See `tick`.
    ticking: bool,

    /// Number of modal confirmation prompts (`confirm`) currently open.
    ///
    /// A prompt runs a nested message loop, often with a core frame beneath
    /// it (`Surface.close` from `keyCallback`, a clipboard confirmation from
    /// `tick`). Neither ticking nor surface teardown may run inside that loop;
    /// see `canReenterCore`.
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

    /// `main_ghostty.zig:104` declares `var app_runtime: apprt.App = undefined`
    /// on its stack, so this initializes in place and never returns a value.
    /// The App therefore has a stable address for the process lifetime, which
    /// is what lets `Surface.rtApp` hand out a pointer derived from it.
    pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
        _ = opts;

        const alloc = core_app.alloc;

        const hinstance = win32.GetModuleHandleW(null) orelse
            return Error.Win32WindowCreationFailed;

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
            .quit_timer_active = false,
            .quit_pending = false,
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
        // Every remaining surface is torn down in the same order as
        // Surface.destroyPosted (stop and wait for the core's threads, deinit
        // the core surface, destroy the window), so
        // that CoreApp.deinit -- which runs after this
        // (main_ghostty.zig:104-105) -- finds an empty surface list and its
        // `font_grid_set.count() == 0` assert holds (src/App.zig:141).
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
        // DestroyWindow runs WM_DESTROY synchronously, which reenters
        // surfaceDestroyed and mutates this list. Moving the list out first
        // makes the iteration stable: the callback finds no membership,
        // leaving the free to us.
        var surfaces = self.surfaces;
        self.surfaces = .empty;
        defer surfaces.deinit(self.core_app.alloc);
        for (surfaces.items) |surface| {
            surface.stopCore();
            surface.destroy();
            surface.deinit();
            self.core_app.alloc.destroy(surface);
        }

        if (self.quit_timer_active) {
            _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
            self.quit_timer_active = false;
        }

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
                fatalNotice(self.core_app.alloc, err);
                return err;
            };
        }

        var msg: win32.MSG = undefined;
        while (!self.quit) {
            // Act on a recorded zero-delay quit here rather than where it was
            // recorded (see `quit_pending`): only here is it known both that
            // the loop has started and that no window is on screen.
            if (self.quit_pending and self.surfaces.items.len == 0) {
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

    /// Wait until every thread in `handles` has exited, while keeping the
    /// main thread responsive: messages are dispatched and the core ticked
    /// between wakeups.
    ///
    /// Pumping is required, not cosmetic. The render and IO threads push into
    /// the app mailbox with `.forever` (e.g. src/renderer/generic.zig:1996),
    /// and only a tick on this thread drains it; a plain WaitForSingleObject
    /// here could wait on a thread that is waiting on us.
    ///
    /// A WM_QUIT pulled out of the queue while pumping is re-posted
    /// afterwards, so a quit requested meanwhile still ends `run`.
    fn waitForThreads(self: *App, handles_in: []const win32.HANDLE) void {
        var handles: [2]win32.HANDLE = undefined;
        std.debug.assert(handles_in.len <= handles.len);
        @memcpy(handles[0..handles_in.len], handles_in);
        var remaining: win32.DWORD = @intCast(handles_in.len);

        var quit_seen = false;
        defer if (quit_seen) win32.PostQuitMessage(0);

        // One-second slices only so that a stuck thread is reported once;
        // the wait itself is unbounded, as the join after it would be.
        var slices: u32 = 0;
        while (remaining > 0) {
            const r = win32.MsgWaitForMultipleObjectsEx(
                remaining,
                &handles,
                1000,
                win32.QS_ALLINPUT,
                // Return for input already in the queue too, not only for
                // input that arrives after the call. Without it a message
                // that was peeked but not removed would not wake us.
                win32.MWMO_INPUTAVAILABLE,
            );

            if (r >= win32.WAIT_OBJECT_0 and r < win32.WAIT_OBJECT_0 + remaining) {
                // That thread has exited. Swap-remove it and keep waiting
                // for the rest.
                const i = r - win32.WAIT_OBJECT_0;
                handles[i] = handles[remaining - 1];
                remaining -= 1;
                continue;
            }

            if (r == win32.WAIT_OBJECT_0 + remaining) {
                var msg: win32.MSG = undefined;
                while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
                    if (msg.message == win32.WM_QUIT) {
                        quit_seen = true;
                        continue;
                    }
                    _ = win32.TranslateMessage(&msg);
                    _ = win32.DispatchMessageW(&msg);
                }
                self.tickFromHandler();
                continue;
            }

            if (r == win32.WAIT_TIMEOUT) {
                slices += 1;
                if (slices == 5) log.warn(
                    "surface threads have not exited after 5s; still waiting",
                    .{},
                );
                continue;
            }

            // WAIT_FAILED (a bad handle). There is nothing to wait on
            // reliably any more; the joins in CoreSurface.deinit that follow
            // will block or fail loudly on their own.
            log.err(
                "MsgWaitForMultipleObjectsEx failed r={x} err={}",
                .{ r, std.os.windows.GetLastError() },
            );
            return;
        }
    }

    /// Called from the renderer and IO threads via `App.Mailbox.push`
    /// (src/App.zig:591), so this must be thread-safe and must not block.
    /// PostMessageW is both.
    pub fn wakeup(self: *App) void {
        _ = win32.PostMessageW(self.msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
    }

    /// `main_ghostty.zig:111` calls this before `run` because a freshly
    /// started app has no surfaces yet.
    pub fn startQuitTimer(self: *App) void {
        // The result is dropped because main_ghostty.zig:111 has nothing to do
        // with it; a failure to arm is already logged by setQuitTimer.
        _ = self.setQuitTimer(.start);
    }

    /// Keyboard layout detection exists only on macOS: `input.Keymap` is
    /// `KeymapNoop` everywhere else (src/input.zig:41-46). `.unknown` is the
    /// honest answer, and it maps to option-as-alt `.false` at the one call
    /// site (src/Surface.zig:3317).
    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        _ = self;
        return .unknown;
    }

    /// Actions this runtime actually performs. Anything not named here
    /// returns `false`, which is the contract's word for "unsupported" -- see
    /// src/apprt/action.zig:75-77. Returning `true` for an action that did not
    /// happen would be a lie the core cannot detect.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        return switch (action) {
            .quit => quit: {
                self.quit = true;
                win32.PostQuitMessage(0);
                break :quit true;
            },

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

            .ring_bell => ring_bell: {
                _ = win32.MessageBeep(win32.MB_ICONASTERISK);
                break :ring_bell true;
            },

            // Everything else, including `.new_window` (see `run`),
            // `.cell_size`, `.size_limit` and `.initial_size` (sent during
            // CoreSurface.init; `false` is a valid answer to each), and
            // `.mouse_over_link` (a link-preview UI this runtime lacks; the
            // core tracks the link itself and ignores the result,
            // src/Surface.zig:1668, :4585).
            else => false,
        };
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
            // binding to this action, src/config/Config.zig:6775-6777) and a
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
    /// typing and shows it on the next mouse event (src/Surface.zig:4791).
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
    /// same link to the core's generic opener (src/Surface.zig:4471-4483)
    /// and bypass the policy. The other kinds are link text the user can
    /// see, or paths the core resolved from it, and open unchanged.
    ///
    /// Nothing here may dispatch messages: the core calls this while
    /// holding its renderer lock (src/Surface.zig:3939-3941), and the next
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
        if (self.quit_timer_active) {
            _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
            self.quit_timer_active = false;
        }

        switch (mode) {
            .stop => {
                self.quit_pending = false;
                return true;
            },

            .start => {
                // The apprt owns the quit-after-last-window policy, and this
                // foundation deliberately overrides the configuration.
                //
                // `quit-after-last-window-closed` is `builtin.os.tag == .linux`
                // (src/config/Config.zig:2639), i.e. false on Windows. But
                // `.new_window` is refused by this runtime (see `run`), so a
                // process that reaches zero windows
                // has no UI left and no way to get one back. Honoring `false`
                // would leave an invisible process with a message-only window
                // that receives nothing and a GetMessageW that blocks forever,
                // endable only from Task Manager.
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
                // runs before run() does. Record the intent and let run()
                // decide; see the `quit_pending` field.
                if (delay_ms == 0) {
                    self.quit_pending = true;
                    return true;
                }

                const id = win32.SetTimer(
                    self.msg_hwnd,
                    quit_timer_id,
                    std.math.cast(win32.UINT, delay_ms) orelse std.math.maxInt(win32.UINT),
                    null,
                );
                self.quit_timer_active = id != 0;
                if (id == 0) {
                    log.warn("failed to arm the quit timer", .{});
                    return false;
                }

                return true;
            },
        }
    }

    /// Report that the process is quitting because of the override in
    /// setQuitTimer rather than because the configuration asked for it.
    /// Called only at the two points where that quit is carried out.
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
        // (src/App.zig:203), so there is no quit-timer handling here.
        const surface = try Surface.create(self);

        // No errdefer after this point: appendAssumeCapacity cannot fail (the
        // capacity was reserved above), so one would be dead code.
        self.surfaces.appendAssumeCapacity(surface);

        return surface;
    }

    /// Called from the surface's WM_DESTROY handler.
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
        // when the core's last surface goes (src/App.zig:237).
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

            win32.WM_TIMER => if (wparam == quit_timer_id) {
                _ = win32.KillTimer(hwnd, quit_timer_id);
                self.quit_timer_active = false;
                self.logQuitOverride();
                self.quit = true;
                win32.PostQuitMessage(0);
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
fn logEffectiveDpiAwareness(user32: win32.HINSTANCE) void {
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
    /// owner and never clears it itself (src/Surface.zig:2562-2570), so each
    /// source must only clear what it set. Written by `setPreedit` alone.
    preedit: Ime.Preedit,

    ime: Ime,

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
    /// teardown pumps messages (`App.waitForThreads`): between
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

        /// Keys whose key-down the IME claimed (VK_PROCESSKEY), by
        /// `scanSlot`. The core never saw those presses, so a key-up that
        /// arrives with the real virtual key is kept from it as well.
        swallow_up: std.StaticBitSet(512) = .initEmpty(),

        const Preedit = enum { none, dead_key, ime };

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
                    // A commit replaces whatever preedit is showing, as in
                    // GTK (src/apprt/gtk/class/surface.zig imCommit).
                    if (owner != .none) p.add(.clear_preedit);
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
        /// pixels (src/Surface.zig:2168-2183); `scale` is DPI / 96 and
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

        /// UTF-8 for an IME string. Unpaired surrogates are dropped: they
        /// have no UTF-8 form, and the core's preedit rejects invalid
        /// input. Nothing else is filtered, as in the GTK and macOS
        /// runtimes.
        fn utf8FromUtf16(alloc: Allocator, units: []const u16) Allocator.Error![]u8 {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(alloc);
            try out.ensureTotalCapacity(alloc, units.len * 3);

            var i: usize = 0;
            while (i < units.len) : (i += 1) {
                const unit = units[i];
                var cp: u21 = unit;
                if (std.unicode.utf16IsHighSurrogate(unit)) {
                    if (i + 1 >= units.len or !std.unicode.utf16IsLowSurrogate(units[i + 1])) continue;
                    cp = std.unicode.utf16DecodeSurrogatePair(&[_]u16{ unit, units[i + 1] }) catch continue;
                    i += 1;
                } else if (std.unicode.utf16IsLowSurrogate(unit)) {
                    continue;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                out.appendSliceAssumeCapacity(buf[0..n]);
            }
            return out.toOwnedSlice(alloc);
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
        /// treat any negative coordinate that way (src/Surface.zig:4573-4575,
        /// :1592). Paths that map a position to a cell clamp it to the
        /// nearest cell instead (src/renderer/size.zig:142-147).
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
                // shape (src/terminal/Terminal.zig:89); the GTK runtime
                // starts there too.
                .shape = .text,
                .cursor = win32.LoadCursorW(null, cursorId(.text)),
                .hidden = false,
            };
        }

        /// The buttons this runtime reports: a separate enum from
        /// input.MouseButton, so nothing else can be sent.
        ///   * `.unknown` would mask motion reports;
        ///   * `.four`-`.seven` are the wheel, which scrollCallback reports;
        ///   * `.eleven` indexes past the end of the core's click_state
        ///     (src/Surface.zig:226, :3838).
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

        /// Whole notches out of wheel deltas.
        ///
        /// The core cannot take fractions of a notch: for x it rounds each
        /// event and keeps no remainder (src/Surface.zig:3561), and for y it
        /// drops the remainder whenever an event crosses a row
        /// (src/Surface.zig:3549 stores `poff - amount * cell_size` with
        /// the untruncated `amount`). A high-resolution wheel's small deltas
        /// would lose rows either way, so only whole notches are passed on.
        /// A change of direction drops the remainder, so a reversal counts
        /// from its own first delta.
        const Notches = struct {
            rem: i32 = 0,

            fn add(self: *Notches, delta: i32) ?i32 {
                if (delta == 0) return null;
                if (self.rem != 0 and (self.rem < 0) != (delta < 0)) self.rem = 0;
                self.rem += delta;
                const whole = @divTrunc(self.rem, win32.WHEEL_DELTA);
                if (whole == 0) return null;
                self.rem -= whole * win32.WHEEL_DELTA;
                return whole;
            }
        };
    };

    /// Heap-allocate and initialize, including the core surface. The address
    /// must be stable: the core stores raw `*apprt.Surface` pointers
    /// (src/Surface.zig:465-466), and the wndproc recovers this pointer from
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
            .closing = false,
            .destroy_deferred = false,
            .preedit = .none,
            .ime = .{},
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
        // routes is checked with hasSurface (src/App.zig:514-529), so a
        // message queued before registration would be dropped. addSurface
        // also cancels the startup quit timer.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Preconditions CoreSurface.init relies on, both true here: the HWND
        // exists at CW_USEDEFAULT size so getSize is non-zero
        // (src/Surface.zig:529), and getContentScale works on it (:501).
        var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
        defer config.deinit();
        try self.core_surface.init(alloc, &config, app.core_app, app, self);

        // Nothing after this point can fail, so there is no errdefer for the
        // core surface. (If CoreSurface.init itself fails after spawning its
        // threads, those threads are not stopped by init's own errdefers;
        // that is a core limitation this runtime cannot repair.)
        self.core_state = .live;

        // The first WM_SIZE, WM_SETFOCUS and WM_PAINT reach the core from
        // here, now that `core_state` is `.live`.
        _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);
        _ = win32.UpdateWindow(hwnd);

        return self;
    }

    /// Release everything except the allocation itself.
    ///
    /// Public because `CoreApp.deinit` calls it on every surface the core
    /// still tracks (src/App.zig:134) -- an apprt contract method the
    /// rt_surface list does not name. In this runtime the core's list is
    /// empty by then (`App.terminate` runs `stopCore` on every surface first).
    pub fn deinit(self: *Surface) void {
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.title = null;
        self.ime.pending.clearAndFree(self.app.core_app.alloc);
    }

    /// Tear down the OS window. The allocation itself is not freed here; see
    /// the ownership invariant on `App.surfaceDestroyed`.
    fn destroy(self: *Surface) void {
        _ = win32.DestroyWindow(self.hwnd);
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
    ///   1. `deleteSurface` first, so the ticks in steps 3-4 drop any message
    ///      still addressed to this surface instead of calling into it
    ///      (src/App.zig:514-529). It also starts the quit timer when this was
    ///      the last surface.
    ///   2. Stop the search thread, if any, while the render thread is still
    ///      draining its mailbox. `CoreSurface.deinit` would do this first
    ///      too (src/Surface.zig:794), but with an unpumped join, and by then
    ///      the render thread is gone: a search thread blocked on a
    ///      `.forever` push into the full renderer mailbox
    ///      (src/renderer/Thread.zig:27) would never return and the main
    ///      thread would hang. Clearing `search` makes deinit skip it.
    ///   3. Stop the IO thread and wait for it (`App.waitForThreads`, which
    ///      pumps messages and ticks), still before the renderer. Its reader
    ///      can also block on a `.forever` renderer mailbox push
    ///      (src/termio/stream_handler.zig:177), and `Exec.threadExit`
    ///      cannot cancel a thread that is not in I/O. Upstream
    ///      `CoreSurface.deinit` stops the renderer first
    ///      (src/Surface.zig:797-807); this order is deliberately the
    ///      reverse. Nothing the render thread does waits on the IO thread
    ///      (it only pushes to the app mailbox, which the ticks drain), and
    ///      the terminal state both share is freed only in step 5.
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
    /// on the main thread, is exactly the unpumped wait steps 3-4 exist to
    /// avoid. If those fields are renamed this stops compiling, which is the
    /// desired failure.
    ///
    /// The search join in step 2 is itself unpumped, as upstream's is; it
    /// is bounded because the render thread is still draining.
    fn stopCore(self: *Surface) void {
        if (self.core_state != .live) return;
        self.core_state = .stopping;

        // A drag in progress ends with the core. Button messages for a
        // `.stopping` surface are not handled, so nothing else would release
        // the capture while this pumps messages (App.waitForThreads).
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
            s.deinit();
            cs.search = null;
        }

        cs.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop err={}", .{err});
        app.waitForThreads(&.{cs.io_thr.getHandle()});

        cs.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop err={}", .{err});
        app.waitForThreads(&.{cs.renderer_thr.getHandle()});

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
    /// `App.waitForThreads` -- never directly inside a core frame, because
    /// the message is only ever posted. When a core frame or prompt is
    /// nonetheless beneath that loop (`App.canReenterCore`), the teardown is
    /// deferred to `run` instead: its pump would tick, and waiting there
    /// could wait on threads blocked behind the undrained mailbox.
    ///
    /// **`self` is freed by the DestroyWindow at the end** (WM_DESTROY ->
    /// App.surfaceDestroyed). Nothing may touch it afterwards, which is why
    /// `hwnd` is copied first and the function ends at that call.
    fn destroyPosted(self: *Surface) void {
        const app = self.app;

        // terminate drives teardown itself; see App.terminate.
        if (app.terminating) return;

        if (!app.canReenterCore()) {
            self.destroy_deferred = true;
            return;
        }

        const hwnd = self.hwnd;
        self.stopCore();
        _ = win32.DestroyWindow(hwnd);
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
    /// This is called from inside core frames (src/Surface.zig:1316 from
    /// `childExited`, :2848 from `keyCallback`) and so must never destroy
    /// anything itself: it posts WM_GHOSTTY_DESTROY and returns. That is also
    /// why a `.closed` InputEffect leaves `self` valid in `keyEvent`.
    ///
    /// `*Surface` rather than `*const`: the core calls this through a mutable
    /// `rt_surface` (src/Surface.zig:841-843).
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
        )) {
            // `self` is still valid: `confirm` raises `prompt_depth`, so no
            // teardown can run inside its modal loop (destroyPosted defers),
            // and nothing but destroyPosted destroys a surface window.
            self.closing = false;
            return;
        }

        self.postDestroy();
    }

    /// The ratio of this window's DPI to the Windows reference DPI of 96.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        const scale: f32 = @as(f32, @floatFromInt(self.dpi())) / 96.0;
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

        return 96;
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
    /// cursorPosCallback (src/Surface.zig:4573-4575) and are passed through
    /// unclamped.
    ///
    /// Cached rather than read live, because the core reads a button or
    /// wheel event's position back through here (e.g. src/Surface.zig:3634,
    /// :3892) after the live pointer may have moved on. After a leave, a
    /// live read would also give a point beyond the window, which the core
    /// clamps to an edge cell instead of treating as outside. The embedded
    /// runtime caches it the same way.
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
        // struct itself (src/apprt/structs.zig:161, :207) -- but the apprt does
        // NOT own that arena here, and destroying it would be a double free.
        //
        // The core destroys the request itself for every answer other than
        // `.started`: src/Surface.zig:6365 for reads and :6405 for writes are
        // both `defer req.destroy()`. Worse, the ENOSYS reply it builds reads
        // `req.id` and `req.terminator`, which live *in* that arena, after we
        // return. Ownership only transfers on `.started`, and then only to
        // completeClipboardRequest (Surface.zig:5946) or denyClipboardRequest
        // (:6068), which destroy it themselves.
        switch (state) {
            .kitty_read, .kitty_write => return .unsupported,

            // The core routes OSC 52 writes straight to setClipboard; they
            // never reach this function (src/Surface.zig:6144-6146).
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
                    L("Pasting this text could be unsafe. Paste anyway?"),
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
        )) return;

        const alloc = self.app.core_app.alloc;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
        defer alloc.free(wide);

        // The clipboard is a process-wide lock. Every exit path from here on
        // must release it, hence the defer immediately after opening.
        // Every failure from here on returns an error rather than `void`.
        // A bare `return` is this function reporting success, and the four
        // failures below all happen *after* EmptyClipboard has already wiped
        // the user's clipboard -- reporting success would mean the core
        // believes a copy landed while the clipboard is empty. Every call site
        // either catches or already returns an error union (Surface.zig:2218,
        // 2335, 5103, 5839, 5933, 6010), so this costs nothing.
        if (!win32.OpenClipboard(self.hwnd).toBool()) {
            log.warn("failed to open the clipboard for writing", .{});
            return App.Error.Win32CallFailed;
        }
        defer _ = win32.CloseClipboard();

        if (!win32.EmptyClipboard().toBool()) {
            log.warn("failed to empty the clipboard", .{});
            return App.Error.Win32CallFailed;
        }

        const bytes = (wide.len + 1) * @sizeOf(u16);
        const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse {
            log.warn("GlobalAlloc failed for {d} clipboard bytes", .{bytes});
            return App.Error.Win32CallFailed;
        };

        // Freed only on the failure paths below: SetClipboardData takes
        // ownership of the HGLOBAL on success, and freeing it then would be a
        // double free the moment anything pastes.
        var owned = true;
        defer if (owned) {
            _ = win32.GlobalFree(mem);
        };

        {
            const dst_raw = win32.GlobalLock(mem) orelse {
                log.warn("GlobalLock failed for the clipboard buffer", .{});
                return App.Error.Win32CallFailed;
            };
            defer _ = win32.GlobalUnlock(mem);

            const dst: [*]u16 = @ptrCast(@alignCast(dst_raw));
            @memcpy(dst[0..wide.len], wide);
            dst[wide.len] = 0;
        }

        if (win32.SetClipboardData(win32.CF_UNICODETEXT, mem) == null) {
            log.warn("SetClipboardData failed", .{});
            return App.Error.Win32CallFailed;
        }

        owned = false;
    }

    /// The environment the child process starts from. The caller takes
    /// ownership and then mutates it (src/Surface.zig:638-643).
    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        return try global.environMap();
    }

    // ---------------------------------------------------------------------
    // Win32 message handling
    // ---------------------------------------------------------------------

    /// Set the window title and remember it for `getTitle`. Returns false if
    /// the title could not be applied, which is what `.set_title` reports.
    fn setTitle(self: *Surface, title: [:0]const u8) bool {
        const alloc = self.app.core_app.alloc;

        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch |err| {
            log.warn("failed to encode the window title err={}", .{err});
            return false;
        };
        defer alloc.free(wide);

        if (!win32.SetWindowTextW(self.hwnd, wide.ptr).toBool()) {
            log.warn("SetWindowTextW failed", .{});
            return false;
        }

        // The stored copy is allocated last, after the final failure point,
        // and that ordering is the leak fix: this function returns `bool`, not
        // an error union, so an `errdefer` guarding an earlier allocation would
        // compile and simply never run. `.set_title` fires on every OSC 0/2, so
        // a leak here would be per title change.
        //
        // Failing here leaves the window text updated but `getTitle` stale
        // until the next set. That is strictly better than the alternative,
        // which is to leak on a path that repeats forever.
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
        // release builds (main_ghostty.zig:208). Without it a stale frame on
        // screen cannot be told apart from a repaint that never ran. The
        // present side (count, dropped stale frames) is logged by
        // src/renderer/D3D11.zig.
        self.paint_count += 1;
        const n = self.paint_count;
        const id = @intFromPtr(self.hwnd);

        // A paint can arrive from inside CreateWindowExW, before the core
        // surface exists; `create` shows the window only after it does.
        const core_surface = self.liveCore() orelse {
            log.debug("paint #{d} hwnd={x}: validated, no live core surface", .{ n, id });
            return;
        };

        // refreshCallback, never CoreSurface.draw: draw renders synchronously
        // on the calling thread (src/Surface.zig:883), and this thread must
        // not make GL calls. refreshCallback only wakes the render thread.
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
                // first (destroyPosted, App.terminate), so this is only
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

                // Minimized: report occluded and do NOT resize. A minimized
                // window reports a 0x0 client area, and the grid is clamped
                // to at least 1x1 (src/renderer/size.zig:260-261), so passing
                // it on would reflow every line to one column and back on
                // restore.
                if (wparam == win32.SIZE_MINIMIZED) {
                    core_surface.occlusionCallback(false) catch |err|
                        log.warn("occlusion callback failed err={}", .{err});
                    return 0;
                }

                // Every other WM_SIZE means visible. Sent unconditionally;
                // the core ignores repeats (src/Surface.zig:3344-3345).
                core_surface.occlusionCallback(true) catch |err|
                    log.warn("occlusion callback failed err={}", .{err});

                // Client size in physical pixels (PerMonitorV2). A zero
                // dimension can also occur without minimizing (a window
                // dragged to zero height); it would clamp the grid the same
                // way, so it is skipped too.
                const width = win32.loword(lparam);
                const height = win32.hiword(lparam);
                if (width == 0 or height == 0) return 0;

                core_surface.sizeCallback(.{
                    .width = width,
                    .height = height,
                }) catch |err| log.warn("size callback failed err={}", .{err});
                return 0;
            },

            win32.WM_DPICHANGED => {
                self.ime.form = null;
                // The new scale first: SetWindowPos below sends WM_SIZE
                // synchronously, so the core sees the scale before the size
                // computed for it. wParam carries the new DPI in both words;
                // they are always equal for a window.
                if (self.liveCore()) |core_surface| {
                    const scale = @as(f32, @floatFromInt(win32.hiword(wparam))) / 96.0;
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

                // A drag does not survive losing focus (Alt+Tab, a dialog,
                // the Start menu). The capture may outlive the focus change,
                // and the button-up then goes to another window. Releasing it
                // lets the next syncMouse send the core that release. Only a
                // Win32 call here: this message is sent, possibly from inside
                // a core frame (a paste confirmation taking focus).
                if (!self.focused and self.mouse.held.count() != 0 and self.hasCapture()) {
                    _ = win32.ReleaseCapture();
                }

                // An open composition does not survive it either, but
                // ending one makes the IME send its messages straight back
                // into this window procedure. That waits for `App.run`
                // (syncIme); the wakeup makes `run` come round, since a
                // sent message does not.
                if (!self.focused and (self.ime.composing or self.preedit == .ime)) {
                    _ = win32.PostMessageW(self.app.msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
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
                log.debug("ime setcontext active={} lang=0x{x}", .{ wparam != 0, inputLanguage() });
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
            // Logged to learn whether another IME disagrees.
            win32.WM_IME_CHAR, win32.WM_IME_REQUEST => {
                log.debug("ime message=0x{x} wparam=0x{x}", .{ msg, wparam });
            },

            win32.WM_KEYDOWN,
            win32.WM_SYSKEYDOWN,
            win32.WM_KEYUP,
            win32.WM_SYSKEYUP,
            => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);

                // IME-owned keystroke: the IME consumes it, not the terminal.
                // The core never sees that press, so if the key-up arrives
                // with the real virtual key it is withheld as well: a
                // release without a press would be reported to programs
                // that ask for key releases.
                const slot = Ime.scanSlot(lparam);
                if (wparam == win32.VK_PROCESSKEY) {
                    if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) self.ime.swallow_up.set(slot);
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }
                if (self.ime.swallow_up.isSet(slot)) {
                    self.ime.swallow_up.unset(slot);
                    if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP) {
                        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                    }
                }

                // The synthetic Left Ctrl of AltGr. The core still sees Ctrl
                // held (GetKeyState) and keyEvent's AltGr rule handles that.
                if (isAltGrFakeCtrl(wparam, lparam)) {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                const mods = currentMods();

                // Alt+Space (Alt alone) opens the window menu, as in every
                // Windows app. It must bypass the core entirely: DefWindowProcW
                // opens the menu from the WM_SYSCHAR ' ' that TranslateMessage
                // posted, so keyEvent must not remove that message either.
                if (wparam == win32.VK_SPACE and
                    mods.binding().equal(.{ .alt = true }))
                {
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
                // keydown produced. What arrives here was posted by someone
                // else (SendMessage/PostMessage from another program, or a
                // keydown the core surface did not exist for yet).

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

                // Arm leave tracking on entry, but not during a drag: the
                // pointer may be outside then, and arming there posts a
                // WM_MOUSELEAVE at once, on every move. The final release
                // arms it instead (mouseButton).
                if (!self.mouse.tracking and self.mouse.held.count() == 0) self.trackLeave();

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
                // core counts clicks itself.
                const is_x = msg == win32.WM_XBUTTONDOWN or msg == win32.WM_XBUTTONUP;
                return @intFromBool(is_x);
            },

            win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                if (!self.syncMouse(core_surface, Mouse.Button.downIn(wparam))) return 0;

                // The core reads the report position from getCursorPos. When
                // the pointer is over this client area, refresh the cache from
                // the message first: after a capture loss it says `outside`
                // until the next move, and reports there would be dropped.
                // Otherwise (the wheel routed by focus while the pointer is
                // elsewhere, or covered) the cache stays, `outside` after a
                // leave.
                if (self.wheelPoint(lparam)) |pos| {
                    if (!self.mouse.tracking and self.mouse.held.count() == 0) self.trackLeave();
                    self.movePointer(core_surface, pos, self.mouseMods(wparam));
                }

                const delta: i32 = win32.wheelDelta(wparam);
                if (msg == win32.WM_MOUSEWHEEL) {
                    // Positive is away from the user: the core's "up"
                    // (src/Surface.zig:3481).
                    if (self.mouse.wheel_y.add(delta)) |notches| {
                        core_surface.scrollCallback(0, @floatFromInt(notches), .{}) catch |err|
                            log.warn("scroll callback failed err={}", .{err});
                    }
                } else if (self.mouse.wheel_x.add(delta)) |notches| {
                    // Positive is to the right here. The core's positive x
                    // is reported as button 6, X11's scroll-left
                    // (src/Surface.zig:3641-3645), and GTK negates its
                    // rightward delta to match; so does this.
                    core_surface.scrollCallback(@floatFromInt(-notches), 0, .{}) catch |err|
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
    /// (App.run, waitForThreads). The core wants both in one event, so the
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
        const release = msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP;

        // lParam bit 30: the key was already down, i.e. autorepeat.
        const action: input.Action = if (release)
            .release
        else if ((@as(usize, @bitCast(lparam)) >> 30) & 1 != 0)
            .repeat
        else
            .press;

        // VK_PACKET is injected text (SendInput with KEYEVENTF_UNICODE: on-
        // screen keyboards, some remote-desktop clients). It is not a
        // physical key, and its lParam scan field is not guaranteed to be
        // zero, so it must not be matched against the keycode table, where
        // it could alias a real key and fire that key's bindings. Its text
        // still arrives through the WM_CHAR collected below.
        const is_packet = wparam == win32.VK_PACKET;

        const key: input.Key = if (is_packet) .unidentified else key: for (input.keycodes.entries) |entry| {
            if (entry.native == scan) break :key entry.key;
        } else .unidentified;

        var mods = mods_in;
        var text: Text = .{};
        if (!release) text.collect(self.hwnd);

        // Text the IME committed earlier comes first. This key's own text
        // is collected before the flush so that nothing the flush triggers
        // can dispatch the queued WM_CHAR out of turn.
        if (self.app.canReenterCore()) self.flushIme(core_surface);

        // AltGr. Windows reports AltGr as LCtrl+RAlt, and a Ctrl+Alt chord
        // that produces a character is AltGr by definition on Windows (it is
        // the documented substitute on keyboards without the key). Left in
        // place, the encoder would treat the character as a Ctrl sequence
        // (src/input/key_encode.zig:332, :450) and German AltGr+Q ('@') would
        // be sent as NUL (:814). Only characters that came through WM_CHAR
        // count: Alt without Ctrl produces WM_SYSCHAR, and Alt+letter must
        // keep its Alt so the encoder prefixes ESC.
        if (text.from_char and mods.ctrl and mods.alt and text.utf8().len > 0) {
            mods.ctrl = false;
            mods.alt = false;
        }

        const unshifted: u21 = if (is_packet) 0 else unshiftedCodepoint(vk, scan);

        // Win32 has no consumed-modifiers report. Shift is the only one that
        // can be inferred: it was consumed if it changed the character.
        var consumed: input.Mods = .{};
        if (mods.shift and text.len > 0) {
            var buf: [4]u8 = undefined;
            const n = if (unshifted != 0)
                std.unicode.utf8Encode(unshifted, &buf) catch 0
            else
                0;
            consumed.shift = !std.mem.eql(u8, buf[0..n], text.utf8());
        }

        // A dead key shows its accent as preedit until the next committed
        // text replaces it. The core does not track this itself
        // (src/Surface.zig:2565-2568).
        if (text.composing) {
            try self.setPreedit(core_surface, text.utf8(), .dead_key);
        } else if (self.preedit == .dead_key and text.len > 0) {
            try self.setPreedit(core_surface, null, .none);
        }

        return try core_surface.keyCallback(.{
            .action = action,
            .key = key,
            .mods = mods,
            .consumed_mods = consumed,
            .composing = text.composing,
            .utf8 = text.utf8(),
            .unshifted_codepoint = unshifted,
        });
    }

    /// Set or clear the core's preedit and record its owner, together.
    fn setPreedit(
        self: *Surface,
        core_surface: *CoreSurface,
        text: ?[]const u8,
        owner: Ime.Preedit,
    ) !void {
        std.debug.assert((text == null) == (owner == .none));

        // The core drops the old preedit before anything in it can fail
        // (src/Surface.zig:2593-2596), so a failure leaves none.
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
        log.debug("ime start lang=0x{x}", .{inputLanguage()});
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
        log.debug("ime composition gcs=0x{x} core_safe={}", .{ bits, core_safe });

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
            // The preedit shown is what this text replaces.
            if (self.preedit == .ime) {
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
        log.debug("ime commit bytes={d}", .{utf8.len});
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
        const units = alloc.alloc(u16, @intCast(@divExact(size, 2))) catch |err| {
            log.warn("ime string dropped err={}", .{err});
            return null;
        };
        defer alloc.free(units);

        const got = win32.ImmGetCompositionStringW(himc, index, units.ptr, @intCast(size));
        if (got <= 0) return null;
        const len: usize = @intCast(@divTrunc(@min(got, size), 2));

        const utf8 = Ime.utf8FromUtf16(alloc, units[0..len]) catch |err| {
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
        const scale: f64 = @as(f64, @floatFromInt(self.dpi())) / 96.0;
        const form = Ime.formFor(pos, scale, core_surface.size.cell.width, client);
        if (self.ime.form) |last| if (std.meta.eql(last, form)) return;
        self.ime.form = form;
        log.debug("ime place dpi={d} pos={d:.1},{d:.1} {d:.1}x{d:.1} rc={d},{d},{d},{d}", .{
            self.dpi(),   pos.x,       pos.y,         pos.width,      pos.height,
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
    /// drawn over the cursor of a window the user has left. Korean is
    /// completed, because a Hangul composition string is text the user
    /// already sees as typed, with no conversion step to confirm; other
    /// languages are cancelled, so that half-converted text does not reach
    /// a shell the user is no longer looking at. Nothing is done while one
    /// of this thread's own windows has the focus (a prompt): the user
    /// returns to the composition.
    fn syncIme(self: *Surface, core_surface: *CoreSurface) void {
        self.flushIme(core_surface);

        if (self.focused or win32.GetFocus() != null) return;
        if (!self.ime.composing and self.preedit != .ime) return;

        if (win32.ImmGetContext(self.hwnd)) |himc| {
            const how = if (inputLanguage() & 0x3FF == win32.LANG_KOREAN)
                win32.CPS_COMPLETE
            else
                win32.CPS_CANCEL;
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
        text.finish();
        if (text.len == 0) return;

        // Text the IME committed earlier comes first.
        if (self.app.canReenterCore()) self.flushIme(core_surface);

        if (text.composing) {
            self.setPreedit(core_surface, text.utf8(), .dead_key) catch |err|
                log.warn("preedit callback failed err={}", .{err});
        } else if (self.preedit == .dead_key) {
            self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err});
        }

        _ = core_surface.keyCallback(.{
            .action = .press,
            .key = .unidentified,
            .mods = currentMods(),
            .composing = text.composing,
            .utf8 = text.utf8(),
        }) catch |err| log.warn("key callback failed err={}", .{err});
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

        if (m.held.count() != 0) {
            const gone = if (!self.hasCapture())
                m.held
            else if (down) |d|
                m.held.differenceWith(d)
            else
                Mouse.Button.Set.empty;
            if (gone.count() != 0) {
                m.owed.setUnion(gone);
                m.held = m.held.differenceWith(gone);
                if (m.held.count() == 0 and self.hasCapture()) _ = win32.ReleaseCapture();
            }
        }
        if (m.owed.count() == 0 and !m.leave_owed) return true;

        if (m.owed.count() != 0) {
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
            m.pos = releasePoint(core_surface, m.left_press_pos);

            // The mods the core already has, so the release is judged like
            // the events before it: a Shift drag in a program with mouse
            // reporting stays a Ghostty selection (src/Surface.zig:3966).
            const mods = core_surface.mouse.mods;
            const owed = m.owed;
            m.owed = .empty;
            var it = owed.iterator();
            while (it.next()) |button| {
                _ = core_surface.mouseButtonCallback(.release, button.core(), mods) catch |err|
                    log.warn("mouse button callback failed err={}", .{err});
            }

            // With a button still held (only some were released), no leave:
            // a position outside would drag to an edge cell. The next
            // captured move supplies the real position.
            if (m.held.count() != 0) {
                m.pos = last;
                return true;
            }
        }

        // Then the leave. If the pointer is in fact over the window, the
        // next WM_MOUSEMOVE re-enters and re-arms tracking.
        m.pos = Mouse.outside;
        m.leave_owed = false;
        m.tracking = false;
        core_surface.cursorPosCallback(Mouse.outside, null) catch |err|
            log.warn("cursor pos callback failed err={}", .{err});
        return true;
    }

    /// The client position of a wheel message's screen point, if the pointer
    /// is over this window's client area and nothing covers it there.
    fn wheelPoint(self: *const Surface, lparam: win32.LPARAM) ?apprt.CursorPos {
        var pt: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
        const under = win32.WindowFromPoint(pt) orelse return null;
        if (under != self.hwnd) return null;
        if (!win32.ScreenToClient(self.hwnd, &pt).toBool()) return null;
        var rect: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &rect).toBool()) return null;
        if (pt.x < rect.left or pt.y < rect.top or pt.x >= rect.right or pt.y >= rect.bottom) {
            return null;
        }
        return .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) };
    }

    /// Give the core a real pointer position, unless it already has it.
    ///
    /// Repeats are dropped, as GTK drops sub-pixel moves: Win32 sends
    /// WM_MOUSEMOVE without movement when windows appear, disappear or move,
    /// and every cursorPosCallback shows a mouse hidden while typing
    /// (src/Surface.zig:4605).
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
                // a link (src/Surface.zig:3938).
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
        // or link under the pointer (src/Surface.zig:4124-4148).
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
    /// (src/Surface.zig:1661, from mouseRefreshLinks), so this must not call
    /// back into the core or run a message loop, and must not fail: an error
    /// would abort cursorPosCallback. It does neither.
    fn setMouseShape(self: *Surface, shape: terminal.MouseShape) bool {
        const m = &self.mouse;
        // Modifier keys resend the current shape on every key event
        // (src/Surface.zig:2804-2815).
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
    /// (src/Surface.zig:1554): lock and side bits would make every mouse
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
        fn collect(self: *Text, hwnd: win32.HWND) void {
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
            self.finish();
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
        /// (src/apprt/gtk/class/surface.zig:1428-1436): the encoder derives
        /// Ctrl+letter, Enter, Tab, Backspace and Esc from the physical key
        /// and the unshifted codepoint, and would double them otherwise.
        /// Unpaired surrogates are dropped rather than failing the keystroke.
        fn finish(self: *Text) void {
            self.len = 0;
            var it = std.unicode.Utf16LeIterator.init(self.units[0..self.units_len]);
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
/// (src/renderer/size.zig:142-147).
fn releasePoint(core_surface: *const CoreSurface, press: apprt.CursorPos) apprt.CursorPos {
    const screen = core_surface.size.screen;
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
    // (src/input/key_mods.zig:55-59). With both keys of a pair down, left is
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

/// The key's scan code in the form of the Windows column of
/// src/input/keycodes.zig: the 8-bit code from lParam bits 16-23, with 0xE0
/// in the high byte when lParam bit 24 (extended key) is set. Keys injected
/// without a scan code (lParam 0, e.g. some SendInput callers) fall back to
/// the layout's mapping of the virtual key.
fn scanCode(vk: win32.UINT, lparam: win32.LPARAM) u32 {
    const l: usize = @bitCast(lparam);
    var sc: u32 = @intCast((l >> 16) & 0xFF);
    if (sc == 0) return win32.MapVirtualKeyW(vk, win32.MAPVK_VK_TO_VSC_EX);
    if ((l >> 24) & 1 != 0) sc |= 0xE000;
    return sc;
}

/// The character the key produces with no modifiers in the current layout,
/// or 0. Used by the encoder for Ctrl/Alt sequences and by bindings.
///
/// TOUNICODE_NO_STATE_CHANGE keeps this query from consuming a pending dead
/// key; on Windows before 10 1607, which ignores the flag, a dead key
/// followed by another key can lose its accent.
fn unshiftedCodepoint(vk: win32.UINT, scan: u32) u21 {
    const empty_state = std.mem.zeroes([256]win32.BYTE);
    var buf: [4]win32.WCHAR = undefined;
    const n = win32.ToUnicodeEx(
        vk,
        // Only the low byte. ToUnicodeEx reads bit 15 of the scan code as
        // "key is up", and the 0xE0 extended prefix sets exactly that bit.
        scan & 0xFF,
        &empty_state,
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

    const ptr: [*:0]const u16 = @ptrCast(@alignCast(raw));
    return try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(ptr));
}

/// A modal yes/no prompt. This is the only confirmation UI this runtime has.
///
/// MessageBoxW runs a nested message loop. `prompt_depth` tells every
/// handler dispatched inside it that a core frame is probably beneath: no
/// ticks and no surface teardown until it returns (`App.canReenterCore`).
/// Output from every surface pauses while a prompt is open.
fn confirm(app: *App, hwnd: win32.HWND, text: win32.LPCWSTR) bool {
    app.prompt_depth += 1;
    defer app.prompt_depth -= 1;
    return win32.MessageBoxW(
        hwnd,
        text,
        L("Ghostty"),
        win32.MB_OKCANCEL | win32.MB_ICONWARNING,
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
fn fatalNotice(alloc: Allocator, err: anyerror) void {
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
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return;
    defer alloc.free(wide);
    _ = win32.MessageBoxW(null, wide.ptr, L("Ghostty"), win32.MB_OK | win32.MB_ICONERROR);
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
        // click_state (src/Surface.zig:226, :3838); input.MouseButton.eleven
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
            var total: i32 = 0;
            for (deltas) |d| total += n.add(sign * d) orelse 0;
            try std.testing.expectEqual(3 * sign, total);
            try std.testing.expectEqual(0, n.rem);
        }
    }

    // A reversal is not absorbed by the other direction's remainder.
    var n: Surface.Mouse.Notches = .{};
    try std.testing.expectEqual(null, n.add(60));
    try std.testing.expectEqual(-1, n.add(-120));
}

test "win32: mouse message button bits" {
    const Set = Surface.Mouse.Button.Set;
    try std.testing.expect(Surface.Mouse.Button.downIn(0).eql(Set.empty));
    const both = Surface.Mouse.Button.downIn(win32.MK_LBUTTON | win32.MK_XBUTTON2 | win32.MK_SHIFT);
    try std.testing.expect(both.eql(Set.initMany(&.{ .left, .x2 })));
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
    const cursor_pos: u32 = 0x0080; // GCS_CURSORPOS
    const attr_clause: u32 = 0x0030; // GCS_COMPATTR | GCS_COMPCLAUSE
    const result_clause: u32 = 0x1000; // GCS_RESULTCLAUSE

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

test "win32: ime strings become UTF-8 without unpaired surrogates" {
    const alloc = std.testing.allocator;
    const Case = struct { units: []const u16, want: []const u8 };
    const cases = [_]Case{
        .{ .units = &.{}, .want = "" },
        .{ .units = &.{ 0x65E5, 0x672C }, .want = "\u{65E5}\u{672C}" },
        .{ .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}" },
        // A control character is kept: only what has no UTF-8 form is dropped.
        .{ .units = &.{ 'a', 0x000A, 'b' }, .want = "a\nb" },
        .{ .units = &.{ 'a', 0xD83D }, .want = "a" },
        .{ .units = &.{ 0xDE00, 'a' }, .want = "a" },
        .{ .units = &.{ 0xD83D, 'a', 0xDE00 }, .want = "a" },
        .{ .units = &.{ 0xD83D, 0xD83D, 0xDE00 }, .want = "\u{1F600}" },
    };
    for (cases) |c| {
        const got = try Surface.Ime.utf8FromUtf16(alloc, c.units);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
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
