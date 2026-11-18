//! A terminal's drag handle (`drag-handle`): a strip across the top of
//! the terminal, by which it is dragged onto another terminal, of its tab
//! or of another window, to go beside it (`Window.dropPane`), as GTK's
//! handle drags a split (src/apprt/gtk/ui/1.0/surface.blp, `surfaceDrop`
//! in src/apprt/gtk/class/surface.zig).
//!
//! It looks as GTK's does (`.drag-handle` in src/apprt/gtk/css/style.css):
//! a band of black at 15% over the terminal, as tall as a 16-pixel icon,
//! with three dots in its middle (`view-more-horizontal-symbolic`), in the
//! frame's text colour (`SearchBar.Colors.ofFrame`). It shows only while
//! the pointer is over it, as GTK's turns opaque on `:hover`, and, as
//! GTK's shows (`closureShouldDragHandleBeShown`): always, never, or by
//! default only over a terminal in a tab of more than one.
//!
//! It is one of the terminal's overlays (Overlays.zig), the top one, over
//! the dim of an unfocused split, as macOS keeps its grab handle above
//! that. Unlike the others it is drawn with per-pixel alpha, a layered
//! window given its pixels (`UpdateLayeredWindow`), so that the terminal
//! shows through the band and the dots do not; one that cannot be layered
//! is not shown, said once for the process (`cannot_layer`). GTK's handle
//! takes the pointer over its strip whether it shows or not; this one is
//! made to show by the terminal's own moves over the strip (`pointerAt`),
//! and then takes the pointer itself, until it leaves (WM_MOUSELEAVE).
//!
//! A press on it and a move past the system's drag threshold, as a tab is
//! dragged (`TabBar.pastDragThreshold`), drags the terminal; it holds the
//! mouse capture meanwhile. Released over a terminal (`paneAt`), the
//! dragged one goes to the side of it nearest the pointer
//! (`Window.dropSide`); anywhere else, nothing moves, as on GTK. Escape
//! (`cancelByKey`) or a capture taken away cancels it.

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const TabBar = @import("TabBar.zig");
const Config = @import("../../config.zig").Config;

const RECT = win32.RECT;
const POINT = win32.POINT;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyDragHandleClass";

