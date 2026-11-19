//! font-thicken for the DirectWrite backend: the outline of a glyph
//! grown outward by a fraction of a pixel, as CoreText's font smoothing
//! grows it on macOS.
//!
//! DirectWrite has nothing that does this. Its bold simulation is one
//! fixed amount, and the contrast it adds to text is applied where the
//! text is blended, which a glyph atlas never is. So the glyph is drawn
//! at `scale` times its size, grown there by taking the most coverage
//! within a disc around each sample, and averaged back down. Growing the
//! coverage at the size of the pixels instead would undercount a stem a
//! pixel or so wide, whose two edges share the pixels in between.
//!
//! How much CoreText grows a glyph was measured, with the context that
//! coretext.zig draws into, on Menlo and SF Mono from 8 to 48 pixels
//! (2026-11-18): each edge moves out by the same distance horizontally
//! and vertically, and the width a stem gains is the size of the font
//! in pixels times a factor that rises with the strength, up to 0.6 of
//! a pixel. `widening` is that rule.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// How many samples a pixel is split into along each axis.
pub const scale: u32 = 4;

/// The most width a stem gains, in pixels, at any size and strength.
const max_widening = 0.6;

/// The width a stem gains per pixel of the font's size, measured at
/// the strengths where CoreText's own steps begin: 128, 192, 224 and
/// 255. CoreText draws the same below 128 as at 0, so that step's
/// factor stands at 96, not 0: the ramp up to 128 is then 32 wide, as
/// the two above 192 are, and strengths up to 96 draw as macOS draws
/// them. Between these points the factor is interpolated so that every
/// strength has its own.
const factors = [_]struct { strength: f64, factor: f64 }{
    .{ .strength = 96, .factor = 0.0115 },
    .{ .strength = 128, .factor = 0.0166 },
    .{ .strength = 192, .factor = 0.0215 },
    .{ .strength = 224, .factor = 0.0265 },
    .{ .strength = 255, .factor = 0.0313 },
};

/// The width, in pixels, that thickening adds to a stem of a font of
/// `em_px` pixels to the em: the half of it on each side.
pub fn widening(em_px: f64, strength: u8) f64 {
    const s: f64 = @floatFromInt(strength);
    const factor = for (factors[1..], 1..) |hi, i| {
        const lo = factors[i - 1];
        if (s <= hi.strength) {
            const t = std.math.clamp((s - lo.strength) / (hi.strength - lo.strength), 0, 1);
            break lo.factor + (hi.factor - lo.factor) * t;
        }
    } else factors[factors.len - 1].factor;
    return @min(@max(em_px, 0) * factor, max_widening);
}

/// The distance, in samples, that each edge moves out.
pub fn radius(em_px: f64, strength: u8) f64 {
    return widening(em_px, strength) / 2 * @as(f64, @floatFromInt(scale));
}

/// A box of whole samples or pixels, +Y down, right and bottom outside.
pub const Box = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Box) u32 {
        return @intCast(self.right - self.left);
    }

    pub fn height(self: Box) u32 {
        return @intCast(self.bottom - self.top);
    }
};

/// The box of samples to grow a glyph in: the box its samples were
/// drawn in, with room for the growth by `r` samples on every side,
/// out to whole pixels so that each pixel is the average of its own
/// samples.
pub fn sampleBox(drawn: Box, r: f64) Box {
    const pad: i32 = @intFromFloat(@ceil(@max(r, 0)));
    const s: i32 = @intCast(scale);
    return .{
        .left = @divFloor(drawn.left - pad, s) * s,
        .top = @divFloor(drawn.top - pad, s) * s,
        .right = @divCeil(drawn.right + pad, s) * s,
        .bottom = @divCeil(drawn.bottom + pad, s) * s,
    };
}

/// The pixels of a box of samples from `sampleBox`.
pub fn pixelBox(samples: Box) Box {
    const s: i32 = @intCast(scale);
    return .{
        .left = @divExact(samples.left, s),
        .top = @divExact(samples.top, s),
        .right = @divExact(samples.right, s),
        .bottom = @divExact(samples.bottom, s),
    };
}

/// Grow coverage by `r` samples: each sample becomes the most coverage
/// within that distance of it. A fraction of a sample is the blend of
/// the growths by the whole samples on either side of it, which moves
/// a straight edge by exactly `r`. The caller frees the result.
pub fn dilate(
    alloc: Allocator,
    src: []const u8,
    width: u32,
    height: u32,
    r: f64,
) Allocator.Error![]u8 {
    std.debug.assert(src.len == @as(usize, width) * height);
    const out = try alloc.alloc(u8, src.len);
    errdefer alloc.free(out);

    const clamped = @max(r, 0);
    const lo: u32 = @intFromFloat(@floor(clamped));
    const frac = clamped - @floor(clamped);
    const hi = if (frac > 0) lo + 1 else lo;

    for (0..height) |y| {
        for (0..width) |x| {
            const a: f64 = @floatFromInt(maxWithin(src, width, height, x, y, lo));
            const b: f64 = if (hi == lo) a else @floatFromInt(maxWithin(src, width, height, x, y, hi));
            out[y * width + x] = @intFromFloat(@round(a + (b - a) * frac));
        }
    }
    return out;
}

