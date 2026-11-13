//! A terminal's renderer error view, as macOS covers a surface whose
//! renderer is unhealthy (`SurfaceRendererUnhealthyView`,
//! macos/Sources/Ghostty/Surface View/SurfaceView.swift): the terminal's
//! background over all of it, and on that the app's icon, a title and a
//! line on what happened, centred. GTK shows nothing.
//!
//! The core says when the renderer's health changes (`renderer_health`,
//! from `generic.Renderer.frameCompleted` through the surface's mailbox).
//! The Direct3D 11 renderer reports a frame unhealthy only when its device
//! was lost (`d3d11/Frame.complete`); it tries to make a new one at the
//! next frame, and again each `D3D11.recovery_retry_ms` after a failure,
//! and the first frame it presents then is healthy, which hides the view.
//!
//! It is one of the terminal's overlays (Overlays.zig), just above the
//! bell border, as macOS stacks it over its bell border and under the dim
//! of an unfocused split. Its window covers the whole terminal; the
//! pointer and clicks over it go to the terminal under it, as macOS's
//! view takes none of the terminal's input. The window is made the first
//! time the renderer is unhealthy (`set`).
//!
//! macOS's title ends in an emoji, which GDI draws without its colours,
//! or as a box where the font has none, so this one leaves it out; and
//! the line says what loses a Direct3D device, and that it is tried
//! again, where macOS's names GPU memory alone.

const std = @import("std");

