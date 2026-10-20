//! A terminal window: the top-level frame, and what belongs to the window
//! rather than to a terminal -- its size, caption, maximize state, the size
//! Windows suggests on a DPI change, its system modal loops. The terminal is
//! a `Surface`, a child window filling the frame's client area; a window
//! holds exactly one. Splits will put several into one frame.
//!
//! Ownership, as for surfaces (`App.surfaceDestroyed`): membership in
//! `App.windows` is ownership of the allocation. The frame's WM_NCDESTROY,
//! which Windows sends after its child windows are destroyed, frees a
//! window that is in the list; one that is not yet (`create` failing) is
//! freed by `create` itself.

const Window = @This();

const std = @import("std");

const apprt = @import("../../apprt.zig");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;

const log = std.log.scoped(.win32);

/// The frame's window class, registered in `App.init`.
pub const class_name = "GhosttyWindowClass";

app: *App,

/// The frame. Written from WM_NCCREATE, the first message it receives, so
/// it is valid in every other handler.
hwnd: win32.HWND,

/// The terminal in this window: null until `create` has made it, and again
/// once it has been destroyed (`App.surfaceDestroyed`), which happens
/// before the frame is (see the ownership note above).
surface: ?*Surface,

/// Tracked so `.toggle_maximize` knows which way to toggle.
maximized: bool,

/// This window's share of `App.modal_loop_depth`; see `ModalLoops`.
modal_loops: ModalLoops,

/// Disabled by `App.beginPrompt` for a prompt in another window, for
/// `App.endPrompt` to enable again.
prompt_disabled: bool,

/// Create a window holding a new terminal, still hidden: `show` shows it
/// once the app owns both (`App.newWindow`). The frame is created at
/// CW_USEDEFAULT size so that the terminal, which fills it, starts with a
/// non-zero size (`CoreSurface.init` reads it).
pub fn create(app: *App, opts: Surface.Options) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .surface = null,
        .maximized = false,
        .modal_loops = .{},
        .prompt_disabled = false,
    };

    const hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        L("Ghostty"),
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed for a window frame", .{});
        return App.Error.Win32WindowCreationFailed;
    };
    // Safe alongside the errdefer above: WM_NCDESTROY frees only a window
    // that is in App.windows, which this one is not yet.
    errdefer _ = win32.DestroyWindow(hwnd);

    self.surface = try Surface.create(app, self, opts);
    return self;
}

/// Size the still-hidden frame to `window-width`/`window-height` and show
/// it. The first WM_SETFOCUS and WM_PAINT (and the first WM_SIZE, unless
/// the size already sent one) reach the terminal from here; its core is
/// live by now.
pub fn show(self: *Window) void {
    if (self.surface) |surface| {
        if (surface.initial_size) |size| {
            applyInitialSize(self.hwnd, (surface.getContentScale() catch unreachable).x, size);
        }
    }
    _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNORMAL);
    _ = win32.UpdateWindow(self.hwnd);
}

/// The frame's window procedure.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    // As in Surface.wndProc: WM_NCCREATE carries the CREATESTRUCTW, and
    // messages before it find no pointer and fall through.
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            const self: *Window = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self: *Window = ptr: {
        const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
    };
    return self.handleMessage(hwnd, msg, wparam, lparam);
}

