//! A terminal's key-state indicator, as GTK shows a pending key sequence
//! and the active key tables in an overlay at the bottom centre of its
//! surface (src/apprt/gtk/class/key_state_overlay.zig and
//! key-state-overlay.blp): the tables joined with " > ", a "›" between
//! them and the sequence, the sequence's keys joined with spaces, as
//! Windows writes shortcuts (`CommandPalette.shortcutLabel`), then "…"
//! where GTK spins a spinner while the sequence waits for its next key;
//! nothing while there is neither (`writeText`). As GTK's surface keeps
//! them (`keyTableAction` and `keySequenceAction` in gtk/class/surface.zig),
//! `.activate` pushes a table and `.deactivate` pops one, `.deactivate_all`
//! pops them all, `.trigger` adds a key and `.end` clears the keys. GTK's
//! keyboard icon, its dimmed chevron, the spinner's motion and the drag
//! between the top and the bottom are left out: it is one line of text.
//!
//! It is one of the terminal's overlays (Overlays.zig): a child window of
//! its frame, just above the link preview, which every layout places,
//! hidden with its terminal and following it to a new frame; the pointer
//! and clicks over it go to the terminal under it.
//!
//! The core performs both actions inside its key callback, before it
//! takes its renderer's lock (`maybeHandleBinding`), and on a
//! configuration change. `.end` comes with almost every bound key, the core
//! ending a sequence whether or not one was pending ("Safe to call if no
//! key sequence is active", `CoreSurface.endKeySequence`): with no keys to
//! clear it returns before anything else. The window is made the first
//! time there is something to show, inside that callback, as
//! `SearchBar.start` makes the search bar's. A passive window is not among
//! what waits for the core's frame to return (`App.requests`: "Creating a
//! terminal there would register a surface with the core in the middle of
//! that frame", "laying terminals out sends them WM_SIZE, which enters the
//! core"), and placing it sends messages to it and to the terminal it
//! covers or uncovers, none of which enter the core. The table names are
//! copied: the core's point into its configuration, which a reload frees.

const std = @import("std");

const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const shortcutLabel = @import("CommandPalette.zig").shortcutLabel;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;

const RECT = win32.RECT;
const L = win32.L;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyKeyStateClass";

/// The most tables the core keeps active, a copy of its
/// `max_active_key_tables` (src/Surface.zig:62), which is not public;
/// it activates no more, and says nothing. A test reads the core's from
/// its source (`coreMaxKeyTables` in App.zig) and activates that many,
/// so it fails if the core's grows past this one.
pub const max_tables = 8;

