//! A transparent window: one whose terminals show what is behind it where
//! their background is translucent (`background-opacity` below 1), as GTK
//! and macOS show it. Probe C0 of the third parity plan measured on Windows
//! 11 what that takes (~/ghostty-win/host/local/out/parity3-c0-report.md,
//! the fork's notes), each part checked against the blend arithmetic over
//! a known backing:
//!
//! - The terminal presents through a composition swap chain, whose alpha
//!   DWM honours; it ignores an HWND chain's (`renderer.D3D11`, asked by
//!   `Surface.presentsAlpha`).
//! - The frame has blur-behind over an empty region (`frameMade`): on
//!   Windows 8 and later nothing is blurred, but DWM composes the frame's
//!   redirection surface with its alpha. Without it the frame is opaque;
//!   DwmExtendFrameIntoClientArea alone shows black on Windows 11.
//! - The terminal's own window, under its chain, paints black
//!   (`paintTerminal`): GDI writes alpha 0, so the chain blends with the
//!   desktop rather than with what the surface held there, GDI white.
//! - Anything else GDI draws in the frame comes out added to what is
//!   behind it, for the same alpha 0: the chrome windows are layered with
//!   alpha 255 (`chrome`), which a child window can be only in a process
//!   whose manifest declares Windows 8 or later (dist/windows), and the
//!   frame's own paint, its dividers, goes through a buffer made opaque
//!   (`fillOpaque`). The themed scroll bar, the terminal's non-client
//!   area, is opaque as it is.
//!
//! `background-blur` blurs what is behind a transparent frame while its
//! opacity is below 1, with DWM's acrylic system backdrop, from Windows 11
//! 22H2 (`applyBlur`): C0
//! measured it blurring under the blend, where Mica only tints it with the
//! wallpaper. Its intensity is ignored, as on Linux.
//!
//! `toggle_background_opacity` leaves a window transparent: its terminals
//! are given `background-opacity` 1 (`App.giveSurface`), which C0 measured
//! a composition chain drawing as an opaque window does (comp1), and the
//! frame the default backdrop.
//!
//! C0 rejected a frame without a redirection bitmap
//! (WS_EX_NOREDIRECTIONBITMAP): it loses the scroll bar and every pixel the
//! frame paints, and can be chosen only as the frame is made.
//!
//! A window is transparent, or not, from when its frame is made until it
//! closes (`Window.transparent`): as `background-opacity` is then
//! (`wanted`), or for a tab moved to a new window as its old window was
//! (`App.moveTabAt`). So a terminal is always in a frame of the kind its
//! renderer presents for, which the renderer asks once. A window made
//! opaque stays so when the opacity drops below 1 later, until it is
//! opened again; macOS needs a restart for any change of it.

const std = @import("std");
const builtin = @import("builtin");

