//! A terminal's scroll bar: the window's own vertical scroll bar
//! (WS_VSCROLL), rather than GTK's overlay scrollbar, which floats over
//! its surface and takes none of its width
//! (src/apprt/gtk/class/surface_scrolled_window.zig). With
//! `scrollbar = system` every terminal's window has it, and with `never`
//! none does (`style`).
//!
//! It shows the core's rows (`.scrollbar`: the scrollback's total, the
//! viewport's offset into it and its length), set with SetScrollInfo and
//! SIF_DISABLENOSCROLL (`update`): a bar with nothing to scroll is
//! disabled rather than removed, so that it never comes or goes, which
//! would change the grid's width and reflow the text. An update that
//! changes nothing is skipped, as GTK skips one, and while the thumb is
//! dragged its position is left alone, as macOS leaves it: the system
//! draws the thumb where the pointer holds it, and when the drag ends the
//! bar takes the row the drag last moved the viewport to, until the core
//! reports it (`State.asked`), or the core's position. Past `i32` rows the
//! range saturates (`infoFor`).
//!
//! What the user does on it, WM_VSCROLL, moves the viewport through the
//! core's `scroll_to_row`, as GTK's adjustment does, to a row worked out
//! from the core's rows (`rowFor`), the last row for the thumb at the
//! bar's end in a drag, and only when that row is another, as macOS asks
//! for it. The last row is asked for past the core's last (`bottom_row`),
//! as the bar's rows can be behind the core's (`scrolled`).
//!
//! A press on the bar, its thumb, track or an arrow, runs a modal loop
//! inside the terminal's DefWindowProcW until the button comes up; and a
//! right click on it shows the system's menu for it (Scroll Here, Top,
//! Bottom, Page Up and Down, Scroll Up and Down), owned by the terminal,
//! inside the same DefWindowProcW, which sends the choice as WM_VSCROLL
//! (`loop`). Neither tells the frame, as a size, move or menu loop of its
//! own does (WM_ENTERSIZEMOVE, WM_ENTERMENULOOP), so the loop counts
//! itself: the app keeps ticking, and no teardown frees the terminal under
//! its handler (`App.beginTerminalLoop`). The menu is kept, under the same
//! count, as every window's own scroll bar has it.
//!
//! In a dark frame it takes the "DarkMode_Explorer" theme class, as the
//! command palette's list does (`applyTheme`). A configuration that
//! changes `scrollbar` gives the terminals their bar, or takes it away,
//! from `App.run` (`restyle`): the client area changes with it, and so
//! does the core's grid.

const std = @import("std");
const builtin = @import("builtin");

const configpkg = @import("../../config.zig");
const terminal = @import("../../terminal/main.zig");
const win32 = @import("win32.zig");
const L = win32.L;
const Surface = @import("Surface.zig").Surface;
const SearchBar = @import("SearchBar.zig");

const log = std.log.scoped(.win32);

/// A terminal's scroll bar (`Surface.scroll_bar`).
pub const State = struct {
    /// The window has the bar (WS_VSCROLL): made with it (`made`) or given
    /// it (`restyle`), the only places its style changes.
    on: bool = false,

    /// The core's last `.scrollbar` (`update`), kept without a bar too, for
    /// one the terminal is given later.
    rows: terminal.Scrollbar = .zero,

    /// What SetScrollInfo was last given (`apply`), to skip an update that
    /// changes nothing; null before the first, after a restyle, and at the
    /// end of a drag (`endDrag`).
    set: ?Info = null,

    /// The thumb is being dragged: from an SB_THUMBTRACK inside one of the
    /// bar's loops (`in_loop`), which Windows sends at the press on the
    /// thumb and at each place it moves to, until SB_ENDSCROLL, the end of
    /// that loop, or a restyle (`restyle`). Outside a loop an
    /// SB_THUMBTRACK, which only another program sends, is a single move
    /// and starts no drag: no loop's end would end one that no
    /// SB_ENDSCROLL does.
    ///
    /// It holds the thumb's last place in the bar's range at that first
    /// SB_THUMBTRACK (`lastPlace`): Windows works the thumb's places out
    /// from the range it takes there for the whole drag, whatever range the
    /// bar is given meanwhile, so that place is the bar's end however far
    /// the output has moved the bottom on since (`scrolled`).
    tracking: ?i32 = null,

    /// The bar's loop that runs in the terminal's DefWindowProcW (`loop`),
    /// null outside one.
    in_loop: ?Loop = null,

    /// The row the viewport was last asked to go to (`scrolled`), which
    /// the core has not reported back: a step up or down starts from it.
    /// For the bar's last row it is that row, the core being asked past it
    /// (`bottom_row`). Cleared by every `.scrollbar`.
    asked: ?usize = null,

    /// The bar was last given the dark theme (`applyTheme`); a new window's
    /// is the system's light one.
    dark: bool = false,

    /// The `.scrollbar` updates so far, wrapping, which the end of the
    /// bar's loop logs the number of (`loop`).
    updates: u32 = 0,
};

