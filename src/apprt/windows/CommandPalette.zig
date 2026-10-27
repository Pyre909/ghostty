//! The command palette, as GTK's (src/apprt/gtk/class/command_palette.zig
//! and command-palette.blp) and macOS's (TerminalCommandPalette.swift)
//! list it: the configuration's `command-palette-entry` commands whose
//! action this runtime performs (`supported`), and one entry per terminal
//! that focuses it, "Focus: <title>"; sorted by title as both sort them
//! (`lessThan`); filtered by a substring of the title or the action,
//! ignoring case as Unicode folds it, the entries whose title matches
//! first (`filter`); each with the shortcut its action is bound to, in
//! Windows' key names (`shortcutLabel`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const Surface = @import("Surface.zig").Surface;
const App = @import("App.zig").App;

const Binding = input.Binding;
const uucode = @import("uucode");

/// Whether this runtime carries out `key`, and so lists a command with
/// it. An exhaustive switch, as `actionCommands` in src/input/command.zig
/// is, so that a new action does not compile until it is given an answer
/// here. An action the core performs itself is supported; one the core
/// hands to this runtime only if `App.performAction` handles what it
/// becomes. GTK's palette leaves out the actions it cannot perform the
/// same way (`isActionSupportedOnGtk`).
pub fn supported(key: Binding.Action.Key) bool {
    return switch (key) {
        // The core's own: the terminal, its screen and its pty.
        .reset,
        .csi,
        .esc,
        .text,
        .cursor_key,
        .copy_to_clipboard,
        .copy_url_to_clipboard,
        .paste_from_clipboard,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        .clear_screen,
        .select_all,
        .search,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        // `copy` and `paste` stay with the core; `open` becomes `open_url`.
        .write_scrollback_file,
        .write_screen_file,
        .write_selection_file,
        // The core keeps the flag; this runtime shows no badge for it.
        .toggle_readonly,
        .toggle_mouse_reporting,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .end_key_sequence,
        .crash,
        // Handed to this runtime, which performs what they become.
        .copy_title_to_clipboard,
        .start_search,
        .search_selection,
        .end_search,
        .navigate_search,
        .new_window,
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .move_tab_to_new_window,
        .close_tab,
        .prompt_surface_title,
        .prompt_tab_title,
        .set_surface_title,
        .set_tab_title,
        .new_split,
        .goto_split,
        .toggle_split_zoom,
        .resize_split,
        .equalize_splits,
        .close_surface,
        .close_window,
        .goto_window,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .reset_window_size,
        .toggle_command_palette,
        .open_config,
        .reload_config,
        .quit,
        => true,

        // Nothing to do.
        .ignore,
        .unbind,
        // Windows has no selection clipboard (`Surface.supportsClipboard`).
        .paste_from_selection,
        // What these become, `App.performAction` does not handle: there is
        // no tab overview, no window title of its own (its caption is its
        // shown tab's), no inspector, quick terminal, updater, undo, secure
        // input or on-screen keyboard here, and the background's opacity
        // is not toggled.
        .toggle_tab_overview,
        .prompt_window_title,
        .set_window_title,
        .close_all_windows,
        .toggle_quick_terminal,
        .toggle_visibility,
        .check_for_updates,
        .undo,
        .redo,
        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .toggle_secure_input,
        .toggle_background_opacity,
        => false,
    };
}

/// One row of the palette.
pub const Entry = struct {
    /// The first line.
    title: []const u8,
    /// The action, as the configuration writes it (`new_split:right`),
    /// GTK's `action-key`, shown on the second line and searched; empty
    /// for a jump.
    action_key: []const u8 = "",
    /// The command's description; a jump's terminal's working directory,
    /// unless its title shows it already, as GTK and macOS describe a
    /// jump. Shown on the second line when there is no action key.
    description: []const u8 = "",
    /// The shortcut the action is bound to (`shortcutLabel`), or empty.
    shortcut: []const u8 = "",
    /// What choosing it does.
    run: Run,
    /// A jump's order among jumps of the same title: its terminal's place
    /// in `App.surfaces`, which is not the order they were made in once a
    /// terminal has closed (the last one takes its place). GTK's and
    /// macOS's orders among such jumps are arbitrary too: GTK's sorts by
    /// the core's surface id, a random number, macOS by object identity.
    sort_key: usize = 0,
    /// `title` and `action_key` case-folded (`fold`), as the filter
    /// compares them; made once, by `build`.
    folded_title: []const u8 = "",
    folded_key: []const u8 = "",

    pub const Run = union(enum) {
        /// Perform this binding action on the palette's terminal.
        action: Binding.Action,
        /// Focus this terminal, as GTK presents it.
        jump: *Surface,
    };

    /// The second line: the action key, else the description.
    pub fn subtitle(self: *const Entry) []const u8 {
        return if (self.action_key.len > 0) self.action_key else self.description;
    }
};

/// A terminal a jump entry focuses, and what it is titled with.
pub const Jump = struct {
    surface: *Surface,
    /// Its title as shown, null for none ("Untitled", as GTK and macOS).
    title: ?[]const u8,
    /// Its working directory, null if unknown.
    pwd: ?[]const u8 = null,
};

