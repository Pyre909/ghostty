//! A terminal's progress bar: a thin bar across the top of the terminal
//! while its program reports progress (OSC 9;4, `progress-style`), as GTK
//! shows one over its surface (the `osd` ProgressBar at
//! src/apprt/gtk/ui/1.0/surface.blp:113, along the top) and macOS
//! (`SurfaceProgressBar`, macos/Sources/Ghostty/Surface
//! View/SurfaceProgressBar.swift). It is drawn as macOS draws it, which
//! says what it looks like where GTK leaves it to the theme: 2 points
//! high; filled from the left to its value in the accent colour, red for
//! an error and orange while paused; and with no value, a block a quarter
//! as wide going from one side to the other and back, 1.2 seconds each
//! way, eased in and out, over a track of its colour at 30%. macOS also
//! eases a new value in over 0.2 seconds; this one shows it at once.
//!
//! Every terminal shows its own, as on GTK and macOS; the window's
//! taskbar button shows its focused terminal's as well (taskbar.zig).
//!
//! It is one of the terminal's overlays (Overlays.zig), just above the
//! read-only badge, under the bell border, as GTK stacks it. An overlay is
//! opaque, so its window covers only what is filled, and the track is
//! drawn over the terminal's background (`Overlays.terminalBackground`);
//! the pointer and clicks over it go to the terminal, as macOS's takes
//! none. The window is made the first time the terminal reports progress
//! (`set`).

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const taskbar = @import("taskbar.zig");

const RECT = win32.RECT;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyProgressBarClass";

/// The WM_TIMER on the terminal's window that moves the bar's block
/// (`timer`), beside its `progress_timer_id`,
/// `DesktopNotifications.timer_id` and `ResizeOverlay.timer_id`.
pub const timer_id: win32.UINT_PTR = 4;

/// How often the block moves: about 30 times a second, smooth enough for
/// a bar 2 points high, at a cost a stalled program's bar does not notice.
const frame_ms: win32.UINT = 33;

/// How long the block takes from one side to the other, macOS's 1.2
/// seconds.
pub const sweep_ms: u64 = 1200;

/// macOS's system red and orange (NSColor.systemRed, systemOrange), in
/// their light appearance.
pub const red = win32.rgb(255, 59, 48);
pub const orange = win32.rgb(255, 149, 0);

/// For tests: the time the block is drawn at (`now`), in place of
/// GetTickCount64's.
pub var test_now: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {};

/// For tests: the accent colour (`accent`), in place of the system's.
pub var test_accent: if (builtin.is_test) ?win32.COLORREF else void = if (builtin.is_test) null else {};

fn now() u64 {
    if (builtin.is_test) if (test_now) |t| return t;
    return win32.GetTickCount64();
}

/// The system's accent colour, as the command palette and the tab
/// overview take it.
fn accent() win32.COLORREF {
    if (builtin.is_test) if (test_accent) |c| return c;
    return win32.GetSysColor(win32.COLOR_HIGHLIGHT);
}

/// A terminal's bar (`Overlays.progress_bar`).
pub const Bar = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// the terminal reports progress; null until then, if it could not
    /// be made, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The terminal's progress, as `set` last took it.
    progress: taskbar.Progress = .{},
    /// When the block set out from the left, in `now`'s milliseconds.
    started: u64 = 0,

    pub fn deinit(self: *Bar, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.progress = .{};
    }

    /// For `Overlays.place`: it has no text to show it.
    pub fn shows(self: *const Bar) bool {
        return self.progress.state != .none;
    }

    /// Whether it shows a moving block, not a value: progress of no known
    /// amount, or an error with none, as macOS shows each.
    pub fn moves(self: *const Bar) bool {
        return switch (self.progress.state) {
            .indeterminate => true,
            .@"error" => self.progress.value == null,
            .none, .normal, .paused => false,
        };
    }

    /// The top of the terminal, as far across as it is filled, for
    /// `Overlays.place`; none while nothing is filled.
    pub fn placeIn(self: *const Bar, dpi: u32, pane: Size) ?Overlays.Placed {
        const right = if (self.moves()) pane.width else filledWidth(pane.width, self.progress.shownValue());
        const bottom = @min(height(dpi), pane.height);
        if (right <= 0 or bottom <= 0) return null;
        return .{ .in = .{ .left = 0, .top = 0, .right = right, .bottom = bottom }, .redraw = false };
    }

    /// The bar's colour, by its state.
    pub fn color(self: *const Bar) win32.COLORREF {
        return switch (self.progress.state) {
            .@"error" => red,
            .paused => orange,
            .none, .normal, .indeterminate => accent(),
        };
    }

    /// Filled in its colour; or, while it moves, its track over
    /// `background` with the block where it is now.
    pub fn draw(self: *const Bar, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, background: win32.COLORREF, font: ?win32.HGDIOBJ) void {
        _ = dpi;
        _ = dark;
        _ = font;
        const c = self.color();
        if (!self.moves()) return SearchBar.fill(hdc, client, c);
        SearchBar.fill(hdc, client, win32.lerp(background, c, 300));
        SearchBar.fill(hdc, blockIn(client, now() -% self.started), c);
    }

    /// Its window `hwnd` shows or hides: the block moves only while it
    /// shows (`timer`), and moves again once it shows again, as from a
    /// hidden tab.
    pub fn handle(self: *Bar, surface: *Surface, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
        _ = hwnd;
        _ = wparam;
        if (msg == win32.WM_WINDOWPOSCHANGED) {
            const pos: *const win32.WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (pos.flags & win32.SWP_SHOWWINDOW != 0 and self.moves()) startTimer(surface);
        }
        return null;
    }
};