fn handleMessage(
    self: *Window,
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    switch (msg) {
        // The title bar button, Alt+F4 when no binding consumed it, and the
        // window menu's Close: the window closes with its terminal.
        win32.WM_CLOSE => {
            if (self.app.terminating) return 0;
            if (self.surface) |surface| {
                surface.requestClose();
            } else {
                // Nothing left inside: frees `self` (WM_NCDESTROY).
                _ = win32.DestroyWindow(hwnd);
            }
            return 0;
        },

        win32.WM_SIZE => {
            const surface = self.surface orelse return 0;
            const minimized = wparam == win32.SIZE_MINIMIZED;
            // A child window is not resized when its frame is minimized
            // or restored at the same size, so it never sees either:
            // report the visibility from here. The core ignores repeats.
            surface.occlusionChanged(!minimized);

            // A minimized frame reports a 0x0 client area. The terminal
            // keeps its size, since the core clamps the grid to at least
            // 1x1 and would reflow every line to one column and back.
            if (minimized) return 0;

            // Fill the client area. SetWindowPos sends the terminal its
            // WM_SIZE synchronously, which resizes its core.
            var client: win32.RECT = undefined;
            if (!win32.GetClientRect(hwnd, &client).toBool()) return 0;
            _ = win32.SetWindowPos(
                surface.hwnd,
                null,
                0,
                0,
                client.right - client.left,
                client.bottom - client.top,
                win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
            );
            return 0;
        },

        win32.WM_DPICHANGED => {
            // The new scale first: the suggested rect below resizes the
            // terminal synchronously, and its core must see the scale
            // before the size computed for it. A child window gets no
            // WM_DPICHANGED of its own. wParam carries the new DPI in both
            // words; they are always equal for a window.
            if (self.surface) |surface| surface.scaleChanged(win32.hiword(wparam));
            applySuggestedRect(hwnd, lparam);
            return 0;
        },

        // Keyboard focus belongs to the terminal: the frame gets it on
        // activation (DefWindowProcW's WM_ACTIVATE), and passes it on.
        win32.WM_SETFOCUS => {
            if (self.surface) |surface| _ = win32.SetFocus(surface.hwnd);
            return 0;
        },

        // The system modal loops. See App.wndProc's WM_GHOSTTY_WAKEUP.
        win32.WM_ENTERSIZEMOVE, win32.WM_ENTERMENULOOP => {
            self.modal_loops.enter(&self.app.modal_loop_depth);
            return 0;
        },
        win32.WM_EXITSIZEMOVE, win32.WM_EXITMENULOOP => {
            self.modal_loops.exit(&self.app.modal_loop_depth);
            return 0;
        },

        // Sent to the top-level window, not to the terminal with the focus.
        win32.WM_SYSCOMMAND => if (isBareKeyMenu(wparam, lparam)) return 0,

        // The terminal covers the whole client area.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_DESTROY => {
            // Destroyed inside its own size/move or menu loop (e.g. the
            // shell exited mid-drag): the WM_EXIT* for that loop will not
            // come, so return this window's share of the depth now.
            // Otherwise every later wakeup would tick from whatever loop
            // dispatched it.
            self.modal_loops.release(&self.app.modal_loop_depth);
            return 0;
        },

        // After the child windows: frees `self`, so nothing may follow.
        win32.WM_NCDESTROY => {
            self.app.windowDestroyed(self);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => {},
    }

    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Resize the window so its client area is `size` scaled by `scale`, the
/// window's content scale. The whole value is scaled, as macOS and GTK also
/// treat it, so the core's device-pixel padding comes out larger by the
/// scale factor: the grid is never smaller than requested, at most a little
/// larger, unless the window would not fit its monitor's work area. The
/// frame is measured from the window itself rather than with
/// AdjustWindowRectExForDpi, which does not exist before Windows 10 1607
/// (see the dynamic imports in App.init): the window already exists at its
/// final DPI, so its window rect minus its client rect is exactly the frame.
/// The sizes saturate, since `window-width` is only clamped from below.
pub fn applyInitialSize(hwnd: win32.HWND, scale: f32, size: apprt.action.InitialSize) void {
    const client_w = std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(size.width)) * scale));
    const client_h = std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(size.height)) * scale));
    var window: win32.RECT = undefined;
    var client: win32.RECT = undefined;
    var monitor: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    const read = read: {
        if (!win32.GetWindowRect(hwnd, &window).toBool()) break :read false;
        if (!win32.GetClientRect(hwnd, &client).toBool()) break :read false;
        const m = win32.MonitorFromWindow(
            hwnd,
            win32.MONITOR_DEFAULTTONEAREST,
        ) orelse break :read false;
        break :read win32.GetMonitorInfoW(m, &monitor).toBool();
    };
    if (!read) {
        log.warn("unable to read the window frame or work area, initial size not applied", .{});
        return;
    }
    const frame_w = (window.right - window.left) - (client.right - client.left);
    const frame_h = (window.bottom - window.top) - (client.bottom - client.top);

    // CW_USEDEFAULT placed the default-sized window inside the work
    // area, but nothing keeps a larger one grown from the same corner
    // there: SetWindowPos does not move a window back on screen, and
    // the only size limit Windows applies is the maximum track size,
    // about the whole virtual screen.
    const rect = constrainToWorkArea(
        window.left,
        window.top,
        client_w +| frame_w,
        client_h +| frame_h,
        monitor.rcWork,
    );

    // SetWindowPos sends WM_SIZE synchronously; the core is live, so it
    // sees the new size before the first paint. That WM_SIZE also reports
    // the window visible (occlusionCallback) while it is still hidden,
    // which is harmless only because ShowWindow follows immediately.
    if (!win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    ).toBool()) log.warn("unable to apply initial window size err={}", .{win32.GetLastError()});
}

