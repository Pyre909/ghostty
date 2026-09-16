//! Application runtime for Windows, built directly on the Win32 API
//! (user32/gdi32) with an OpenGL context supplied by WGL.
//!
//! ## What this is
//!
//! This is a *foundation*, and the doc comments below are written to say so
//! plainly rather than to imply more than exists:
//!
//!   * `App` owns the process lifecycle: the Win32 message loop, a
//!     message-only window used as the wakeup and timer target, the loaded
//!     configuration, and the WGL entry points harvested from a bootstrap
//!     context.
//!   * `Surface` owns an `HWND`, its `HDC` and a real OpenGL 4.3 core-profile
//!     `HGLRC`. It also *reserves storage* for a `CoreSurface` by value, as
//!     the apprt contract requires, but that storage has **not** been through
//!     `CoreSurface.init` and `core()` therefore returns memory that is not
//!     yet a terminal.
//!
//! The reason is a single hard edge: `renderer.Renderer` for a Windows exe is
//! `GenericRenderer(OpenGL)` (src/renderer.zig), and `src/renderer/OpenGL.zig`
//! is unconditionally EGL — it calls `egl.load()` and `egl.Display.init` in
//! `init`. There is no libEGL on Windows. Zig only analyzes function bodies it
//! reaches, so naming the `CoreSurface` type is free while *calling*
//! `CoreSurface.init` would pull `eglGetProcAddress` into the link. A WGL
//! renderer backend is the next project; until it lands, this runtime creates
//! windows and contexts but hosts no terminal.
//!
//! ## What that means for the contract
//!
//! Every method the core calls on an apprt is implemented here for real,
//! against Win32, not stubbed. Most of them are structurally unreachable today
//! because their only caller is a `CoreSurface` that is never initialized;
//! they are still written and still type-checked (see the `comptime` block at
//! the bottom of this file, which exists precisely because Zig would otherwise
//! never analyze them).
//!
//! Actions are refused honestly: `performAction` names the actions it really
//! performs and returns `false` for everything else. It never claims an action
//! it did not carry out.

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
// import library named by an `extern "user32"`-style declaration, which is why
// src/build/SharedDeps.zig's explicit `linkSystemLibrary` calls are redundant
// for correctness but load-bearing for `opengl32` ordering.
// -------------------------------------------------------------------------
const win32 = struct {
    const w = std.os.windows;

    const BOOL = w.BOOL;
    const BYTE = w.BYTE;
    const WORD = w.WORD;
    const DWORD = w.DWORD;
    const UINT = w.UINT;
    const LONG = w.LONG;
    const WCHAR = w.WCHAR;
    const LPCWSTR = w.LPCWSTR;
    const HANDLE = w.HANDLE;
    const HWND = w.HWND;
    const HDC = w.HDC;
    const HGLRC = w.HGLRC;
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

    const WNDPROC = *const fn (
        hwnd: HWND,
        msg: UINT,
        wparam: WPARAM,
        lparam: LPARAM,
    ) callconv(.winapi) LRESULT;

    const POINT = extern struct { x: LONG, y: LONG };
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

    const PIXELFORMATDESCRIPTOR = extern struct {
        nSize: WORD,
        nVersion: WORD,
        dwFlags: DWORD,
        iPixelType: BYTE,
        cColorBits: BYTE,
        cRedBits: BYTE,
        cRedShift: BYTE,
        cGreenBits: BYTE,
        cGreenShift: BYTE,
        cBlueBits: BYTE,
        cBlueShift: BYTE,
        cAlphaBits: BYTE,
        cAlphaShift: BYTE,
        cAccumBits: BYTE,
        cAccumRedBits: BYTE,
        cAccumGreenBits: BYTE,
        cAccumBlueBits: BYTE,
        cAccumAlphaBits: BYTE,
        cDepthBits: BYTE,
        cStencilBits: BYTE,
        cAuxBuffers: BYTE,
        iLayerType: BYTE,
        bReserved: BYTE,
        dwLayerMask: DWORD,
        dwVisibleMask: DWORD,
        dwDamageMask: DWORD,
    };

    const PAINTSTRUCT = extern struct {
        hdc: ?HDC,
        fErase: BOOL,
        rcPaint: RECT,
        fRestore: BOOL,
        fIncUpdate: BOOL,
        rgbReserved: [32]BYTE,
    };

    // Window class styles. CS_OWNDC is required: a WGL context is bound to the
    // device context it was created against, so the window must keep one DC
    // for its whole life instead of handing out a fresh one per GetDC.
    const CS_VREDRAW: UINT = 0x0001;
    const CS_HREDRAW: UINT = 0x0002;
    const CS_OWNDC: UINT = 0x0020;

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
    const WM_CLOSE: UINT = 0x0010;
    const WM_QUIT: UINT = 0x0012;
    const WM_ERASEBKGND: UINT = 0x0014;
    const WM_PAINT: UINT = 0x000F;
    const WM_NCCREATE: UINT = 0x0081;
    const WM_TIMER: UINT = 0x0113;
    const WM_DPICHANGED: UINT = 0x02E0;
    const WM_APP: UINT = 0x8000;

    const PM_REMOVE: UINT = 0x0001;

    const SWP_NOZORDER: UINT = 0x0004;
    const SWP_NOACTIVATE: UINT = 0x0010;

    const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

    const CF_UNICODETEXT: UINT = 13;
    const GMEM_MOVEABLE: UINT = 0x0002;

    const MB_OKCANCEL: UINT = 0x00000001;
    const MB_ICONWARNING: UINT = 0x00000030;
    const IDOK: c_int = 1;

    const MB_ICONASTERISK: UINT = 0x00000040;

    // Pixel format descriptor flags/values.
    const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
    const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
    const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
    const PFD_TYPE_RGBA: BYTE = 0;
    const PFD_MAIN_PLANE: BYTE = 0;

    // WGL_ARB_create_context / _profile attribute names.
    const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
    const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
    const WGL_CONTEXT_FLAGS_ARB: c_int = 0x2094;
    const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
    const WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB: c_int = 0x0002;
    const WGL_CONTEXT_DEBUG_BIT_ARB: c_int = 0x0001;
    const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x00000001;

    const GL_COLOR_BUFFER_BIT: c_uint = 0x00004000;

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

    const PFNWGLCREATECONTEXTATTRIBSARB = *const fn (
        hdc: HDC,
        share: ?HGLRC,
        attribs: [*]const c_int,
    ) callconv(.winapi) ?HGLRC;

    extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
    extern "kernel32" fn LoadLibraryW(name: LPCWSTR) callconv(.winapi) ?HINSTANCE;
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
    extern "user32" fn GetCursorPos(pt: *POINT) callconv(.winapi) BOOL;
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
    extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: LPCWSTR) callconv(.winapi) ?HCURSOR;
    extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn InvalidateRect(
        hwnd: ?HWND,
        rect: ?*const RECT,
        erase: BOOL,
    ) callconv(.winapi) BOOL;
    extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
    extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
    extern "user32" fn SetTimer(
        hwnd: ?HWND,
        id: UINT_PTR,
        elapse_ms: UINT,
        proc: ?*const anyopaque,
    ) callconv(.winapi) UINT_PTR;
    extern "user32" fn KillTimer(hwnd: ?HWND, id: UINT_PTR) callconv(.winapi) BOOL;
    extern "user32" fn ShowCursor(show: BOOL) callconv(.winapi) c_int;
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

    extern "gdi32" fn ChoosePixelFormat(
        hdc: HDC,
        pfd: *const PIXELFORMATDESCRIPTOR,
    ) callconv(.winapi) c_int;
    extern "gdi32" fn SetPixelFormat(
        hdc: HDC,
        format: c_int,
        pfd: *const PIXELFORMATDESCRIPTOR,
    ) callconv(.winapi) BOOL;
    extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
    extern "gdi32" fn GetDeviceCaps(hdc: HDC, index: c_int) callconv(.winapi) c_int;

    extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
    extern "opengl32" fn wglDeleteContext(ctx: HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, ctx: ?HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

    // OpenGL 1.1 entry points are exported by opengl32.dll directly (unlike
    // anything newer, which must come through wglGetProcAddress). These three
    // are all the foundation needs to prove the context is live.
    extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
    extern "opengl32" fn glClear(mask: c_uint) callconv(.winapi) void;
    extern "opengl32" fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.winapi) void;
};

