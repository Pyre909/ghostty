//! A window's tab overview, as GTK's AdwTabOverview and macOS's own show
//! one for `toggle_tab_overview`: every tab of the window as a card, in
//! the tabs' order, with a field that narrows them by title or directory,
//! and a "+" for a new tab. A card is chosen with the arrows and Enter or
//! a click, and closed with its "×", a middle click or Delete.
//!
//! This part is the layout, the hit testing, the movement through the
//! grid, the filter and what each key in the field does: pure functions,
//! so that they can be tested on any input.

const std = @import("std");
const Allocator = std.mem.Allocator;

const win32 = @import("win32.zig");
const CommandPalette = @import("CommandPalette.zig");

const RECT = win32.RECT;

/// The overview's sizes at a DPI.
pub const Metrics = struct {
    /// Around the header and the grid.
    pad: i32,
    /// Between two cards, either way.
    gap: i32,
    /// The header's height: the field, and the "+" at its right, square.
    header: i32,
    /// The least and the most a card is wide.
    card_min: i32,
    card_max: i32,
    /// The row under a card's preview, with its title.
    title: i32,
    /// The close glyph's box, square, at the right of the title row.
    close: i32,
    /// Between the title row's edges and what is in it.
    inset: i32,
    /// How thick the selection's ring is.
    ring: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .pad = scale(16, dpi),
            .gap = scale(12, dpi),
            .header = scale(32, dpi),
            .card_min = scale(200, dpi),
            .card_max = scale(340, dpi),
            .title = scale(28, dpi),
            .close = scale(18, dpi),
            .inset = scale(8, dpi),
            .ring = scale(2, dpi),
        };
    }

    fn scale(v: i32, dpi: u32) i32 {
        const base: i32 = @intCast(win32.USER_DEFAULT_SCREEN_DPI);
        return @divTrunc(v * @as(i32, @intCast(dpi)) + @divTrunc(base, 2), base);
    }
};

/// What a point of the overview is over. A card is named by its place
/// among those shown, which the filter chooses.
pub const Hit = union(enum) {
    none,
    card: usize,
    close: usize,
    plus,
};

