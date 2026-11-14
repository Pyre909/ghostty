//! A terminal's dim while it is a split without the focus
//! (`unfocused-split-opacity`, `unfocused-split-fill`): its fill colour,
//! the terminal's configured background unless set, over all of it at one
//! less the opacity, as macOS puts a rectangle of that colour at that
//! opacity over an unfocused split (the `isSplit && !focused` rectangle in
//! macos/Sources/Ghostty/Surface View/SurfaceView.swift) and GTK a
//! revealer styled `unfocused-split` (src/apprt/gtk/ui/1.0/surface.blp,
//! coloured by `loadRuntimeCss` in src/apprt/gtk/class/application.zig).
//! It shows as GTK's does
//! (`closureShouldUnfocusedSplitBeShown`): over a terminal in a tab of
//! more than one, not its tab's focused one, whose search bar is not open.
//!
//! It is one of the terminal's overlays (Overlays.zig), the top one, as
//! GTK stacks it over the others; macOS puts it over all but its grab
//! handle. Unlike the others it is see-through: a layered window, at the
//! alpha the opacity gives (`alphaOf`), which DWM blends with the
//! terminal's swap chain under it. One that cannot be layered is not
//! shown, as it would hide the terminal. The pointer, clicks and drops
//! over it go to the terminal, as macOS's takes none
//! (`allowsHitTesting(false)`): it is WS_EX_TRANSPARENT, which every hit
//! test passes over in a layered window, another process's too, such as
//! Explorer's as it drags files; the HTTRANSPARENT all overlays answer
//! counts only on Ghostty's own thread.
//! Its window is made the first time it shows (`sync`).

const std = @import("std");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const Transparency = @import("Transparency.zig");
const Config = @import("../../config.zig").Config;

const RECT = win32.RECT;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyUnfocusedSplitClass";

/// A terminal's dim (`Overlays.dim`).
pub const Dim = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// the dim shows; null until then, if it could not be made or
    /// layered, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// Whether it shows, as `sync` last found.
    on: bool = false,
    /// The alpha its window was layered with, 0 for none yet: layered
    /// again only when the opacity changes.
    alpha: u8 = 0,
    /// The colour it fills with, as `sync` last found it:
    /// `unfocused-split-fill`, else the configured background, as GTK's
    /// (`loadRuntimeCss`) and macOS's. Not a background a program set
    /// (`Overlays.colorChanged`), which the other overlays draw on: the
    /// dim is to darken the terminal, whatever colour it shows.
    fill: win32.COLORREF = 0,

    pub fn deinit(self: *Dim, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.on = false;
        self.alpha = 0;
    }

    /// For `Overlays.place`: it has no text to show it.
    pub fn shows(self: *const Dim) bool {
        return self.on;
    }

    /// All of the terminal, for `Overlays.place`.
    pub fn placeIn(self: *const Dim, dpi: u32, pane: Size) ?Overlays.Placed {
        _ = self;
        _ = dpi;
        return .{ .in = .{ .left = 0, .top = 0, .right = pane.width, .bottom = pane.height }, .redraw = false };
    }

    /// Its colour over all of the window, which its alpha blends; not the
    /// terminal's `background` (`fill`).
    pub fn draw(self: *const Dim, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = dpi;
        _ = dark;
        _ = background;
        _ = font;
        SearchBar.fill(hdc, client, self.fill);
    }
};

/// The alpha of a dim for `opacity`, the unfocused split's: one less it,
/// of 255, rounded. The configuration keeps the opacity within 0.15 and
/// 1 (`Config.finalize`); 0 for 1, no dim.
pub fn alphaOf(opacity: f64) u8 {
    const of = std.math.clamp(1.0 - opacity, 0.0, 1.0);
    return @intFromFloat(@round(of * 255.0));
}

/// Whether `surface` is dimmed, as GTK's `closureShouldUnfocusedSplitBeShown`
/// says: with a dim to show (`alpha`), in a tab of more than one
/// terminal, not the tab's focused one, and its search bar not open.
pub fn wanted(surface: *const Surface, alpha: u8) bool {
    if (alpha == 0) return false;
    if (surface.search_bar.open) return false;
    const t = surface.window.tabOf(surface) orelse return false;
    return t.tree.isSplit() and t.focused != surface;
}

/// Whether a dim could not be layered: then none is made again in this
/// process, rather than one made, refused and destroyed at every
/// placement. A child window is layered only in a process whose manifest
/// declares Windows 8 or later, and without one every child fails (error
/// 87), as in the test runner; the app has one.
pub var cannot_layer = false;

/// Make `hwnd` layered with `alpha`. A layered window shows nothing until
/// its attributes are set; if they cannot be, it is not to be shown, and
/// that is said once for the process (`cannot_layer`).
fn layer(hwnd: win32.HWND, alpha: u8) bool {
    if (Transparency.layerAt(hwnd, alpha)) return true;
    log.warn("unfocused splits cannot be dimmed: their dim cannot be layered err={}", .{win32.GetLastError()});
    cannot_layer = true;
    return false;
}

/// Find whether `surface`'s dim shows, from `config`, for
/// `Overlays.place`, which then places or hides it: its window made the
/// first time it shows, and layered again for a new opacity. One whose
/// window cannot be made does not show, and is made again the next time
/// its terminal is placed; one that cannot be layered is destroyed, and no
/// dim shows in this process after it (`cannot_layer`).
pub fn sync(surface: *Surface, config: *const Config) void {
    const self = &surface.overlays.dim;
    const alpha = alphaOf(config.@"unfocused-split-opacity");
    const fill = config.@"unfocused-split-fill" orelse config.background;
    self.fill = win32.rgb(fill.r, fill.g, fill.b);
    self.on = !cannot_layer and wanted(surface, alpha);
    if (!self.on) return;
    const hwnd = self.hwnd orelse made: {
        const made = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make an unfocused split's dim err={}", .{win32.GetLastError()});
            self.on = false;
            return;
        };
        // Passed over by every hit test once layered (the file's doc).
        const style = win32.GetWindowLongPtrW(made, win32.GWL_EXSTYLE);
        const see_through: isize = win32.WS_EX_TRANSPARENT;
        _ = win32.SetWindowLongPtrW(made, win32.GWL_EXSTYLE, style | see_through);
        self.hwnd = made;
        self.alpha = 0;
        break :made made;
    };
    if (self.alpha == alpha) return;
    if (!layer(hwnd, alpha)) {
        self.on = false;
        // Its WM_DESTROY forgets it.
        _ = win32.DestroyWindow(hwnd);
        return;
    }
    self.alpha = alpha;
    _ = win32.InvalidateRect(hwnd, null, .FALSE);
}

test "win32: an unfocused split's dim is one less its opacity, of 255" {
    const testing = std.testing;
    try testing.expectEqual(77, alphaOf(0.7));
    try testing.expectEqual(0, alphaOf(1));
    try testing.expectEqual(217, alphaOf(0.15));
    try testing.expectEqual(255, alphaOf(0));
    try testing.expectEqual(0, alphaOf(1.5));
}
