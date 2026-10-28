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

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const Window = @import("Window.zig");
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