/// The palette's entries, sorted, in memory of their own: the
/// configuration they came from may be replaced while the palette is open.
pub const Entries = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Entry,

    pub fn deinit(self: *Entries) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The entries for `commands` (the configuration's
/// `command-palette-entry`) whose action is `supported`, with the
/// shortcut `set` binds each action to, and one for each of `jumps`;
/// sorted (`lessThan`).
pub fn build(
    alloc: Allocator,
    commands: []const input.Command,
    set: *const Binding.Set,
    jumps: []const Jump,
) Allocator.Error!Entries {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(Entry) = try .initCapacity(a, commands.len + jumps.len);
    for (commands) |command| {
        if (!supported(command.action)) continue;
        const cloned = try command.clone(a);
        var shortcut: []const u8 = "";
        if (set.getTrigger(command.action)) |trigger| {
            var w: std.Io.Writer.Allocating = .init(a);
            if (shortcutLabel(&w.writer, trigger) catch return error.OutOfMemory) shortcut = w.written();
        }
        list.appendAssumeCapacity(try withFolded(a, .{
            .title = cloned.title,
            .action_key = try a.print("{f}", .{cloned.action}),
            .description = cloned.description,
            .shortcut = shortcut,
            .run = .{ .action = cloned.action },
        }));
    }
    for (jumps, 0..) |jump, i| {
        const shown = jump.title orelse "Untitled";
        const pwd = jump.pwd orelse "";
        list.appendAssumeCapacity(try withFolded(a, .{
            .title = try a.print("Focus: {s}", .{shown}),
            .description = if (pwd.len > 0 and std.mem.indexOf(u8, shown, pwd) == null) try a.dupe(u8, pwd) else "",
            .run = .{ .jump = jump.surface },
            .sort_key = i,
        }));
    }
    // Stable, as GTK's sort is.
    std.mem.sort(Entry, list.items, {}, lessThan);
    return .{ .arena = arena, .items = list.items };
}

/// The entries for `app` now: its configuration's commands and shortcuts,
/// as GTK's palette reads its window's configuration, and a jump to each
/// terminal that is not closing, in every window, titled as it shows
/// (`Surface.effectiveTitle`), as GTK's lists every surface of the core;
/// none to `skip`, a terminal going away.
pub fn forApp(app: *App, skip: ?*const Surface) Allocator.Error!Entries {
    const alloc = app.core_app.alloc;
    // The directories, read from the cores, only until `build` has copied
    // what it keeps.
    var scratch: std.heap.ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const s = scratch.allocator();
    var jumps: std.ArrayList(Jump) = try .initCapacity(s, app.surfaces.items.len);
    for (app.surfaces.items) |surface| {
        if (surface.closing or surface == skip) continue;
        const pwd: ?[]const u8 = if (surface.liveCore()) |core| try core.pwd(s) else null;
        jumps.appendAssumeCapacity(.{ .surface = surface, .title = surface.effectiveTitle(), .pwd = pwd });
    }
    return build(alloc, app.config.@"command-palette-entry".value.items, &app.config.keybind.set, jumps.items);
}

/// GTK's order (`compareCommands`): by title, ignoring ASCII case, a ':'
/// sorting before every other character so that "Foo:" comes before
/// "Foo Bar:", a title before the longer ones it begins; two jumps of the
/// same title by their terminals' order.
pub fn lessThan(_: void, a: Entry, b: Entry) bool {
    for (a.title[0..@min(a.title.len, b.title.len)], b.title[0..@min(a.title.len, b.title.len)]) |ca, cb| {
        const la = std.ascii.toLower(if (ca == ':') '\t' else ca);
        const lb = std.ascii.toLower(if (cb == ':') '\t' else cb);
        if (la != lb) return la < lb;
    }
    if (a.title.len != b.title.len) return a.title.len < b.title.len;
    if (a.run != .jump or b.run != .jump) return false;
    return a.sort_key < b.sort_key;
}

/// How an entry matches a query.
pub const Match = enum {
    none,
    /// In its action key only.
    action_key,
    /// In its title.
    title,
};

/// Whether `entry` matches `folded`, a query already case-folded
/// (`fold`): a substring of its title, else of its action key, both
/// folded, as GTK's palette filters on either (its StringFilters on
/// `title` and `action-key`, which ignore case). An empty query matches
/// every title.
pub fn match(entry: *const Entry, folded: []const u8) Match {
    if (std.mem.indexOf(u8, entry.folded_title, folded) != null) return .title;
    if (entry.action_key.len > 0 and std.mem.indexOf(u8, entry.folded_key, folded) != null) return .action_key;
    return .none;
}

/// `text` case-folded, as GTK's StringFilter folds both the query and
/// the text with `g_utf8_casefold`: each code point by Unicode's full
/// case folding (uucode's `case_folding_full`, as `Binding.Trigger`
/// folds a key), so that "Ü" matches "ü", "Σ" matches "σ" and "SS"
/// matches "ß". A byte that is not UTF-8 is kept as it is. In memory of
/// `alloc`.
pub fn fold(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(alloc, text.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const cp: ?u21 = if (len > 0 and i + len <= text.len)
            std.unicode.utf8Decode(text[i..][0..len]) catch null
        else
            null;
        const c = cp orelse {
            try out.append(alloc, text[i]);
            i += 1;
            continue;
        };
        i += len;
        if (c < 0x80) {
            try out.append(alloc, std.ascii.toLower(@intCast(c)));
            continue;
        }
        var single: [1]u21 = undefined;
        for (uucode.get(.case_folding_full, c).with(&single, c)) |f| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(f, &buf) catch continue;
            try out.appendSlice(alloc, buf[0..n]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `entry` with its title and action key folded (`fold`) for the filter.
fn withFolded(a: Allocator, entry: Entry) Allocator.Error!Entry {
    var e = entry;
    e.folded_title = try fold(a, entry.title);
    e.folded_key = try fold(a, entry.action_key);
    return e;
}

/// The indices into `entries` of those that match `query`, into `out`
/// (cleared first): those whose title matches, then those whose action
/// key alone does, as macOS ranks a title match over the rest; each kind
/// in the entries' order. The query is folded here, once (`match`).
pub fn filter(
    alloc: Allocator,
    entries: []const Entry,
    query: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(alloc, entries.len);
    const folded = try fold(alloc, query);
    defer alloc.free(folded);
    for (entries, 0..) |*entry, i| {
        if (match(entry, folded) == .title) out.appendAssumeCapacity(@intCast(i));
    }
    for (entries, 0..) |*entry, i| {
        if (match(entry, folded) == .action_key) out.appendAssumeCapacity(@intCast(i));
    }
}

/// The shortcut `trigger` is, as Windows writes one in menus and
/// tooltips: the modifiers in the order Win, Ctrl, Alt, Shift, then the
/// key, a letter in capitals (Ctrl+Shift+T). False, with nothing written,
/// for a trigger that is no one key (`catch_all`).
pub fn shortcutLabel(w: *std.Io.Writer, trigger: Binding.Trigger) std.Io.Writer.Error!bool {
    if (trigger.key == .catch_all) return false;
    if (trigger.mods.super) try w.writeAll("Win+");
    if (trigger.mods.ctrl) try w.writeAll("Ctrl+");
    if (trigger.mods.alt) try w.writeAll("Alt+");
    if (trigger.mods.shift) try w.writeAll("Shift+");
    switch (trigger.key) {
        .unicode => |cp| try writeCodepoint(w, cp),
        .physical => |key| try writeKey(w, key),
        .catch_all => unreachable,
    }
    return true;
}

/// A key bound by the character it types: a letter in capitals, as the
/// key cap shows it; the space bar and '+' by name, as "Ctrl++" would
/// read badly.
fn writeCodepoint(w: *std.Io.Writer, cp: u21) std.Io.Writer.Error!void {
    switch (cp) {
        ' ' => try w.writeAll("Space"),
        '+' => try w.writeAll("Plus"),
        '\t' => try w.writeAll("Tab"),
        '\r', '\n' => try w.writeAll("Enter"),
        0x1B => try w.writeAll("Esc"),
        0x08 => try w.writeAll("Backspace"),
        'a'...'z' => try w.writeByte(std.ascii.toUpper(@intCast(cp))),
        else => if (cp < 0x20 or cp == 0x7F) {
            try w.print("U+{X:0>4}", .{cp});
        } else {
            try w.print("{u}", .{cp});
        },
    }
}

/// A key bound by its place on the keyboard, by the names Windows menus
/// give keys (PgUp, Del, Esc); a key on the number pad with "Num " before
/// it; any other by its name in words.
fn writeKey(w: *std.Io.Writer, key: input.Key) std.Io.Writer.Error!void {
    const name: ?[]const u8 = switch (key) {
        .enter, .numpad_enter => "Enter",
        .escape => "Esc",
        .backspace => "Backspace",
        .tab => "Tab",
        .space => "Space",
        .delete => "Del",
        .insert => "Ins",
        .home => "Home",
        .end => "End",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .print_screen => "PrtScn",
        .context_menu => "Menu",
        else => null,
    };
    if (name) |n| return w.writeAll(n);
    if (key.codepoint()) |cp| {
        // As Windows names them: Num +, Num 5.
        if (key.keypad()) return w.print("Num {u}", .{cp});
        return writeCodepoint(w, cp);
    }
    // "f12" and the like are written in capitals, the rest as words.
    const tag = @tagName(key);
    if (tag.len >= 2 and tag[0] == 'f' and std.ascii.isDigit(tag[1])) {
        try w.writeByte('F');
        return w.writeAll(tag[1..]);
    }
    var first = true;
    var it = std.mem.tokenizeScalar(u8, tag, '_');
    while (it.next()) |word| {
        if (!first) try w.writeByte(' ');
        first = false;
        try w.writeByte(std.ascii.toUpper(word[0]));
        try w.writeAll(word[1..]);
    }
}

// The palette on screen.
//
// A child window of the frame, as the search bars are (SearchBar.zig), at
// the top centre of the area under the tab bar, above the terminals: GDI in
// a child of a terminal's window would never be composed over its
// flip-model swap chain, while a sibling above it draws. An EDIT takes the
// query and a LISTBOX, owner-drawn, shows the entries, two lines each (the
// title, then the action key or the description) with the shortcut on the
// right, as GTK's rows show them (command-palette.blp). The LISTBOX keeps
// each title as its item's text, for accessibility, and the entry's index
// as its data. The keyboard stays in the field: Up, Down, PgUp and PgDn
// move the selection, Enter runs it, Escape closes; a click on a row runs
// it.
//
// One per window (`Window.palette`), for the terminal with the focus in
// its shown tab (`focusMoved`), which gets the focus back when it closes.
// It closes on Escape, when it runs an entry, when its frame is
// deactivated, when the layout leaves no room for it, and with its window
// or its terminal; it is made anew each time it opens, with the entries
// as they are then. An entry runs after the palette has closed, as GTK
// closes its dialog first so that a dialog the action opens (a title
// prompt) is not held up by it, on the terminal it was open for, never
// inside a core frame (`App.requests`).

const builtin = @import("builtin");
const CoreSurface = @import("../../Surface.zig");
const win32 = @import("win32.zig");
const Window = @import("Window.zig");
const SearchBar = @import("SearchBar.zig");
const overlay_keys = @import("overlay_keys.zig");
const messageFont = @import("TabBar.zig").messageFont;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const utf8FromWide = @import("clipboard.zig").utf8FromWide;

const RECT = win32.RECT;
const L = win32.L;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyCommandPaletteClass";

/// Posted to the palette's window when its frame is deactivated
/// (`deactivated`).
pub const WM_PALETTE_CLOSE: win32.UINT = win32.WM_USER + 1;

/// A window's palette (`Window.palette`): its windows while it is open,
/// none while it is closed.
pub const Palette = struct {
    /// The palette's window, a child of the frame; null while closed.
    hwnd: ?win32.HWND = null,
    /// The query, an EDIT child of `hwnd`.
    edit: ?win32.HWND = null,
    /// The entries, an owner-drawn LISTBOX child of `hwnd`.
    list: ?win32.HWND = null,
    /// From `open` until `close` starts: the keyboard focus the window
    /// gives goes to the field (`focusTarget`).
    open: bool = false,
    /// The terminal entries run on, live while open: the one it was
    /// opened for, then the one with the focus in the shown tab
    /// (`focusMoved`).
    surface: ?*Surface = null,
    /// What it lists; the list's items hold indices into it.
    entries: ?Entries = null,
    /// The filter's result, reused for each query.
    shown: std.ArrayList(u32) = .empty,
    /// The row the left button went down on; it runs if the button comes
    /// up on it too.
    pressed: ?usize = null,
    /// While a wheel message is being forwarded to the list (`wndProc`).
    wheeling: bool = false,
    /// Whether the list has the dark theme class, null before it has had
    /// either (`applyListTheme`).
    list_dark: ?bool = null,
    /// The system's message font at `font_dpi`, and the height of a line
    /// of it, as the search bar's (`applyFont`).
    font: ?win32.HGDIOBJ = null,
    font_dpi: u32 = 0,
    text_height: i32 = 0,
    /// The brush the field and the list are painted with, of
    /// `brush_color`.
    brush: ?win32.HGDIOBJ = null,
    brush_color: win32.COLORREF = 0,

    /// Where the keyboard focus the window gives goes: the field while
    /// the palette is open and shows; else null.
    pub fn focusTarget(self: *const Palette) ?win32.HWND {
        if (!self.open) return null;
        const hwnd = self.hwnd orelse return null;
        if (!SearchBar.visibleStyle(hwnd)) return null;
        return self.edit;
    }

    /// Whether the keyboard focus is in the palette now.
    fn holdsFocus(self: *const Palette) bool {
        const hwnd = self.hwnd orelse return false;
        const focus = Window.keyboardFocus() orelse return false;
        return focus == hwnd or win32.IsChild(hwnd, focus).toBool();
    }

    /// Give the field and the list the message font at `dpi`, made once
    /// for each DPI, measure a line of it, and size the rows for it.
    fn applyFont(self: *Palette, dpi: u32) void {
        if (self.font != null and self.font_dpi == dpi) return;
        const edit = self.edit orelse return;
        const font = messageFont(dpi) orelse return;
        _ = win32.SendMessageW(edit, win32.WM_SETFONT, @intFromPtr(font), 1);
        if (self.list) |list| _ = win32.SendMessageW(list, win32.WM_SETFONT, @intFromPtr(font), 0);
        if (self.font) |old| _ = win32.DeleteObject(old);
        self.font = font;
        self.font_dpi = dpi;
        self.text_height = SearchBar.textHeight(edit, font);
        if (self.list) |list| {
            const row: win32.LPARAM = Metrics.init(dpi).rowHeight(self.text_height);
            _ = win32.SendMessageW(list, win32.LB_SETITEMHEIGHT, 0, row);
        }
    }

    /// The brush for the field and the list, of `color`.
    fn brushOf(self: *Palette, color: win32.COLORREF) ?win32.HGDIOBJ {
        if (self.brush != null and self.brush_color == color) return self.brush;
        const brush: win32.HGDIOBJ = win32.CreateSolidBrush(color) orelse return self.brush;
        if (self.brush) |old| _ = win32.DeleteObject(old);
        self.brush = brush;
        self.brush_color = color;
        return brush;
    }

    /// Free everything, as its window is destroyed.
    fn free(self: *Palette, alloc: Allocator) void {
        if (self.entries) |*e| e.deinit();
        self.shown.deinit(alloc);
        if (self.font) |f| _ = win32.DeleteObject(f);
        if (self.brush) |b| _ = win32.DeleteObject(b);
        self.* = .{};
    }
};

/// An entry chosen while the core could not be re-entered, with the
/// entries it is one of, for `run` to carry out (`App.Request.palette_run`).
pub const Pending = struct {
    entries: Entries,
    index: usize,

    pub fn entry(self: *const Pending) *const Entry {
        return &self.entries.items[self.index];
    }

    /// Whether choosing it focuses `surface`.
    pub fn jumpsTo(self: *const Pending, surface: *const Surface) bool {
        return switch (self.entry().run) {
            .jump => |s| s == surface,
            .action => false,
        };
    }

    pub fn destroy(self: *Pending, alloc: Allocator) void {
        self.entries.deinit();
        alloc.destroy(self);
    }
};

/// `toggle_command_palette` on `surface`, carried out by `run`
/// (`App.Request.palette`): its window's palette closes if it is open,
/// else opens, as GTK's `toggle`.
pub fn toggle(surface: *Surface) void {
    const window = surface.window;
    if (window.palette.hwnd != null) return close(window);
    _ = open(surface);
}

/// Open `surface`'s window's palette, with every entry listed and the
/// first selected, and give its field the keyboard focus; whether it
/// opened. Not for a closing terminal or window, nor over a title prompt,
/// which holds the frame disabled; nor where it does not fit (`place`).
pub fn open(surface: *Surface) bool {
    const window = surface.window;
    const app = window.app;
    const p = &window.palette;
    if (p.hwnd != null) return true;
    if (surface.closing or window.closing) return false;
    if (window.title_prompt.hwnd != null) {
        log.info("no command palette over a title prompt", .{});
        return false;
    }
    const entries = forApp(app, null) catch |err| {
        log.warn("cannot list the command palette's entries err={}", .{err});
        return false;
    };
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
        log.warn("cannot make a command palette err={}", .{win32.GetLastError()});
        var e = entries;
        e.deinit();
        return false;
    };
    // From here its WM_DESTROY frees all of it. It is for the window's
    // focused terminal, as GTK's runs on its window's active surface. An
    // `all:` binding asks from every terminal, and each request toggles
    // its window's palette, as each surface's toggles GTK's: a window's
    // palette is left open only when it has an odd number of terminals,
    // counting those in hidden tabs.
    p.hwnd = hwnd;
    p.entries = entries;
    p.surface = window.tab().focused orelse surface;
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
    ) orelse return failed(hwnd, "field");
    p.edit = edit;
    const old_edit = win32.SetWindowLongPtrW(edit, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
    if (edit_proc == null) edit_proc = @ptrFromInt(@as(usize, @bitCast(old_edit)));
    // GTK's placeholder.
    _ = win32.SendMessageW(edit, win32.EM_SETCUEBANNER, 0, @bitCast(@intFromPtr(L("Execute a command\u{2026}"))));
    // Before the list, whose WM_MEASUREITEM reads the line's height.
    p.applyFont(Window.dpiOf(app, window.hwnd));
    const list = win32.CreateWindowExW(
        0,
        L("LISTBOX"),
        null,
        win32.WS_CHILD | win32.WS_VISIBLE | win32.WS_VSCROLL | win32.LBS_NOTIFY |
            win32.LBS_OWNERDRAWFIXED | win32.LBS_HASSTRINGS | win32.LBS_NOINTEGRALHEIGHT,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return failed(hwnd, "list");
    p.list = list;
    const old_list = win32.SetWindowLongPtrW(list, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&listProc)));
    if (list_proc == null) list_proc = @ptrFromInt(@as(usize, @bitCast(old_list)));
    if (p.font) |f| _ = win32.SendMessageW(list, win32.WM_SETFONT, @intFromPtr(f), 0);
    applyListTheme(window);
    refill(window, "");
    p.open = true;
    if (!place(window)) return false;
    window.setKeyboardFocus(edit, true);
    return true;
}

/// A child of a palette being opened could not be made: logged, and the
/// palette destroyed, which frees it.
fn failed(hwnd: win32.HWND, what: []const u8) bool {
    log.warn("cannot make the command palette's {s} err={}", .{ what, win32.GetLastError() });
    _ = win32.DestroyWindow(hwnd);
    return false;
}

/// Close `window`'s palette, if it is open: the terminal gets the
/// keyboard focus if the palette had it, then the palette's window is
/// destroyed, which frees what it held.
pub fn close(window: *Window) void {
    const p = &window.palette;
    const hwnd = p.hwnd orelse return;
    const had_focus = p.holdsFocus();
    p.open = false;
    if (had_focus) {
        if (window.tab().focused) |s| window.setKeyboardFocus(Window.focusTarget(s), true);
    }
    _ = win32.DestroyWindow(hwnd);
}

/// Escape or Enter in the field closed the palette: the key's release
/// would reach the terminal that took the focus, which never saw it
/// pressed, and a program that asked for key releases would see one
/// alone, so the terminal withholds it, as after a title prompt
/// (`TitleDialog.closedByKey`). Whichever terminal holds the keyboard
/// focus now, in any window: Enter on a jump to another window's terminal
/// leaves the focus there.
fn closedByKey(app: *App, lparam: win32.LPARAM) void {
    const focus = Window.keyboardFocus() orelse return;
    for (app.surfaces.items) |surface| {
        if (surface.hwnd != focus) continue;
        surface.withholdKeyUp(lparam);
        return;
    }
}

/// `window` was deactivated (its WM_ACTIVATE): its palette closes, as GTK's
/// dialog does, once the deactivation is over, by a message to itself:
/// inside WM_ACTIVATE the focus is still in the field, and destroying it
/// there would hand the focus to the frame, and from there to a terminal,
/// in a window that is losing it, perhaps to a confirmation prompt whose
/// core frame is on the stack.
pub fn deactivated(window: *Window) void {
    const hwnd = window.palette.hwnd orelse return;
    _ = win32.PostMessageW(hwnd, WM_PALETTE_CLOSE, 0, 0);
}

/// `surface` is beginning to close, or is freed: the palette open for it
/// closes; another one lists it no more.
pub fn forget(app: *App, surface: *Surface) void {
    for (app.windows.items) |window| {
        const p = &window.palette;
        if (p.hwnd == null) continue;
        if (p.surface == surface) {
            close(window);
            continue;
        }
        const entries = p.entries orelse continue;
        const listed = for (entries.items) |e| {
            if (e.run == .jump and e.run.jump == surface) break true;
        } else false;
        if (listed) relist(window, surface);
    }
}

/// List `window`'s palette's entries again, without `gone`, keeping the
/// query and the selected entry, which the user may have moved to before
/// pressing Enter: its new row is selected (`sameEntry`), with the list
/// scrolled as it was if that row is still in view; the first row, as
/// when the query changes, if it was `gone`'s jump.
fn relist(window: *Window, gone: *const Surface) void {
    const p = &window.palette;
    const list = p.list orelse return;
    const fresh = forApp(window.app, gone) catch |err| {
        // Its jump would focus a freed terminal: no palette rather than that.
        log.warn("cannot list the command palette's entries again err={}", .{err});
        return close(window);
    };
    // The old entries are freed only once the selected one is found again.
    var old = p.entries;
    defer if (old) |*o| o.deinit();
    const selected: ?Entry = selected: {
        const entries = old orelse break :selected null;
        const cur = win32.SendMessageW(list, win32.LB_GETCURSEL, 0, 0);
        if (cur < 0) break :selected null;
        const data = win32.SendMessageW(list, win32.LB_GETITEMDATA, @intCast(cur), 0);
        if (data < 0 or @as(usize, @intCast(data)) >= entries.items.len) break :selected null;
        break :selected entries.items[@intCast(data)];
    };
    const top = win32.SendMessageW(list, win32.LB_GETTOPINDEX, 0, 0);
    p.entries = fresh;
    textChanged(window);
    const was = selected orelse return;
    for (p.shown.items, 0..) |index, row| {
        if (!sameEntry(&fresh.items[index], &was)) continue;
        // Back to the top it had, then the row selected, which scrolls the
        // list only if the row is out of view from there.
        if (top > 0) _ = win32.SendMessageW(list, win32.LB_SETTOPINDEX, @intCast(top), 0);
        _ = win32.SendMessageW(list, win32.LB_SETCURSEL, row, 0);
        return;
    }
}

/// Whether `a` and `b`, from two listings of the palette's entries, are
/// the same entry: jumps to the same terminal, or commands of the same
/// title and action (two commands alike in both are one to the user).
pub fn sameEntry(a: *const Entry, b: *const Entry) bool {
    return switch (a.run) {
        .jump => |s| b.run == .jump and b.run.jump == s,
        .action => b.run == .action and
            std.mem.eql(u8, a.title, b.title) and
            std.mem.eql(u8, a.action_key, b.action_key),
    };
}

/// `surface` took the focus in its window's shown tab
/// (`Window.setFocused`): an open palette now runs on it. So the palette
/// always runs on a terminal of its window's shown tab: one whose tab is
/// replaced or moved to a new window hands it to the terminal of the tab
/// shown next. Not from a terminal that is closing, which passes the focus
/// on as it leaves its window: the palette closes with it (`forget`).
pub fn focusMoved(window: *Window, surface: *Surface) void {
    const p = &window.palette;
    if (p.hwnd == null) return;
    if (p.surface) |s| if (s.closing) return;
    p.surface = surface;
}

/// Draw the palette again, as the theme changed.
pub fn invalidate(window: *Window) void {
    const p = &window.palette;
    applyListTheme(window);
    if (p.hwnd) |h| _ = win32.InvalidateRect(h, null, .TRUE);
    if (p.edit) |h| _ = win32.InvalidateRect(h, null, .TRUE);
    if (p.list) |h| _ = win32.InvalidateRect(h, null, .TRUE);
}

/// The list's scrollbar in the frame's mode. The list is a system LISTBOX:
/// WM_CTLCOLORLISTBOX colours its rows' background, but Windows draws its
/// scrollbar with the window's visual style, light by default, a white
/// track beside the dark rows. So in a dark frame the list takes the
/// "DarkMode_Explorer" theme class, which gives it the dark scrollbar, as
/// Explorer, Notepad++ and Windows Terminal give their controls; and
/// "Explorer" back in a light frame. The class name is not documented: a
/// Windows without it keeps the light scrollbar. Only when the mode
/// changes, as each call sends the list WM_THEMECHANGED.
fn applyListTheme(window: *Window) void {
    const p = &window.palette;
    const list = p.list orelse return;
    if (p.list_dark) |dark| if (dark == window.dark_frame) return;
    p.list_dark = window.dark_frame;
    const class = if (window.dark_frame) L("DarkMode_Explorer") else L("Explorer");
    const hr = win32.SetWindowTheme(list, class, null);
    if (hr < 0) log.info("cannot set the command palette list's theme hr=0x{x}", .{@as(u32, @bitCast(hr))});
}

/// The system's message font changed: made again and placed.
pub fn fontChanged(window: *Window) void {
    if (window.palette.hwnd == null) return;
    window.palette.font_dpi = 0;
    _ = place(window);
}

/// Place `window`'s open palette at the top centre of the area under the
/// tab bar, above the terminals and their search bars; whether it shows.
/// One that no longer fits there (`paletteRect`) closes. Called by every
/// layout (`Window.relayout`), which never runs inside a core frame.
pub fn place(window: *Window) bool {
    const p = &window.palette;
    const hwnd = p.hwnd orelse return false;
    if (!p.open) return false;
    const dpi = Window.dpiOf(window.app, window.hwnd);
    p.applyFont(dpi);
    const m = Metrics.init(dpi);
    const area = window.layoutArea() orelse return false;
    const at = paletteRect(m, area, p.text_height) orelse {
        log.info("no room for the command palette", .{});
        close(window);
        return false;
    };
    const width = at.right - at.left;
    const height = at.bottom - at.top;
    _ = win32.SetWindowPos(hwnd, win32.HWND_TOP, at.left, at.top, width, height, win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW);
    const l = Layout.init(m, width, height, p.text_height);
    if (p.edit) |edit| _ = win32.SetWindowPos(edit, null, l.edit.left, l.edit.top, l.edit.right - l.edit.left, l.edit.bottom - l.edit.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    if (p.list) |list| _ = win32.SetWindowPos(list, null, l.list.left, l.list.top, l.list.right - l.list.left, l.list.bottom - l.list.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    invalidate(window);
    return true;
}

/// The field's text changed (EN_CHANGE): the list shows what matches it,
/// the first selected, as GTK's list selects its first item.
fn textChanged(window: *Window) void {
    const p = &window.palette;
    const edit = p.edit orelse return;
    const alloc = window.app.core_app.alloc;
    const len: usize = @intCast(@max(win32.GetWindowTextLengthW(edit), 0));
    const wide = alloc.alloc(u16, len + 1) catch |err| return log.warn("cannot read the command palette's field err={}", .{err});
    defer alloc.free(wide);
    const n: usize = @intCast(@max(win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));
    const query = utf8FromWide(alloc, wide[0..n]) catch |err| return log.warn("cannot read the command palette's field err={}", .{err});
    defer alloc.free(query);
    refill(window, query);
}

/// Fill the list with the entries that match `query` (`filter`), the
/// first selected.
fn refill(window: *Window, query: []const u8) void {
    const p = &window.palette;
    const list = p.list orelse return;
    const entries = p.entries orelse return;
    const alloc = window.app.core_app.alloc;
    filter(alloc, entries.items, query, &p.shown) catch |err| {
        log.warn("cannot filter the command palette err={}", .{err});
        p.shown.clearRetainingCapacity();
    };
    _ = win32.SendMessageW(list, win32.WM_SETREDRAW, 0, 0);
    _ = win32.SendMessageW(list, win32.LB_RESETCONTENT, 0, 0);
    for (p.shown.items) |index| {
        const wide = wideFromUtf8(alloc, entries.items[index].title) catch continue;
        defer alloc.free(wide);
        const row = win32.SendMessageW(list, win32.LB_ADDSTRING, 0, @bitCast(@intFromPtr(wide.ptr)));
        if (row < 0) continue;
        _ = win32.SendMessageW(list, win32.LB_SETITEMDATA, @intCast(row), index);
    }
    if (win32.SendMessageW(list, win32.LB_GETCOUNT, 0, 0) > 0) {
        _ = win32.SendMessageW(list, win32.LB_SETCURSEL, 0, 0);
        // A list with no room for a row, as this one is until `place`
        // sizes it, scrolls past the row it selects (its top becomes row
        // 1) and keeps that top once sized: so the top is set as well.
        _ = win32.SendMessageW(list, win32.LB_SETTOPINDEX, 0, 0);
    }
    _ = win32.SendMessageW(list, win32.WM_SETREDRAW, 1, 0);
    _ = win32.InvalidateRect(list, null, .TRUE);
}

/// Up, Down, PgUp or PgDn in the field: the selection moves by `by` rows,
/// a page being the rows the list shows (`step`).
fn move(window: *Window, by: enum { up, down, page_up, page_down }) void {
    const list = window.palette.list orelse return;
    const count = win32.SendMessageW(list, win32.LB_GETCOUNT, 0, 0);
    if (count <= 0) return;
    const cur = win32.SendMessageW(list, win32.LB_GETCURSEL, 0, 0);
    var client: RECT = undefined;
    if (!win32.GetClientRect(list, &client).toBool()) client.bottom = 0;
    const row = win32.SendMessageW(list, win32.LB_GETITEMHEIGHT, 0, 0);
    const page: isize = if (row > 0) @max(1, @divTrunc(client.bottom, @as(i32, @intCast(row)))) else 1;
    const delta: isize = switch (by) {
        .up => -1,
        .down => 1,
        .page_up => -page,
        .page_down => page,
    };
    const next = step(if (cur < 0) null else @intCast(cur), @intCast(count), delta) orelse return;
    _ = win32.SendMessageW(list, win32.LB_SETCURSEL, next, 0);
}

/// The row `delta` rows from `cur` among `count`, kept within them, as a
/// list's selection moves; from no selection, the first row down or the
/// last up. Null with no rows.
pub fn step(cur: ?usize, count: usize, delta: isize) ?usize {
    if (count == 0) return null;
    const from: isize = if (cur) |c| @intCast(@min(c, count - 1)) else if (delta > 0) -1 else @intCast(count);
    return @intCast(std.math.clamp(from + delta, 0, @as(isize, @intCast(count - 1))));
}

/// Run the entry on the list's `row`: the palette closes, then the entry
/// runs (`perform`). The entries are kept until it has.
fn runRow(window: *Window, row: usize) void {
    const p = &window.palette;
    const list = p.list orelse return;
    const surface = p.surface orelse return;
    if (p.entries == null) return;
    const data = win32.SendMessageW(list, win32.LB_GETITEMDATA, row, 0);
    if (data < 0 or @as(usize, @intCast(data)) >= p.entries.?.items.len) return;
    const entries = p.entries.?;
    p.entries = null;
    close(window);
    perform(surface, entries, @intCast(data));
}

/// Enter in the field: the selected row runs, if there is one.
fn runSelected(window: *Window) void {
    const list = window.palette.list orelse return;
    const cur = win32.SendMessageW(list, win32.LB_GETCURSEL, 0, 0);
    if (cur < 0) return;
    runRow(window, @intCast(cur));
}

/// Run `entries`' entry `index` on `surface`, owning `entries`: now if the
/// core may be re-entered, as the search bar performs its keys; else
/// recorded, with the entries, for `run` (`App.Request.palette_run`), as
/// a key in the field is (`overlay_keys`).
fn perform(surface: *Surface, entries: Entries, index: usize) void {
    const app = surface.app;
    const alloc = app.core_app.alloc;
    var owned = entries;
    if (!app.canReenterCore()) {
        // Every surface a request names is live (`App.requests`).
        const core = overlay_keys.coreOf(surface) orelse return owned.deinit();
        const pending = alloc.create(Pending) catch |err| {
            log.warn("cannot record a command palette entry err={}", .{err});
            return owned.deinit();
        };
        pending.* = .{ .entries = owned, .index = index };
        app.requests.append(alloc, .{ .palette_run = .{ .from = core, .pending = pending } }) catch |err| {
            log.warn("cannot record a command palette entry err={}", .{err});
            return pending.destroy(alloc);
        };
        app.wakeup();
        return;
    }
    defer owned.deinit();
    runNow(surface, owned.items[index].run);
}

/// An entry `perform` recorded, carried out by `run`, which frees it.
pub fn replay(surface: *Surface, pending: *Pending) void {
    defer pending.destroy(surface.app.core_app.alloc);
    runNow(surface, pending.entry().run);
}

/// An entry's action, performed on `surface` as a key's binding would be
/// (`SearchBar.perform`), then the focus move it chose; or the terminal
/// a jump focuses, its window brought forward if it is another, its tab
/// shown, as GTK presents it.
fn runNow(surface: *Surface, run: Entry.Run) void {
    switch (run) {
        .action => |action| {
            _ = SearchBar.perform(surface, action);
            surface.app.applyPendingFocus();
        },
        .jump => |target| {
            const window = target.window;
            if (window != surface.window) _ = window.present();
            window.focusFromGoto(target);
        },
    }
}

/// The procedure every EDIT and LISTBOX had before it was subclassed.
var edit_proc: ?win32.WNDPROC = null;
var list_proc: ?win32.WNDPROC = null;

/// For tests: how many WM_CHARs the field's subclass passed on to the EDIT.
pub var test_forwarded: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

/// The window whose palette the window `hwnd` is, null once it is
/// destroyed.
fn windowOf(hwnd: win32.HWND) ?*Window {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The window whose palette holds the child `hwnd`, while it is open.
fn windowOfChild(hwnd: win32.HWND) ?*Window {
    const parent = win32.GetAncestor(hwnd, win32.GA_PARENT) orelse return null;
    const window = windowOf(parent) orelse return null;
    if (window.palette.hwnd != parent or !window.palette.open) return null;
    return window;
}

/// The palette's window procedure. WM_NCCREATE brings its window.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(param)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const window = windowOf(hwnd) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const p = &window.palette;

    switch (msg) {
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            paint(window, hwnd);
            return 0;
        },

        // The field and the list in the palette's colours.
        win32.WM_CTLCOLOREDIT, win32.WM_CTLCOLORLISTBOX => {
            const colors = SearchBar.Colors.of(window.dark_frame);
            const hdc: win32.HDC = @ptrFromInt(wparam);
            _ = win32.SetTextColor(hdc, colors.text);
            _ = win32.SetBkColor(hdc, colors.field);
            const brush = p.brushOf(colors.field) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return @bitCast(@intFromPtr(brush));
        },

        win32.WM_COMMAND => {
            if (win32.hiword(wparam) == win32.EN_CHANGE and p.edit != null and
                lparam == @as(win32.LPARAM, @bitCast(@intFromPtr(p.edit.?)))) textChanged(window);
            return 0;
        },

        win32.WM_MEASUREITEM => {
            const measure: *win32.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            measure.itemHeight = @intCast(Metrics.init(Window.dpiOf(window.app, hwnd)).rowHeight(p.text_height));
            return 1;
        },

        win32.WM_DRAWITEM => {
            const dis: *const win32.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (p.list == null or dis.hwndItem != p.list) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            drawRow(window, dis);
            return 1;
        },

        // The wheel over the field, which passes it here, scrolls the list.
        // The system list hands a wheel it does not take (one with Ctrl or
        // Shift held, in the reference sources) to DefWindowProcW, which
        // sends it to the parent, this window: forwarded to the list again,
        // it would go round, each turn a nested SendMessage on this thread,
        // until the stack overflowed and took the process with it. So a
        // wheel that arrives while one is being forwarded is dropped: the
        // palette has nothing else to do with it, and its frame should not
        // zoom a terminal under it. A guard rather than a test of the
        // modifiers, as which wheels the list passes up is not documented.
        win32.WM_MOUSEWHEEL => {
            if (p.wheeling) return 0;
            const list = p.list orelse return 0;
            p.wheeling = true;
            defer p.wheeling = false;
            return win32.SendMessageW(list, msg, wparam, lparam);
        },

        WM_PALETTE_CLOSE => {
            // Unless the frame was activated again meanwhile.
            if (win32.GetActiveWindow() != window.hwnd) close(window);
            return 0;
        },

        win32.WM_DESTROY => {
            p.free(window.app.core_app.alloc);
            return 0;
        },

        win32.WM_NCDESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        },

        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The field's subclass: the list's keys, Enter and Escape, the keys an
/// EDIT gets wrong without a dialog manager, as in the search field
/// (`SearchBar.editKey`), then the terminal's bindings that still act from
/// a field (`overlay_keys`).
fn editProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    const proc = edit_proc.?;
    const window = windowOfChild(hwnd) orelse return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);

    if (msg == win32.WM_KEYDOWN) switch (wparam) {
        win32.VK_UP => {
            move(window, .up);
            return 0;
        },
        win32.VK_DOWN => {
            move(window, .down);
            return 0;
        },
        win32.VK_PRIOR => {
            move(window, .page_up);
            return 0;
        },
        win32.VK_NEXT => {
            move(window, .page_down);
            return 0;
        },
        else => {},
    };
    switch (SearchBar.editKey(msg, wparam, false)) {
        .pass => {},
        .swallow => return 0,
        // Nothing of the field is touched after either: it is destroyed.
        // The release is withheld wherever the focus went, a jump's
        // terminal in another window included.
        .next, .previous => {
            runSelected(window);
            closedByKey(window.app, lparam);
            return 0;
        },
        .close => {
            close(window);
            closedByKey(window.app, lparam);
            return 0;
        },
        .delete_word => {
            SearchBar.deleteWord(window.app.core_app.alloc, hwnd);
            return 0;
        },
    }
    if (window.palette.surface) |surface| {
        if (overlay_keys.keyDown(surface, hwnd, proc, msg, wparam, lparam, .palette)) return 0;
    }
    if (builtin.is_test) if (msg == win32.WM_CHAR) {
        test_forwarded += 1;
    };
    return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

/// The list's subclass: a click on a row selects it, and runs it when the
/// button comes up on the same row, as GTK's list runs a row on a single
/// click; the keyboard focus stays in the field.
fn listProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    const proc = list_proc.?;
    const window = windowOfChild(hwnd) orelse return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
    const p = &window.palette;
    switch (msg) {
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK => {
            if (p.edit) |edit| window.setKeyboardFocus(edit, true);
            const row = rowAt(hwnd, lparam) orelse return 0;
            _ = win32.SendMessageW(hwnd, win32.LB_SETCURSEL, row, 0);
            // Captured first: SetCapture cancels a press the list held.
            if (win32.GetCapture() != hwnd) _ = win32.SetCapture(hwnd);
            p.pressed = row;
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const pressed = p.pressed;
            p.pressed = null;
            if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
            const row = rowAt(hwnd, lparam) orelse return 0;
            if (pressed != row) return 0;
            // Nothing of the list is touched after: it is destroyed.
            runRow(window, row);
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            p.pressed = null;
            return 0;
        },
        // Keys go to the field, which moves the list.
        win32.WM_SETFOCUS => {
            if (p.edit) |edit| window.setKeyboardFocus(edit, true);
            return 0;
        },
        else => {},
    }
    return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

/// The row under the list's client point in `lparam`, if any.
fn rowAt(list: win32.HWND, lparam: win32.LPARAM) ?usize {
    const x = win32.xLparam(lparam);
    const y = win32.yLparam(lparam);
    if (x < 0 or y < 0) return null;
    const at: usize = @bitCast(win32.SendMessageW(list, win32.LB_ITEMFROMPOINT, 0, lparam));
    // The high word is 1 for a point past the last row.
    if ((at >> 16) & 0xFFFF != 0) return null;
    return at & 0xFFFF;
}

fn paint(window: *Window, hwnd: win32.HWND) void {
    const p = &window.palette;
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = win32.EndPaint(hwnd, &ps);
    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) return;
    const dpi = Window.dpiOf(window.app, hwnd);
    const colors = SearchBar.Colors.of(window.dark_frame);
    const m = Metrics.init(dpi);
    const l = Layout.init(m, client.right, client.bottom, p.text_height);
    const line = @max(1, SearchBar.Metrics.scale(1, dpi));
    // The palette, framed; the field's box, framed, behind the EDIT.
    SearchBar.fill(hdc, client, colors.border);
    SearchBar.fill(hdc, SearchBar.inset(client, line), colors.bar);
    SearchBar.fill(hdc, l.field, colors.border);
    SearchBar.fill(hdc, SearchBar.inset(l.field, line), colors.field);
}

/// One of the list's rows: its background, selected or not, the title and
/// under it the action key or the description, and the shortcut on the
/// right, centred down the row, as GTK's row shows them.
fn drawRow(window: *Window, dis: *const win32.DRAWITEMSTRUCT) void {
    const p = &window.palette;
    const colors = SearchBar.Colors.of(window.dark_frame);
    const hdc = dis.hDC;
    const selected = dis.itemState & win32.ODS_SELECTED != 0;
    SearchBar.fill(hdc, dis.rcItem, if (selected) colors.hover else colors.field);
    // An empty list's focus rect has no item.
    if (dis.itemID == std.math.maxInt(win32.UINT)) return;
    const entries = p.entries orelse return;
    if (dis.itemData >= entries.items.len) return;
    const entry = &entries.items[dis.itemData];
    const alloc = window.app.core_app.alloc;

    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    const old_font = if (p.font) |f| win32.SelectObject(hdc, f) else null;
    defer if (old_font) |f| {
        _ = win32.SelectObject(hdc, f);
    };
    const m = Metrics.init(Window.dpiOf(window.app, dis.hwndItem orelse window.hwnd));
    const flags = win32.DT_SINGLELINE | win32.DT_NOPREFIX;

    // The shortcut's width first, as the title gives way to it.
    var shortcut_w: i32 = 0;
    const shortcut = wideFromUtf8(alloc, entry.shortcut) catch null;
    defer if (shortcut) |s| alloc.free(s);
    if (shortcut) |s| if (s.len > 0) {
        var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = win32.DrawTextW(hdc, s.ptr, @intCast(s.len), &r, flags | win32.DT_CALCRECT);
        shortcut_w = r.right - r.left;
    };
    const row = Row.init(m, dis.rcItem, p.text_height, shortcut_w);
    if (shortcut) |s| if (s.len > 0) {
        var r = row.shortcut;
        _ = win32.SetTextColor(hdc, colors.dim);
        _ = win32.DrawTextW(hdc, s.ptr, @intCast(s.len), &r, flags | win32.DT_RIGHT | win32.DT_VCENTER);
    };
    if (wideFromUtf8(alloc, entry.title)) |title| {
        defer alloc.free(title);
        var r = row.title;
        _ = win32.SetTextColor(hdc, colors.text);
        _ = win32.DrawTextW(hdc, title.ptr, @intCast(title.len), &r, flags | win32.DT_END_ELLIPSIS);
    } else |_| {}
    const sub = entry.subtitle();
    if (sub.len > 0) if (wideFromUtf8(alloc, sub)) |text| {
        defer alloc.free(text);
        var r = row.subtitle;
        _ = win32.SetTextColor(hdc, colors.dim);
        _ = win32.DrawTextW(hdc, text.ptr, @intCast(text.len), &r, flags | win32.DT_END_ELLIPSIS);
    } else |_| {};
}

/// The palette's sizes at a DPI, from their values at 96 DPI: GTK's
/// dialog is 700 wide (command-palette.blp's `content-width`) and its list
/// at least 300 tall (`min-content-height`), eight rows here.
pub const Metrics = struct {
    /// Between the palette and the top and sides of the area under the
    /// tab bar.
    margin: i32,
    /// Its width, and the least it narrows to before it no longer fits.
    width: i32,
    min_width: i32,
    /// Inside its edges, and between the field and the list.
    pad: i32,
    gap: i32,
    /// Between the field's box and its text.
    inset: i32,
    /// Above and below a row's two lines, and either side of them.
    row_pad: i32,
    row_inset: i32,
    /// The rows the list shows when there is room.
    rows: i32,

    pub fn init(dpi: u32) Metrics {
        const s = SearchBar.Metrics.scale;
        return .{
            .margin = s(8, dpi),
            .width = s(700, dpi),
            .min_width = s(240, dpi),
            .pad = s(8, dpi),
            .gap = s(6, dpi),
            .inset = s(4, dpi),
            .row_pad = s(4, dpi),
            .row_inset = s(8, dpi),
            .rows = 8,
        };
    }

    /// The field's box, for a line of text `text_height` tall.
    pub fn boxHeight(self: Metrics, text_height: i32) i32 {
        return @max(0, text_height) + 2 * self.inset;
    }

    /// A row: two lines of text.
    pub fn rowHeight(self: Metrics, text_height: i32) i32 {
        return 2 * @max(0, text_height) + 2 * self.row_pad;
    }

    /// Above the list: the edge and the field.
    fn head(self: Metrics, text_height: i32) i32 {
        return self.pad + self.boxHeight(text_height) + self.gap;
    }
};

/// Where the palette goes in `area`, the frame's client area under the tab
/// bar: `margin` below its top, centred across it, `width` wide or as wide
/// as the area leaves, with as many rows up to `rows` as its height
/// leaves; null when it leaves less than `min_width` or one row.
pub fn paletteRect(m: Metrics, area: RECT, text_height: i32) ?RECT {
    const room_w = area.right - area.left - 2 * m.margin;
    const width = @min(m.width, room_w);
    if (width < m.min_width) return null;
    const row = m.rowHeight(text_height);
    const room_h = area.bottom - area.top - 2 * m.margin - m.head(text_height) - m.pad;
    if (row <= 0 or room_h < row) return null;
    const rows = @min(m.rows, @divTrunc(room_h, row));
    const left = area.left + @divTrunc(area.right - area.left - width, 2);
    const top = area.top + m.margin;
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + m.head(text_height) + rows * row + m.pad };
}

/// What a palette `width` by `height` holds, in its own client
/// coordinates: the field's box at the top (the EDIT inside it, as tall
/// as a line of text), and the list under it to the bottom edge.
pub const Layout = struct {
    field: RECT,
    edit: RECT,
    list: RECT,

    pub fn init(m: Metrics, width: i32, height: i32, text_height: i32) Layout {
        const right = @max(m.pad, width - m.pad);
        const field: RECT = .{ .left = m.pad, .top = m.pad, .right = right, .bottom = m.pad + m.boxHeight(text_height) };
        const edit: RECT = .{
            .left = field.left + m.inset,
            .top = field.top + m.inset,
            .right = @max(field.left + m.inset, field.right - m.inset),
            .bottom = field.top + m.inset + @max(0, text_height),
        };
        const top = m.head(text_height);
        const list: RECT = .{ .left = m.pad, .top = top, .right = right, .bottom = @max(top, height - m.pad) };
        return .{ .field = field, .edit = edit, .list = list };
    }
};

/// A row of the list at `item`: the title on the first line and the
/// subtitle on the second, `row_inset` in from either side, leaving the
/// shortcut, `shortcut_w` wide, on the right, centred down the row.
pub const Row = struct {
    title: RECT,
    subtitle: RECT,
    shortcut: RECT,

    pub fn init(m: Metrics, item: RECT, text_height: i32, shortcut_w: i32) Row {
        const right = @max(item.left + m.row_inset, item.right - m.row_inset);
        const shortcut_left = @max(item.left + m.row_inset, right - @max(0, shortcut_w));
        const text_right = if (shortcut_w > 0) @max(item.left + m.row_inset, shortcut_left - m.row_inset) else right;
        const h = @max(0, text_height);
        const top = item.top + m.row_pad;
        return .{
            .title = .{ .left = item.left + m.row_inset, .top = top, .right = text_right, .bottom = top + h },
            .subtitle = .{ .left = item.left + m.row_inset, .top = top + h, .right = text_right, .bottom = top + 2 * h },
            .shortcut = .{ .left = shortcut_left, .top = item.top, .right = right, .bottom = item.bottom },
        };
    }
};

const testing = std.testing;
const Config = @import("../../config.zig").Config;

test "win32: the command palette sits at the top centre of the area under the tab bar, or not at all" {
    const m = Metrics.init(96);
    try testing.expectEqual(16 + 8, m.boxHeight(16));
    try testing.expectEqual(32 + 8, m.rowHeight(16));
    try testing.expectEqual(1050, Metrics.init(144).width);
    // A wide area: 700 wide, centred, 8 below its top, with eight rows.
    const area: RECT = .{ .left = 0, .top = 30, .right = 1000, .bottom = 800 };
    const head = 8 + 24 + 6;
    try testing.expectEqual(RECT{ .left = 150, .top = 38, .right = 850, .bottom = 38 + head + 8 * 40 + 8 }, paletteRect(m, area, 16).?);
    // A narrower one: the palette narrows to it, down to 240.
    const narrow = paletteRect(m, .{ .left = 100, .top = 0, .right = 500, .bottom = 800 }, 16).?;
    try testing.expectEqual(RECT{ .left = 108, .top = 8, .right = 492, .bottom = 8 + head + 8 * 40 + 8 }, narrow);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 256, .bottom = 800 }, 16) != null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 255, .bottom = 800 }, 16) == null);
    // A short one: fewer rows, down to one.
    const short = paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 8 + head + 3 * 40 + 39 + 8 + 8 }, 16).?;
    try testing.expectEqual(head + 3 * 40 + 8, short.bottom - short.top);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 8 + head + 40 + 8 + 8 }, 16) != null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 8 + head + 40 + 8 + 7 }, 16) == null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, 16) == null);
}

