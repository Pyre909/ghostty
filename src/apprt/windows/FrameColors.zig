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
/// perceived luminance of 0.5, as `window-theme = auto` picks it. From the
/// focused colours, so that the mode does not change with the focus.
pub fn dark(self: FrameColors) bool {
    return self.background.perceivedLuminance() <= 0.5;
}

/// These colours for an inactive frame: the background darkened as GTK
/// darkens an unfocused header bar (`windowhandle:backdrop`,
/// `oklab(from <background> calc(l * 0.9) a b)`), the foreground as it is.
/// A saturated colour can leave sRGB as it darkens; it is clamped channel
/// by channel (`Oklab.rgb`), not mapped back by reducing its chroma as CSS
/// Color 4 describes.
pub fn unfocused(self: FrameColors) FrameColors {
    var lab = Oklab.of(self.background);
    lab.l *= 0.9;
    return .{ .background = lab.rgb(), .foreground = self.foreground };
}

/// A colour in Oklab (Björn Ottosson, "A perceptual color space for image
/// processing", 2020, whose matrices these are), from and to 8-bit sRGB.
pub const Oklab = struct {
    l: f32,
    a: f32,
    b: f32,

    pub fn of(c: RGB) Oklab {
        const r = linear(c.r);
        const g = linear(c.g);
        const b = linear(c.b);
        const l_ = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
        const m_ = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
        const s_ = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
        return .{
            .l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            .a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            .b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
        };
    }

    /// The nearest 8-bit sRGB colour, each channel clamped to its range.
    pub fn rgb(self: Oklab) RGB {
        const l_ = self.l + 0.3963377774 * self.a + 0.2158037573 * self.b;
        const m_ = self.l - 0.1055613458 * self.a - 0.0638541728 * self.b;
        const s_ = self.l - 0.0894841775 * self.a - 1.2914855480 * self.b;
        const l = l_ * l_ * l_;
        const m = m_ * m_ * m_;
        const s = s_ * s_ * s_;
        return .{
            .r = encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            .g = encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            .b = encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
        };
    }

    /// sRGB's transfer function, from an 8-bit channel to linear light.
    fn linear(c: u8) f32 {
        const v = @as(f32, @floatFromInt(c)) / 255;
        return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }

    fn encode(v: f32) u8 {
        const c = std.math.clamp(v, 0, 1);
        const e = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
        return @intFromFloat(@round(std.math.clamp(e, 0, 1) * 255));
    }
};

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

test "win32: Oklab matches its published values and round-trips sRGB" {
    const testing = std.testing;
    // sRGB red and white, as Ottosson's post lists them.
    const red = Oklab.of(.{ .r = 255, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.627955), red.l, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.224863), red.a, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.125846), red.b, 1e-4);
    const white = Oklab.of(.{ .r = 255, .g = 255, .b = 255 });
    try testing.expectApproxEqAbs(@as(f32, 1), white.l, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), white.a, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), white.b, 1e-4);

    // Every 8-bit grey and a spread of colours come back as they went in.
    var v: u16 = 0;
    while (v < 256) : (v += 1) {
        const c: RGB = .{ .r = @intCast(v), .g = @intCast(v), .b = @intCast(v) };
        try testing.expectEqual(c, Oklab.of(c).rgb());
        const d: RGB = .{ .r = @intCast(v), .g = @intCast(255 - v), .b = @intCast((v * 7) % 256) };
        try testing.expectEqual(d, Oklab.of(d).rgb());
    }
}

test "win32: an unfocused frame's background is GTK's: Oklab lightness times 0.9" {
    const testing = std.testing;
    const colours = [_]RGB{
        .{ .r = 0x28, .g = 0x2C, .b = 0x34 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0xF8, .g = 0xF0, .b = 0xE0 },
        .{ .r = 0x2E, .g = 0x6B, .b = 0xA8 },
    };
    for (colours) |c| {
        const focused: FrameColors = .{ .background = c, .foreground = .{ .r = 1, .g = 2, .b = 3 } };
        const u = focused.unfocused();
        try testing.expectEqual(focused.foreground, u.foreground);
        const before = Oklab.of(c);
        const after = Oklab.of(u.background);
        // Within what 8 bits a channel can hold, for colours that stay in
        // sRGB as they darken.
        try testing.expectApproxEqAbs(before.l * 0.9, after.l, 0.004);
        try testing.expectApproxEqAbs(before.a, after.a, 0.004);
        try testing.expectApproxEqAbs(before.b, after.b, 0.004);
    }
    // Black has no lightness to lose.
    const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
    try testing.expectEqual(black, (FrameColors{ .background = black, .foreground = black }).unfocused().background);
}
