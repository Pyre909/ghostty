//! A window's tab bar: a strip of our own under the title bar, as GTK's
//! AdwTabBar sits under its header bar, with a button per tab (its title,
//! a close glyph, the shown one marked) and a "+" button for a new tab.
//!
//! This part is the layout and the hit testing, pure functions of the
//! bar's width, the number of tabs and the DPI, so that they can be tested
//! on any input: tabs share the width between a minimum and a maximum
//! size, and once even the minimum does not fit they scroll, the "+"
//! button then kept at the right end.
//!
//! A tab is dragged with the left button, as on GTK's AdwTabBar, in
//! Windows Terminal and in Edge: once the pointer has moved past the
//! system's drag threshold (`pastDragThreshold`), the tab follows it and
//! the others make room (`Layout.dropIndex`), the tabs scrolling while it
//! is held near either end (`Layout.autoScrollStep`); dropped outside the
//! window, it moves to a new one (`Window.dropTabOut`). See `Drag`.

const std = @import("std");

const win32 = @import("win32.zig");
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const Window = @import("Window.zig");

const RECT = win32.RECT;
const L = win32.L;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyTabBarClass";

/// A window's bar: a child window of its frame, shown above the terminals
/// while the window shows it (`Window.barShown`).
pub const Bar = struct {
    hwnd: ?win32.HWND = null,
    /// How far the tabs are scrolled, in pixels (`Layout.scroll`).
    scroll: i32 = 0,
    /// What the pointer is over, for its highlight.
    hover: Hit = .none,
    /// Where the pointer was last over the bar, null once it left: the
    /// highlight follows the tabs when they move under a pointer that
    /// does not (`rehover`).
    pointer: ?win32.POINT = null,
    /// What the left button went down on, so that a close or a "+" is
    /// made only when it comes up on the same. The bar holds the mouse
    /// capture meanwhile, so that it sees the button come up wherever it
    /// does; a capture taken away, or a change to the tabs, which moves
    /// what an index names, cancels the press (`tabsChanged`).
    pressed: Hit = .none,
    /// The tab the middle button went down on, which a middle click
    /// closes only if it comes up on the same; cancelled as `pressed` is.
    middle: ?usize = null,
    /// A left press on a tab's label, which becomes a drag once the
    /// pointer moves far enough with the button down; null without one.
    /// Ended by the release, and cancelled as `pressed` is.
    drag: ?Drag = null,
    /// Whether the last left press was on the bar's empty part. A double
    /// click opens a tab only if both of its presses were there: its first
    /// press may have closed the last tab, leaving empty space under the
    /// second. Windows sends a WM_LBUTTONDOWN before each WM_LBUTTONDBLCLK.
    /// Kept when the tabs change, which moves what an index names but not
    /// where that press was.
    down_on_empty: bool = false,
    /// Wheel movement not yet scrolled, in pixels times WHEEL_DELTA: a
    /// high-resolution wheel sends fractions of a notch, as `Notches` in
    /// Surface.zig keeps them.
    wheel_rem: i32 = 0,
    font: ?win32.HGDIOBJ = null,
    font_dpi: u32 = 0,

    /// Make the bar's window in `window`'s frame, hidden; nothing, logged,
    /// if it cannot be made: the window then has no bar.
    pub fn create(self: *Bar, window: *Window) void {
        self.hwnd = win32.CreateWindowExW(
            0,
            L(class_name),
            null,
            win32.WS_CHILD | win32.WS_CLIPSIBLINGS,
            0,
            0,
            0,
            0,
            window.hwnd,
            null,
            window.app.hinstance,
            window,
        ) orelse {
            log.warn("cannot make a tab bar err={}", .{win32.GetLastError()});
            return;
        };
    }

    /// Draw the bar again: a tab came, went, moved or was renamed, another
    /// is shown, or the theme changed.
    pub fn invalidate(self: *const Bar) void {
        const hwnd = self.hwnd orelse return;
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
    }

    /// The tabs came, went or moved: a press names a tab by its index,
    /// which may now name another, so it is cancelled; and the highlight
    /// follows what is now under the pointer. A drag ends where it is: the
    /// tabs changed under it, so where it began no longer says where its
    /// tab was. A drag's own moves do not come here (`Window.reorderTab`).
    pub fn tabsChanged(self: *Bar, window: *Window) void {
        self.pressed = .none;
        self.middle = null;
        self.endDrag();
        self.rehover(window);
        self.invalidate();
    }

    /// A left press at `at` on the label of tab `index`, once the click
    /// has shown it (`Window.clickTab`): it may become a drag. Where the
    /// label was grabbed is read after that, as showing the tab may have
    /// scrolled it, and kept within it.
    fn pressTab(self: *Bar, window: *Window, hwnd: win32.HWND, index: usize, at: win32.POINT) void {
        self.endDrag();
        if (window.closing or window.app.terminating) return;
        if (index >= window.tabs.items.len) return;
        const l = layoutOf(window, hwnd);
        self.drag = .{
            .index = index,
            .from = index,
            .press = at,
            .grab = .{ .x = std.math.clamp(at.x - l.tabRect(index).left, 0, @max(0, l.tab - 1)), .y = at.y },
            .threshold = dragThreshold(Window.dpiOf(window.app, hwnd)),
            .pointer = at,
        };
    }

    /// The pointer moved to `at` with the left button down. Past the drag
    /// threshold, the press becomes a drag: the tab follows the pointer
    /// from then on. Not while the core may not be re-entered, as under a
    /// prompt, whose caller may count on the order of the tabs
    /// (`Window.requestCloseTabs`): the press stays a click.
    fn dragTo(self: *Bar, window: *Window, hwnd: win32.HWND, at: win32.POINT) void {
        const d = if (self.drag) |*d| d else return;
        d.pointer = at;
        if (!d.active) {
            if (!pastDragThreshold(d.press, at, d.threshold)) return;
            if (!window.app.canReenterCore()) return;
            d.active = true;
            // For as long as the pointer is held near an end of the bar,
            // which sends no WM_MOUSEMOVE (`autoScroll`).
            if (win32.SetTimer(hwnd, drag_timer, drag_timer_ms, null) == 0) {
                log.warn("cannot start the tab drag's timer, the tabs will not scroll err={}", .{win32.GetLastError()});
            }
        }
        self.follow(window, hwnd);
    }

    /// Put the dragged tab where the pointer now puts it among the others
    /// (`Layout.dropIndex`), and draw it there. Only the order changes
    /// (`Window.reorderTab`); while the core may not be re-entered it waits
    /// for the next move, as it does in `dragTo`.
    fn follow(self: *Bar, window: *Window, hwnd: win32.HWND) void {
        const d = &self.drag.?;
        if (window.app.canReenterCore() and d.index < window.tabs.items.len) {
            const to = layoutOf(window, hwnd).dropIndex(d.grab.x, d.pointer.x);
            window.reorderTab(d.index, to);
            d.index = to;
        }
        self.invalidate();
    }

    /// The drag's timer: with the pointer held near either end of tabs
    /// that do not all fit, they scroll (`Layout.autoScrollStep`), and the
    /// dragged tab finds its place among those that come into view.
    fn autoScroll(self: *Bar, window: *Window, hwnd: win32.HWND) void {
        const d = self.drag orelse return self.endDrag();
        if (!d.active) return self.endDrag();
        const l = layoutOf(window, hwnd);
        const scroll = std.math.clamp(l.scroll + l.autoScrollStep(d.pointer.x, d.pointer.y), 0, l.max_scroll);
        if (scroll == l.scroll) return;
        self.scroll = scroll;
        self.wheel_rem = 0;
        self.follow(window, hwnd);
    }

    /// The left button came up at `at`, ending a drag that began: in
    /// place, or, released outside the window, with its tab moved to a
    /// new one (`Window.dropTabOut`), the label where it was grabbed.
    fn drop(window: *Window, hwnd: win32.HWND, d: Drag, at: win32.POINT) void {
        var screen = at;
        var frame: RECT = undefined;
        if (!win32.ClientToScreen(hwnd, &screen).toBool() or
            !win32.GetWindowRect(window.hwnd, &frame).toBool()) return;
        if (contains(frame, screen.x, screen.y)) return;
        window.dropTabOut(d.index, .{ .at = screen, .grab = d.grab });
    }

    /// The capture was taken away: the button will come up unseen, so a
    /// drag puts its tab back where it began. Not while the core may not
    /// be re-entered (`dragTo`): a prompt taking the capture disables the
    /// window (WM_CANCELMODE), and its caller may count on the order, so
    /// the drag then ends where it is.
    fn cancelDrag(self: *Bar, window: *Window) void {
        const d = self.drag orelse return;
        self.endDrag();
        if (!d.active or !window.app.canReenterCore()) return;
        if (d.index >= window.tabs.items.len or d.from >= window.tabs.items.len) return;
        window.reorderTab(d.index, d.from);
    }

    /// End a press or a drag where it is, and stop the drag's timer.
    fn endDrag(self: *Bar) void {
        const d = self.drag orelse return;
        self.drag = null;
        if (!d.active) return;
        if (self.hwnd) |hwnd| _ = win32.KillTimer(hwnd, drag_timer);
        // Drawn again without the tab under the pointer.
        self.invalidate();
    }

    /// Scroll so that all of tab `index` shows (`Layout.scrollToShow`),
    /// for the bar's width now.
    pub fn scrollToShow(self: *Bar, window: *Window, index: usize) void {
        const hwnd = self.hwnd orelse return;
        const scroll = layoutOf(window, hwnd).scrollToShow(index);
        if (scroll == self.scroll) return;
        self.scroll = scroll;
        self.wheel_rem = 0;
        self.rehover(window);
        self.invalidate();
    }

    /// Highlight what is under the pointer now, if it is over the bar.
    fn rehover(self: *Bar, window: *Window) void {
        const hwnd = self.hwnd orelse return;
        const now: Hit = if (self.pointer) |p| layoutOf(window, hwnd).hit(p.x, p.y) else .none;
        if (std.meta.eql(now, self.hover)) return;
        self.hover = now;
        self.invalidate();
    }

    /// Delete the font. Also from `App.windowDestroyed`, for a frame that
    /// `terminate` could not destroy, whose bar has no WM_DESTROY.
    pub fn freeFont(self: *Bar) void {
        if (self.font) |f| _ = win32.DeleteObject(f);
        self.font = null;
        self.font_dpi = 0;
    }

    /// The font for `dpi` (`messageFont`), made once for each DPI. The new
    /// one is made before the old one goes, which is kept if it cannot be:
    /// the next paint tries again.
    fn fontFor(self: *Bar, dpi: u32) ?win32.HGDIOBJ {
        if (self.font != null and self.font_dpi == dpi) return self.font;
        const font = messageFont(dpi) orelse return self.font;
        self.freeFont();
        self.font = font;
        self.font_dpi = dpi;
        return font;
    }
};