test "win32: the command palette's field and list, and a row's parts" {
    const m = Metrics.init(96);
    const l = Layout.init(m, 700, 400, 16);
    try testing.expectEqual(RECT{ .left = 8, .top = 8, .right = 692, .bottom = 32 }, l.field);
    try testing.expectEqual(RECT{ .left = 12, .top = 12, .right = 688, .bottom = 28 }, l.edit);
    try testing.expectEqual(RECT{ .left = 8, .top = 38, .right = 692, .bottom = 392 }, l.list);
    // No room: nothing negative.
    const none = Layout.init(m, 0, 0, 0);
    try testing.expect(none.edit.right >= none.edit.left and none.list.bottom >= none.list.top);

    const item: RECT = .{ .left = 0, .top = 40, .right = 600, .bottom = 80 };
    const r = Row.init(m, item, 16, 100);
    try testing.expectEqual(RECT{ .left = 492, .top = 40, .right = 592, .bottom = 80 }, r.shortcut);
    try testing.expectEqual(RECT{ .left = 8, .top = 44, .right = 484, .bottom = 60 }, r.title);
    try testing.expectEqual(RECT{ .left = 8, .top = 60, .right = 484, .bottom = 76 }, r.subtitle);
    // No shortcut: the text goes to the right edge.
    try testing.expectEqual(592, Row.init(m, item, 16, 0).title.right);
}

