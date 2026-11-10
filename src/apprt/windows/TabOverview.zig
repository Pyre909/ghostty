//! A window's tab overview, as GTK's AdwTabOverview and macOS's own show
//! one for `toggle_tab_overview`: every tab of the window as a card, in
//! the tabs' order, with a field that narrows them by title or directory,
//! and a "+" for a new tab. A card is chosen with the arrows and Enter or
//! a click, and closed with its "×", a middle click or Delete.
//!
//! The layout, the hit testing, the movement through the grid, the filter
//! and what each key in the field does are pure functions, so that they
//! can be tested on any input; the window that shows them follows.
//!
//! A card's preview is its terminal's background, with nothing of its
//! screen: a hidden tab's terminals have no frame to copy, and to draw
//! one they would have to be told they show.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const CommandPalette = @import("CommandPalette.zig");
const SearchBar = @import("SearchBar.zig");
const Transparency = @import("Transparency.zig");
const overlay_keys = @import("overlay_keys.zig");
const messageFont = @import("TabBar.zig").messageFont;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const utf8FromWide = @import("clipboard.zig").utf8FromWide;
const Question = @import("dialog.zig").Question;

const RECT = win32.RECT;
const L = win32.L;

const log = std.log.scoped(.win32);

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

    const scale = SearchBar.Metrics.scale;
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

    /// A card's height: its preview and its title's line.
    pub fn cardHeight(self: Layout) i32 {
        return self.preview_height + self.m.title;
    }

    /// The rows the cards fill, the last perhaps in part.
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

    /// Card `i`'s preview, above its title.
    pub fn previewRect(self: Layout, i: usize) RECT {
        var r = self.cardRect(i);
        r.bottom = r.top + self.preview_height;
        return r;
    }

    /// Card `i`'s title line, under its preview.
    pub fn titleRect(self: Layout, i: usize) RECT {
        var r = self.cardRect(i);
        r.top += self.preview_height;
        return r;
    }

    /// Card `i`'s close glyph, at the right of its title line.
    pub fn closeRect(self: Layout, i: usize) RECT {
        const t = self.titleRect(i);
        const right = t.right - self.m.inset;
        const top = t.top + @divTrunc(self.m.title - self.m.close, 2);
        return .{ .left = right - self.m.close, .top = top, .right = right, .bottom = top + self.m.close };
    }

    /// The "+", at the right of the field.
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

    /// What the point is over. A card's close glyph comes before the
    /// card, and a card scrolled out of the grid is not hit.
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

// The overview on screen.
//
// A child window of the frame over all of its client area, the tab bar
// included, above the terminals, as the command palette is
// (CommandPalette.zig): an EDIT takes the query, and the cards and the
// "+" are drawn by the window itself. The keyboard stays in the field.
//
// One per window (`Window.overview`), made anew each time it opens. It
// keeps no tab and no terminal: what it shows is read from the window's
// tabs each time it draws or is asked something (`sync`), so a tab that
// came, went, moved or was renamed is never one it remembers, and the
// bar tells it to draw again when it does itself (`TabBar.Bar.overview`).
// The terminal's bindings that still act from a field act on the shown
// tab's focused terminal, looked up when the key comes.
//
// It closes when a card is chosen, on "+", on Escape with no query, on
// the action again, when the layout leaves no room for it, when the
// command palette or a title prompt opens, and when its window is hidden,
// minimized or goes. Not when the frame is deactivated: a tab closed from
// it may ask first, and it is still there after the answer.

/// The overview's window class, registered with the app's others.
pub const class_name = "GhosttyTabOverviewClass";

/// The field's placeholder in the user's language, for the program's
/// time, as the palette's.
pub var placeholder: Question = .{};

/// What the overview shows of a tab: its label, as the bar's
/// (`Window.labelText`), its focused terminal's directory, and the
/// shortcut of its `goto_tab`, or ""; and which tab it is (`Tab.id`).
const Shown = struct {
    id: u64,
    title: []const u8,
    pwd: ?[]const u8,
    shortcut: []const u8,
};

