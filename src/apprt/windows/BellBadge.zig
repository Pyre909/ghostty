//! A bell on a window's taskbar button while a terminal in any of its
//! tabs rings (`Surface.bell_ringing`) and `bell-features` has
//! `attention`: Windows' counterpart of macOS's dock badge
//! (`setDockBadge` in macos/Sources/App/macOS/AppDelegate.swift), which
//! counts the windows with a ringing bell. A taskbar button is a
//! window's, not the app's, so each window shows its own, and a fixed
//! bell, not a count: the overlay is not meant to change often
//! (ITaskbarList3::SetOverlayIcon).
//!
//! The icon is drawn here, as no system icon is a bell: the bell of the
//! system's icon font (Segoe Fluent Icons, else Segoe MDL2 Assets, both
//! U+EA8F) in dark grey on an amber disk, the bell border's amber
//! (BellBorder.zig). Without either font the disk shows alone. Its size
//! is a small icon's at the window's DPI, which is the taskbar's when the
//! window is on the taskbar's monitor, and it is drawn again when that
//! DPI changes.
//!
//! The overlay is set only once Explorer said the button exists
//! (`Window.taskbar_button`), and set again when it says so again, after
//! a restart of Explorer (`buttonCreated`).

const std = @import("std");

const win32 = @import("win32.zig");
const Window = @import("Window.zig");

const L = win32.L;
const log = std.log.scoped(.win32);

/// The bell border's amber, as BGR.
const amber = [3]u8{ 0, 204, 255 };
/// The bell's grey, as BGR.
const dark = [3]u8{ 32, 32, 32 };

/// The fonts with the bell, in order; Segoe Fluent Icons is Windows 11's.
const faces = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons"),
    std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"),
};
/// The bell in both (Bell in Microsoft's lists of their glyphs).
const bell = [_]u16{0xEA8F};

/// The largest icon drawn, within the pixels of the mask buffer.
const max_size = 64;

/// Show the bell on the window's taskbar button, at the window's size,
/// or remove it, as its terminals and `bell-features` now ask, if that
/// changed (`Window.bell_badge`). Called wherever a terminal's bell starts
/// or stops ringing, `bell-features` changes, a terminal or a tab joins
/// or leaves the window, or its DPI changes.
pub fn sync(window: *Window) void {
    const want: ?i32 = if (wanted(window)) iconSize(window) else null;
    if (want == window.bell_badge) return;
    if (!window.taskbar_button) return;
    const list = window.app.taskbar_list orelse return;

    const icon: ?win32.HICON = if (want) |size| make(size) orelse return else null;
    // The taskbar keeps its own copy.
    defer if (icon) |i| {
        _ = win32.DestroyIcon(i);
    };
    if (!list.setOverlay(window.hwnd, icon, if (want != null) L("Bell") else null)) return;
    window.bell_badge = want;
}

/// Explorer made the window's button, which has no overlay, again after
/// it restarted: show the bell on it if it rings.
pub fn buttonCreated(window: *Window) void {
    window.bell_badge = null;
    sync(window);
}

/// Whether the window's button should show the bell.
fn wanted(window: *const Window) bool {
    if (!window.app.config.@"bell-features".attention) return false;
    for (window.tabs.items) |t| {
        var it = t.tree.iterator();
        while (it.next()) |entry| if (entry.view.bell_ringing) return true;
    }
    return false;
}

/// A small icon's size at the window's DPI; at the system DPI before
/// Windows 10 1607, which has no other (`App.bar_metric`).
fn iconSize(window: *const Window) i32 {
    if (window.app.bar_metric) |m| {
        const dpi = m.dpi_of(window.hwnd);
        if (dpi != 0) return sizeOf(m.metric_for(win32.SM_CXSMICON, dpi));
    }
    return sizeOf(win32.GetSystemMetrics(win32.SM_CXSMICON));
}

/// `iconSize` from what the system metric gave: 16, its size at 96 DPI,
/// if it gave nothing, and never more than `max_size`.
fn sizeOf(metric: c_int) i32 {
    if (metric <= 0) return 16;
    return @min(metric, max_size);
}

