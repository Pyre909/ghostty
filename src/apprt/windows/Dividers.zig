//! Where the pointer takes hold of the dividers between a tab's terminals.
//!
//! A divider is a line of the frame's own client area between two
//! terminals (`Window.layout`), a pixel wide at 96 DPI
//! (`Window.dividerWidth`). Its band is the line and 3 DIP on each side of
//! it, as macOS's divider is a 1 pt line in a 7 pt hit box
//! (`splitterVisibleSize` and `splitterInvisibleSize` in
//! macos/Sources/Features/Splits/SplitView.swift). Over the band's pixels
//! on either side, the terminal there answers WM_NCHITTEST with
//! HTTRANSPARENT (`hitTest`), so that Windows gives the pointer to the
//! frame under it, as over the line itself; the frame's WM_SETCURSOR then
//! shows the resize pointer across the divider (`setCursor`). The band
//! takes those pixels from the terminals, where the default padding
//! (`window-padding-x` and `window-padding-y`, 2 pt) covers most of them.
//! GTK narrowed its separator's grab area to its line instead, because a
//! wider one made the first column right of a split unselectable
//! (src/apprt/gtk/css/style.css, ghostty#3020).
//!
//! Only the dividers the frame draws have bands: those of the tab it
//! shows, none in a zoomed tab, and none along the window's outer edges.
//! Each hit test lays the shown tab out again (`at`) instead of keeping the
//! dividers of the last layout, so that a band never lags behind the tree,
//! the client area or the DPI: a walk of the tree, without allocating.
//!
//! A press in a band drags the divider (`Drag`): each move of the pointer
//! writes its split's ratio and lays the terminals out at once, as GTK's
//! and macOS's dividers resize their splits while they are dragged, and
//! the line stops where a terminal on either side, nested splits'
//! included, would shrink below a cell, as `Window.adopt` refuses a resize
//! that would (`dragRatio`). A double click in a band equalizes the tab's
//! splits, as on macOS (`doubleClick`). These are the frame's own
//! messages, which reach it from a message loop: `App.run`'s, a size, move
//! or menu loop, or a teardown's wait (`App.waitForThread`), none of them
//! with a core frame beneath. The one loop that can run inside a core
//! frame, a prompt's, disables every frame first (`App.beginPrompt`),
//! which takes the capture from a drag (WM_CANCELMODE) and gives the frame
//! no mouse input; a move still lays nothing out while the core may not be
//! re-entered (`follow`), as the tab bar's drag does.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const win32 = @import("win32.zig");
const Window = @import("Window.zig");
const Tab = Window.Tab;
const Surface = @import("Surface.zig").Surface;
const SplitTree = @import("../../datastruct/main.zig").SplitTree;

const log = std.log.scoped(.win32);

/// A divider of a tree of type `Tree` that the pointer is over or beside
/// (`find`): what a drag of it needs.
pub fn GrabOf(comptime Tree: type) type {
    return struct {
        /// Its split. It names that split in the tree it was found in only
        /// until that tree changes.
        handle: Tree.Node.Handle,

        /// Whether the split's sides are left and right of the divider
        /// (`.horizontal`), else above and below it.
        across: bool,

        /// Where the split lays out: its two sides and the divider, in the
        /// coordinates `find` was given.
        area: win32.RECT,

        /// The divider's line, as `Window.layout` reports it: at most
        /// `Window.dividerWidth` pixels across, fewer in a narrower split.
        line: win32.RECT,
    };
}

/// A divider of a window's shown tab (`at`).
pub const Grab = GrabOf(Window.Tree);

/// How far a band reaches on each side of its divider's line: 3
/// device-independent pixels at `dpi`, to the nearest whole pixel (halves
/// up), as `Window.dividerWidth` rounds.
pub fn bandReach(dpi: u32) i32 {
    const base = win32.USER_DEFAULT_SCREEN_DPI;
    return @intCast((3 *| dpi +| base / 2) / base);
}

/// The divider of `tree`, laid out in `area` with dividers `divider`
/// pixels wide (`Window.layout`), whose band holds `point`: its line and
/// `reach` pixels on each side of it, across it only and never outside the
/// area its split lays out in. Where two bands overlap, as where a divider
/// meets the one of a split it is inside, the divider nearer `point`
/// across its line; of two as near, the outer one. Null where there is
/// none, as anywhere in a tree zoomed to one terminal, where `layout`
/// reports no divider.
pub fn find(
    tree: anytype,
    area: win32.RECT,
    divider: i32,
    reach: i32,
    point: win32.POINT,
) ?GrabOf(@TypeOf(tree.*)) {
    var ctx: Finder(@TypeOf(tree.*)) = .{ .point = point, .reach = reach };
    Window.layout(tree, area, divider, &ctx);
    return ctx.found;
}

/// What `find` asks `Window.layout` for.
fn Finder(comptime Tree: type) type {
    return struct {
        const Self = @This();

        point: win32.POINT,
        reach: i32,
        found: ?GrabOf(Tree) = null,
        /// How far `point` is from `found`'s line across it: 0 on it.
        distance: i32 = 0,

        pub fn pane(self: *Self, view: anytype, rect: win32.RECT) void {
            _ = self;
            _ = view;
            _ = rect;
        }

        pub fn hidden(self: *Self, view: anytype) void {
            _ = self;
            _ = view;
        }

        /// `layout` reports a split before the splits inside it, so a
        /// later divider replaces the found one only if it is nearer.
        pub fn divider(
            self: *Self,
            handle: Tree.Node.Handle,
            line: win32.RECT,
            across: bool,
            area: win32.RECT,
        ) void {
            const b = band(line, area, across, self.reach);
            const p = self.point;
            if (p.x < b.left or p.x >= b.right or p.y < b.top or p.y >= b.bottom) return;
            const d = if (across)
                distance(p.x, line.left, line.right)
            else
                distance(p.y, line.top, line.bottom);
            if (self.found != null and d >= self.distance) return;
            self.found = .{ .handle = handle, .across = across, .area = area, .line = line };
            self.distance = d;
        }
    };
}