/// A window's tab overview (`Window.overview`): its windows while it is
/// open, none while it is closed.
pub const Overview = struct {
    /// The overview's window, a child of the frame; null while closed.
    hwnd: ?win32.HWND = null,
    /// The query, an EDIT child of `hwnd`.
    edit: ?win32.HWND = null,
    /// From `open` until `close` starts: the keyboard focus the window
    /// gives goes to the field (`focusTarget`).
    open: bool = false,
    /// The tabs as `sync` last read them, in their order, their text in
    /// `arena`; and those the query keeps, by index.
    arena: ?std.heap.ArenaAllocator = null,
    tabs: []const Shown = &.{},
    kept: std.ArrayList(u32) = .empty,
    /// The selected card, among those kept.
    selected: usize = 0,
    /// The tab the window showed at the last `sync` (`Tab.id`), 0 before
    /// the first: when another shows, the selection goes to it.
    shown_tab: u64 = 0,
    scroll: i32 = 0,
    /// What is left of a high-resolution wheel's turn, in 120ths of a
    /// pixel, as the tab bar keeps it.
    wheel_rem: i32 = 0,
    /// What the pointer is over, and what the left button went down on,
    /// which acts if the button comes up on the same. A card is a place
    /// in the grid, and the tabs may change under a held button, so the
    /// press also names its card's tab (`pressed_tab`), and acts only if
    /// that tab is still the one there. `middle` is the tab the middle
    /// button went down on, likewise.
    hover: Hit = .none,
    pressed: Hit = .none,
    pressed_tab: u64 = 0,
    middle: ?u64 = null,
    /// Whether the window has asked for the WM_MOUSELEAVE that ends
    /// `hover`.
    tracking_leave: bool = false,
    /// The system's message font at `font_dpi`, and the height of a line
    /// of it, as the search bar's.
    font: ?win32.HGDIOBJ = null,
    font_dpi: u32 = 0,
    text_height: i32 = 0,
    /// The brush the field is painted with, of `brush_color`.
    brush: ?win32.HGDIOBJ = null,
    brush_color: win32.COLORREF = 0,

    /// Where the keyboard focus the window gives goes: the field while
    /// the overview is open and shows; else null.
    pub fn focusTarget(self: *const Overview) ?win32.HWND {
        if (!self.open) return null;
        const hwnd = self.hwnd orelse return null;
        if (!SearchBar.visibleStyle(hwnd)) return null;
        return self.edit;
    }

    /// Whether the keyboard focus is in the overview now.
    fn holdsFocus(self: *const Overview) bool {
        const hwnd = self.hwnd orelse return false;
        const focus = Window.keyboardFocus() orelse return false;
        return focus == hwnd or win32.IsChild(hwnd, focus).toBool();
    }

    fn applyFont(self: *Overview, dpi: u32) void {
        if (self.font != null and self.font_dpi == dpi) return;
        const edit = self.edit orelse return;
        const font = messageFont(dpi) orelse return;
        _ = win32.SendMessageW(edit, win32.WM_SETFONT, @intFromPtr(font), 1);
        if (self.font) |old| _ = win32.DeleteObject(old);
        self.font = font;
        self.font_dpi = dpi;
        self.text_height = SearchBar.textHeight(edit, font);
    }

    fn brushOf(self: *Overview, color: win32.COLORREF) ?win32.HGDIOBJ {
        if (self.brush != null and self.brush_color == color) return self.brush;
        const brush: win32.HGDIOBJ = win32.CreateSolidBrush(color) orelse return self.brush;
        if (self.brush) |old| _ = win32.DeleteObject(old);
        self.brush = brush;
        self.brush_color = color;
        return brush;
    }

    /// The tab the selected card is, if any card is kept.
    pub fn selectedTab(self: *const Overview) ?usize {
        if (self.selected >= self.kept.items.len) return null;
        return self.kept.items[self.selected];
    }

    /// Which tab the card at `at` was at the last `sync`, 0 for none.
    fn idAt(self: *const Overview, at: usize) u64 {
        if (at >= self.kept.items.len) return 0;
        return self.tabs[self.kept.items[at]].id;
    }

    /// Which tab `hit` is on, 0 for none.
    fn idOf(self: *const Overview, hit: Hit) u64 {
        return switch (hit) {
            .card, .close => |at| self.idAt(at),
            .none, .plus => 0,
        };
    }

    /// Free everything, as its window is destroyed.
    fn free(self: *Overview, alloc: Allocator) void {
        if (self.arena) |*a| a.deinit();
        self.kept.deinit(alloc);
        if (self.font) |f| _ = win32.DeleteObject(f);
        if (self.brush) |b| _ = win32.DeleteObject(b);
        self.* = .{};
    }
};

