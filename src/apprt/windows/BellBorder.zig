//! A terminal's bell border (`bell-features` `border`): a line around the
//! terminal's edges while its bell rings (`Surface.bell_ringing`), as GTK
//! shows one over its surface (the revealer at
//! src/apprt/gtk/ui/1.0/surface.blp:129, styled `bell-overlay` at
//! src/apprt/gtk/css/style.css:132) and macOS (`BellBorderOverlay`,
//! macos/Sources/Ghostty/Surface View/SurfaceView.swift:905). It is
//! macOS's (lines 910-912): 3 pixels wide at 96 DPI, amber at half
//! opacity, here blended with the terminal's background
//! (`Overlays.terminalBackground`), since an overlay is opaque. GTK's
//! also fills the terminal with its accent colour at half opacity, which
//! an opaque overlay cannot do, and both fade it in and out; this one
//! shows and hides at once.
//!
//! It is one of the terminal's overlays (Overlays.zig), just above the
//! read-only badge, as GTK stacks it. Its window covers the whole terminal
//! and is shaped to the line alone (`shape`), so the terminal shows inside
//! it, and the pointer and clicks over the line go to the terminal, as
//! GTK's takes none (`can-target: false`). The window is made the first
//! time the border shows (`set`).

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const ChildExited = @import("ChildExited.zig");

const RECT = win32.RECT;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyBellBorderClass";

/// macOS's amber, `Color(red: 1.0, green: 0.8, blue: 0.0)`, in sRGB.
const amber = win32.rgb(255, 204, 0);

/// A terminal's border (`Overlays.bell_border`).
pub const Border = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// the border shows; null until then, if it could not be made, and
    /// once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// Whether it shows, as `set` last said.
    on: bool = false,
    /// What its window's region was made for, so that it is made again
    /// only when that changes; null for none yet.
    shaped: ?Shape = null,

    const Shape = struct { width: i32, height: i32, line: i32 };

    pub fn deinit(self: *Border, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.on = false;
        self.shaped = null;
    }

    /// For `Overlays.place`: it has no text to show it.
    pub fn shows(self: *const Border) bool {
        return self.on;
    }

    /// All of the terminal, for `Overlays.place`.
    pub fn placeIn(self: *const Border, dpi: u32, pane: Size) ?Overlays.Placed {
        _ = self;
        _ = dpi;
        return .{ .in = .{ .left = 0, .top = 0, .right = pane.width, .bottom = pane.height }, .redraw = false };
    }

    /// Shape `hwnd`, to be placed `in`, to the line at `dpi`, for
    /// `Overlays.place`, before it shows: outside the line, the window is
    /// not there, and what is under it shows and gets the pointer. A
    /// window too small for a hole, as wide or as high as two lines or
    /// less, is all line. False, logged, if it cannot be shaped: it is
    /// not shown, as it would cover the terminal, and is shaped again the
    /// next time it is placed.
    pub fn shape(self: *Border, hwnd: win32.HWND, dpi: u32, in: RECT) bool {
        const want: Shape = .{ .width = in.right - in.left, .height = in.bottom - in.top, .line = lineWidth(dpi) };
        if (self.shaped) |had| if (std.meta.eql(had, want)) return true;
        // Until it is shaped again: a failure below may leave the window's
        // region as it was, or not, which nothing says.
        self.shaped = null;
        const outer = createRectRgn(0, 0, want.width, want.height) orelse {
            log.warn("cannot make the bell border's region err={}", .{win32.GetLastError()});
            return false;
        };
        if (want.width > 2 * want.line and want.height > 2 * want.line) {
            const inner = createRectRgn(want.line, want.line, want.width - want.line, want.height - want.line) orelse {
                log.warn("cannot make the bell border's hole err={}", .{win32.GetLastError()});
                _ = win32.DeleteObject(outer);
                return false;
            };
            defer _ = win32.DeleteObject(inner);
            // CombineRgn tells its failure by its answer alone.
            if (win32.CombineRgn(outer, outer, inner, win32.RGN_DIFF) == win32.RGN_ERROR) {
                log.warn("cannot cut the bell border's hole err=RGN_ERROR", .{});
                _ = win32.DeleteObject(outer);
                return false;
            }
        }
        if (win32.SetWindowRgn(hwnd, outer, .TRUE) == 0) {
            log.warn("cannot shape the bell border err={}", .{win32.GetLastError()});
            _ = win32.DeleteObject(outer);
            return false;
        }
        // The window owns the region now.
        self.shaped = want;
        return true;
    }

    /// The line, over all of the window: its region leaves the rest out.
    pub fn draw(self: *const Border, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = self;
        _ = dpi;
        _ = dark;
        _ = font;
        SearchBar.fill(hdc, client, color(background));
    }
};

/// For tests: answers in place of CreateRectRgn (`Border.shape`), as
/// `Overlays.test_make` stands for CreateWindowExW.
pub var test_create_rgn: if (builtin.is_test) ?*const fn (i32, i32, i32, i32) ?win32.HRGN else void =
    if (builtin.is_test) null else {};

fn createRectRgn(left: i32, top: i32, right: i32, bottom: i32) ?win32.HRGN {
    if (builtin.is_test) if (test_create_rgn) |create| return create(left, top, right, bottom);
    return win32.CreateRectRgn(left, top, right, bottom);
}

/// The line's width at `dpi`: macOS's 3 points, at least a pixel.
pub fn lineWidth(dpi: u32) i32 {
    return @max(1, SearchBar.Metrics.scale(3, dpi));
}