/// The band of a divider's `line` in a split laid out in `area`: the line
/// and `reach` pixels on each side of it, across it only, and inside
/// `area`.
fn band(line: win32.RECT, area: win32.RECT, across: bool, reach: i32) win32.RECT {
    var b = line;
    if (across) {
        b.left = @max(area.left, line.left - reach);
        b.right = @min(area.right, line.right + reach);
    } else {
        b.top = @max(area.top, line.top - reach);
        b.bottom = @min(area.bottom, line.bottom + reach);
    }
    return b;
}

/// How far `pos` is from the pixels `from` up to `to`: 0 on them, 1 next
/// to them.
fn distance(pos: i32, from: i32, to: i32) i32 {
    if (pos < from) return from - pos;
    if (pos >= to) return pos - to + 1;
    return 0;
}

/// The divider of `window`'s shown tab whose band holds `client`, a point
/// in the frame's client area (`find`): the tab laid out as
/// `Window.relayout` lays it out, under the tab bar and at the frame's DPI.
pub fn at(window: *const Window, client: win32.POINT) ?Grab {
    const area = window.layoutArea() orelse return null;
    const dpi = Window.dpiOf(window.app, window.hwnd);
    return find(&window.tab().tree, area, Window.dividerWidth(dpi), bandReach(dpi), client);
}

/// A terminal's WM_NCHITTEST, `lparam` a point on the screen: in a band of
/// its frame's shown tab (`at`), HTTRANSPARENT, so that the frame under
/// it gets the pointer; elsewhere DefWindowProcW's answer, and that one
/// too wherever it is not HTCLIENT.
pub fn hitTest(
    window: *const Window,
    hwnd: win32.HWND,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    const hit = win32.DefWindowProcW(hwnd, win32.WM_NCHITTEST, wparam, lparam);
    if (hit != win32.HTCLIENT) return hit;
    var client: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    if (!win32.ScreenToClient(window.hwnd, &client).toBool()) return hit;
    return if (at(window, client) != null) win32.HTTRANSPARENT else hit;
}

/// For tests: answers in place of GetCursorPos (`setCursor`), as
/// `Window.test_get_focus` stands for GetFocus, so that a test chooses
/// the point without moving the pointer.
pub var test_cursor_pos: if (builtin.is_test) ?win32.POINT else void =
    if (builtin.is_test) null else {};

/// The frame's WM_SETCURSOR: with the pointer over the frame itself
/// (`wparam`), in its client area, on a divider or in its band (`at`), set
/// the resize pointer across the divider, left and right between
/// terminals side by side, up and down between terminals one above the
/// other, and return true. Otherwise false, for DefWindowProcW, which
/// sets the frame's arrow over its own client area, as before.
pub fn setCursor(window: *const Window, wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    if (wparam != @intFromPtr(window.hwnd) or win32.loword(lparam) != win32.HTCLIENT) return false;
    var client = cursorPos() orelse return false;
    if (!win32.ScreenToClient(window.hwnd, &client).toBool()) return false;
    const grab = at(window, client) orelse return false;
    const id = if (grab.across) win32.IDC_SIZEWE else win32.IDC_SIZENS;
    const cursor = win32.LoadCursorW(null, id) orelse {
        log.warn("cannot load a divider's pointer err={}", .{win32.GetLastError()});
        return false;
    };
    _ = win32.SetCursor(cursor);
    return true;
}

/// Where the pointer is on the screen, or null if Windows cannot say.
fn cursorPos() ?win32.POINT {
    if (builtin.is_test) if (test_cursor_pos) |pos| return pos;
    var pos: win32.POINT = undefined;
    if (!win32.GetCursorPos(&pos).toBool()) return null;
    return pos;
}

/// A divider being dragged (`Window.divider_drag`): from a press in its
/// band (`press`) until the button comes up (`release`), a move comes
/// without it (`dragTo`), the frame loses the capture (`captureLost`), or
/// its tab's tree changes or the tab is no longer shown (`tabChanged`).
pub const Drag = struct {
    /// The tab shown at the press, only compared with others
    /// (`tabChanged`), never read through.
    tab: *const Tab,

    /// The split, in `tab`'s tree, which the drag ends on changing.
    handle: Window.Tree.Node.Handle,

    /// Where the press was from the line's first pixel, across it: the
    /// line keeps it, so that it moves as far as the pointer does rather
    /// than jump under it. Negative for a press before the line.
    grab: i32,
};

/// The frame's WM_LBUTTONDOWN, `lparam` a point in its client area: in a
/// band (`at`), the frame takes the mouse capture, so that it gets the
/// moves and the release wherever the pointer goes, and the divider's
/// drag starts. Returns whether it did; elsewhere the press is
/// DefWindowProcW's, as before.
pub fn press(window: *Window, lparam: win32.LPARAM) bool {
    const client = pointOf(lparam);
    const grab = at(window, client) orelse return false;
    // Captured first: SetCapture sends WM_CAPTURECHANGED to the window
    // losing the capture, which would end a drag (`captureLost`).
    if (win32.GetCapture() != window.hwnd) _ = win32.SetCapture(window.hwnd);
    window.divider_drag = .{
        .tab = window.tab(),
        .handle = grab.handle,
        .grab = if (grab.across) client.x - grab.line.left else client.y - grab.line.top,
    };
    return true;
}

