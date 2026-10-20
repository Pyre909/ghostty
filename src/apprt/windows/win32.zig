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

const std = @import("std");

const internal_os = @import("../../os/main.zig");

const win32 = @This();

const w = std.os.windows;

const BOOL = w.BOOL;
pub const BYTE = w.BYTE;
pub const DWORD = w.DWORD;
const HRESULT = internal_os.windows.HRESULT;
pub const UINT = w.UINT;
pub const LONG = w.LONG;
pub const WCHAR = w.WCHAR;
pub const LPCWSTR = w.LPCWSTR;
pub const HANDLE = w.HANDLE;
pub const HWND = w.HWND;
const HDC = w.HDC;
pub const HINSTANCE = w.HINSTANCE;
pub const HMODULE = w.HMODULE;
const HICON = w.HICON;
pub const HCURSOR = w.HCURSOR;
const HBRUSH = w.HBRUSH;
const HMENU = w.HMENU;
const ATOM = w.ATOM;

pub const LPARAM = w.LPARAM;
const LONG_PTR = w.LONG_PTR;

/// Not in std: WPARAM, LRESULT, UINT_PTR and HGLOBAL. WPARAM and
/// LRESULT are pointer-sized like LPARAM, unsigned for WPARAM and
/// signed for LRESULT.
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const UINT_PTR = usize;
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

