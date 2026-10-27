//! A terminal's link preview, as GTK shows the URL of the link under the
//! pointer in a label over the bottom-left corner of its surface
//! (`url_left` in src/apprt/gtk/ui/1.0/surface.blp): the core's
//! `mouse_over_link` gives the URL, and an empty one hides it. While the
//! pointer is over the label's place, it shows at the bottom-right corner
//! instead, as GTK shows `url_right` while the pointer is over `url_left`.
//! GTK's label does not ellipsize, so a URL wider than its terminal is cut
//! at the terminal's edge: at the left the URL's start shows, at the right
//! its end. Control, bidirectional and zero-width code points show
//! escaped, as the macOS app's preview shows them (`displayText`); GTK's
//! label shows them as they are.
//!
//! It is one of the terminal's overlays (Overlays.zig): a child window of
//! the terminal's frame, just above the terminal's own window and under
//! its search bar and the window's command palette, which every layout
//! places, hidden with its terminal and following it to a new frame. It
//! is passive: the pointer and clicks over it go to the terminal under
//! it, which keeps tracking the link. Whether the pointer is over its
//! place is the terminal's to say (`pointerAt`, from its WM_MOUSEMOVE).
//!
//! The core gives the URL from its cursor and key callbacks, mostly with
//! its renderer's lock held. Showing, moving, hiding and retitling the
//! preview send messages to it and to the terminal it uncovers, none of
//! which enter the core (the terminal's paint comes later, from the
//! loop). What waits for the core's frame to return is narrower than
//! any window: terminals, since "Creating a terminal there would register
//! a surface with the core in the middle of that frame" and "laying
//! terminals out sends them WM_SIZE, which enters the core"
//! (`App.requests`), and the focus, since "moving the focus inside it
//! would send WM_KILLFOCUS into a surface whose key callback is on the
//! stack" (`App.search_focus`). A passive window may be made there, as
//! `SearchBar.start` makes the search bar's. The preview's window is made,
//! hidden, with its terminal's (`Overlays.create`) so that the first
//! preview shows without a window being made as the pointer reaches a
//! link, and nothing about the window can fail then. The cost is one
//! hidden window for every terminal, also when `link-previews` is false.

const std = @import("std");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const unsafeCodepoint = @import("App.zig").unsafeCodepoint;

const RECT = win32.RECT;
const L = win32.L;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyLinkPreviewClass";

/// A terminal's preview (`Overlays.link_preview`).
pub const Preview = struct {
    /// The preview's window, a child of the terminal's frame, made with
    /// the terminal; null if it could not be made, and once it is
    /// destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The URL shown, and the same as the window draws it, both owned;
    /// null while there is none.
    url: ?[]u8 = null,
    text: ?[:0]u16 = null,
    /// The size of `text` in the overlays' font; measured again when
    /// either changes.
    text_size: Size = .{ .width = 0, .height = 0 },
    measured: bool = false,
    /// Where the pointer is over the terminal, in its client coordinates,
    /// from its last WM_MOUSEMOVE; null once it has left.
    pointer: ?win32.POINT = null,
    /// The corner it shows at, as it was last placed.
    side: Side = .left,

    /// Free the URL, as the terminal is freed (`Overlays.deinit`).
    pub fn deinit(self: *Preview, alloc: std.mem.Allocator) void {
        self.clear(alloc);
    }

    /// Take `url`, not empty, and the text shown for it (`displayText`),
    /// while there is none.
    fn take(self: *Preview, alloc: std.mem.Allocator, url: []const u8) !void {
        const copy = try alloc.dupe(u8, url);
        errdefer alloc.free(copy);
        self.text = try displayText(alloc, url);
        self.url = copy;
    }

    /// Forget the URL.
    fn clear(self: *Preview, alloc: std.mem.Allocator) void {
        if (self.url) |v| alloc.free(v);
        self.url = null;
        if (self.text) |v| alloc.free(v);
        self.text = null;
        self.measured = false;
    }

    /// Where the preview goes over a terminal `pane` big at `dpi`, in the
    /// terminal's client coordinates (`Overlays.place`): over its
    /// bottom-left corner, or its bottom-right while the pointer is over
    /// the bottom-left place (`sideFor`), drawn again when it changes
    /// corners; null for a terminal with no area.
    pub fn placeIn(self: *Preview, dpi: u32, pane: Size) ?Overlays.Placed {
        const m = Metrics.init(dpi);
        const side = sideFor(m, pane, self.text_size, self.pointer);
        const in = rectIn(m, pane, self.text_size, side) orelse return null;
        defer self.side = side;
        return .{ .in = in, .redraw = side != self.side };
    }

    /// Where the text goes in the preview, `width` wide at `dpi`
    /// (`textRect`).
    pub fn textIn(self: *const Preview, dpi: u32, width: i32) RECT {
        return textRect(.init(dpi), width, self.text_size, self.side);
    }
};