/// Which of the bar's loops runs (`State.in_loop`).
pub const Loop = enum {
    /// A press on the bar, its thumb, track or an arrow, until the button
    /// comes up (WM_SYSCOMMAND).
    press,
    /// The system's menu for the bar, until it closes (WM_CONTEXTMENU).
    menu,
};

/// What the bar is given (`infoFor`): the range from 0 to `max`, the page
/// and the position.
pub const Info = struct { max: i32, page: u32, pos: i32 };

/// The most SetScrollInfo takes: its values are `int`s, and the range may
/// not be larger than MAXLONG (SetScrollRange).
const max_rows: usize = std.math.maxInt(i32);

/// The bar for `rows`: from row 0 to the last, a page of `len` rows, at
/// `offset`. Each value saturates at `max_rows` rather than wrapping, so
/// that past it the thumb's positions run from 0 to `max_rows - len + 1`
/// (nMax - nPage + 1), and the arrows and the track reach the rest
/// (`rowFor`). An empty scrollback keeps one row, and the page at least
/// one, so that the bar is disabled (SIF_DISABLENOSCROLL) rather than
/// given an empty range.
pub fn infoFor(rows: terminal.Scrollbar) Info {
    return .{
        .max = @intCast(@min(@max(rows.total, 1) - 1, max_rows)),
        .page = @intCast(std.math.clamp(rows.len, 1, max_rows)),
        .pos = @intCast(@min(rows.offset, max_rows)),
    };
}

/// The thumb's last place in `info`'s range: nMax - nPage + 1, the largest
/// position Windows keeps (SetScrollInfo), and 0 when the page holds the
/// whole range.
fn lastPlace(info: Info) i32 {
    return @max(0, info.max - @as(i32, @intCast(info.page)) + 1);
}

/// The row asked of the core for every step to the bar's last row
/// (`lastRow`, `scrolled`): the menu's Bottom, a line or a page down that
/// reaches it or stops there, and the thumb there or at the bar's end in a
/// drag. It is past every row the core can have, which it takes as its
/// last, its active area, and follows the output from
/// (src/terminal/PageList.zig:3337). The bar's own last row can be behind
/// the core's when it is asked: the rows come from the core's tick while
/// the output goes on, and asked for, a row short of its last would pin
/// the viewport there.
pub const bottom_row: usize = std.math.maxInt(usize);

/// The last row the viewport can start at in `rows`, `total - len`, 0 when
/// the screen holds them all: the bar's last row.
fn lastRow(rows: terminal.Scrollbar) usize {
    return rows.total -| rows.len;
}

/// The row WM_VSCROLL's request `code` moves the viewport's top to from
/// `from`, the row it is at, in `rows`: one up or down (SB_LINEUP,
/// SB_LINEDOWN), a screen up or down (SB_PAGEUP, SB_PAGEDOWN, as GTK's
/// page increment is the page), the first or the last row (SB_TOP,
/// SB_BOTTOM), or `thumb`, where the thumb is (SB_THUMBTRACK,
/// SB_THUMBPOSITION); kept from 0 to the last row the viewport can start
/// at (`lastRow`). Null for SB_ENDSCROLL and any other request, and for a
/// thumb whose place Windows did not give.
pub fn rowFor(code: u16, rows: terminal.Scrollbar, from: usize, thumb: ?i32) ?usize {
    const last = lastRow(rows);
    const row: usize = switch (code) {
        win32.SB_LINEUP => from -| 1,
        win32.SB_LINEDOWN => from +| 1,
        win32.SB_PAGEUP => from -| rows.len,
        win32.SB_PAGEDOWN => from +| rows.len,
        win32.SB_TOP => 0,
        win32.SB_BOTTOM => last,
        win32.SB_THUMBTRACK, win32.SB_THUMBPOSITION => @intCast(@max(0, thumb orelse return null)),
        else => return null,
    };
    return @min(row, last);
}