/// `toggle_tab_overview` on `surface`, carried out by `run`
/// (`App.Request.overview`): its window's overview closes if it is open,
/// else opens, as GTK's toggles its window's.
pub fn toggle(surface: *Surface) void {
    const window = surface.window;
    if (window.overview.hwnd != null) return close(window);
    _ = open(surface);
}

/// Open `surface`'s window's overview, the shown tab's card selected, and
/// give its field the keyboard focus; whether it opened. Not for a closing
/// terminal or window, nor over a title prompt, which holds the frame
/// disabled; nor where it does not fit (`place`). The window's command
/// palette closes: the two are never open together.
pub fn open(surface: *Surface) bool {
    const window = surface.window;
    const app = window.app;
    const o = &window.overview;
    if (o.hwnd != null) return true;
    if (surface.closing or window.closing) return false;
    if (window.title_prompt.hwnd != null) {
        log.info("no tab overview over a title prompt", .{});
        return false;
    }
    CommandPalette.close(window);
    const hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        null,
        win32.WS_CHILD | win32.WS_CLIPSIBLINGS | win32.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        window.hwnd,
        null,
        app.hinstance,
        window,
    ) orelse {
        log.warn("cannot make a tab overview err={}", .{win32.GetLastError()});
        return false;
    };
    // From here its WM_DESTROY frees all of it.
    o.hwnd = hwnd;
    window.bar.overview = hwnd;
    Transparency.chrome(window, hwnd);
    const edit = win32.CreateWindowExW(
        0,
        L("EDIT"),
        L(""),
        win32.WS_CHILD | win32.WS_VISIBLE | win32.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse {
        log.warn("cannot make the tab overview's field err={}", .{win32.GetLastError()});
        _ = win32.DestroyWindow(hwnd);
        return false;
    };
    o.edit = edit;
    const old_edit = win32.SetWindowLongPtrW(edit, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
    if (edit_proc == null) edit_proc = @ptrFromInt(@as(usize, @bitCast(old_edit)));
    // The search field's placeholder, shown with the focus in the field
    // too (wParam), as it always is here.
    _ = win32.SendMessageW(edit, win32.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(placeholder.one("Find\u{2026}"))));
    o.open = true;
    // No tab was shown at a sync yet, so this selects the shown one's card.
    sync(window);
    if (!place(window)) return false;
    reveal(window);
    window.setKeyboardFocus(edit, true);
    return true;
}

/// Close `window`'s overview, if it is open: the shown tab's terminal
/// gets the keyboard focus if the overview had it, then the overview's
/// window is destroyed, which frees what it held.
pub fn close(window: *Window) void {
    const o = &window.overview;
    const hwnd = o.hwnd orelse return;
    const had_focus = o.holdsFocus();
    o.open = false;
    if (had_focus) {
        if (window.tab().focused) |s| window.setKeyboardFocus(Window.focusTarget(s), true);
    }
    _ = win32.DestroyWindow(hwnd);
}

/// Draw the overview again, as the theme changed.
pub fn invalidate(window: *Window) void {
    const o = &window.overview;
    if (o.hwnd) |h| _ = win32.InvalidateRect(h, null, .FALSE);
    if (o.edit) |h| _ = win32.InvalidateRect(h, null, .TRUE);
}

/// The system's message font changed: made again and placed.
pub fn fontChanged(window: *Window) void {
    if (window.overview.hwnd == null) return;
    window.overview.font_dpi = 0;
    _ = place(window);
}

/// Read the window's tabs again, and which of them the query keeps. The
/// selection stays on its tab, wherever that tab's card now is; once the
/// tab is gone, or no longer kept, it stays on its place among the cards,
/// or the last of them, so that closing card after card with Delete goes
/// down the grid. It goes to the shown tab's card when the window shows
/// another tab than it did.
///
/// Out of memory, it shows no card until the next one: it never closes
/// here, nor moves the focus, as this runs wherever a tab changes.
fn sync(window: *Window) void {
    const o = &window.overview;
    const selected_tab = o.idAt(o.selected);
    if (o.arena) |*a| a.deinit();
    o.arena = null;
    o.tabs = &.{};
    o.kept.clearRetainingCapacity();
    read(window) catch |err| {
        log.warn("cannot list the tab overview's tabs err={}", .{err});
        if (o.arena) |*a| a.deinit();
        o.arena = null;
        o.tabs = &.{};
        o.kept.clearRetainingCapacity();
    };
    if (selected_tab != 0) {
        for (0..o.kept.items.len) |at| {
            if (o.idAt(at) == selected_tab) o.selected = at;
        }
    }
    const shown_tab = window.tab().id;
    if (shown_tab != o.shown_tab) {
        o.shown_tab = shown_tab;
        selectShown(window);
    }
    o.selected = @min(o.selected, o.kept.items.len -| 1);
}