/// A left press on a tab's label and, once the pointer has moved past the
/// system's drag threshold with the button down, the drag of that tab
/// (`Bar.dragTo`): the tab is drawn under the pointer, held where it was
/// grabbed, and the others make room as it passes them. The bar holds the
/// mouse capture throughout, as for any press. Released inside the window
/// the tab stays where it is; outside, it moves to a new window
/// (`Bar.drop`). A capture taken away puts it back (`Bar.cancelDrag`).
pub const Drag = struct {
    /// The tab's index now: the drag moves it (`Window.reorderTab`).
    index: usize,
    /// Its index when pressed, where a cancelled drag puts it back.
    from: usize,
    /// Where the button went down, in the bar's client coordinates.
    press: win32.POINT,
    /// Where the label was grabbed, from its top-left corner.
    grab: win32.POINT,
    /// How far the pointer may go from `press` and still click: SM_CXDRAG
    /// and SM_CYDRAG at the bar's DPI, read at the press.
    threshold: win32.POINT,
    /// The pointer's last place, in the bar's client coordinates.
    pointer: win32.POINT,
    /// Whether the pointer went past the threshold: the tab follows it.
    active: bool = false,
};

/// The bar's timer while a tab is dragged (`Bar.autoScroll`), and how often
/// it fires: about once a frame at 60 Hz.
pub const drag_timer: win32.UINT_PTR = 1;
const drag_timer_ms: win32.UINT = 16;