/// The style bit a terminal's window is made with for `config`: the bar
/// with `scrollbar = system`.
pub fn style(config: *const configpkg.Config) win32.DWORD {
    return switch (config.scrollbar) {
        .system => win32.WS_VSCROLL,
        .never => 0,
    };
}

/// `surface`'s window was just made, with `style`'s bit or not: a bar is
/// disabled until the core's first rows come (`update`), rather than at
/// the range of 0 to 100 a new bar has, and takes its frame's theme
/// (`applyTheme`).
pub fn made(surface: *Surface) void {
    const bit: isize = win32.WS_VSCROLL;
    surface.scroll_bar.on = win32.GetWindowLongPtrW(surface.hwnd, win32.GWL_STYLE) & bit != 0;
    if (surface.scroll_bar.on) apply(surface);
    applyTheme(surface);
}

/// The bar's width in pixels, 0 without one: SM_CXVSCROLL at the window's
/// DPI, the width Windows gives a window's own scroll bar
/// (AdjustWindowRectEx leaves scroll bars out, and says to add it). The
/// grid is laid out in what the bar leaves of the window
/// (`Surface.getSize`), so what sizes a window for a grid adds it across.
pub fn width(surface: *const Surface) i32 {
    if (!surface.scroll_bar.on) return 0;
    const hwnd = surface.hwnd;
    if (surface.app.bar_metric) |m| {
        const dpi = m.dpi_of(hwnd);
        if (dpi != 0) return m.metric_for(win32.SM_CXVSCROLL, dpi);
    }
    return win32.GetSystemMetrics(win32.SM_CXVSCROLL);
}

/// How `width` reads SM_CXVSCROLL at a window's DPI, as Windows sizes the
/// bar it draws: GetDpiForWindow and GetSystemMetricsForDpi, which exist
/// from Windows 10 1607 and are looked up once (`App.bar_metric`); without
/// them, GetSystemMetrics', at the system DPI, the only one before them.
/// Its own GetDpiForWindow, not the one the app lays out with
/// (`App.get_dpi_for_window`, `Window.dpiOf`), which a test may stand in
/// for: the bar is drawn at the window's real DPI.
pub const Metric = struct {
    dpi_of: win32.GetDpiForWindowFn,
    metric_for: win32.GetSystemMetricsForDpiFn,

    /// Both from `user32`, or null if either is missing.
    pub fn resolve(user32: ?win32.HMODULE) ?Metric {
        const m = user32 orelse return null;
        const dpi_of = win32.GetProcAddress(m, "GetDpiForWindow") orelse return null;
        const metric_for = win32.GetProcAddress(m, "GetSystemMetricsForDpi") orelse return null;
        return .{ .dpi_of = @ptrCast(@alignCast(dpi_of)), .metric_for = @ptrCast(@alignCast(metric_for)) };
    }
};

/// `.scrollbar`: the core's rows for `surface`'s bar (`apply`); false, the
/// action not carried out, while the terminal has no bar
/// (`scrollbar = never`). The rows are kept either way, for a bar the
/// terminal is given later (`restyle`), and a step up or down starts from
/// them again (`asked`). It comes from the core's tick, inside its frame:
/// SetScrollInfo with SIF_DISABLENOSCROLL never shows or hides the bar, so
/// the client area keeps its size and no WM_SIZE enters the core.
pub fn update(surface: *Surface, rows: terminal.Scrollbar) bool {
    const s = &surface.scroll_bar;
    s.rows = rows;
    s.asked = null;
    s.updates +%= 1;
    if (!s.on) return false;
    apply(surface);
    return true;
}

/// For tests: how many times `apply` called SetScrollInfo.
pub var test_sets: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