/// A terminal's indicator (`Overlays.key_state`).
pub const Indicator = struct {
    /// Its window, a child of the terminal's frame, made the first time
    /// there is something to show; null until then, if it could not be
    /// made, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The active tables' names, the innermost last, owned.
    tables: [max_tables][]u8 = undefined,
    depth: usize = 0,
    /// The pending sequence's keys, by their labels, owned.
    keys: std.ArrayList([]u8) = .empty,
    /// What it shows, the same as its window's text, owned; null while
    /// there is nothing.
    text: ?[:0]u16 = null,
    /// The size of `text` in the overlays' font; measured again when
    /// either changes.
    text_size: Size = .{ .width = 0, .height = 0 },
    measured: bool = false,

    /// Free the names, the keys and the text, as the terminal is freed
    /// (`Overlays.deinit`).
    pub fn deinit(self: *Indicator, alloc: std.mem.Allocator) void {
        self.popTo(alloc, 0);
        self.clearKeys(alloc);
        self.keys.deinit(alloc);
        if (self.text) |t| alloc.free(t);
        self.text = null;
    }

    /// Pop tables until `depth` are left.
    fn popTo(self: *Indicator, alloc: std.mem.Allocator, depth: usize) void {
        while (self.depth > depth) {
            self.depth -= 1;
            alloc.free(self.tables[self.depth]);
        }
    }

    fn clearKeys(self: *Indicator, alloc: std.mem.Allocator) void {
        for (self.keys.items) |k| alloc.free(k);
        self.keys.clearRetainingCapacity();
    }

    /// Add `trigger`'s label to the keys; a trigger with none
    /// (`catch_all`) is left out, as GTK leaves it out.
    fn addKey(self: *Indicator, alloc: std.mem.Allocator, trigger: input.Binding.Trigger) !void {
        var label: std.Io.Writer.Allocating = .init(alloc);
        defer label.deinit();
        if (!try shortcutLabel(&label.writer, trigger)) return;
        try self.keys.ensureUnusedCapacity(alloc, 1);
        self.keys.appendAssumeCapacity(try label.toOwnedSlice());
    }

    /// What it shows now (`writeText`), as its window draws it; null for
    /// nothing.
    fn makeText(self: *const Indicator, alloc: std.mem.Allocator) !?[:0]u16 {
        if (self.depth == 0 and self.keys.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try writeText(&out.writer, self.tables[0..self.depth], self.keys.items);
        return try wideFromUtf8(alloc, out.written());
    }

    /// Take `text` as what it shows, which its window draws and is named.
    fn setText(self: *Indicator, alloc: std.mem.Allocator, text: ?[:0]u16) void {
        if (self.text) |old| alloc.free(old);
        self.text = text;
        self.measured = false;
        const hwnd = self.hwnd orelse return;
        // Its name, for what reads windows' text, as screen readers do.
        _ = win32.SetWindowTextW(hwnd, if (text) |t| t.ptr else L(""));
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
    }

    /// Where the indicator goes over a terminal `pane` big at `dpi`, in
    /// the terminal's client coordinates (`rectIn`), for `Overlays.place`.
    pub fn placeIn(self: *const Indicator, dpi: u32, pane: Size) ?Overlays.Placed {
        const in = rectIn(.init(dpi), pane, self.text_size) orelse return null;
        return .{ .in = in, .redraw = false };
    }

    /// Where the text goes in the indicator at `dpi`: inside its padding,
    /// which centres it; cut at the right in one narrower than the text.
    pub fn textIn(self: *const Indicator, dpi: u32, width: i32) RECT {
        _ = width;
        const m = Metrics.init(dpi);
        return .{ .left = m.pad_x, .top = m.pad_y, .right = m.pad_x + self.text_size.width, .bottom = m.pad_y + self.text_size.height };
    }
};

/// `key_sequence` on `surface`: `.trigger` adds its key, `.end` clears
/// the keys, and the indicator shows what there is now, or hides. False
/// if a key cannot be added or the window cannot be made.
pub fn sequence(surface: *Surface, value: apprt.action.KeySequence) bool {
    const self = &surface.overlays.key_state;
    const alloc = surface.app.core_app.alloc;
    switch (value) {
        .trigger => |trigger| self.addKey(alloc, trigger) catch |err| {
            log.warn("cannot show a key of a sequence err={}", .{err});
            return false;
        },
        .end => {
            if (self.keys.items.len == 0) return true;
            self.clearKeys(alloc);
        },
    }
    return update(surface);
}

/// `key_table` on `surface`: `.activate` pushes a copy of the table's
/// name, `.deactivate` pops the innermost, `.deactivate_all` pops them
/// all, and the indicator shows what there is now, or hides. False if a
/// name cannot be copied, one more than the core keeps is pushed, or the
/// window cannot be made.
pub fn table(surface: *Surface, value: apprt.action.KeyTable) bool {
    const self = &surface.overlays.key_state;
    const alloc = surface.app.core_app.alloc;
    switch (value) {
        .activate => |name| {
            if (self.depth == max_tables) {
                log.warn("more key tables than the core keeps len={d}", .{name.len});
                return false;
            }
            const copy = alloc.dupe(u8, name) catch |err| {
                log.warn("cannot show a key table len={d} err={}", .{ name.len, err });
                return false;
            };
            self.tables[self.depth] = copy;
            self.depth += 1;
        },
        .deactivate => {
            if (self.depth == 0) return true;
            self.popTo(alloc, self.depth - 1);
        },
        .deactivate_all => {
            if (self.depth == 0) return true;
            self.popTo(alloc, 0);
        },
    }
    return update(surface);
}

/// Show what `surface`'s indicator holds now where it goes
/// (`Overlays.place`), or hide it while it holds nothing; its window is
/// made first if there is something to show and none yet. False, the
/// indicator hidden, if its text or its window cannot be made.
fn update(surface: *Surface) bool {
    const self = &surface.overlays.key_state;
    const alloc = surface.app.core_app.alloc;
    const text = self.makeText(alloc) catch |err| {
        log.warn("cannot show the key state err={}", .{err});
        // An older text would show what is no longer so.
        self.setText(alloc, null);
        Overlays.hideWindow(self.hwnd);
        return false;
    };
    if (text != null and self.hwnd == null) {
        self.hwnd = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a key state indicator err={}", .{win32.GetLastError()});
            alloc.free(text.?);
            return false;
        };
    }
    self.setText(alloc, text);
    Overlays.place(surface);
    return true;
}