fn read(window: *Window) !void {
    const o = &window.overview;
    const alloc = window.app.core_app.alloc;
    o.arena = .init(alloc);
    const a = o.arena.?.allocator();
    const set = &window.app.config.keybind.set;
    const tabs = try a.alloc(Shown, window.tabs.items.len);
    const cards = try a.alloc(Card, tabs.len);
    for (window.tabs.items, tabs, cards, 1..) |t, *tab, *card, number| {
        var shortcut: []const u8 = "";
        if (set.getTrigger(.{ .goto_tab = number })) |trigger| {
            var w: std.Io.Writer.Allocating = .init(a);
            if (CommandPalette.shortcutLabel(&w.writer, trigger) catch return error.OutOfMemory) shortcut = w.written();
        }
        tab.* = .{
            .id = t.id,
            .title = try window.labelText(a, t),
            .pwd = if (t.focused) |s| if (s.pwd) |pwd| try a.dupe(u8, pwd) else null else null,
            .shortcut = shortcut,
        };
        card.* = .{ .title = tab.title, .pwd = tab.pwd };
    }
    o.tabs = tabs;
    const query = try queryOf(a, o.edit);
    try filter(alloc, cards, query, &o.kept);
}

/// The field's text.
fn queryOf(alloc: Allocator, field: ?win32.HWND) ![]u8 {
    const edit = field orelse return alloc.dupe(u8, "");
    const len: usize = @intCast(@max(win32.GetWindowTextLengthW(edit), 0));
    const wide = try alloc.alloc(u16, len + 1);
    defer alloc.free(wide);
    const n: usize = @intCast(@max(win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));
    return utf8FromWide(alloc, wide[0..n]);
}

/// Select the shown tab's card, or the first if the query does not keep
/// it.
fn selectShown(window: *Window) void {
    const o = &window.overview;
    o.selected = for (o.kept.items, 0..) |index, at| {
        if (index == window.selected) break at;
    } else 0;
}

/// The cards' places in the overview's window as it is now.
pub fn layoutOf(window: *Window) ?Layout {
    const o = &window.overview;
    const hwnd = o.hwnd orelse return null;
    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) return null;
    const m: Metrics = .init(Window.dpiOf(window.app, window.hwnd));
    return .init(m, o.kept.items.len, client.right, client.bottom, o.scroll);
}

/// Scroll the grid so that the selected card shows, and draw it again.
fn reveal(window: *Window) void {
    const o = &window.overview;
    if (layoutOf(window)) |l| {
        o.scroll = if (o.kept.items.len > 0) l.scrollToShow(o.selected) else 0;
    }
    if (o.hwnd) |h| _ = win32.InvalidateRect(h, null, .FALSE);
}

