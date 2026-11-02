//! A terminal's resize overlay, as GTK shows the size of its grid while
//! its surface is resized (src/apprt/gtk/class/resize_overlay.zig, and
//! `resizeOverlaySchedule` in gtk/class/surface.zig): "{columns} x
//! {rows}" in a label over the terminal where `resize-overlay-position`
//! puts it, shown each time the terminal's size in pixels changes and
//! hidden `resize-overlay-duration` after the last change. With
//! `resize-overlay = never` it never shows. With `always`, as with
//! `after-first`, it does not show for the sizes a terminal takes in its
//! first 250 ms (`first_delay_ms`), as its window is laid out and shown:
//! GTK waits out its `first-delay` and macOS its `ready` whichever is
//! set, though the option's documentation says `always` shows them. The
//! duration is taken as it is, as macOS takes it; GTK refuses one under
//! its property's least, 250 ms, and keeps the one it had. GTK shows it
//! on an idle tick after the change, to keep its own layout from
//! flickering; this one shows inside the change, as the terminal's window
//! is sized.
//!
//! It is one of the terminal's overlays (Overlays.zig): a child window of
//! its frame, just above the child-exited banner and under the link
//! preview, as GTK stacks them (surface.blp), which every layout places,
//! hidden with its terminal and following it to a new frame; the pointer
//! and clicks over it go to the terminal under it. Its window is made the
//! first time it shows, and again at the next change if it could not be.

const std = @import("std");
const builtin = @import("builtin");

const configpkg = @import("../../config.zig");
const renderer = @import("../../renderer.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");

const RECT = win32.RECT;
const L = win32.L;
const Size = Overlays.Size;
const Position = configpkg.Config.ResizeOverlayPosition;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyResizeOverlayClass";

/// The WM_TIMER on the terminal's window that hides the overlay (`timer`),
/// beside its `progress_timer_id` and `DesktopNotifications.timer_id`.
pub const timer_id: win32.UINT_PTR = 3;

/// How long after its terminal is made the overlay does not show: GTK's
/// `first-delay` (resize-overlay.blp).
pub const first_delay_ms: u64 = 250;

/// The longest text the overlay shows, a grid as wide and tall as the
/// core's sizes go.
const max_text = std.fmt.count("{d} x {d}", .{ std.math.maxInt(renderer.GridSize.Unit), std.math.maxInt(renderer.GridSize.Unit) });

/// For tests: the time the overlay is driven with (`now`), in place of
/// GetTickCount64's.
pub var test_now: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {};

/// The time in milliseconds the first delay and the duration are measured
/// with.
fn now() u64 {
    if (builtin.is_test) if (test_now) |t| return t;
    return win32.GetTickCount64();
}

/// For tests: SetTimer failing (`startTimer`), as it does when the
/// process has used up its timers.
pub var test_timer_fails: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// Start, or start again, the timer that hides `surface`'s overlay, to
/// fire in `ms` (at least USER_TIMER_MINIMUM); false if it cannot be.
fn startTimer(surface: *Surface, ms: u32) bool {
    if (builtin.is_test) if (test_timer_fails) return false;
    return win32.SetTimer(surface.hwnd, timer_id, @max(ms, win32.USER_TIMER_MINIMUM), null) != 0;
}

/// A terminal's overlay (`Overlays.resize_overlay`).
pub const Overlay = struct {
    /// Its window, a child of the terminal's frame, made the first time it
    /// shows; null until then, if it could not be made, and once it is
    /// destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// What it shows, in `buf`; null once its timer or a failure has
    /// hidden it, kept while its terminal is hidden. The overlay is never
    /// moved, being in its terminal's `Surface`, whose address the core
    /// keeps.
    text: ?[:0]const u16 = null,
    buf: [max_text:0]u16 = undefined,
    /// The size of `text` in the overlays' font; measured again when
    /// either changes.
    text_size: Size = .{ .width = 0, .height = 0 },
    measured: bool = false,
    /// Where it goes, `resize-overlay-position` as it last showed.
    position: Position = .center,
    /// Before when, in `now`'s milliseconds, it does not show: the end of
    /// its terminal's first delay (`start`). Never before that is set: the
    /// terminal's window is sized as it is made, before its core is.
    ready_at: u64 = std.math.maxInt(u64),
    /// When it hides, in `now`'s milliseconds, `resize-overlay-duration`
    /// after it last showed.
    hides_at: u64 = 0,

    /// Nothing is owned: the text is in `buf`.
    pub fn deinit(self: *Overlay, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.text = null;
    }

    /// Show `text`, which its window draws and is named; the same text
    /// again changes nothing.
    fn setText(self: *Overlay, text: []const u16) void {
        if (self.text) |old| if (std.mem.eql(u16, old, text)) return;
        @memcpy(self.buf[0..text.len], text);
        self.buf[text.len] = 0;
        self.text = self.buf[0..text.len :0];
        self.measured = false;
        const hwnd = self.hwnd orelse return;
        // Its name, for what reads windows' text, as screen readers do.
        _ = win32.SetWindowTextW(hwnd, self.buf[0..text.len :0].ptr);
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
    }

    /// Hide it, until it shows again; its place in the stack is kept.
    fn hide(self: *Overlay) void {
        self.text = null;
        if (self.hwnd) |hwnd| _ = win32.SetWindowTextW(hwnd, L(""));
        Overlays.hideWindow(self.hwnd);
    }

    /// Where the overlay goes over a terminal `pane` big at `dpi`, in the
    /// terminal's client coordinates (`rectIn`), for `Overlays.place`.
    pub fn placeIn(self: *const Overlay, dpi: u32, pane: Size) ?Overlays.Placed {
        const in = rectIn(.init(dpi), pane, self.text_size, self.position) orelse return null;
        return .{ .in = in, .redraw = false };
    }

    /// Where the text goes in the overlay at `dpi`: inside its padding,
    /// which centres it; cut at the right in one narrower than the text.
    pub fn textIn(self: *const Overlay, dpi: u32, width: i32) RECT {
        _ = width;
        const m = Metrics.init(dpi);
        return .{ .left = m.pad_x, .top = m.pad_y, .right = m.pad_x + self.text_size.width, .bottom = m.pad_y + self.text_size.height };
    }
};