test "win32: the command palette's selection moves within its rows" {
    try testing.expectEqual(1, step(0, 5, 1).?);
    try testing.expectEqual(0, step(1, 5, -1).?);
    // Kept within them, not wrapped.
    try testing.expectEqual(0, step(0, 5, -1).?);
    try testing.expectEqual(4, step(4, 5, 1).?);
    try testing.expectEqual(4, step(1, 5, 8).?);
    try testing.expectEqual(0, step(3, 5, -8).?);
    // From no selection: the first down, the last up.
    try testing.expectEqual(0, step(null, 5, 1).?);
    try testing.expectEqual(4, step(null, 5, -1).?);
    try testing.expect(step(null, 0, 1) == null);
    try testing.expect(step(2, 0, -1) == null);
}

fn testLabel(buf: []u8, trigger: Binding.Trigger) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try testing.expect(try shortcutLabel(&w, trigger));
    return w.buffered();
}

test "win32: a palette entry's shortcut in Windows' key names" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+T", try testLabel(&buf, .{ .key = .{ .unicode = 't' }, .mods = .{ .ctrl = true, .shift = true } }));
    // Win, Ctrl, Alt, Shift, whatever order they were written in.
    try testing.expectEqualStrings("Win+Ctrl+Alt+Shift+Q", try testLabel(&buf, .{ .key = .{ .unicode = 'q' }, .mods = .{ .shift = true, .alt = true, .ctrl = true, .super = true } }));
    try testing.expectEqualStrings("Ctrl+Plus", try testLabel(&buf, .{ .key = .{ .unicode = '+' }, .mods = .{ .ctrl = true } }));
    try testing.expectEqualStrings("Ctrl+=", try testLabel(&buf, .{ .key = .{ .unicode = '=' }, .mods = .{ .ctrl = true } }));
    try testing.expectEqualStrings("Ctrl+Space", try testLabel(&buf, .{ .key = .{ .unicode = ' ' }, .mods = .{ .ctrl = true } }));
    try testing.expectEqualStrings("Alt+\u{00E9}", try testLabel(&buf, .{ .key = .{ .unicode = 0xE9 }, .mods = .{ .alt = true } }));
    // Physical keys: by name, letters and digits as they type, the number
    // pad's marked.
    try testing.expectEqualStrings("Ctrl+Shift+Enter", try testLabel(&buf, .{ .key = .{ .physical = .enter }, .mods = .{ .ctrl = true, .shift = true } }));
    try testing.expectEqualStrings("Shift+PgUp", try testLabel(&buf, .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true } }));
    try testing.expectEqualStrings("Ctrl+Alt+Left", try testLabel(&buf, .{ .key = .{ .physical = .arrow_left }, .mods = .{ .ctrl = true, .alt = true } }));
    try testing.expectEqualStrings("Ctrl+A", try testLabel(&buf, .{ .key = .{ .physical = .key_a }, .mods = .{ .ctrl = true } }));
    try testing.expectEqualStrings("Ctrl+0", try testLabel(&buf, .{ .key = .{ .physical = .digit_0 }, .mods = .{ .ctrl = true } }));
    try testing.expectEqualStrings("Ctrl+[", try testLabel(&buf, .{ .key = .{ .physical = .bracket_left }, .mods = .{ .ctrl = true } }));
    try testing.expectEqualStrings("Num +", try testLabel(&buf, .{ .key = .{ .physical = .numpad_add } }));
    try testing.expectEqualStrings("Num 5", try testLabel(&buf, .{ .key = .{ .physical = .numpad_5 } }));
    try testing.expectEqualStrings("F11", try testLabel(&buf, .{ .key = .{ .physical = .f11 } }));
    try testing.expectEqualStrings("Esc", try testLabel(&buf, .{ .key = .{ .physical = .escape } }));
    try testing.expectEqualStrings("Audio Volume Up", try testLabel(&buf, .{ .key = .{ .physical = .audio_volume_up } }));
    // No one key: no label.
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expect(!try shortcutLabel(&w, .{ .key = .catch_all, .mods = .{ .ctrl = true } }));
    try testing.expectEqual(0, w.buffered().len);
}