/// The most coverage within `r` whole samples of a sample: the digital
/// disc, the offsets within r * r + r, which is within half a sample of
/// the round one. Within r * r alone, the disc of 1 is a cross and the
/// corners of a glyph grew by next to nothing: 0.28 of a pixel's area
/// short on a hyphen at strength 255 (2026-11-18). Straight edges move
/// by `r` either way.
fn maxWithin(src: []const u8, width: u32, height: u32, x: usize, y: usize, r: u32) u8 {
    const ri: i64 = r;
    var best: u8 = 0;
    var dy: i64 = -ri;
    while (dy <= ri) : (dy += 1) {
        const sy = @as(i64, @intCast(y)) + dy;
        if (sy < 0 or sy >= height) continue;
        var dx: i64 = -ri;
        while (dx <= ri) : (dx += 1) {
            if (dx * dx + dy * dy > ri * ri + ri) continue;
            const sx = @as(i64, @intCast(x)) + dx;
            if (sx < 0 or sx >= width) continue;
            best = @max(best, src[@as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx))]);
        }
    }
    return best;
}

/// Average each pixel's `scale` by `scale` samples. The width and the
/// height are of the samples, whole pixels of them. The caller frees
/// the result.
pub fn downsample(
    alloc: Allocator,
    src: []const u8,
    width: u32,
    height: u32,
) Allocator.Error![]u8 {
    std.debug.assert(width % scale == 0 and height % scale == 0);
    std.debug.assert(src.len == @as(usize, width) * height);
    const w = width / scale;
    const h = height / scale;
    const out = try alloc.alloc(u8, @as(usize, w) * h);
    errdefer alloc.free(out);

    const n = scale * scale;
    for (0..h) |py| {
        for (0..w) |px| {
            var sum: u32 = 0;
            for (0..scale) |sy| {
                const row = (py * scale + sy) * width + px * scale;
                for (src[row..][0..scale]) |v| sum += v;
            }
            out[py * w + px] = @intCast((sum + n / 2) / n);
        }
    }
    return out;
}

const testing = std.testing;

/// Coverage of a vertical stem from `left` to `right` samples, in a
/// grid `width` samples wide and `height` high: what a rasterizer draws
/// of it, a fraction of a sample at each edge.
fn testStem(alloc: Allocator, width: u32, height: u32, left: f64, right: f64) ![]u8 {
    const out = try alloc.alloc(u8, @as(usize, width) * height);
    for (0..height) |y| {
        for (0..width) |x| {
            const x0: f64 = @floatFromInt(x);
            const covered = @max(@min(x0 + 1, right) - @max(x0, left), 0);
            out[y * width + x] = @intFromFloat(@round(covered * 255));
        }
    }
    return out;
}

/// The coverage of one row, in samples (255 is one).
fn testRow(data: []const u8, width: u32, y: usize) f64 {
    var sum: f64 = 0;
    for (data[y * width ..][0..width]) |v| sum += @floatFromInt(v);
    return sum / 255;
}

test "widening follows CoreText's measured factors and stops at 0.6" {
    // 16 pixels: 0.180 at 0 and 0.498 at 255, measured.
    try testing.expectApproxEqAbs(@as(f64, 0.184), widening(16, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.184), widening(16, 96), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.2656), widening(16, 128), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.344), widening(16, 192), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.424), widening(16, 224), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.5008), widening(16, 255), 0.001);
    // Halfway, or near it, along each ramp: interpolated, not stepped.
    try testing.expectApproxEqAbs(@as(f64, 0.2248), widening(16, 112), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.3048), widening(16, 160), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.384), widening(16, 208), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.4636), widening(16, 240), 0.001);
    // 48 pixels: 0.596 from 128 on, measured; 0.557 at 0.
    try testing.expectApproxEqAbs(@as(f64, 0.552), widening(48, 0), 0.001);
    try testing.expectEqual(@as(f64, 0.6), widening(48, 128));
    try testing.expectEqual(@as(f64, 0.6), widening(48, 255));
    try testing.expectEqual(@as(f64, 0), widening(0, 255));
    try testing.expectEqual(@as(f64, 0), widening(-3, 255));
}

test "widening never falls as the strength or the size rises" {
    // Flat up to 96, then rising at every strength: each has its own.
    // At 16 pixels, where the cap is never reached.
    var prev: f64 = 0;
    for (0..256) |s| {
        const w = widening(16, @intCast(s));
        if (s > 96) try testing.expect(w > prev) else try testing.expect(w >= prev);
        prev = w;
    }
    try testing.expect(widening(20, 255) > widening(20, 0));
    prev = 0;
    var px: f64 = 1;
    while (px <= 100) : (px += 0.5) {
        const w = widening(px, 200);
        try testing.expect(w >= prev);
        prev = w;
    }
}