/// `mouse_over_link` on `surface`: show `url` in its preview, over its
/// terminal's bottom-left corner, or hide the preview when `url` is
/// empty, as GTK's label shows while the URL is not empty. False if the
/// terminal has no preview, or the URL cannot be copied or its text made
/// (the preview is hidden then: an older URL would name another link).
///
/// The core performs this inside its cursor and key callbacks, which
/// send the same URL again on every move over a link; nothing is drawn
/// again unless something changed.
pub fn show(surface: *Surface, url: []const u8) bool {
    const preview = &surface.overlays.link_preview;
    const hwnd = preview.hwnd orelse return false;
    const alloc = surface.app.core_app.alloc;
    const same = if (preview.url) |v| std.mem.eql(u8, v, url) else url.len == 0;
    if (!same) {
        preview.clear(alloc);
        const taken = if (url.len > 0) preview.take(alloc, url) else {};
        // Its name, for what reads windows' text, as screen readers do.
        _ = win32.SetWindowTextW(hwnd, if (preview.text) |t| t.ptr else L(""));
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
        taken catch |err| {
            log.warn("cannot show a link preview len={d} err={}", .{ url.len, err });
            Overlays.hideWindow(preview.hwnd);
            return false;
        };
    }
    Overlays.place(surface);
    return true;
}

/// `url` as its preview shows it, NUL-terminated: each code point that can
/// hide part of the target or add a line (`unsafeCodepoint`) written as
/// its value in upper-case hex without leading zeros, `\u{202E}` or
/// `\u{85}`, as the macOS app's preview writes it
/// (`UntrustedURL.displayString`); each invalid UTF-8 sequence as U+FFFD.
/// The caller frees it.
fn displayText(alloc: std.mem.Allocator, url: []const u8) ![:0]u16 {
    const wide = try wideFromUtf8(alloc, url);
    // Unit by unit: every such code point is in the BMP and none is a
    // surrogate, so a unit of a surrogate pair is never one.
    for (wide) |unit| {
        if (unsafeCodepoint(unit)) break;
    } else return wide;
    defer alloc.free(wide);

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(alloc);
    for (wide) |unit| {
        if (!unsafeCodepoint(unit)) {
            try out.append(alloc, unit);
            continue;
        }
        var buf: ["\\u{FEFF}".len]u8 = undefined;
        const escaped = std.fmt.bufPrint(&buf, "\\u{{{X}}}", .{unit}) catch unreachable;
        for (escaped) |c| try out.append(alloc, c);
    }
    return out.toOwnedSliceSentinel(alloc, 0);
}

/// The pointer moved over `surface`'s terminal, to `at` in its client
/// coordinates, or left it (null): a preview that shows goes to the
/// other corner if the pointer came over its place or left it.
pub fn pointerAt(surface: *Surface, at: ?win32.POINT) void {
    const preview = &surface.overlays.link_preview;
    preview.pointer = at;
    const hwnd = preview.hwnd orelse return;
    if (preview.text != null and SearchBar.visibleStyle(hwnd)) Overlays.place(surface);
}

pub const Size = Overlays.Size;

/// The corner a preview shows at.
pub const Side = enum { left, right };