/// The frame's WM_MOUSEMOVE: a drag's divider follows the pointer
/// (`follow`). A move without the left button down, after a release the
/// frame did not see, ends the drag where it is. Returns whether there
/// was a drag.
pub fn dragTo(window: *Window, wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    const d = window.divider_drag orelse return false;
    if (wparam & win32.MK_LBUTTON == 0) {
        endDrag(window);
    } else {
        follow(window, d, pointOf(lparam));
    }
    return true;
}

/// The frame's WM_LBUTTONUP: a drag's divider goes where the button came
/// up, and the drag ends. Returns whether there was a drag.
pub fn release(window: *Window, lparam: win32.LPARAM) bool {
    const d = window.divider_drag orelse return false;
    follow(window, d, pointOf(lparam));
    endDrag(window);
    return true;
}

/// The frame's WM_CAPTURECHANGED: the capture went to another window, or
/// was released, as DefWindowProcW releases it when a prompt disables the
/// frame (WM_CANCELMODE). The release will come up unseen, so the drag
/// ends where it is.
pub fn captureLost(window: *Window) void {
    window.divider_drag = null;
}

/// `t`'s tree changed, or `t` is no longer `window`'s shown tab: a drag of
/// one of its dividers ends where it is, as its split may be gone and its
/// handle name another, and the frame lets go of the capture.
pub fn tabChanged(window: *Window, t: *const Tab) void {
    const d = window.divider_drag orelse return;
    if (d.tab == t) endDrag(window);
}

/// The frame's WM_LBUTTONDBLCLK, which with `CS_DBLCLKS` comes in place of
/// a double click's second press: in a band, every split of the shown tab
/// is equalized (`Window.equalizeTab`), as a double click on a divider
/// does on macOS; not while the core may not be re-entered (`follow`).
/// Returns whether it was in a band; elsewhere it is DefWindowProcW's, as
/// the second press was before.
pub fn doubleClick(window: *Window, lparam: win32.LPARAM) bool {
    if (at(window, pointOf(lparam)) == null) return false;
    if (window.app.canReenterCore()) window.equalizeTab(window.tab());
    return true;
}

/// End a drag where it is, and let go of the capture. Cleared first, as
/// ReleaseCapture sends the frame WM_CAPTURECHANGED (`captureLost`).
fn endDrag(window: *Window) void {
    window.divider_drag = null;
    if (win32.GetCapture() == window.hwnd) _ = win32.ReleaseCapture();
}

/// Put the dragged divider where the pointer at `client` puts it
/// (`dragRatio`), and if it moved, lay the shown tab out at once. The
/// split's area is laid out again for each move, so that a resize or a
/// DPI change during the drag is followed. Not while the core may not be
/// re-entered (`App.canReenterCore`): the layout sends the terminals
/// WM_SIZE, which enters the core (`App.requests`); the line then waits
/// for the next move.
fn follow(window: *Window, d: Drag, client: win32.POINT) void {
    if (!window.app.canReenterCore()) return;
    const t = window.tab();
    const area = window.layoutArea() orelse return;
    const divider = Window.dividerWidth(Window.dpiOf(window.app, window.hwnd));
    var found: AreaOf = .{ .handle = d.handle };
    Window.layout(&t.tree, area, divider, &found);
    const split = found.area orelse return;
    const pos = if (found.across) client.x - split.left else client.y - split.top;
    const ratio = dragRatio(&t.tree, d.handle, split, divider, pos - d.grab) orelse return;
    t.tree.resizeInPlace(d.handle, ratio);
    window.relayout();
}

/// What `follow` asks `Window.layout` for: where the split at `handle`
/// lays out, and along which axis; nothing for a split without a line.
const AreaOf = struct {
    handle: Window.Tree.Node.Handle,
    area: ?win32.RECT = null,
    across: bool = false,

    pub fn pane(self: *AreaOf, surface: *Surface, rect: win32.RECT) void {
        _ = self;
        _ = surface;
        _ = rect;
    }

    pub fn hidden(self: *AreaOf, surface: *Surface) void {
        _ = self;
        _ = surface;
    }

    pub fn divider(
        self: *AreaOf,
        handle: Window.Tree.Node.Handle,
        line: win32.RECT,
        across: bool,
        area: win32.RECT,
    ) void {
        _ = line;
        if (handle != self.handle) return;
        self.area = area;
        self.across = across;
    }
};

/// A mouse message's point, in the client coordinates it comes in.
fn pointOf(lparam: win32.LPARAM) win32.POINT {
    return .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
}

/// The ratio for the split at `handle` of `tree`, laid out in `area` with
/// dividers `divider` pixels wide (`Window.splitArea`), that gives its
/// first side (left or top) `first` pixels: kept to the places where no
/// terminal shrinks below a cell (`dragRange`), as `Window.adopt` keeps a
/// resize, and as near as an `f16` ratio lays it out, which over 3840
/// pixels can place the line only every pixel or two. Null where that
/// leaves the line where it is, as where it already leaves a terminal its
/// least on the side `first` would shrink.
pub fn dragRatio(
    tree: *const Window.Tree,
    handle: Window.Tree.Node.Handle,
    area: win32.RECT,
    divider: i32,
    first: i32,
) ?f16 {
    const range = dragRange(tree, handle, area, divider);
    if (range.lo == range.hi) return null;
    const ratio = ratioFor(range.rest, std.math.clamp(first, range.lo, range.hi), range.lo, range.hi);
    if (Window.firstExtent(range.rest, ratio) == range.now) return null;
    return ratio;
}

