//! A terminal's link preview, as GTK shows the URL of the link under the
//! pointer in a label over the bottom-left corner of its surface
//! (`url_left` in src/apprt/gtk/ui/1.0/surface.blp): the core's
//! `mouse_over_link` gives the URL, and an empty one hides it. While the
//! pointer is over the label's place, it shows at the bottom-right corner
//! instead, as GTK shows `url_right` while the pointer is over `url_left`.
//! GTK's label does not ellipsize, so a URL wider than its terminal is cut
//! at the terminal's edge: at the left the URL's start shows, at the right
//! its end. Control, bidirectional and zero-width code points show
//! escaped, as the macOS app's preview shows them (`displayText`); GTK's
//! label shows them as they are.
//!
//! Like the search bar (SearchBar.zig), the preview is a child window of
//! the terminal's **frame**, placed above the terminal's own window: GDI
//! drawn in a child of the window that owns a flip-model swap chain is
//! never composed. So every path that lays terminals out places it
//! (`place`, from `Window.relayout`), a hidden tab's is hidden with its
//! terminals, and it follows its terminal to a new frame. It sits just
//! above its own terminal, under the terminal's search bar and the
//! window's command palette.
//!
//! It is passive: it answers WM_NCHITTEST with HTTRANSPARENT, so the
//! pointer and clicks over it go to the terminal under it, which keeps
//! tracking the link, and it is never given the focus. Whether the
//! pointer is over its place is the terminal's to say (`pointerAt`, from
//! its WM_MOUSEMOVE).
//!
//! The core gives the URL from its cursor and key callbacks, mostly with
//! its renderer's lock held. Showing, moving, hiding and retitling the
//! preview send messages to it and to the terminal it uncovers, none of
//! which enter the core (the terminal's paint comes later, from the
//! loop). What waits for the core's frame to return is narrower than
//! any window: terminals, since "Creating a terminal there would register
//! a surface with the core in the middle of that frame" and "laying
//! terminals out sends them WM_SIZE, which enters the core"
//! (`App.requests`), and the focus, since "moving the focus inside it
//! would send WM_KILLFOCUS into a surface whose key callback is on the
//! stack" (`App.search_focus`). A passive window may be made there, as
//! `SearchBar.start` makes the search bar's. The preview's window is made,
//! hidden, with its terminal's (`create`) so that the first preview
//! shows without a window being made as the pointer reaches a link, and
//! nothing about the window can fail then. The cost is one hidden window
//! for every terminal, also when `link-previews` is false.

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const SearchBar = @import("SearchBar.zig");
const messageFont = @import("TabBar.zig").messageFont;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const unsafeCodepoint = @import("App.zig").unsafeCodepoint;

const RECT = win32.RECT;
const L = win32.L;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyLinkPreviewClass";

/// For tests: how many messages a preview's window got after its terminal
/// had let go of it (`Preview.deinit`), which the default procedure
/// handled.
pub var test_detached: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

