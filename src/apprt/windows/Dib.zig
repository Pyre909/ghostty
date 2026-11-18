//! A 32-bit top-down DIB section whose pixels the program writes, for a
//! bitmap drawn by hand: the bell's taskbar badge (BellBadge.zig) and a
//! terminal's drag handle (DragHandle.zig). Also the coverage of a disc,
//! which both blend their round edges by.

const std = @import("std");

const win32 = @import("win32.zig");

const Dib = @This();

bitmap: win32.HGDIOBJ,
/// BGRA, top row first, `width` by `height`.
pixels: [][4]u8,

/// A bitmap `width` by `height` for `dc`; null if it cannot be made.
pub fn init(dc: ?win32.HDC, width: i32, height: i32) ?Dib {
    const header: win32.BITMAPINFOHEADER = .{
        .biSize = @sizeOf(win32.BITMAPINFOHEADER),
        .biWidth = width,
        // Rows from the top down.
        .biHeight = -height,
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
    const n: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    return .{ .bitmap = bitmap, .pixels = @as([*][4]u8, @ptrCast(@alignCast(bits.?)))[0..n] };
}

pub fn deinit(self: Dib) void {
    _ = win32.DeleteObject(self.bitmap);
}

/// How much of a pixel whose centre is `dx`, `dy` from a disc's centre the
/// disc of `radius` covers, 0 to 1: all within it less half a pixel, none
/// beyond it plus half, linear between, which smooths the edge.
pub fn discCoverage(dx: f32, dy: f32, radius: f32) f32 {
    return std.math.clamp(radius - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
}
