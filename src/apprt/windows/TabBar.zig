//! A window's tab bar: a strip of our own under the title bar, as GTK's
//! AdwTabBar sits under its header bar, with a button per tab (its title,
//! a close glyph, the shown one marked) and a "+" button for a new tab.
//!
//! This part is the layout and the hit testing, pure functions of the
//! bar's width, the number of tabs and the DPI, so that they can be tested
//! on any input: tabs share the width between a minimum and a maximum
//! size, and once even the minimum does not fit they scroll, the "+"
//! button then kept at the right end.

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
    /// follows what is now under the pointer.
    pub fn tabsChanged(self: *Bar, window: *Window) void {
        self.pressed = .none;
        self.middle = null;
        self.rehover(window);
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
            bar.pointer = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
            bar.rehover(window);
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
                .tab => |index| window.clickTab(index),
                else => {},
            }
            return 0;
        },

        win32.WM_LBUTTONUP => {
            const at = hitAt(window, hwnd, lparam);
            // Read before ReleaseCapture, whose WM_CAPTURECHANGED cancels it.
            const pressed = bar.pressed;
            bar.pressed = .none;
            if (win32.GetCapture() == hwnd and bar.middle == null) _ = win32.ReleaseCapture();
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

    const alloc = window.app.core_app.alloc;
    for (window.tabs.items, 0..) |t, index| {
        const r = l.tabRect(index);
        if (r.right <= 0 or r.left >= l.width) continue;
        const shown = index == window.selected;
        const hovered = std.meta.eql(window.bar.hover, Hit{ .tab = index }) or
            std.meta.eql(window.bar.hover, Hit{ .close = index });
        if (shown or hovered) fill(mem, r, if (shown) colors.shown else colors.hover);

        // The title, cut short with an ellipsis where it does not fit.
        var text_rect: RECT = .{
            .left = r.left + l.m.pad,
            .top = r.top,
            .right = l.closeRect(index).left - @divTrunc(l.m.pad, 2),
            .bottom = r.bottom,
        };
        _ = win32.SetTextColor(mem, if (shown) colors.text else colors.dim);
        const title = wideFromUtf8(alloc, Window.tabTitle(t) orelse "Ghostty") catch null;
        defer if (title) |w| alloc.free(w);
        if (title) |w| _ = win32.DrawTextW(mem, w.ptr, @intCast(w.len), &text_rect, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_END_ELLIPSIS | win32.DT_NOPREFIX);

        var close = l.closeRect(index);
        if (std.meta.eql(window.bar.hover, Hit{ .close = index })) fill(mem, close, colors.shown);
        _ = win32.SetTextColor(mem, colors.dim);
        _ = win32.DrawTextW(mem, L("\u{00D7}"), 1, &close, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_CENTER | win32.DT_NOPREFIX);
    }

    // Over any tab scrolled under it.
    var plus = l.plusRect();
    fill(mem, plus, if (window.bar.hover == .plus) colors.hover else colors.bar);
    _ = win32.SetTextColor(mem, colors.text);
    _ = win32.DrawTextW(mem, L("+"), 1, &plus, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_CENTER | win32.DT_NOPREFIX);

    _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
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

    pub fn init(dpi: u32) Metrics {
        return .{
            .height = scale(34, dpi),
            .tab_min = scale(72, dpi),
            .tab_max = scale(220, dpi),
            .plus = scale(34, dpi),
            .close = scale(16, dpi),
            .pad = scale(8, dpi),
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
        const t = self.tabRect(index);
        const top = @divTrunc(self.m.height - self.m.close, 2);
        return .{
            .left = t.right - self.m.pad - self.m.close,
            .top = top,
            .right = t.right - self.m.pad,
            .bottom = top + self.m.close,
        };
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
};

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