/// `amber` at half opacity over `background`, as macOS draws it over the
/// terminal.
pub fn color(background: win32.COLORREF) win32.COLORREF {
    return ChildExited.mix(amber, background);
}

/// Show `surface`'s border while `on`, its window made first if it has
/// none, or hide it. A window that cannot be made is logged, and tried
/// again the next time it shows: the next time the terminal starts
/// ringing, or a configuration change while it rings
/// (`Surface.showBell`); hiding it with none makes none.
pub fn set(surface: *Surface, on: bool) void {
    const self = &surface.overlays.bell_border;
    self.on = on;
    if (self.hwnd == null) {
        if (!on) return;
        self.hwnd = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a bell border err={}", .{win32.GetLastError()});
            return;
        };
        // A window made again, after one was destroyed, has no region.
        self.shaped = null;
    }
    Overlays.place(surface);
}

test "win32: the bell border is macOS's amber at half over the background" {
    const testing = std.testing;
    try testing.expectEqual(win32.rgb(128, 102, 0), color(win32.rgb(0, 0, 0)));
    try testing.expectEqual(win32.rgb(255, 230, 128), color(win32.rgb(255, 255, 255)));
    // Ghostty's default background, #282c34.
    try testing.expectEqual(win32.rgb(148, 124, 26), color(win32.rgb(0x28, 0x2c, 0x34)));
    try testing.expectEqual(3, lineWidth(96));
    try testing.expectEqual(6, lineWidth(192));
    try testing.expectEqual(1, lineWidth(1));
}

test "win32: the bell border's region is the line, or all of a window too small for a hole, made again only for a new shape" {
    const testing = std.testing;
    const hwnd = win32.CreateWindowExW(0, win32.L("STATIC"), win32.L(""), win32.WS_POPUP, 0, 0, 40, 40, null, null, null, null) orelse
        return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);
    const Regions = struct {
        var made: usize = 0;
        /// The call from which they fail, if any.
        var fail_from: ?usize = null;
        fn create(left: i32, top: i32, right: i32, bottom: i32) ?win32.HRGN {
            made += 1;
            if (fail_from) |n| if (made >= n) return null;
            return win32.CreateRectRgn(left, top, right, bottom);
        }
    };
    Regions.made = 0;
    Regions.fail_from = null;
    test_create_rgn = &Regions.create;
    defer test_create_rgn = null;
    const rgn = win32.CreateRectRgn(0, 0, 0, 0) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteObject(rgn);
    const in = struct {
        fn f(r: win32.HRGN, x: i32, y: i32) bool {
            return win32.PtInRegion(r, x, y).toBool();
        }
    }.f;
    var border: Border = .{};

    // 40 by 40 at 96 DPI: a line 3 wide around a hole; placed elsewhere,
    // the same.
    try testing.expect(border.shape(hwnd, 96, .{ .left = 10, .top = 10, .right = 50, .bottom = 50 }));
    try testing.expectEqual(2, Regions.made);
    try testing.expect(win32.GetWindowRgn(hwnd, rgn) != win32.RGN_ERROR);
    try testing.expect(in(rgn, 2, 20) and !in(rgn, 3, 20) and in(rgn, 37, 20) and !in(rgn, 36, 20));
    try testing.expect(in(rgn, 20, 2) and !in(rgn, 20, 3) and in(rgn, 20, 37) and !in(rgn, 20, 36));
    try testing.expect(border.shape(hwnd, 96, .{ .left = 0, .top = 0, .right = 40, .bottom = 40 }));
    try testing.expectEqual(2, Regions.made);

    // As wide or as high as two lines or less: all line, without a hole;
    // one more pixel: a hole a pixel across.
    for ([_][2]i32{ .{ 6, 40 }, .{ 5, 40 }, .{ 2, 40 }, .{ 40, 6 }, .{ 40, 1 } }) |size| {
        const made = Regions.made;
        try testing.expect(border.shape(hwnd, 96, .{ .left = 0, .top = 0, .right = size[0], .bottom = size[1] }));
        try testing.expectEqual(made + 1, Regions.made);
        try testing.expect(win32.GetWindowRgn(hwnd, rgn) != win32.RGN_ERROR);
        for (0..@as(usize, @intCast(size[0]))) |x| {
            for (0..@as(usize, @intCast(size[1]))) |y| try testing.expect(in(rgn, @intCast(x), @intCast(y)));
        }
    }
    try testing.expect(border.shape(hwnd, 96, .{ .left = 0, .top = 0, .right = 7, .bottom = 40 }));
    try testing.expect(win32.GetWindowRgn(hwnd, rgn) != win32.RGN_ERROR);
    try testing.expect(in(rgn, 2, 20) and !in(rgn, 3, 20) and in(rgn, 4, 20));

    // A region, or its hole, that cannot be made: not shaped, and tried
    // again the next time, at the same size.
    Regions.fail_from = Regions.made + 1;
    try testing.expect(!border.shape(hwnd, 96, .{ .left = 0, .top = 0, .right = 30, .bottom = 30 }));
    Regions.fail_from = Regions.made + 2;
    try testing.expect(!border.shape(hwnd, 96, .{ .left = 0, .top = 0, .right = 30, .bottom = 30 }));
    Regions.fail_from = null;
    const before = Regions.made;
    try testing.expect(border.shape(hwnd, 96, .{ .left = 0, .top = 0, .right = 30, .bottom = 30 }));
    try testing.expectEqual(before + 2, Regions.made);
    try testing.expect(win32.GetWindowRgn(hwnd, rgn) != win32.RGN_ERROR);
    try testing.expect(in(rgn, 29, 15) and !in(rgn, 26, 15));
}