/// The preview's sizes at a DPI, from GTK's at 96 (`label.url-overlay` in
/// src/apprt/gtk/css/style.css: padding 4px 8px).
pub const Metrics = struct {
    /// Between the text and the preview's left and right edges.
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

/// Where a preview of text `text` big goes over a terminal `pane` big, in
/// the terminal's client coordinates: in its bottom-left or bottom-right
/// corner, as wide and tall as the text with its padding, but no wider or
/// taller than the terminal, as GTK's label is drawn only over its
/// surface; null for a terminal with no area.
pub fn rectIn(m: Metrics, pane: Size, text: Size, side: Side) ?RECT {
    if (pane.width <= 0 or pane.height <= 0) return null;
    const width = @min(@max(0, text.width) + 2 * m.pad_x, pane.width);
    const height = @min(@max(0, text.height) + 2 * m.pad_y, pane.height);
    const left = switch (side) {
        .left => 0,
        .right => pane.width - width,
    };
    return .{ .left = left, .top = pane.height - height, .right = left + width, .bottom = pane.height };
}

/// The corner for a preview of text `text` big over a terminal `pane`
/// big with the pointer at `pointer`: the right while the pointer is over
/// the preview's place at the left, as GTK shows `url_right` while the
/// pointer is over `url_left`, else the left.
pub fn sideFor(m: Metrics, pane: Size, text: Size, pointer: ?win32.POINT) Side {
    const pt = pointer orelse return .left;
    const left = rectIn(m, pane, text, .left) orelse return .left;
    const over = pt.x >= left.left and pt.x < left.right and pt.y >= left.top and pt.y < left.bottom;
    return if (over) .right else .left;
}

/// Where the text goes in a preview `width` wide at `side`, in its client
/// coordinates. GTK's labels are as wide as their text: `url_left` starts
/// at its surface's left edge and `url_right` ends at its right edge, and
/// what goes past the other edge is cut. So at the left the text starts
/// `pad_x` in from the left, and at the right it ends `pad_x` in from the
/// right, and starts before the left edge when it is too wide.
pub fn textRect(m: Metrics, width: i32, text: Size, side: Side) RECT {
    const left = switch (side) {
        .left => m.pad_x,
        .right => width - m.pad_x - text.width,
    };
    return .{ .left = left, .top = m.pad_y, .right = left + text.width, .bottom = m.pad_y + text.height };
}

test "win32: a link preview sits in its terminal's bottom corner, as wide as its URL" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(8, m.pad_x);
    try testing.expectEqual(4, m.pad_y);
    try testing.expectEqual(12, Metrics.init(144).pad_x);
    try testing.expectEqual(6, Metrics.init(144).pad_y);

    const pane: Size = .{ .width = 800, .height = 600 };
    const text: Size = .{ .width = 200, .height = 16 };
    try testing.expectEqual(RECT{ .left = 0, .top = 576, .right = 216, .bottom = 600 }, rectIn(m, pane, text, .left).?);
    try testing.expectEqual(RECT{ .left = 584, .top = 576, .right = 800, .bottom = 600 }, rectIn(m, pane, text, .right).?);

    // Wider than its terminal: as wide as it, from either side.
    const wide: Size = .{ .width = 900, .height = 16 };
    try testing.expectEqual(RECT{ .left = 0, .top = 576, .right = 800, .bottom = 600 }, rectIn(m, pane, wide, .left).?);
    try testing.expectEqual(RECT{ .left = 0, .top = 576, .right = 800, .bottom = 600 }, rectIn(m, pane, wide, .right).?);
    // Taller: as tall.
    try testing.expectEqual(RECT{ .left = 0, .top = 0, .right = 216, .bottom = 20 }, rectIn(m, .{ .width = 800, .height = 20 }, text, .left).?);
    // No area: nowhere.
    try testing.expect(rectIn(m, .{ .width = 0, .height = 600 }, text, .left) == null);
    try testing.expect(rectIn(m, .{ .width = 800, .height = 0 }, text, .right) == null);
}

test "win32: a link preview moves right while the pointer is over its place at the left" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const pane: Size = .{ .width = 800, .height = 600 };
    const text: Size = .{ .width = 200, .height = 16 };
    // Its place at the left is (0,576)-(216,600).
    try testing.expectEqual(Side.left, sideFor(m, pane, text, null));
    try testing.expectEqual(Side.right, sideFor(m, pane, text, .{ .x = 0, .y = 576 }));
    try testing.expectEqual(Side.right, sideFor(m, pane, text, .{ .x = 215, .y = 599 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 216, .y = 590 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 100, .y = 575 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 100, .y = 600 }));
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = -1, .y = 590 }));
    // Over its place at the right, which GTK does not watch: the left.
    try testing.expectEqual(Side.left, sideFor(m, pane, text, .{ .x = 700, .y = 590 }));
    // As wide as the terminal: anywhere along its bottom.
    try testing.expectEqual(Side.right, sideFor(m, pane, .{ .width = 900, .height = 16 }, .{ .x = 799, .y = 590 }));
    try testing.expectEqual(Side.left, sideFor(m, .{ .width = 0, .height = 0 }, text, .{ .x = 0, .y = 0 }));
}

test "win32: a link preview too wide for its terminal shows the URL's start at the left and its end at the right" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const text: Size = .{ .width = 200, .height = 16 };
    try testing.expectEqual(RECT{ .left = 8, .top = 4, .right = 208, .bottom = 20 }, textRect(m, 216, text, .left));
    try testing.expectEqual(RECT{ .left = 8, .top = 4, .right = 208, .bottom = 20 }, textRect(m, 216, text, .right));
    // Cut to 100: the start shows at the left, the end at the right.
    try testing.expectEqual(RECT{ .left = 8, .top = 4, .right = 208, .bottom = 20 }, textRect(m, 100, text, .left));
    try testing.expectEqual(RECT{ .left = -108, .top = 4, .right = 92, .bottom = 20 }, textRect(m, 100, text, .right));
}