/// A terminal's handle (`Overlays.drag_handle`).
pub const Handle = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// the pointer comes over the strip (`pointerAt`); null until then,
    /// if it could not be made, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// Whether the terminal has a handle, as `sync` last found.
    on: bool = false,
    /// The pointer is over the strip, or over the handle.
    hover: bool = false,
    /// A WM_MOUSELEAVE is asked for (TrackMouseEvent).
    tracking: bool = false,
    /// The left button went down on the handle, which holds the capture.
    press: ?Press = null,
    /// The dots' colour, as `sync` last found it.
    color: win32.COLORREF = 0,

    pub fn deinit(self: *Handle, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.on = false;
        self.hover = false;
        self.tracking = false;
        self.press = null;
    }

    /// For `Overlays.place`: it has no text to show it.
    pub fn shows(self: *const Handle) bool {
        return self.on and (self.hover or self.press != null);
    }

    /// Across the top of the terminal, `heightAt` tall, for
    /// `Overlays.place`.
    pub fn placeIn(self: *const Handle, dpi: u32, pane: Size) ?Overlays.Placed {
        _ = self;
        if (pane.width <= 0 or pane.height <= 0) return null;
        const height = @min(heightAt(dpi), pane.height);
        return .{ .in = .{ .left = 0, .top = 0, .right = pane.width, .bottom = height }, .redraw = false };
    }

    /// Its pixels for its place `in`, given to its layered window before
    /// it shows (`Overlays.place`): whether they were. Not shown if not.
    pub fn shape(self: *Handle, hwnd: win32.HWND, dpi: u32, in: RECT) bool {
        const size: Size = .{ .width = in.right - in.left, .height = in.bottom - in.top };
        if (size.width <= 0 or size.height <= 0) return false;
        if (builtin.is_test) if (test_update) |answer| return answer(hwnd, size);
        return update(hwnd, size, dpi, self.color);
    }

    /// Nothing: a window given its pixels (`update`) gets no WM_PAINT.
    pub fn draw(self: *const Handle, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = self;
        _ = hdc;
        _ = client;
        _ = dpi;
        _ = dark;
        _ = background;
        _ = font;
    }

    /// Its window `hwnd` is being hidden (`Overlays.hide`): it shows again
    /// only when the pointer next comes over the strip, and a press on it
    /// ends, with its capture.
    pub fn hidden(self: *Handle, hwnd: win32.HWND) void {
        self.hover = false;
        self.tracking = false;
        if (self.press == null) return;
        self.press = null;
        if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
    }

    /// The handle's own messages, which `Overlays.wndProc` hands it first:
    /// the hit test, the activation, the cursor, and the pointer and the
    /// left button over it. Null for the others.
    pub fn handle(self: *Handle, surface: *Surface, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
        _ = wparam;
        switch (msg) {
            // All of it takes the pointer, as GTK's handle does.
            win32.WM_NCHITTEST => return win32.HTCLIENT,

            // A press on it neither activates the frame nor moves the
            // focus out of the terminal.
            win32.WM_MOUSEACTIVATE => return win32.MA_NOACTIVATE,

            // GTK gives it the "grab" cursor, which Windows lacks; its
            // own for moving a thing is the four arrows.
            win32.WM_SETCURSOR => {
                _ = win32.SetCursor(win32.LoadCursorW(null, win32.IDC_SIZEALL));
                return 1;
            },

            win32.WM_MOUSEMOVE => {
                if (!self.tracking) self.tracking = track(hwnd);
                if (self.press) |*p| {
                    if (screenPoint(hwnd, lparam)) |at| {
                        if (TabBar.pastDragThreshold(p.at, at, p.threshold)) p.active = true;
                    }
                }
                return 0;
            },

            win32.WM_MOUSELEAVE => {
                self.tracking = false;
                if (self.press == null and self.hover) {
                    self.hover = false;
                    Overlays.place(surface);
                }
                return 0;
            },

            win32.WM_LBUTTONDOWN => {
                const at = screenPoint(hwnd, lparam) orelse return 0;
                // Captured first: SetCapture sends WM_CAPTURECHANGED to the
                // window that loses it, which would cancel a press.
                if (win32.GetCapture() != hwnd) _ = win32.SetCapture(hwnd);
                self.press = .{ .at = at, .threshold = TabBar.dragThreshold(Window.dpiOf(surface.app, hwnd)) };
                captured = hwnd;
                return 0;
            },

            win32.WM_LBUTTONUP => {
                const at = screenPoint(hwnd, lparam) orelse return 0;
                release(surface, hwnd, at);
                return 0;
            },

            // Another window took the capture, or Escape let it go
            // (`cancelByKey`): the drag ends, and nothing moves.
            win32.WM_CAPTURECHANGED => {
                if (self.press != null) {
                    self.press = null;
                    self.hover = false;
                    Overlays.place(surface);
                }
                return 0;
            },

            // Its press goes with it; then `Overlays.wndProc` forgets it.
            win32.WM_DESTROY => {
                self.press = null;
                if (captured == hwnd) captured = null;
                return null;
            },

            else => return null,
        }
    }
};

/// A left press on a handle, and the drag it becomes.
pub const Press = struct {
    /// Where the button went down, on the screen.
    at: POINT,
    /// SM_CXDRAG and SM_CYDRAG at the handle's DPI, read at the press.
    threshold: POINT,
    /// Whether the pointer went past the threshold: a drag, not a click.
    active: bool = false,
};

/// The height of a handle at `dpi`: that of a 16-pixel icon, as GTK's
/// handle holds one with no padding.
pub fn heightAt(dpi: u32) i32 {
    return @intCast((16 * @as(u64, dpi) + 48) / 96);
}

/// Whether `surface` has a handle under `mode`, as GTK's
/// `closureShouldDragHandleBeShown` says: always, never, or by default
/// in a tab of more than one terminal.
pub fn wanted(surface: *const Surface, mode: Config.DragHandle) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => if (surface.window.tabOf(surface)) |t| t.tree.isSplit() else false,
    };
}

/// Find whether `surface` has a handle, and its dots' colour, for
/// `Overlays.place`, which then places or hides it. One that no longer
/// has one stops showing.
pub fn sync(surface: *Surface, config: *const Config) void {
    const self = &surface.overlays.drag_handle;
    self.on = !cannot_layer and wanted(surface, config.@"drag-handle");
    self.color = SearchBar.Colors.ofFrame(surface.window).text;
}