test "win32: the palette's entries are the supported commands and a jump per terminal, sorted" {
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    const commands = config.@"command-palette-entry".value.items;

    // Fake terminals: a jump only carries its pointer.
    const one: *Surface = @ptrFromInt(0x10000);
    const two: *Surface = @ptrFromInt(0x20000);
    const three: *Surface = @ptrFromInt(0x30000);
    const jumps = [_]Jump{
        .{ .surface = one, .title = "vim", .pwd = "C:\\src" },
        .{ .surface = two, .title = null },
        // Its title shows its directory already.
        .{ .surface = three, .title = "C:\\src - cmd", .pwd = "C:\\src" },
        .{ .surface = one, .title = "vim" },
    };
    var entries = try build(alloc, commands, &config.keybind.set, &jumps);
    defer entries.deinit();

    var commands_kept: usize = 0;
    for (commands) |c| {
        if (supported(c.action)) commands_kept += 1;
    }
    // Some are left out: the inspector, undo, the tab overview.
    try testing.expect(commands_kept < commands.len);
    try testing.expectEqual(commands_kept + jumps.len, entries.items.len);

    // Sorted as GTK sorts them; nothing unsupported.
    for (entries.items[0 .. entries.items.len - 1], entries.items[1..]) |a, b| {
        try testing.expect(!lessThan({}, b, a));
    }
    var saw_split = false;
    var saw_tab = false;
    for (entries.items) |*e| switch (e.run) {
        .action => |action| {
            try testing.expect(supported(action));
            try testing.expect(e.action_key.len > 0);
            // The entry's own copy, not the configuration's.
            for (commands) |c| try testing.expect(c.title.ptr != e.title.ptr);
            if (std.mem.eql(u8, e.action_key, "new_split:right")) {
                saw_split = true;
                try testing.expectEqualStrings("Split Right", e.title);
                try testing.expectEqualStrings("Ctrl+Shift+O", e.shortcut);
                try testing.expectEqualStrings(e.action_key, e.subtitle());
            }
            if (std.mem.eql(u8, e.action_key, "new_tab")) {
                saw_tab = true;
                try testing.expectEqualStrings("Ctrl+Shift+T", e.shortcut);
            }
            try testing.expect(std.mem.indexOf(u8, e.action_key, "inspector") == null);
            try testing.expect(!std.mem.eql(u8, e.action_key, "undo"));
            try testing.expect(!std.mem.eql(u8, e.action_key, "toggle_tab_overview"));
        },
        .jump => {},
    };
    try testing.expect(saw_split and saw_tab);

    // The jumps: "Focus: <title>", "Untitled" for none, the directory as
    // the description unless the title shows it; two of the same title in
    // their terminals' order.
    var focus: [4]*const Entry = undefined;
    var n: usize = 0;
    for (entries.items) |*e| if (e.run == .jump) {
        focus[n] = e;
        n += 1;
    };
    try testing.expectEqual(4, n);
    try testing.expectEqualStrings("Focus: C:\\src - cmd", focus[0].title);
    try testing.expectEqualStrings("", focus[0].description);
    try testing.expectEqualStrings("Focus: Untitled", focus[1].title);
    try testing.expectEqualStrings("Focus: vim", focus[2].title);
    try testing.expectEqualStrings("C:\\src", focus[2].description);
    try testing.expectEqualStrings("C:\\src", focus[2].subtitle());
    try testing.expectEqual(0, focus[2].sort_key);
    try testing.expectEqualStrings("Focus: vim", focus[3].title);
    try testing.expectEqual(3, focus[3].sort_key);
    try testing.expect(focus[2].run.jump == one);
    try testing.expectEqualStrings("", focus[3].shortcut);
    try testing.expectEqualStrings("", focus[3].action_key);
}