/// What the indicator shows for active tables `tables`, the innermost
/// last, and a pending sequence's keys `keys`, by their labels, as GTK's
/// overlay shows them in a row (key-state-overlay.blp): the tables joined
/// with " > ", "›" between them and the keys, the keys joined with
/// spaces, then "…" for the spinner while a sequence is pending. Nothing
/// for neither.
pub fn writeText(w: *std.Io.Writer, tables: []const []const u8, keys: []const []const u8) std.Io.Writer.Error!void {
    for (tables, 0..) |name, i| {
        if (i > 0) try w.writeAll(" > ");
        try w.writeAll(name);
    }
    if (tables.len > 0 and keys.len > 0) try w.writeAll(" \u{203A} ");
    for (keys, 0..) |key, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(key);
    }
    if (keys.len > 0) try w.writeAll(" \u{2026}");
}

/// The indicator's sizes at a DPI, from GTK's at 96 (`.key-state-overlay`
/// in src/apprt/gtk/css/style.css: padding 6px 10px, margin 8px).
pub const Metrics = struct {
    /// Between the text and the indicator's left and right edges.
    pad_x: i32,
    /// Between the text and its top and bottom edges.
    pad_y: i32,
    /// Between the indicator and its terminal's edges.
    margin: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .pad_x = SearchBar.Metrics.scale(10, dpi),
            .pad_y = SearchBar.Metrics.scale(6, dpi),
            .margin = SearchBar.Metrics.scale(8, dpi),
        };
    }
};

/// Where an indicator of text `text` big goes over a terminal `pane` big,
/// in the terminal's client coordinates: centred, `margin` above the
/// terminal's bottom, as wide and tall as the text with its padding, but
/// no wider than the terminal less a margin on each side; null for a
/// terminal with no room for it within its margins.
pub fn rectIn(m: Metrics, pane: Size, text: Size) ?RECT {
    const room = pane.width - 2 * m.margin;
    const height = @max(0, text.height) + 2 * m.pad_y;
    if (room <= 0 or pane.height - 2 * m.margin < height) return null;
    const width = @min(@max(0, text.width) + 2 * m.pad_x, room);
    const left = @divTrunc(pane.width - width, 2);
    const bottom = pane.height - m.margin;
    return .{ .left = left, .top = bottom - height, .right = left + width, .bottom = bottom };
}

test "win32: the key state shows the tables, a chevron, then the sequence's keys" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const cases = [_]struct { tables: []const []const u8, keys: []const []const u8, text: []const u8 }{
        .{ .tables = &.{}, .keys = &.{}, .text = "" },
        .{ .tables = &.{"nav"}, .keys = &.{}, .text = "nav" },
        .{ .tables = &.{ "nav", "resize" }, .keys = &.{}, .text = "nav > resize" },
        .{ .tables = &.{}, .keys = &.{"Ctrl+A"}, .text = "Ctrl+A \u{2026}" },
        .{ .tables = &.{}, .keys = &.{ "Ctrl+A", "Shift+B" }, .text = "Ctrl+A Shift+B \u{2026}" },
        .{ .tables = &.{ "nav", "resize" }, .keys = &.{ "Ctrl+A", "Up" }, .text = "nav > resize \u{203A} Ctrl+A Up \u{2026}" },
        // As many as the core keeps.
        .{ .tables = &.{ "1", "2", "3", "4", "5", "6", "7", "8" }, .keys = &.{}, .text = "1 > 2 > 3 > 4 > 5 > 6 > 7 > 8" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try writeText(&w, c.tables, c.keys);
        try testing.expectEqualStrings(c.text, w.buffered());
    }
}

test "win32: the key state indicator sits at its terminal's bottom centre, inside its margins" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(10, m.pad_x);
    try testing.expectEqual(6, m.pad_y);
    try testing.expectEqual(8, m.margin);
    const big = Metrics.init(144);
    try testing.expectEqual(15, big.pad_x);
    try testing.expectEqual(9, big.pad_y);
    try testing.expectEqual(12, big.margin);

    const text: Size = .{ .width = 100, .height = 16 };
    try testing.expectEqual(RECT{ .left = 340, .top = 564, .right = 460, .bottom = 592 }, rectIn(m, .{ .width = 800, .height = 600 }, text).?);
    // An odd width: the extra pixel on the right.
    try testing.expectEqual(RECT{ .left = 340, .top = 564, .right = 460, .bottom = 592 }, rectIn(m, .{ .width = 801, .height = 600 }, text).?);
    // Narrower than its text: the terminal less its margins.
    try testing.expectEqual(RECT{ .left = 8, .top = 64, .right = 92, .bottom = 92 }, rectIn(m, .{ .width = 100, .height = 100 }, text).?);
    // No room within the margins: nowhere.
    try testing.expect(rectIn(m, .{ .width = 16, .height = 600 }, text) == null);
    try testing.expect(rectIn(m, .{ .width = 800, .height = 43 }, text) == null);
    try testing.expectEqual(RECT{ .left = 340, .top = 8, .right = 460, .bottom = 36 }, rectIn(m, .{ .width = 800, .height = 44 }, text).?);
}