/// Where `count` cards go in an overview `width` by `height`, scrolled
/// down by `scroll`.
pub const Layout = struct {
    m: Metrics,
    count: usize,
    width: i32,
    height: i32,
    columns: usize,
    card_width: i32,
    preview_height: i32,
    /// How far the grid can scroll: 0 when its rows fit.
    max_scroll: i32,
    scroll: i32,

    /// Null where the header and one card of the least size do not fit:
    /// the overview is then not shown.
    pub fn init(m: Metrics, count: usize, width: i32, height: i32, scroll: i32) ?Layout {
        const room = width - 2 * m.pad;
        if (room < m.card_min) return null;
        if (height < gridTop(m) + previewHeight(m.card_min) + m.title + m.pad) return null;

        // As many columns as fit at the least width, and no more than
        // there are cards; the cards then take the room, up to the most.
        const fit: usize = @intCast(@divTrunc(room + m.gap, m.card_min + m.gap));
        const columns = @max(1, @min(fit, @max(count, 1)));
        const n: i32 = @intCast(columns);
        const card_width = @min(m.card_max, @divTrunc(room - m.gap * (n - 1), n));
        var self: Layout = .{
            .m = m,
            .count = count,
            .width = width,
            .height = height,
            .columns = columns,
            .card_width = card_width,
            .preview_height = previewHeight(card_width),
            .max_scroll = 0,
            .scroll = 0,
        };
        const n_rows: i32 = @intCast(self.rows());
        const content = n_rows * self.cardHeight() + @max(0, n_rows - 1) * m.gap + m.pad;
        self.max_scroll = @max(0, content - (height - gridTop(m)));
        self.scroll = std.math.clamp(scroll, 0, self.max_scroll);
        return self;
    }

    /// A preview is 16 by 10, about a terminal window's shape.
    fn previewHeight(card_width: i32) i32 {
        return @divTrunc(card_width * 10, 16);
    }

    fn gridTop(m: Metrics) i32 {
        return 2 * m.pad + m.header;
    }

    pub fn cardHeight(self: Layout) i32 {
        return self.preview_height + self.m.title;
    }

    pub fn rows(self: Layout) usize {
        return (self.count + self.columns - 1) / self.columns;
    }

    /// The rows a page key moves by: those that fit whole, at least one.
    pub fn pageRows(self: Layout) usize {
        const view = self.height - gridTop(self.m);
        return @intCast(@max(1, @divTrunc(view + self.m.gap, self.cardHeight() + self.m.gap)));
    }

    /// The grid's part of the overview, which the cards are clipped to.
    pub fn gridRect(self: Layout) RECT {
        return .{ .left = 0, .top = gridTop(self.m), .right = self.width, .bottom = self.height };
    }

    /// Card `i`'s place, which may be above or below what shows.
    pub fn cardRect(self: Layout, i: usize) RECT {
        const col: i32 = @intCast(i % self.columns);
        const row: i32 = @intCast(i / self.columns);
        const left = self.m.pad + col * (self.card_width + self.m.gap);
        const top = gridTop(self.m) + row * (self.cardHeight() + self.m.gap) - self.scroll;
        return .{ .left = left, .top = top, .right = left + self.card_width, .bottom = top + self.cardHeight() };
    }

    pub fn previewRect(self: Layout, i: usize) RECT {
        var r = self.cardRect(i);
        r.bottom = r.top + self.preview_height;
        return r;
    }

    pub fn titleRect(self: Layout, i: usize) RECT {
        var r = self.cardRect(i);
        r.top += self.preview_height;
        return r;
    }

    pub fn closeRect(self: Layout, i: usize) RECT {
        const t = self.titleRect(i);
        const right = t.right - self.m.inset;
        const top = t.top + @divTrunc(self.m.title - self.m.close, 2);
        return .{ .left = right - self.m.close, .top = top, .right = right, .bottom = top + self.m.close };
    }

    pub fn plusRect(self: Layout) RECT {
        const right = self.width - self.m.pad;
        return .{ .left = right - self.m.header, .top = self.m.pad, .right = right, .bottom = self.m.pad + self.m.header };
    }

    /// The field's box, from the left edge to the "+".
    pub fn fieldRect(self: Layout) RECT {
        return .{
            .left = self.m.pad,
            .top = self.m.pad,
            .right = self.plusRect().left - self.m.gap,
            .bottom = self.m.pad + self.m.header,
        };
    }

    pub fn hit(self: Layout, x: i32, y: i32) Hit {
        if (contains(self.plusRect(), x, y)) return .plus;
        if (!contains(self.gridRect(), x, y)) return .none;
        for (0..self.count) |i| {
            if (!contains(self.cardRect(i), x, y)) continue;
            return if (contains(self.closeRect(i), x, y)) .{ .close = i } else .{ .card = i };
        }
        return .none;
    }

    /// Whether any of card `i` shows.
    pub fn visible(self: Layout, i: usize) bool {
        const r = self.cardRect(i);
        return r.bottom > gridTop(self.m) and r.top < self.height;
    }

    /// The scroll that shows all of card `i`, moved the least from the
    /// one there is; its top, where the card is taller than the grid.
    pub fn scrollToShow(self: Layout, i: usize) i32 {
        const r = self.cardRect(i);
        const top = gridTop(self.m);
        var scroll = self.scroll;
        if (r.bottom + self.m.pad > self.height) scroll += r.bottom + self.m.pad - self.height;
        if (r.top - (scroll - self.scroll) < top) scroll = self.scroll + r.top - top;
        return std.math.clamp(scroll, 0, self.max_scroll);
    }
};