/// A terminal's preview (`Surface.link_preview`).
pub const Preview = struct {
    /// The preview's window, a child of the terminal's frame, made with
    /// the terminal; null if it could not be made, and once it is
    /// destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The URL shown, and the same as the window draws it, both owned;
    /// null while there is none.
    url: ?[]u8 = null,
    text: ?[:0]u16 = null,
    /// The size of `text` in `font`; measured again when either changes.
    text_size: Size = .{ .width = 0, .height = 0 },
    measured: bool = false,
    /// Where the pointer is over the terminal, in its client coordinates,
    /// from its last WM_MOUSEMOVE; null once it has left.
    pointer: ?win32.POINT = null,
    /// The corner it shows at, as it was last placed.
    side: Side = .left,
    /// The system's message font at `font_dpi` (`applyFont`).
    font: ?win32.HGDIOBJ = null,
    font_dpi: u32 = 0,

    /// Hide the window, as when its terminal is hidden; the URL stays.
    pub fn hideWindow(self: *const Preview) void {
        const hwnd = self.hwnd orelse return;
        if (SearchBar.visibleStyle(hwnd)) _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    }

    /// Destroy the window, for a terminal leaving its window
    /// (`Surface.destroy`) or never put in one (`Surface.discard`).
    pub fn destroy(self: *const Preview) void {
        const hwnd = self.hwnd orelse return;
        _ = win32.DestroyWindow(hwnd);
    }

    /// Let go of the window and free the URL and the font, as the terminal
    /// is freed (`Surface.deinit`). The window may outlive the terminal by
    /// a few messages: when a frame is destroyed, Windows sends WM_DESTROY
    /// to its children in an order of its own, so the window loses its
    /// back-pointer, as the search bar's does, and goes with its frame.
    pub fn deinit(self: *Preview, alloc: std.mem.Allocator) void {
        if (self.hwnd) |hwnd| _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        self.hwnd = null;
        self.clear(alloc);
        if (self.font) |f| _ = win32.DeleteObject(f);
        self.font = null;
        self.font_dpi = 0;
    }

    /// Take `url`, not empty, and the text shown for it (`displayText`),
    /// while there is none.
    fn take(self: *Preview, alloc: std.mem.Allocator, url: []const u8) !void {
        const copy = try alloc.dupe(u8, url);
        errdefer alloc.free(copy);
        self.text = try displayText(alloc, url);
        self.url = copy;
    }

    /// Forget the URL.
    fn clear(self: *Preview, alloc: std.mem.Allocator) void {
        if (self.url) |v| alloc.free(v);
        self.url = null;
        if (self.text) |v| alloc.free(v);
        self.text = null;
        self.measured = false;
    }

    /// Draw it again: the theme changed.
    pub fn invalidate(self: *const Preview) void {
        if (self.hwnd) |hwnd| _ = win32.InvalidateRect(hwnd, null, .FALSE);
    }

    /// The system's message font changed: made again at the next placement.
    pub fn fontChanged(self: *Preview) void {
        self.font_dpi = 0;
    }

    /// The message font at `dpi`, made once for each DPI, the new one
    /// before the old one goes, which is kept if it cannot be made; and
    /// the text measured in it.
    fn applyFont(self: *Preview, dpi: u32) void {
        if (self.font == null or self.font_dpi != dpi) {
            if (messageFont(dpi)) |font| {
                if (self.font) |old| _ = win32.DeleteObject(old);
                self.font = font;
                self.font_dpi = dpi;
                self.measured = false;
            }
        }
        if (!self.measured) self.measure();
    }

    fn measure(self: *Preview) void {
        self.measured = true;
        self.text_size = .{ .width = 0, .height = 0 };
        const text = self.text orelse return;
        const hwnd = self.hwnd orelse return;
        const hdc = win32.GetDC(hwnd) orelse return;
        defer _ = win32.ReleaseDC(hwnd, hdc);
        const old = if (self.font) |f| win32.SelectObject(hdc, f) else null;
        defer if (old) |o| {
            _ = win32.SelectObject(hdc, o);
        };
        var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = win32.DrawTextW(hdc, text.ptr, std.math.lossyCast(c_int, text.len), &r, text_format | win32.DT_CALCRECT);
        self.text_size = .{ .width = r.right - r.left, .height = r.bottom - r.top };
    }
};

/// One line, `&` drawn as itself: CR and LF in a URL break nothing.
const text_format = win32.DT_SINGLELINE | win32.DT_NOPREFIX;

/// Make `surface`'s preview window, hidden, in its frame, as its
/// terminal's own is made (`Surface.create`). Without one, logged, the
/// terminal shows no previews.
pub fn create(surface: *Surface) void {
    const preview = &surface.link_preview;
    if (preview.hwnd != null) return;
    preview.hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        null,
        win32.WS_CHILD | win32.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        surface.window.hwnd,
        null,
        surface.app.hinstance,
        surface,
    ) orelse {
        log.warn("cannot make a link preview err={}", .{win32.GetLastError()});
        return;
    };
}

/// `mouse_over_link` on `surface`: show `url` in its preview, over its
/// terminal's bottom-left corner, or hide the preview when `url` is
/// empty, as GTK's label shows while the URL is not empty. False if the
/// terminal has no preview, or the URL cannot be copied or its text made
/// (the preview is hidden then: an older URL would name another link).
///
/// The core performs this inside its cursor and key callbacks, which
/// send the same URL again on every move over a link; nothing is drawn
/// again unless something changed.
pub fn show(surface: *Surface, url: []const u8) bool {
    const preview = &surface.link_preview;
    const hwnd = preview.hwnd orelse return false;
    const alloc = surface.app.core_app.alloc;
    const same = if (preview.url) |v| std.mem.eql(u8, v, url) else url.len == 0;
    if (!same) {
        preview.clear(alloc);
        const taken = if (url.len > 0) preview.take(alloc, url) else {};
        // Its name, for what reads windows' text, as screen readers do.
        _ = win32.SetWindowTextW(hwnd, if (preview.text) |t| t.ptr else L(""));
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
        taken catch |err| {
            log.warn("cannot show a link preview len={d} err={}", .{ url.len, err });
            preview.hideWindow();
            return false;
        };
    }
    place(surface);
    return true;
}