test "the sample box makes room for the growth, out to whole pixels" {
    const box = sampleBox(.{ .left = -5, .top = 3, .right = 9, .bottom = 12 }, 1.2);
    try testing.expectEqual(Box{ .left = -8, .top = 0, .right = 12, .bottom = 16 }, box);
    try testing.expectEqual(Box{ .left = -2, .top = 0, .right = 3, .bottom = 4 }, pixelBox(box));

    // No growth: already whole pixels stay as they are.
    const whole = sampleBox(.{ .left = -4, .top = 0, .right = 8, .bottom = 4 }, 0);
    try testing.expectEqual(Box{ .left = -4, .top = 0, .right = 8, .bottom = 4 }, whole);
}

test "growing by nothing changes nothing" {
    const alloc = testing.allocator;
    const src = try testStem(alloc, 16, 4, 5.3, 9.6);
    defer alloc.free(src);
    const out = try dilate(alloc, src, 16, 4, 0);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, src, out);
}

test "a stem grows by the radius on each side, whole or a fraction" {
    const alloc = testing.allocator;
    const width = 32;
    const src = try testStem(alloc, width, 8, 11.3, 16.8);
    defer alloc.free(src);
    const before = testRow(src, width, 4);
    for ([_]f64{ 0.25, 0.5, 1, 1.2, 1.75, 2 }) |r| {
        const out = try dilate(alloc, src, width, 8, r);
        defer alloc.free(out);
        // Each byte is rounded, so a row may be off by half of one per
        // sample it changed at the two edges.
        try testing.expectApproxEqAbs(before + 2 * r, testRow(out, width, 4), 0.01);
    }
}

test "a box grows by the radius along its edges, its corners nearly round" {
    // A box with fractional edges, in samples. Grown by r, a rectangle
    // gains its edges' 2 * r * (w + h), and at its corners pi * r * r if
    // they are round. CoreText's corners measured from 1 to 4.4 of
    // r * r, too few pixels to tell round from square; these are round
    // to within 1.5 samples, a tenth of a pixel's area, where the cross
    // of r * r alone fell 3 short at a radius of 1.
    const alloc = testing.allocator;
    const width = 48;
    const height = 24;
    const left = 10.3;
    const right = 35.9;
    const top = 8.6;
    const bottom = 14.8;
    var src: [width * height]u8 = undefined;
    for (0..height) |y| for (0..width) |x| {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        const across = @max(@min(fx + 1, right) - @max(fx, left), 0);
        const down = @max(@min(fy + 1, bottom) - @max(fy, top), 0);
        src[y * width + x] = @intFromFloat(@round(across * down * 255));
    };
    var before: f64 = 0;
    for (src) |v| before += @floatFromInt(v);
    for ([_]f64{ 0.46, 1, 1.2, 2 }) |r| {
        const out = try dilate(alloc, &src, width, height, r);
        defer alloc.free(out);
        var after: f64 = 0;
        for (out) |v| after += @floatFromInt(v);
        const corners = (after - before) / 255 - 2 * r * ((right - left) + (bottom - top));
        errdefer std.debug.print("r={d}: corners {d:.2}, round {d:.2}\n", .{ r, corners, std.math.pi * r * r });
        try testing.expectApproxEqAbs(std.math.pi * r * r, corners, 1.5);
    }
}

test "downsampling keeps the coverage" {
    const alloc = testing.allocator;
    const width = 8 * scale;
    const height = 2 * scale;
    const src = try testStem(alloc, width, height, 6.3, 19.6);
    defer alloc.free(src);
    const out = try downsample(alloc, src, width, height);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 16), out.len);
    // 13.3 samples of 4 per pixel: 3.325 pixels in each row.
    try testing.expectApproxEqAbs(@as(f64, 3.325), testRow(out, 8, 0), 0.02);
    try testing.expectEqualSlices(u8, out[0..8], out[8..16]);
    // Pixel 2 holds samples 8..12, all covered. Pixel 1 has 1.7 of
    // its 4 columns, whose part sample is rounded first: 179 and 255.
    try testing.expectEqual(@as(u8, 255), out[2]);
    try testing.expectEqual(@as(u8, 109), out[1]);
}

test "a thickened stem gains what CoreText's does" {
    // The whole path short of DirectWrite: a stem drawn in samples,
    // grown by the radius for its font, and averaged to pixels gains
    // the widening, in pixels, in every row.
    const alloc = testing.allocator;
    const em_px = 20;
    const r = radius(em_px, 255);
    const drawn: Box = .{ .left = 37, .top = 0, .right = 46, .bottom = 16 };
    const box = sampleBox(drawn, r);
    const width = box.width();
    const height = box.height();
    const left: f64 = @floatFromInt(drawn.left - box.left);
    const src = try testStem(alloc, width, height, left + 0.6, left + 7.9);
    defer alloc.free(src);
    const grown = try dilate(alloc, src, width, height, r);
    defer alloc.free(grown);
    const plain = try downsample(alloc, src, width, height);
    defer alloc.free(plain);
    const thick = try downsample(alloc, grown, width, height);
    defer alloc.free(thick);
    const pw = pixelBox(box).width();
    try testing.expectApproxEqAbs(
        widening(em_px, 255),
        testRow(thick, pw, 1) - testRow(plain, pw, 1),
        0.02,
    );
}