fn contains(r: RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

/// A move of the selection through the grid.
pub const Dir = enum { left, right, up, down, next, previous, page_up, page_down };

/// The card selected after `dir` from `selected`, of `count` cards in
/// `columns` columns, a page being `page` rows. The arrows stop at the
/// grid's edges, and down from above a last row that is short goes to
/// its last card; Tab's two go round.
pub fn step(selected: usize, dir: Dir, columns: usize, count: usize, page: usize) usize {
    if (count == 0) return 0;
    const at = @min(selected, count - 1);
    const last_row = (count - 1) / columns;
    const row = at / columns;
    return switch (dir) {
        .left => at -| 1,
        .right => @min(at + 1, count - 1),
        .next => if (at + 1 == count) 0 else at + 1,
        .previous => if (at == 0) count - 1 else at - 1,
        .up, .page_up => at - columns * @min(row, if (dir == .up) 1 else page),
        .down, .page_down => @min(
            at + columns * @min(last_row - row, if (dir == .down) 1 else page),
            count - 1,
        ),
    };
}

/// What the filter reads of a tab.
pub const Card = struct {
    title: []const u8,
    /// The directory of the tab's focused terminal, or none known.
    pwd: ?[]const u8 = null,
};

/// The cards a query leaves, in their order, into `out`: those whose
/// title or directory holds it, ignoring case as the palette's filter
/// does (`CommandPalette.fold`). An empty query leaves all.
pub fn filter(
    alloc: Allocator,
    cards: []const Card,
    query: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(alloc, cards.len);
    const needle = try CommandPalette.fold(alloc, query);
    defer alloc.free(needle);
    for (cards, 0..) |card, i| {
        if (try holds(alloc, card.title, needle) or
            (card.pwd != null and try holds(alloc, card.pwd.?, needle)))
            out.appendAssumeCapacity(@intCast(i));
    }
}

fn holds(alloc: Allocator, text: []const u8, needle: []const u8) Allocator.Error!bool {
    if (needle.len == 0) return true;
    const folded = try CommandPalette.fold(alloc, text);
    defer alloc.free(folded);
    return std.mem.indexOf(u8, folded, needle) != null;
}

/// What a key pressed in the field does.
pub const Key = union(enum) {
    /// The field's own: it edits the query, or moves its caret.
    edit,
    move: Dir,
    /// Show the selected card's tab, and close the overview.
    choose,
    /// Close the selected card's tab.
    close_tab,
    /// Empty the field.
    clear,
    /// Close the overview.
    dismiss,
};

/// What `vk` does in the field, with Shift down or not, and the field
/// empty or not. The arrows are the grid's, as the field is one line
/// and its query short. Escape empties a query before it closes the
/// overview, and Delete closes a tab only while there is no query for
/// it to edit: a click can have put the caret before its end.
///
/// Keys with Ctrl or Alt are not asked about: they are bindings
/// (overlay_keys.zig) or the field's own.
pub fn fieldKey(vk: win32.WPARAM, shift: bool, field_empty: bool) Key {
    return switch (vk) {
        win32.VK_RETURN => .choose,
        win32.VK_ESCAPE => if (field_empty) .dismiss else .clear,
        win32.VK_DELETE => if (field_empty) .close_tab else .edit,
        win32.VK_TAB => .{ .move = if (shift) .previous else .next },
        win32.VK_LEFT => .{ .move = .left },
        win32.VK_RIGHT => .{ .move = .right },
        win32.VK_UP => .{ .move = .up },
        win32.VK_DOWN => .{ .move = .down },
        win32.VK_PRIOR => .{ .move = .page_up },
        win32.VK_NEXT => .{ .move = .page_down },
        else => .edit,
    };
}

test "win32: the tab overview's cards fill columns by its width, and scroll by rows" {
    const testing = std.testing;
    const m = Metrics.init(96);

    // Too narrow for a card, or too short for the header and one.
    try testing.expectEqual(null, Layout.init(m, 3, 2 * m.pad + m.card_min - 1, 600, 0));
    const least = 2 * m.pad + m.header + @divTrunc(m.card_min * 10, 16) + m.title + m.pad;
    try testing.expectEqual(null, Layout.init(m, 3, 800, least - 1, 0));
    try testing.expect(Layout.init(m, 3, 2 * m.pad + m.card_min, least, 0) != null);

    // 800 wide: 768 of room holds three cards of 200 with two gaps of
    // 12, and not four; each is then (768 - 24) / 3 wide.
    var l = Layout.init(m, 7, 800, 600, 0).?;
    try testing.expectEqual(3, l.columns);
    try testing.expectEqual(248, l.card_width);
    try testing.expectEqual(155, l.preview_height);
    try testing.expectEqual(3, l.rows());
    try testing.expectEqual(RECT{ .left = 16, .top = 64, .right = 264, .bottom = 247 }, l.cardRect(0));
    try testing.expectEqual(RECT{ .left = 276, .top = 64, .right = 524, .bottom = 247 }, l.cardRect(1));
    try testing.expectEqual(RECT{ .left = 16, .top = 259, .right = 264, .bottom = 442 }, l.cardRect(3));
    try testing.expectEqual(RECT{ .left = 16, .top = 64, .right = 264, .bottom = 219 }, l.previewRect(0));
    try testing.expectEqual(RECT{ .left = 16, .top = 219, .right = 264, .bottom = 247 }, l.titleRect(0));
    try testing.expectEqual(RECT{ .left = 238, .top = 224, .right = 256, .bottom = 242 }, l.closeRect(0));
    try testing.expectEqual(RECT{ .left = 752, .top = 16, .right = 784, .bottom = 48 }, l.plusRect());
    try testing.expectEqual(RECT{ .left = 16, .top = 16, .right = 740, .bottom = 48 }, l.fieldRect());

    // Three rows of 183 with two gaps and the pad under them are 589,
    // and 536 show.
    try testing.expectEqual(53, l.max_scroll);
    try testing.expectEqual(2, l.pageRows());
    try testing.expectEqual(53, Layout.init(m, 7, 800, 600, 1000).?.scroll);
    try testing.expectEqual(0, Layout.init(m, 7, 800, 600, -5).?.scroll);

    // No more columns than cards, and a card no wider than its most.
    l = Layout.init(m, 2, 1600, 600, 0).?;
    try testing.expectEqual(2, l.columns);
    try testing.expectEqual(m.card_max, l.card_width);
    try testing.expectEqual(0, l.max_scroll);
    // None at all: one column, nothing to hit.
    l = Layout.init(m, 0, 800, 600, 0).?;
    try testing.expectEqual(1, l.columns);
    try testing.expectEqual(0, l.rows());
    try testing.expectEqual(Hit.none, l.hit(20, 70));

    // At 144 DPI everything is half as large again.
    const big = Metrics.init(144);
    try testing.expectEqual(24, big.pad);
    try testing.expectEqual(300, big.card_min);
    l = Layout.init(big, 7, 1200, 900, 0).?;
    try testing.expectEqual(3, l.columns);
    try testing.expectEqual(372, l.card_width);
}

test "win32: a point of the tab overview is a card, its close, the new tab button or nothing" {
    const testing = std.testing;
    const m = Metrics.init(96);
    var l = Layout.init(m, 7, 800, 600, 0).?;
    try testing.expectEqual(Hit{ .card = 0 }, l.hit(16, 64));
    try testing.expectEqual(Hit{ .card = 0 }, l.hit(263, 246));
    try testing.expectEqual(Hit{ .card = 1 }, l.hit(276, 64));
    try testing.expectEqual(Hit{ .card = 3 }, l.hit(100, 300));
    // Between two cards, and under the last row's one card.
    try testing.expectEqual(Hit.none, l.hit(270, 100));
    try testing.expectEqual(Hit.none, l.hit(100, 250));
    try testing.expectEqual(Hit.none, l.hit(300, 500));
    try testing.expectEqual(Hit{ .card = 6 }, l.hit(100, 500));
    // The close glyph's box, to its edges.
    try testing.expectEqual(Hit{ .close = 0 }, l.hit(238, 224));
    try testing.expectEqual(Hit{ .close = 0 }, l.hit(255, 241));
    try testing.expectEqual(Hit{ .card = 0 }, l.hit(237, 224));
    try testing.expectEqual(Hit{ .card = 0 }, l.hit(256, 241));
    try testing.expectEqual(Hit.plus, l.hit(760, 30));
    try testing.expectEqual(Hit.none, l.hit(100, 30));

    // Scrolled, a card's part under the header is not it.
    l = Layout.init(m, 7, 800, 600, 53).?;
    try testing.expectEqual(RECT{ .left = 16, .top = 11, .right = 264, .bottom = 194 }, l.cardRect(0));
    try testing.expectEqual(Hit.none, l.hit(100, 40));
    try testing.expectEqual(Hit{ .card = 0 }, l.hit(100, 64));
    try testing.expect(l.visible(0));
    try testing.expect(l.visible(6));

    // A grid of one row showing: the rest are not visible, and the
    // scroll that shows one moves no more than it must.
    l = Layout.init(m, 12, 800, 300, 0).?;
    try testing.expect(l.visible(0) and l.visible(3) and !l.visible(6));
    try testing.expectEqual(0, l.scrollToShow(0));
    // Card 3's bottom, 442, and the pad under it reach 458 of 300.
    try testing.expectEqual(158, l.scrollToShow(3));
    l = Layout.init(m, 12, 800, 300, 400).?;
    // From below: its top, 259, comes to the grid's, 64.
    try testing.expectEqual(195, l.scrollToShow(3));
    // Card 6's top is 10 above the grid's; once there, it stays.
    try testing.expectEqual(390, l.scrollToShow(6));
    try testing.expectEqual(390, Layout.init(m, 12, 800, 300, 390).?.scrollToShow(6));
    try testing.expectEqual(l.max_scroll, l.scrollToShow(11));
}

test "win32: the tab overview's selection moves by the arrows within the grid, and by Tab around it" {
    const testing = std.testing;
    // 0 1 2
    // 3 4 5
    // 6
    const Case = struct { usize, Dir, usize };
    for ([_]Case{
        .{ 0, .left, 0 },      .{ 1, .left, 0 },     .{ 3, .left, 2 },
        .{ 2, .right, 3 },     .{ 6, .right, 6 },    .{ 0, .up, 0 },
        .{ 2, .up, 2 },        .{ 4, .up, 1 },       .{ 6, .up, 3 },
        .{ 0, .down, 3 },      .{ 3, .down, 6 },     .{ 4, .down, 6 },
        .{ 5, .down, 6 },      .{ 6, .down, 6 },     .{ 6, .next, 0 },
        .{ 0, .next, 1 },      .{ 0, .previous, 6 }, .{ 4, .previous, 3 },
        .{ 6, .page_up, 0 },   .{ 5, .page_up, 2 },  .{ 0, .page_down, 6 },
        .{ 1, .page_down, 6 }, .{ 2, .page_up, 2 },  .{ 6, .page_down, 6 },
        // Past the end, as after a tab closed: from the last.
        .{ 9, .left, 5 },      .{ 9, .up, 3 },
    }) |case| {
        errdefer std.debug.print("from {} {t}\n", .{ case[0], case[1] });
        try testing.expectEqual(case[2], step(case[0], case[1], 3, 7, 2));
    }
    // A page of one row is the arrow's step.
    try testing.expectEqual(3, step(6, .page_up, 3, 7, 1));
    try testing.expectEqual(3, step(0, .page_down, 3, 7, 1));

    // No move leaves the grid, whatever its shape.
    for (1..5) |columns| for (0..10) |count| for (0..12) |from| {
        for (std.enums.values(Dir)) |dir| {
            const to = step(from, dir, columns, count, 2);
            try testing.expect(to < @max(count, 1));
        }
    };
}

test "win32: the tab overview's filter keeps the tabs whose title or directory holds the query" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cards = [_]Card{
        .{ .title = "build", .pwd = "C:\\src\\ghostty" },
        .{ .title = "Logs" },
        .{ .title = "ÉDITEUR", .pwd = "C:\\Users\\me" },
        .{ .title = "vim notes.txt", .pwd = "C:\\src\\Logs" },
    };
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(alloc);

    try filter(alloc, &cards, "", &out);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, out.items);
    // In the title or the directory, in the tabs' order, either case.
    try filter(alloc, &cards, "LOG", &out);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, out.items);
    try filter(alloc, &cards, "src", &out);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, out.items);
    try filter(alloc, &cards, "éd", &out);
    try testing.expectEqualSlices(u32, &.{2}, out.items);
    try filter(alloc, &cards, "nothing", &out);
    try testing.expectEqualSlices(u32, &.{}, out.items);
}