/// Whether the pointer at `now` is past the drag threshold from a press at
/// `press`: more than `threshold`'s pixels away on either side, across or
/// down, as SM_CXDRAG and SM_CYDRAG are documented ("the number of pixels
/// on either side of a mouse-down point that the mouse pointer can move
/// before a drag operation begins"), whatever their sign.
pub fn pastDragThreshold(press: win32.POINT, now: win32.POINT, threshold: win32.POINT) bool {
    return @abs(now.x - press.x) > @abs(threshold.x) or @abs(now.y - press.y) > @abs(threshold.y);
}

/// SM_CXDRAG and SM_CYDRAG at `dpi`, from GetSystemMetricsForDpi, which is
/// looked up as GetDpiForWindow is (Windows 10 1607; see `App.init`); else
/// GetSystemMetrics's. Windows 11 25H2 gives the same at 96 and 192 DPI
/// (4 by default): it does not scale these two, so the fallback does not
/// either.
fn dragThreshold(dpi: u32) win32.POINT {
    if (win32.GetModuleHandleW(L("user32.dll"))) |user32| {
        if (win32.GetProcAddress(user32, "GetSystemMetricsForDpi")) |p| {
            const f: win32.GetSystemMetricsForDpiFn = @ptrCast(@alignCast(p));
            return .{ .x = f(win32.SM_CXDRAG, dpi), .y = f(win32.SM_CYDRAG, dpi) };
        }
    }
    return .{ .x = win32.GetSystemMetrics(win32.SM_CXDRAG), .y = win32.GetSystemMetrics(win32.SM_CYDRAG) };
}

/// The system's message font, the one the user sets for the UI, which
/// varies by language (Segoe UI 9 points by default, Yu Gothic UI on
/// Japanese Windows), at `dpi`; else Segoe UI at 9 points. Windows gives
/// it for the system DPI, whatever the monitor's.
pub fn messageFont(dpi: u32) ?win32.HGDIOBJ {
    if (messageLogFont(dpi)) |lf| {
        if (win32.CreateFontIndirectW(&lf)) |font| return font;
        log.warn("cannot make the message font err={}", .{win32.GetLastError()});
    }
    return win32.CreateFontW(
        -scaleHeight(12, dpi, win32.USER_DEFAULT_SCREEN_DPI),
        0,
        0,
        0,
        win32.FW_NORMAL,
        0,
        0,
        0,
        win32.DEFAULT_CHARSET,
        win32.OUT_DEFAULT_PRECIS,
        win32.CLIP_DEFAULT_PRECIS,
        win32.CLEARTYPE_QUALITY,
        win32.DEFAULT_PITCH,
        L("Segoe UI"),
    );
}

/// The system's message font as `messageFont` makes it, scaled to `dpi`.
pub fn messageLogFont(dpi: u32) ?win32.LOGFONTW {
    var ncm = std.mem.zeroes(win32.NONCLIENTMETRICSW);
    ncm.cbSize = @sizeOf(win32.NONCLIENTMETRICSW);
    if (!win32.SystemParametersInfoW(win32.SPI_GETNONCLIENTMETRICS, ncm.cbSize, &ncm, 0).toBool()) {
        log.warn("cannot read the system's message font err={}", .{win32.GetLastError()});
        return null;
    }
    var lf = ncm.lfMessageFont;
    lf.lfHeight = scaleHeight(lf.lfHeight, dpi, systemDpi());
    return lf;
}

/// The DPI the system's metrics are given at.
fn systemDpi() u32 {
    if (win32.GetDC(null)) |screen| {
        defer _ = win32.ReleaseDC(null, screen);
        const v = win32.GetDeviceCaps(screen, win32.LOGPIXELSY);
        if (v > 0) return @intCast(v);
    }
    return win32.USER_DEFAULT_SCREEN_DPI;
}

/// A font height at DPI `from` scaled to DPI `to`, rounded half away from
/// zero, as MulDiv rounds; its sign kept (a negative LOGFONT height is the
/// character height, a positive one the cell's).
fn scaleHeight(height: i32, to: u32, from: u32) i32 {
    const n = @as(i64, height) * to;
    const d: i64 = from;
    const q = @divTrunc(@as(i64, @intCast(@abs(n))) * 2 + d, 2 * d);
    return @intCast(if (n < 0) -q else q);
}

/// The bar's colours, by whether the title bar is dark (`Window.dark_frame`),
/// as the frame follows `window-theme`.
const Colors = struct {
    bar: win32.COLORREF,
    shown: win32.COLORREF,
    hover: win32.COLORREF,
    text: win32.COLORREF,
    dim: win32.COLORREF,

    fn of(dark: bool) Colors {
        return if (dark) .{
            .bar = win32.rgb(0x1f, 0x1f, 0x1f),
            .shown = win32.rgb(0x3a, 0x3a, 0x3a),
            .hover = win32.rgb(0x2d, 0x2d, 0x2d),
            .text = win32.rgb(0xff, 0xff, 0xff),
            .dim = win32.rgb(0xb4, 0xb4, 0xb4),
        } else .{
            .bar = win32.rgb(0xf0, 0xf0, 0xf0),
            .shown = win32.rgb(0xff, 0xff, 0xff),
            .hover = win32.rgb(0xe2, 0xe2, 0xe2),
            .text = win32.rgb(0x1a, 0x1a, 0x1a),
            .dim = win32.rgb(0x5c, 0x5c, 0x5c),
        };
    }
};

