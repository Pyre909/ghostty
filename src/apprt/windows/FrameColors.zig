//! The colours of a frame's chrome under `window-theme = ghostty`: its
//! caption and tab bar in `window-titlebar-background` and
//! `window-titlebar-foreground`, each falling back to the terminal's
//! `background` and `foreground`, as GTK colours its header bar
//! (`Application.loadRuntimeCss`). Only from the configuration, as on GTK:
//! a background a program sets (OSC 11) does not reach the frame.
//!
//! DWM draws the caption in them (DWMWA_CAPTION_COLOR and
//! DWMWA_TEXT_COLOR, Windows 11), over its Mica, and keeps them while the
//! frame is inactive; the caption buttons follow the immersive dark mode
//! alone, so the mode follows the caption's colour (`dark`), measured
//! dark on dark otherwise.
const FrameColors = @This();

const std = @import("std");

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const terminal = @import("../../terminal/main.zig");
const win32 = @import("win32.zig");

const RGB = terminal.color.RGB;

background: RGB,
foreground: RGB,

/// The colours `config` gives every frame, or null when they are the
/// system's: under any `window-theme` but `ghostty`, and while a theme set
/// for the session (`set_window_theme`) overrides it, as GTK writes its
/// header bar's colours only then.
pub fn of(config: *const configpkg.Config, override: apprt.action.WindowTheme) ?FrameColors {
    if (override != .config or config.@"window-theme" != .ghostty) return null;
    return .{
        .background = (config.@"window-titlebar-background" orelse config.background).toTerminalRGB(),
        .foreground = (config.@"window-titlebar-foreground" orelse config.foreground).toTerminalRGB(),
    };
}

/// Whether the caption's mode is dark: its background at or below a
/// perceived luminance of 0.5, as `window-theme = auto` picks it.
pub fn dark(self: FrameColors) bool {
    return self.background.perceivedLuminance() <= 0.5;
}

/// `a` with `t` of `b` mixed in, per channel in sRGB, rounded.
pub fn mix(a: RGB, b: RGB, t: f32) RGB {
    const ch = struct {
        fn f(x: u8, y: u8, w: f32) u8 {
            const v = @as(f32, @floatFromInt(x)) * (1 - w) + @as(f32, @floatFromInt(y)) * w;
            return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
        }
    }.f;
    return .{ .r = ch(a.r, b.r, t), .g = ch(a.g, b.g, t), .b = ch(a.b, b.b, t) };
}

pub fn colorref(c: RGB) win32.COLORREF {
    return win32.rgb(c.r, c.g, c.b);
}

/// The tab bar's colours under these: the bar in the background, the
/// shown and hovered tab tinted toward the foreground, the text in it.
/// The tints are ours; GTK leaves its tab bar to libadwaita.
pub fn tabBar(self: FrameColors) struct {
    bar: RGB,
    shown: RGB,
    hover: RGB,
    text: RGB,
    dim: RGB,
} {
    return .{
        .bar = self.background,
        .shown = mix(self.background, self.foreground, 0.16),
        .hover = mix(self.background, self.foreground, 0.08),
        .text = self.foreground,
        .dim = mix(self.background, self.foreground, 0.7),
    };
}

test "win32: frame colours only under window-theme = ghostty, from the config" {
    const testing = std.testing;
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    config.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
    config.foreground = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };

    for (std.enums.values(configpkg.Config.WindowTheme)) |theme| {
        config.@"window-theme" = theme;
        try testing.expectEqual(theme == .ghostty, of(&config, .config) != null);
        // A theme set for the session gives the system's colours.
        for ([_]apprt.action.WindowTheme{ .system, .light, .dark }) |o|
            try testing.expect(of(&config, o) == null);
    }

    config.@"window-theme" = .ghostty;
    var c = of(&config, .config).?;
    try testing.expectEqual(RGB{ .r = 0x28, .g = 0x2C, .b = 0x34 }, c.background);
    try testing.expectEqual(RGB{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, c.foreground);
    try testing.expect(c.dark());

    // The title bar's own colours win, each on its own.
    config.@"window-titlebar-background" = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE };
    c = of(&config, .config).?;
    try testing.expectEqual(RGB{ .r = 0xEE, .g = 0xEE, .b = 0xEE }, c.background);
    try testing.expectEqual(RGB{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, c.foreground);
    try testing.expect(!c.dark());
    config.@"window-titlebar-foreground" = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    c = of(&config, .config).?;
    try testing.expectEqual(RGB{ .r = 0x10, .g = 0x20, .b = 0x30 }, c.foreground);
}

test "win32: frame colours mix toward the foreground" {
    const testing = std.testing;
    const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
    const white: RGB = .{ .r = 255, .g = 255, .b = 255 };
    try testing.expectEqual(black, mix(black, white, 0));
    try testing.expectEqual(white, mix(black, white, 1));
    try testing.expectEqual(RGB{ .r = 128, .g = 128, .b = 128 }, mix(black, white, 0.5));
    try testing.expectEqual(RGB{ .r = 0x10, .g = 0x80, .b = 0xF0 }, mix(.{ .r = 0x10, .g = 0x80, .b = 0xF0 }, white, 0));

    const bar = (FrameColors{ .background = black, .foreground = white }).tabBar();
    try testing.expectEqual(black, bar.bar);
    try testing.expectEqual(white, bar.text);
    // The shown tab stands further from the bar than a hovered one.
    try testing.expect(bar.shown.r > bar.hover.r and bar.hover.r > bar.bar.r);
    try testing.expectEqual(@as(win32.COLORREF, 0x00F08010), colorref(.{ .r = 0x10, .g = 0x80, .b = 0xF0 }));
}