/// Place `window`'s open overview over the frame's client area, above the
/// terminals and their search bars; whether it shows. One the frame has
/// no room for (`Layout.init`) closes. Called by every layout
/// (`Window.relayout`), which never runs inside a core frame.
pub fn place(window: *Window) bool {
    const o = &window.overview;
    const hwnd = o.hwnd orelse return false;
    if (!o.open) return false;
    const dpi = Window.dpiOf(window.app, window.hwnd);
    o.applyFont(dpi);
    const m: Metrics = .init(dpi);
    var client: RECT = undefined;
    if (!win32.GetClientRect(window.hwnd, &client).toBool()) return false;
    const l = Layout.init(m, o.kept.items.len, client.right, client.bottom, o.scroll) orelse {
        log.info("no room for the tab overview", .{});
        close(window);
        return false;
    };
    o.scroll = l.scroll;
    _ = win32.SetWindowPos(hwnd, win32.HWND_TOP, 0, 0, client.right, client.bottom, win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW);
    if (o.edit) |edit| {
        // A line of text, centred down the field's box.
        const box = l.fieldRect();
        const height = @min(o.text_height, box.bottom - box.top);
        const top = box.top + @divTrunc(box.bottom - box.top - height, 2);
        _ = win32.SetWindowPos(edit, null, box.left + m.inset, top, @max(0, box.right - box.left - 2 * m.inset), height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    }
    invalidate(window);
    return true;
}

/// The field's text changed (EN_CHANGE): the first card the query keeps
/// is selected, or the shown tab's when there is no query.
fn textChanged(window: *Window) void {
    const o = &window.overview;
    sync(window);
    o.selected = 0;
    const edit = o.edit orelse return;
    if (win32.GetWindowTextLengthW(edit) == 0) selectShown(window);
    o.scroll = 0;
    reveal(window);
}

/// Move the selection through the grid.
fn move(window: *Window, dir: Dir) void {
    const o = &window.overview;
    sync(window);
    const l = layoutOf(window) orelse return;
    o.selected = step(o.selected, dir, l.columns, o.kept.items.len, l.pageRows());
    reveal(window);
}

/// Show the tab at `index`, as a click on its label in the bar does
/// (`Window.clickTab`), which keeps a zoom in it, then close. In that
/// order: while the overview is open the focus stays in its field
/// (`Window.focusTarget`), so closing hands it straight to the new tab's
/// terminal. Closed first, the tab being left would get the focus for a
/// moment, which clears its bell and tells its program of a focus it
/// never had.
fn choose(window: *Window, index: usize) void {
    window.clickTab(index);
    close(window);
}

/// Close the tab at `index`, as its close glyph in the bar does: it may
/// ask first, and the last tab's takes the window with it.
fn closeTab(window: *Window, index: usize) void {
    _ = window.closeTabs(index, .this);
}

/// What `hit`, clicked, does.
fn act(window: *Window, hit: Hit) void {
    const o = &window.overview;
    switch (hit) {
        .none => {},
        .plus => {
            close(window);
            window.clickNewTab();
        },
        inline .card, .close => |at, tag| {
            if (at >= o.kept.items.len) return;
            const index = o.kept.items[at];
            if (tag == .card) choose(window, index) else closeTab(window, index);
        },
    }
}

/// The procedure every EDIT had before it was subclassed.
var edit_proc: ?win32.WNDPROC = null;

/// The window whose overview the window `hwnd` is, null once it is
/// destroyed.
fn windowOf(hwnd: win32.HWND) ?*Window {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The window whose overview holds the child `hwnd`, while it is open.
fn windowOfChild(hwnd: win32.HWND) ?*Window {
    const parent = win32.GetAncestor(hwnd, win32.GA_PARENT) orelse return null;
    const window = windowOf(parent) orelse return null;
    if (window.overview.hwnd != parent or !window.overview.open) return null;
    return window;
}

/// What the point of a mouse message is over, read from the tabs as they
/// are now.
fn hitOf(window: *Window, lparam: win32.LPARAM) Hit {
    sync(window);
    const l = layoutOf(window) orelse return .none;
    return l.hit(win32.xLparam(lparam), win32.yLparam(lparam));
}

fn setHover(window: *Window, hit: Hit) void {
    const o = &window.overview;
    if (std.meta.eql(o.hover, hit)) return;
    o.hover = hit;
    if (o.hwnd) |h| _ = win32.InvalidateRect(h, null, .FALSE);
}

/// The overview's window procedure. WM_NCCREATE brings its window.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(param)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const window = windowOf(hwnd) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const o = &window.overview;
    // Its own window only: one being destroyed after a newer one opened
    // is no longer the window's.
    const current = o.hwnd == hwnd;

    switch (msg) {
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            if (current) sync(window);
            paint(window, hwnd);
            return 0;
        },

        win32.WM_CTLCOLOREDIT => {
            const colors = SearchBar.Colors.of(window.dark_frame);
            const hdc: win32.HDC = @ptrFromInt(wparam);
            _ = win32.SetTextColor(hdc, colors.text);
            _ = win32.SetBkColor(hdc, colors.field);
            const brush = o.brushOf(colors.field) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return @bitCast(@intFromPtr(brush));
        },

        win32.WM_COMMAND => {
            if (current and o.open and win32.hiword(wparam) == win32.EN_CHANGE and o.edit != null and
                lparam == @as(win32.LPARAM, @bitCast(@intFromPtr(o.edit.?)))) textChanged(window);
            return 0;
        },

        // The wheel, which the field passes here, scrolls the grid by a
        // third of a card a notch.
        win32.WM_MOUSEWHEEL => {
            if (!current or !o.open) return 0;
            sync(window);
            const l = layoutOf(window) orelse return 0;
            const notch = @divTrunc(l.cardHeight(), 3);
            const delta: i32 = win32.wheelDelta(wparam);
            // A high-resolution wheel's fractions of a notch add up, as
            // in the tab bar; a turn the other way drops what was left.
            if (o.wheel_rem != 0 and (delta < 0) != (o.wheel_rem < 0)) o.wheel_rem = 0;
            o.wheel_rem += delta * notch;
            const pixels = @divTrunc(o.wheel_rem, win32.WHEEL_DELTA);
            o.wheel_rem -= pixels * win32.WHEEL_DELTA;
            const scroll = std.math.clamp(o.scroll - pixels, 0, l.max_scroll);
            // At either end nothing is kept for the way on.
            if (pixels != 0 and scroll == o.scroll) o.wheel_rem = 0;
            o.scroll = scroll;
            _ = win32.InvalidateRect(hwnd, null, .FALSE);
            return 0;
        },

        win32.WM_MOUSEMOVE => {
            if (!current or !o.open) return 0;
            if (!o.tracking_leave) {
                var tme: win32.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(win32.TRACKMOUSEEVENT), .dwFlags = win32.TME_LEAVE, .hwndTrack = hwnd, .dwHoverTime = 0 };
                o.tracking_leave = win32.TrackMouseEvent(&tme).toBool();
            }
            // Against the cards as last read, with no `sync`: every
            // change to them draws the overview again, and the highlight
            // names no tab.
            const hit: Hit = if (layoutOf(window)) |l| l.hit(win32.xLparam(lparam), win32.yLparam(lparam)) else .none;
            setHover(window, hit);
            return 0;
        },

        win32.WM_MOUSELEAVE => {
            o.tracking_leave = false;
            setHover(window, .none);
            return 0;
        },

        win32.WM_LBUTTONDOWN => {
            if (!current or !o.open) return 0;
            o.pressed = hitOf(window, lparam);
            o.pressed_tab = o.idOf(o.pressed);
            if (o.pressed != .none) _ = win32.SetCapture(hwnd);
            _ = win32.InvalidateRect(hwnd, null, .FALSE);
            return 0;
        },

        win32.WM_LBUTTONUP => {
            if (!current or !o.open) return 0;
            const pressed = o.pressed;
            const pressed_tab = o.pressed_tab;
            o.pressed = .none;
            if (pressed == .none) return 0;
            const hit = hitOf(window, lparam);
            const same = std.meta.eql(hit, pressed) and o.idOf(hit) == pressed_tab;
            if (o.middle == null) _ = win32.ReleaseCapture();
            _ = win32.InvalidateRect(hwnd, null, .FALSE);
            // Nothing of the overview is touched after: it may be closed.
            if (same) act(window, hit);
            return 0;
        },

        win32.WM_MBUTTONDOWN => {
            if (!current or !o.open) return 0;
            const id = o.idOf(hitOf(window, lparam));
            o.middle = if (id != 0) id else null;
            // Captured, as the tab bar's, so that its release is seen
            // wherever it comes.
            if (o.middle != null) _ = win32.SetCapture(hwnd);
            return 0;
        },

        win32.WM_MBUTTONUP => {
            if (!current or !o.open) return 0;
            const middle = o.middle orelse return 0;
            o.middle = null;
            const hit = hitOf(window, lparam);
            const same = o.idOf(hit) == middle;
            if (o.pressed == .none) _ = win32.ReleaseCapture();
            switch (hit) {
                .card, .close => |at| if (same) act(window, .{ .close = at }),
                .none, .plus => {},
            }
            return 0;
        },

        // The capture went elsewhere, to a prompt for one of the tabs or
        // to another window: neither press acts.
        win32.WM_CAPTURECHANGED => {
            if (@as(usize, @bitCast(lparam)) == @intFromPtr(hwnd)) return 0;
            o.pressed = .none;
            o.middle = null;
            return 0;
        },

        win32.WM_DESTROY => {
            if (window.bar.overview == hwnd) window.bar.overview = null;
            return 0;
        },

        // Freed here, after the field is destroyed, which has the font
        // and is painted with the brush until then.
        win32.WM_NCDESTROY => {
            if (current) o.free(window.app.core_app.alloc);
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        },

        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The field's subclass: the grid's keys (`fieldKey`), the keys an EDIT
/// gets wrong without a dialog manager, as in the search field
/// (`SearchBar.editKey`), then the terminal's bindings that still act from
/// a field (`overlay_keys`), on the shown tab's focused terminal.
fn editProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
    const proc = edit_proc.?;
    const window = windowOfChild(hwnd) orelse return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
    const o = &window.overview;

    const down = struct {
        fn f(vk: win32.WPARAM) bool {
            return win32.GetKeyState(@intCast(vk)) < 0;
        }
    }.f;
    if (msg == win32.WM_KEYDOWN and !down(win32.VK_CONTROL) and !down(win32.VK_MENU)) {
        const empty = win32.GetWindowTextLengthW(hwnd) == 0;
        switch (fieldKey(wparam, down(@intCast(win32.VK_SHIFT)), empty)) {
            .edit => {},
            .move => |dir| {
                move(window, dir);
                return 0;
            },
            // Nothing of the field is touched after either: it is
            // destroyed. The key's release is withheld from the terminal
            // that took the focus, which never saw it pressed.
            .choose => {
                sync(window);
                if (o.selectedTab()) |index| choose(window, index) else close(window);
                CommandPalette.closedByKey(window.app, lparam);
                return 0;
            },
            .dismiss => {
                close(window);
                CommandPalette.closedByKey(window.app, lparam);
                return 0;
            },
            // The field tells of its change itself (EN_CHANGE).
            .clear => {
                _ = win32.SetWindowTextW(hwnd, L(""));
                return 0;
            },
            .close_tab => {
                sync(window);
                if (o.selectedTab()) |index| closeTab(window, index);
                return 0;
            },
        }
    }
    switch (SearchBar.editKey(msg, wparam, false)) {
        // Enter and Escape with Ctrl or Alt are no key of the overview's.
        .pass, .next, .previous, .close => {},
        .swallow => return 0,
        .delete_word => {
            SearchBar.deleteWord(window.app.core_app.alloc, hwnd);
            return 0;
        },
    }
    if (window.tab().focused) |surface| {
        if (overlay_keys.keyDown(surface, hwnd, proc, msg, wparam, lparam, .overview)) return 0;
    }
    return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

/// A frame `width` thick just inside `r`.
fn frame(hdc: win32.HDC, r: RECT, width: i32, color: win32.COLORREF) void {
    SearchBar.fill(hdc, .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.top + width }, color);
    SearchBar.fill(hdc, .{ .left = r.left, .top = r.bottom - width, .right = r.right, .bottom = r.bottom }, color);
    SearchBar.fill(hdc, .{ .left = r.left, .top = r.top, .right = r.left + width, .bottom = r.bottom }, color);
    SearchBar.fill(hdc, .{ .left = r.right - width, .top = r.top, .right = r.right, .bottom = r.bottom }, color);
}