test "win32: the palette sorts as GTK's does" {
    const e = struct {
        fn of(title: []const u8) Entry {
            return .{ .title = title, .run = .{ .action = .ignore } };
        }
    }.of;
    // A colon before a space: "Foo:" before "Foo Bar:".
    try testing.expect(lessThan({}, e("Foo: x"), e("Foo Bar: x")));
    try testing.expect(!lessThan({}, e("Foo Bar: x"), e("Foo: x")));
    // Case is ignored; a title before the longer one it begins.
    try testing.expect(lessThan({}, e("apple"), e("Banana")));
    try testing.expect(!lessThan({}, e("Banana"), e("apple")));
    try testing.expect(lessThan({}, e("Split"), e("split right")));
    // Equal titles are equal, unless both are jumps.
    try testing.expect(!lessThan({}, e("Same"), e("same")));
    const a: Entry = .{ .title = "Focus: x", .run = .{ .jump = @ptrFromInt(0x10000) }, .sort_key = 1 };
    const b: Entry = .{ .title = "Focus: x", .run = .{ .jump = @ptrFromInt(0x20000) }, .sort_key = 2 };
    try testing.expect(lessThan({}, a, b));
    try testing.expect(!lessThan({}, b, a));
}

/// For tests: the titles `filter` picks for `query`, joined by '|'.
fn testFiltered(buf: []u8, entries: []const Entry, query: []const u8) ![]const u8 {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try filter(testing.allocator, entries, query, &out);
    var w: std.Io.Writer = .fixed(buf);
    for (out.items, 0..) |i, n| {
        if (n > 0) try w.writeByte('|');
        try w.writeAll(entries[i].title);
    }
    return w.buffered();
}

