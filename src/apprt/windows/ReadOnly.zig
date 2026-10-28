//! A terminal's read-only badge, as GTK shows one over the top-right
//! corner of its surface while the surface is read-only
//! (`readonly_overlay` in src/apprt/gtk/ui/1.0/surface.blp): "Read-only"
//! in GTK's colour for it, framed in the same colour, with GTK's padding
//! and margin (`.readonly_overlay` in src/apprt/gtk/css/style.css), on the
//! terminal's background (`Overlays.terminalBackground`), as GTK's, which
//! has none of its own, shows over the terminal. GTK's lock icon is left
//! out: it is one line of text.
//!
//! The core keeps the flag: the `toggle_readonly` binding flips it, then
//! performs `readonly` with what it is now
//! (`CoreSurface.performBindingAction`). While it is on, the core sends
//! nothing to the terminal's program and asks before the terminal closes
//! (`CoreSurface.needsConfirmQuit`), even once its command has exited;
//! the prompt then says the terminal is read-only (`Surface.close`).
//!
//! It is one of the terminal's overlays (Overlays.zig), the lowest of them,
//! as GTK stacks it: the link preview and the key-state indicator show
//! above it, and the terminal's search bar, placed above every overlay,
//! covers it while it is open. The pointer and clicks over it go to the
//! terminal under it, as GTK's takes none (`can-target: false`).
//!
//! The core performs the action inside its `performBindingAction` frame,
//! which a key callback enters, or the command palette's entry
//! (`CommandPalette.runNow`). The window is made the first time the
//! terminal is made read-only, there, as `SearchBar.start` makes the
//! search bar's and `KeyState.update` the key-state indicator's.

const std = @import("std");

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");

const RECT = win32.RECT;
const L = win32.L;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyReadOnlyClass";

/// What the badge says, GTK's label.
pub const label = "Read-only";
const label_text: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral(label);

/// GTK's colour for the badge's text and outline, hsl(25 50 75)
/// (`.readonly_overlay`), in sRGB.
pub const color = win32.rgb(223, 186, 159);

/// A terminal's badge (`Overlays.readonly`).
pub const Badge = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// the terminal is made read-only; null until then, if it could not be
    /// made, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// What it shows, `label`, while the terminal is read-only; null while
    /// it is not.
    text: ?[:0]const u16 = null,
    /// Whether the terminal is read-only, as the core last said (`set`),
    /// whether or not the badge could be made: its close prompt says so
    /// (`Surface.close`).
    on: bool = false,
    /// The size of `text` in the overlays' font; measured again when the
    /// font changes.
    text_size: Size = .{ .width = 0, .height = 0 },
    measured: bool = false,

    /// Nothing to free: its text is `label`'s.
    pub fn deinit(self: *Badge, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.text = null;
    }

    /// Show `text`, or nothing, which its window is also named.
    fn setText(self: *Badge, text: ?[:0]const u16) void {
        self.text = text;
        const hwnd = self.hwnd orelse return;
        // Its name, for what reads windows' text, as screen readers do.
        _ = win32.SetWindowTextW(hwnd, if (text) |t| t.ptr else L(""));
    }

    /// Where the badge goes over a terminal `pane` big at `dpi`, in the
    /// terminal's client coordinates (`rectIn`), for `Overlays.place`.
    pub fn placeIn(self: *const Badge, dpi: u32, pane: Size) ?Overlays.Placed {
        const in = rectIn(.init(dpi), pane, self.text_size) orelse return null;
        return .{ .in = in, .redraw = false };
    }

    /// Where the text goes in the badge at `dpi`: inside its padding.
    pub fn textIn(self: *const Badge, dpi: u32, width: i32) RECT {
        _ = width;
        const m = Metrics.init(dpi);
        return .{ .left = m.pad, .top = m.pad, .right = m.pad + self.text_size.width, .bottom = m.pad + self.text_size.height };
    }

    /// GTK's colour for the text and the frame around it (its outline),
    /// on the terminal's `background` (`Overlays.lookOf`), not the search
    /// bar's: GTK's badge has no background, and its colour is too light to
    /// read on the light bar.
    pub fn look(self: *const Badge, colors: SearchBar.Colors, background: win32.COLORREF) Overlays.Look {
        _ = self;
        _ = colors;
        return .{ .line = color, .fill = background, .text = color };
    }
};