/// A plus or a cross in the middle of `r`, drawn with lines so that it is
/// the same in every font.
fn glyph(hdc: win32.HDC, r: RECT, cross: bool, color: win32.COLORREF, width: i32) void {
    const pen = win32.CreatePen(win32.PS_SOLID, width, color) orelse return;
    defer _ = win32.DeleteObject(pen);
    const old = win32.SelectObject(hdc, pen);
    defer if (old) |v| {
        _ = win32.SelectObject(hdc, v);
    };
    const cx = @divTrunc(r.left + r.right, 2);
    const cy = @divTrunc(r.top + r.bottom, 2);
    const h = @max(2, @divTrunc(r.right - r.left, 5));
    const a: [2]win32.POINT, const b: [2]win32.POINT = if (cross) .{
        .{ .{ .x = cx - h, .y = cy - h }, .{ .x = cx + h + 1, .y = cy + h + 1 } },
        .{ .{ .x = cx + h, .y = cy - h }, .{ .x = cx - h - 1, .y = cy + h + 1 } },
    } else .{
        .{ .{ .x = cx - h, .y = cy }, .{ .x = cx + h + 1, .y = cy } },
        .{ .{ .x = cx, .y = cy - h }, .{ .x = cx, .y = cy + h + 1 } },
    };
    _ = win32.Polyline(hdc, &a, a.len);
    _ = win32.Polyline(hdc, &b, b.len);
}

