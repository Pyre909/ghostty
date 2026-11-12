//! A terminal's dim while it is a split without the focus
//! (`unfocused-split-opacity`, `unfocused-split-fill`): its fill colour,
//! the terminal's configured background unless set, over all of it at one
//! less the opacity, as macOS puts a rectangle of that colour at that
//! opacity over an unfocused split (macos/Sources/Ghostty/Surface
//! View/SurfaceView.swift:151-161) and GTK a revealer styled
//! `unfocused-split` (src/apprt/gtk/ui/1.0/surface.blp:203,
//! src/apprt/gtk/class/application.zig:1041). It shows as GTK's does
//! (`closureShouldUnfocusedSplitBeShown`): over a terminal in a tab of
//! more than one, not its tab's focused one, whose search bar is not open.
//!
//! It is one of the terminal's overlays (Overlays.zig), the top one, as
//! GTK stacks it over the others; macOS puts it over all but its grab
//! handle. Unlike the others it is see-through: a layered window, at the
//! alpha the opacity gives (`alphaOf`), which DWM blends with the
//! terminal's swap chain under it. One that cannot be layered is not
//! shown, as it would hide the terminal. The pointer and clicks over it go
//! to the terminal, as macOS's takes none (`allowsHitTesting(false)`).
//! Its window is made the first time it shows (`sync`).

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
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
    /// The colour it fills with, `unfocused-split-fill`; null for the
    /// terminal's background.
    fill: ?win32.COLORREF = null,

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

    /// Its colour over all of the window, which its alpha blends.
    pub fn draw(self: *const Dim, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = dpi;
        _ = dark;
        _ = font;
        SearchBar.fill(hdc, client, self.fill orelse background);
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

/// For tests: answers in place of SetLayeredWindowAttributes in `layer`,
/// as the test runner has no manifest, and so cannot layer a child window
/// (`Transparency.test_set_alpha`).
pub var test_set_alpha: if (builtin.is_test) ?*const fn (win32.HWND, u8) bool else void =
    if (builtin.is_test) null else {};

/// Whether a dim could not be layered: then none is made again in this
/// process. A child window is layered only in a process whose manifest
/// declares Windows 8 or later, and without one every child fails (error
/// 87), as in the test runner; the app has one.
var cannot_layer = false;

/// Make `hwnd` layered with `alpha`. A layered window shows nothing until
/// its attributes are set; if they cannot be, it is not to be shown, and
/// that is said once for the process (`cannot_layer`).
fn layer(hwnd: win32.HWND, alpha: u8) bool {
    const style = win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE);
    const layered: isize = win32.WS_EX_LAYERED;
    if (style & layered == 0) _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, style | layered);
    if (setAlpha(hwnd, alpha)) return true;
    log.warn("unfocused splits cannot be dimmed: their dim cannot be layered err={}", .{win32.GetLastError()});
    cannot_layer = true;
    return false;
}

/// Whether a dim can be layered, as far as this process knows: for a
/// test, whenever it stands in for SetLayeredWindowAttributes.
fn canLayer() bool {
    if (builtin.is_test) if (test_set_alpha != null) return true;
    return !cannot_layer;
}

fn setAlpha(hwnd: win32.HWND, alpha: u8) bool {
    if (builtin.is_test) if (test_set_alpha) |answer| return answer(hwnd, alpha);
    return win32.SetLayeredWindowAttributes(hwnd, 0, alpha, win32.LWA_ALPHA).toBool();
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
    self.fill = if (config.@"unfocused-split-fill") |c| win32.rgb(c.r, c.g, c.b) else null;
    self.on = canLayer() and wanted(surface, alpha);
    if (!self.on) return;
    const hwnd = self.hwnd orelse made: {
        const made = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make an unfocused split's dim err={}", .{win32.GetLastError()});
            self.on = false;
            return;
        };
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
