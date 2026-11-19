//! Mica behind an opaque frame's tab bar, as behind its title bar, from
//! Windows 11 22H2 (`Transparency.backdrop_build`). DWM gives an opaque
//! frame's caption Mica by itself; for the tab bar under it, what was
//! measured (build 26300) to take:
//!
//! - The frame asks for Mica (DWMSBT_MAINWINDOW) and extends its frame
//!   over the bar (DwmExtendFrameIntoClientArea). Where the bar then draws
//!   alpha 0 the caption's Mica shows through, in the caption's colour,
//!   active and inactive. Extended under the default backdrop, the frame
//!   showed black, its caption with it; asked for Mica alone, the caption
//!   showed as before.
//! - GDI writes alpha 0, so what it draws there comes out added to the
//!   Mica (#3A3A3A showed #545C5F): the bar draws into a buffer whose
//!   pixels in the bar's own colour are then made transparent and the rest
//!   opaque (`keyOut`). Text's antialiased edges, blended with the bar's
//!   colour, stay opaque, in a colour close to the Mica's.
//! - Its title field, a child window there, is layered with alpha 255
//!   (`Transparency.layer`), as a transparent frame's chrome is.
//!
//! Not under `window-theme = ghostty`, whose caption and bar are in its
//! own colours; not for a transparent frame, whose backdrop is
//! `background-blur`'s (Transparency.zig); not without a title bar, nor
//! in the quick terminal, a pop-up; and not while the tab overview,
//! which covers the bar, is open: such a frame keeps the default backdrop
//! until it first reaches over its bar.
const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const Transparency = @import("Transparency.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

/// Give `window`'s frame Mica behind its tab bar, or take it away, as
/// its bar, theme, decoration and tab overview now ask (`wanted`). The
/// backdrop is asked for as the frame first reaches over its bar, and then
/// kept while the frame is opaque, with buffered painting for its bar
/// (`Transparency.startBufferedPaint`): a frame that never does keeps the
/// default. The extension follows the bar. A failed
/// call leaves `Window.backdrop` and `Window.mica_top` as they were, so
/// the next layout tries again, and is said once for the process: a DWM
/// that refuses would refuse at every WM_SIZE of a resize. Called after
/// every layout and theme change.
pub fn apply(window: *Window) void {
    if (window.transparent) return;
    // Only in tests that answer for DWM: the others' frames keep the
    // default, as they did before.
    if (builtin.is_test and test_extend == null) return;
    if (Transparency.build() < Transparency.backdrop_build) return;
    const top = wanted(window);
    // As it is, unless left extended under another backdrop: a frame
    // DWM would not take the reach from as it turned transparent
    // (`leave`) asks for Mica again on turning opaque.
    if (top == window.mica_top and (top == 0 or window.backdrop == .mica)) return;
    if (window.backdrop != .mica) {
        if (!Transparency.startBufferedPaint(window)) return;
        const hr = Transparency.askBackdrop(window.hwnd, .mica);
        if (hr < 0) {
            refused("set a window's backdrop to Mica", hr);
            return;
        }
        window.backdrop = .mica;
    }
    if (!extend(window.hwnd, top)) return;
    window.mica_top = top;
    // A field open in the bar as Mica comes would show added to it.
    if (top > 0) if (window.bar.editor.edit) |edit| {
        _ = Transparency.layer(edit);
    };
    window.bar.invalidate();
}

/// Take the frame's reach over its bar away, as `window` turns
/// transparent (`Window.setTransparent`): a transparent frame's backdrop
/// is `background-blur`'s (`Transparency.applyBlur`), which replaces
/// Mica, and its bar is layered, with the title field in it. Left
/// extended, logged, if DWM refuses; the next turn to opaque applies
/// Mica again.
pub fn leave(window: *Window) void {
    if (window.mica_top != 0 and extend(window.hwnd, 0)) window.mica_top = 0;
    if (window.bar.editor.edit) |edit| Transparency.unlayer(edit);
}

/// Whether `refused` has said once that DWM refused.
var refused_logged = false;

fn refused(what: []const u8, hr: win32.HRESULT) void {
    if (refused_logged) return;
    refused_logged = true;
    log.warn("cannot {s}, so the tab bar shows no Mica behind it hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
}

/// How far the frame is to reach into the client area: over the tab bar
/// while it shows and Mica is wanted, else not at all. The quick
/// terminal is a pop-up with no title bar, whatever `window-decoration`
/// says (`Window.isDecorated` reads only that).
fn wanted(window: *const Window) i32 {
    if (window.frame_colors != null or window.quick) return 0;
    if (!window.isDecorated() or window.overview.open) return 0;
    if (window.bar.hwnd == null) return 0;
    return window.barHeight();
}

/// For tests: answers in place of DwmExtendFrameIntoClientArea, given the
/// frame and the top margin; whether DWM took it. Mica is applied in tests
/// only while it is set (`apply`).
pub var test_extend: if (builtin.is_test) ?*const fn (win32.HWND, i32) bool else void =
    if (builtin.is_test) null else {};

fn extend(frame: win32.HWND, top: i32) bool {
    if (builtin.is_test) if (test_extend) |answer| return answer(frame, top);
    const margins: win32.MARGINS = .{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = top, .cyBottomHeight = 0 };
    const hr = win32.DwmExtendFrameIntoClientArea(frame, &margins);
    if (hr >= 0) return true;
    refused("extend a window's frame over its tab bar", hr);
    return false;
}

/// Make `pixels`, a buffer's rows of 32-bit BGRA, `row` pixels apart, of
/// which the first `width` are drawn, ready to show over Mica: a pixel in
/// `key` transparent (0, premultiplied), any other opaque.
pub fn keyOut(pixels: []u32, row: usize, width: usize, key: win32.COLORREF) void {
    std.debug.assert(width <= row);
    // A COLORREF is 0x00BBGGRR; a BGRA pixel read as a u32 is 0xAARRGGBB.
    const k: u32 = ((key & 0xFF) << 16) | (key & 0xFF00) | ((key >> 16) & 0xFF);
    var start: usize = 0;
    while (start + width <= pixels.len) : (start += row) {
        for (pixels[start..][0..width]) |*p| {
            p.* = if (p.* & 0x00FF_FFFF == k) 0 else p.* | 0xFF00_0000;
        }
    }
}

test "win32: over Mica the bar's colour is transparent, all else opaque" {
    const testing = std.testing;
    const key = win32.rgb(0x1F, 0x2E, 0x3D);
    // Two rows of three drawn pixels, four apart. GDI left alpha 0, or
    // anything at all: it is set either way.
    var pixels = [_]u32{
        0x001F2E3D, 0x00FFFFFF, 0x7F1F2E3D, 0x12345678,
        0x003D2E1F, 0x00000000, 0x001F2E3D, 0x001F2E3D,
    };
    keyOut(&pixels, 4, 3, key);
    try testing.expectEqualSlices(u32, &.{
        0x00000000, 0xFFFFFFFF, 0x00000000, 0x12345678,
        // The channels the other way round is another colour; black is
        // opaque black.
        0xFF3D2E1F, 0xFF000000, 0x00000000, 0x001F2E3D,
    }, &pixels);
}