/// The pointer moved over `surface` to `at`, in its client coordinates,
/// with a button `held` or not (its WM_MOUSEMOVE): over the strip with no
/// button held, the handle shows, its window made the first time, and
/// takes the pointer from there; off the strip, a handle that missed the
/// pointer's leave hides.
pub fn pointerAt(surface: *Surface, at: POINT, held: bool) void {
    const self = &surface.overlays.drag_handle;
    const dpi = Window.dpiOf(surface.app, surface.window.hwnd);
    const on_strip = !held and at.y >= 0 and at.y < heightAt(dpi);
    if (!on_strip) {
        if (self.hover and self.press == null) {
            self.hover = false;
            Overlays.place(surface);
        }
        return;
    }
    if (self.hover or cannot_layer) return;
    if (!wanted(surface, surface.app.config.@"drag-handle")) return;
    const hwnd = self.hwnd orelse made: {
        const made = make(surface) orelse return;
        self.hwnd = made;
        break :made made;
    };
    self.hover = true;
    Overlays.place(surface);
    if (!SearchBar.visibleStyle(hwnd)) self.hover = false;
    // Its leave is asked for at its own first move, which Windows sends
    // as it shows under the pointer: asked for now, before Windows has
    // seen the pointer over it, the leave would come at once (measured).
}

/// The handle's window for `surface`, hidden, layered with no attributes
/// set (`update` gives it its pixels); null, logged, if it cannot be made.
fn make(surface: *Surface) ?win32.HWND {
    const hwnd = Overlays.make(surface, class_name) orelse {
        log.warn("cannot make a terminal's drag handle err={}", .{win32.GetLastError()});
        return null;
    };
    // Over a transparent terminal `Overlays.make` layers it at 255
    // (`Transparency.chrome`), after which UpdateLayeredWindow is refused
    // until the style is taken off and put back.
    const style = win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE);
    const layered: isize = win32.WS_EX_LAYERED;
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, style & ~layered);
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, style | layered);
    return hwnd;
}

/// Ask for `hwnd`'s WM_MOUSELEAVE; whether it was asked.
fn track(hwnd: win32.HWND) bool {
    var t: win32.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    return win32.TrackMouseEvent(&t).toBool();
}

/// A mouse message's client point in `hwnd`, on the screen.
fn screenPoint(hwnd: win32.HWND, lparam: win32.LPARAM) ?POINT {
    var at: POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    if (!win32.ClientToScreen(hwnd, &at).toBool()) return null;
    return at;
}

/// The left button came up at `at`, on the screen, over the handle
/// `hwnd` or wherever its capture brought it: the press ends and the
/// handle hides, and a drag drops its terminal beside the terminal under
/// the pointer, if there is one and it is another (`paneAt`).
fn release(surface: *Surface, hwnd: win32.HWND, at: POINT) void {
    const self = &surface.overlays.drag_handle;
    const p = self.press orelse return;
    // Ended before the capture goes, whose WM_CAPTURECHANGED then
    // cancels nothing, and before the move, which lays the terminals out
    // again, this one perhaps in another frame.
    self.press = null;
    self.hover = false;
    if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
    if (captured == hwnd) captured = null;
    Overlays.place(surface);
    if (!p.active and !TabBar.pastDragThreshold(p.at, at, p.threshold)) return;
    const target = paneAt(surface.app, at) orelse return;
    if (target.surface == surface) return;
    Window.dropPane(surface, target.surface, Window.dropSide(target.rect, at));
}

/// A terminal under the pointer, and its place on the screen.
pub const Target = struct { surface: *Surface, rect: RECT };

/// For tests: answers in place of WindowFromPoint in `paneAt`, as the
/// test runner's windows are not shown where a point could find them.
pub var test_window_at: if (builtin.is_test) ?*const fn (POINT) ?win32.HWND else void =
    if (builtin.is_test) null else {};

/// The window at `at`, on the screen: WindowFromPoint's, or the tests'
/// (`test_window_at`).
fn windowAt(at: POINT) ?win32.HWND {
    if (builtin.is_test) if (test_window_at) |answer| return answer(at);
    return win32.WindowFromPoint(at);
}