/// The bar's window procedure. WM_NCCREATE brings the window it belongs to.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(param)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const window: *Window = ptr: {
        const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
    };
    const bar = &window.bar;

    switch (msg) {
        // All of it is painted, from a bitmap.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            paint(window, hwnd);
            return 0;
        },

        win32.WM_MOUSEMOVE => {
            // Asked once each time the pointer comes over the bar.
            if (bar.pointer == null) {
                var track: win32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = win32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = win32.TrackMouseEvent(&track);
            }
            bar.pointer = pointAt(lparam);
            bar.rehover(window);
            // A button that came up unseen ends the drag where it is.
            if (wparam & win32.MK_LBUTTON != 0) {
                bar.dragTo(window, hwnd, pointAt(lparam));
            } else {
                bar.endDrag();
            }
            return 0;
        },

        win32.WM_TIMER => {
            if (wparam == drag_timer) bar.autoScroll(window, hwnd);
            return 0;
        },

        win32.WM_MOUSELEAVE => {
            bar.pointer = null;
            bar.rehover(window);
            return 0;
        },

        // With CS_DBLCLKS the second press of a double click comes as
        // WM_LBUTTONDBLCLK. It is a press like any other, so that closing
        // tabs one after another at one place, or a quick second "+",
        // takes every click; but with both of its presses on the bar's
        // empty part it opens a tab, as a double click there does on GTK's
        // tab bar and in Windows Terminal.
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK => {
            const at = hitAt(window, hwnd, lparam);
            const on_empty = at == .none;
            const first_on_empty = bar.down_on_empty;
            bar.down_on_empty = msg == win32.WM_LBUTTONDOWN and on_empty;
            if (msg == win32.WM_LBUTTONDBLCLK and on_empty and first_on_empty) {
                window.clickNewTab();
                return 0;
            }
            // Captured first: SetCapture sends WM_CAPTURECHANGED to the
            // window that loses it, which cancels a press.
            if (at != .none and win32.GetCapture() != hwnd) _ = win32.SetCapture(hwnd);
            bar.pressed = at;
            switch (at) {
                .tab => |index| {
                    window.clickTab(index);
                    bar.pressTab(window, hwnd, index, pointAt(lparam));
                },
                else => bar.endDrag(),
            }
            return 0;
        },

        win32.WM_LBUTTONUP => {
            const at = hitAt(window, hwnd, lparam);
            // Its last place is where the button came up.
            if (bar.drag) |d| if (d.active) bar.dragTo(window, hwnd, pointAt(lparam));
            // Read before ReleaseCapture, whose WM_CAPTURECHANGED cancels them.
            const pressed = bar.pressed;
            const drag = bar.drag;
            bar.pressed = .none;
            bar.endDrag();
            if (win32.GetCapture() == hwnd and bar.middle == null) _ = win32.ReleaseCapture();
            // A drag is no click: its press already showed the tab.
            if (drag) |d| if (d.active) {
                Bar.drop(window, hwnd, d, pointAt(lparam));
                return 0;
            };
            if (!std.meta.eql(at, pressed)) return 0;
            switch (at) {
                .close => |index| _ = window.closeTabs(index, .this),
                .plus => window.clickNewTab(),
                .none, .tab => {},
            }
            return 0;
        },

        // A middle click closes a tab, as in a browser: pressed and
        // released on the same tab, its close glyph included. A quick
        // second press comes as WM_MBUTTONDBLCLK (CS_DBLCLKS) and is a
        // press like any other, so that closing tabs one after another at
        // one place takes every click.
        win32.WM_MBUTTONDOWN, win32.WM_MBUTTONDBLCLK => {
            const index = tabAt(hitAt(window, hwnd, lparam)) orelse return 0;
            if (win32.GetCapture() != hwnd) _ = win32.SetCapture(hwnd);
            bar.middle = index;
            return 0;
        },

        win32.WM_MBUTTONUP => {
            const pressed = bar.middle;
            bar.middle = null;
            if (win32.GetCapture() == hwnd and bar.pressed == .none) _ = win32.ReleaseCapture();
            const index = tabAt(hitAt(window, hwnd, lparam)) orelse return 0;
            if (pressed == null or pressed.? != index) return 0;
            _ = window.closeTabs(index, .this);
            return 0;
        },

        // A message box, or another window, took the capture: the button
        // will come up elsewhere, unseen.
        win32.WM_CAPTURECHANGED => {
            bar.pressed = .none;
            bar.middle = null;
            bar.cancelDrag(window);
            return 0;
        },

        // The wheel scrolls tabs that do not fit, a notch a tab, and a
        // high-resolution wheel's fractions of a notch in proportion.
        win32.WM_MOUSEWHEEL => {
            const l = layoutOf(window, hwnd);
            const delta: i32 = win32.wheelDelta(wparam);
            // A turn the other way drops what was left of the last.
            if (bar.wheel_rem != 0 and (delta < 0) != (bar.wheel_rem < 0)) bar.wheel_rem = 0;
            bar.wheel_rem += delta * l.tab;
            const pixels = @divTrunc(bar.wheel_rem, win32.WHEEL_DELTA);
            bar.wheel_rem -= pixels * win32.WHEEL_DELTA;
            const scroll = std.math.clamp(l.scroll - pixels, 0, l.max_scroll);
            // At either end nothing is kept for the way on.
            if (pixels != 0 and scroll == l.scroll) bar.wheel_rem = 0;
            if (scroll != bar.scroll) {
                bar.scroll = scroll;
                bar.rehover(window);
                bar.invalidate();
            }
            return 0;
        },

        win32.WM_DESTROY => {
            bar.endDrag();
            bar.freeFont();
            // Nothing draws into, or places, a destroyed window.
            bar.hwnd = null;
            return 0;
        },

        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The layout of `window`'s tabs in its bar, whose window is `hwnd`.