/// `url` as its preview shows it, NUL-terminated: each code point that can
/// hide part of the target or add a line (`unsafeCodepoint`) written as
/// its value in upper-case hex without leading zeros, `\u{202E}` or
/// `\u{85}`, as the macOS app's preview writes it
/// (`UntrustedURL.displayString`); each invalid UTF-8 sequence as U+FFFD.
/// The caller frees it.
fn displayText(alloc: std.mem.Allocator, url: []const u8) ![:0]u16 {
    const wide = try wideFromUtf8(alloc, url);
    // Unit by unit: every such code point is in the BMP and none is a
    // surrogate, so a unit of a surrogate pair is never one.
    for (wide) |unit| {
        if (unsafeCodepoint(unit)) break;
    } else return wide;
    defer alloc.free(wide);

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(alloc);
    for (wide) |unit| {
        if (!unsafeCodepoint(unit)) {
            try out.append(alloc, unit);
            continue;
        }
        var buf: ["\\u{FEFF}".len]u8 = undefined;
        const escaped = std.fmt.bufPrint(&buf, "\\u{{{X}}}", .{unit}) catch unreachable;
        for (escaped) |c| try out.append(alloc, c);
    }
    return out.toOwnedSliceSentinel(alloc, 0);
}

/// The pointer moved over `surface`'s terminal, to `at` in its client
/// coordinates, or left it (null): a preview that shows goes to the
/// other corner if the pointer came over its place or left it.
pub fn pointerAt(surface: *Surface, at: ?win32.POINT) void {
    const preview = &surface.link_preview;
    preview.pointer = at;
    const hwnd = preview.hwnd orelse return;
    if (preview.text != null and SearchBar.visibleStyle(hwnd)) place(surface);
}

/// Place `surface`'s preview over its terminal's bottom-left corner, or
/// its bottom-right while the pointer is over the bottom-left place
/// (`sideFor`), just above the terminal; or hide it while it has no URL
/// or the terminal is hidden (a hidden tab, a zoom). A preview whose
/// terminal moved to another frame (`Window.moveTabTo`) goes there first;
/// one that cannot is destroyed, logged, and the terminal shows no more
/// previews.
///
/// The terminals tile their area, and the search bars and the command
/// palette are placed above all of them (`SearchBar.place`,
/// `CommandPalette.place`), so just above its own terminal the preview
/// covers nothing but that terminal, under its search bar and the
/// palette, wherever it is placed from.
pub fn place(surface: *Surface) void {
    const preview = &surface.link_preview;
    const hwnd = preview.hwnd orelse return;
    const window = surface.window;
    if (win32.GetAncestor(hwnd, win32.GA_PARENT) != window.hwnd) {
        if (win32.SetParent(hwnd, window.hwnd) == null) {
            log.warn("cannot move a link preview to its terminal's new frame err={}", .{win32.GetLastError()});
            _ = win32.DestroyWindow(hwnd);
            return;
        }
    }
    if (preview.text == null or !SearchBar.visibleStyle(surface.hwnd)) return preview.hideWindow();
    var pane: RECT = undefined;
    if (!win32.GetWindowRect(surface.hwnd, &pane).toBool() or !window.toClient(&pane)) return preview.hideWindow();
    const dpi = Window.dpiOf(surface.app, window.hwnd);
    preview.applyFont(dpi);
    const m = Metrics.init(dpi);
    const size: Size = .{ .width = pane.right - pane.left, .height = pane.bottom - pane.top };
    const side = sideFor(m, size, preview.text_size, preview.pointer);
    const in = rectIn(m, size, preview.text_size, side) orelse return preview.hideWindow();
    const at: RECT = .{ .left = pane.left + in.left, .top = pane.top + in.top, .right = pane.left + in.right, .bottom = pane.top + in.bottom };

    const above = win32.GetWindow(surface.hwnd, win32.GW_HWNDPREV);
    var now: RECT = undefined;
    const in_place = SearchBar.visibleStyle(hwnd) and above == hwnd and
        win32.GetWindowRect(hwnd, &now).toBool() and window.toClient(&now) and
        std.meta.eql(now, at);
    if (in_place and side == preview.side) return;
    preview.side = side;
    if (!in_place) {
        // Just under the window above the terminal, or the top if none is.
        const flags = win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW | if (above == hwnd) win32.SWP_NOZORDER else 0;
        _ = win32.SetWindowPos(hwnd, above, at.left, at.top, at.right - at.left, at.bottom - at.top, flags);
    }
    _ = win32.InvalidateRect(hwnd, null, .FALSE);
}