/// The bell as an icon `size` pixels square, the caller's to destroy;
/// null, logged, if it could not be made.
fn make(size: i32) ?win32.HICON {
    std.debug.assert(size > 0 and size <= max_size);

    const dc = win32.CreateCompatibleDC(null) orelse return failed("CreateCompatibleDC");
    defer _ = win32.DeleteDC(dc);
    const color = Dib.init(dc, size) orelse return failed("CreateDIBSection");
    defer color.deinit();
    if (!paint(dc, color, size)) return failed("SelectObject");

    // All zero: the colour bitmap's alpha alone decides what shows. Rows
    // of a monochrome bitmap are WORD-aligned.
    const mask_bits: [max_size * max_size / 8]u8 = @splat(0);
    const mask = win32.CreateBitmap(size, size, 1, 1, &mask_bits) orelse return failed("CreateBitmap");
    defer _ = win32.DeleteObject(mask);
    return win32.CreateIconIndirect(&.{ .fIcon = .TRUE, .hbmMask = mask, .hbmColor = color.bitmap }) orelse
        failed("CreateIconIndirect");
}

/// A 32-bit DIB section `size` pixels square and its pixels, BGRA, top
/// row first (each row of 32-bit pixels is DWORD-aligned already).
const Dib = struct {
    bitmap: win32.HGDIOBJ,
    pixels: [][4]u8,

    fn init(dc: win32.HDC, size: i32) ?Dib {
        const header: win32.BITMAPINFOHEADER = .{
            .biSize = @sizeOf(win32.BITMAPINFOHEADER),
            .biWidth = size,
            .biHeight = -size,
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = win32.BI_RGB,
            .biSizeImage = 0,
            .biXPelsPerMeter = 0,
            .biYPelsPerMeter = 0,
            .biClrUsed = 0,
            .biClrImportant = 0,
        };
        var bits: ?*anyopaque = null;
        const bitmap = win32.CreateDIBSection(dc, &header, win32.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
        const n: usize = @intCast(size * size);
        return .{ .bitmap = bitmap, .pixels = @as([*][4]u8, @ptrCast(@alignCast(bits.?)))[0..n] };
    }

    fn deinit(self: Dib) void {
        _ = win32.DeleteObject(self.bitmap);
    }
};

/// Paint the bell into `dib`, `size` pixels square: the glyph is drawn in
/// white on black, so that any channel is its coverage, and then each
/// pixel made from it and the disk (`pixel`). False if `dib` could not be
/// selected into `dc`.
fn paint(dc: win32.HDC, dib: Dib, size: i32) bool {
    @memset(dib.pixels, .{ 0, 0, 0, 0 });
    {
        const old = win32.SelectObject(dc, dib.bitmap) orelse return false;
        defer _ = win32.SelectObject(dc, old);
        if (!drawGlyph(dc, size, &faces)) log.warn("taskbar bell: no font with the bell, the disk alone", .{});
        // GDI batches its drawing: done before the pixels are read.
        _ = win32.GdiFlush();
    }
    const side: usize = @intCast(size);
    for (dib.pixels, 0..) |*p, i| {
        p.* = pixel(p[1], diskCoverage(size, @intCast(i % side), @intCast(i / side)));
    }
    return true;
}

fn failed(comptime what: []const u8) ?win32.HICON {
    log.warn("taskbar bell: " ++ what ++ " failed err={}", .{win32.GetLastError()});
    return null;
}

/// Draw the bell, centred, in white into `dc`'s bitmap, in the first of
/// `candidates` installed; false if none is.
fn drawGlyph(dc: win32.HDC, size: i32, candidates: []const [:0]const u16) bool {
    for (candidates) |face| {
        const font = win32.CreateFontW(
            -glyphHeight(size),
            0,
            0,
            0,
            win32.FW_NORMAL,
            0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.ANTIALIASED_QUALITY,
            win32.DEFAULT_PITCH,
            face.ptr,
        ) orelse continue;
        defer _ = win32.DeleteObject(font);
        const old = win32.SelectObject(dc, font) orelse continue;
        defer _ = win32.SelectObject(dc, old);
        // GDI gives some other font for a face it lacks, which would draw
        // a box or nothing for the bell.
        var got: [64]u16 = @splat(0);
        if (win32.GetTextFaceW(dc, got.len, &got) <= 0) continue;
        if (!std.mem.eql(u16, std.mem.sliceTo(&got, 0), face)) continue;

        _ = win32.SetBkMode(dc, win32.TRANSPARENT);
        _ = win32.SetTextColor(dc, win32.rgb(255, 255, 255));
        var rect: win32.RECT = .{ .left = 0, .top = 0, .right = size, .bottom = size };
        _ = win32.DrawTextW(dc, &bell, bell.len, &rect, win32.DT_CENTER | win32.DT_VCENTER | win32.DT_SINGLELINE | win32.DT_NOPREFIX);
        return true;
    }
    return false;
}

/// The bell's em height for an icon `size` pixels square: the glyph
/// fills about four fifths of its em, so it stays within the disk.
fn glyphHeight(size: i32) i32 {
    return @max(1, @divTrunc(size * 5 + 4, 8));
}

/// How much of the pixel at (`x`, `y`) the disk filling the icon covers,
/// 0 to 1: one where its centre is half a pixel or more inside the
/// circle, none where it is as far outside, linear between, which
/// smooths the edge.
fn diskCoverage(size: i32, x: i32, y: i32) f32 {
    const r: f32 = @as(f32, @floatFromInt(size)) / 2;
    const dx = @as(f32, @floatFromInt(x)) + 0.5 - r;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - r;
    return std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
}

/// A pixel of the icon, BGRA with straight (not premultiplied) alpha, as
/// a 32-bit icon's colour bitmap holds it, from the glyph's coverage
/// `glyph` (0 to 255) and the disk's `disk`: the bell's grey over amber,
/// as opaque as the disk covers it.
fn pixel(glyph: u8, disk: f32) [4]u8 {
    const a: u16 = @intFromFloat(@round(std.math.clamp(disk, 0, 1) * 255));
    var out: [4]u8 = undefined;
    for (0..3) |c| {
        out[c] = @intCast((@as(u16, amber[c]) * (255 - glyph) + @as(u16, dark[c]) * glyph + 127) / 255);
    }
    out[3] = @intCast(a);
    return out;
}

test "win32: the bell's pixels are amber, the glyph grey, with straight alpha" {
    const t = std.testing;
    try t.expectEqual([4]u8{ 0, 204, 255, 255 }, pixel(0, 1));
    try t.expectEqual([4]u8{ 32, 32, 32, 255 }, pixel(255, 1));
    try t.expectEqual([4]u8{ 32, 32, 32, 0 }, pixel(255, 0));
    try t.expectEqual([4]u8{ 0, 204, 255, 128 }, pixel(0, 0.5));
    // The colour does not depend on the disk's coverage, only the alpha.
    for (0..256) |g| for (1..11) |d| {
        const p = pixel(@intCast(g), @as(f32, @floatFromInt(d)) / 10);
        try t.expectEqualSlices(u8, pixel(@intCast(g), 1)[0..3], p[0..3]);
    };
}

test "win32: the bell's icon blends its edge as straight alpha" {
    // Drawn over white, a pixel the disk half covers is amber and white
    // in proportion; a premultiplied bitmap would darken it.
    const t = std.testing;
    const size = 16;
    const icon = make(size) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyIcon(icon);
    const dc = win32.CreateCompatibleDC(null) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteDC(dc);
    const target = Dib.init(dc, size) orelse return error.TestUnexpectedResult;
    defer target.deinit();
    const pixels = target.pixels;
    @memset(pixels, .{ 255, 255, 255, 255 });
    const old = win32.SelectObject(dc, target.bitmap) orelse return error.TestUnexpectedResult;
    defer _ = win32.SelectObject(dc, old);
    try t.expect(win32.DrawIconEx(dc, 0, 0, icon, size, size, 0, null, win32.DI_NORMAL).toBool());
    _ = win32.GdiFlush();

    // The rim in the top left corner, away from the glyph.
    var checked: usize = 0;
    for (0..size / 4) |y| for (0..size / 4) |x| {
        const d = diskCoverage(size, @intCast(x), @intCast(y));
        if (d < 0.25 or d > 0.75) continue;
        const got = pixels[y * size + x];
        const a = @round(d * 255) / 255;
        for (0..3) |c| {
            const want = 255 * (1 - a) + @as(f32, @floatFromInt(amber[c])) * a;
            try t.expectApproxEqAbs(want, @as(f32, @floatFromInt(got[c])), 4);
        }
        checked += 1;
    };
    try t.expect(checked > 0);
}

test "win32: the bell's disk fills its icon's circle, smoothly edged" {
    const t = std.testing;
    for ([_]i32{ 16, 20, 24, 32, 64 }) |size| {
        const last = size - 1;
        try t.expectEqual(@as(f32, 1), diskCoverage(size, @divTrunc(size, 2), @divTrunc(size, 2)));
        try t.expectEqual(@as(f32, 0), diskCoverage(size, 0, 0));
        // Symmetric in both axes and across the diagonal.
        var area: f32 = 0;
        var partial: usize = 0;
        var y: i32 = 0;
        while (y < size) : (y += 1) {
            var x: i32 = 0;
            while (x < size) : (x += 1) {
                const c = diskCoverage(size, x, y);
                try t.expectEqual(c, diskCoverage(size, last - x, y));
                try t.expectEqual(c, diskCoverage(size, x, last - y));
                try t.expectEqual(c, diskCoverage(size, y, x));
                area += c;
                if (c > 0 and c < 1) partial += 1;
            }
        }
        // About the circle's area, pi r^2.
        const r: f32 = @as(f32, @floatFromInt(size)) / 2;
        try t.expectApproxEqRel(std.math.pi * r * r, area, 0.03);
        // The edge smoothed: pixels it crosses are partly covered.
        try t.expect(partial >= @as(usize, @intCast(size)));
    }
}

test "win32: the bell's icon is a small icon's size, within bounds" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 16), sizeOf(0));
    try t.expectEqual(@as(i32, 16), sizeOf(16));
    try t.expectEqual(@as(i32, 24), sizeOf(24));
    try t.expectEqual(@as(i32, 64), sizeOf(80));
    try t.expect(glyphHeight(16) < 16);
    try t.expect(glyphHeight(1) >= 1);
}