/// UTF-16 string literal helper for the many `LPCWSTR` constants below.
fn L(comptime s: []const u8) win32.LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Window class names. These are process-global, so they are registered once
/// in `App.init` and unregistered in `App.terminate`.
const surface_class_name = "GhosttySurfaceClass";
const app_class_name = "GhosttyAppClass";
const bootstrap_class_name = "GhosttyWglBootstrapClass";

/// Posted by `App.wakeup` from arbitrary threads to break `GetMessageW` out of
/// its block so `run` reaches the next `core_app.tick`.
const WM_GHOSTTY_WAKEUP: win32.UINT = win32.WM_APP + 1;

/// Timer id for the quit-after-last-window timer on the app's message-only
/// window. Any non-zero value works; it only has to be unique per window.
const quit_timer_id: win32.UINT_PTR = 1;

pub const App = struct {
    core_app: *CoreApp,

    /// The configuration. Owned by this struct, freed in `terminate`.
    ///
    /// This exists because the app-scoped key path (`CoreApp.keyEvent`,
    /// src/App.zig:359) reads `rt_app.config.keybind`. Nothing routes keys yet
    /// (there is no CoreSurface to route them to), but the field is part of
    /// the documented rt_app contract and `terminate` must own its lifetime.
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

    /// Harvested from the bootstrap context in `init`. Null means the driver
    /// does not advertise WGL_ARB_create_context, in which case no modern
    /// context can be created and surfaces fail loudly rather than silently
    /// running on a 1.1 compatibility context.
    create_context_attribs: ?win32.PFNWGLCREATECONTEXTATTRIBSARB,

    /// The windows this runtime owns. These are foundation windows: they hold
    /// an HWND and a GL context but no initialized CoreSurface, so they are
    /// deliberately *not* registered with `CoreApp.addSurface`.
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

    /// Whether this runtime currently has the cursor hidden.
    ///
    /// ShowCursor keeps a counter per input queue, not a flag per window, so
    /// an unbalanced hide outlives the window that asked for it and leaves the
    /// cursor invisible for the rest of the session. Tracking the state here
    /// keeps the counter in {0, -1} and lets teardown unwind it.
    cursor_hidden: bool,

    pub const Error = error{
        Win32ClassRegistrationFailed,
        Win32WindowCreationFailed,
        Win32MessageLoopFailed,
        /// A Win32 call that should not fail for a live window did.
        Win32CallFailed,
        WglBootstrapFailed,
        WglContextCreationFailed,
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

        // Make opengl32.dll resident before anything can call SetPixelFormat.
        // The ICD is only hooked into a window's pixel format if opengl32.dll
        // is already loaded at that point; otherwise wglCreateContext fails
        // with ERROR_INVALID_PIXEL_FORMAT (2000). SharedDeps.addWin32 links
        // the import library for the same reason, which makes this redundant
        // in a normal build -- it is spelled out anyway so the ordering
        // survives a build-system change that drops the explicit link.
        _ = win32.LoadLibraryW(L("opengl32.dll"));

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
            .create_context_attribs = bootstrapWgl(hinstance),
            .surfaces = .empty,
            .quit = false,
            .quit_timer_active = false,
            .quit_pending = false,
            .cursor_hidden = false,
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
            surface.destroy();
            surface.deinit();
            self.core_app.alloc.destroy(surface);
        }

        if (self.quit_timer_active) {
            _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
            self.quit_timer_active = false;
        }

        // Unwind an outstanding cursor hide. ShowCursor's counter belongs to
        // the input queue, not to the process, so leaving it negative would
        // outlive us in a terminal that launched this one.
        self.showCursor();

        _ = win32.DestroyWindow(self.msg_hwnd);
        unregisterClasses(self.hinstance);
        self.config.deinit();
    }

    /// The Win32 message loop.
    pub fn run(self: *App) !void {
        // Create the foundation window.
        //
        // In a complete runtime this belongs in the `.new_window` action,
        // driven by `CoreApp.newWindow` through the mailbox. That path needs
        // `CoreSurface.init`, which this build cannot call (see the module
        // doc comment), so the initial window is created directly here and
        // `.new_window` is refused. When the WGL renderer backend lands, this
        // block moves into `performAction`.
        if (self.config.@"initial-window") {
            _ = self.newSurface() catch |err| {
                log.err("failed to create the initial window err={}", .{err});
                return err;
            };
        }

        var msg: win32.MSG = undefined;
        while (!self.quit) {
            // Act on a recorded zero-delay quit here rather than where it was
            // recorded (see `quit_pending`): only here is it known both that
            // the loop has started and that no window is on screen.
            if (self.quit_pending and self.surfaces.items.len == 0) {
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
            try self.core_app.tick(self);
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
            .mouse_visibility => self.mouseVisibility(value),

            .ring_bell => ring_bell: {
                _ = win32.MessageBeep(win32.MB_ICONASTERISK);
                break :ring_bell true;
            },

            // Everything else, including `.new_window` (no CoreSurface can be
            // hosted yet) and `.open_url` (whose `false` is a supported path:
            // src/Surface.zig:4471 falls back to internal_os.open).
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
            // Ask the window manager to close it. The actual teardown
            // happens on WM_DESTROY so that every close path -- the title bar
            // button, Alt+F4 and this action -- converges. DestroyWindow's
            // BOOL is a real success flag, so it is what gets reported.
            .surface => |v| win32.DestroyWindow(v.rt_surface.hwnd).toBool(),
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

    fn render(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| win32.InvalidateRect(v.rt_surface.hwnd, null, .FALSE).toBool(),
        };
    }

    fn mouseVisibility(self: *App, value: apprt.action.MouseVisibility) bool {
        // ShowCursor maintains a counter, not a flag. The core does send this
        // action only on transitions -- hideMouse/showMouse both guard on
        // `self.mouse.hidden` (src/Surface.zig:4791-4812) -- but that balances
        // hides and shows *per surface*, while the counter belongs to the
        // whole input queue. A surface destroyed while it had the cursor
        // hidden would never send the matching `.visible`. Mirroring the state
        // here keeps the counter in {0, -1} and gives teardown something to
        // unwind (see showCursor).
        const hide = value == .hidden;
        if (hide == self.cursor_hidden) return true;
        self.cursor_hidden = hide;
        _ = win32.ShowCursor(.fromBool(!hide));
        return true;
    }

    /// Undo an outstanding cursor hide. A no-op when nothing is hidden.
    fn showCursor(self: *App) void {
        if (!self.cursor_hidden) return;
        self.cursor_hidden = false;
        _ = win32.ShowCursor(.fromBool(true));
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
                // `.new_window` is refused by this runtime -- no CoreSurface
                // can be hosted yet -- so a process that reaches zero windows
                // has no UI left and no way to get one back. Honoring `false`
                // would leave an invisible process with a message-only window
                // that receives nothing and a GetMessageW that blocks forever,
                // endable only from Task Manager.
                //
                // Delete this override -- not the config read -- as soon as
                // `.new_window` can actually create a window.
                if (!self.config.@"quit-after-last-window-closed") {
                    log.info(
                        "quitting despite quit-after-last-window-closed=false: " ++
                            "this runtime cannot open a new window",
                        .{},
                    );
                }

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

    /// Create a foundation window. See `run` for why this is not driven by
    /// the `.new_window` action.
    fn newSurface(self: *App) !*Surface {
        const alloc = self.core_app.alloc;
        try self.surfaces.ensureUnusedCapacity(alloc, 1);

        const surface = try Surface.create(self);

        // No errdefer between here and the return: appendAssumeCapacity cannot
        // fail (the capacity was reserved above) and setQuitTimer returns
        // rather than errors, so one would be dead code -- and a dead errdefer
        // that calls only `destroy()` would leak the allocation anyway, since
        // surfaceDestroyed declines to free a surface that is not yet in the
        // list.
        self.surfaces.appendAssumeCapacity(surface);

        // The core cancels the quit timer from addSurface (src/App.zig:202).
        // These windows are deliberately not registered with the core, so the
        // cancel has to happen here; without it the startup timer outlives the
        // window it was waiting for and the app quits with a terminal on
        // screen.
        _ = self.setQuitTimer(.stop);

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

        if (self.surfaces.items.len == 0) {
            // A hide owned by a window that no longer exists can never be
            // undone by the core, and ShowCursor's counter is per input queue.
            self.showCursor();

            // The core normally drives quit_timer through
            // addSurface/deleteSurface. These windows are not registered with
            // the core, so the apprt applies the policy itself.
            _ = self.setQuitTimer(.start);
        }
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
            // Nothing to do but return: the message existing is the point.
            // `run` ticks the core after every dispatched message.
            WM_GHOSTTY_WAKEUP => return 0,

            win32.WM_TIMER => if (wparam == quit_timer_id) {
                _ = win32.KillTimer(hwnd, quit_timer_id);
                self.quit_timer_active = false;
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

    /// Storage for the core surface, embedded by value because the core
    /// requires `core()` to return `&self.core_surface` and because
    /// `apprt.Target.cval` round-trips through `rt_surface`.
    ///
    /// **This storage is `undefined`.** Nothing calls `CoreSurface.init` yet;
    /// see the module doc comment. It is reserved rather than omitted so the
    /// shape of this struct does not have to change when the renderer lands.
    core_surface: CoreSurface,

    /// The window handle. Written from WM_NCCREATE, which is the first
    /// message this window receives, so it is valid in every other handler.
    hwnd: win32.HWND,

    /// The window's own DC (CS_OWNDC), valid for the window's lifetime and
    /// never released, and the GL context bound to it.
    ///
    /// Both are optional because the window procedure starts running *inside*
    /// CreateWindowExW, before either exists: WM_SIZE and WM_PAINT can arrive
    /// while `create` is still between CreateWindowExW and createContext.
    hdc: ?win32.HDC,
    hglrc: ?win32.HGLRC,

    /// The current window title, owned by this struct. `getTitle` reads it
    /// back to answer CSI 21 t; a native runtime has to store it itself.
    title: ?[:0]u8,

    /// Tracked so `.toggle_maximize` knows which way to toggle.
    maximized: bool,

    /// Heap-allocate and initialize. The address must be stable: the core
    /// stores raw `*apprt.Surface` pointers (src/Surface.zig:465-466), and the
    /// wndproc recovers this pointer from GWLP_USERDATA.
    fn create(app: *App) !*Surface {
        const alloc = app.core_app.alloc;
        const self = try alloc.create(Surface);
        errdefer alloc.destroy(self);

        self.* = .{
            .app = app,
            .core_surface = undefined,
            // `hwnd` is written from WM_NCCREATE, the first message this
            // window receives, so it is set before anything can read it.
            .hwnd = undefined,
            .hdc = null,
            .hglrc = null,
            .title = null,
            .maximized = false,
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

        // CS_OWNDC means this DC belongs to the window for its whole life.
        const hdc = win32.GetDC(hwnd) orelse return App.Error.Win32WindowCreationFailed;
        self.hdc = hdc;
        self.hglrc = try createContext(app, hdc);

        _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);
        _ = win32.UpdateWindow(hwnd);

        return self;
    }

    /// Release everything except the allocation itself.
    ///
    /// Public because `CoreApp.deinit` calls it on every surface the core
    /// still tracks (src/App.zig:134) -- an apprt contract method the
    /// rt_surface list does not name.
    pub fn deinit(self: *Surface) void {
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.title = null;
    }

    /// Tear down the OS window. The allocation itself is not freed here; see
    /// the ownership invariant on `App.surfaceDestroyed`.
    fn destroy(self: *Surface) void {
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Release the GL context. Called from WM_DESTROY, before the HWND dies.
    fn releaseContext(self: *Surface) void {
        const hglrc = self.hglrc orelse return;
        self.hglrc = null;

        // Unbind before deleting: wglDeleteContext on a context that is still
        // current only marks it for deletion.
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(hglrc);
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
    pub fn close(self: *const Surface, process_alive: bool) void {
        // Read before the prompt, deliberately. `confirm` runs a nested modal
        // loop; a message dispatched inside it that reaches this window's
        // WM_DESTROY frees `self`, and every field read after that point would
        // be a use-after-free. The HWND stays valid because DestroyWindow on
        // an already-destroyed window fails harmlessly.
        const hwnd = self.hwnd;

        if (process_alive) {
            const ok = confirm(
                hwnd,
                L("A process is still running in this terminal. Close it anyway?"),
            );
            if (!ok) return;
        }

        _ = win32.DestroyWindow(hwnd);
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
        if (self.hdc) |hdc| {
            const v = win32.GetDeviceCaps(hdc, win32.LOGPIXELSX);
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

    /// Cursor position in client-relative physical pixels. Negative values are
    /// meaningful: the core reads them as "outside the viewport"
    /// (src/Surface.zig:4575), so they are passed through unclamped.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        var pt: win32.POINT = undefined;
        if (!win32.GetCursorPos(&pt).toBool()) return App.Error.Win32CallFailed;
        if (!win32.ScreenToClient(self.hwnd, &pt).toBool()) {
            return App.Error.Win32CallFailed;
        }

        return .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) };
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
            // pumping, but `core_app.tick` does not -- it runs only in `run`'s
            // loop -- so the mailbox goes undrained for as long as the prompt
            // is up and renderer and IO messages stall behind it. The same
            // reentrancy is a memory hazard: a dispatched message that reaches
            // this window's WM_DESTROY frees `self`, and the
            // completeClipboardRequest calls below would then run against freed
            // memory. MessageBoxW disabling its owner window makes that hard to
            // reach, not impossible. Both problems go away when this becomes an
            // in-window prompt driven from the core's own confirmation UI.
            error.UnsafePaste, error.UnauthorizedPaste => {
                if (confirm(
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

    /// Paint. Without a renderer there is nothing to draw, so the foundation
    /// clears to the configured background. This is not a placeholder for the
    /// renderer -- it is the cheapest proof that the WGL context is live, and
    /// it goes away when the renderer takes over presentation.
    fn paint(self: *Surface) void {
        // BeginPaint/EndPaint must bracket every WM_PAINT even when we draw
        // nothing: they clear the update region, and without them Windows
        // re-posts WM_PAINT forever and the loop spins at 100% CPU.
        var ps: win32.PAINTSTRUCT = undefined;
        _ = win32.BeginPaint(self.hwnd, &ps);
        defer _ = win32.EndPaint(self.hwnd, &ps);

        // A paint can arrive from inside CreateWindowExW, before the context
        // exists. Nothing to do then; the window is repainted after create.
        const hdc = self.hdc orelse return;
        const hglrc = self.hglrc orelse return;

        if (!win32.wglMakeCurrent(hdc, hglrc).toBool()) {
            log.warn("wglMakeCurrent failed during paint", .{});
            return;
        }

        const size = self.getSize() catch return;
        win32.glViewport(0, 0, @intCast(size.width), @intCast(size.height));

        const bg = self.app.config.background;
        win32.glClearColor(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );
        win32.glClear(win32.GL_COLOR_BUFFER_BIT);
        _ = win32.SwapBuffers(hdc);
    }

    fn handleMessage(
        self: *Surface,
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) win32.LRESULT {
        switch (msg) {
            win32.WM_CLOSE => {
                // The core's close path (CoreSurface.close -> rt_surface.close)
                // handles the "process still running" confirmation. Without a
                // CoreSurface there is nothing to confirm, so this goes
                // straight to teardown.
                _ = win32.DestroyWindow(hwnd);
                return 0;
            },

            win32.WM_DESTROY => {
                // The GL context must die before its window does.
                self.releaseContext();
                self.app.surfaceDestroyed(self);
                return 0;
            },

            win32.WM_SIZE => {
                // This is where CoreSurface.sizeCallback goes
                // (src/Surface.zig:2502) once a core surface is hosted. Until
                // then a resize only needs a repaint.
                _ = win32.InvalidateRect(hwnd, null, .FALSE);
                return 0;
            },

            win32.WM_DPICHANGED => {
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
                // CoreSurface.contentScaleCallback (src/Surface.zig:3667) goes
                // here alongside the reposition.
                return 0;
            },

            win32.WM_PAINT => {
                self.paint();
                return 0;
            },

            // We paint every pixel of the client area in WM_PAINT, so letting
            // GDI erase first only produces a flash of the class background.
            win32.WM_ERASEBKGND => return 1,

            else => {},
        }

        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

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

fn registerClasses(hinstance: win32.HINSTANCE) !void {
    const arrow = win32.LoadCursorW(null, win32.IDC_ARROW);

    const surface_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        // CS_OWNDC is required for WGL: the context is bound to the DC it was
        // created against, so the window must own one DC permanently.
        .style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,
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
    errdefer _ = win32.UnregisterClassW(L(app_class_name), hinstance);

    // SetPixelFormat can only ever be called once per HWND, so the legacy
    // bootstrap context needs a window that is thrown away afterwards. It gets
    // its own class only so that CS_OWNDC applies to it too.
    const bootstrap_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_OWNDC,
        .lpfnWndProc = &win32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(bootstrap_class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&bootstrap_class) == 0) {
        log.err("failed to register the WGL bootstrap window class", .{});
        return App.Error.Win32ClassRegistrationFailed;
    }
}

fn unregisterClasses(hinstance: win32.HINSTANCE) void {
    _ = win32.UnregisterClassW(L(bootstrap_class_name), hinstance);
    _ = win32.UnregisterClassW(L(app_class_name), hinstance);
    _ = win32.UnregisterClassW(L(surface_class_name), hinstance);
}

/// The pixel format every Ghostty window uses. 32-bit RGBA, double buffered,
/// no depth or stencil: a terminal draws flat.
const pixel_format: win32.PIXELFORMATDESCRIPTOR = .{
    .nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR),
    .nVersion = 1,
    .dwFlags = win32.PFD_DRAW_TO_WINDOW |
        win32.PFD_SUPPORT_OPENGL |
        win32.PFD_DOUBLEBUFFER,
    .iPixelType = win32.PFD_TYPE_RGBA,
    .cColorBits = 32,
    .cRedBits = 0,
    .cRedShift = 0,
    .cGreenBits = 0,
    .cGreenShift = 0,
    .cBlueBits = 0,
    .cBlueShift = 0,
    .cAlphaBits = 8,
    .cAlphaShift = 0,
    .cAccumBits = 0,
    .cAccumRedBits = 0,
    .cAccumGreenBits = 0,
    .cAccumBlueBits = 0,
    .cAccumAlphaBits = 0,
    .cDepthBits = 0,
    .cStencilBits = 0,
    .cAuxBuffers = 0,
    .iLayerType = win32.PFD_MAIN_PLANE,
    .bReserved = 0,
    .dwLayerMask = 0,
    .dwVisibleMask = 0,
    .dwDamageMask = 0,
};

/// Harvest wglCreateContextAttribsARB.
///
/// WGL has a chicken-and-egg problem: the function that creates a modern
/// context is itself an extension, and extension entry points can only be
/// resolved while some context is current. So a legacy 1.1 context is created
/// on a throwaway window, the pointer is read out, and the whole thing is torn
/// down. The window is throwaway because SetPixelFormat is one-shot per HWND.
///
/// It is a real (if 1x1 and never shown) top-level window rather than a
/// message-only one: a message-only window has no display device behind it, so
/// ChoosePixelFormat/SetPixelFormat have nothing to describe.
///
/// Returns null on any failure; the caller reports it when a surface actually
/// needs a context, rather than failing app startup for it.
fn bootstrapWgl(hinstance: win32.HINSTANCE) ?win32.PFNWGLCREATECONTEXTATTRIBSARB {
    const hwnd = win32.CreateWindowExW(
        0,
        L(bootstrap_class_name),
        null,
        // WS_OVERLAPPED, i.e. no style bits. Never shown, so never visible.
        0,
        0,
        0,
        1,
        1,
        null,
        null,
        hinstance,
        null,
    ) orelse {
        log.warn("failed to create the WGL bootstrap window", .{});
        return null;
    };
    defer _ = win32.DestroyWindow(hwnd);

    const hdc = win32.GetDC(hwnd) orelse {
        log.warn("failed to get the WGL bootstrap DC", .{});
        return null;
    };

    const format = win32.ChoosePixelFormat(hdc, &pixel_format);
    if (format == 0) {
        log.warn("ChoosePixelFormat failed for the WGL bootstrap window", .{});
        return null;
    }
    if (!win32.SetPixelFormat(hdc, format, &pixel_format).toBool()) {
        log.warn("SetPixelFormat failed for the WGL bootstrap window", .{});
        return null;
    }

    const ctx = win32.wglCreateContext(hdc) orelse {
        // If this fails with ERROR_INVALID_PIXEL_FORMAT (2000), opengl32.dll
        // was not resident before SetPixelFormat and the ICD never got hooked
        // in. See App.init.
        log.warn("wglCreateContext failed for the bootstrap context", .{});
        return null;
    };
    defer _ = win32.wglDeleteContext(ctx);

    if (!win32.wglMakeCurrent(hdc, ctx).toBool()) {
        log.warn("wglMakeCurrent failed for the bootstrap context", .{});
        return null;
    }
    defer _ = win32.wglMakeCurrent(null, null);

    const proc = win32.wglGetProcAddress("wglCreateContextAttribsARB") orelse {
        log.warn("WGL_ARB_create_context is not available", .{});
        return null;
    };

    // wglGetProcAddress does not signal failure with NULL alone: the documented
    // failure values are 0, 1, 2, 3 and -1. `orelse` catches only the first of
    // those, and casting any of the rest to a function pointer turns the next
    // context creation into a call to address 1.
    switch (@intFromPtr(proc)) {
        1, 2, 3, std.math.maxInt(usize) => {
            log.warn("WGL_ARB_create_context is not available", .{});
            return null;
        },
        else => {},
    }

    // @alignCast is load-bearing, not decoration: wglGetProcAddress is typed
    // `*const anyopaque`, which is align(1), while a function pointer is
    // align(4) on AArch64 because its instructions are fixed-width and must be
    // 4-byte aligned. x86_64 has align(1) function pointers and hides this
    // entirely -- the aarch64-windows build is what catches it. Any address the
    // loader hands back for real code satisfies the assertion.
    return @ptrCast(@alignCast(proc));
}

/// Create the real context: OpenGL 4.3 core profile, which is what Ghostty's
/// shaders need (GLSL 4.30, SSBOs with std430, sampler2DRect,
/// ARB_vertex_attrib_binding).
fn createContext(app: *App, hdc: win32.HDC) !win32.HGLRC {
    const create = app.create_context_attribs orelse {
        log.err("cannot create a modern GL context: WGL_ARB_create_context missing", .{});
        return App.Error.WglBootstrapFailed;
    };

    const format = win32.ChoosePixelFormat(hdc, &pixel_format);
    if (format == 0) {
        log.err("ChoosePixelFormat failed", .{});
        return App.Error.WglContextCreationFailed;
    }
    if (!win32.SetPixelFormat(hdc, format, &pixel_format).toBool()) {
        log.err("SetPixelFormat failed", .{});
        return App.Error.WglContextCreationFailed;
    }

    const debug_bit: c_int = if (builtin.mode == .Debug)
        win32.WGL_CONTEXT_DEBUG_BIT_ARB
    else
        0;

    const attribs = [_]c_int{
        win32.WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
        win32.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
        win32.WGL_CONTEXT_PROFILE_MASK_ARB,  win32.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        win32.WGL_CONTEXT_FLAGS_ARB,         win32.WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB | debug_bit,
        0,
    };

    return create(hdc, null, &attribs) orelse {
        log.err("wglCreateContextAttribsARB failed for a 4.3 core context", .{});
        return App.Error.WglContextCreationFailed;
    };
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
fn confirm(hwnd: win32.HWND, text: win32.LPCWSTR) bool {
    return win32.MessageBoxW(
        hwnd,
        text,
        L("Ghostty"),
        win32.MB_OKCANCEL | win32.MB_ICONWARNING,
    ) == win32.IDOK;
}

comptime {
    // Zig only analyzes function bodies it reaches. Nothing in this build
    // reaches most of the apprt contract -- the rt_surface methods are called
    // only by a CoreSurface, and this runtime hosts none (see the module doc
    // comment) -- so without these references the contract would never be
    // type-checked and would rot silently against core changes.
    //
    // Guarded on the target because src/apprt.zig imports this file
    // unconditionally on every platform.
    if (builtin.os.tag == .windows) {
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