const configpkg = @import("../../config.zig");
const win32 = @import("win32.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

/// Whether a window made under `config` is to be transparent: its
/// terminals' background is translucent.
pub fn wanted(config: *const configpkg.Config) bool {
    return config.@"background-opacity" < 1;
}

/// For tests: answers in place of DwmEnableBlurBehindWindow, given the
/// frame and whether blur-behind is turned on, as the test runner's
/// session may have no DWM to ask; whether DWM took it.
pub var test_blur_behind: if (builtin.is_test) ?*const fn (win32.HWND, bool) bool else void =
    if (builtin.is_test) null else {};

/// Make `frame`, a new window's, let the desktop through: blur-behind over
/// an empty region; and start buffered painting on this thread for its
/// dividers (`fillOpaque`), which the frame's WM_NCDESTROY ends
/// (`frameDestroyed`), as each BufferedPaintInit is to be matched by a
/// BufferedPaintUnInit (Learn). Whether the window is transparent; if
/// either step fails, logged, it is opaque, with no blur-behind.
pub fn frameMade(frame: win32.HWND) bool {
    if (!blurBehind(frame, true)) return false;
    const hr = win32.BufferedPaintInit();
    if (hr >= 0) return true;
    log.warn("a window is opaque: BufferedPaintInit failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    _ = blurBehind(frame, false);
    return false;
}

/// For a transparent frame's WM_NCDESTROY: what `frameMade` started.
pub fn frameDestroyed() void {
    _ = win32.BufferedPaintUnInit();
}

/// DwmEnableBlurBehindWindow on all of `frame` (`on`) or none; whether DWM
/// took it, logged if not. The region (0, 0)-(-1, -1) is empty: blur-behind
/// is on, and blurs nothing.
fn blurBehind(frame: win32.HWND, on: bool) bool {
    if (builtin.is_test) if (test_blur_behind) |answer| return answer(frame, on);
    const empty = win32.CreateRectRgn(0, 0, -1, -1) orelse {
        log.warn("a window is opaque: no region for its blur-behind err={}", .{win32.GetLastError()});
        return false;
    };
    // DWM keeps none of it: the probe deleted it at once.
    defer _ = win32.DeleteObject(empty);
    const blur: win32.DWM_BLURBEHIND = .{
        .flags = win32.DWM_BB_ENABLE | win32.DWM_BB_BLURREGION,
        .enable = if (on) .TRUE else .FALSE,
        .region = empty,
        .transition_on_maximized = .FALSE,
    };
    const hr = win32.DwmEnableBlurBehindWindow(frame, &blur);
    if (hr >= 0) return true;
    log.warn("DwmEnableBlurBehindWindow failed on={} hr=0x{x}", .{ on, @as(u32, @bitCast(hr)) });
    return false;
}

/// The system backdrop DWM draws behind a transparent frame
/// (DWMWA_SYSTEMBACKDROP_TYPE, dwmapi.h's DWM_SYSTEMBACKDROP_TYPE): the
/// default, which a window has until it asks, or acrylic, which blurs what
/// is behind the frame (C0: Mica, 2, only tints it with the wallpaper).
pub const Backdrop = enum(win32.DWORD) {
    default = win32.DWMSBT_AUTO,
    acrylic = win32.DWMSBT_TRANSIENTWINDOW,
};

/// The backdrop `config` asks a transparent window for: acrylic while
/// `background-blur` blurs at all (`BackgroundBlur.enabled`, so macOS's
/// glass too, as on Linux) and `background-opacity` is below 1, as the
/// option says and macOS does (`ghostty_set_window_background_blur` in
/// embedded.zig). At 1 the terminals draw opaque, and acrylic would show
/// only in the title bar, which an opaque window's has not. DWM takes no
/// radius: the intensity is ignored, as on Linux.
pub fn backdrop(config: *const configpkg.Config) Backdrop {
    if (config.@"background-opacity" >= 1) return .default;
    return if (config.@"background-blur".enabled()) .acrylic else .default;
}

/// The first build of Windows whose DWM has DWMWA_SYSTEMBACKDROP_TYPE
/// (Windows 11 22H2, Learn); what it does below that is not documented, so
/// it is not asked there.
pub const backdrop_build = 22621;

/// For tests: the build of Windows to take in place of RtlGetVersion's,
/// and what answers in place of DwmSetWindowAttribute for the backdrop.
pub var test_build: if (builtin.is_test) ?u32 else void = if (builtin.is_test) null else {};
pub var test_backdrop: if (builtin.is_test) ?*const fn (win32.HWND, Backdrop) bool else void =
    if (builtin.is_test) null else {};

/// The running build of Windows, asked once: RtlGetVersion, which no
/// manifest's compatibility section changes (unlike GetVersionEx).
fn build() u32 {
    if (builtin.is_test) if (test_build) |b| return b;
    const Once = struct {
        var value: ?u32 = null;
    };
    if (Once.value) |b| return b;
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    const b: u32 = switch (std.os.windows.ntdll.RtlGetVersion(&info)) {
        .SUCCESS => info.dwBuildNumber,
        else => 0,
    };
    Once.value = b;
    return b;
}

/// Whether `applyBlur` has said once that blur needs a later Windows.
var old_build_logged = false;

/// Give `window`'s frame the backdrop the configuration asks for, if the
/// window is transparent, or the default while the background is toggled
/// opaque (`App.background_opaque`): an opaque window is left as it is, as
/// is every frame on a build before `backdrop_build`. Called as the frame
/// is made, for each new configuration and at each toggle; a failed call
/// leaves `Window.backdrop` as it was, so the next one tries again.
pub fn applyBlur(window: *Window) void {
    if (!window.transparent) return;
    const want: Backdrop = if (window.app.background_opaque) .default else backdrop(&window.app.config);
    if (want == window.backdrop) return;
    if (build() < backdrop_build) {
        if (!old_build_logged) {
            old_build_logged = true;
            log.info("background-blur needs Windows 11 22H2 (build {}), this is build {}", .{ backdrop_build, build() });
        }
        return;
    }
    if (!setBackdrop(window.hwnd, want)) return;
    window.backdrop = want;
}

fn setBackdrop(frame: win32.HWND, to: Backdrop) bool {
    if (builtin.is_test) if (test_backdrop) |answer| return answer(frame, to);
    const value: win32.DWORD = @backingInt(to);
    const hr = win32.DwmSetWindowAttribute(frame, win32.DWMWA_SYSTEMBACKDROP_TYPE, &value, @sizeOf(win32.DWORD));
    if (hr >= 0) return true;
    log.warn("cannot set a window's backdrop to={t} hr=0x{x}", .{ to, @as(u32, @bitCast(hr)) });
    return false;
}

/// Layer `hwnd`, a GDI-drawn window just made in `window`'s frame (its
/// bar, a search bar, the command palette, an overlay), if the window is
/// transparent (`layer`). Not their own children, the fields and the
/// palette's list: a layered window's children are drawn into its
/// surface, and come out opaque with it (c3s's probes, which left the
/// search field and the palette's field and list unlayered: each the
/// colour it is in an opaque window).
pub fn chrome(window: *const Window, hwnd: win32.HWND) void {
    if (window.transparent) _ = layer(hwnd);
}

/// For tests: answers in place of SetLayeredWindowAttributes in `layer`,
/// as the test runner has no manifest, and so cannot layer a child window.
pub var test_set_alpha: if (builtin.is_test) ?*const fn (win32.HWND) bool else void =
    if (builtin.is_test) null else {};

/// Whether `layer` has said once that a window could not be layered.
var layer_failed_logged = false;

/// Make `hwnd` layered with alpha 255: drawn into a surface of its own and
/// composed opaque, where its pixels would otherwise add to what is behind
/// the frame. Whether it is; a layered window shows nothing until its
/// attributes are set, so if they cannot be, it is not layered after all,
/// and shows as GDI drew it, said once for the process (without the
/// manifest's Windows 8 declaration every child fails, error 87).
pub fn layer(hwnd: win32.HWND) bool {
    const style = win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE);
    const layered: isize = win32.WS_EX_LAYERED;
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, style | layered);
    if (setAlpha(hwnd)) return true;
    const err = win32.GetLastError();
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, style);
    if (!layer_failed_logged) {
        layer_failed_logged = true;
        log.warn("a window over a transparent terminal cannot be layered, so it shows blended with what is behind it err={}", .{err});
    }
    return false;
}