/// Where a dragged split may put its line (`dragRange`): its first side
/// from `lo` to `hi` of the `rest` pixels its line leaves, around `now`,
/// where its ratio puts it.
const Range = struct {
    lo: i32,
    hi: i32,
    now: i32,
    rest: i32,
};

/// The places of the line of the split at `handle` of `tree`, laid out in
/// `area` with dividers `divider` pixels wide, where each terminal under
/// it, laid out with the split's first side that many pixels, keeps a cell
/// across and down wherever it shrinks: `Window.adopt`'s check of a resize
/// (`Window.keepsCellsAt`), so that a nested split keeps each of its
/// terminals a cell at its own ratio. Where the line is now nothing
/// shrinks, so that place is one of them. As the first side grows by a
/// pixel, each terminal in it grows by a pixel or not at all, and each in
/// the second side shrinks by a pixel or not at all (for sides under 8192
/// pixels, where `Window.firstExtent`'s product is exact), so the places
/// are the pixels from the first that keeps the first side's terminals to
/// the last that keeps the second's: each found by halving, each step a
/// walk of the split's terminals.
fn dragRange(
    tree: *const Window.Tree,
    handle: Window.Tree.Node.Handle,
    area: win32.RECT,
    divider: i32,
) Range {
    const s = tree.nodes[handle.idx()].split;
    const across = s.layout == .horizontal;
    const was = Window.splitArea(area, across, s.ratio, divider);
    const total = @max(0, if (across) area.right - area.left else area.bottom - area.top);
    const rest = total - was.line;
    const now = Window.firstExtent(rest, s.ratio);
    const fit: Fit = .{ .tree = tree, .split = s, .area = area, .across = across, .was = was, .divider = divider };

    // The first place that fits, from 0 to `now`, where only the first
    // side's terminals shrink.
    var lo: i32 = 0;
    var upper = now;
    while (lo < upper) {
        const mid = lo + @divTrunc(upper - lo, 2);
        if (fit.keeps(mid)) upper = mid else lo = mid + 1;
    }

    // The last, from `now` to `rest`, where only the second side's do.
    var hi = now;
    var lower = rest;
    while (hi < lower) {
        const mid = hi + @divTrunc(lower - hi + 1, 2);
        if (fit.keeps(mid)) hi = mid else lower = mid - 1;
    }
    return .{ .lo = lo, .hi = hi, .now = now, .rest = rest };
}

/// `dragRange`'s check of one place of the line: whether the terminals of
/// both sides of `split`, laid out in `area` as `was` by its ratio, keep a
/// cell wherever they shrink with its first side `first` pixels.
const Fit = struct {
    tree: *const Window.Tree,
    split: Window.Tree.Split,
    area: win32.RECT,
    across: bool,
    was: Window.Sides,
    divider: i32,

    fn keeps(self: Fit, first: i32) bool {
        const now = Window.splitAt(self.area, self.across, self.was.line, first);
        const t = self.tree;
        return Window.keepsCellsAt(t, t, self.split.left, self.was.first, now.first, self.divider) and
            Window.keepsCellsAt(t, t, self.split.right, self.was.second, now.second, self.divider);
    }
};

/// The `f16` ratio nearest `first / rest` whose first side
/// (`Window.firstExtent`) is from `lo` to `hi` pixels, where
/// `0 <= lo <= first <= hi <= rest`, `lo < hi`, and some `f16` ratio lays
/// one out there, as the split's own does (`dragRange`).
fn ratioFor(rest: i32, first: i32, lo: i32, hi: i32) f16 {
    assert(0 <= lo and lo < hi and lo <= first and first <= hi and hi <= rest);
    var ratio: f16 = @floatCast(@as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(rest)));
    // Each step is the next f16 and moves the side by at most a pixel or
    // two; a ratio of 1 gives all of `rest`, and one of 0 none of it.
    while (Window.firstExtent(rest, ratio) < lo) ratio = std.math.nextAfter(f16, ratio, 1);
    while (Window.firstExtent(rest, ratio) > hi) ratio = std.math.nextAfter(f16, ratio, 0);
    assert(Window.firstExtent(rest, ratio) >= lo);
    return ratio;
}

/// For the pure tests: a view with a name and no reference count.
const TestView = struct {
    name: u8,

    pub fn ref(self: *TestView) *TestView {
        return self;
    }

    pub fn unref(self: *TestView) void {
        _ = self;
    }
};

const TestTree = SplitTree(TestView);
const TestGrab = GrabOf(TestTree);

/// `tree` with `view` split off `at_handle` in `direction` at `ratio`.
fn testSplit(
    tree: *const TestTree,
    at_handle: TestTree.Node.Handle,
    direction: TestTree.Split.Direction,
    ratio: f16,
    view: *TestView,
) !TestTree {
    const alloc = std.testing.allocator;
    var single: TestTree = try .init(alloc, view);
    defer single.deinit();
    return tree.split(alloc, at_handle, direction, ratio, &single);
}

/// `a` beside `b` in `direction`, at `ratio`.
fn testPair(a: *TestView, b: *TestView, direction: TestTree.Split.Direction, ratio: f16) !TestTree {
    var only_a: TestTree = try .init(std.testing.allocator, a);
    defer only_a.deinit();
    return testSplit(&only_a, .root, direction, ratio, b);
}

/// The grab at `x`, `y` of `tree` in `area` at 96 DPI: dividers a pixel
/// wide and bands 3 pixels on each side.
fn testFind(tree: *const TestTree, area: win32.RECT, x: i32, y: i32) ?TestGrab {
    return find(tree, area, 1, 3, .{ .x = x, .y = y });
}