fn layoutOf(window: *Window, hwnd: win32.HWND) Layout {
    var client: RECT = undefined;
    const width = if (win32.GetClientRect(hwnd, &client).toBool()) client.right else 0;
    return .init(Metrics.init(Window.dpiOf(window.app, hwnd)), window.tabs.items.len, width, window.bar.scroll);
}

/// What a mouse message's `lparam` points at in the bar.
fn hitAt(window: *Window, hwnd: win32.HWND, lparam: win32.LPARAM) Hit {
    return layoutOf(window, hwnd).hit(win32.xLparam(lparam), win32.yLparam(lparam));
}

/// A mouse message's point, in the bar's client coordinates.
fn pointAt(lparam: win32.LPARAM) win32.POINT {
    return .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
}

/// The tab a hit is on, its close glyph included.
fn tabAt(at: Hit) ?usize {
    return switch (at) {
        .tab, .close => |index| index,
        .none, .plus => null,
    };
}

fn paint(window: *Window, hwnd: win32.HWND) void {
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = win32.EndPaint(hwnd, &ps);

    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) return;
    if (client.right <= 0 or client.bottom <= 0) return;

    // Drawn off the screen, then copied at once, so that it never flickers.
    const mem = win32.CreateCompatibleDC(hdc) orelse return;
    defer _ = win32.DeleteDC(mem);
    const bitmap = win32.CreateCompatibleBitmap(hdc, client.right, client.bottom) orelse return;
    defer _ = win32.DeleteObject(bitmap);
    const old_bitmap = win32.SelectObject(mem, bitmap);
    defer if (old_bitmap) |b| {
        _ = win32.SelectObject(mem, b);
    };

    const dpi = Window.dpiOf(window.app, hwnd);
    const colors = Colors.of(window.dark_frame);
    const l = layoutOf(window, hwnd);
    fill(mem, client, colors.bar);

    const font = window.bar.fontFor(dpi);
    const old_font = if (font) |f| win32.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = win32.SelectObject(mem, f);
    };
    _ = win32.SetBkMode(mem, win32.TRANSPARENT);

    // A dragged tab is drawn last, over the others, under the pointer;
    // nothing is highlighted meanwhile.
    const drag: ?Drag = if (window.bar.drag) |d| (if (d.active) d else null) else null;
    for (window.tabs.items, 0..) |t, index| {
        if (drag) |d| if (d.index == index) continue;
        const hover: Hover = if (drag != null)
            .none
        else if (std.meta.eql(window.bar.hover, Hit{ .close = index }))
            .close
        else if (std.meta.eql(window.bar.hover, Hit{ .tab = index }))
            .tab
        else
            .none;
        drawTab(window, mem, l, t, l.tabRect(index), index == window.selected, hover, colors);
    }
    if (drag) |d| {
        const left = l.dragLeft(d.grab.x, d.pointer.x);
        const r: RECT = .{ .left = left, .top = 0, .right = left + l.tab, .bottom = l.m.height };
        drawTab(window, mem, l, window.tabs.items[d.index], r, d.index == window.selected, .tab, colors);
    }

    // Over any tab scrolled under it.
    var plus = l.plusRect();
    fill(mem, plus, if (window.bar.hover == .plus) colors.hover else colors.bar);
    _ = win32.SetTextColor(mem, colors.text);
    _ = win32.DrawTextW(mem, L("+"), 1, &plus, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_CENTER | win32.DT_NOPREFIX);

    _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
}

/// What of a tab the pointer is over, for its highlight.
const Hover = enum { none, tab, close };

/// Draw tab `t` in `r`: the shown one or one under the pointer filled, its
/// title, and its close glyph.
fn drawTab(
    window: *Window,
    hdc: win32.HDC,
    l: Layout,
    t: *const Window.Tab,
    r: RECT,
    shown: bool,
    hover: Hover,
    colors: Colors,
) void {
    if (r.right <= 0 or r.left >= l.width) return;
    if (shown or hover != .none) fill(hdc, r, if (shown) colors.shown else colors.hover);

    // The title, cut short with an ellipsis where it does not fit.
    var close = closeIn(l.m, r);
    var text_rect: RECT = .{
        .left = r.left + l.m.pad,
        .top = r.top,
        .right = close.left - @divTrunc(l.m.pad, 2),
        .bottom = r.bottom,
    };
    _ = win32.SetTextColor(hdc, if (shown) colors.text else colors.dim);
    const alloc = window.app.core_app.alloc;
    const title = wideFromUtf8(alloc, Window.tabTitle(t) orelse "Ghostty") catch null;
    defer if (title) |w| alloc.free(w);
    if (title) |w| _ = win32.DrawTextW(hdc, w.ptr, @intCast(w.len), &text_rect, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_END_ELLIPSIS | win32.DT_NOPREFIX);

    if (hover == .close) fill(hdc, close, colors.shown);
    _ = win32.SetTextColor(hdc, colors.dim);
    _ = win32.DrawTextW(hdc, L("\u{00D7}"), 1, &close, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_CENTER | win32.DT_NOPREFIX);
}

fn fill(hdc: win32.HDC, r: RECT, color: win32.COLORREF) void {
    const brush = win32.CreateSolidBrush(color) orelse return;
    defer _ = win32.DeleteObject(brush);
    _ = win32.FillRect(hdc, &r, brush);
}