fn setAlpha(hwnd: win32.HWND) bool {
    if (builtin.is_test) if (test_set_alpha) |answer| return answer(hwnd);
    return win32.SetLayeredWindowAttributes(hwnd, 0, 255, win32.LWA_ALPHA).toBool();
}

/// A terminal's WM_PAINT in a transparent frame: its update region filled
/// black, alpha 0 in the frame's surface, under the terminal's chain,
/// which then blends with the desktop (C0: #203060 at 0.5 over GDI white,
/// unpainted, showed #94a0c3). The region is validated either way, or
/// Windows would post WM_PAINT again at once, forever.
pub fn paintTerminal(hwnd: win32.HWND) void {
    var paint: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &paint) orelse {
        _ = win32.ValidateRect(hwnd, null);
        return;
    };
    defer _ = win32.EndPaint(hwnd, &paint);
    const black = win32.CreateSolidBrush(win32.rgb(0, 0, 0)) orelse return;
    defer _ = win32.DeleteObject(black);
    _ = win32.FillRect(hdc, &paint.rcPaint, black);
}

/// Whether `fillOpaque` has said once that it could not buffer a paint.
var buffer_failed_logged = false;

/// Fill `rect` of `hdc`, a transparent frame's paint DC, with `brush`,
/// opaque: in a buffer whose alpha is set to 255 before it is copied to
/// the frame, as GDI alone writes alpha 0, which DWM shows added to what
/// is behind the frame (C0: the divider #131d3a over magenta showed
/// #ff1dff). Filled directly, said once, if no buffer can be had.
pub fn fillOpaque(hdc: win32.HDC, rect: *const win32.RECT, brush: win32.HBRUSH) void {
    if (rect.right <= rect.left or rect.bottom <= rect.top) return;
    var mem: ?win32.HDC = null;
    const buffer = win32.BeginBufferedPaint(hdc, rect, win32.BPBF_TOPDOWNDIB, null, &mem) orelse {
        if (!buffer_failed_logged) {
            buffer_failed_logged = true;
            log.warn("a transparent window's dividers show blended with what is behind it: BeginBufferedPaint failed err={}", .{win32.GetLastError()});
        }
        _ = win32.FillRect(hdc, rect, brush);
        return;
    };
    // The buffer's DC, set whenever the buffer is (Learn), takes the
    // target's coordinates.
    _ = win32.FillRect(mem.?, rect, brush);
    _ = win32.BufferedPaintSetAlpha(buffer, null, 255);
    _ = win32.EndBufferedPaint(buffer, .TRUE);
}