/// Give `surface`'s bar its rows (`infoFor`), unless it has them: the range
/// and the page, and the position unless the thumb is being dragged, at
/// the row the viewport was last asked to go to while the core has not
/// reported it (`asked`), as at the end of a drag released before the core
/// caught up, else at the core's.
fn apply(surface: *Surface) void {
    const s = &surface.scroll_bar;
    var rows = s.rows;
    rows.offset = s.asked orelse rows.offset;
    const want = infoFor(rows);
    if (s.set) |had| {
        if (had.max == want.max and had.page == want.page and (s.tracking != null or had.pos == want.pos)) return;
    }
    var mask = win32.SIF_RANGE | win32.SIF_PAGE | win32.SIF_DISABLENOSCROLL;
    if (s.tracking == null) mask |= win32.SIF_POS;
    const info: win32.SCROLLINFO = .{ .fMask = mask, .nMax = want.max, .nPage = want.page, .nPos = want.pos };
    _ = win32.SetScrollInfo(surface.hwnd, win32.SB_VERT, &info, .TRUE);
    if (builtin.is_test) test_sets += 1;
    const pos = if (s.tracking == null) want.pos else if (s.set) |had| had.pos else 0;
    s.set = .{ .max = want.max, .page = want.page, .pos = pos };
}

/// WM_VSCROLL from `surface`'s bar, `wparam` its request: the viewport
/// moves to the row it names (`rowFor`) through the core's
/// `scroll_to_row`, performed as a key's binding is (`SearchBar.perform`),
/// if that is another row than the one it is at or was last asked to go
/// to. The thumb's place is its 32-bit track position (`trackPos`), not
/// wParam's high word, which holds only 16 bits of it.
///
/// The bar's loop sends it, and the bar's menu for the item chosen
/// (`loop`), under the terminal's handler with no core frame beneath; the
/// core is still entered only while `App.canReenterCore` allows it, as a
/// key is dropped under a prompt (`Surface.handleMessage`).
///
/// SB_THUMBTRACK inside one of the bar's loops starts a drag of the
/// thumb, during which `apply` leaves its position alone; SB_ENDSCROLL
/// ends it, and the bar takes the row the viewport was last asked to go
/// to, or the core's position (`apply`). In a press's loop
/// SB_THUMBPOSITION asks nothing: Windows sends SB_THUMBTRACK at the press
/// on the thumb and at each place it moves to, and the release's
/// SB_THUMBPOSITION names the last of those, which was taken when it came.
/// Asked again once the viewport's row has moved on while the thumb was
/// held, as the output moves it in a scrollback at its limit, which takes
/// rows off the top, it would put the viewport back there. The bar's
/// menu's SB_THUMBPOSITION (Scroll Here), and another program's, are
/// taken. A terminal without the bar (`scrollbar = never`) takes none: it
/// has no bar to send one, and its window's scroll info is the last bar's,
/// if it had one.
///
/// In a drag, the thumb at the last place of the range Windows tracks it
/// with (`State.tracking`) is at the bottom, rather than at the row that
/// place names, which was the bottom when the drag began and which the
/// output may have moved on from since. Every step to the bar's last row
/// (`lastRow`), the menu's Bottom, a line or a page down that reaches it
/// or stops there, and the thumb there, asks for the core's last row as it
/// is then (`bottom_row`), as the bar's rows can be behind the core's;
/// `asked` holds the bar's own last row, which the bar shows when the
/// scroll ends (`endDrag`) until the core reports. From there the core's
/// viewport follows the output again, as GTK's does at its adjustment's
/// end, so a thumb held there asks nothing more while the output comes,
/// nor does a step at the bar's last row already. A range that has shrunk
/// since the drag began, as a cleared scrollback shrinks it, is still kept
/// to: a place past its last row is its last row.
pub fn scrolled(surface: *Surface, wparam: win32.WPARAM) void {
    const s = &surface.scroll_bar;
    // Without the bar, nothing of this window's sends it.
    if (!s.on) return;
    const code: u16 = @truncate(wparam);
    switch (code) {
        win32.SB_ENDSCROLL => return endDrag(surface),
        // Only inside a loop, which ends the drag if no SB_ENDSCROLL does;
        // the range is the bar's at the first.
        win32.SB_THUMBTRACK => if (s.in_loop != null and s.tracking == null) {
            s.tracking = lastPlace(infoFor(s.rows));
        },
        win32.SB_THUMBPOSITION => if (s.in_loop == .press) return,
        else => {},
    }
    const thumb: ?i32 = switch (code) {
        win32.SB_THUMBTRACK, win32.SB_THUMBPOSITION => trackPos(surface.hwnd),
        else => null,
    };
    const at_end = if (s.tracking) |end| if (thumb) |at| at >= end else false else false;
    const from = s.asked orelse s.rows.offset;
    const row = rowFor(if (at_end) win32.SB_BOTTOM else code, s.rows, from, thumb) orelse return;
    if (row == from) return;
    if (!surface.app.canReenterCore()) {
        log.debug("a scroll bar move is dropped, the core cannot be re-entered row={d}", .{row});
        return;
    }
    s.asked = row;
    _ = SearchBar.perform(surface, .{ .scroll_to_row = if (row == lastRow(s.rows)) bottom_row else row });
}