/// The bar's sizes at a DPI, from their values at 96 DPI.
pub const Metrics = struct {
    height: i32,
    tab_min: i32,
    tab_max: i32,
    /// The "+" button, square.
    plus: i32,
    /// The close glyph's box, square, inset `pad` from a tab's right edge.
    close: i32,
    pad: i32,
    /// How near either end of the tabs a dragged tab's pointer scrolls
    /// them (`Layout.autoScrollStep`).
    edge: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .height = scale(34, dpi),
            .tab_min = scale(72, dpi),
            .tab_max = scale(220, dpi),
            .plus = scale(34, dpi),
            .close = scale(16, dpi),
            .pad = scale(8, dpi),
            .edge = scale(32, dpi),
        };
    }

    fn scale(v: i32, dpi: u32) i32 {
        const base: i32 = win32.USER_DEFAULT_SCREEN_DPI;
        return @divTrunc(v * @as(i32, @intCast(dpi)) + @divTrunc(base, 2), base);
    }
};

/// Where `count` tabs go in a bar `width` wide, scrolled by `scroll`.
pub const Layout = struct {
    m: Metrics,
    count: usize,
    width: i32,
    /// Each tab's width.
    tab: i32,
    /// How far the tabs can scroll: 0 when they fit.
    max_scroll: i32,
    scroll: i32,

    pub fn init(m: Metrics, count: usize, width: i32, scroll: i32) Layout {
        const room = @max(0, width - m.plus);
        const n: i32 = @intCast(@max(count, 1));
        const tab = std.math.clamp(@divTrunc(room, n), m.tab_min, m.tab_max);
        const max_scroll = @max(0, tab * n - room);
        return .{
            .m = m,
            .count = count,
            .width = width,
            .tab = tab,
            .max_scroll = max_scroll,
            .scroll = std.math.clamp(scroll, 0, max_scroll),
        };
    }

    /// Tab `index`'s rect, which may lie partly or wholly outside the bar
    /// when the tabs scroll.
    pub fn tabRect(self: Layout, index: usize) RECT {
        const left = @as(i32, @intCast(index)) * self.tab - self.scroll;
        return .{ .left = left, .top = 0, .right = left + self.tab, .bottom = self.m.height };
    }

    /// The close glyph's box in tab `index`.
    pub fn closeRect(self: Layout, index: usize) RECT {
        return closeIn(self.m, self.tabRect(index));
    }

    /// The "+" button: after the last tab, or at the right end once the
    /// tabs scroll.
    pub fn plusRect(self: Layout) RECT {
        const after = @as(i32, @intCast(self.count)) * self.tab - self.scroll;
        const left = @min(after, self.width - self.m.plus);
        return .{ .left = left, .top = 0, .right = left + self.m.plus, .bottom = self.m.height };
    }

    /// Where the tabs end: the "+" button's left edge.
    fn tabsEnd(self: Layout) i32 {
        return self.plusRect().left;
    }

    /// What is at `x`, `y` in the bar.
    pub fn hit(self: Layout, x: i32, y: i32) Hit {
        if (y < 0 or y >= self.m.height or x < 0 or x >= self.width) return .none;
        if (contains(self.plusRect(), x, y)) return .plus;
        if (x >= self.tabsEnd()) return .none;
        const index: usize = @intCast(@divTrunc(x + self.scroll, self.tab));
        if (index >= self.count) return .none;
        if (contains(self.closeRect(index), x, y)) return .{ .close = index };
        return .{ .tab = index };
    }

    /// The scroll that shows all of tab `index`, as near as can be to the
    /// one there is.
    pub fn scrollToShow(self: Layout, index: usize) i32 {
        const t = self.tabRect(index);
        const end = self.width - self.m.plus;
        var scroll = self.scroll;
        if (t.left < 0) scroll += t.left;
        if (t.right > end) scroll += t.right - end;
        return std.math.clamp(scroll, 0, self.max_scroll);
    }

    /// Where the left edge of a tab dragged with the pointer at `x`,
    /// grabbed `grab` pixels from its left edge, is drawn: under the
    /// pointer, kept within the part of the bar the tabs show in, from its
    /// left end to the "+" button.
    pub fn dragLeft(self: Layout, grab: i32, x: i32) i32 {
        return @max(0, @min(x - grab, self.tabsEnd() - self.tab));
    }

    /// The index a tab dragged so goes to among the `count` tabs, itself
    /// counted (`dragLeft`): the place it covers the most of, scroll
    /// included. A neighbour makes room once the dragged tab's leading
    /// edge passes the neighbour's centre, the dragged tab's centre then
    /// in the neighbour's place; it can go no further than the first or
    /// last place.
    pub fn dropIndex(self: Layout, grab: i32, x: i32) usize {
        if (self.count == 0) return 0;
        const tab = @max(1, self.tab);
        const left = self.dragLeft(grab, x) + self.scroll;
        const place: i64 = @divFloor(left + @divTrunc(tab, 2), tab);
        return @intCast(std.math.clamp(place, 0, @as(i64, @intCast(self.count - 1))));
    }

    /// How far, at each tick of a drag's timer, the tabs scroll with the
    /// dragged tab's pointer at `x`, `y`: toward the end of the tabs it is
    /// held within `Metrics.edge` of, or past, the faster the nearer, up to
    /// a quarter of that edge a tick; 0 when the tabs all fit, when there
    /// is no more to scroll that way, and with the pointer more than the
    /// bar's height above or below it, as when it takes a tab out of it.
    pub fn autoScrollStep(self: Layout, x: i32, y: i32) i32 {
        if (self.max_scroll == 0) return 0;
        if (y < -self.m.height or y >= 2 * self.m.height) return 0;
        const edge = self.m.edge;
        if (x < edge) return if (self.scroll > 0) -scrollSpeed(edge - x, edge) else 0;
        const end = self.tabsEnd();
        if (x >= end - edge) return if (self.scroll < self.max_scroll) scrollSpeed(x - (end - edge) + 1, edge) else 0;
        return 0;
    }

    fn scrollSpeed(depth: i32, edge: i32) i32 {
        return @max(1, @divTrunc(@min(depth, edge), 4));
    }
};