/// For tests: a shown 40 by 40 pop-up, owned by no window, which paints
/// only from its own messages, none of which a test dispatches.
fn testPopup() !win32.HWND {
    const hwnd = win32.CreateWindowExW(0, win32.L("STATIC"), null, win32.WS_POPUP, 0, 0, 40, 40, null, null, null, null) orelse
        return error.TestUnexpectedResult;
    _ = win32.ShowWindow(hwnd, win32.SW_SHOWNOACTIVATE);
    return hwnd;
}

/// For tests: the colour at 1, 1 of `hwnd`'s client area.
fn testPixel(hwnd: win32.HWND) !win32.COLORREF {
    const hdc = win32.GetDC(hwnd) orelse return error.TestUnexpectedResult;
    defer _ = win32.ReleaseDC(hwnd, hdc);
    return win32.GetPixel(hdc, 1, 1);
}

/// For tests: `hwnd`'s client area filled with `color`, outside a paint.
fn testFill(hwnd: win32.HWND, color: win32.COLORREF) !void {
    const hdc = win32.GetDC(hwnd) orelse return error.TestUnexpectedResult;
    defer _ = win32.ReleaseDC(hwnd, hdc);
    const brush = win32.CreateSolidBrush(color) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteObject(brush);
    const all: win32.RECT = .{ .left = 0, .top = 0, .right = 40, .bottom = 40 };
    _ = win32.FillRect(hdc, &all, brush);
}

test "win32: a window layered over a transparent frame is opaque, and one that cannot be is left as it was" {
    // A top-level window can be layered in any process: it is, with alpha
    // 255 and nothing else. One whose attributes are refused, here by a
    // stand-in, as a child's are in the test runner, which has no manifest
    // (error 87), keeps the style it had. A top-level one too: a child
    // there does not take WS_EX_LAYERED at all, so its style is as it was
    // whether `layer` puts it back or not (c3u's mutant layer-keeps-style
    // survived a child).
    const testing = std.testing;
    const top = try testPopup();
    defer _ = win32.DestroyWindow(top);
    try testing.expect(layer(top));
    const layered: isize = win32.WS_EX_LAYERED;
    try testing.expect(win32.GetWindowLongPtrW(top, win32.GWL_EXSTYLE) & layered != 0);
    var key: win32.COLORREF = 1;
    var alpha: win32.BYTE = 0;
    var flags: win32.DWORD = 0;
    try testing.expect(win32.GetLayeredWindowAttributes(top, &key, &alpha, &flags).toBool());
    try testing.expectEqual(255, alpha);
    try testing.expectEqual(win32.LWA_ALPHA, flags);

    const refused = try testPopup();
    defer _ = win32.DestroyWindow(refused);
    const before = win32.GetWindowLongPtrW(refused, win32.GWL_EXSTYLE);
    try testing.expect(before & layered == 0);
    const Refuse = struct {
        fn setAlpha(_: win32.HWND) bool {
            return false;
        }
    };
    test_set_alpha = &Refuse.setAlpha;
    defer test_set_alpha = null;
    try testing.expect(!layer(refused));
    try testing.expectEqual(before, win32.GetWindowLongPtrW(refused, win32.GWL_EXSTYLE));
}

test "win32: a transparent frame's terminal paints black, its dividers their colour" {
    // The terminal's paint fills its update region black, and validates
    // it: left invalid, Windows would post WM_PAINT again at once. The
    // dividers' paint fills with the brush through its buffer, copied to
    // the window. Each over white, so that a paint that draws nothing
    // shows.
    const testing = std.testing;
    const hwnd = try testPopup();
    defer _ = win32.DestroyWindow(hwnd);

    try testFill(hwnd, win32.rgb(255, 255, 255));
    _ = win32.InvalidateRect(hwnd, null, .FALSE);
    paintTerminal(hwnd);
    try testing.expect(!win32.GetUpdateRect(hwnd, null, .FALSE).toBool());
    try testing.expectEqual(win32.rgb(0, 0, 0), try testPixel(hwnd));

    try testFill(hwnd, win32.rgb(255, 255, 255));
    _ = win32.InvalidateRect(hwnd, null, .FALSE);
    var paint: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &paint) orelse return error.TestUnexpectedResult;
    const brush = win32.CreateSolidBrush(win32.rgb(19, 29, 58)) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteObject(brush);
    fillOpaque(hdc, &paint.rcPaint, brush);
    _ = win32.EndPaint(hwnd, &paint);
    try testing.expectEqual(win32.rgb(19, 29, 58), try testPixel(hwnd));
}