const apprt = @import("../../apprt.zig");
const renderer = @import("../../renderer.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const TabBar = @import("TabBar.zig");

const RECT = win32.RECT;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyRendererHealthClass";

/// The view's words.
pub const title = "Oh, no.";
pub const body = "The renderer has failed. This is usually because the graphics driver was reset or ran out of GPU memory. Ghostty tries again every second.";
const title_text: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral(title);
/// Their conversions at compile time take more than the default branch
/// quota.
const body_text: [:0]const u16 = blk: {
    @setEvalBranchQuota(10_000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral(body);
};
/// Its window's name, for what reads windows' text, as screen readers do.
const name_text: [:0]const u16 = blk: {
    @setEvalBranchQuota(10_000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral(title ++ " " ++ body);
};

/// ID_ICON_GHOSTTY in dist/windows/ghostty.rc, which the exe links and
/// the test exe does not.
pub const icon_resource_id = 1;

const title_format = win32.DT_SINGLELINE | win32.DT_NOPREFIX;
const body_format = win32.DT_WORDBREAK | win32.DT_NOPREFIX;

/// A terminal's view (`Overlays.renderer_health`).
pub const View = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// the renderer is unhealthy; null until then, if it could not be
    /// made, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// Whether the renderer is unhealthy, as the core last said (`set`).
    on: bool = false,

    pub fn deinit(self: *View, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.on = false;
    }

    /// For `Overlays.place`: it has no text of the overlays' to show it.
    pub fn shows(self: *const View) bool {
        return self.on;
    }

    /// All of the terminal, for `Overlays.place`; drawn again at each new
    /// size, since what it holds is centred.
    pub fn placeIn(self: *const View, dpi: u32, pane: Size) ?Overlays.Placed {
        _ = self;
        _ = dpi;
        return .{ .in = .{ .left = 0, .top = 0, .right = pane.width, .bottom = pane.height }, .redraw = false };
    }

    /// The view, `client` big, drawn into `hdc` at `dpi` over a terminal
    /// whose background is `background`: that background, and on it the
    /// icon, the title and the line in `textOn(background)`, laid out by
    /// `Layout`. Its fonts and the icon are made for each paint, which
    /// comes only as it shows or changes size, so they follow the system's
    /// message font and the DPI with nothing kept.
    pub fn draw(self: *const View, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = self;
        _ = dark;
        _ = font;
        SearchBar.fill(hdc, client, background);
        const m = Metrics.init(dpi);
        const fonts = Fonts.init(dpi);
        defer fonts.deinit();
        const icon = loadIcon(m.icon);
        defer if (icon) |i| {
            _ = win32.DestroyIcon(i);
        };
        const title_size = measure(hdc, fonts.title, title_text, title_format, m.text);
        const fit = Layout.fit(m, client.right, icon != null, title_size.width);
        const body_size = measure(hdc, fonts.body, body_text, body_format, fit.wrap);
        const l = Layout.init(m, .{ .width = client.right, .height = client.bottom }, fit.icon, title_size, body_size);
        if (icon) |i| {
            if (l.icon) |at| _ = win32.DrawIconEx(hdc, at.left, at.top, i, at.right - at.left, at.bottom - at.top, 0, null, win32.DI_NORMAL);
        }
        const color = textOn(background);
        Overlays.drawText(hdc, fonts.title, title_text, l.title, color, title_format);
        Overlays.drawText(hdc, fonts.body, body_text, l.body, color, body_format);
    }
};

/// `renderer_health` on `surface`: `.unhealthy` shows its view, its
/// window made first if it has none, and `.healthy` hides it. False if
/// the window cannot be made, which is tried again the next time the
/// renderer is unhealthy; `.healthy` with no view makes none.
pub fn set(surface: *Surface, health: renderer.Health) bool {
    const self = &surface.overlays.renderer_health;
    self.on = health == .unhealthy;
    if (self.hwnd == null) {
        if (!self.on) return true;
        const hwnd = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a renderer error view err={}", .{win32.GetLastError()});
            return false;
        };
        self.hwnd = hwnd;
        _ = win32.SetWindowTextW(hwnd, name_text.ptr);
    }
    Overlays.place(surface);
    return true;
}

/// The view's two fonts at a DPI: the system's message font for the line
/// (`TabBar.messageLogFont`), and the title in it at twice its size, as
/// macOS's title font is about twice its body's.
const Fonts = struct {
    title: ?win32.HGDIOBJ,
    body: ?win32.HGDIOBJ,

    fn init(dpi: u32) Fonts {
        const message = TabBar.messageFont(dpi);
        var lf = TabBar.messageLogFont(dpi) orelse return .{ .title = null, .body = message };
        lf.lfHeight *|= 2;
        return .{ .title = win32.CreateFontIndirectW(&lf), .body = message };
    }

    fn deinit(self: Fonts) void {
        if (self.title) |f| _ = win32.DeleteObject(f);
        if (self.body) |f| _ = win32.DeleteObject(f);
    }
};

/// The exe's icon, `size` square, scaled from its largest image; null in
/// an exe without it (the test exe), and if it cannot be loaded.
fn loadIcon(size: i32) ?win32.HICON {
    const module = win32.GetModuleHandleW(null) orelse return null;
    const handle = win32.LoadImageW(@ptrCast(module), @ptrFromInt(icon_resource_id), win32.IMAGE_ICON, size, size, win32.LR_DEFAULTCOLOR) orelse return null;
    return @ptrCast(handle);
}

/// The size of `text` in `font` drawn into `hdc` by `format`, at most
/// `width` wide where it wraps; none if it cannot be measured.
fn measure(hdc: win32.HDC, font: ?win32.HGDIOBJ, text: [:0]const u16, format: win32.UINT, width: i32) Size {
    const old = if (font) |f| win32.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = win32.SelectObject(hdc, o);
    };
    var r: RECT = .{ .left = 0, .top = 0, .right = width, .bottom = 0 };
    if (win32.DrawTextW(hdc, text.ptr, std.math.lossyCast(c_int, text.len), &r, format | win32.DT_CALCRECT) == 0)
        return .{ .width = 0, .height = 0 };
    return .{ .width = r.right - r.left, .height = r.bottom - r.top };
}

/// Black or white, whichever reads better on `background`: black where
/// its WCAG 2 relative luminance is above 0.179, where the two contrast
/// ratios cross.
pub fn textOn(background: win32.COLORREF) win32.COLORREF {
    return if (luminance(background) > 0.179) win32.rgb(0, 0, 0) else win32.rgb(255, 255, 255);
}

/// WCAG 2's relative luminance of the sRGB colour `c`.
fn luminance(c: win32.COLORREF) f64 {
    // A COLORREF is 0x00BBGGRR.
    const shifts = [_]u5{ 0, 8, 16 };
    const weights = [_]f64{ 0.2126, 0.7152, 0.0722 };
    var sum: f64 = 0;
    for (shifts, weights) |shift, w| {
        const s = @as(f64, @floatFromInt((c >> shift) & 0xff)) / 255;
        const l = if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
        sum += w * l;
    }
    return sum;
}