/// The close glyph's box in a tab at `r`: `m.close` square, inset `m.pad`
/// from its right edge, centred down the bar.
fn closeIn(m: Metrics, r: RECT) RECT {
    const top = @divTrunc(m.height - m.close, 2);
    return .{
        .left = r.right - m.pad - m.close,
        .top = top,
        .right = r.right - m.pad,
        .bottom = top + m.close,
    };
}

pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    plus,
};

fn contains(r: RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

test "win32: the tab bar's tabs share its width, then scroll" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(34, m.height);
    try testing.expectEqual(51, Metrics.init(144).height);

    // Few tabs: each as wide as it may be, the "+" button after them.
    const few = Layout.init(m, 2, 1000, 0);
    try testing.expectEqual(220, few.tab);
    try testing.expectEqual(0, few.max_scroll);
    try testing.expectEqual(RECT{ .left = 220, .top = 0, .right = 440, .bottom = 34 }, few.tabRect(1));
    try testing.expectEqual(RECT{ .left = 440, .top = 0, .right = 474, .bottom = 34 }, few.plusRect());

    // More: they share the room left of the "+" button.
    const many = Layout.init(m, 6, 1000, 0);
    try testing.expectEqual(161, many.tab);
    try testing.expectEqual(0, many.max_scroll);

    // Too many for the least width: they scroll, the "+" button at the
    // right end, and a scroll past either end stops there.
    const over = Layout.init(m, 20, 1000, 5000);
    try testing.expectEqual(72, over.tab);
    try testing.expectEqual(20 * 72 - (1000 - 34), over.max_scroll);
    try testing.expectEqual(over.max_scroll, over.scroll);
    try testing.expectEqual(RECT{ .left = 966, .top = 0, .right = 1000, .bottom = 34 }, over.plusRect());
    try testing.expectEqual(0, Layout.init(m, 20, 1000, -10).scroll);

    // No room at all, and no tabs: nothing divides by zero.
    _ = Layout.init(m, 3, 0, 0).tabRect(2);
    _ = Layout.init(m, 0, 500, 0).plusRect();
}

test "win32: a point in the tab bar hits a tab, its close glyph or the + button" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const l = Layout.init(m, 3, 1000, 0);

    try testing.expectEqual(Hit{ .tab = 0 }, l.hit(10, 10));
    try testing.expectEqual(Hit{ .tab = 2 }, l.hit(2 * 220 + 5, 20));
    // The close glyph: 16 px, 8 px in from the tab's right edge, centred.
    try testing.expectEqual(Hit{ .close = 1 }, l.hit(2 * 220 - 8 - 8, 17));
    try testing.expectEqual(Hit{ .tab = 1 }, l.hit(2 * 220 - 8 - 8, 2));
    try testing.expectEqual(Hit.plus, l.hit(3 * 220 + 10, 10));
    // Past the "+" button, below the bar, left of it: nothing.
    try testing.expectEqual(Hit.none, l.hit(900, 10));
    try testing.expectEqual(Hit.none, l.hit(10, 34));
    try testing.expectEqual(Hit.none, l.hit(-1, 10));

    // Scrolled: the scroll counts, and a tab under the "+" button is not hit.
    const s = Layout.init(m, 20, 1000, 100);
    try testing.expectEqual(Hit{ .tab = 1 }, s.hit(0, 10));
    try testing.expectEqual(Hit.plus, s.hit(980, 10));
}

test "win32: the tab bar's font is the system's message font" {
    // Whatever font the user set for the UI, scaled from the system DPI
    // to the bar's, as MulDiv rounds.
    const testing = std.testing;
    try testing.expectEqual(-24, scaleHeight(-12, 192, 96));
    try testing.expectEqual(-18, scaleHeight(-12, 144, 96));
    try testing.expectEqual(14, scaleHeight(9, 144, 96));
    try testing.expectEqual(-14, scaleHeight(-9, 144, 96));

    var ncm = std.mem.zeroes(win32.NONCLIENTMETRICSW);
    ncm.cbSize = @sizeOf(win32.NONCLIENTMETRICSW);
    try testing.expect(win32.SystemParametersInfoW(win32.SPI_GETNONCLIENTMETRICS, ncm.cbSize, &ncm, 0).toBool());
    const dpi = 2 * systemDpi();
    const font = messageFont(dpi) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteObject(font);
    var made: win32.LOGFONTW = undefined;
    try testing.expectEqual(@sizeOf(win32.LOGFONTW), win32.GetObjectW(font, @sizeOf(win32.LOGFONTW), &made));
    try testing.expectEqualSlices(u16, &ncm.lfMessageFont.lfFaceName, &made.lfFaceName);
    try testing.expectEqual(2 * ncm.lfMessageFont.lfHeight, made.lfHeight);
}

test "win32: a press on a tab drags it only past the system's threshold" {
    const testing = std.testing;
    const press: win32.POINT = .{ .x = 100, .y = 10 };
    const four: win32.POINT = .{ .x = 4, .y = 4 };
    // As far as the threshold on either side, across or down: a click.
    try testing.expect(!pastDragThreshold(press, .{ .x = 104, .y = 10 }, four));
    try testing.expect(!pastDragThreshold(press, .{ .x = 96, .y = 14 }, four));
    try testing.expect(!pastDragThreshold(press, .{ .x = 100, .y = 6 }, four));
    // One pixel more, either way: a drag.
    try testing.expect(pastDragThreshold(press, .{ .x = 105, .y = 10 }, four));
    try testing.expect(pastDragThreshold(press, .{ .x = 95, .y = 10 }, four));
    try testing.expect(pastDragThreshold(press, .{ .x = 100, .y = 15 }, four));
    try testing.expect(pastDragThreshold(press, .{ .x = 100, .y = 5 }, four));
    // A negative metric counts as its size.
    try testing.expect(!pastDragThreshold(press, .{ .x = 104, .y = 10 }, .{ .x = -4, .y = -4 }));
    try testing.expect(pastDragThreshold(press, .{ .x = 105, .y = 10 }, .{ .x = -4, .y = -4 }));

    // Windows gives one at any DPI.
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const t = dragThreshold(dpi);
        try testing.expect(t.x > 0 and t.y > 0);
    }
}