/// `readonly` on `surface`: `.on` shows its badge, its window made first
/// if it has none, and `.off` hides it. False if the window cannot be
/// made; `.off` with no badge makes none. Either way the terminal is
/// known to be read-only or not (`Badge.on`).
pub fn set(surface: *Surface, value: apprt.action.Readonly) bool {
    const self = &surface.overlays.readonly;
    self.on = value == .on;
    switch (value) {
        .on => if (self.hwnd == null) {
            self.hwnd = Overlays.make(surface, class_name) orelse {
                log.warn("cannot make a read-only badge err={}", .{win32.GetLastError()});
                return false;
            };
        },
        .off => if (self.hwnd == null) {
            self.text = null;
            return true;
        },
    }
    self.setText(switch (value) {
        .on => label_text,
        .off => null,
    });
    Overlays.place(surface);
    return true;
}

/// The badge's sizes at a DPI, from GTK's at 96 (`.readonly_overlay` in
/// src/apprt/gtk/css/style.css: padding 8px, margin 8px).
pub const Metrics = struct {
    /// Between the text and the badge's edges.
    pad: i32,
    /// Between the badge and its terminal's top and right edges.
    margin: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .pad = SearchBar.Metrics.scale(8, dpi),
            .margin = SearchBar.Metrics.scale(8, dpi),
        };
    }
};

/// Where a badge of text `text` big goes over a terminal `pane` big, in
/// the terminal's client coordinates: `margin` in from its top-right
/// corner, as big as the text with its padding; null for a terminal with
/// no room for it within its margins.
pub fn rectIn(m: Metrics, pane: Size, text: Size) ?RECT {
    const width = @max(0, text.width) + 2 * m.pad;
    const height = @max(0, text.height) + 2 * m.pad;
    if (pane.width - 2 * m.margin < width or pane.height - 2 * m.margin < height) return null;
    const right = pane.width - m.margin;
    return .{ .left = right - width, .top = m.margin, .right = right, .bottom = m.margin + height };
}

test "win32: the read-only badge sits in its terminal's top-right corner, inside its margins" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(8, m.pad);
    try testing.expectEqual(8, m.margin);
    try testing.expectEqual(16, Metrics.init(192).pad);
    try testing.expectEqual(12, Metrics.init(144).margin);

    const text: Size = .{ .width = 60, .height = 16 };
    try testing.expectEqual(RECT{ .left = 716, .top = 8, .right = 792, .bottom = 40 }, rectIn(m, .{ .width = 800, .height = 600 }, text).?);
    // Just room for it within the margins; one pixel less, none.
    try testing.expectEqual(RECT{ .left = 8, .top = 8, .right = 84, .bottom = 40 }, rectIn(m, .{ .width = 92, .height = 48 }, text).?);
    try testing.expect(rectIn(m, .{ .width = 91, .height = 600 }, text) == null);
    try testing.expect(rectIn(m, .{ .width = 800, .height = 47 }, text) == null);
}

test "win32: the read-only badge's colour is GTK's hsl(25 50 75)" {
    // CSS's hsl() to sRGB (CSS Color 4, "Converting HSL Colors to sRGB"),
    // rounded to bytes.
    const h: f64 = 25;
    const s: f64 = 0.50;
    const l: f64 = 0.75;
    const a = s * @min(l, 1 - l);
    var rgb: [3]u8 = undefined;
    for ([_]f64{ 0, 8, 4 }, 0..) |n, i| {
        const k = @mod(n + h / 30, 12);
        const v = l - a * @max(-1, @min(k - 3, 9 - k, 1));
        rgb[i] = @intFromFloat(@round(v * 255));
    }
    try std.testing.expectEqual(win32.rgb(rgb[0], rgb[1], rgb[2]), color);
}

/// For tests: WCAG 2's relative luminance of the sRGB colour `c`.
fn luminance(c: win32.COLORREF) f64 {
    const weights = [_]f64{ 0.2126, 0.7152, 0.0722 };
    var sum: f64 = 0;
    for (weights, 0..) |w, i| {
        const shift: u5 = @intCast(8 * i);
        const v = @as(f64, @floatFromInt((c >> shift) & 0xff)) / 255;
        sum += w * if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
    }
    return sum;
}

/// For tests: WCAG 2's contrast ratio of `a` and `b`, 1 to 21.
fn contrast(a: win32.COLORREF, b: win32.COLORREF) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "win32: the read-only badge's text reads on Ghostty's default background" {
    // WCAG asks text for a contrast of 4.5:1 at least. The badge is drawn
    // on its terminal's background, the configuration's `background`: here
    // its default, read from the configuration.
    const testing = std.testing;
    try testing.expectApproxEqAbs(21, contrast(win32.rgb(255, 255, 255), win32.rgb(0, 0, 0)), 1e-9);
    try testing.expectApproxEqAbs(1, contrast(color, color), 1e-9);
    const field = std.meta.fieldInfo(configpkg.Config, .background);
    const bg = comptime field.attrs.defaultValue(field.type).?;
    try testing.expect(contrast(color, win32.rgb(bg.r, bg.g, bg.b)) >= 4.5);
}