/// The view's sizes at a DPI, from macOS's at 96: the icon's 128, the
/// line's most width, 350, the stack's spacing, 8, and its padding, 16.
pub const Metrics = struct {
    icon: i32,
    text: i32,
    gap: i32,
    pad: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .icon = SearchBar.Metrics.scale(128, dpi),
            .text = SearchBar.Metrics.scale(350, dpi),
            .gap = SearchBar.Metrics.scale(8, dpi),
            .pad = SearchBar.Metrics.scale(16, dpi),
        };
    }
};

/// Where the view's parts go in a view `view` big, in its own client
/// coordinates: as macOS's stacks them, the icon (if `with_icon`) at the
/// left, `gap` before the title over the line, the title and the line
/// left-aligned, the icon centred down the text; all of it centred in the
/// view, and at least `pad` from its top and left edges. `fit` decides
/// the icon and the width the line wraps at.
pub const Layout = struct {
    icon: ?RECT,
    title: RECT,
    body: RECT,

    /// Whether the icon goes beside the text, and the width the line wraps
    /// at, in a view `view_width` wide whose title is `title_width` wide
    /// on one line. As macOS's stack, which gives the text what the icon
    /// and the padding leave, up to its most width: the icon stays while
    /// the title fits beside it, and the line wraps at what is left, so a
    /// narrow terminal wraps it rather than cutting it off.
    pub const Fit = struct { icon: bool, wrap: i32 };

    pub fn fit(m: Metrics, view_width: i32, has_icon: bool, title_width: i32) Fit {
        const avail = view_width - 2 * m.pad;
        const icon = has_icon and avail - m.icon - m.gap >= title_width;
        const room = if (icon) avail - m.icon - m.gap else avail;
        return .{ .icon = icon, .wrap = @max(1, @min(m.text, room)) };
    }

    pub fn init(m: Metrics, view: Size, with_icon: bool, title_size: Size, body_size: Size) Layout {
        const text_w = @max(title_size.width, body_size.width);
        const text_h = title_size.height + body_size.height;
        const total_w = text_w + if (with_icon) m.icon + m.gap else 0;
        const total_h = if (with_icon) @max(m.icon, text_h) else text_h;
        const left = @max(m.pad, @divTrunc(view.width - total_w, 2));
        const top = @max(m.pad, @divTrunc(view.height - total_h, 2));
        const text_left = left + if (with_icon) m.icon + m.gap else 0;
        const text_top = top + @divTrunc(total_h - text_h, 2);
        return .{
            .icon = if (with_icon) blk: {
                const icon_top = top + @divTrunc(total_h - m.icon, 2);
                break :blk .{ .left = left, .top = icon_top, .right = left + m.icon, .bottom = icon_top + m.icon };
            } else null,
            .title = .{ .left = text_left, .top = text_top, .right = text_left + title_size.width, .bottom = text_top + title_size.height },
            .body = .{
                .left = text_left,
                .top = text_top + title_size.height,
                .right = text_left + body_size.width,
                .bottom = text_top + title_size.height + body_size.height,
            },
        };
    }
};

test "win32: the renderer error view's sizes are macOS's at 96 DPI, scaled" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(128, m.icon);
    try testing.expectEqual(350, m.text);
    try testing.expectEqual(8, m.gap);
    try testing.expectEqual(16, m.pad);
    const big = Metrics.init(144);
    try testing.expectEqual(192, big.icon);
    try testing.expectEqual(525, big.text);
    try testing.expectEqual(12, big.gap);
    try testing.expectEqual(24, big.pad);
}