/// The overview: the cards, then the header over what of them scrolled
/// under it. A card is its preview, the terminals' background, over a row
/// with its label, its shortcut and its close glyph; the shown tab's is
/// framed in the system's highlight colour, and the selected one has a
/// ring around it.
fn paint(window: *Window, hwnd: win32.HWND) void {
    const o = &window.overview;
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = win32.EndPaint(hwnd, &ps);
    if (o.hwnd != hwnd) return;

    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) return;
    if (client.right <= 0 or client.bottom <= 0) return;

    // Drawn off the screen, then copied at once, so that it never flickers.
    const mem = win32.CreateCompatibleDC(hdc) orelse return;
    defer _ = win32.DeleteDC(mem);
    const bitmap = win32.CreateCompatibleBitmap(hdc, client.right, client.bottom) orelse return;
    defer _ = win32.DeleteObject(bitmap);
    const old_bitmap = win32.SelectObject(mem, bitmap);
    defer if (old_bitmap) |b| {
        _ = win32.SelectObject(mem, b);
    };

    const alloc = window.app.core_app.alloc;
    const dpi = Window.dpiOf(window.app, window.hwnd);
    const colors = SearchBar.Colors.of(window.dark_frame);
    const m: Metrics = .init(dpi);
    const line = @max(1, SearchBar.Metrics.scale(1, dpi));
    SearchBar.fill(mem, client, colors.bar);
    const l = Layout.init(m, o.kept.items.len, client.right, client.bottom, o.scroll) orelse {
        _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
        return;
    };

    _ = win32.SetBkMode(mem, win32.TRANSPARENT);
    const old_font = if (o.font) |f| win32.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = win32.SelectObject(mem, f);
    };
    const flags = win32.DT_SINGLELINE | win32.DT_NOPREFIX | win32.DT_VCENTER;
    const bg = window.app.config.background;
    const accent = win32.GetSysColor(win32.COLOR_HIGHLIGHT);

    for (o.kept.items, 0..) |index, at| {
        if (!l.visible(at) or index >= o.tabs.len) continue;
        const tab = &o.tabs[index];
        const card = l.cardRect(at);
        const hovered = switch (o.hover) {
            .card, .close => |h| h == at,
            .none, .plus => false,
        };
        if (at == o.selected) {
            const around: RECT = SearchBar.inset(card, -(m.ring + line));
            frame(mem, around, m.ring, colors.text);
        }
        SearchBar.fill(mem, l.previewRect(at), win32.rgb(bg.r, bg.g, bg.b));
        const title = l.titleRect(at);
        SearchBar.fill(mem, title, if (hovered) colors.hover else colors.field);
        frame(mem, card, line, if (index == window.selected) accent else colors.border);

        const x = l.closeRect(at);
        if (hovered or at == o.selected) {
            const on_close = std.meta.eql(o.hover, Hit{ .close = at });
            if (on_close) SearchBar.fill(mem, x, colors.border);
            glyph(mem, x, true, colors.text, line);
        }
        // The shortcut's width first, as the label gives way to it.
        var text: RECT = .{ .left = title.left + m.inset, .top = title.top, .right = x.left - m.inset, .bottom = title.bottom };
        if (tab.shortcut.len > 0) if (wideFromUtf8(alloc, tab.shortcut)) |s| {
            defer alloc.free(s);
            var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = win32.DrawTextW(mem, s.ptr, @intCast(s.len), &r, flags | win32.DT_CALCRECT);
            // Not where it would leave the label less than half the row.
            if (r.right - r.left <= @divTrunc(text.right - text.left, 2)) {
                var at_right = text;
                _ = win32.SetTextColor(mem, colors.dim);
                _ = win32.DrawTextW(mem, s.ptr, @intCast(s.len), &at_right, flags | win32.DT_RIGHT);
                text.right -= r.right - r.left + m.inset;
            }
        } else |_| {};
        if (wideFromUtf8(alloc, tab.title)) |s| {
            defer alloc.free(s);
            _ = win32.SetTextColor(mem, colors.text);
            _ = win32.DrawTextW(mem, s.ptr, @intCast(s.len), &text, flags | win32.DT_END_ELLIPSIS);
        } else |_| {}
    }

    // The header, over the cards scrolled under it: the field's box,
    // framed, behind the EDIT, and the "+".
    const grid = l.gridRect();
    SearchBar.fill(mem, .{ .left = 0, .top = 0, .right = client.right, .bottom = grid.top - @divTrunc(m.pad, 2) }, colors.bar);
    const box = l.fieldRect();
    SearchBar.fill(mem, box, colors.border);
    SearchBar.fill(mem, SearchBar.inset(box, line), colors.field);
    const plus = l.plusRect();
    if (o.pressed == .plus) {
        SearchBar.fill(mem, plus, colors.border);
    } else if (o.hover == .plus) {
        SearchBar.fill(mem, plus, colors.hover);
    }
    glyph(mem, plus, false, colors.text, line);

    _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
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
