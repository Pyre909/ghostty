//! A terminal's passive overlays: windows that show something about the
//! terminal over it and take no input, as GTK stacks overlays over its
//! surface (src/apprt/gtk/ui/1.0/surface.blp): the link preview
//! (LinkPreview.zig) and the key-state indicator (KeyState.zig). This
//! file does for each what they all need: their window class and
//! procedure, their place in the Z order, their font, colours and frame,
//! and their teardown; each overlay's own file says what it shows and
//! where (`placeIn`, `textIn`).
//!
//! Like the search bar (SearchBar.zig), an overlay is a child window of
//! the terminal's **frame**, placed above the terminal's own window: GDI
//! drawn in a child of the window that owns a flip-model swap chain is
//! never composed. So every path that lays terminals out places them
//! (`place`, from `Window.relayout`), a hidden tab's are hidden with its
//! terminals, and they follow their terminal to a new frame. They sit
//! just above their own terminal, in GTK's order (`stack`), under the
//! terminal's search bar and the window's command palette.
//!
//! They are passive: each answers WM_NCHITTEST with HTTRANSPARENT, so the
//! pointer and clicks over it go to the terminal under it, and none is
//! ever given the focus. Each draws a line of text in the system's
//! message font, one for all of a terminal's overlays (`font`), on the
//! search bar's colours, framed as GTK's labels are.

const Overlays = @This();

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const SearchBar = @import("SearchBar.zig");
const LinkPreview = @import("LinkPreview.zig");
const KeyState = @import("KeyState.zig");
const messageFont = @import("TabBar.zig").messageFont;

const RECT = win32.RECT;
const L = win32.L;
const log = std.log.scoped(.win32);

/// The link preview, made, hidden, with its terminal (`create`).
link_preview: LinkPreview.Preview = .{},

/// The key-state indicator, made the first time it has something to show
/// (`KeyState.sequence`, `KeyState.table`).
key_state: KeyState.Indicator = .{},

/// The system's message font at `font_dpi`, which every overlay draws
/// in, made as the first of them is placed with something to show
/// (`applyFont`).
font: ?win32.HGDIOBJ = null,
font_dpi: u32 = 0,

/// The overlays, by their fields, bottom to top, as GTK stacks them over
/// its surface (surface.blp). Each has a window `hwnd`, the `text` it
/// draws, `text_size` and `measured` for that text in `font`, and
/// `placeIn`, `textIn` and `deinit`.
const stack = [_][]const u8{ "link_preview", "key_state" };

/// Each overlay's window class, all with `wndProc`: one for each, so that
/// what reads windows can tell them apart.
const classes = [_][]const u8{ LinkPreview.class_name, KeyState.class_name };

/// For tests: how many messages an overlay's window got after its
/// terminal had let go of it (`deinit`), which the default procedure
/// handled.
pub var test_detached: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

pub const Size = struct { width: i32, height: i32 };

/// Where an overlay goes over its terminal, in the terminal's client
/// coordinates (`placeIn`), and whether it must be drawn again though it
/// stays there.
pub const Placed = struct { in: RECT, redraw: bool };

/// One line, `&` drawn as itself: CR and LF in the text break nothing.
const text_format = win32.DT_SINGLELINE | win32.DT_NOPREFIX;

/// Hide the windows, as when their terminal is hidden; what they show
/// stays.
pub fn hideWindows(self: *const Overlays) void {
    inline for (stack) |name| hideWindow(@field(self, name).hwnd);
}

/// Hide `hwnd`, if there is one and it shows.
pub fn hideWindow(hwnd: ?win32.HWND) void {
    const h = hwnd orelse return;
    if (SearchBar.visibleStyle(h)) _ = win32.ShowWindow(h, win32.SW_HIDE);
}

/// Destroy the windows, for a terminal leaving its window
/// (`Surface.destroy`) or never put in one (`Surface.discard`).
pub fn destroy(self: *const Overlays) void {
    inline for (stack) |name| {
        if (@field(self, name).hwnd) |hwnd| _ = win32.DestroyWindow(hwnd);
    }
}

/// Let go of the windows and free what they show and the font, as the
/// terminal is freed (`Surface.deinit`). A window may outlive the terminal
/// by a few messages: when a frame is destroyed, Windows sends WM_DESTROY
/// to its children in an order of its own, so each window loses its
/// back-pointer, as the search bar's does, and goes with its frame.
pub fn deinit(self: *Overlays, alloc: std.mem.Allocator) void {
    inline for (stack) |name| {
        const o = &@field(self, name);
        if (o.hwnd) |hwnd| _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        o.hwnd = null;
        o.deinit(alloc);
    }
    if (self.font) |f| _ = win32.DeleteObject(f);
    self.font = null;
    self.font_dpi = 0;
}

