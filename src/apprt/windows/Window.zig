//! Window-level behaviour of a terminal window: what belongs to the
//! top-level window rather than to the terminal surface inside it.
//!
//! Each window holds one surface today, and that surface's HWND is the
//! top-level window, so everything here takes that HWND. When a window holds
//! split panes, the panes become child windows of a frame window, and this
//! is the frame's behaviour.

const std = @import("std");

const apprt = @import("../../apprt.zig");

const win32 = @import("win32.zig");
const L = win32.L;

const log = std.log.scoped(.win32);

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