/// The rect for a `width` x `height` window at `x`, `y`, kept inside the
/// work area `work` as macOS keeps a window on screen
/// (`NSWindow.constrainToScreen`): it is moved up or left until it fits, and
/// made smaller only if it is larger than the work area.
fn constrainToWorkArea(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    work: win32.RECT,
) win32.RECT {
    const w = @min(width, work.right - work.left);
    const h = @min(height, work.bottom - work.top);
    const left = @max(work.left, @min(x, work.right - w));
    const top = @max(work.top, @min(y, work.bottom - h));
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// Bring the window to the front, restoring it first if it is
/// minimized, as GTK's `gtk.Window.present` does. SetForegroundWindow
/// alone only activates a window: a minimized one stays minimized.
pub fn present(hwnd: win32.HWND) bool {
    if (win32.IsIconic(hwnd).toBool()) {
        // The BOOL is the previous visibility, not success.
        _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
    }

    // SetForegroundWindow returning FALSE is the documented *normal*
    // outcome under Windows' foreground lock -- the calling process is
    // not foreground and has had no recent input -- so hard-coding true
    // here would lie in the common case rather than the rare one.
    return win32.SetForegroundWindow(hwnd).toBool();
}

/// `.toggle_maximize`: maximize the window, or restore it, and record which
/// in `maximized`.
pub fn toggleMaximize(hwnd: win32.HWND, maximized: *bool) void {
    maximized.* = !maximized.*;
    // ShowWindow's BOOL is the window's *previous* visibility, not
    // whether the call succeeded, so it deliberately is not
    // propagated: a window that was hidden returns zero from a
    // call that worked perfectly.
    _ = win32.ShowWindow(
        hwnd,
        if (maximized.*) win32.SW_MAXIMIZE else win32.SW_RESTORE,
    );
}

/// WM_DPICHANGED's second half: lParam carries the suggested new window
/// rect. Not honoring it leaves the window the wrong physical size on the
/// new monitor, so it is applied verbatim. SetWindowPos sends WM_SIZE
/// synchronously, so the surfaces must have the new scale before this.
pub fn applySuggestedRect(hwnd: win32.HWND, lparam: win32.LPARAM) void {
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
}

/// Whether a WM_SYSCOMMAND is a bare Alt or F10 released without being
/// consumed: it arrives as SC_KEYMENU with lParam 0 and would put the
/// window into menu mode, swallowing the next keystroke. The window has no
/// menu bar, so that mode is never wanted. Alt+Space arrives with lParam
/// ' ' and still opens the window menu.
pub fn isBareKeyMenu(wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    return wparam & 0xFFF0 == win32.SC_KEYMENU and lparam == 0;
}

/// A window's share of `App.modal_loop_depth`: the system modal loops
/// (size/move, menu) it has entered and not yet reported leaving. A window
/// destroyed inside its own loop never receives the matching WM_EXIT*, so
/// its share is returned with `release` instead.
pub const ModalLoops = struct {
    count: u32 = 0,

    /// WM_ENTERSIZEMOVE, WM_ENTERMENULOOP.
    pub fn enter(self: *ModalLoops, app_depth: *u32) void {
        self.count += 1;
        app_depth.* += 1;
    }

    /// WM_EXITSIZEMOVE, WM_EXITMENULOOP. Only undoes what this window added,
    /// so a stray exit can never take another window's loop out of the
    /// count.
    pub fn exit(self: *ModalLoops, app_depth: *u32) void {
        if (self.count == 0) return;
        self.count -= 1;
        app_depth.* -|= 1;
    }

    /// WM_DESTROY: give back whatever this window still holds.
    pub fn release(self: *ModalLoops, app_depth: *u32) void {
        app_depth.* -|= self.count;
        self.count = 0;
    }

    /// Whether this window is inside one of its loops.
    pub fn inLoop(self: ModalLoops) bool {
        return self.count != 0;
    }
};

test "win32: an initial size is kept inside the monitor work area" {
    const testing = std.testing;
    const RECT = win32.RECT;

    // 1920x1080 with a 40 px taskbar at the bottom.
    const work: RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };

    // Fits where it is: unchanged.
    try testing.expectEqual(
        RECT{ .left = 100, .top = 50, .right = 900, .bottom = 650 },
        constrainToWorkArea(100, 50, 800, 600, work),
    );

    // Fits the work area but not below and right of its origin: moved up
    // and left, at the size asked for.
    try testing.expectEqual(
        RECT{ .left = 1120, .top = 40, .right = 1920, .bottom = 1040 },
        constrainToWorkArea(1300, 80, 800, 1000, work),
    );

    // Larger than the work area, including the saturated size of an
    // enormous `window-width`: the whole work area.
    try testing.expectEqual(work, constrainToWorkArea(100, 50, 2500, 1200, work));
    try testing.expectEqual(work, constrainToWorkArea(
        100,
        50,
        std.math.maxInt(i32),
        std.math.maxInt(i32),
        work,
    ));

    // A monitor left of and above the primary, with the taskbar on its
    // left edge: the work area does not start at zero.
    try testing.expectEqual(
        RECT{ .left = -1232, .top = 524, .right = -632, .bottom = 824 },
        constrainToWorkArea(-1260, 700, 600, 300, .{
            .left = -1232,
            .top = -200,
            .right = 0,
            .bottom = 824,
        }),
    );
}