/// Draw them again: the theme changed.
pub fn invalidate(self: *const Overlays) void {
    inline for (stack) |name| {
        if (@field(self, name).hwnd) |hwnd| _ = win32.InvalidateRect(hwnd, null, .FALSE);
    }
}

/// The system's message font changed: made again at the next placement.
pub fn fontChanged(self: *Overlays) void {
    self.font_dpi = 0;
}

/// The message font at `dpi`, made once for each DPI, the new one before
/// the old one goes, which is kept if it cannot be made; every overlay's
/// text is measured again in a new one.
fn applyFont(self: *Overlays, dpi: u32) void {
    if (self.font == null or self.font_dpi != dpi) {
        if (messageFont(dpi)) |font| {
            if (self.font) |old| _ = win32.DeleteObject(old);
            self.font = font;
            self.font_dpi = dpi;
            inline for (stack) |name| @field(self, name).measured = false;
        }
    }
}

/// The size of `text` in `font`, as `hwnd` draws it; none if it cannot be
/// measured.
fn measure(hwnd: win32.HWND, font: ?win32.HGDIOBJ, text: [:0]const u16) Size {
    const hdc = win32.GetDC(hwnd) orelse return .{ .width = 0, .height = 0 };
    defer _ = win32.ReleaseDC(hwnd, hdc);
    const old = if (font) |f| win32.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = win32.SelectObject(hdc, o);
    };
    var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.DrawTextW(hdc, text.ptr, std.math.lossyCast(c_int, text.len), &r, text_format | win32.DT_CALCRECT);
    return .{ .width = r.right - r.left, .height = r.bottom - r.top };
}

/// Make the overlays made with `surface`'s own window (`Surface.create`),
/// hidden, in its frame: its link preview. Without one, logged, the
/// terminal shows no previews.
pub fn create(surface: *Surface) void {
    const preview = &surface.overlays.link_preview;
    if (preview.hwnd != null) return;
    preview.hwnd = make(surface, LinkPreview.class_name) orelse {
        log.warn("cannot make a link preview err={}", .{win32.GetLastError()});
        return;
    };
}

/// A hidden window of the overlay class `class` in `surface`'s frame,
/// whose procedure finds `surface` from its WM_NCCREATE; null if it cannot
/// be made.
pub fn make(surface: *Surface, comptime class: []const u8) ?win32.HWND {
    return win32.CreateWindowExW(
        0,
        L(class),
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
    );
}

/// Place `surface`'s overlays over its terminal, each where its own file
/// says (`placeIn`), the first that shows just above the terminal and
/// each other one just above the one under it in `stack`; or hide those
/// with nothing to show, and all of them while the terminal is hidden (a
/// hidden tab, a zoom). Overlays whose terminal moved to another frame
/// (`Window.moveTabTo`) go there first; one that cannot is destroyed,
/// logged, and the terminal shows no more of it.
///
/// The terminals tile their area, and the search bars and the command
/// palette are placed above all of them (`SearchBar.place`,
/// `CommandPalette.place`), so just above its own terminal an overlay
/// covers nothing but that terminal, under its search bar and the
/// palette, wherever it is placed from.
pub fn place(surface: *Surface) void {
    const self = &surface.overlays;
    const window = surface.window;
    inline for (stack) |name| {
        if (@field(self, name).hwnd) |hwnd| reparent(hwnd, window, name);
    }
    const pane = paneRect(surface) orelse return self.hideWindows();
    const size: Size = .{ .width = pane.right - pane.left, .height = pane.bottom - pane.top };
    const dpi = Window.dpiOf(surface.app, window.hwnd);
    var under = surface.hwnd;
    inline for (stack) |name| {
        const o = &@field(self, name);
        if (o.hwnd) |hwnd| {
            if (self.placed(o, hwnd, dpi, size)) |p| {
                const at: RECT = .{ .left = pane.left + p.in.left, .top = pane.top + p.in.top, .right = pane.left + p.in.right, .bottom = pane.top + p.in.bottom };
                const moved = put(window, hwnd, under, at);
                if (moved or p.redraw) _ = win32.InvalidateRect(hwnd, null, .FALSE);
                under = hwnd;
            } else hideWindow(hwnd);
        }
    }
}

/// Where the overlay `o`, whose window is `hwnd`, goes over a terminal
/// `pane` big (`placeIn`), its text measured first in the font at `dpi`;
/// null while it has nothing to show, or no place.
fn placed(self: *Overlays, o: anytype, hwnd: win32.HWND, dpi: u32, pane: Size) ?Placed {
    const text = o.text orelse return null;
    self.applyFont(dpi);
    if (!o.measured) {
        o.measured = true;
        o.text_size = measure(hwnd, self.font, text);
    }
    return o.placeIn(dpi, pane);
}

