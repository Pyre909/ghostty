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
    /// Layered for an alpha of its own in any frame: `Overlays.chromeAgain`
    /// leaves it as it is when its window turns transparent or opaque.
    pub const own_layering = {};

    /// Its window, a child of the terminal's frame, made the first time
    /// it shows; null until then, if it could not be made or layered, and
    /// once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The side the dragged terminal would go to, while it shows; set
    /// only once its window is made and layered.
    side: ?Side = null,

    /// The terminal is freed (`Surface.deinit`): no preview of the drag
    /// is left naming it.
    pub fn deinit(self: *Preview, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.side = null;
        if (shown_on == self) shown_on = null;
        if (failed_on == self) failed_on = null;
    }

    /// For `Overlays.place`: it has no text to show it.
    pub fn shows(self: *const Preview) bool {
        return self.side != null;
    }

    /// Its window is hidden with the terminal's overlays
    /// (`Overlays.hide`): the terminal is parked, zoomed out of sight or
    /// in a tab not shown. The preview ends, so that it does not show
    /// again with the terminal, after the drag; the drag's next move
    /// shows it again where it applies.
    pub fn hidden(self: *Preview, hwnd: win32.HWND) void {
        _ = hwnd;
        self.side = null;
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

/// The preview set now, if any (`set`); let go of when its terminal is
/// freed (`Preview.deinit`).
var shown_on: ?*Preview = null;

/// The preview whose window could not be made or layered during this
/// drag (`show`): not tried again, nor logged again, until the pointer
/// goes over another terminal or the drag ends (`set`, `clear`).
var failed_on: ?*Preview = null;

/// Show the preview over `target`, on `side`, and hide the one shown
/// before, if it was another's; with no target, hide it.
pub fn set(target: ?*Surface, side: Side) void {
    const want: ?*Preview = if (target) |t| &t.overlays.drop_preview else null;
    if (shown_on) |old| if (old != want) hide(old);
    shown_on = null;
    if (failed_on != want) failed_on = null;
    const t = target orelse return;
    if (show(t, side)) shown_on = want;
}

/// Hide the preview, wherever it shows (`set` with no target), at the end
/// of a drag.
pub fn clear() void {
    set(null, .left);
}

fn hide(self: *Preview) void {
    if (self.side == null) return;
    self.side = null;
    const overlays: *Overlays = @alignCast(@fieldParentPtr("drop_preview", self));
    const surface: *Surface = @alignCast(@fieldParentPtr("overlays", overlays));
    Overlays.place(surface);
}

/// Show the preview over `surface` on `side`, its window made and layered
/// the first time, and placed whenever it is made, as a window made again
/// after its own was destroyed shows nothing yet; whether its side is set.
/// Logged once, and not shown, if its window cannot be made or layered
/// (`failed_on`).
fn show(surface: *Surface, side: Side) bool {
    const self = &surface.overlays.drop_preview;
    const fresh = self.hwnd == null;
    if (fresh) {
        self.side = null;
        if (failed_on == self) return false;
        const made = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a drop preview err={}", .{win32.GetLastError()});
            failed_on = self;
            return false;
        };
        // Passed over by every hit test once layered.
        const style = win32.GetWindowLongPtrW(made, win32.GWL_EXSTYLE);
        const see_through: isize = win32.WS_EX_TRANSPARENT;
        _ = win32.SetWindowLongPtrW(made, win32.GWL_EXSTYLE, style | see_through);
        if (!Transparency.layerAt(made, alpha)) {
            log.warn("cannot show a drop preview: its window cannot be layered err={}", .{win32.GetLastError()});
            failed_on = self;
            // Its WM_DESTROY forgets it.
            _ = win32.DestroyWindow(made);
            return false;
        }
        self.hwnd = made;
    }
    if (self.side == side) return true;
    self.side = side;
    Overlays.place(surface);
    return true;
}

test "win32: a drop preview is the half of the terminal on its side" {
    const t = std.testing;
    const pane: Size = .{ .width = 101, .height = 50 };
    try t.expectEqual(RECT{ .left = 0, .top = 0, .right = 50, .bottom = 50 }, half(.left, pane));
    try t.expectEqual(RECT{ .left = 50, .top = 0, .right = 101, .bottom = 50 }, half(.right, pane));
    try t.expectEqual(RECT{ .left = 0, .top = 0, .right = 101, .bottom = 25 }, half(.up, pane));
    try t.expectEqual(RECT{ .left = 0, .top = 25, .right = 101, .bottom = 50 }, half(.down, pane));
}