test "win32: a key in the tab overview's field moves the selection, chooses, closes or edits" {
    const testing = std.testing;
    const Case = struct { win32.WPARAM, bool, bool, Key };
    for ([_]Case{
        .{ win32.VK_RETURN, false, true, .choose },
        .{ win32.VK_RETURN, false, false, .choose },
        .{ win32.VK_ESCAPE, false, true, .dismiss },
        .{ win32.VK_ESCAPE, false, false, .clear },
        .{ win32.VK_DELETE, false, true, .close_tab },
        .{ win32.VK_DELETE, false, false, .edit },
        .{ win32.VK_TAB, false, true, .{ .move = .next } },
        .{ win32.VK_TAB, true, true, .{ .move = .previous } },
        .{ win32.VK_LEFT, false, false, .{ .move = .left } },
        .{ win32.VK_RIGHT, false, false, .{ .move = .right } },
        .{ win32.VK_UP, false, false, .{ .move = .up } },
        .{ win32.VK_DOWN, true, false, .{ .move = .down } },
        .{ win32.VK_PRIOR, false, false, .{ .move = .page_up } },
        .{ win32.VK_NEXT, false, false, .{ .move = .page_down } },
        .{ win32.VK_HOME, false, false, .edit },
        .{ 'A', false, true, .edit },
        .{ win32.VK_BACK, false, false, .edit },
    }) |case| {
        try testing.expectEqual(case[3], fieldKey(case[0], case[1], case[2]));
    }
}