/// The terminal of `app` under `at`, on the screen: one shown in the
/// selected tab of the frame of whatever window is there, which another
/// program's window over it hides; none over a frame's tab bar or a
/// divider, nor over a frame being closed.
pub fn paneAt(app: *App, at: POINT) ?Target {
    const under = windowAt(at) orelse return null;
    const root = win32.GetAncestor(under, win32.GA_ROOT) orelse return null;
    for (app.windows.items) |window| {
        if (window.hwnd != root) continue;
        if (window.closing or window.tabs.items.len == 0) return null;
        var it = window.tab().tree.iterator();
        while (it.next()) |entry| {
            const s = entry.view;
            if (s.closing or !SearchBar.visibleStyle(s.hwnd)) continue;
            var r: RECT = undefined;
            if (!win32.GetWindowRect(s.hwnd, &r).toBool()) continue;
            if (at.x >= r.left and at.x < r.right and at.y >= r.top and at.y < r.bottom) {
                return .{ .surface = s, .rect = r };
            }
        }
        return null;
    }
    return null;
}

/// The handle that holds the capture for a press, if any: Escape, which
/// goes to the terminal with the focus, not to it, cancels the press
/// (`cancelByKey`). Compared with GetCapture before it is used, so a
/// stale one is never acted on.
var captured: ?win32.HWND = null;

/// Escape went down (the focused terminal's WM_KEYDOWN): a handle's press
/// or drag is cancelled by letting go of its capture (its
/// WM_CAPTURECHANGED). Whether there was one, whose key then goes no
/// further.
pub fn cancelByKey() bool {
    const hwnd = captured orelse return false;
    captured = null;
    if (win32.GetCapture() != hwnd) return false;
    _ = win32.ReleaseCapture();
    return true;
}

/// Whether a handle could not be layered: then none shows again in this
/// process, rather than one made and refused at every hover. A child
/// window is layered only in a process whose manifest declares Windows 8
/// or later, and without one every child fails (error 87), as in the test
/// runner (`test_update`); the app has one.
pub var cannot_layer = false;

/// For tests: answers in place of `update` in `Handle.shape`, given the
/// handle's size, as the test runner cannot layer a child window.
pub var test_update: if (builtin.is_test) ?*const fn (win32.HWND, Size) bool else void =
    if (builtin.is_test) null else {};