pub const POINT = extern struct { x: LONG, y: LONG };
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};
pub const RECT = internal_os.windows.RECT;

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const WNDCLASSEXW = extern struct {
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

pub const CREATESTRUCTW = extern struct {
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

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_MINIMIZE: DWORD = 0x20000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOWNORMAL: c_int = 1;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_RESTORE: c_int = 9;

/// Parent value that makes CreateWindowExW produce a message-only window:
/// no pixels, not enumerated, but a valid PostMessage and SetTimer target.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. Passed as an opaque handle
/// whose value is a small negative integer.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

pub const GWLP_USERDATA: c_int = -21;

pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_MOUSEACTIVATE: UINT = 0x0021;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_NCDESTROY: UINT = 0x0082;
pub const WM_KEYFIRST: UINT = 0x0100;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_DEADCHAR: UINT = 0x0103;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_SYSDEADCHAR: UINT = 0x0107;
/// Windows XP and later; 0x0108 before WM_UNICHAR (0x0109) existed.
pub const WM_KEYLAST: UINT = 0x0109;
pub const WM_SYSCOMMAND: UINT = 0x0112;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_ENTERMENULOOP: UINT = 0x0211;
pub const WM_EXITMENULOOP: UINT = 0x0212;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
pub const WM_MOUSELEAVE: UINT = 0x02A3;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_APP: UINT = 0x8000;

pub const PM_NOREMOVE: UINT = 0x0000;
pub const PM_REMOVE: UINT = 0x0001;

/// WM_SIZE wParam.
pub const SIZE_MINIMIZED: WPARAM = 1;

/// Mouse message wParam (the low word for the wheel and X-button
/// messages): the buttons down and the Shift/Ctrl state at the time of
/// the event. There is no Alt or Windows-key flag. The button bits
/// follow the left/right swap setting, as the button messages do.
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_SHIFT: WPARAM = 0x0004;
pub const MK_CONTROL: WPARAM = 0x0008;
pub const MK_MBUTTON: WPARAM = 0x0010;
pub const MK_XBUTTON1: WPARAM = 0x0020;
pub const MK_XBUTTON2: WPARAM = 0x0040;
/// WM_XBUTTON* wParam high word (GET_XBUTTON_WPARAM).
pub const XBUTTON1: u16 = 0x0001;
pub const XBUTTON2: u16 = 0x0002;
/// One wheel notch. High-resolution wheels send fractions of it.
pub const WHEEL_DELTA: i32 = 120;
/// SystemParametersInfoW: lines (vertical) and characters (horizontal)
/// to scroll per notch, both 3 by default. Lines can instead be
/// WHEEL_PAGESCROLL, "one screen at a time".
pub const SPI_GETWHEELSCROLLLINES: UINT = 0x0068;
pub const SPI_GETWHEELSCROLLCHARS: UINT = 0x006C;
pub const WHEEL_PAGESCROLL: UINT = std.math.maxInt(UINT);
pub const TME_LEAVE: DWORD = 0x00000002;
/// The client-area hit-test code (WM_NCHITTEST), which is the low word
/// of WM_MOUSEACTIVATE's and WM_SETCURSOR's lParam.
pub const HTCLIENT: u16 = 1;
/// WM_MOUSEACTIVATE: activate the window and pass the mouse message on.
pub const MA_ACTIVATE: LRESULT = 1;
/// WM_MOUSEACTIVATE: activate the window and discard the mouse message.
pub const MA_ACTIVATEANDEAT: LRESULT = 2;

/// WM_SYSCOMMAND wParam (low four bits are reserved and must be masked).
pub const SC_KEYMENU: WPARAM = 0xF100;

// Virtual-key codes.
pub const VK_SPACE: WPARAM = 0x20;
pub const VK_PROCESSKEY: WPARAM = 0xE5;
pub const VK_PACKET: WPARAM = 0xE7;
pub const VK_CONTROL: WPARAM = 0x11;
pub const VK_MENU: WPARAM = 0x12;
pub const VK_NUMPAD0: UINT = 0x60;
pub const VK_NUMPAD9: UINT = 0x69;
pub const VK_DECIMAL: UINT = 0x6E;
pub const VK_SHIFT: c_int = 0x10;
pub const VK_CAPITAL: c_int = 0x14;
pub const VK_NUMLOCK: c_int = 0x90;
pub const VK_LWIN: c_int = 0x5B;
pub const VK_RWIN: c_int = 0x5C;
pub const VK_LSHIFT: c_int = 0xA0;
pub const VK_RSHIFT: c_int = 0xA1;
pub const VK_LCONTROL: c_int = 0xA2;
pub const VK_RCONTROL: c_int = 0xA3;
pub const VK_LMENU: c_int = 0xA4;
pub const VK_RMENU: c_int = 0xA5;

/// MapVirtualKeyW mode: VK -> scan code, with the 0xE0/0xE1 prefix
/// in the high byte for extended keys.
pub const MAPVK_VK_TO_VSC_EX: UINT = 4;

/// ToUnicodeEx flag: do not change the keyboard state, in particular
/// the pending dead key. Honored from Windows 10 1607.
pub const TOUNICODE_NO_STATE_CHANGE: UINT = 0x4;

// MsgWaitForMultipleObjectsEx. Since Windows 8, winuser.h includes
// QS_TOUCH and QS_POINTER in QS_INPUT (0x04FF is the older value);
// without them pen and touch input does not end the wait.
const QS_TOUCH: DWORD = 0x0800;
const QS_POINTER: DWORD = 0x1000;
pub const QS_ALLINPUT: DWORD = 0x04FF | QS_TOUCH | QS_POINTER;
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;

pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;

/// A resource name that may be an integer id (MAKEINTRESOURCEW): the
/// same pointer as LPCWSTR, but without its alignment, since the ids are
/// odd as often as even. An LPCWSTR still coerces to it.
pub const ResourceW = [*:0]align(1) const u16;
pub const IDC_ARROW: ResourceW = @ptrFromInt(32512);
pub const IDC_IBEAM: ResourceW = @ptrFromInt(32513);
pub const IDC_WAIT: ResourceW = @ptrFromInt(32514);
pub const IDC_CROSS: ResourceW = @ptrFromInt(32515);
pub const IDC_SIZENWSE: ResourceW = @ptrFromInt(32642);
pub const IDC_SIZENESW: ResourceW = @ptrFromInt(32643);
pub const IDC_SIZEWE: ResourceW = @ptrFromInt(32644);
pub const IDC_SIZENS: ResourceW = @ptrFromInt(32645);
pub const IDC_SIZEALL: ResourceW = @ptrFromInt(32646);
pub const IDC_NO: ResourceW = @ptrFromInt(32648);
pub const IDC_HAND: ResourceW = @ptrFromInt(32649);
pub const IDC_APPSTARTING: ResourceW = @ptrFromInt(32650);
pub const IDC_HELP: ResourceW = @ptrFromInt(32651);

pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const CP_UTF8: UINT = 65001;

pub const MB_OK: UINT = 0x00000000;
pub const MB_OKCANCEL: UINT = 0x00000001;
pub const MB_ICONWARNING: UINT = 0x00000030;
pub const MB_ICONERROR: UINT = 0x00000010;
pub const MB_DEFBUTTON1: UINT = 0x00000000;
pub const MB_DEFBUTTON2: UINT = 0x00000100;
pub const MB_DEFMASK: UINT = 0x00000F00;
pub const IDOK: c_int = 1;

pub const MB_ICONASTERISK: UINT = 0x00000040;

/// GetDeviceCaps index for horizontal DPI. Used as the pre-1607 fallback
/// for GetDpiForWindow, where it is the correct answer: those versions
/// have no per-monitor DPI at all.
pub const LOGPIXELSX: c_int = 88;
/// The reference DPI: a scale of 1.
pub const USER_DEFAULT_SCREEN_DPI: UINT = 96;

// Entry points that must NOT be statically imported.
//
// SetProcessDpiAwarenessContext is a user32 export only from Windows 10
// 1703, and GetDpiForWindow only from 1607. Declaring either as
// `extern "user32"` puts it in the PE import table, and the loader then
// fails the whole process with STATUS_ENTRY_POINT_NOT_FOUND *before* main
// runs -- there is no FALSE return to observe and no fallback to take.
// They are resolved with GetProcAddress in App.init instead.
pub const SetProcessDpiAwarenessContextFn = *const fn (
    ctx: HANDLE,
) callconv(.winapi) BOOL;
pub const GetDpiForWindowFn = *const fn (hwnd: HWND) callconv(.winapi) UINT;
pub const GetThreadDpiAwarenessContextFn = *const fn () callconv(.winapi) ?HANDLE;
pub const AreDpiAwarenessContextsEqualFn = *const fn (a: HANDLE, b: HANDLE) callconv(.winapi) BOOL;

pub const GetLastError = internal_os.windows.GetLastError;
pub const GetModuleHandleW = internal_os.windows.exp.kernel32.GetModuleHandleW;
pub const GetProcAddress = internal_os.windows.exp.kernel32.GetProcAddress;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-globalsize
pub extern "kernel32" fn GlobalSize(mem: HGLOBAL) callconv(.winapi) usize;
/// https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar
pub extern "kernel32" fn MultiByteToWideChar(
    code_page: UINT,
    flags: DWORD,
    src: [*]const u8,
    src_len: c_int,
    dst: ?[*]u16,
    dst_len: c_int,
) callconv(.winapi) c_int;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(name: LPCWSTR, inst: ?HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
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
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(
    msg: *MSG,
    hwnd: ?HWND,
    min: UINT,
    max: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(
    msg: *MSG,
    hwnd: ?HWND,
    min: UINT,
    max: UINT,
    remove: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageTime() callconv(.winapi) LONG;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(
    hwnd: ?HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
/// user32 exports the LONG_PTR forms only on 64-bit Windows. On 32-bit,
/// winuser.h defines them as the LONG forms, which have the same
/// signature there because LONG_PTR is LONG.
pub const SetWindowLongPtrW = if (@sizeOf(LONG_PTR) == 8)
    window_long.SetWindowLongPtrW
else
    window_long.SetWindowLongW;
pub const GetWindowLongPtrW = if (@sizeOf(LONG_PTR) == 8)
    window_long.GetWindowLongPtrW
else
    window_long.GetWindowLongW;
const window_long = struct {
    extern "user32" fn SetWindowLongPtrW(
        hwnd: HWND,
        index: c_int,
        value: LONG_PTR,
    ) callconv(.winapi) LONG_PTR;
    extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) LONG_PTR;
    extern "user32" fn SetWindowLongW(hwnd: HWND, index: c_int, value: LONG) callconv(.winapi) LONG;
    extern "user32" fn GetWindowLongW(hwnd: HWND, index: c_int) callconv(.winapi) LONG;
};
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
pub const GetClientRect = internal_os.windows.exp.user32.GetClientRect;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setfocus
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getactivewindow
pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getancestor
pub extern "user32" fn GetAncestor(hwnd: HWND, flags: UINT) callconv(.winapi) ?HWND;
pub const GA_ROOT: UINT = 2;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
pub extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn WindowFromPoint(pt: POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SystemParametersInfoW(
    action: UINT,
    param: UINT,
    value: ?*anyopaque,
    win_ini: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    after: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: ResourceW) callconv(.winapi) ?HCURSOR;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadiconw
pub extern "user32" fn LoadIconW(inst: ?HINSTANCE, name: ResourceW) callconv(.winapi) ?HICON;
/// Returns an HINSTANCE in name only: a value of 32 or below is an
/// SE_ERR_* code (0 means out of memory), so it is read as an integer.
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    operation: ?LPCWSTR,
    file: LPCWSTR,
    parameters: ?LPCWSTR,
    directory: ?LPCWSTR,
    show: c_int,
) callconv(.winapi) usize;
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

// IMM32. Both forms are in client coordinates of the context's window.
pub const HIMC = *opaque {};
pub const COMPOSITIONFORM = extern struct { dwStyle: DWORD, ptCurrentPos: POINT, rcArea: RECT };
pub const CANDIDATEFORM = extern struct { dwIndex: DWORD, dwStyle: DWORD, ptCurrentPos: POINT, rcArea: RECT };
pub const WM_INPUTLANGCHANGE: UINT = 0x0051;
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;
pub const WM_IME_SETCONTEXT: UINT = 0x0281;
pub const WM_IME_CHAR: UINT = 0x0286;
pub const WM_IME_REQUEST: UINT = 0x0288;
pub const ISC_SHOWUICOMPOSITIONWINDOW: usize = 0x80000000;
const GCS_COMPREADSTR: u32 = 0x0001;
const GCS_COMPREADATTR: u32 = 0x0002;
const GCS_COMPREADCLAUSE: u32 = 0x0004;
pub const GCS_COMPSTR: u32 = 0x0008;
pub const GCS_COMPATTR: u32 = 0x0010;
pub const GCS_COMPCLAUSE: u32 = 0x0020;
pub const GCS_CURSORPOS: u32 = 0x0080;
const GCS_DELTASTART: u32 = 0x0100;
const GCS_RESULTREADSTR: u32 = 0x0200;
const GCS_RESULTREADCLAUSE: u32 = 0x0400;
pub const GCS_RESULTSTR: u32 = 0x0800;
pub const GCS_RESULTCLAUSE: u32 = 0x1000;
/// Every GCS_* flag. A WM_IME_COMPOSITION with none of them set means
/// the composition was cancelled.
pub const GCS_ALL: u32 = GCS_COMPREADSTR | GCS_COMPREADATTR |
    GCS_COMPREADCLAUSE | GCS_COMPSTR | GCS_COMPATTR | GCS_COMPCLAUSE |
    GCS_CURSORPOS | GCS_DELTASTART | GCS_RESULTREADSTR |
    GCS_RESULTREADCLAUSE | GCS_RESULTSTR | GCS_RESULTCLAUSE;
pub const CFS_POINT: DWORD = 0x0002;
pub const CFS_EXCLUDE: DWORD = 0x0080;
pub const NI_COMPOSITIONSTR: DWORD = 0x0015;
pub const CPS_COMPLETE: DWORD = 0x0001;
pub const CPS_CANCEL: DWORD = 0x0004;
pub const LANG_KOREAN = w.LANG.KOREAN;

/// PRIMARYLANGID (winnt.h): a LANGID without its sublanguage.
pub fn primaryLangId(lgid: u16) u16 {
    return lgid & 0x3FF;
}

pub extern "imm32" fn ImmGetContext(hwnd: HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hwnd: HWND, himc: HIMC) callconv(.winapi) BOOL;
/// Sizes are in bytes, also for the W form; negative is an error.
pub extern "imm32" fn ImmGetCompositionStringW(
    himc: HIMC,
    index: DWORD,
    buf: ?*anyopaque,
    len: DWORD,
) callconv(.winapi) LONG;
pub extern "imm32" fn ImmSetCompositionWindow(himc: HIMC, form: *COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(himc: HIMC, form: *CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmNotifyIME(himc: HIMC, action: DWORD, index: DWORD, value: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-isiconic
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iswindow
pub extern "user32" fn IsWindow(hwnd: HWND) callconv(.winapi) BOOL;
/// Returns whether the window was disabled *before* the call.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enablewindow
pub extern "user32" fn EnableWindow(hwnd: HWND, enable: BOOL) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iswindowenabled
pub extern "user32" fn IsWindowEnabled(hwnd: HWND) callconv(.winapi) BOOL;

const HMONITOR = *opaque {};
pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-monitorinfo
pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-monitorfromwindow
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: DWORD) callconv(.winapi) ?HMONITOR;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmonitorinfow
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(hwnd: ?HWND, rect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) c_int;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    count: DWORD,
    handles: ?[*]const HANDLE,
    timeout_ms: DWORD,
    wake_mask: DWORD,
    flags: DWORD,
) callconv(.winapi) DWORD;
pub extern "user32" fn GetKeyState(vk: c_int) callconv(.winapi) SHORT;
pub extern "user32" fn GetKeyboardState(key_state: *[256]BYTE) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(code: UINT, map_type: UINT) callconv(.winapi) UINT;
pub extern "user32" fn GetKeyboardLayout(thread_id: DWORD) callconv(.winapi) ?HKL;
pub extern "user32" fn ToUnicodeEx(
    vk: UINT,
    scan_code: UINT,
    key_state: *const [256]BYTE,
    buf: [*]WCHAR,
    buf_len: c_int,
    flags: UINT,
    layout: ?HKL,
) callconv(.winapi) c_int;
pub extern "user32" fn SetTimer(
    hwnd: ?HWND,
    id: UINT_PTR,
    elapse_ms: UINT,
    proc: ?*const anyopaque,
) callconv(.winapi) UINT_PTR;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: UINT_PTR) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn MessageBeep(type_: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(
    hwnd: ?HWND,
    text: LPCWSTR,
    caption: LPCWSTR,
    type_: UINT,
) callconv(.winapi) c_int;
pub extern "user32" fn OpenClipboard(hwnd: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(format: UINT, mem: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;

pub extern "gdi32" fn GetDeviceCaps(hdc: HDC, index: c_int) callconv(.winapi) c_int;

pub fn loword(v: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(v)));
}

pub fn hiword(v: anytype) u16 {
    return @truncate(@as(usize, @bitCast(v)) >> 16);
}

/// GET_X_LPARAM / GET_Y_LPARAM (windowsx.h). Signed: while the mouse is
/// captured, positions above or left of the client area are negative,
/// which loword/hiword would turn into values near 65535.
pub fn xLparam(v: LPARAM) i16 {
    return @bitCast(loword(v));
}

pub fn yLparam(v: LPARAM) i16 {
    return @bitCast(hiword(v));
}

/// GET_WHEEL_DELTA_WPARAM: the signed high word.
pub fn wheelDelta(v: WPARAM) i16 {
    return @bitCast(hiword(v));
}

/// UTF-16 string literal helper for the many `LPCWSTR` constants in this runtime.
pub fn L(comptime s: []const u8) win32.LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "win32: wheel deltas are the signed high word" {
    // One notch toward the user is -120 (0xFF88), here with MK_CONTROL in
    // the low word.
    try std.testing.expectEqual(-120, win32.wheelDelta(0xFF88_0008));
    try std.testing.expectEqual(120, win32.wheelDelta(0x0078_0000));
}