/// The terminal whose preview the window `hwnd` is, null once it is freed.
fn surfaceOf(hwnd: win32.HWND) ?*Surface {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The preview's window procedure. WM_NCCREATE brings its terminal.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_NCCREATE => {
            const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (cs.lpCreateParams) |param| {
                _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(param)));
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The pointer and clicks over it are the terminal's under it,
        // which Windows gives them to instead, being of the same thread.
        win32.WM_NCHITTEST => return win32.HTTRANSPARENT,
        else => {},
    }
    const surface = surfaceOf(hwnd) orelse {
        if (builtin.is_test) test_detached += 1;
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    };
    const preview = &surface.link_preview;

    switch (msg) {
        // All of it is painted, from a bitmap.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            paint(surface, hwnd);
            return 0;
        },

        win32.WM_DESTROY => {
            // Nothing places or draws into a destroyed window; the URL and
            // the font are freed with the terminal.
            preview.hwnd = null;
            return 0;
        },

        win32.WM_NCDESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        },

        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The URL on the search bar's colours, framed as GTK's label is.
fn paint(surface: *Surface, hwnd: win32.HWND) void {
    const preview = &surface.link_preview;
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

    const dpi = Window.dpiOf(surface.app, hwnd);
    const colors = SearchBar.Colors.of(surface.window.dark_frame);
    const line = @max(1, SearchBar.Metrics.scale(1, dpi));
    SearchBar.fill(mem, client, colors.border);
    SearchBar.fill(mem, SearchBar.inset(client, line), colors.bar);

    if (preview.text) |text| {
        _ = win32.SetBkMode(mem, win32.TRANSPARENT);
        _ = win32.SetTextColor(mem, colors.text);
        const old_font = if (preview.font) |f| win32.SelectObject(mem, f) else null;
        defer if (old_font) |f| {
            _ = win32.SelectObject(mem, f);
        };
        var r = textRect(.init(dpi), client.right, preview.text_size, preview.side);
        _ = win32.DrawTextW(mem, text.ptr, std.math.lossyCast(c_int, text.len), &r, text_format);
    }

    _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
}

pub const Size = struct { width: i32, height: i32 };

/// The corner a preview shows at.
pub const Side = enum { left, right };

/// The preview's sizes at a DPI, from GTK's at 96 (`label.url-overlay` in
/// src/apprt/gtk/css/style.css: padding 4px 8px).
pub const Metrics = struct {
    /// Between the text and the preview's left and right edges.
    pad_x: i32,
    /// Between the text and its top and bottom edges.
    pad_y: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .pad_x = SearchBar.Metrics.scale(8, dpi),
            .pad_y = SearchBar.Metrics.scale(4, dpi),
        };
    }
};

/// Where a preview of text `text` big goes over a terminal `pane` big, in
/// the terminal's client coordinates: in its bottom-left or bottom-right
/// corner, as wide and tall as the text with its padding, but no wider or
/// taller than the terminal, as GTK's label is drawn only over its
/// surface; null for a terminal with no area.
pub fn rectIn(m: Metrics, pane: Size, text: Size, side: Side) ?RECT {
    if (pane.width <= 0 or pane.height <= 0) return null;
    const width = @min(@max(0, text.width) + 2 * m.pad_x, pane.width);
    const height = @min(@max(0, text.height) + 2 * m.pad_y, pane.height);
    const left = switch (side) {
        .left => 0,
        .right => pane.width - width,
    };
    return .{ .left = left, .top = pane.height - height, .right = left + width, .bottom = pane.height };
}

/// The corner for a preview of text `text` big over a terminal `pane`
/// big with the pointer at `pointer`: the right while the pointer is over
/// the preview's place at the left, as GTK shows `url_right` while the
/// pointer is over `url_left`, else the left.
pub fn sideFor(m: Metrics, pane: Size, text: Size, pointer: ?win32.POINT) Side {
    const pt = pointer orelse return .left;
    const left = rectIn(m, pane, text, .left) orelse return .left;
    const over = pt.x >= left.left and pt.x < left.right and pt.y >= left.top and pt.y < left.bottom;
    return if (over) .right else .left;
}