test "win32: modal loops are counted per window and returned on destroy" {
    // The app ticks the core from its window procedure while any window is
    // in a size/move or menu loop (WM_GHOSTTY_WAKEUP), so the count must
    // not leak past a loop's end or a window's. One message-only window
    // stands in for both frames: these handlers never use it.
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

    var a: Window = undefined;
    var b: Window = undefined;
    for ([_]*Window{ &a, &b }) |window| {
        window.app = &app;
        window.hwnd = hwnd;
        window.surface = null;
        window.modal_loops = .{};
    }

    _ = a.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    _ = a.handleMessage(hwnd, win32.WM_ENTERMENULOOP, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    // An exit with no loop of its own takes nothing from another window.
    _ = b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    _ = b.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    try std.testing.expectEqual(3, app.modal_loop_depth);

    // Destroyed inside both of its loops, so their exits never come.
    _ = a.handleMessage(hwnd, win32.WM_DESTROY, 0, 0);
    try std.testing.expectEqual(1, app.modal_loop_depth);

    _ = b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
    _ = b.handleMessage(hwnd, win32.WM_EXITMENULOOP, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
}

test "win32: presenting a minimized window restores it" {
    // A top-level window created minimized and hidden stands in for a
    // terminal window: `present` only uses the handle.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        win32.WS_OVERLAPPEDWINDOW | win32.WS_MINIMIZE,
        0,
        0,
        200,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);
    try std.testing.expect(win32.IsIconic(hwnd).toBool());

    _ = present(hwnd);
    try std.testing.expect(!win32.IsIconic(hwnd).toBool());
}