/// The thumb is no longer dragged: the bar takes the row the viewport was
/// last asked to go to until the core reports it (`State.asked`), else
/// the core's position (`apply`), given to Windows even where the bar's
/// record says Windows has it (`State.set`). SetScrollInfo keeps the
/// position inside the range it is given, so a range given during the
/// drag can have moved Windows' with no SIF_POS of the bar's: a cleared
/// scrollback moves it to the top of what is left, and the output that
/// fills the range again leaves it there.
fn endDrag(surface: *Surface) void {
    const s = &surface.scroll_bar;
    s.tracking = null;
    s.set = null;
    if (s.on) apply(surface);
}

/// Where the thumb is, SCROLLINFO's 32-bit nTrackPos; null if Windows does
/// not say.
fn trackPos(hwnd: win32.HWND) ?i32 {
    var info: win32.SCROLLINFO = .{ .fMask = win32.SIF_TRACKPOS };
    if (!win32.GetScrollInfo(hwnd, win32.SB_VERT, &info).toBool()) return null;
    return info.nTrackPos;
}

/// Whether `msg` to a terminal runs one of the bar's loops in its
/// DefWindowProcW (`loop`): WM_SYSCOMMAND's scroll commands, which
/// DefWindowProcW sends for a press on the bar (WM_NCLBUTTONDOWN) and for
/// a double click on it (WM_NCLBUTTONDBLCLK), and another program may
/// send, and WM_CONTEXTMENU at a point on the bar, which a right click
/// there sends (WM_NCRBUTTONUP). For a press on the vertical bar Windows
/// 11 sends SC_HSCROLL, with HTVSCROLL in the four low bits SC_MASK leaves
/// out, and for a double click SC_VSCROLL, with HTVSCROLL: both are taken.
pub fn runsLoop(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    return switch (msg) {
        win32.WM_SYSCOMMAND => switch (wparam & win32.SC_MASK) {
            win32.SC_VSCROLL, win32.SC_HSCROLL => true,
            else => false,
        },
        win32.WM_CONTEXTMENU => onBar(hwnd, lparam),
        else => false,
    };
}

/// Whether the point on the screen `lparam` is on `hwnd`'s bar, as the
/// system hit-tests it for its menu. A menu asked for from the keyboard
/// comes at (-1, -1), which is taken as any other point: whether the
/// system shows the bar's menu for it is its own hit test's to say.
fn onBar(hwnd: win32.HWND, lparam: win32.LPARAM) bool {
    return win32.DefWindowProcW(hwnd, win32.WM_NCHITTEST, 0, lparam) == win32.HTVSCROLL;
}

/// For tests: stands in for DefWindowProcW's loop (`loop`), given the
/// terminal and the message, as `ContextMenu.test_track` stands in for
/// the context menu's. Unset, no loop runs in a test, as one waits for the
/// button to come up.
pub var test_loop: if (builtin.is_test) ?*const fn (*Surface, win32.UINT, win32.WPARAM, win32.LPARAM) win32.LRESULT else void =
    if (builtin.is_test) null else {};