test "win32: a divider's band is its line and 3 DIP on each side, across it" {
    var a: TestView = .{ .name = 'a' };
    var b: TestView = .{ .name = 'b' };
    const area: win32.RECT = .{ .left = 10, .top = 20, .right = 111, .bottom = 71 };

    // a | b: 100 pixels for the panes, so the line is the column at 60.
    var row = try testPair(&a, &b, .right, 0.5);
    defer row.deinit();
    const line: win32.RECT = .{ .left = 60, .top = 20, .right = 61, .bottom = 71 };
    const want: TestGrab = .{ .handle = .root, .across = true, .area = area, .line = line };
    for ([_]i32{ 57, 58, 59, 60, 61, 62, 63 }) |x| {
        try std.testing.expectEqual(want, testFind(&row, area, x, 45).?);
    }
    // Along the whole line, and not past its ends.
    try std.testing.expectEqual(want, testFind(&row, area, 60, 20).?);
    try std.testing.expectEqual(want, testFind(&row, area, 60, 70).?);
    for ([_][2]i32{ .{ 56, 45 }, .{ 64, 45 }, .{ 60, 19 }, .{ 60, 71 } }) |p| {
        try std.testing.expect(testFind(&row, area, p[0], p[1]) == null);
    }

    // a over b: 50 pixels for the panes, so the line is the row at 45.
    var column = try testPair(&a, &b, .down, 0.5);
    defer column.deinit();
    const across: win32.RECT = .{ .left = 10, .top = 45, .right = 111, .bottom = 46 };
    const want_down: TestGrab = .{ .handle = .root, .across = false, .area = area, .line = across };
    for ([_]i32{ 42, 43, 44, 45, 46, 47, 48 }) |y| {
        try std.testing.expectEqual(want_down, testFind(&column, area, 80, y).?);
    }
    try std.testing.expectEqual(want_down, testFind(&column, area, 10, 45).?);
    try std.testing.expectEqual(want_down, testFind(&column, area, 110, 45).?);
    for ([_][2]i32{ .{ 80, 41 }, .{ 80, 49 }, .{ 9, 45 }, .{ 111, 45 } }) |p| {
        try std.testing.expect(testFind(&column, area, p[0], p[1]) == null);
    }
}

test "win32: in nested splits the pointer takes the divider nearest it" {
    // a | (b over c): the line between b and c starts where the one
    // between a and b ends, and their bands overlap there. A point on
    // either line takes that one; of two as near, the outer one.
    var a: TestView = .{ .name = 'a' };
    var b: TestView = .{ .name = 'b' };
    var c: TestView = .{ .name = 'c' };
    var ab = try testPair(&a, &b, .right, 0.5);
    defer ab.deinit();
    var tree = try testSplit(&ab, ab.locate(&b).?, .down, 0.5, &c);
    defer tree.deinit();
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 201, .bottom = 101 };

    // The outer line is the column at 100; the right side, 101 to 201,
    // splits at the row 50.
    const outer = testFind(&tree, area, 100, 10).?;
    try std.testing.expectEqual(TestTree.Node.Handle.root, outer.handle);
    try std.testing.expect(outer.across);
    const inner_handle = tree.nodes[TestTree.Node.Handle.root.idx()].split.right;
    const right: win32.RECT = .{ .left = 101, .top = 0, .right = 201, .bottom = 101 };
    const inner = testFind(&tree, area, 150, 50).?;
    try std.testing.expectEqual(TestGrab{
        .handle = inner_handle,
        .across = false,
        .area = right,
        .line = .{ .left = 101, .top = 50, .right = 201, .bottom = 51 },
    }, inner);

    // On the inner line a pixel from the outer one: the inner.
    try std.testing.expectEqual(inner_handle, testFind(&tree, area, 102, 50).?.handle);
    // On the outer line, level with the inner one: the outer.
    try std.testing.expectEqual(TestTree.Node.Handle.root, testFind(&tree, area, 100, 50).?.handle);
    // Two from the inner line, one from the outer: the outer.
    try std.testing.expectEqual(TestTree.Node.Handle.root, testFind(&tree, area, 101, 48).?.handle);
    // As near to both: the outer.
    try std.testing.expectEqual(TestTree.Node.Handle.root, testFind(&tree, area, 102, 48).?.handle);
    // The inner band is the right side's only: none of it left of the
    // outer line, where a's own pixels are the outer band's.
    try std.testing.expectEqual(TestTree.Node.Handle.root, testFind(&tree, area, 99, 50).?.handle);
    try std.testing.expect(testFind(&tree, area, 50, 50) == null);
}

test "win32: a band reaches 3 DIP at the window's DPI" {
    var a: TestView = .{ .name = 'a' };
    var b: TestView = .{ .name = 'b' };
    var row = try testPair(&a, &b, .right, 0.5);
    defer row.deinit();
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 400, .bottom = 100 };

    // DPI, reach: 4.5 pixels at 150% round up.
    for ([_][2]u32{ .{ 96, 3 }, .{ 144, 5 }, .{ 192, 6 } }) |c| {
        const reach = bandReach(c[0]);
        try std.testing.expectEqual(@as(i32, @intCast(c[1])), reach);
        const divider = Window.dividerWidth(c[0]);
        const line = (find(&row, area, divider, reach, .{ .x = 200, .y = 50 }) orelse
            return error.TestUnexpectedResult).line;
        try std.testing.expectEqual(divider, line.right - line.left);
        const left = line.left - reach;
        const right = line.right - 1 + reach;
        try std.testing.expect(find(&row, area, divider, reach, .{ .x = left, .y = 50 }) != null);
        try std.testing.expect(find(&row, area, divider, reach, .{ .x = right, .y = 50 }) != null);
        try std.testing.expect(find(&row, area, divider, reach, .{ .x = left - 1, .y = 50 }) == null);
        try std.testing.expect(find(&row, area, divider, reach, .{ .x = right + 1, .y = 50 }) == null);
    }
}