/// `surface` was made (`Surface.create`): its overlay does not show for
/// the sizes its window takes in the next `first_delay_ms`.
pub fn start(surface: *Surface) void {
    surface.overlays.resize_overlay.ready_at = now() + first_delay_ms;
}

/// `surface`'s size in pixels changed, which made its core's grid `grid`
/// (`Surface.resize`): the overlay shows the grid where
/// `resize-overlay-position` puts it until `resize-overlay-duration` has
/// passed with no other change, its window made first if it has none.
/// Nothing with `resize-overlay = never`, nor in the terminal's first
/// delay (`start`). If its window cannot be made, or its timer cannot be
/// started, which would leave it shown, it does not show.
pub fn resized(surface: *Surface, grid: renderer.GridSize) void {
    const self = &surface.overlays.resize_overlay;
    const config = &surface.app.config;
    switch (config.@"resize-overlay") {
        .always, .@"after-first" => {},
        .never => return,
    }
    const t = now();
    if (t < self.ready_at) return;

    if (self.hwnd == null) {
        // A text kept from a window since destroyed: named and drawn
        // again in the new one.
        self.text = null;
        self.hwnd = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a resize overlay err={}", .{win32.GetLastError()});
            return;
        };
    }
    const ms = config.@"resize-overlay-duration".asMilliseconds();
    // Replaces the timer an earlier change started.
    if (!startTimer(surface, ms)) {
        log.warn("cannot start the resize overlay's timer err={}", .{win32.GetLastError()});
        self.hide();
        return;
    }
    self.hides_at = t + ms;

    var buf: [max_text]u16 = undefined;
    self.setText(textOf(&buf, grid));
    // A new position moves it, which `place` draws again.
    self.position = config.@"resize-overlay-position";
    Overlays.place(surface);
}

/// The overlay's timer on `surface` fired: it hides once its duration has
/// passed since the last change. A WM_TIMER already due as a change
/// started the timer again can come early, and the timer is started again
/// for the rest; if it cannot be, the overlay hides now.
pub fn timer(surface: *Surface) void {
    const self = &surface.overlays.resize_overlay;
    const t = now();
    if (self.text != null and t < self.hides_at) {
        const rest = @min(self.hides_at - t, std.math.maxInt(u32));
        if (startTimer(surface, @intCast(rest))) return;
        log.warn("cannot start the resize overlay's timer again err={}", .{win32.GetLastError()});
    }
    _ = win32.KillTimer(surface.hwnd, timer_id);
    self.hide();
}

/// What the overlay shows for `grid`, as GTK's label shows it, in `buf`.
pub fn textOf(buf: *[max_text]u16, grid: renderer.GridSize) []const u16 {
    var utf8: [max_text]u8 = undefined;
    // `max_text` holds the longest.
    const s = std.fmt.bufPrint(&utf8, "{d} x {d}", .{ grid.columns, grid.rows }) catch unreachable;
    for (s, buf[0..s.len]) |c, *w| w.* = c;
    return buf[0..s.len];
}

/// The overlay's sizes at a DPI, from GTK's at 96 (`.resize-overlay` in
/// src/apprt/gtk/css/style.css: padding 4px 8px). GTK's rounded corners
/// are left out, as the link preview leaves out its own.
pub const Metrics = struct {
    /// Between the text and the overlay's left and right edges.
    pad_x: i32,
    /// Between the text and its top and bottom edges.
    pad_y: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .pad_x = SearchBar.Metrics.scale(8, dpi),
            .pad_y = SearchBar.Metrics.scale(4, dpi),
        };
    }
};

/// How the overlay lines up along one side of its terminal: GTK's
/// `gtk.Align` for `overlay-halign` and `overlay-valign`.
const Align = enum { start, center, end };