/// DefWindowProcW for `msg`, which runs one of the bar's loops
/// (`runsLoop`), and its answer. The loop dispatches every message posted
/// meanwhile and returns to the terminal's handler when the button comes
/// up or the menu closes, and the frame hears of none of it. So it is
/// counted in `App.modal_loop_depth`, as the frame counts a size, move or
/// menu loop, and the app keeps ticking while the thumb is held: the bar
/// follows the output that keeps coming. It is counted in
/// `App.terminal_loops` as well, so that a teardown posted meanwhile, the
/// shell exiting or the window closed, waits until it has returned
/// (`App.beginTerminalLoop`). While it runs the bar knows which loop it is
/// (`State.in_loop`), as only inside one is SB_THUMBTRACK a drag, and in a
/// press's SB_THUMBPOSITION asks nothing (`scrolled`). A drag of the thumb
/// ends with it, SB_ENDSCROLL or not.
pub fn loop(
    surface: *Surface,
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    const app = surface.app;
    const s = &surface.scroll_bar;
    const start = win32.GetTickCount64();
    const updates = s.updates;
    // A loop inside another, as another program's WM_SYSCOMMAND could
    // start, gives the outer one its own back.
    const outer = s.in_loop;
    app.beginTerminalLoop();
    app.modal_loop_depth += 1;
    s.in_loop = if (msg == win32.WM_CONTEXTMENU) .menu else .press;
    const result = result: {
        if (builtin.is_test) break :result if (test_loop) |run| run(surface, msg, wparam, lparam) else 0;
        break :result win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    };
    s.in_loop = outer;
    app.modal_loop_depth -= 1;
    if (s.tracking != null) endDrag(surface);
    log.debug("scroll bar loop ended ms={d} updates={d}", .{ win32.GetTickCount64() - start, s.updates -% updates });
    app.endTerminalLoop();
    return result;
}

/// Give `surface`'s window the bar the configuration asks for (`style`),
/// or take it away, and give a new bar the core's rows. The client area
/// changes by the bar's width, which reaches the core as WM_SIZE, so this
/// runs from `App.run` (`App.Request.redecorate`), never inside the
/// action or a core frame, as the frames' decorations change
/// (`Window.applyDecorations`).
pub fn restyle(surface: *Surface) void {
    const s = &surface.scroll_bar;
    const want = surface.app.config.scrollbar == .system;
    if (want == s.on) return;
    const hwnd = surface.hwnd;
    const bit: isize = win32.WS_VSCROLL;
    const now = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, if (want) now | bit else now & ~bit);
    s.on = want;
    s.set = null;
    s.tracking = null;
    const flags = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOOWNERZORDER |
        win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED;
    _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, flags);
    if (want) apply(surface);
}