test "win32: a band stays inside its split's area" {
    // A split at the end of its area, or one a pixel across, draws its line
    // along the area's edge: the band does not reach past it, as no
    // divider lies beyond.
    var a: TestView = .{ .name = 'a' };
    var b: TestView = .{ .name = 'b' };
    var row = try testPair(&a, &b, .right, 0.5);
    defer row.deinit();
    const area: win32.RECT = .{ .left = 10, .top = 10, .right = 110, .bottom = 60 };

    // a squeezed to nothing: the line is the area's first column.
    row.resizeInPlace(.root, 0);
    const edge = testFind(&row, area, 10, 30).?;
    try std.testing.expectEqual(@as(i32, 10), edge.line.left);
    try std.testing.expect(testFind(&row, area, 13, 30) != null);
    try std.testing.expect(testFind(&row, area, 9, 30) == null);
    try std.testing.expect(testFind(&row, area, 7, 30) == null);

    // An area of one pixel is all line, and its band that pixel alone.
    row.resizeInPlace(.root, 0.5);
    const pixel: win32.RECT = .{ .left = 10, .top = 10, .right = 11, .bottom = 11 };
    const all = testFind(&row, pixel, 10, 10).?;
    try std.testing.expectEqual(pixel, all.line);
    for ([_][2]i32{ .{ 9, 10 }, .{ 11, 10 }, .{ 10, 9 }, .{ 10, 11 } }) |p| {
        try std.testing.expect(testFind(&row, pixel, p[0], p[1]) == null);
    }
}

test "win32: a zoomed tree has no band" {
    var a: TestView = .{ .name = 'a' };
    var b: TestView = .{ .name = 'b' };
    var row = try testPair(&a, &b, .right, 0.5);
    defer row.deinit();
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 101, .bottom = 50 };
    try std.testing.expect(testFind(&row, area, 50, 25) != null);
    row.zoom(row.locate(&a).?);
    for ([_]i32{ 47, 50, 53 }) |x| try std.testing.expect(testFind(&row, area, x, 25) == null);
}

/// For the pure tests of the drag: terminals with no window, whose least
/// extent (`Window.cellExtent`) is a cell of their own or, without a
/// core, a pixel. Static: a `Surface` is large.
const TestCells = struct {
    var a: Surface = undefined;
    var b: Surface = undefined;
    var c: Surface = undefined;
    var many: [6]Surface = undefined;

    /// `s` with a live core whose cells are `width` by `height`, or with
    /// none.
    fn set(s: *Surface, cell: ?[2]u32) void {
        const wh = cell orelse {
            s.core_state = .none;
            return;
        };
        s.core_state = .live;
        s.core_surface.size.cell = .{ .width = wh[0], .height = wh[1] };
    }

    /// `other` split off `one` in `where`, at `ratio`.
    fn pair(one: *Surface, other: *Surface, where: Window.Tree.Split.Direction, ratio: f16) !Window.Tree {
        const alloc = std.testing.allocator;
        var base: Window.Tree = try .init(alloc, one);
        defer base.deinit();
        var single: Window.Tree = try .init(alloc, other);
        defer single.deinit();
        return base.split(alloc, .root, where, ratio, &single);
    }
};