/// Where the text goes in a preview `width` wide at `side`, in its client
/// coordinates. GTK's labels are as wide as their text: `url_left` starts
/// at its surface's left edge and `url_right` ends at its right edge, and
/// what goes past the other edge is cut. So at the left the text starts
/// `pad_x` in from the left, and at the right it ends `pad_x` in from the
/// right, and starts before the left edge when it is too wide.
pub fn textRect(m: Metrics, width: i32, text: Size, side: Side) RECT {
    const left = switch (side) {
        .left => m.pad_x,
        .right => width - m.pad_x - text.width,
    };
    return .{ .left = left, .top = m.pad_y, .right = left + text.width, .bottom = m.pad_y + text.height };
}

test "win32: a link preview sits in its terminal's bottom corner, as wide as its URL" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(8, m.pad_x);
    try testing.expectEqual(4, m.pad_y);
    try testing.expectEqual(12, Metrics.init(144).pad_x);
    try testing.expectEqual(6, Metrics.init(144).pad_y);

    const pane: Size = .{ .width = 800, .height = 600 };
    const text: Size = .{ .width = 200, .height = 16 };
    try testing.expectEqual(RECT{ .left = 0, .top = 576, .right = 216, .bottom = 600 }, rectIn(m, pane, text, .left).?);
    try testing.expectEqual(RECT{ .left = 584, .top = 576, .right = 800, .bottom = 600 }, rectIn(m, pane, text, .right).?);

    // Wider than its terminal: as wide as it, from either side.
    const wide: Size = .{ .width = 900, .height = 16 };
    try testing.expectEqual(RECT{ .left = 0, .top = 576, .right = 800, .bottom = 600 }, rectIn(m, pane, wide, .left).?);
    try testing.expectEqual(RECT{ .left = 0, .top = 576, .right = 800, .bottom = 600 }, rectIn(m, pane, wide, .right).?);
    // Taller: as tall.
    try testing.expectEqual(RECT{ .left = 0, .top = 0, .right = 216, .bottom = 20 }, rectIn(m, .{ .width = 800, .height = 20 }, text, .left).?);
    // No area: nowhere.
    try testing.expect(rectIn(m, .{ .width = 0, .height = 600 }, text, .left) == null);
    try testing.expect(rectIn(m, .{ .width = 800, .height = 0 }, text, .right) == null);
}

test "win32: a link preview moves right while the pointer is over its place at the left" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const pane: Size = .{ .width = 800, .height = 600 };
    const text: Size = .{ .width = 200, .height = 16 };
    // Its place at the left is (0,576)-(216,600).
    try testing.expectEqual(Side.left, sideFor(m, pane, text, null));
    try testing.expectEqual(Side.right, sideFor(m, pane, text, .{ .x = 0, .y = 576 }));
    try testing.expectEqual(Side.right, sideFor(m, pane, text, .{ .x = 215, .y = 599 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 216, .y = 590 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 100, .y = 575 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 100, .y = 600 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = -1, .y = 590 }));
    // Over its place at the right, which GTK does not watch: the left.
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 700, .y = 590 }));
    // As wide as the terminal: anywhere along its bottom.
    try testing.expectEqual(Side.right, sideFor(m, pane, .{ .width = 900, .height = 16 }, .{ .x = 799, .y = 590 }));
    try testing.expectEqual(Side.left, sideFor(m, .{ .width = 0, .height = 0 }, text, .{ .x = 0, .y = 0 }));
}

test "win32: a link preview too wide for its terminal shows the URL's start at the left and its end at the right" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const text: Size = .{ .width = 200, .height = 16 };
    try testing.expectEqual(RECT{ .left = 8, .top = 4, .right = 208, .bottom = 20 }, textRect(m, 216, text, .left));
    try testing.expectEqual(RECT{ .left = 8, .top = 4, .right = 208, .bottom = 20 }, textRect(m, 216, text, .right));
    // Cut to 100: the start shows at the left, the end at the right.
    try testing.expectEqual(RECT{ .left = 8, .top = 4, .right = 208, .bottom = 20 }, textRect(m, 100, text, .left));
    try testing.expectEqual(RECT{ .left = -108, .top = 4, .right = 92, .bottom = 20 }, textRect(m, 100, text, .right));
}