/// Give `surface`'s bar its frame's mode (`Window.dark_frame`): the
/// "DarkMode_Explorer" theme class in a dark one, as the command palette's
/// list takes it (`CommandPalette.applyListTheme`), and the system's own
/// back in a light one. The class name is not documented: a Windows
/// without it keeps the light bar. Only when the mode changes, as each
/// call sends the window WM_THEMECHANGED. The bar's width stays: the
/// client area keeps its size, which matters as the frame's theme follows
/// a configuration a soft reload gives inside a core frame
/// (`App.configChange`).
pub fn applyTheme(surface: *Surface) void {
    const s = &surface.scroll_bar;
    const dark = surface.window.dark_frame;
    if (dark == s.dark) return;
    const hr = win32.SetWindowTheme(surface.hwnd, if (dark) L("DarkMode_Explorer") else null, null);
    if (hr < 0) {
        log.info("cannot set a terminal's scroll bar theme hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return;
    }
    s.dark = dark;
}

const testing = std.testing;

test "win32: a scroll bar request moves the viewport to its row, kept to the scrollback" {
    // 1000 rows, 50 on the screen: the viewport starts at most at 950.
    const rows: terminal.Scrollbar = .{ .total = 1000, .offset = 500, .len = 50 };
    try testing.expectEqual(499, rowFor(win32.SB_LINEUP, rows, 500, null));
    try testing.expectEqual(501, rowFor(win32.SB_LINEDOWN, rows, 500, null));
    try testing.expectEqual(450, rowFor(win32.SB_PAGEUP, rows, 500, null));
    try testing.expectEqual(550, rowFor(win32.SB_PAGEDOWN, rows, 500, null));
    try testing.expectEqual(0, rowFor(win32.SB_TOP, rows, 500, null));
    try testing.expectEqual(950, rowFor(win32.SB_BOTTOM, rows, 500, null));
    try testing.expectEqual(123, rowFor(win32.SB_THUMBTRACK, rows, 500, 123));
    try testing.expectEqual(777, rowFor(win32.SB_THUMBPOSITION, rows, 500, 777));
    // From the row given, not the core's offset: a step after a step not
    // reported back yet.
    try testing.expectEqual(512, rowFor(win32.SB_LINEDOWN, rows, 511, null));
    // No row: the end of a scroll, a request there is none of, a thumb
    // Windows gave no place for.
    try testing.expectEqual(null, rowFor(win32.SB_ENDSCROLL, rows, 500, null));
    try testing.expectEqual(null, rowFor(9, rows, 500, null));
    try testing.expectEqual(null, rowFor(win32.SB_THUMBTRACK, rows, 500, null));

    // At the top, nothing above it.
    try testing.expectEqual(0, rowFor(win32.SB_LINEUP, rows, 0, null));
    try testing.expectEqual(0, rowFor(win32.SB_PAGEUP, rows, 0, null));
    try testing.expectEqual(0, rowFor(win32.SB_PAGEUP, rows, 10, null));
    try testing.expectEqual(0, rowFor(win32.SB_THUMBTRACK, rows, 500, -5));
    // At the bottom, nothing below it.
    try testing.expectEqual(950, rowFor(win32.SB_LINEDOWN, rows, 950, null));
    try testing.expectEqual(950, rowFor(win32.SB_LINEDOWN, rows, 949, null));
    try testing.expectEqual(950, rowFor(win32.SB_PAGEDOWN, rows, 920, null));
    try testing.expectEqual(950, rowFor(win32.SB_THUMBPOSITION, rows, 500, 2000));

    // As many rows as the screen, or fewer: nothing to scroll.
    for ([_]usize{ 50, 10, 0 }) |total| {
        const short: terminal.Scrollbar = .{ .total = total, .offset = 0, .len = 50 };
        for ([_]u16{ win32.SB_LINEDOWN, win32.SB_PAGEDOWN, win32.SB_BOTTOM, win32.SB_TOP }) |code| {
            try testing.expectEqual(0, rowFor(code, short, 0, null));
        }
        try testing.expectEqual(0, rowFor(win32.SB_THUMBTRACK, short, 0, 5));
    }

    // Past what the bar can hold, a step is still exact.
    const huge: terminal.Scrollbar = .{ .total = 1 << 33, .offset = 1 << 32, .len = 50 };
    try testing.expectEqual((1 << 32) + 1, rowFor(win32.SB_LINEDOWN, huge, 1 << 32, null));
    try testing.expectEqual((1 << 33) - 50, rowFor(win32.SB_BOTTOM, huge, 1 << 32, null));
}

test "win32: a scroll bar's range saturates at what SetScrollInfo takes" {
    const max: i32 = std.math.maxInt(i32);
    const rows: usize = max;
    try testing.expectEqual(Info{ .max = 999, .page = 50, .pos = 500 }, infoFor(.{ .total = 1000, .offset = 500, .len = 50 }));
    // An empty scrollback: one row, a page of one.
    try testing.expectEqual(Info{ .max = 0, .page = 1, .pos = 0 }, infoFor(.zero));
    // Up to the boundary, exact; past it, the most it takes, where a wrap
    // would give 4 for 2^32 + 5 rows.
    try testing.expectEqual(max - 1, infoFor(.{ .total = rows, .offset = 0, .len = 50 }).max);
    try testing.expectEqual(max, infoFor(.{ .total = rows + 1, .offset = 0, .len = 50 }).max);
    try testing.expectEqual(max, infoFor(.{ .total = rows + 2, .offset = 0, .len = 50 }).max);
    const past = infoFor(.{ .total = (1 << 32) + 5, .offset = (1 << 32) + 7, .len = (1 << 32) + 9 });
    try testing.expectEqual(Info{ .max = max, .page = @intCast(max), .pos = max }, past);
}

test "win32: the core takes a scroll bar's bottom row as its last, and follows the output from it" {
    // What `bottom_row` relies on (src/terminal/PageList.zig:3337): asked
    // for a row past its last, a viewport pinned in the scrollback becomes
    // the active area, which stays at the bottom as the output adds rows.
    var pages = try terminal.PageList.init(testing.allocator, .{ .cols = 10, .rows = 5 });
    defer pages.deinit();
    for (0..20) |_| _ = try pages.grow();
    pages.scroll(.{ .row = 3 });
    try testing.expectEqual(3, pages.scrollbar().offset);
    pages.scroll(.{ .row = bottom_row });
    try testing.expect(pages.viewport == .active);
    _ = try pages.grow();
    const rows = pages.scrollbar();
    try testing.expectEqual(rows.total - rows.len, rows.offset);
}