/// The bar's height at `dpi`: macOS's 2 points, at least a pixel.
pub fn height(dpi: u32) i32 {
    return @max(1, SearchBar.Metrics.scale(2, dpi));
}

/// How much of `width` a bar filled to `value` out of 100 covers.
pub fn filledWidth(width: i32, value: u8) i32 {
    if (width <= 0) return 0;
    return @intCast(@divTrunc(@as(i64, width) * @min(value, 100), 100));
}

/// Where the block is in `client`, `elapsed` milliseconds after it set
/// out from the left: a quarter as wide, `sweep_ms` to the right side,
/// as long back, eased in and out each way (smoothstep, close to the
/// ease-in-out curve macOS animates it with).
pub fn blockIn(client: RECT, elapsed: u64) RECT {
    const width = client.right - client.left;
    const block = @max(1, @divTrunc(width, 4));
    const room: i64 = @max(0, width - block);
    const t = elapsed % (2 * sweep_ms);
    // How far across, in thousandths, then eased.
    const across: i64 = @intCast(if (t <= sweep_ms) t * 1000 / sweep_ms else (2 * sweep_ms - t) * 1000 / sweep_ms);
    const eased = @divTrunc(across * across * (3000 - 2 * across), 1000 * 1000);
    const left = client.left + @as(i32, @intCast(@divTrunc(room * eased, 1000)));
    return .{ .left = left, .top = client.top, .right = left + block, .bottom = client.bottom };
}

/// Start, or start again, the timer that moves `surface`'s block. One
/// that cannot be started is logged: the bar shows, its block still.
fn startTimer(surface: *Surface) void {
    if (win32.SetTimer(surface.hwnd, timer_id, frame_ms, null) == 0) {
        log.warn("cannot start the progress bar's timer err={}", .{win32.GetLastError()});
    }
}

/// The block's timer on `surface` fired: it is drawn where it is now,
/// while it moves and shows; otherwise the timer stops until it shows
/// moving again (`set`, `Bar.handle`).
pub fn timer(surface: *Surface) void {
    const self = &surface.overlays.progress_bar;
    if (self.hwnd) |hwnd| if (self.moves() and SearchBar.visibleStyle(hwnd)) {
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
        return;
    };
    _ = win32.KillTimer(surface.hwnd, timer_id);
}

/// Show `surface`'s progress (`Surface.progress`) on its bar, its window
/// made first if it has none, or hide it. A window that cannot be made is
/// logged, and tried again at the terminal's next report; a removal with
/// none makes none.
pub fn set(surface: *Surface) void {
    const self = &surface.overlays.progress_bar;
    const moved = self.moves();
    self.progress = surface.progress;
    if (self.moves()) {
        if (!moved) self.started = now();
        startTimer(surface);
    } else {
        _ = win32.KillTimer(surface.hwnd, timer_id);
    }
    if (self.hwnd == null) {
        if (!self.shows()) return;
        self.hwnd = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a progress bar err={}", .{win32.GetLastError()});
            return;
        };
    }
    Overlays.place(surface);
    // Its colour may change where it stays.
    if (self.hwnd) |hwnd| _ = win32.InvalidateRect(hwnd, null, .FALSE);
}

test "win32: the progress bar is macOS's height, filled to its value" {
    const testing = std.testing;
    try testing.expectEqual(2, height(96));
    try testing.expectEqual(3, height(144));
    try testing.expectEqual(4, height(192));
    try testing.expectEqual(0, filledWidth(800, 0));
    try testing.expectEqual(320, filledWidth(800, 40));
    try testing.expectEqual(800, filledWidth(800, 100));
    try testing.expectEqual(800, filledWidth(800, 255));
    try testing.expectEqual(0, filledWidth(0, 50));
    // Rounded down: never filled further than it has got.
    try testing.expectEqual(6, filledWidth(13, 50));
}

test "win32: the progress bar's block goes across and back, eased" {
    const testing = std.testing;
    const client: RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 2 };
    // At the left, a quarter wide; at the right after a sweep; back
    // after two; halfway at half a sweep each way.
    try testing.expectEqual(RECT{ .left = 0, .top = 0, .right = 200, .bottom = 2 }, blockIn(client, 0));
    try testing.expectEqual(@as(i32, 600), blockIn(client, sweep_ms).left);
    try testing.expectEqual(@as(i32, 0), blockIn(client, 2 * sweep_ms).left);
    try testing.expectEqual(@as(i32, 300), blockIn(client, sweep_ms / 2).left);
    try testing.expectEqual(@as(i32, 300), blockIn(client, sweep_ms + sweep_ms / 2).left);
    // Eased: slower near the sides than in the middle.
    const near_side = blockIn(client, sweep_ms / 10).left;
    const near_middle = blockIn(client, sweep_ms / 2 + sweep_ms / 10).left - 300;
    try testing.expect(near_side < near_middle);
    // The same way back as out.
    try testing.expectEqual(blockIn(client, 100).left, blockIn(client, 2 * sweep_ms - 100).left);
    // Too narrow to move: a pixel at the left.
    const tiny: RECT = .{ .left = 0, .top = 0, .right = 1, .bottom = 2 };
    try testing.expectEqual(tiny, blockIn(tiny, sweep_ms / 2));
}