/// Give the layered window `hwnd` its pixels, `size` big at `dpi`, the
/// dots in `color` (`paint`); whether it took them. A window that refuses
/// them is said once for the process, and no handle shows after it
/// (`cannot_layer`).
fn update(hwnd: win32.HWND, size: Size, dpi: u32, color: win32.COLORREF) bool {
    const dc = win32.CreateCompatibleDC(null) orelse return false;
    defer _ = win32.DeleteDC(dc);
    const header: win32.BITMAPINFOHEADER = .{
        .biSize = @sizeOf(win32.BITMAPINFOHEADER),
        .biWidth = size.width,
        // Rows from the top down.
        .biHeight = -size.height,
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = win32.BI_RGB,
        .biSizeImage = 0,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    };
    var bits: ?*anyopaque = null;
    const bitmap = win32.CreateDIBSection(dc, &header, win32.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
    defer _ = win32.DeleteObject(bitmap);
    const width: usize = @intCast(size.width);
    const height: usize = @intCast(size.height);
    const pixels = @as([*][4]u8, @ptrCast(@alignCast(bits.?)))[0 .. width * height];
    paint(pixels, width, height, dpi, color);
    const old = win32.SelectObject(dc, bitmap) orelse return false;
    defer _ = win32.SelectObject(dc, old);
    const src: POINT = .{ .x = 0, .y = 0 };
    const blend: win32.BLENDFUNCTION = .{};
    const sized: win32.SIZE = .{ .cx = size.width, .cy = size.height };
    if (win32.UpdateLayeredWindow(hwnd, null, null, &sized, dc, &src, 0, &blend, win32.ULW_ALPHA).toBool()) return true;
    log.warn("terminals have no drag handle: its window cannot be layered err={}", .{win32.GetLastError()});
    cannot_layer = true;
    return false;
}

/// The alpha of the band, GTK's black at 15% (`.drag-handle`), of 255.
pub const band_alpha: u8 = 38;

/// Paint a handle `width` by `height` pixels at `dpi` into `pixels`, BGRA
/// with premultiplied alpha, top row first, as UpdateLayeredWindow takes
/// them: the band, and over it, centred, three dots in `color`, each
/// 3 pixels across at 96 DPI and 5 apart, as the 16-pixel
/// `view-more-horizontal-symbolic` draws them, their edges blended
/// (`coverage`).
pub fn paint(pixels: [][4]u8, width: usize, height: usize, dpi: u32, color: win32.COLORREF) void {
    std.debug.assert(pixels.len == width * height);
    const scale = @as(f32, @floatFromInt(dpi)) / 96;
    const radius = 1.5 * scale;
    const gap = 5 * scale;
    const cx = @as(f32, @floatFromInt(width)) / 2;
    const cy = @as(f32, @floatFromInt(height)) / 2;
    const rgb = [3]u8{
        @truncate(color >> 16),
        @truncate(color >> 8),
        @truncate(color),
    };
    for (0..height) |y| for (0..width) |x| {
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var cover: f32 = 0;
        for ([_]f32{ -1, 0, 1 }) |k| {
            cover = @max(cover, coverage(px - (cx + k * gap), py - cy, radius));
        }
        pixels[y * width + x] = over(rgb, cover);
    };
}

/// How much of a pixel whose centre is `dx`, `dy` from a dot's centre the
/// dot of `radius` covers: all within it less half a pixel, none beyond
/// it plus half, and in between by the distance, as the bell's disk is
/// blended (BellBadge.zig).
fn coverage(dx: f32, dy: f32, radius: f32) f32 {
    return std.math.clamp(radius - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
}

/// A dot's colour `rgb` (blue, green, red), as much as `cover`, over the
/// band, premultiplied.
fn over(rgb: [3]u8, cover: f32) [4]u8 {
    const c = std.math.clamp(cover, 0, 1);
    var out: [4]u8 = undefined;
    for (0..3) |i| out[i] = @intFromFloat(@round(@as(f32, @floatFromInt(rgb[i])) * c));
    out[3] = @intFromFloat(@round(255 * c + @as(f32, band_alpha) * (1 - c)));
    return out;
}

test "win32: a drag handle is GTK's band at 15% with three dots in the middle, premultiplied" {
    const t = std.testing;
    const width = 60;
    const height = 16;
    var pixels: [width * height][4]u8 = undefined;
    const color = win32.rgb(0xf0, 0x80, 0x10);
    paint(&pixels, width, height, 96, color);
    // The band, away from the dots.
    try t.expectEqual([4]u8{ 0, 0, 0, band_alpha }, pixels[0]);
    try t.expectEqual([4]u8{ 0, 0, 0, band_alpha }, pixels[width * height - 1]);
    // The middle dot's centre: the colour, opaque (blue, green, red).
    try t.expectEqual([4]u8{ 0x10, 0x80, 0xf0, 255 }, pixels[8 * width + 30]);
    // Three dots across the middle row, mirrored about the centre.
    var runs: usize = 0;
    var in = false;
    for (0..width) |x| {
        const p = pixels[8 * width + x];
        try t.expectEqual(p, pixels[8 * width + (width - 1 - x)]);
        const dot = p[3] > band_alpha;
        if (dot and !in) runs += 1;
        in = dot;
        // Premultiplied: no channel above the alpha.
        for (0..3) |i| try t.expect(p[i] <= p[3]);
    }
    try t.expectEqual(3, runs);
    // Twice the size at twice the DPI: the dots cover four times the
    // area, within a tenth for their blended edges.
    var big: [width * 2 * height * 2][4]u8 = undefined;
    paint(&big, width * 2, height * 2, 192, color);
    const small_area = dotArea(&pixels);
    const big_area = dotArea(&big);
    try t.expect(@abs(big_area - 4 * small_area) <= 0.4 * small_area);
}

/// How many pixels' worth the dots of `pixels` cover.
fn dotArea(pixels: []const [4]u8) f32 {
    var area: f32 = 0;
    for (pixels) |p| area += @as(f32, @floatFromInt(p[3] - band_alpha)) / (255 - band_alpha);
    return area;
}

test "win32: a drag handle is as tall as a 16-pixel icon at the DPI" {
    try std.testing.expectEqual(16, heightAt(96));
    try std.testing.expectEqual(24, heightAt(144));
    try std.testing.expectEqual(32, heightAt(192));
}