/// For tests: `entries` folded for the filter (`withFolded`), in `arena`.
fn testFolded(arena: Allocator, comptime entries: []const Entry) ![entries.len]Entry {
    var out: [entries.len]Entry = undefined;
    for (entries, &out) |e, *o| o.* = try withFolded(arena, e);
    return out;
}

test "win32: the palette filters on title and action, title matches first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const entries = try testFolded(arena.allocator(), &.{
        .{ .title = "Previous", .action_key = "previous_tab", .run = .{ .action = .ignore } },
        .{ .title = "Close Tab", .action_key = "close_tab:this", .run = .{ .action = .ignore } },
        .{ .title = "New Split", .action_key = "new_split:right", .run = .{ .action = .ignore } },
        .{ .title = "Split Zoom", .action_key = "toggle_split_zoom", .run = .{ .action = .ignore } },
        .{ .title = "Focus: tab", .description = "C:\\split", .run = .{ .jump = @ptrFromInt(0x10000) } },
        .{ .title = "Next", .action_key = "next_tab", .run = .{ .action = .ignore } },
    });
    var buf: [256]u8 = undefined;
    // Empty: everything, in order.
    try testing.expectEqualStrings("Previous|Close Tab|New Split|Split Zoom|Focus: tab|Next", try testFiltered(&buf, &entries, ""));
    // Any case; titles first, then action keys, each in order; a jump's
    // description is not searched.
    try testing.expectEqualStrings("New Split|Split Zoom", try testFiltered(&buf, &entries, "SPLIT"));
    try testing.expectEqualStrings("Close Tab|Focus: tab|Previous|Next", try testFiltered(&buf, &entries, "tab"));
    try testing.expectEqualStrings("Next", try testFiltered(&buf, &entries, "next_"));
    try testing.expectEqualStrings("Close Tab", try testFiltered(&buf, &entries, ":this"));
    try testing.expectEqualStrings("", try testFiltered(&buf, &entries, "zzz"));
    // Longer than any title or action key.
    try testing.expectEqualStrings("", try testFiltered(&buf, &entries, "previous_tab_and_more"));
    try testing.expectEqual(Match.title, match(&entries[1], "tab"));
    try testing.expectEqual(Match.action_key, match(&entries[5], "_tab"));
    try testing.expectEqual(Match.none, match(&entries[4], "split"));
}

