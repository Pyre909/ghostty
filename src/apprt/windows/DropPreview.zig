//! Where a terminal dragged by its handle (DragHandle.zig) would go: the
//! half of the terminal under the pointer nearest it, in the accent colour
//! at half opacity, as GTK's `drop_overlay` shows it
//! (src/apprt/gtk/ui/1.0/surface.blp; `.drop-overlay` in
//! src/apprt/gtk/css/style.css, a gradient that is the accent at 50% on
//! that half and transparent on the other). The accent is the system's
//! highlight colour, as the progress bar, the command palette and the tab
//! overview take it.
//!
//! It is one of the terminal's overlays (Overlays.zig), the top one, as
//! GTK puts it over its drag handle. Like the dim of an unfocused split
//! (UnfocusedSplit.zig) it is a layered window at one alpha, which DWM
//! blends with the terminal under it, WS_EX_TRANSPARENT so that every hit
//! test passes over it, `DragHandle.paneAt`'s included; one that cannot
//! be layered is not shown, as it would hide half of the terminal. Its
//! window is made the first time it shows (`show`). One terminal at a
//! time shows it, the one under the dragged terminal's pointer (`set`).

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const Transparency = @import("Transparency.zig");

const RECT = win32.RECT;
const Size = Overlays.Size;
const Side = Window.Tree.Split.Direction;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyDropPreviewClass";

/// GTK's 50%, of 255.
pub const alpha: u8 = 128;

/// A terminal's preview (`Overlays.drop_preview`).
pub const Preview = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// it shows; null until then, if it could not be made or layered, and
    /// once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The side the dragged terminal would go to, while it shows.
    side: ?Side = null,
    /// Whether its window is layered at `alpha`.
    layered: bool = false,

    pub fn deinit(self: *Preview, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.side = null;
        self.layered = false;
    }

    /// For `Overlays.place`: it has no text to show it.
    pub fn shows(self: *const Preview) bool {
        return self.side != null and self.layered;
    }

    /// The half of the terminal on its side, for `Overlays.place`.
    pub fn placeIn(self: *const Preview, dpi: u32, pane: Size) ?Overlays.Placed {
        _ = dpi;
        const side = self.side orelse return null;
        return .{ .in = half(side, pane), .redraw = false };
    }

    /// The highlight colour over all of the window, which its alpha
    /// blends.
    pub fn draw(self: *const Preview, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = self;
        _ = dpi;
        _ = dark;
        _ = background;
        _ = font;
        SearchBar.fill(hdc, client, highlight());
    }
};

/// The half of a terminal `pane` big on `side`: its left or right half,
/// the right one the wider for an odd width, as GTK's gradient stops at
/// 50%; its top or bottom half likewise.
pub fn half(side: Side, pane: Size) RECT {
    const w = @divTrunc(pane.width, 2);
    const h = @divTrunc(pane.height, 2);
    return switch (side) {
        .left => .{ .left = 0, .top = 0, .right = w, .bottom = pane.height },
        .right => .{ .left = w, .top = 0, .right = pane.width, .bottom = pane.height },
        .up => .{ .left = 0, .top = 0, .right = pane.width, .bottom = h },
        .down => .{ .left = 0, .top = h, .right = pane.width, .bottom = pane.height },
    };
}

/// For tests: in place of the system's highlight colour.
pub var test_highlight: if (builtin.is_test) ?win32.COLORREF else void = if (builtin.is_test) null else {};

fn highlight() win32.COLORREF {
    if (builtin.is_test) if (test_highlight) |c| return c;
    return win32.GetSysColor(win32.COLOR_HIGHLIGHT);
}

/// The terminal that shows a preview now, if any (`set`).
var shown_on: ?*Surface = null;

/// Show the preview over `target`, on `side`, and hide the one shown
/// before, if it was another's; with no target, hide it. The terminal
/// that showed it is looked for among `app`'s before it is touched, as it
/// may have closed since.
pub fn set(app: *App, target: ?*Surface, side: Side) void {
    if (shown_on) |old| {
        if (old != target and live(app, old)) hide(old);
    }
    shown_on = null;
    const t = target orelse return;
    if (show(t, side)) shown_on = t;
}

/// Hide the preview, wherever it shows (`set` with no target).
pub fn clear(app: *App) void {
    set(app, null, .left);
}

/// Whether `surface` is one of `app`'s terminals, in any tab of any of
/// its windows.
fn live(app: *const App, surface: *const Surface) bool {
    for (app.windows.items) |window| {
        for (window.tabs.items) |t| {
            var it = t.tree.iterator();
            while (it.next()) |entry| if (entry.view == surface) return true;
        }
    }
    return false;
}

fn hide(surface: *Surface) void {
    const self = &surface.overlays.drop_preview;
    if (self.side == null) return;
    self.side = null;
    Overlays.place(surface);
}

/// Show the preview over `surface` on `side`, its window made and layered
/// the first time; whether it shows. Logged, and not shown, if its window
/// cannot be made or layered: made again at the next show.
fn show(surface: *Surface, side: Side) bool {
    const self = &surface.overlays.drop_preview;
    if (self.hwnd == null) {
        const made = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a drop preview err={}", .{win32.GetLastError()});
            return false;
        };
        // Passed over by every hit test once layered.
        const style = win32.GetWindowLongPtrW(made, win32.GWL_EXSTYLE);
        const see_through: isize = win32.WS_EX_TRANSPARENT;
        _ = win32.SetWindowLongPtrW(made, win32.GWL_EXSTYLE, style | see_through);
        if (!Transparency.layerAt(made, alpha)) {
            log.warn("cannot show a drop preview: its window cannot be layered err={}", .{win32.GetLastError()});
            // Its WM_DESTROY forgets it.
            _ = win32.DestroyWindow(made);
            return false;
        }
        self.hwnd = made;
        self.layered = true;
    }
    if (self.side == side) return true;
    self.side = side;
    Overlays.place(surface);
    return SearchBar.visibleStyle(self.hwnd orelse return false);
}

test "win32: a drop preview is the half of the terminal on its side" {
    const t = std.testing;
    const pane: Size = .{ .width = 101, .height = 50 };
    try t.expectEqual(RECT{ .left = 0, .top = 0, .right = 50, .bottom = 50 }, half(.left, pane));
    try t.expectEqual(RECT{ .left = 50, .top = 0, .right = 101, .bottom = 50 }, half(.right, pane));
    try t.expectEqual(RECT{ .left = 0, .top = 0, .right = 101, .bottom = 25 }, half(.up, pane));
    try t.expectEqual(RECT{ .left = 0, .top = 25, .right = 101, .bottom = 50 }, half(.down, pane));
}