/// `position` as GTK's surface sets the overlay's alignments
/// (`propConfig` in gtk/class/surface.zig), across and down.
fn alignOf(position: Position) [2]Align {
    return switch (position) {
        .center => .{ .center, .center },
        .@"top-left" => .{ .start, .start },
        .@"top-center" => .{ .center, .start },
        .@"top-right" => .{ .end, .start },
        .@"bottom-left" => .{ .start, .end },
        .@"bottom-center" => .{ .center, .end },
        .@"bottom-right" => .{ .end, .end },
    };
}

/// Where along `room` something `size` long starts, lined up by `a`; the
/// extra pixel of an odd remainder after it, as GTK centres.
fn offset(a: Align, room: i32, size: i32) i32 {
    return switch (a) {
        .start => 0,
        .center => @divTrunc(room - size, 2),
        .end => room - size,
    };
}

/// Where an overlay of text `text` big goes over a terminal `pane` big, in
/// the terminal's client coordinates: lined up with its edges or centres
/// as `position` says, with no margin, as GTK's label has none, as wide
/// and tall as the text with its padding but no wider or taller than the
/// terminal; null for a terminal with no area.
pub fn rectIn(m: Metrics, pane: Size, text: Size, position: Position) ?RECT {
    if (pane.width <= 0 or pane.height <= 0) return null;
    const width = @min(@max(0, text.width) + 2 * m.pad_x, pane.width);
    const height = @min(@max(0, text.height) + 2 * m.pad_y, pane.height);
    const a = alignOf(position);
    const left = offset(a[0], pane.width, width);
    const top = offset(a[1], pane.height, height);
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
}

test "win32: the resize overlay shows the grid's columns by its rows, as GTK writes them" {
    const testing = std.testing;
    var buf: [max_text]u16 = undefined;
    const cases = [_]struct { grid: renderer.GridSize, text: []const u8 }{
        .{ .grid = .{ .columns = 80, .rows = 24 }, .text = "80 x 24" },
        .{ .grid = .{ .columns = 1, .rows = 1 }, .text = "1 x 1" },
        .{ .grid = .{ .columns = 0, .rows = 0 }, .text = "0 x 0" },
        .{ .grid = .{ .columns = std.math.maxInt(renderer.GridSize.Unit), .rows = std.math.maxInt(renderer.GridSize.Unit) }, .text = "65535 x 65535" },
    };
    for (cases) |c| {
        var utf8: [max_text]u8 = undefined;
        const wide = textOf(&buf, c.grid);
        for (wide, 0..) |w, i| utf8[i] = @intCast(w);
        try testing.expectEqualStrings(c.text, utf8[0..wide.len]);
    }
}

test "win32: the resize overlay lines up with its terminal's edges or centres as its position says" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(8, m.pad_x);
    try testing.expectEqual(4, m.pad_y);
    const big = Metrics.init(144);
    try testing.expectEqual(12, big.pad_x);
    try testing.expectEqual(6, big.pad_y);

    const pane: Size = .{ .width = 801, .height = 601 };
    const text: Size = .{ .width = 100, .height = 16 };
    // 116 by 24 with its padding; an odd remainder's extra pixel after it.
    const cases = [_]struct { position: Position, rect: RECT }{
        .{ .position = .center, .rect = .{ .left = 342, .top = 288, .right = 458, .bottom = 312 } },
        .{ .position = .@"top-left", .rect = .{ .left = 0, .top = 0, .right = 116, .bottom = 24 } },
        .{ .position = .@"top-center", .rect = .{ .left = 342, .top = 0, .right = 458, .bottom = 24 } },
        .{ .position = .@"top-right", .rect = .{ .left = 685, .top = 0, .right = 801, .bottom = 24 } },
        .{ .position = .@"bottom-left", .rect = .{ .left = 0, .top = 577, .right = 116, .bottom = 601 } },
        .{ .position = .@"bottom-center", .rect = .{ .left = 342, .top = 577, .right = 458, .bottom = 601 } },
        .{ .position = .@"bottom-right", .rect = .{ .left = 685, .top = 577, .right = 801, .bottom = 601 } },
    };
    for (cases) |c| try testing.expectEqual(c.rect, rectIn(m, pane, text, c.position).?);

    // Smaller than its text: as big as the terminal.
    try testing.expectEqual(RECT{ .left = 0, .top = 0, .right = 50, .bottom = 10 }, rectIn(m, .{ .width = 50, .height = 10 }, text, .center).?);
    try testing.expectEqual(RECT{ .left = 0, .top = 0, .right = 50, .bottom = 10 }, rectIn(m, .{ .width = 50, .height = 10 }, text, .@"bottom-right").?);
    // No area: nowhere.
    try testing.expect(rectIn(m, .{ .width = 0, .height = 600 }, text, .center) == null);
    try testing.expect(rectIn(m, .{ .width = 800, .height = 0 }, text, .center) == null);
}