test "win32: two listings' entries are the same entry by jump target, or title and action" {
    const one: *Surface = @ptrFromInt(0x10000);
    const two: *Surface = @ptrFromInt(0x20000);
    const jump: Entry = .{ .title = "Focus: a", .run = .{ .jump = one } };
    // A jump by its terminal, whatever its title now.
    try testing.expect(sameEntry(&jump, &.{ .title = "Focus: b", .run = .{ .jump = one } }));
    try testing.expect(!sameEntry(&jump, &.{ .title = "Focus: a", .run = .{ .jump = two } }));
    try testing.expect(!sameEntry(&jump, &.{ .title = "Focus: a", .action_key = "ignore", .run = .{ .action = .ignore } }));
    // A command by its title and its action.
    const command: Entry = .{ .title = "Split Right", .action_key = "new_split:right", .run = .{ .action = .{ .new_split = .right } } };
    try testing.expect(sameEntry(&command, &.{ .title = "Split Right", .action_key = "new_split:right", .run = .{ .action = .{ .new_split = .right } } }));
    try testing.expect(!sameEntry(&command, &.{ .title = "Split", .action_key = "new_split:right", .run = .{ .action = .{ .new_split = .right } } }));
    try testing.expect(!sameEntry(&command, &.{ .title = "Split Right", .action_key = "new_split:left", .run = .{ .action = .{ .new_split = .left } } }));
    try testing.expect(!sameEntry(&command, &.{ .title = "Split Right", .run = .{ .jump = one } }));
}

test "win32: the palette's filter ignores case beyond ASCII, as GTK's folds it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unicode's full folding: one code point to its folded form, or to
    // several ("ß" is "ss"); ASCII to lower case; what is not UTF-8 kept.
    try testing.expectEqualStrings("focus: überblick", try fold(a, "Focus: ÜBERBLICK"));
    try testing.expectEqualStrings("σύνοψη", try fold(a, "ΣΎΝΟΨΗ"));
    try testing.expectEqualStrings("обзор", try fold(a, "ОБЗОР"));
    try testing.expectEqualStrings("strasse", try fold(a, "Straße"));
    try testing.expectEqualStrings("strasse", try fold(a, "STRASSE"));
    try testing.expectEqualStrings("a\xffb\xc3", try fold(a, "A\xffB\xc3"));
    try testing.expectEqualStrings("", try fold(a, ""));

    const entries = try testFolded(a, &.{
        .{ .title = "Focus: Überblick", .run = .{ .jump = @ptrFromInt(0x10000) } },
        .{ .title = "Focus: σύνοψη", .run = .{ .jump = @ptrFromInt(0x20000) } },
        .{ .title = "Focus: ОБЗОР", .run = .{ .jump = @ptrFromInt(0x30000) } },
        .{ .title = "Focus: Straße", .run = .{ .jump = @ptrFromInt(0x40000) } },
        .{ .title = "Focus: STRASSE 2", .run = .{ .jump = @ptrFromInt(0x50000) } },
        .{ .title = "Ändern", .action_key = "prompt_tab_title", .run = .{ .action = .ignore } },
    });
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Focus: Überblick", try testFiltered(&buf, &entries, "focus: überblick"));
    try testing.expectEqualStrings("Focus: Überblick", try testFiltered(&buf, &entries, "ÜBER"));
    try testing.expectEqualStrings("Focus: σύνοψη", try testFiltered(&buf, &entries, "ΣΎΝΟ"));
    try testing.expectEqualStrings("Focus: ОБЗОР", try testFiltered(&buf, &entries, "обзор"));
    // "ß" and "SS" find each other.
    try testing.expectEqualStrings("Focus: Straße|Focus: STRASSE 2", try testFiltered(&buf, &entries, "straße"));
    try testing.expectEqualStrings("Focus: Straße|Focus: STRASSE 2", try testFiltered(&buf, &entries, "STRASSE"));
    // Title matches still first, then the action key's.
    try testing.expectEqualStrings("Ändern", try testFiltered(&buf, &entries, "äNDERN"));
    try testing.expectEqualStrings("Ändern", try testFiltered(&buf, &entries, "TAB_TITLE"));
}

test "win32: the palette's filter narrows as the query grows, and keeps the order" {
    // Metamorphic, over the default commands and their shortcuts, jumps
    // titled in scripts with case beyond ASCII, and every prefix (whole
    // code points) of queries made from their own titles and action keys,
    // in a random case: extending a query never adds an entry; within the
    // title matches and within the rest the entries' order is kept; and
    // each result is exactly the entries that match.
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    const jumps = [_]Jump{
        .{ .surface = @ptrFromInt(0x10000), .title = "Überblick" },
        .{ .surface = @ptrFromInt(0x20000), .title = "σύνοψη ΣΎΝΟΨΗ" },
        .{ .surface = @ptrFromInt(0x30000), .title = "Обзор" },
        .{ .surface = @ptrFromInt(0x40000), .title = "Straße" },
    };
    var entries = try build(alloc, config.@"command-palette-entry".value.items, &config.keybind.set, &jumps);
    defer entries.deinit();
    const items = entries.items;

    var prev: std.ArrayList(u32) = .empty;
    defer prev.deinit(alloc);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(alloc);
    var seed: std.Random.DefaultPrng = .init(0x9a1e77e);
    const rand = seed.random();
    var checked: usize = 0;
    // Upper and lower case of the letters beyond ASCII the jumps use.
    const cases = [_][2][]const u8{
        .{ "ü", "Ü" },
        .{ "σ", "Σ" },
        .{ "ύ", "Ύ" },
        .{ "ν", "Ν" },
        .{ "ο", "Ο" },
        .{ "ψ", "Ψ" },
        .{ "η", "Η" },
        .{ "о", "О" },
        .{ "б", "Б" },
        .{ "з", "З" },
        .{ "р", "Р" },
        .{ "ß", "SS" },
    };
    var wide_queries: usize = 0;
    for (0..300) |round| {
        // Part of an entry's title or action key, from a code point on,
        // each letter in a random case; every fourth from a jump.
        const index: usize = if (round % 4 != 0)
            rand.uintLessThan(usize, items.len)
        else for (items, 0..) |e, k| {
            if (e.run == .jump and e.sort_key == round / 4 % jumps.len) break k;
        } else unreachable;
        const from = items[index];
        const source = if (from.action_key.len == 0 or rand.boolean()) from.title else from.action_key;
        var start = rand.uintLessThan(usize, source.len);
        while (start > 0 and source[start] & 0xC0 == 0x80) start -= 1;
        var query_buf: [96]u8 = undefined;
        var len: usize = 0;
        var at = start;
        var wide = false;
        while (at < source.len) {
            const n = std.unicode.utf8ByteSequenceLength(source[at]) catch unreachable;
            const ch = source[at..][0..n];
            at += n;
            var one: [1]u8 = .{if (rand.boolean()) std.ascii.toUpper(ch[0]) else std.ascii.toLower(ch[0])};
            const piece: []const u8 = if (n == 1) &one else for (cases) |c| {
                if (std.mem.eql(u8, ch, c[0]) or std.mem.eql(u8, ch, c[1])) break c[rand.uintLessThan(usize, 2)];
            } else ch;
            if (len + piece.len > 64) break;
            if (n > 1) wide = true;
            @memcpy(query_buf[len..][0..piece.len], piece);
            len += piece.len;
        }
        if (wide) wide_queries += 1;
        try filter(alloc, items, "", &prev);
        for (0..len + 1) |n| {
            // Whole code points only.
            if (n < len and query_buf[n] & 0xC0 == 0x80) continue;
            const query = query_buf[0..n];
            const folded = try fold(alloc, query);
            defer alloc.free(folded);
            try filter(alloc, items, query, &next);
            // Narrower: everything in `next` was in `prev`.
            for (next.items) |i| try testing.expect(std.mem.indexOfScalar(u32, prev.items, i) != null);
            // Exactly the matches, title matches first, each kind in order.
            var count: usize = 0;
            for (items) |*e| {
                if (match(e, folded) != .none) count += 1;
            }
            try testing.expectEqual(count, next.items.len);
            var past_titles = false;
            for (next.items, 0..) |i, k| {
                const m = match(&items[i], folded);
                try testing.expect(m != .none);
                if (m == .action_key) past_titles = true;
                if (past_titles) try testing.expectEqual(Match.action_key, m);
                if (k > 0 and match(&items[next.items[k - 1]], folded) == m) {
                    try testing.expect(next.items[k - 1] < i);
                }
            }
            // The entry the query was made from is among them, whatever
            // the case of each letter.
            try testing.expect(std.mem.indexOfScalar(u32, next.items, @intCast(index)) != null);
            std.mem.swap(std.ArrayList(u32), &prev, &next);
            checked += 1;
        }
    }
    try testing.expect(checked > 300);
    // Enough of them reach beyond ASCII.
    try testing.expect(wide_queries > 30);
}
