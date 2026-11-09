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
const log = std.log.scoped(.win32);

const w = std.os.windows;

pub const BOOL = w.BOOL;
pub const BYTE = w.BYTE;
pub const DWORD = w.DWORD;
pub const WORD = w.WORD;
pub const HRESULT = internal_os.windows.HRESULT;
pub const UINT = w.UINT;
pub const LONG = w.LONG;
pub const WCHAR = w.WCHAR;
pub const LPCWSTR = w.LPCWSTR;
pub const HANDLE = w.HANDLE;
pub const HWND = w.HWND;
pub const HDC = w.HDC;
pub const HINSTANCE = w.HINSTANCE;
pub const HMODULE = w.HMODULE;
pub const HICON = w.HICON;
pub const HCURSOR = w.HCURSOR;
pub const HBRUSH = w.HBRUSH;
pub const HMENU = w.HMENU;
const ATOM = w.ATOM;

pub const LPARAM = w.LPARAM;
const LONG_PTR = w.LONG_PTR;

/// Not in std: WPARAM, LRESULT, UINT_PTR and HGLOBAL. WPARAM and
/// LRESULT are pointer-sized like LPARAM, unsigned for WPARAM and
/// signed for LRESULT.
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const UINT_PTR = usize;
pub const HGLOBAL = *anyopaque;
const SHORT = w.SHORT;

/// Keyboard layout handle. Only ever passed back to user32.
const HKL = *opaque {};

pub const WNDPROC = *const fn (
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: LONG, y: LONG };
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-windowpos
pub const WINDOWPOS = extern struct {
    hwnd: ?HWND,
    hwndInsertAfter: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-minmaxinfo
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    /// Null in TME_QUERY's answer when nothing is tracked.
    hwndTrack: ?HWND,
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
/// WNDCLASSEXW.style: the class's windows get a double-click message in
/// place of the second press of a quick second click, for every button:
/// WM_LBUTTONDBLCLK, WM_MBUTTONDBLCLK, WM_RBUTTONDBLCLK, WM_XBUTTONDBLCLK.
pub const CS_DBLCLKS: UINT = 0x0008;
/// WNDCLASSEXW.style: a change of the window's width (CS_HREDRAW) or
/// height (CS_VREDRAW) invalidates all of its client area.
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;

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
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZE: DWORD = 0x20000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const SW_HIDE: c_int = 0;
pub const SW_SHOWNORMAL: c_int = 1;
pub const SW_SHOWNOACTIVATE: c_int = 4;
pub const SW_SHOWMINNOACTIVE: c_int = 7;
pub const SW_SHOWNA: c_int = 8;
pub const SW_MAXIMIZE: c_int = 3;
/// SW_MAXIMIZE's other name, the one WINDOWPLACEMENT.showCmd reports.
pub const SW_SHOWMAXIMIZED: c_int = 3;
pub const SW_RESTORE: c_int = 9;

/// Parent value that makes CreateWindowExW produce a message-only window:
/// no pixels, not enumerated, but a valid PostMessage and SetTimer target.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. Passed as an opaque handle
/// whose value is a small negative integer.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

pub const GWL_STYLE: c_int = -16;
pub const GWL_EXSTYLE: c_int = -20;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
/// The window takes files dropped on it (WM_DROPFILES), as
/// DragAcceptFiles sets.
pub const WS_EX_ACCEPTFILES: DWORD = 0x00000010;
/// Not in the taskbar or in the Alt+Tab switcher.
/// https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
/// A layered window, which SetLayeredWindowAttributes can make
/// translucent.
/// https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles
pub const WS_EX_LAYERED: DWORD = 0x00080000;
/// SetLayeredWindowAttributes: the alpha applies.
pub const LWA_ALPHA: DWORD = 0x00000002;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setlayeredwindowattributes
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: COLORREF, alpha: BYTE, flags: DWORD) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getlayeredwindowattributes
pub extern "user32" fn GetLayeredWindowAttributes(hwnd: HWND, key: ?*COLORREF, alpha: ?*BYTE, flags: ?*DWORD) callconv(.winapi) BOOL;
/// SetWindowPos's place for a window above every window that is not on
/// top, and back among them.
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
pub const GWLP_USERDATA: c_int = -21;

/// No message: a window procedure does nothing with it.
pub const WM_NULL: UINT = 0x0000;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
/// Sent to top-level windows, never to message-only ones; nonzero lets
/// the session end.
pub const WM_QUERYENDSESSION: UINT = 0x0011;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_ERASEBKGND: UINT = 0x0014;
/// Sent to top-level windows, never to message-only ones; wParam is
/// nonzero when the session ends, which it may any time after the last
/// window has returned.
pub const WM_ENDSESSION: UINT = 0x0016;
/// Sent to top-level windows, never to message-only ones.
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_MOUSEACTIVATE: UINT = 0x0021;
/// lParam is the MINMAXINFO, filled with Windows' own sizes, which the
/// handler may change in place.
pub const WM_GETMINMAXINFO: UINT = 0x0024;
/// lParam is the WINDOWPOS about to be applied, which the handler may
/// change in place.
pub const WM_WINDOWPOSCHANGING: UINT = 0x0046;
/// lParam is the WINDOWPOS that was applied.
pub const WM_WINDOWPOSCHANGED: UINT = 0x0047;
/// Sent to top-level windows "when the display resolution has changed"
/// (Learn, WM_DISPLAYCHANGE).
pub const WM_DISPLAYCHANGE: UINT = 0x007E;
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
/// The range of the client area's mouse messages, WM_MOUSEMOVE to
/// WM_MOUSEHWHEEL.
pub const WM_MOUSEFIRST: UINT = 0x0200;
pub const WM_MOUSELAST: UINT = 0x020E;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
/// Only for a window whose class has CS_DBLCLKS: the second press of a
/// double click, in place of its WM_LBUTTONDOWN.
pub const WM_LBUTTONDBLCLK: UINT = 0x0203;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
/// As WM_LBUTTONDBLCLK, for the right button.
pub const WM_RBUTTONDBLCLK: UINT = 0x0206;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
/// As WM_LBUTTONDBLCLK, for the middle button.
pub const WM_MBUTTONDBLCLK: UINT = 0x0209;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
/// As WM_LBUTTONDBLCLK, for an X button.
pub const WM_XBUTTONDBLCLK: UINT = 0x020D;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_ENTERMENULOOP: UINT = 0x0211;
pub const WM_EXITMENULOOP: UINT = 0x0212;
/// Sent to the window losing the mouse capture, whatever took it.
pub const WM_CAPTURECHANGED: UINT = 0x0215;
pub const WM_ENTERSIZEMOVE: UINT = 0x0231;
pub const WM_EXITSIZEMOVE: UINT = 0x0232;
/// wParam is the drop's HDROP, which the window frees with DragFinish.
pub const WM_DROPFILES: UINT = 0x0233;
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
/// SystemParametersInfoW: read the fonts and sizes of the non-client
/// area (NONCLIENTMETRICSW), at the system DPI; WM_SETTINGCHANGE's wParam
/// once they change.
pub const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;
pub const SPI_SETNONCLIENTMETRICS: UINT = 0x002A;
/// WM_SETTINGCHANGE's wParam once a work area changes, as when the
/// taskbar moves.
pub const SPI_SETWORKAREA: UINT = 0x002F;
pub const TME_LEAVE: DWORD = 0x00000002;
/// TrackMouseEvent: fill the structure with what is tracked now.
pub const TME_QUERY: DWORD = 0x40000000;
/// The client-area hit-test code (WM_NCHITTEST), which is the low word
/// of WM_MOUSEACTIVATE's and WM_SETCURSOR's lParam.
pub const HTCLIENT: u16 = 1;
/// WM_MOUSEACTIVATE: activate the window and pass the mouse message on.
pub const MA_ACTIVATE: LRESULT = 1;
/// WM_MOUSEACTIVATE: activate the window and discard the mouse message.
pub const MA_ACTIVATEANDEAT: LRESULT = 2;
/// WM_MOUSEACTIVATE: leave the activation as it is, and pass the mouse
/// message on.
pub const MA_NOACTIVATE: LRESULT = 3;

/// WM_SYSCOMMAND wParam (low four bits are reserved and must be masked).
/// WM_SYSCOMMAND: the system uses wParam's low four bits internally; mask
/// them before comparing.
pub const SC_MASK: WPARAM = 0xFFF0;
pub const SC_MAXIMIZE: WPARAM = 0xF030;
pub const SC_KEYMENU: WPARAM = 0xF100;
pub const SC_RESTORE: WPARAM = 0xF120;

// Virtual-key codes.
pub const VK_SPACE: WPARAM = 0x20;
pub const VK_PROCESSKEY: WPARAM = 0xE5;
pub const VK_PACKET: WPARAM = 0xE7;
pub const VK_CONTROL: WPARAM = 0x11;
/// What the layout makes of Pause with Ctrl held: Break.
pub const VK_CANCEL: UINT = 0x03;
pub const VK_PAUSE: UINT = 0x13;
pub const VK_F12: UINT = 0x7B;
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

/// MapVirtualKeyExW mode: scan code, with the 0xE0/0xE1 prefix in the
/// high byte for extended keys, -> VK, telling left and right apart.
pub const MAPVK_VSC_TO_VK_EX: UINT = 3;

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

pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const SWP_HIDEWINDOW: UINT = 0x0080;
pub const SWP_NOOWNERZORDER: UINT = 0x0200;

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
/// https://learn.microsoft.com/en-us/windows/win32/dataxchg/standard-clipboard-formats
pub const CF_DIB: UINT = 8;
pub const CF_DIBV5: UINT = 17;
/// A file list, as a drop's HDROP is (DragQueryFileW).
pub const CF_HDROP: UINT = 15;
pub const GMEM_MOVEABLE: UINT = 0x0002;