test "win32: a dragged tab goes to the place it covers the most of" {
    const testing = std.testing;
    const m = Metrics.init(96);

    // Three tabs 220 wide at 0, 220 and 440, grabbed 20 px in: the first
    // stays first until it has moved half a tab, then makes the second
    // room; it goes no further than the last place, nor before the first,
    // and is drawn no further than the "+" or the bar's left end.
    const l = Layout.init(m, 3, 1000, 0);
    try testing.expectEqual(0, l.dropIndex(20, 20));
    try testing.expectEqual(0, l.dropIndex(20, 20 + 109));
    try testing.expectEqual(1, l.dropIndex(20, 20 + 110));
    try testing.expectEqual(1, l.dropIndex(20, 20 + 329));
    try testing.expectEqual(2, l.dropIndex(20, 20 + 330));
    try testing.expectEqual(2, l.dropIndex(20, 5000));
    try testing.expectEqual(0, l.dropIndex(20, -5000));
    try testing.expectEqual(440, l.dragLeft(20, 5000));
    try testing.expectEqual(0, l.dragLeft(20, -5000));
    try testing.expectEqual(123, l.dragLeft(20, 143));
    // The last, dragged left, likewise.
    try testing.expectEqual(2, l.dropIndex(20, 460 - 110));
    try testing.expectEqual(1, l.dropIndex(20, 460 - 111));

    // Scrolled tabs: the scroll counts, and at either end of it the
    // dragged tab reaches the first or the last place.
    const s = Layout.init(m, 20, 1000, 100);
    try testing.expectEqual(1, s.dropIndex(10, 10));
    try testing.expectEqual(966 - 72, s.dragLeft(10, 5000));
    try testing.expectEqual(14, s.dropIndex(10, 5000));
    try testing.expectEqual(19, Layout.init(m, 20, 1000, 10_000).dropIndex(10, 5000));
    try testing.expectEqual(0, Layout.init(m, 20, 1000, 0).dropIndex(10, -5));

    // No room, and no tabs: the first place, nothing divides by zero.
    try testing.expectEqual(0, Layout.init(m, 3, 0, 0).dropIndex(10, 500));
    try testing.expectEqual(0, Layout.init(m, 3, 0, 0).dragLeft(10, 500));
    try testing.expectEqual(0, Layout.init(m, 0, 500, 0).dropIndex(10, 500));
}

test "win32: a dragged tab held near an end of the bar scrolls the tabs" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(32, m.edge);

    // Twenty tabs in 1000 px, scrolled 100 of 474: the tabs end at the
    // "+", 966. Within 32 px of either end, or past it, they scroll that
    // way, by 1 px a tick at the edge's inner side up to 8 at the end.
    const s = Layout.init(m, 20, 1000, 100);
    try testing.expectEqual(0, s.autoScrollStep(500, 10));
    try testing.expectEqual(-8, s.autoScrollStep(0, 10));
    try testing.expectEqual(-1, s.autoScrollStep(31, 10));
    try testing.expectEqual(0, s.autoScrollStep(32, 10));
    try testing.expectEqual(-8, s.autoScrollStep(-300, 10));
    try testing.expectEqual(0, s.autoScrollStep(933, 10));
    try testing.expectEqual(1, s.autoScrollStep(934, 10));
    try testing.expectEqual(8, s.autoScrollStep(965, 10));
    try testing.expectEqual(8, s.autoScrollStep(2000, 10));
    // Not with the pointer more than the bar's height above or below it.
    try testing.expectEqual(-8, s.autoScrollStep(0, -34));
    try testing.expectEqual(0, s.autoScrollStep(0, -35));
    try testing.expectEqual(-8, s.autoScrollStep(0, 67));
    try testing.expectEqual(0, s.autoScrollStep(0, 68));

    // At the first and the last scroll, only the other way.
    const first = Layout.init(m, 20, 1000, 0);
    try testing.expectEqual(0, first.autoScrollStep(0, 10));
    try testing.expectEqual(8, first.autoScrollStep(965, 10));
    const last = Layout.init(m, 20, 1000, 10_000);
    try testing.expectEqual(0, last.autoScrollStep(965, 10));
    try testing.expectEqual(-8, last.autoScrollStep(0, 10));

    // Tabs that all fit never scroll; nor does a bar with no room, but
    // back to its start.
    const fit = Layout.init(m, 3, 1000, 0);
    try testing.expectEqual(0, fit.autoScrollStep(0, 10));
    try testing.expectEqual(0, fit.autoScrollStep(999, 10));
    try testing.expectEqual(0, Layout.init(m, 3, 0, 0).autoScrollStep(0, 10));
    try testing.expectEqual(-8, Layout.init(m, 3, 0, 500).autoScrollStep(0, 10));
}

test "win32: the tab bar scrolls to show a tab" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const l = Layout.init(m, 20, 1000, 0);
    // Already shown: unchanged.
    try testing.expectEqual(0, l.scrollToShow(3));
    // Past the right: its right edge at the "+" button's left.
    try testing.expectEqual(15 * 72 - 966, l.scrollToShow(14));
    // Before the left, scrolled to the end: its left edge at 0.
    const end = Layout.init(m, 20, 1000, 10_000);
    try testing.expectEqual(2 * 72, end.scrollToShow(2));
}