test "win32: the bell's icon is made, its glyph drawn" {
    const t = std.testing;
    for ([_]i32{ 16, 24, 64 }) |size| {
        const icon = make(size) orelse return error.TestUnexpectedResult;
        try t.expect(win32.DestroyIcon(icon).toBool());
    }
    // Painted: clear outside the disk, amber on it, the bell's grey in
    // its middle.
    for ([_]i32{ 16, 32 }) |size| {
        const dc = win32.CreateCompatibleDC(null) orelse return error.TestUnexpectedResult;
        defer _ = win32.DeleteDC(dc);
        const dib = Dib.init(dc, size) orelse return error.TestUnexpectedResult;
        defer dib.deinit();
        try t.expect(paint(dc, dib, size));
        try t.expectEqual(@as(u8, 0), dib.pixels[0][3]);
        const side: usize = @intCast(size);
        var plain: usize = 0;
        var grey: usize = 0;
        for (side / 4..side * 3 / 4) |y| for (side / 4..side * 3 / 4) |x| {
            const p = dib.pixels[y * side + x];
            if (std.mem.eql(u8, &p, &.{ 0, 204, 255, 255 })) plain += 1;
            if (p[3] == 255 and p[1] < 64) grey += 1;
        };
        try t.expect(plain > 0);
        try t.expect(grey > 0);
    }
    // Windows 11 has Segoe Fluent Icons; a face it lacks is refused, not
    // drawn in whatever GDI gives instead.
    const dc = win32.CreateCompatibleDC(null) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteDC(dc);
    try t.expect(drawGlyph(dc, 16, &faces));
    const missing = [_][:0]const u16{std.unicode.utf8ToUtf16LeStringLiteral("Ghostty No Such Font")};
    try t.expect(!drawGlyph(dc, 16, &missing));
}