/// Move `hwnd` into `window`'s frame if it is not there: its terminal
/// moved to another frame. If it cannot, it is destroyed (its WM_DESTROY
/// forgets it).
fn reparent(hwnd: win32.HWND, window: *const Window, comptime name: []const u8) void {
    if (win32.GetAncestor(hwnd, win32.GA_PARENT) != window.hwnd) {
        if (win32.SetParent(hwnd, window.hwnd) == null) {
            log.warn("cannot move an overlay to its terminal's new frame overlay={s} err={}", .{ name, win32.GetLastError() });
            _ = win32.DestroyWindow(hwnd);
        }
    }
}

/// `surface`'s client area in its frame's client coordinates; null while
/// the terminal is hidden: a hidden tab's terminals are hidden
/// (`Window.selectTab`), and so is one a zoom hides (`Window.layout`).
fn paneRect(surface: *const Surface) ?RECT {
    if (!SearchBar.visibleStyle(surface.hwnd)) return null;
    var client: RECT = undefined;
    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    if (!win32.GetClientRect(surface.hwnd, &client).toBool() or
        !win32.ClientToScreen(surface.hwnd, &origin).toBool() or
        !win32.ScreenToClient(surface.window.hwnd, &origin).toBool()) return null;
    return .{ .left = origin.x, .top = origin.y, .right = origin.x + client.right, .bottom = origin.y + client.bottom };
}

/// Show `hwnd` at `at`, in its frame's client coordinates, just above
/// `under`. Whether it was moved, sized, shown or put back in its place
/// in the Z order, and so is to be drawn again; nothing is done for one
/// already there.
fn put(window: *const Window, hwnd: win32.HWND, under: win32.HWND, at: RECT) bool {
    const above = win32.GetWindow(under, win32.GW_HWNDPREV);
    var now: RECT = undefined;
    const in_place = SearchBar.visibleStyle(hwnd) and above == hwnd and
        win32.GetWindowRect(hwnd, &now).toBool() and window.toClient(&now) and
        std.meta.eql(now, at);
    if (in_place) return false;
    // Just under the window above `under`, or the top if none is.
    const flags = win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW | if (above == hwnd) win32.SWP_NOZORDER else 0;
    _ = win32.SetWindowPos(hwnd, above, at.left, at.top, at.right - at.left, at.bottom - at.top, flags);
    return true;
}

/// Register `classes`, with `cursor`, which never shows: the terminal
/// under an overlay takes the pointer (WM_NCHITTEST). Each overlay draws
/// itself through GDI and is invalidated when it is placed somewhere new,
/// its text changes or the theme does (`place`, `invalidate`).
pub fn registerClasses(hinstance: win32.HINSTANCE, cursor: ?win32.HCURSOR) App.Error!void {
    inline for (classes, 0..) |name, i| {
        const class: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = cursor,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = L(name),
            .hIconSm = null,
        };
        if (win32.RegisterClassExW(&class) == 0) {
            log.err("failed to register an overlay class class={s} err={}", .{ name, win32.GetLastError() });
            unregisterFirst(hinstance, i);
            return App.Error.Win32ClassRegistrationFailed;
        }
    }
}

pub fn unregisterClasses(hinstance: win32.HINSTANCE) void {
    unregisterFirst(hinstance, classes.len);
}

fn unregisterFirst(hinstance: win32.HINSTANCE, n: usize) void {
    inline for (classes, 0..) |name, i| {
        if (i < n) _ = win32.UnregisterClassW(L(name), hinstance);
    }
}

/// The terminal whose overlay the window `hwnd` is, null once it is freed.
fn surfaceOf(hwnd: win32.HWND) ?*Surface {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// Every overlay's window procedure. WM_NCCREATE brings its terminal.
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

    switch (msg) {
        // All of it is painted, from a bitmap.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            paint(surface, hwnd);
            return 0;
        },

        win32.WM_DESTROY => {
            // Nothing places or draws into a destroyed window; what it
            // shows and the font are freed with the terminal.
            inline for (stack) |name| {
                const o = &@field(surface.overlays, name);
                if (o.hwnd == hwnd) o.hwnd = null;
            }
            return 0;
        },

        win32.WM_NCDESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        },

        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The overlay's text on the search bar's colours, framed as GTK's labels
/// are, where its own file puts it (`textIn`).
fn paint(surface: *Surface, hwnd: win32.HWND) void {
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

    inline for (stack) |name| {
        const o = &@field(surface.overlays, name);
        if (o.hwnd == hwnd) {
            if (o.text) |text| {
                _ = win32.SetBkMode(mem, win32.TRANSPARENT);
                _ = win32.SetTextColor(mem, colors.text);
                const old_font = if (surface.overlays.font) |f| win32.SelectObject(mem, f) else null;
                defer if (old_font) |f| {
                    _ = win32.SelectObject(mem, f);
                };
                var r = o.textIn(dpi, client.right);
                _ = win32.DrawTextW(mem, text.ptr, std.math.lossyCast(c_int, text.len), &r, text_format);
            }
        }
    }

    _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
}