test "win32: a dragged divider keeps each terminal of a nested split a cell, at its ratio" {
    // a | (b | c), lines 2 pixels, over 202 pixels: 200 for the sides, 100
    // each. a's cells are 10 wide, b's 7 and c's 9, and the right side
    // splits at 0.8: of its 98 pixels b has 78 and c 20. Dragged right,
    // the line stops where c keeps 9 at that ratio: the right side 45
    // pixels, 43 for b and c, 34 and 9; at 44, b and c would have 34 and
    // 8. Every terminal's least added up, 18 pixels, would leave c 3.
    const s = TestCells;
    s.set(&s.a, .{ 10, 20 });
    s.set(&s.b, .{ 7, 15 });
    s.set(&s.c, .{ 9, 5 });
    var ab = try s.pair(&s.a, &s.b, .right, 0.5);
    defer ab.deinit();
    var single: Window.Tree = try .init(std.testing.allocator, &s.c);
    defer single.deinit();
    var tree = try ab.split(std.testing.allocator, ab.locate(&s.b).?, .right, 0.8, &single);
    defer tree.deinit();
    const root = Window.Tree.Node.Handle.root;
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 202, .bottom = 100 };
    try std.testing.expectEqual(78, testExtent(&tree, area, &s.b, true));
    try std.testing.expectEqual(20, testExtent(&tree, area, &s.c, true));

    const right = dragRatio(&tree, root, area, 2, 5000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(155, Window.firstExtent(200, right));
    tree.resizeInPlace(root, right);
    try std.testing.expectEqual(34, testExtent(&tree, area, &s.b, true));
    try std.testing.expectEqual(9, testExtent(&tree, area, &s.c, true));

    // Dragged left from there, the line stops at a's 10 pixels.
    const left = dragRatio(&tree, root, area, 2, -50) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(10, Window.firstExtent(200, left));

    // b over c instead: each has the right side's whole width, so it stops
    // at the wider of their cells, c's 9.
    var across = try ab.split(std.testing.allocator, ab.locate(&s.b).?, .down, 0.8, &single);
    defer across.deinit();
    const below = dragRatio(&across, root, area, 2, 5000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(191, Window.firstExtent(200, below));
}

test "win32: a dragged divider keeps each side its least, as near as an f16 lays it" {
    const s = TestCells;
    s.set(&s.a, .{ 10, 20 });
    s.set(&s.b, null);
    var row = try s.pair(&s.a, &s.b, .right, 0.5);
    defer row.deinit();
    const root = Window.Tree.Node.Handle.root;

    // a | b over 101 pixels and a line of 1: 100 for the sides, 50 each.
    const wide: win32.RECT = .{ .left = 0, .top = 0, .right = 101, .bottom = 40 };
    try std.testing.expectEqual(30, Window.firstExtent(100, dragRatio(&row, root, wide, 1, 30).?));
    // Where the line is already: null.
    try std.testing.expect(dragRatio(&row, root, wide, 1, 50) == null);
    // Short of a's cell, a's cell; past all but b's pixel, that.
    try std.testing.expectEqual(10, Window.firstExtent(100, dragRatio(&row, root, wide, 1, 3).?));
    try std.testing.expectEqual(10, Window.firstExtent(100, dragRatio(&row, root, wide, 1, -50).?));
    try std.testing.expectEqual(99, Window.firstExtent(100, dragRatio(&row, root, wide, 1, 200).?));

    // In 15 pixels, 7 each, a is already narrower than its cell: as
    // `Window.adopt` keeps it, it may grow but not shrink. With b's cells
    // as wide, neither may shrink, so the line stays.
    const narrow: win32.RECT = .{ .left = 0, .top = 0, .right = 15, .bottom = 40 };
    try std.testing.expect(dragRatio(&row, root, narrow, 1, 0) == null);
    try std.testing.expectEqual(13, Window.firstExtent(14, dragRatio(&row, root, narrow, 1, 20).?));
    s.set(&s.b, .{ 10, 20 });
    for ([_]i32{ 0, 4, 7, 10, 14 }) |first| {
        try std.testing.expect(dragRatio(&row, root, narrow, 1, first) == null);
    }

    // a over b: down, by the cells' height.
    var column = try s.pair(&s.a, &s.b, .down, 0.5);
    defer column.deinit();
    const tall: win32.RECT = .{ .left = 0, .top = 0, .right = 40, .bottom = 101 };
    try std.testing.expectEqual(20, Window.firstExtent(100, dragRatio(&column, root, tall, 1, 0).?));
    try std.testing.expectEqual(80, Window.firstExtent(100, dragRatio(&column, root, tall, 1, 95).?));

    // Over 3840 pixels for the sides, an f16 ratio lays a side out at
    // places up to 2 pixels apart: each wanted width is given to within a
    // pixel, and never past either side's least.
    s.set(&s.a, null);
    s.set(&s.b, null);
    const screen: win32.RECT = .{ .left = 0, .top = 0, .right = 3841, .bottom = 40 };
    var first: i32 = -5;
    while (first <= 3845) : (first += 1) {
        const want = std.math.clamp(first, 1, 3839);
        const laid = if (dragRatio(&row, root, screen, 1, first)) |r| Window.firstExtent(3840, r) else 1920;
        try std.testing.expect(laid >= 1 and laid <= 3839);
        try std.testing.expect(@abs(laid - want) <= 1);
    }

    // A side's least at a width no f16 ratio lays out, whose nearest ratio
    // lays out the pixel past it: the line stops a pixel short instead.
    // b's cell leaves a at most `over`, where the nearest is a pixel wider:
    // dragged right from a quarter, the line stops a pixel narrower.
    const over = try testGap(3840, 1);
    s.set(&s.b, .{ @intCast(3840 - over), 1 });
    row.resizeInPlace(root, 0.25);
    const short = dragRatio(&row, root, screen, 1, 5000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(over - 1, Window.firstExtent(3840, short));
    // a's cell is `under`, where the nearest is a pixel narrower: dragged
    // left from three quarters, the line stops a pixel wider.
    const under = try testGap(3840, -1);
    s.set(&s.a, .{ @intCast(under), 1 });
    s.set(&s.b, null);
    row.resizeInPlace(root, 0.75);
    const wider = dragRatio(&row, root, screen, 1, -50) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(under + 1, Window.firstExtent(3840, wider));
}

test "win32: a drag's places for its line are those adopt's check allows" {
    // Random trees of up to six terminals, with random ratios, cells (or
    // no core), areas and DPIs. For a random split of each, the places
    // `dragRange` finds by halving are exactly the first sides, from 0 to
    // all of it, that `Window.keepsCells`, the check `Window.adopt` makes
    // of a resize, allows for the whole tree with that split's ratio laying
    // that side out; and the line goes where `dragRatio` is asked, as near
    // as those places allow. Areas stay under 2048 pixels, where every
    // first side has a ratio that lays it out.
    const alloc = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5333_5231);
    const random = prng.random();
    const Handle = Window.Tree.Node.Handle;
    var cases: usize = 0;
    var inside: usize = 0;
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        const n = random.intRangeAtMost(usize, 2, TestCells.many.len);
        for (TestCells.many[0..n]) |*leaf| {
            TestCells.set(leaf, if (random.uintLessThan(u8, 3) == 0) null else .{
                random.intRangeAtMost(u32, 1, 30),
                random.intRangeAtMost(u32, 1, 40),
            });
        }
        var tree = try testRandomTree(random, TestCells.many[0..n]);
        defer tree.deinit();
        const area: win32.RECT = .{
            .left = random.intRangeAtMost(i32, -50, 50),
            .top = random.intRangeAtMost(i32, -50, 50),
            .right = 0,
            .bottom = 0,
        };
        var whole = area;
        whole.right = area.left + random.intRangeAtMost(i32, 1, 600);
        whole.bottom = area.top + random.intRangeAtMost(i32, 1, 600);
        const dpis = [_]u32{ 96, 120, 144, 192, 288 };
        const divider = Window.dividerWidth(dpis[random.uintLessThan(usize, dpis.len)]);

        // A split, if it has a line to drag.
        var splits: [TestCells.many.len]Handle = undefined;
        var count: usize = 0;
        for (tree.nodes, 0..) |node, i| if (node == .split) {
            splits[count] = Handle.root.offset(i);
            count += 1;
        };
        const handle = splits[random.uintLessThan(usize, count)];
        var found: AreaOf = .{ .handle = handle };
        Window.layout(&tree, whole, divider, &found);
        const split = found.area orelse continue;
        cases += 1;

        const range = dragRange(&tree, handle, split, divider);
        try std.testing.expect(range.lo <= range.now and range.now <= range.hi);
        if (range.lo > 0 and range.lo < range.hi and range.hi < range.rest) inside += 1;

        // The ratio that first lays out each side, ratios rising.
        var ratios: [2049]?f16 = @splat(null);
        var bits: u16 = 0;
        while (bits <= 0x3C00) : (bits += 1) {
            const r: f16 = @bitCast(bits);
            const p: usize = @intCast(Window.firstExtent(range.rest, r));
            if (ratios[p] == null) ratios[p] = r;
        }
        var moved = try tree.clone(alloc);
        defer moved.deinit();
        var p: i32 = 0;
        while (p <= range.rest) : (p += 1) {
            const r = ratios[@intCast(p)] orelse return error.TestUnexpectedResult;
            moved.resizeInPlace(handle, r);
            const allowed = range.lo <= p and p <= range.hi;
            try std.testing.expectEqual(Window.keepsCells(&tree, &moved, whole, divider), allowed);
        }

        const want = random.intRangeAtMost(i32, -20, range.rest + 20);
        const to = std.math.clamp(want, range.lo, range.hi);
        if (dragRatio(&tree, handle, split, divider, want)) |r| {
            try std.testing.expectEqual(to, Window.firstExtent(range.rest, r));
        } else {
            try std.testing.expectEqual(range.now, to);
        }
    }
    // Most rounds drag a line, and many of those stop short of both ends.
    try std.testing.expect(cases > 200);
    try std.testing.expect(inside > cases / 4);
}