/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapv5header
pub const BITMAPV5HEADER = extern struct {
    bV5Size: DWORD,
    bV5Width: LONG,
    bV5Height: LONG,
    bV5Planes: WORD,
    bV5BitCount: WORD,
    bV5Compression: DWORD,
    bV5SizeImage: DWORD,
    bV5XPelsPerMeter: LONG,
    bV5YPelsPerMeter: LONG,
    bV5ClrUsed: DWORD,
    bV5ClrImportant: DWORD,
    bV5RedMask: DWORD,
    bV5GreenMask: DWORD,
    bV5BlueMask: DWORD,
    bV5AlphaMask: DWORD,
    bV5CSType: DWORD,
    /// CIEXYZTRIPLE: three CIEXYZ of three FXPT2DOT30 each.
    bV5Endpoints: [9]LONG,
    bV5GammaRed: DWORD,
    bV5GammaGreen: DWORD,
    bV5GammaBlue: DWORD,
    bV5Intent: DWORD,
    bV5ProfileData: DWORD,
    bV5ProfileSize: DWORD,
    bV5Reserved: DWORD,
};
comptime {
    // The SDK's size and the offsets of the fields after the endpoints,
    // which a wrong CIEXYZTRIPLE would move.
    std.debug.assert(@sizeOf(BITMAPV5HEADER) == 124);
    std.debug.assert(@offsetOf(BITMAPV5HEADER, "bV5AlphaMask") == 52);
    std.debug.assert(@offsetOf(BITMAPV5HEADER, "bV5GammaRed") == 96);
    std.debug.assert(@offsetOf(BITMAPV5HEADER, "bV5Intent") == 108);
}
/// biCompression values (wingdi.h).
pub const BI_RGB: DWORD = 0;
pub const BI_RLE8: DWORD = 1;
pub const BI_RLE4: DWORD = 2;
pub const BI_BITFIELDS: DWORD = 3;
/// bV5CSType: the sRGB color space, 'sRGB'.
pub const LCS_sRGB: DWORD = 0x73524742;
/// bV5CSType: a profile in the DIB, 'MBED', and one named by a path in it,
/// 'LINK'. Either is found from bV5ProfileData, an offset from the header.
pub const PROFILE_EMBEDDED: DWORD = 0x4D424544;
pub const PROFILE_LINKED: DWORD = 0x4C494E4B;
/// bV5Intent: keep contrast, for photographs and images.
pub const LCS_GM_IMAGES: DWORD = 4;
pub const CP_UTF8: UINT = internal_os.windows.CP_UTF8;

pub const MB_OK: UINT = 0x00000000;
pub const MB_OKCANCEL: UINT = 0x00000001;
pub const MB_RETRYCANCEL: UINT = 0x00000005;
pub const MB_ICONWARNING: UINT = 0x00000030;
pub const MB_ICONERROR: UINT = 0x00000010;
pub const MB_DEFBUTTON1: UINT = 0x00000000;
pub const MB_DEFBUTTON2: UINT = 0x00000100;
pub const MB_DEFMASK: UINT = 0x00000F00;
pub const IDOK: c_int = 1;
pub const IDRETRY: c_int = 4;

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
/// From Windows 10 1903, and with no import library at all: whether a
/// window is arranged, as a snapped one is.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iswindowarranged
pub const IsWindowArrangedFn = *const fn (hwnd: HWND) callconv(.winapi) BOOL;
/// From Windows 10 1607, as GetDpiForWindow.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetricsfordpi
pub const GetSystemMetricsForDpiFn = *const fn (index: c_int, dpi: UINT) callconv(.winapi) c_int;