test "win32: the renderer error view centres the icon beside the title over the line" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const title_size: Size = .{ .width = 100, .height = 40 };
    const body_size: Size = .{ .width = 300, .height = 60 };

    // 128 + 8 + 300 = 436 wide, 128 high, in 800 by 600.
    const l = Layout.init(m, .{ .width = 800, .height = 600 }, true, title_size, body_size);
    try testing.expectEqual(RECT{ .left = 182, .top = 236, .right = 310, .bottom = 364 }, l.icon.?);
    // The text, 100 high, centred down the icon, left-aligned after it.
    try testing.expectEqual(RECT{ .left = 318, .top = 250, .right = 418, .bottom = 290 }, l.title);
    try testing.expectEqual(RECT{ .left = 318, .top = 290, .right = 618, .bottom = 350 }, l.body);

    // Text taller than the icon: the icon centred down it.
    const tall = Layout.init(m, .{ .width = 800, .height = 600 }, true, title_size, .{ .width = 300, .height = 200 });
    try testing.expectEqual(@as(i32, (600 - 240) / 2), tall.title.top);
    try testing.expectEqual(@as(i32, (600 - 240) / 2 + (240 - 128) / 2), tall.icon.?.top);

    // No icon to draw: the text centred alone.
    const none = Layout.init(m, .{ .width = 800, .height = 600 }, false, title_size, body_size);
    try testing.expect(none.icon == null);
    try testing.expectEqual(RECT{ .left = 250, .top = 250, .right = 350, .bottom = 290 }, none.title);
    try testing.expectEqual(RECT{ .left = 250, .top = 290, .right = 550, .bottom = 350 }, none.body);

    // Larger than the view: the padding from its top-left corner kept.
    const small = Layout.init(m, .{ .width = 200, .height = 50 }, false, title_size, body_size);
    try testing.expectEqual(RECT{ .left = 16, .top = 16, .right = 116, .bottom = 56 }, small.title);
}

test "win32: the renderer error view wraps its line at what the icon and the padding leave, and drops the icon where the title does not fit beside it" {
    const testing = std.testing;
    const m = Metrics.init(96);
    // Wide: the icon, and the line at its most width, macOS's 350.
    try testing.expectEqual(Layout.Fit{ .icon = true, .wrap = 350 }, Layout.fit(m, 800, true, 100));
    // Just wide enough for it: 16 + 128 + 8 + 350 + 16.
    try testing.expectEqual(Layout.Fit{ .icon = true, .wrap = 350 }, Layout.fit(m, 518, true, 100));
    // Narrower: the line wraps at what is left beside the icon.
    try testing.expectEqual(Layout.Fit{ .icon = true, .wrap = 299 }, Layout.fit(m, 467, true, 100));
    // Just room for the title beside the icon; one pixel less, no icon,
    // and the line wraps across the view less its padding.
    try testing.expectEqual(Layout.Fit{ .icon = true, .wrap = 100 }, Layout.fit(m, 268, true, 100));
    try testing.expectEqual(Layout.Fit{ .icon = false, .wrap = 235 }, Layout.fit(m, 267, true, 100));
    // No icon to draw: the line takes the view less its padding.
    try testing.expectEqual(Layout.Fit{ .icon = false, .wrap = 350 }, Layout.fit(m, 800, false, 100));
    try testing.expectEqual(Layout.Fit{ .icon = false, .wrap = 268 }, Layout.fit(m, 300, false, 100));
    // Narrower than the padding: still a width to wrap at.
    try testing.expectEqual(Layout.Fit{ .icon = false, .wrap = 1 }, Layout.fit(m, 20, true, 100));
}

test "win32: the renderer error view's text is black or white, whichever reads better on the background" {
    const testing = std.testing;
    const black = win32.rgb(0, 0, 0);
    const white = win32.rgb(255, 255, 255);
    try testing.expectEqual(white, textOn(black));
    try testing.expectEqual(black, textOn(white));
    // Ghostty's default background, #282c34, and a light theme's.
    try testing.expectEqual(white, textOn(win32.rgb(0x28, 0x2c, 0x34)));
    try testing.expectEqual(black, textOn(win32.rgb(0xfd, 0xf6, 0xe3)));
    // Either side of the crossing: #757575 is 0.178, #767676 0.181.
    try testing.expectEqual(white, textOn(win32.rgb(0x75, 0x75, 0x75)));
    try testing.expectEqual(black, textOn(win32.rgb(0x76, 0x76, 0x76)));
}