/// For the pure tests: `leaves` in a tree, each split off a random one
/// before it in a random direction, and every split at a random ratio,
/// either end included.
fn testRandomTree(random: std.Random, leaves: []Surface) !Window.Tree {
    const alloc = std.testing.allocator;
    var tree: Window.Tree = try .init(alloc, &leaves[0]);
    errdefer tree.deinit();
    for (leaves[1..]) |*leaf| {
        var pick: Window.Tree.Node.Handle = .root;
        var seen: usize = 0;
        var it = tree.iterator();
        while (it.next()) |entry| {
            seen += 1;
            if (random.uintLessThan(usize, seen) == 0) pick = entry.handle;
        }
        var single: Window.Tree = try .init(alloc, leaf);
        defer single.deinit();
        const next = try tree.split(alloc, pick, random.enumValue(Window.Tree.Split.Direction), 0.5, &single);
        tree.deinit();
        tree = next;
    }
    for (tree.nodes, 0..) |node, i| if (node == .split) {
        const ratio: f16 = switch (random.uintLessThan(u8, 8)) {
            0 => 0,
            1 => 1,
            else => @floatCast(random.float(f32)),
        };
        tree.resizeInPlace(Window.Tree.Node.Handle.root.offset(i), ratio);
    };
    return tree;
}

/// For the pure tests: how wide (`across`) or high `surface` is where
/// `Window.layout` puts it in `area`, with lines 2 pixels wide.
fn testExtent(tree: *const Window.Tree, area: win32.RECT, surface: *Surface, across: bool) i32 {
    const Of = struct {
        surface: *Surface,
        rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

        pub fn pane(self: *@This(), view: *Surface, rect: win32.RECT) void {
            if (view == self.surface) self.rect = rect;
        }

        pub fn hidden(self: *@This(), view: *Surface) void {
            _ = self;
            _ = view;
        }

        pub fn divider(
            self: *@This(),
            handle: Window.Tree.Node.Handle,
            line: win32.RECT,
            a: bool,
            in: win32.RECT,
        ) void {
            _ = self;
            _ = handle;
            _ = line;
            _ = a;
            _ = in;
        }
    };
    var of: Of = .{ .surface = surface };
    Window.layout(tree, area, 2, &of);
    return if (across) of.rect.right - of.rect.left else of.rect.bottom - of.rect.top;
}

/// For the tests: a first side of `rest` pixels, above half of it, that no
/// f16 ratio lays out, while the f16 nearest its share lays out the pixel
/// `side` past it (1 or -1).
fn testGap(rest: i32, side: i32) !i32 {
    var k = @divTrunc(rest, 2) + 1;
    while (k < rest) : (k += 1) {
        if (laysOut(rest, k)) continue;
        const nearest: f16 = @floatCast(@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(rest)));
        if (Window.firstExtent(rest, nearest) == k + side) return k;
    }
    return error.TestUnexpectedResult;
}

/// For the tests: whether some f16 ratio gives a first side of `width` of
/// `rest` pixels (`Window.firstExtent`).
fn laysOut(rest: i32, width: i32) bool {
    var ratio: f16 = 0;
    while (ratio < 1) : (ratio = std.math.nextAfter(f16, ratio, 1)) {
        if (Window.firstExtent(rest, ratio) == width) return true;
    }
    return Window.firstExtent(rest, 1) == width;
}