pub const GetLastError = internal_os.windows.GetLastError;
/// GetLastError's answer: `.SUCCESS`, or the error a failing call left.
pub const Win32Error = w.Win32Error;
/// Sets the thread's last error. Cleared to `.SUCCESS` before a call whose
/// answer for a failure is also one of its results, it tells the two apart
/// afterwards.
/// https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-setlasterror
pub extern "kernel32" fn SetLastError(code: Win32Error) callconv(.winapi) void;
pub const GetModuleHandleW = internal_os.windows.exp.kernel32.GetModuleHandleW;
pub const GetProcAddress = internal_os.windows.exp.kernel32.GetProcAddress;
pub const LoadLibraryExW = internal_os.windows.exp.kernel32.LoadLibraryExW;
pub const LOAD_LIBRARY_SEARCH_SYSTEM32 = internal_os.windows.LOAD_LIBRARY_SEARCH_SYSTEM32;
pub const CreateProcessW = internal_os.windows.exp.kernel32.CreateProcessW;
pub const STARTUPINFOW = internal_os.windows.STARTUPINFOW;
pub const PROCESS_INFORMATION = internal_os.windows.PROCESS_INFORMATION;
pub const GetEnvironmentVariableW = internal_os.windows.exp.kernel32.GetEnvironmentVariableW;
pub const SetEnvironmentVariableW = internal_os.windows.exp.kernel32.SetEnvironmentVariableW;
/// Milliseconds since the system started.
/// https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-gettickcount64
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
/// "On systems that run Windows XP or later, the function will always
/// succeed and will thus never return zero."
/// https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancecounter
pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
/// Counts per second, fixed at boot.
/// https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancefrequency
pub extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) BOOL;
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
pub extern "user32" fn SendMessageW(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
/// A message number for `name`, the same in every process; 0 on failure.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerwindowmessagew
pub extern "user32" fn RegisterWindowMessageW(name: LPCWSTR) callconv(.winapi) UINT;
pub const MSGFLT_ALLOW: DWORD = 1;
/// Lets a message through to `hwnd` from a process of lower integrity, as
/// one running elevated needs for Explorer's TaskbarButtonCreated.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-changewindowmessagefilterex
pub extern "user32" fn ChangeWindowMessageFilterEx(
    hwnd: HWND,
    message: UINT,
    action: DWORD,
    change_filter: ?*anyopaque,
) callconv(.winapi) BOOL;
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
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-windowplacement
pub const WINDOWPLACEMENT = extern struct {
    length: UINT,
    flags: UINT,
    showCmd: UINT,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowplacement
pub extern "user32" fn GetWindowPlacement(hwnd: HWND, placement: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowplacement
pub extern "user32" fn SetWindowPlacement(hwnd: HWND, placement: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-ischild
pub extern "user32" fn IsChild(parent: HWND, hwnd: HWND) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setfocus
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getactivewindow
pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getancestor
pub extern "user32" fn GetAncestor(hwnd: HWND, flags: UINT) callconv(.winapi) ?HWND;
pub const GA_PARENT: UINT = 1;
pub const GA_ROOT: UINT = 2;
/// The top-level window at the end of a window's chain of parents and
/// owners: a frame's, for one of its prompts.
pub const GA_ROOTOWNER: UINT = 3;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setparent
pub extern "user32" fn SetParent(child: HWND, parent: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
pub extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn WindowFromPoint(pt: POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(hwnd: HWND, pt: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(pt: *POINT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics
pub extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
/// The pixels on either side of a press the pointer may move before a
/// drag begins, at the system DPI (GetSystemMetrics) or a given one.
pub const SM_CXDRAG: c_int = 68;
pub const SM_CYDRAG: c_int = 69;
pub extern "user32" fn SystemParametersInfoW(
    action: UINT,
    param: UINT,
    value: ?*anyopaque,
    win_ini: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iswindowvisible
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowtextw
pub extern "user32" fn GetWindowTextW(hwnd: HWND, text: [*]u16, max: c_int) callconv(.winapi) c_int;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    after: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
) callconv(.winapi) BOOL;
/// For tests: a hook on the messages sent to a thread's windows.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowshookexw
pub const HHOOK = *opaque {};
pub const HOOKPROC = *const fn (code: c_int, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub const WH_CALLWNDPROC: c_int = 4;
pub const WH_CALLWNDPROCRET: c_int = 12;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-cwpretstruct
pub const CWPRETSTRUCT = extern struct {
    lResult: LRESULT,
    lParam: LPARAM,
    wParam: WPARAM,
    message: UINT,
    hwnd: HWND,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-cwpstruct
pub const CWPSTRUCT = extern struct {
    lParam: LPARAM,
    wParam: WPARAM,
    message: UINT,
    hwnd: HWND,
};
pub extern "user32" fn SetWindowsHookExW(
    id: c_int,
    proc: HOOKPROC,
    module: ?HINSTANCE,
    thread: DWORD,
) callconv(.winapi) ?HHOOK;
pub extern "user32" fn UnhookWindowsHookEx(hook: HHOOK) callconv(.winapi) BOOL;
pub extern "user32" fn CallNextHookEx(hook: ?HHOOK, code: c_int, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

// A desktop of its own for a test that reads whether a window is topmost
// (App.testOnOwnDesktop): window messages and hooks do not cross desktops.
// https://learn.microsoft.com/en-us/windows/win32/winstation/desktops
pub const HDESK = *opaque {};
/// Every access right to a desktop.
/// https://learn.microsoft.com/en-us/windows/win32/winstation/desktop-security-and-access-rights
pub const GENERIC_ALL: DWORD = 0x10000000;
/// Opens the process's window station's desktop of that name instead, if
/// there is one.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createdesktopw
pub extern "user32" fn CreateDesktopW(
    name: LPCWSTR,
    device: ?LPCWSTR,
    mode: ?*const anyopaque,
    flags: DWORD,
    access: DWORD,
    attributes: ?*const anyopaque,
) callconv(.winapi) ?HDESK;
/// Fails for a thread that has a window or a hook.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddesktop
pub extern "user32" fn SetThreadDesktop(desktop: HDESK) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-closedesktop
pub extern "user32" fn CloseDesktop(desktop: HDESK) callconv(.winapi) BOOL;

/// A pending batch of window positions (BeginDeferWindowPos).
pub const HDWP = *opaque {};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-begindeferwindowpos
pub extern "user32" fn BeginDeferWindowPos(count: c_int) callconv(.winapi) ?HDWP;
/// Returns the batch to pass on, possibly a new handle, or null on failure,
/// when the caller is to abandon the batch and not call EndDeferWindowPos.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-deferwindowpos
pub extern "user32" fn DeferWindowPos(
    batch: HDWP,
    hwnd: HWND,
    after: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
) callconv(.winapi) ?HDWP;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enddeferwindowpos
pub extern "user32" fn EndDeferWindowPos(batch: HDWP) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: ResourceW) callconv(.winapi) ?HCURSOR;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadiconw
pub extern "user32" fn LoadIconW(inst: ?HINSTANCE, name: ResourceW) callconv(.winapi) ?HICON;
/// https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-assocquerystringw
pub extern "shlwapi" fn AssocQueryStringW(
    flags: DWORD,
    str: DWORD,
    assoc: LPCWSTR,
    extra: ?LPCWSTR,
    out: ?[*]u16,
    out_len: *DWORD,
) callconv(.winapi) HRESULT;
/// ASSOCF_INIT_IGNOREUNKNOWN: fail for a kind no program is registered
/// for, rather than answer with the shell's Unknown type (OpenWith).
pub const ASSOCF_INIT_IGNOREUNKNOWN: DWORD = 0x00000400;
/// ASSOCF_NOTRUNCATE: fail with E_POINTER for a string the buffer cannot
/// hold, rather than cut it short.
pub const ASSOCF_NOTRUNCATE: DWORD = 0x00000020;
pub const ASSOCSTR_COMMAND: DWORD = 1;
pub const ASSOCSTR_PROGID: DWORD = 20;
/// Takes a path of at most MAX_PATH characters, and returns the address
/// of its extension's '.' or of its terminating NUL.
/// https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-pathfindextensionw
pub extern "shlwapi" fn PathFindExtensionW(path: LPCWSTR) callconv(.winapi) LPCWSTR;
pub const MAX_PATH = w.MAX_PATH;
/// https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-shellexecuteinfow
pub const SHELLEXECUTEINFOW = extern struct {
    cbSize: DWORD,
    fMask: DWORD,
    hwnd: ?HWND = null,
    lpVerb: ?LPCWSTR = null,
    lpFile: ?LPCWSTR = null,
    lpParameters: ?LPCWSTR = null,
    lpDirectory: ?LPCWSTR = null,
    nShow: c_int,
    hInstApp: ?HINSTANCE = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?LPCWSTR = null,
    hkeyClass: ?HKEY = null,
    dwHotKey: DWORD = 0,
    hIconOrMonitor: ?HANDLE = null,
    hProcess: ?HANDLE = null,
};
pub const SEE_MASK_CLASSNAME: DWORD = 0x00000001;
/// SEE_MASK_NOASYNC: finish the launch, a DDE conversation included,
/// before returning; required of a thread with no message loop or one
/// that ends soon after the call.
pub const SEE_MASK_NOASYNC: DWORD = 0x00000100;
pub const SEE_MASK_FLAG_NO_UI: DWORD = 0x00000400;
/// https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shellexecuteexw
pub extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
/// The files of a drop: a global memory block that starts with DROPFILES.
pub const HDROP = *opaque {};
/// https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/ns-shlobj_core-dropfiles
/// Followed, at `pFiles` bytes from its start, by the names, each ended
/// by a NUL and the list by another.
pub const DROPFILES = extern struct {
    pFiles: DWORD,
    pt: POINT,
    fNC: BOOL,
    fWide: BOOL,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-dragqueryfilew
/// With index 0xFFFFFFFF, the number of files; with no buffer, the
/// length of a name in characters, not counting its NUL.
pub extern "shell32" fn DragQueryFileW(
    drop: HDROP,
    index: UINT,
    buf: ?[*]u16,
    len: UINT,
) callconv(.winapi) UINT;
pub extern "shell32" fn DragFinish(drop: HDROP) callconv(.winapi) void;
pub const COINIT_MULTITHREADED: DWORD = 0x0;
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
/// `fail` if `hr` is a failure, logged with `what`: how the Save dialog,
/// the bell's audio, the taskbar's progress and the toasts check their
/// COM and WinRT calls. `fail` is an error value, so each keeps its own
/// error set: `error.ToastFailed` is an `error{ToastFailed}`.
pub fn checkHr(hr: HRESULT, comptime fail: anytype, what: []const u8) @TypeOf(fail)!void {
    if (hr >= 0) return;
    log.warn("{s} failed hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
    return fail;
}
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
/// https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-cocreateinstance
pub extern "ole32" fn CoCreateInstance(
    clsid: *const w.GUID,
    outer: ?*anyopaque,
    context: DWORD,
    iid: *const w.GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;
/// Frees what a COM method allocated for its caller, such as a string it
/// returned (combaseapi.h).
/// https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-cotaskmemfree
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

// The common item dialog (SaveDialog.zig).

/// FILEOPENDIALOGOPTIONS (shobjidl.h). A Save dialog starts with
/// OVERWRITEPROMPT, NOCHANGEDIR, PATHMUSTEXIST and NOREADONLYRETURN set.
pub const FOS_OVERWRITEPROMPT: DWORD = 0x2;
pub const FOS_NOCHANGEDIR: DWORD = 0x8;
/// Only items with a path in the file system.
pub const FOS_FORCEFILESYSTEM: DWORD = 0x40;
pub const FOS_PATHMUSTEXIST: DWORD = 0x800;
pub const FOS_NOREADONLYRETURN: DWORD = 0x8000;
/// The shell item for a path (shobjidl.h), as the dialog returns one.
/// https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-shcreateitemfromparsingname
pub extern "shell32" fn SHCreateItemFromParsingName(
    path: LPCWSTR,
    bind: ?*anyopaque,
    iid: *const w.GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;

// DWM
/// https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmsetwindowattribute
pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HWND,
    attribute: DWORD,
    value: *const anyopaque,
    size: DWORD,
) callconv(.winapi) HRESULT;
/// dwmapi.h, from Windows 10 20H1 (build 19041).
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
/// https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmgetwindowattribute
pub extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: HWND,
    attribute: DWORD,
    value: *anyopaque,
    size: DWORD,
) callconv(.winapi) HRESULT;
/// The frame's visible bounds, a RECT in screen coordinates, without the
/// invisible resize borders GetWindowRect includes (dwmapi.h).
pub const DWMWA_EXTENDED_FRAME_BOUNDS: DWORD = 9;
/// dwmapi.h, from Windows 11 22H2 (build 22621): a DWORD, one of
/// DWM_SYSTEMBACKDROP_TYPE's.
pub const DWMWA_SYSTEMBACKDROP_TYPE: DWORD = 38;
/// DWM_SYSTEMBACKDROP_TYPE: DWM decides, the default; and acrylic, a
/// transient window's (Learn: "Desktop Acrylic").
pub const DWMSBT_AUTO: DWORD = 0;
pub const DWMSBT_TRANSIENTWINDOW: DWORD = 3;
/// DWM_BLURBEHIND's `flags`: `enable` and `region` apply.
pub const DWM_BB_ENABLE: DWORD = 0x1;
pub const DWM_BB_BLURREGION: DWORD = 0x2;
/// https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ns-dwmapi-dwm_blurbehind
pub const DWM_BLURBEHIND = extern struct {
    flags: DWORD,
    enable: BOOL,
    region: ?HRGN,
    transition_on_maximized: BOOL,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmenableblurbehindwindow
pub extern "dwmapi" fn DwmEnableBlurBehindWindow(hwnd: HWND, blur: *const DWM_BLURBEHIND) callconv(.winapi) HRESULT;

// Registry
pub const HKEY = w.HKEY;
pub const HKEY_CURRENT_USER = w.HKEY_CURRENT_USER;
pub const RRF_RT_REG_DWORD: DWORD = 0x0000_0010;
/// https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-reggetvaluew
pub extern "advapi32" fn RegGetValueW(
    key: HKEY,
    subkey: ?LPCWSTR,
    value: ?LPCWSTR,
    flags: DWORD,
    value_type: ?*DWORD,
    data: ?*anyopaque,
    size: ?*DWORD,
) callconv(.winapi) LONG;

pub const REG_SZ: DWORD = 1;
pub const REG_OPTION_NON_VOLATILE: DWORD = 0;
pub const KEY_SET_VALUE: DWORD = 0x0002;
/// https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regcreatekeyexw
pub extern "advapi32" fn RegCreateKeyExW(
    key: HKEY,
    subkey: LPCWSTR,
    reserved: DWORD,
    class: ?LPCWSTR,
    options: DWORD,
    sam: DWORD,
    security: ?*anyopaque,
    result: *HKEY,
    disposition: ?*DWORD,
) callconv(.winapi) LONG;
/// https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regsetvalueexw
pub extern "advapi32" fn RegSetValueExW(
    key: HKEY,
    name: ?LPCWSTR,
    reserved: DWORD,
    value_type: DWORD,
    data: [*]const u8,
    size: DWORD,
) callconv(.winapi) LONG;
/// https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regdeletevaluew
pub extern "advapi32" fn RegDeleteValueW(key: HKEY, name: ?LPCWSTR) callconv(.winapi) LONG;
/// https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regclosekey
pub extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) LONG;

// COM, shared by the runtime's own interfaces (taskbar.zig, toast.zig).
pub const S_OK: HRESULT = internal_os.windows.S_OK;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const IID_IUnknown: w.GUID = w.GUID.parse("{00000000-0000-0000-c000-000000000046}");
/// An object that may be called on any thread, with no marshaling.
pub const IID_IAgileObject: w.GUID = w.GUID.parse("{94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90}");
/// A length-prefixed UTF-16 string from SysAllocString.
pub const BSTR = [*:0]u16;
/// https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-sysallocstring
pub extern "oleaut32" fn SysAllocString(text: LPCWSTR) callconv(.winapi) ?BSTR;
/// https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-sysfreestring
pub extern "oleaut32" fn SysFreeString(text: ?BSTR) callconv(.winapi) void;

// Windows Runtime. Both import libraries are API sets, which Windows
// resolves to combase.dll: mingw has them, the Windows SDK does not, so
// they are linked only through these declarations
// (src/build/SharedDeps.zig).
pub const HSTRING = ?*opaque {};
/// https://learn.microsoft.com/en-us/windows/win32/api/winstring/nf-winstring-windowscreatestring
pub extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(
    source: ?[*]const u16,
    length: u32,
    string: *HSTRING,
) callconv(.winapi) HRESULT;
/// https://learn.microsoft.com/en-us/windows/win32/api/winstring/nf-winstring-windowsdeletestring
pub extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(string: HSTRING) callconv(.winapi) HRESULT;
/// https://learn.microsoft.com/en-us/windows/win32/api/roapi/nf-roapi-rogetactivationfactory
pub extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(
    class: HSTRING,
    iid: *const w.GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;
/// https://learn.microsoft.com/en-us/windows/win32/api/roapi/nf-roapi-roactivateinstance
pub extern "api-ms-win-core-winrt-l1-1-0" fn RoActivateInstance(
    class: HSTRING,
    instance: *?*anyopaque,
) callconv(.winapi) HRESULT;

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
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-allowsetforegroundwindow
pub extern "user32" fn AllowSetForegroundWindow(process_id: DWORD) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-isiconic
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iswindow
pub extern "user32" fn IsWindow(hwnd: HWND) callconv(.winapi) BOOL;
/// The handle the property `name` held, or null if the window had none.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-removepropa
pub extern "user32" fn RemovePropA(hwnd: HWND, name: [*:0]const u8) callconv(.winapi) ?HANDLE;
/// Returns whether the window was disabled *before* the call.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enablewindow
pub extern "user32" fn EnableWindow(hwnd: HWND, enable: BOOL) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-iswindowenabled
pub extern "user32" fn IsWindowEnabled(hwnd: HWND) callconv(.winapi) BOOL;

pub const HMONITOR = *opaque {};
pub const MONITOR_DEFAULTTONULL: DWORD = 0x00000000;
pub const MONITOR_DEFAULTTOPRIMARY: DWORD = 0x00000001;
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
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-monitorfromrect
pub extern "user32" fn MonitorFromRect(rect: *const RECT, flags: DWORD) callconv(.winapi) ?HMONITOR;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-monitorfrompoint
pub extern "user32" fn MonitorFromPoint(pt: POINT, flags: DWORD) callconv(.winapi) ?HMONITOR;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmonitorinfow
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(hwnd: ?HWND, rect: ?*const RECT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-invalidaterect
pub extern "user32" fn InvalidateRect(hwnd: ?HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
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
/// For tests: the calling thread's key state, as GetKeyState reads it.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setkeyboardstate
pub extern "user32" fn SetKeyboardState(key_state: *const [256]BYTE) callconv(.winapi) BOOL;
/// For tests: wait without pumping messages.
/// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleep
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "user32" fn MapVirtualKeyW(code: UINT, map_type: UINT) callconv(.winapi) UINT;
pub extern "user32" fn GetKeyboardLayout(thread_id: DWORD) callconv(.winapi) ?HKL;
/// MapVirtualKeyW on `layout`.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mapvirtualkeyexw
pub extern "user32" fn MapVirtualKeyExW(code: UINT, map_type: UINT, layout: ?HKL) callconv(.winapi) UINT;
/// The key that types `ch` on `layout`: its virtual key in the low byte
/// and the shift state it needs in the high one, or -1.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-vkkeyscanexw
pub extern "user32" fn VkKeyScanExW(ch: WCHAR, layout: ?HKL) callconv(.winapi) SHORT;

/// Hotkeys: a WM_HOTKEY to the window's thread when the keys are pressed,
/// in whichever program is in front.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey
pub extern "user32" fn RegisterHotKey(hwnd: ?HWND, id: c_int, mods: UINT, vk: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn UnregisterHotKey(hwnd: ?HWND, id: c_int) callconv(.winapi) BOOL;
pub const WM_HOTKEY: UINT = 0x0312;
pub const MOD_ALT: UINT = 0x0001;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_WIN: UINT = 0x0008;
/// A held key fires the hotkey once, not at each repeat.
pub const MOD_NOREPEAT: UINT = 0x4000;
pub extern "user32" fn ToUnicodeEx(
    vk: UINT,
    scan_code: UINT,
    key_state: *const [256]BYTE,
    buf: [*]WCHAR,
    buf_len: c_int,
    flags: UINT,
    layout: ?HKL,
) callconv(.winapi) c_int;
/// The shortest a timer runs; SetTimer takes any shorter time as this.
pub const USER_TIMER_MINIMUM: UINT = 0x0000000A;
pub extern "user32" fn SetTimer(
    hwnd: ?HWND,
    id: UINT_PTR,
    elapse_ms: UINT,
    proc: ?*const anyopaque,
) callconv(.winapi) UINT_PTR;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: UINT_PTR) callconv(.winapi) BOOL;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetCursor() callconv(.winapi) ?HCURSOR;
/// GetClassLongW's index of the class's style (`CS_DBLCLKS`).
pub const GCL_STYLE: c_int = -26;
pub extern "user32" fn GetClassLongW(hwnd: HWND, index: c_int) callconv(.winapi) DWORD;
pub extern "user32" fn MessageBeep(type_: UINT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-flashwinfo
pub const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};
/// FLASHWINFO: flash the taskbar button.
pub const FLASHW_TRAY: DWORD = 0x2;
/// FLASHWINFO: flash until the window comes to the foreground.
pub const FLASHW_TIMERNOFG: DWORD = 0xC;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-flashwindowex
pub extern "user32" fn FlashWindowEx(info: *const FLASHWINFO) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getforegroundwindow
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
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
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclipboardformatw
pub extern "user32" fn RegisterClipboardFormatW(name: LPCWSTR) callconv(.winapi) UINT;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumclipboardformats
pub extern "user32" fn EnumClipboardFormats(format: UINT) callconv(.winapi) UINT;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclipboardformatnamew
pub extern "user32" fn GetClipboardFormatNameW(format: UINT, name: [*]u16, max: c_int) callconv(.winapi) c_int;

pub extern "gdi32" fn GetDeviceCaps(hdc: HDC, index: c_int) callconv(.winapi) c_int;

/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-paintstruct
pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-beginpaint
pub extern "user32" fn BeginPaint(hwnd: HWND, paint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-endpaint
pub extern "user32" fn EndPaint(hwnd: HWND, paint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-fillrect
pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) c_int;
/// A colour as GDI takes it: 0x00BBGGRR.
pub const COLORREF = w.COLORREF;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createsolidbrush
pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getstockobject
/// The system's own object, made once: not to be deleted (Learn: deleting
/// one is unnecessary, though not harmful).
pub extern "gdi32" fn GetStockObject(index: c_int) callconv(.winapi) ?HGDIOBJ;
/// wingdi.h's stock black brush, for GetStockObject.
pub const BLACK_BRUSH = 4;
/// A brush, font, bitmap or other GDI object.
pub const HGDIOBJ = *anyopaque;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-deleteobject
pub extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) BOOL;
/// A region, a GDI object.
pub const HRGN = HGDIOBJ;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createrectrgn
pub extern "gdi32" fn CreateRectRgn(left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.winapi) ?HRGN;
/// CombineRgn: the part of the first region not in the second.
pub const RGN_DIFF: c_int = 4;
/// CombineRgn's and GetWindowRgn's answer on failure.
pub const RGN_ERROR: c_int = 0;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-combinergn
pub extern "gdi32" fn CombineRgn(dst: HRGN, src1: HRGN, src2: HRGN, mode: c_int) callconv(.winapi) c_int;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-ptinregion
pub extern "gdi32" fn PtInRegion(rgn: HRGN, x: c_int, y: c_int) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowrgn
pub extern "user32" fn SetWindowRgn(hwnd: HWND, rgn: ?HRGN, redraw: BOOL) callconv(.winapi) c_int;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrgn
pub extern "user32" fn GetWindowRgn(hwnd: HWND, rgn: HRGN) callconv(.winapi) c_int;
/// GetWindowRgn's and GetRgnBox's answers for an empty region and for a
/// rectangle.
pub const NULLREGION: c_int = 1;
pub const SIMPLEREGION: c_int = 2;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getrgnbox
pub extern "gdi32" fn GetRgnBox(rgn: HRGN, rect: *RECT) callconv(.winapi) c_int;
/// RedrawWindow: invalidate, erase, the frame too, and every child.
pub const RDW_INVALIDATE: UINT = 0x0001;
pub const RDW_ERASE: UINT = 0x0004;
pub const RDW_ALLCHILDREN: UINT = 0x0080;
pub const RDW_FRAME: UINT = 0x0400;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-redrawwindow
pub extern "user32" fn RedrawWindow(hwnd: ?HWND, update: ?*const RECT, rgn: ?HRGN, flags: UINT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-selectobject
pub extern "gdi32" fn SelectObject(hdc: HDC, object: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createcompatibledc
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createcompatiblebitmap
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, width: c_int, height: c_int) callconv(.winapi) ?HGDIOBJ;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-deletedc
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub const SRCCOPY: DWORD = 0x00CC0020;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt
pub extern "gdi32" fn BitBlt(
    dest: HDC,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    src: HDC,
    src_x: c_int,
    src_y: c_int,
    rop: DWORD,
) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getpixel
pub extern "gdi32" fn GetPixel(hdc: HDC, x: c_int, y: c_int) callconv(.winapi) COLORREF;
pub const TRANSPARENT: c_int = 1;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setbkmode
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-settextcolor
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub const DT_CENTER: UINT = 0x0001;
pub const DT_VCENTER: UINT = 0x0004;
pub const DT_SINGLELINE: UINT = 0x0020;
pub const DT_NOPREFIX: UINT = 0x0800;
pub const DT_END_ELLIPSIS: UINT = 0x8000;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-drawtextw
pub extern "user32" fn DrawTextW(hdc: HDC, text: [*]const u16, len: c_int, rect: *RECT, format: UINT) callconv(.winapi) c_int;
pub const FW_NORMAL: c_int = 400;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const OUT_DEFAULT_PRECIS: DWORD = 0;
pub const CLIP_DEFAULT_PRECIS: DWORD = 0;
pub const CLEARTYPE_QUALITY: DWORD = 5;
pub const DEFAULT_PITCH: DWORD = 0;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createfontw
pub extern "gdi32" fn CreateFontW(
    height: c_int,
    width: c_int,
    escapement: c_int,
    orientation: c_int,
    weight: c_int,
    italic: DWORD,
    underline: DWORD,
    strike_out: DWORD,
    charset: DWORD,
    out_precision: DWORD,
    clip_precision: DWORD,
    quality: DWORD,
    pitch_and_family: DWORD,
    face: LPCWSTR,
) callconv(.winapi) ?HGDIOBJ;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-logfontw
pub const LOGFONTW = extern struct {
    lfHeight: LONG,
    lfWidth: LONG,
    lfEscapement: LONG,
    lfOrientation: LONG,
    lfWeight: LONG,
    lfItalic: u8,
    lfUnderline: u8,
    lfStrikeOut: u8,
    lfCharSet: u8,
    lfOutPrecision: u8,
    lfClipPrecision: u8,
    lfQuality: u8,
    lfPitchAndFamily: u8,
    lfFaceName: [32]u16,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-nonclientmetricsw
/// With iPaddedBorderWidth, which Windows Vista added.
pub const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT,
    iBorderWidth: c_int,
    iScrollWidth: c_int,
    iScrollHeight: c_int,
    iCaptionWidth: c_int,
    iCaptionHeight: c_int,
    lfCaptionFont: LOGFONTW,
    iSmCaptionWidth: c_int,
    iSmCaptionHeight: c_int,
    lfSmCaptionFont: LOGFONTW,
    iMenuWidth: c_int,
    iMenuHeight: c_int,
    lfMenuFont: LOGFONTW,
    lfStatusFont: LOGFONTW,
    lfMessageFont: LOGFONTW,
    iPaddedBorderWidth: c_int,
};
comptime {
    // The sizes of the SDK's structs, which SystemParametersInfoW checks
    // against cbSize.
    std.debug.assert(@sizeOf(LOGFONTW) == 92);
    std.debug.assert(@sizeOf(NONCLIENTMETRICSW) == 504);
}
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createfontindirectw
pub extern "gdi32" fn CreateFontIndirectW(font: *const LOGFONTW) callconv(.winapi) ?HGDIOBJ;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getobjectw
pub extern "gdi32" fn GetObjectW(object: HGDIOBJ, size: c_int, out: ?*anyopaque) callconv(.winapi) c_int;
/// GetDeviceCaps index for vertical DPI.
pub const LOGPIXELSY: c_int = 90;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getupdaterect
pub extern "user32" fn GetUpdateRect(hwnd: HWND, rect: ?*RECT, erase: BOOL) callconv(.winapi) BOOL;

// The search bar (SearchBar.zig): a window of our own holding an EDIT
// control, subclassed as SetWindowLongPtrW(GWLP_WNDPROC) documents, which
// needs nothing of comctl32 but the control the manifest's Common Controls
// v6 gives.

/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-callwindowprocw
pub extern "user32" fn CallWindowProcW(proc: WNDPROC, hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub const GWLP_WNDPROC: c_int = -4;
/// SetWindowPos's place in the Z order: above every sibling.
pub const HWND_TOP: ?HWND = null;
pub const GW_HWNDNEXT: UINT = 2;
/// GetWindow: the window above, in the Z order.
pub const GW_HWNDPREV: UINT = 3;
pub const GW_CHILD: UINT = 5;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindow
pub extern "user32" fn GetWindow(hwnd: HWND, cmd: UINT) callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowtextlengthw
pub extern "user32" fn GetWindowTextLengthW(hwnd: HWND) callconv(.winapi) c_int;
pub const ES_AUTOHSCROLL: DWORD = 0x0080;
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_GETFONT: UINT = 0x0031;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_CTLCOLOREDIT: UINT = 0x0133;
/// WM_COMMAND's high word of wParam: the EDIT's text changed.
pub const EN_CHANGE: UINT = 0x0300;
pub const EM_GETSEL: UINT = 0x00B0;
pub const EM_SETSEL: UINT = 0x00B1;
pub const EM_REPLACESEL: UINT = 0x00C2;
/// An EDIT copies its selection, and pastes the clipboard's text.
pub const WM_COPY: UINT = 0x0301;
pub const WM_PASTE: UINT = 0x0302;
/// ECM_FIRST + 1: the gray hint an empty EDIT shows (Common Controls v6).
pub const EM_SETCUEBANNER: UINT = 0x1501;
pub const VK_BACK: WPARAM = 0x08;
pub const VK_TAB: WPARAM = 0x09;
pub const VK_RETURN: WPARAM = 0x0D;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const DT_RIGHT: UINT = 0x0002;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setbkcolor
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
pub const PS_SOLID: c_int = 0;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createpen
pub extern "gdi32" fn CreatePen(style: c_int, width: c_int, color: COLORREF) callconv(.winapi) ?HGDIOBJ;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-polyline
pub extern "gdi32" fn Polyline(hdc: HDC, points: [*]const POINT, count: c_int) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-textmetricw
pub const TEXTMETRICW = extern struct {
    tmHeight: LONG,
    tmAscent: LONG,
    tmDescent: LONG,
    tmInternalLeading: LONG,
    tmExternalLeading: LONG,
    tmAveCharWidth: LONG,
    tmMaxCharWidth: LONG,
    tmWeight: LONG,
    tmOverhang: LONG,
    tmDigitizedAspectX: LONG,
    tmDigitizedAspectY: LONG,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};
comptime {
    // The SDK's sizeof(TEXTMETRICW).
    std.debug.assert(@sizeOf(TEXTMETRICW) == 60);
}
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-gettextmetricsw
pub extern "gdi32" fn GetTextMetricsW(hdc: HDC, tm: *TEXTMETRICW) callconv(.winapi) BOOL;

// The title prompt (TitleDialog.zig): a dialog box made from a template in
// memory and run modeless, its keys handled by IsDialogMessageW from
// `App.run`'s loop.

/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nc-winuser-dlgproc
pub const DLGPROC = *const fn (
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) isize;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createdialogindirectparamw
pub extern "user32" fn CreateDialogIndirectParamW(
    instance: ?HINSTANCE,
    template: *const anyopaque,
    owner: ?HWND,
    proc: DLGPROC,
    param: LPARAM,
) callconv(.winapi) ?HWND;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-isdialogmessagew
pub extern "user32" fn IsDialogMessageW(dialog: HWND, msg: *MSG) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdlgitem
pub extern "user32" fn GetDlgItem(dialog: HWND, id: c_int) callconv(.winapi) ?HWND;
pub const WM_INITDIALOG: UINT = 0x0110;
pub const IDCANCEL: c_int = 2;
pub const SW_SHOW: c_int = 5;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_GROUP: DWORD = 0x00020000;
pub const WS_TABSTOP: DWORD = 0x00010000;
/// The template names the dialog's font (its point size and face).
pub const DS_SETFONT: DWORD = 0x0040;
pub const DS_MODALFRAME: DWORD = 0x0080;
pub const BS_PUSHBUTTON: DWORD = 0x0000;
pub const BS_DEFPUSHBUTTON: DWORD = 0x0001;
/// A static control shows its text with no "&" mnemonic.
pub const SS_NOPREFIX: DWORD = 0x0080;

// The Kitty clipboard prompt (`ClipboardDialog`): a modal dialog box made
// from a template in memory, its parts in a combo box, the one picked
// shown as text in a read-only EDIT or as an image drawn into an
// owner-drawn static control.

/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-dialogboxindirectparamw
/// The value given to EndDialog; -1 if the dialog could not be made, 0
/// if `owner` is not a window.
pub extern "user32" fn DialogBoxIndirectParamW(
    instance: ?HINSTANCE,
    template: *const anyopaque,
    owner: ?HWND,
    proc: DLGPROC,
    param: LPARAM,
) callconv(.winapi) isize;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enddialog
pub extern "user32" fn EndDialog(dialog: HWND, result: isize) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdlgitemtextw
pub extern "user32" fn SetDlgItemTextW(dialog: HWND, id: c_int, text: LPCWSTR) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsyscolor
pub extern "user32" fn GetSysColor(index: c_int) callconv(.winapi) COLORREF;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsyscolorbrush
/// One the system owns, never deleted.
pub extern "user32" fn GetSysColorBrush(index: c_int) callconv(.winapi) ?HBRUSH;
/// The face of dialog boxes and their buttons.
pub const COLOR_BTNFACE: c_int = 15;
/// GetWindow: the window's owner.
pub const GW_OWNER: UINT = 4;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setstretchbltmode
pub extern "gdi32" fn SetStretchBltMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
/// Each pixel the average of the pixels it stands for.
pub const HALFTONE: c_int = 4;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-setbrushorgex
/// Called after SetStretchBltMode(HALFTONE), as that function's page asks.
pub extern "gdi32" fn SetBrushOrgEx(hdc: HDC, x: c_int, y: c_int, old: ?*POINT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getbrushorgex
pub extern "gdi32" fn GetBrushOrgEx(hdc: HDC, point: *POINT) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-getstretchbltmode
/// 0 on failure.
pub extern "gdi32" fn GetStretchBltMode(hdc: HDC) callconv(.winapi) c_int;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-savedc
/// The number of the state saved; 0 on failure.
pub extern "gdi32" fn SaveDC(hdc: HDC) callconv(.winapi) c_int;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-restoredc
/// Back to the state SaveDC numbered `saved`.
pub extern "gdi32" fn RestoreDC(hdc: HDC, saved: c_int) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-stretchdibits
/// The scan lines copied; 0 on failure.
pub extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    x_dest: c_int,
    y_dest: c_int,
    width_dest: c_int,
    height_dest: c_int,
    x_src: c_int,
    y_src: c_int,
    width_src: c_int,
    height_src: c_int,
    bits: *const anyopaque,
    info: *const anyopaque,
    usage: UINT,
    rop: DWORD,
) callconv(.winapi) c_int;
/// The color table holds RGBQUADs.
pub const DIB_RGB_COLORS: UINT = 0;
/// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader
pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: i32,
    /// Negative for rows from the top down.
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};
comptime {
    // biSize: the SDK's sizeof(BITMAPINFOHEADER).
    std.debug.assert(@sizeOf(BITMAPINFOHEADER) == 40);
}
/// https://learn.microsoft.com/en-us/windows/win32/controls/combo-box-styles
pub const CBS_DROPDOWNLIST: DWORD = 0x0003;
/// https://learn.microsoft.com/en-us/windows/win32/controls/bumper-combobox-control-reference-messages
pub const CB_ADDSTRING: UINT = 0x0143;
pub const CB_GETCOUNT: UINT = 0x0146;
pub const CB_GETCURSEL: UINT = 0x0147;
pub const CB_SETCURSEL: UINT = 0x014E;
/// WM_COMMAND's notification: the combo box's selection changed.
pub const CBN_SELCHANGE: u16 = 1;
/// https://learn.microsoft.com/en-us/windows/win32/controls/edit-control-styles
pub const ES_MULTILINE: DWORD = 0x0004;
pub const ES_AUTOVSCROLL: DWORD = 0x0040;
pub const ES_READONLY: DWORD = 0x0800;
/// https://learn.microsoft.com/en-us/windows/win32/controls/static-control-styles
pub const SS_CENTER: DWORD = 0x0001;
pub const SS_LEFTNOWORDWRAP: DWORD = 0x000C;
/// Its parent draws it, given WM_DRAWITEM.
pub const SS_OWNERDRAW: DWORD = 0x000D;
pub const SS_ENDELLIPSIS: DWORD = 0x4000;
/// https://learn.microsoft.com/en-us/windows/win32/controls/button-styles
pub const BS_AUTOCHECKBOX: DWORD = 0x0003;
pub const BM_GETCHECK: UINT = 0x00F0;
pub const BM_SETCHECK: UINT = 0x00F1;
/// BM_GETCHECK's answer for a checked box, and BM_SETCHECK's to check it.
pub const BST_CHECKED: LRESULT = 1;
/// https://learn.microsoft.com/en-us/windows/win32/dlgbox/dm-getdefid
/// The default push button's id in the low word, DC_HASDEFID in the high.
pub const DM_GETDEFID: UINT = 0x0400;
pub const DC_HASDEFID: u16 = 0x534B;
/// Centred in the work area of its owner's monitor, or the primary's.
pub const DS_CENTER: DWORD = 0x0800;

// The command palette (CommandPalette.zig): a window of the frame's holding
// an EDIT for the query above an owner-drawn LISTBOX.

pub const WS_VSCROLL: DWORD = 0x00200000;
pub const WM_USER: UINT = 0x0400;
pub const WM_SETREDRAW: UINT = 0x000B;
pub const WM_DRAWITEM: UINT = 0x002B;
pub const WM_MEASUREITEM: UINT = 0x002C;
pub const WM_CTLCOLORLISTBOX: UINT = 0x0134;
/// WM_ACTIVATE's low word of wParam when the window is deactivated.
pub const WA_INACTIVE: u16 = 0;
pub const VK_PRIOR: WPARAM = 0x21;
pub const VK_NEXT: WPARAM = 0x22;
pub const VK_UP: WPARAM = 0x26;
pub const VK_DOWN: WPARAM = 0x28;
pub const LBS_NOTIFY: DWORD = 0x0001;
pub const LBS_OWNERDRAWFIXED: DWORD = 0x0010;
pub const LBS_HASSTRINGS: DWORD = 0x0040;
pub const LBS_NOINTEGRALHEIGHT: DWORD = 0x0100;
pub const LB_ADDSTRING: UINT = 0x0180;
pub const LB_RESETCONTENT: UINT = 0x0184;
pub const LB_SETCURSEL: UINT = 0x0186;
pub const LB_GETCURSEL: UINT = 0x0188;
pub const LB_GETCOUNT: UINT = 0x018B;
pub const LB_GETTOPINDEX: UINT = 0x018E;
pub const LB_SETTOPINDEX: UINT = 0x0197;
pub const LB_GETITEMDATA: UINT = 0x0199;
pub const LB_SETITEMDATA: UINT = 0x019A;
pub const LB_SETITEMHEIGHT: UINT = 0x01A0;
pub const LB_GETITEMHEIGHT: UINT = 0x01A1;
pub const LB_ITEMFROMPOINT: UINT = 0x01A9;
pub const LB_ERR: LRESULT = -1;
/// DRAWITEMSTRUCT's itemState: the item is selected.
pub const ODS_SELECTED: UINT = 0x0001;
/// DrawTextW measures the text into the rect and draws nothing.
pub const DT_CALCRECT: UINT = 0x0400;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-drawitemstruct
pub const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: ?HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-measureitemstruct
pub const MEASUREITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemWidth: UINT,
    itemHeight: UINT,
    itemData: usize,
};
/// The visual style a control is drawn with: the command palette's list
/// takes the dark one for its scrollbar in a dark frame
/// (`CommandPalette.applyListTheme`).
/// https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-setwindowtheme
pub extern "uxtheme" fn SetWindowTheme(hwnd: HWND, sub_app_name: ?LPCWSTR, sub_id_list: ?LPCWSTR) callconv(.winapi) HRESULT;

// Buffered painting: GDI drawn into a 32-bit buffer whose alpha can be
// set before it is copied to the window, as GDI alone writes alpha 0
// (`Transparency.fillOpaque`).
/// A buffered paint context (uxtheme.h).
pub const HPAINTBUFFER = *opaque {};
/// BP_BUFFERFORMAT: a top-down 32-bit DIB, which has an alpha channel.
pub const BPBF_TOPDOWNDIB: c_int = 2;
/// https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-bufferedpaintinit
pub extern "uxtheme" fn BufferedPaintInit() callconv(.winapi) HRESULT;
/// https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-bufferedpaintuninit
pub extern "uxtheme" fn BufferedPaintUnInit() callconv(.winapi) HRESULT;
/// https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-beginbufferedpaint
pub extern "uxtheme" fn BeginBufferedPaint(
    target: HDC,
    rect: *const RECT,
    format: c_int,
    params: ?*const anyopaque,
    hdc: *?HDC,
) callconv(.winapi) ?HPAINTBUFFER;
/// https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-bufferedpaintsetalpha
pub extern "uxtheme" fn BufferedPaintSetAlpha(buffer: HPAINTBUFFER, rect: ?*const RECT, alpha: BYTE) callconv(.winapi) HRESULT;
/// https://learn.microsoft.com/en-us/windows/win32/api/uxtheme/nf-uxtheme-endbufferedpaint
pub extern "uxtheme" fn EndBufferedPaint(buffer: HPAINTBUFFER, update_target: BOOL) callconv(.winapi) HRESULT;

// The palette's tooltip, a system tooltip control made by its class name,
// which the manifest's Common Controls v6 registers: nothing is imported
// from comctl32. It is fed the list's mouse messages (TTM_RELAYEVENT)
// rather than subclassing the list itself.

/// https://learn.microsoft.com/en-us/windows/win32/controls/wm-vscroll
pub const WM_VSCROLL: UINT = 0x0115;
/// TOOLTIPS_CLASSW.
/// https://learn.microsoft.com/en-us/windows/win32/controls/tooltip-controls
pub const TOOLTIPS_CLASS = "tooltips_class32";
/// https://learn.microsoft.com/en-us/windows/win32/controls/tooltip-styles
pub const TTS_ALWAYSTIP: DWORD = 0x01;
pub const TTS_NOPREFIX: DWORD = 0x02;
/// TOOLINFOW's uId is the window the tool covers, all of its client area.
pub const TTF_IDISHWND: UINT = 0x0001;
/// https://learn.microsoft.com/en-us/windows/win32/controls/ttm-relayevent
pub const TTM_RELAYEVENT: UINT = WM_USER + 7;
/// https://learn.microsoft.com/en-us/windows/win32/controls/ttm-setmaxtipwidth
pub const TTM_SETMAXTIPWIDTH: UINT = WM_USER + 24;
/// https://learn.microsoft.com/en-us/windows/win32/controls/ttm-pop
pub const TTM_POP: UINT = WM_USER + 28;
/// https://learn.microsoft.com/en-us/windows/win32/controls/ttm-addtool
pub const TTM_ADDTOOLW: UINT = WM_USER + 50;
/// https://learn.microsoft.com/en-us/windows/win32/controls/ttm-updatetiptext
pub const TTM_UPDATETIPTEXTW: UINT = WM_USER + 57;
/// The whole structure, lpReserved included, as Common Controls v6 wants
/// cbSize (TTTOOLINFOW_V3_SIZE).
/// https://learn.microsoft.com/en-us/windows/win32/api/commctrl/ns-commctrl-ttoolinfow
pub const TOOLINFOW = extern struct {
    cbSize: UINT = @sizeOf(TOOLINFOW),
    uFlags: UINT = 0,
    hwnd: ?HWND = null,
    uId: usize = 0,
    rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    hinst: ?HINSTANCE = null,
    lpszText: ?LPCWSTR = null,
    lParam: LPARAM = 0,
    lpReserved: ?*anyopaque = null,
};

// A terminal's context menu (ContextMenu.zig): a system popup menu.

/// AppendMenuW's flags. MF_STRING is 0: an item of text, enabled and not
/// checked.
pub const MF_STRING: UINT = 0x0000;
pub const MF_GRAYED: UINT = 0x0001;
pub const MF_CHECKED: UINT = 0x0008;
/// The id is a submenu's HMENU, which the menu then owns.
pub const MF_POPUP: UINT = 0x0010;
pub const MF_SEPARATOR: UINT = 0x0800;
/// GetMenuState's and GetMenuStringW's item is a place, not an id.
pub const MF_BYPOSITION: UINT = 0x0400;
/// TrackPopupMenuEx's flags: items are chosen with either button, and the
/// chosen item's id is returned rather than sent as WM_COMMAND.
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const TPM_RETURNCMD: UINT = 0x0100;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
/// Destroys its submenus with it.
pub extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: UINT_PTR, item: ?LPCWSTR) callconv(.winapi) BOOL;
/// With TPM_RETURNCMD, the chosen item's id, or 0 for none (dismissed, or
/// an error): declared as the int it is rather than a BOOL.
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-trackpopupmenuex
pub extern "user32" fn TrackPopupMenuEx(
    menu: HMENU,
    flags: UINT,
    x: c_int,
    y: c_int,
    owner: HWND,
    params: ?*anyopaque,
) callconv(.winapi) c_int;
pub extern "user32" fn GetMenuItemCount(menu: HMENU) callconv(.winapi) c_int;
pub extern "user32" fn GetMenuItemID(menu: HMENU, pos: c_int) callconv(.winapi) UINT;
pub extern "user32" fn GetSubMenu(menu: HMENU, pos: c_int) callconv(.winapi) ?HMENU;
pub extern "user32" fn GetMenuState(menu: HMENU, item: UINT, flags: UINT) callconv(.winapi) UINT;
pub extern "user32" fn GetMenuStringW(menu: HMENU, item: UINT, text: ?[*]u16, max: c_int, flags: UINT) callconv(.winapi) c_int;
/// GetGuiResources' count of the process's USER objects, menus among them.
pub const GR_USEROBJECTS: DWORD = 1;
pub extern "user32" fn GetGuiResources(process: HANDLE, flags: DWORD) callconv(.winapi) DWORD;
/// GetCurrentProcess's pseudo handle, which needs no closing.
pub const current_process: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const current_thread: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

// Named pipes, events and tokens, for IPC (IpcServer.zig).

pub const CloseHandle = internal_os.windows.exp.kernel32.CloseHandle;
pub const CreateFileW = internal_os.windows.exp.kernel32.CreateFileW;
pub const CreateNamedPipeW = internal_os.windows.exp.kernel32.CreateNamedPipeW;
pub const ReadFile = internal_os.windows.exp.kernel32.ReadFile;
pub const WriteFile = internal_os.windows.exp.kernel32.WriteFile;
pub const CancelIoEx = internal_os.windows.exp.kernel32.CancelIoEx;
pub const WaitForSingleObject = internal_os.windows.exp.kernel32.WaitForSingleObject;
pub const OVERLAPPED = internal_os.windows.OVERLAPPED;
pub const SECURITY_ATTRIBUTES = internal_os.windows.SECURITY_ATTRIBUTES;
pub const INVALID_HANDLE_VALUE = w.INVALID_HANDLE_VALUE;
pub const FILE_FLAG_OVERLAPPED: DWORD = internal_os.windows.FILE_FLAG_OVERLAPPED;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = internal_os.windows.FILE_FLAG_FIRST_PIPE_INSTANCE;
pub const OPEN_EXISTING: DWORD = internal_os.windows.OPEN_EXISTING;
/// https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createnamedpipew
pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;
pub const PIPE_TYPE_MESSAGE: DWORD = 0x00000004;
pub const PIPE_READMODE_MESSAGE: DWORD = 0x00000002;
pub const PIPE_WAIT: DWORD = 0x00000000;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008;
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
/// https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants
pub const FILE_READ_DATA: DWORD = 0x0001;
pub const FILE_WRITE_DATA: DWORD = 0x0002;
pub const FILE_READ_ATTRIBUTES: DWORD = 0x0080;
pub const FILE_WRITE_ATTRIBUTES: DWORD = 0x0100;
/// https://learn.microsoft.com/en-us/windows/win32/secauthz/standard-access-rights
pub const READ_CONTROL: DWORD = 0x00020000;
pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const INFINITE: DWORD = 0xFFFF_FFFF;
pub const WAIT_OBJECT_0: DWORD = 0x0000_0000;
pub const WAIT_TIMEOUT: DWORD = 0x0000_0102;
pub const WAIT_FAILED: DWORD = 0xFFFF_FFFF;
/// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventw
pub extern "kernel32" fn CreateEventW(
    attributes: ?*SECURITY_ATTRIBUTES,
    manual_reset: BOOL,
    initial_state: BOOL,
    name: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;
/// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setevent
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-resetevent
pub extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjects
pub extern "kernel32" fn WaitForMultipleObjects(
    count: DWORD,
    handles: [*]const HANDLE,
    wait_all: BOOL,
    milliseconds: DWORD,
) callconv(.winapi) DWORD;
/// https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-getoverlappedresult
pub extern "kernel32" fn GetOverlappedResult(
    file: HANDLE,
    overlapped: *OVERLAPPED,
    transferred: *DWORD,
    wait: BOOL,
) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-connectnamedpipe
pub extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-disconnectnamedpipe
pub extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeclientprocessid
pub extern "kernel32" fn GetNamedPipeClientProcessId(pipe: HANDLE, process_id: *DWORD) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid
pub extern "kernel32" fn GetNamedPipeServerProcessId(pipe: HANDLE, process_id: *DWORD) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-waitnamedpipew
pub extern "kernel32" fn WaitNamedPipeW(name: LPCWSTR, timeout_ms: DWORD) callconv(.winapi) BOOL;
/// CreateFileW's flags for a pipe client's security quality of service: the
/// level at which the server may act as it, here SecurityIdentification
/// shifted into place
/// (https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
pub const SECURITY_SQOS_PRESENT: DWORD = 0x0010_0000;
pub const SECURITY_IDENTIFICATION: DWORD = 0x0001_0000;
/// For tests, which check that level.
/// https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-impersonatenamedpipeclient
pub extern "advapi32" fn ImpersonateNamedPipeClient(pipe: HANDLE) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-reverttoself
pub extern "advapi32" fn RevertToSelf() callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openthreadtoken
pub extern "advapi32" fn OpenThreadToken(thread: HANDLE, access: DWORD, open_as_self: BOOL, token: *HANDLE) callconv(.winapi) BOOL;
/// SECURITY_IMPERSONATION_LEVEL (winnt.h).
pub const SECURITY_IMPERSONATION_LEVEL = enum(c_int) {
    SecurityAnonymous = 0,
    SecurityIdentification = 1,
    SecurityImpersonation = 2,
    SecurityDelegation = 3,
    _,
};
/// For tests, which need a user other than their own.
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createwellknownsid
pub extern "advapi32" fn CreateWellKnownSid(kind: c_int, domain: ?PSID, sid: ?*anyopaque, size: *DWORD) callconv(.winapi) BOOL;
/// WELL_KNOWN_SID_TYPE (winnt.h).
pub const WinLocalSystemSid: c_int = 22;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
/// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess
pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, process_id: DWORD) callconv(.winapi) ?HANDLE;
/// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-processidtosessionid
pub extern "kernel32" fn ProcessIdToSessionId(process_id: DWORD, session_id: *DWORD) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-localfree
pub extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const PSID = *anyopaque;
pub const PSECURITY_DESCRIPTOR = *anyopaque;
pub const TOKEN_QUERY: DWORD = 0x0008;
/// https://learn.microsoft.com/en-us/windows/win32/api/winnt/ne-winnt-token_information_class
pub const TOKEN_INFORMATION_CLASS = enum(c_int) {
    TokenUser = 1,
    TokenImpersonationLevel = 9,
    TokenSessionId = 12,
    TokenElevation = 20,
    TokenIntegrityLevel = 25,
};
pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: PSID,
    Attributes: DWORD,
};
pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};
pub const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: DWORD,
};
pub const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};
/// Integrity levels, each the last sub-authority of a mandatory label's
/// SID, `S-1-16-<level>` (winnt.h).
pub const SECURITY_MANDATORY_LOW_RID: DWORD = 0x1000;
pub const SECURITY_MANDATORY_MEDIUM_RID: DWORD = 0x2000;
/// The longest SID, in bytes (winnt.h).
pub const SECURITY_MAX_SID_SIZE = 68;
pub const SDDL_REVISION_1: DWORD = 1;
/// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken
pub extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation
pub extern "advapi32" fn GetTokenInformation(
    token: HANDLE,
    class: TOKEN_INFORMATION_CLASS,
    information: ?*anyopaque,
    length: DWORD,
    return_length: *DWORD,
) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-isvalidsid
pub extern "advapi32" fn IsValidSid(sid: PSID) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getlengthsid
pub extern "advapi32" fn GetLengthSid(sid: PSID) callconv(.winapi) DWORD;
/// https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertsidtostringsidw
pub extern "advapi32" fn ConvertSidToStringSidW(sid: PSID, string: *?[*:0]u16) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertstringsecuritydescriptortosecuritydescriptorw
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    string: LPCWSTR,
    revision: DWORD,
    descriptor: *?PSECURITY_DESCRIPTOR,
    size: ?*DWORD,
) callconv(.winapi) BOOL;
/// A pipe's owner and integrity label (`IpcClient.checkPipe`), and in
/// tests the rest of its security.
/// https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo
pub extern "advapi32" fn GetSecurityInfo(
    handle: HANDLE,
    object_type: c_int,
    information: DWORD,
    owner: ?*?PSID,
    group: ?*?PSID,
    dacl: ?*?*ACL,
    sacl: ?*?*ACL,
    descriptor: ?*?PSECURITY_DESCRIPTOR,
) callconv(.winapi) DWORD;
/// SE_OBJECT_TYPE (accctrl.h).
pub const SE_FILE_OBJECT: c_int = 1;
pub const SE_KERNEL_OBJECT: c_int = 6;
pub const OWNER_SECURITY_INFORMATION: DWORD = 0x0000_0001;
pub const DACL_SECURITY_INFORMATION: DWORD = 0x0000_0004;
/// With DACL_SECURITY_INFORMATION in SetSecurityInfo: the DACL given
/// inherits nothing from the parent, or may (winnt.h).
pub const PROTECTED_DACL_SECURITY_INFORMATION: DWORD = 0x8000_0000;
pub const UNPROTECTED_DACL_SECURITY_INFORMATION: DWORD = 0x2000_0000;
/// A replaced file's DACL, given to the file an export replaces it with
/// (`App.writeExport`).
/// https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo
pub extern "advapi32" fn SetSecurityInfo(
    handle: HANDLE,
    object_type: c_int,
    information: DWORD,
    owner: ?PSID,
    group: ?PSID,
    dacl: ?*ACL,
    sacl: ?*ACL,
) callconv(.winapi) DWORD;
/// https://learn.microsoft.com/en-us/windows/win32/api/sddl/nf-sddl-convertsecuritydescriptortostringsecuritydescriptorw
pub extern "advapi32" fn ConvertSecurityDescriptorToStringSecurityDescriptorW(
    descriptor: PSECURITY_DESCRIPTOR,
    revision: DWORD,
    information: DWORD,
    string: *?[*:0]u16,
    length: ?*DWORD,
) callconv(.winapi) BOOL;
/// The same file again, with other access: WRITE_DAC on a file std made
/// for writing.
/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-reopenfile
pub extern "kernel32" fn ReOpenFile(
    original: HANDLE,
    access: DWORD,
    share: DWORD,
    flags: DWORD,
) callconv(.winapi) HANDLE;
/// https://learn.microsoft.com/en-us/windows/win32/secauthz/standard-access-rights
pub const WRITE_DAC: DWORD = 0x0004_0000;
/// The object's mandatory label, which READ_CONTROL lets a process read
/// though it is in the SACL
/// (https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information).
pub const LABEL_SECURITY_INFORMATION: DWORD = 0x0000_0010;
pub const ACL = opaque {};
pub const ACL_SIZE_INFORMATION = extern struct {
    AceCount: DWORD,
    AclBytesInUse: DWORD,
    AclBytesFree: DWORD,
};
/// ACL_INFORMATION_CLASS (winnt.h).
pub const AclSizeInformation: c_int = 2;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getaclinformation
pub extern "advapi32" fn GetAclInformation(
    acl: *ACL,
    information: *anyopaque,
    length: DWORD,
    class: c_int,
) callconv(.winapi) BOOL;
pub const ACE_HEADER = extern struct {
    AceType: BYTE,
    AceFlags: BYTE,
    AceSize: u16,
};
pub const ACCESS_ALLOWED_ACE = extern struct {
    Header: ACE_HEADER,
    Mask: DWORD,
    SidStart: DWORD,
};
pub const ACCESS_ALLOWED_ACE_TYPE: BYTE = 0;
pub const SYSTEM_MANDATORY_LABEL_ACE = extern struct {
    Header: ACE_HEADER,
    Mask: DWORD,
    SidStart: DWORD,
};
pub const SYSTEM_MANDATORY_LABEL_ACE_TYPE: BYTE = 0x11;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getace
pub extern "advapi32" fn GetAce(acl: *ACL, index: DWORD, ace: *?*anyopaque) callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getsecuritydescriptorcontrol
pub extern "advapi32" fn GetSecurityDescriptorControl(
    descriptor: PSECURITY_DESCRIPTOR,
    control: *u16,
    revision: *DWORD,
) callconv(.winapi) BOOL;
pub const SE_DACL_PROTECTED: u16 = 0x1000;
/// https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getsecuritydescriptordacl
pub extern "advapi32" fn GetSecurityDescriptorDacl(
    descriptor: PSECURITY_DESCRIPTOR,
    present: *BOOL,
    dacl: *?*ACL,
    defaulted: *BOOL,
) callconv(.winapi) BOOL;

// The overlays (Overlays.zig): windows of our own that the pointer passes
// through to the terminal under them, placed just above that one.

/// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nchittest
pub const WM_NCHITTEST: UINT = 0x0084;
/// WM_NCHITTEST: the message is sent on to the windows under this one in
/// the same thread, until one of them returns another code.
pub const HTTRANSPARENT: LRESULT = -1;
/// https://learn.microsoft.com/en-us/windows/win32/gdi/wm-printclient
pub const WM_PRINTCLIENT: UINT = 0x0318;
/// WM_PRINTCLIENT: draw the client area.
pub const PRF_CLIENT: LPARAM = 0x0004;

// A terminal's scroll bar (ScrollBar.zig): the window's own vertical scroll
// bar, WS_VSCROLL, and the loops DefWindowProcW runs for it.

/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-scrollinfo
pub const SCROLLINFO = extern struct {
    cbSize: UINT = @sizeOf(SCROLLINFO),
    fMask: UINT,
    nMin: c_int = 0,
    nMax: c_int = 0,
    nPage: UINT = 0,
    nPos: c_int = 0,
    nTrackPos: c_int = 0,
};
/// SCROLLINFO's members to set or read.
pub const SIF_RANGE: UINT = 0x0001;
pub const SIF_PAGE: UINT = 0x0002;
pub const SIF_POS: UINT = 0x0004;
/// SetScrollInfo: a bar its new range makes needless is disabled, not
/// removed.
pub const SIF_DISABLENOSCROLL: UINT = 0x0008;
pub const SIF_TRACKPOS: UINT = 0x0010;
pub const SIF_ALL: UINT = SIF_RANGE | SIF_PAGE | SIF_POS | SIF_TRACKPOS;
/// The window's own vertical scroll bar.
pub const SB_VERT: c_int = 1;
/// WM_VSCROLL's request, the low word of wParam.
/// https://learn.microsoft.com/en-us/windows/win32/controls/wm-vscroll
pub const SB_LINEUP: u16 = 0;
pub const SB_LINEDOWN: u16 = 1;
pub const SB_PAGEUP: u16 = 2;
pub const SB_PAGEDOWN: u16 = 3;
pub const SB_THUMBPOSITION: u16 = 4;
pub const SB_THUMBTRACK: u16 = 5;
pub const SB_TOP: u16 = 6;
pub const SB_BOTTOM: u16 = 7;
pub const SB_ENDSCROLL: u16 = 8;
/// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setscrollinfo
pub extern "user32" fn SetScrollInfo(hwnd: HWND, bar: c_int, info: *const SCROLLINFO, redraw: BOOL) callconv(.winapi) c_int;
pub extern "user32" fn GetScrollInfo(hwnd: HWND, bar: c_int, info: *SCROLLINFO) callconv(.winapi) BOOL;
/// WM_SYSCOMMAND's scroll bar commands, under SC_MASK.
pub const SC_VSCROLL: WPARAM = 0xF070;
pub const SC_HSCROLL: WPARAM = 0xF080;
/// WM_NCHITTEST: on the vertical scroll bar.
pub const HTVSCROLL: u16 = 7;
/// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nclbuttondown
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
/// https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nclbuttondblclk
pub const WM_NCLBUTTONDBLCLK: UINT = 0x00A3;
/// https://learn.microsoft.com/en-us/windows/win32/menurc/wm-contextmenu
pub const WM_CONTEXTMENU: UINT = 0x007B;
/// The width of a vertical scroll bar.
pub const SM_CXVSCROLL: c_int = 2;
/// Ends a scroll bar's tracking and a menu's loop, and releases the
/// capture (DefWindowProcW).
/// https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-cancelmode
pub const WM_CANCELMODE: UINT = 0x001F;
pub extern "user32" fn EndMenu() callconv(.winapi) BOOL;
/// https://learn.microsoft.com/en-us/windows/win32/gdi/wm-print
pub const WM_PRINT: UINT = 0x0317;
/// WM_PRINT: draw the non-client area.
pub const PRF_NONCLIENT: LPARAM = 0x0002;

comptime {
    // The SDK's sizes on 64-bit Windows.
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(DRAWITEMSTRUCT) == 64);
        std.debug.assert(@sizeOf(MEASUREITEMSTRUCT) == 32);
        std.debug.assert(@sizeOf(TOOLINFOW) == 72);
        std.debug.assert(@sizeOf(MSG) == 48);
        std.debug.assert(@sizeOf(FLASHWINFO) == 32);
    }
    std.debug.assert(@sizeOf(SCROLLINFO) == 28);
}

/// The RGB macro of wingdi.h.
pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

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
