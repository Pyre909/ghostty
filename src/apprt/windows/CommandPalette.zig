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
const unsafeCodepoint = @import("App.zig").unsafeCodepoint;

const Binding = input.Binding;
const i18n = @import("../../os/main.zig").i18n;
const uucode = @import("uucode");
const unicode = @import("../../unicode/main.zig");
const terminal = @import("../../terminal/main.zig");

/// Whether this runtime carries out `key`, and so lists a command with
/// it. An exhaustive switch, as `actionCommands` in src/input/command.zig
/// is, so that a new action does not compile until it is given an answer
/// here. An action the core performs itself is supported; one the core
/// hands to this runtime only if `App.performAction` handles what it
/// becomes. GTK's palette leaves out the actions it cannot perform the
/// same way (`isActionSupportedOnGtk`). A global keybind whose actions are
/// all left out, `ignore` aside, is refused as well
/// (`Hotkeys.performsNone`).
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
        .toggle_mouse_reporting,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .end_key_sequence,
        .crash,
        // Handed to this runtime, which performs what they become.
        // `toggle_readonly` flips the core's flag, then hands over
        // `readonly`, the badge.
        .toggle_readonly,
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
        .prompt_window_title,
        .set_surface_title,
        .set_tab_title,
        .set_window_title,
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
        .toggle_background_opacity,
        .set_window_theme,
        .reset_window_size,
        .toggle_command_palette,
        .toggle_tab_overview,
        .toggle_quick_terminal,
        .toggle_visibility,
        .open_config,
        .reload_config,
        .quit,
        .inspector,
        .show_on_screen_keyboard,
        .undo,
        .redo,
        => true,

        // Nothing to do.
        .ignore,
        .unbind,
        // Windows has no selection clipboard (`Surface.supportsClipboard`).
        .paste_from_selection,
        // What these become, `App.performAction` does not handle: there is
        // no GTK inspector, updater or secure input here.
        .close_all_windows,
        .check_for_updates,
        .show_gtk_inspector,
        .toggle_secure_input,
        => false,
    };
}

/// One row of the palette.
pub const Entry = struct {
    /// The first line.
    title: []const u8,
    /// The action, as the configuration writes it (`new_split:right`),
    /// GTK's `action-key`, searched, and shown on the second line when
    /// there is no description; empty for a jump.
    action_key: []const u8 = "",
    /// The command's description; a jump's terminal's working directory,
    /// unless its title shows it already, as GTK and macOS describe a
    /// jump, escaped (`escaped`). Shown on the second line, as macOS
    /// shows it, and as a command's tooltip (`tooltip`).
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

    /// The second line: the description, as macOS's row shows it, else the
    /// action key (`subtitleIsKey`).
    pub fn subtitle(self: *const Entry) []const u8 {
        return if (self.subtitleIsKey()) self.action_key else self.description;
    }

    /// Whether the second line is the action key, there being no
    /// description.
    fn subtitleIsKey(self: *const Entry) bool {
        return self.description.len == 0;
    }

    /// The letters `folded`, a folded query (`fold`), matched in the row's
    /// lines (`matchSpan`), each a span of its line: in the title; else in
    /// the second line when it is the action key, which the filter also
    /// matches, as macOS bolds the subtitle's only when the title has
    /// none. A description, which the filter does not search, has none.
    pub fn spans(self: *const Entry, folded: []const u8) Spans {
        if (matchSpan(self.title, self.folded_title, folded)) |t| return .{ .title = t };
        if (!self.subtitleIsKey()) return .{};
        return .{ .subtitle = matchSpan(self.action_key, self.folded_key, folded) };
    }

    /// The row's tooltip: a command's description, as GTK's row binds it
    /// to its tooltip and macOS's to its help, which shows all of a
    /// description the second line cuts short; null when there is none,
    /// or for a jump, whose working directory is all of its second line.
    pub fn tooltip(self: *const Entry) ?[]const u8 {
        if (self.description.len == 0 or self.action_key.len == 0) return null;
        return self.description;
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
///
/// In the user's language: a title and a description are translated
/// here, as they are listed, rather than as the configuration loads,
/// which is before its `language` is known. An entry of the user's own
/// is looked up as the defaults are, and shows as written unless its
/// text is a default's.
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
        const cloned = try command.translated().clone(a);
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
        const shown = jump.title orelse std.mem.span(i18n._("Untitled"));
        const pwd = jump.pwd orelse "";
        list.appendAssumeCapacity(try withFolded(a, .{
            // As GTK words it.
            .title = try a.print("{s}: {s}", .{ i18n._("Focus"), shown }),
            .description = if (pwd.len > 0 and std.mem.indexOf(u8, shown, pwd) == null) try escaped(a, pwd) else "",
            .run = .{ .jump = jump.surface },
            .sort_key = i,
        }));
    }
    // Stable, as GTK's sort is.
    std.mem.sort(Entry, list.items, {}, lessThan);
    return .{ .arena = arena, .items = list.items };
}

/// `text` with each code point that can reorder or hide text or add a
/// line (`App.unsafeCodepoint`) written as "U+XXXX", as the context menu
/// writes a shortcut's: for a jump's working directory, which its shell
/// reports. Text that is not UTF-8 is kept as it is; the row leaves out a
/// line it cannot convert (`drawRow`).
fn escaped(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const view = std.unicode.Utf8View.init(text) catch return a.dupe(u8, text);
    var w: std.Io.Writer.Allocating = .init(a);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (unsafeCodepoint(cp)) {
            w.writer.print("U+{X:0>4}", .{cp}) catch return error.OutOfMemory;
        } else {
            w.writer.print("{u}", .{cp}) catch return error.OutOfMemory;
        }
    }
    return w.written();
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
    var buf: [max_fold]u8 = undefined;
    while (i < text.len) {
        const one = foldStep(text[i..], &buf);
        try out.appendSlice(alloc, one.folded);
        i += one.source;
    }
    return out.toOwnedSlice(alloc);
}

/// The most bytes one code point folds to: Unicode's full case folding
/// gives at most three code points, each at most four bytes.
const max_fold = 3 * 4;

/// One step of `fold` at the start of `rest`, not empty: the bytes it
/// reads, one code point or a byte that is not UTF-8, and what they fold
/// to, in `buf`. `matchSpan` walks a text by the same steps.
fn foldStep(rest: []const u8, buf: *[max_fold]u8) struct { source: usize, folded: []const u8 } {
    const len: usize = std.unicode.utf8ByteSequenceLength(rest[0]) catch 0;
    const cp: ?u21 = if (len > 0 and len <= rest.len)
        std.unicode.utf8Decode(rest[0..len]) catch null
    else
        null;
    const c = cp orelse {
        buf[0] = rest[0];
        return .{ .source = 1, .folded = buf[0..1] };
    };
    if (c < 0x80) {
        buf[0] = std.ascii.toLower(@intCast(c));
        return .{ .source = len, .folded = buf[0..1] };
    }
    var single: [1]u21 = undefined;
    var n: usize = 0;
    for (uucode.get(.case_folding_full, c).with(&single, c)) |f| {
        n += std.unicode.utf8Encode(f, buf[n..]) catch continue;
    }
    return .{ .source = len, .folded = buf[0..n] };
}

/// A range of a text's bytes.
pub const Span = struct { start: usize, end: usize };

/// The letters a query matched in a row's two lines (`Entry.spans`).
pub const Spans = struct { title: ?Span = null, subtitle: ?Span = null };

/// The bytes of `text` whose folded form, `folded_text` (`fold`), holds
/// the first occurrence of `folded`, a folded query, as the filter found
/// it (`match`): every code point whose folding overlaps it, so that a
/// match beginning or ending inside one code point's folding ("ß" for
/// "s") takes all of it, widened to whole grapheme clusters
/// (`clusters`), so that a mark or a modifier is never drawn apart from
/// its base. Null for an empty query, or none. As macOS bolds the letters
/// a query matched.
pub fn matchSpan(text: []const u8, folded_text: []const u8, folded: []const u8) ?Span {
    if (folded.len == 0) return null;
    const at = std.mem.indexOf(u8, folded_text, folded) orelse return null;
    const end = at + folded.len;
    var span: ?Span = null;
    var src: usize = 0;
    var out: usize = 0;
    var buf: [max_fold]u8 = undefined;
    while (src < text.len and out < end) {
        const one = foldStep(text[src..], &buf);
        const next = out + one.folded.len;
        if (next > at) {
            if (span == null) span = .{ .start = src, .end = src };
            span.?.end = src + one.source;
        }
        src += one.source;
        out = next;
    }
    return clusters(text, span orelse return null);
}

/// `span`, which starts and ends on a code point of `text`, widened to
/// the grapheme clusters it touches, by the terminal's segmentation
/// (`unicode.graphemeBreak`), stepping through `text` as `foldStep`
/// does. A control character, or a byte that is not UTF-8, is a cluster
/// of its own, as the segmentation is not for them.
fn clusters(text: []const u8, span: Span) Span {
    var out = span;
    var state: uucode.grapheme.BreakState = .default;
    var prev: ?u21 = null;
    var cluster: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const cp: ?u21 = if (len > 0 and len <= text.len - i)
            std.unicode.utf8Decode(text[i..][0..len]) catch null
        else
            null;
        const usable = if (cp) |c| c >= 0x20 and c != 0x7f else false;
        const breaks = if (prev) |a| if (usable)
            unicode.graphemeBreak(unicode.table.get(a).grapheme_break, unicode.table.get(cp.?).grapheme_break, &state)
        else
            true else true;
        if (breaks) {
            if (i >= span.end) {
                out.end = i;
                return out;
            }
            cluster = i;
            state = .default;
        }
        if (i == span.start) out.start = cluster;
        prev = if (usable) cp else null;
        i += if (cp == null) 1 else len;
    }
    out.end = text.len;
    return out;
}

/// Whether `text` holds a right-to-left letter: Hebrew, Arabic and the
/// scripts near them, and their presentation forms. Such a line is drawn
/// whole, in one run, which lays it out from right to left: cut at a
/// match into runs drawn left to right, its pieces would come out in the
/// wrong order.
pub fn holdsRtl(text: []const u8) bool {
    const view = std.unicode.Utf8View.init(text) catch return holdsRtlLossy(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |c| if (isRtl(c)) return true;
    return false;
}

/// `holdsRtl` for a text that is not all UTF-8: its code points that are.
fn holdsRtlLossy(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (len > 0 and len <= text.len - i) {
            if (std.unicode.utf8Decode(text[i..][0..len])) |c| {
                if (isRtl(c)) return true;
                i += len;
                continue;
            } else |_| {}
        }
        i += 1;
    }
    return false;
}

fn isRtl(c: u21) bool {
    return (c >= 0x0590 and c <= 0x08ff) or
        (c >= 0xfb1d and c <= 0xfdff) or
        (c >= 0xfe70 and c <= 0xfeff) or
        (c >= 0x10800 and c <= 0x10fff) or
        (c >= 0x1e800 and c <= 0x1efff);
}

/// `entry` with its title and action key folded (`fold`) for the filter.
fn withFolded(a: Allocator, entry: Entry) Allocator.Error!Entry {
    var e = entry;
    e.folded_title = try fold(a, entry.title);
    e.folded_key = try fold(a, entry.action_key);
    return e;
}

/// The indices into `entries` of those that match `folded`, a query
/// the caller folded (`fold`), as the rows show its matches with the same
/// folding (`Entry.spans`), into `out` (cleared first): those whose title
/// matches, then those whose action key alone does, as macOS ranks a
/// title match over the rest; each kind in the entries' order.
pub fn filter(
    alloc: Allocator,
    entries: []const Entry,
    folded: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(alloc, entries.len);
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
// A pop-up window the frame owns, over the top centre of the area under
// the tab bar, as macOS floats its palette over the terminals with rounded
// corners, a border and a shadow: Windows 11 gives a top-level window
// those (DWMWA_WINDOW_CORNER_PREFERENCE, DWMWA_BORDER_COLOR), never a
// child. Being its own window, it takes the activation while it is open;
// the frame's caption is kept active meanwhile (`Palette.activating`), as
// a menu keeps its window's, and it follows the frame as it moves
// (`frameMoved`). It looks as macOS's does, in colours from its
// terminal's background (`Look`): an EDIT across the top takes the query
// in a large light font (`Fonts`), over a divider, and a LISTBOX,
// owner-drawn, shows the entries, two lines each (the title, then the
// description or the action key) with the shortcut on the right, the
// selected row on a rounded tint; the palette is as tall as its rows, up
// to five, or says "No matches". The LISTBOX keeps each title as its
// item's text, for accessibility, and the entry's index as its data.
// The keyboard stays in the field: Up, Down, PgUp and PgDn move the
// selection, Enter runs it, Escape closes; a click on a row runs it.
//
// One per window (`Window.palette`), for the terminal with the focus in
// its shown tab (`focusMoved`), which gets the focus back when it closes.
// It closes on Escape, when it runs an entry, when it or its frame is
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
const TabOverview = @import("TabOverview.zig");
const ScrollBar = @import("ScrollBar.zig");
const overlay_keys = @import("overlay_keys.zig");
const TabBar = @import("TabBar.zig");
const Overlays = @import("Overlays.zig");
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const utf8FromWide = @import("clipboard.zig").utf8FromWide;

const RECT = win32.RECT;
const L = win32.L;
const lerp = win32.lerp;
const Question = @import("dialog.zig").Question;
/// The field's placeholder in the user's language, for the program's
/// time: nothing documents that the field copies it.
pub var placeholder: Question = .{};

const log = std.log.scoped(.win32);

pub const class_name = "GhosttyCommandPaletteClass";

/// Posted to the palette's window when it or its frame is deactivated
/// (`deactivated`).
pub const WM_PALETTE_CLOSE: win32.UINT = win32.WM_USER + 1;
/// Posted to the palette's window when its frame takes the keyboard focus
/// while it is open (`activateLater`).
pub const WM_PALETTE_ACTIVATE: win32.UINT = win32.WM_USER + 2;

/// A window's palette (`Window.palette`): its windows while it is open,
/// none while it is closed.
pub const Palette = struct {
    /// The palette's window, a pop-up the frame owns; null while closed.
    hwnd: ?win32.HWND = null,
    /// The query, an EDIT child of `hwnd`.
    edit: ?win32.HWND = null,
    /// The entries, an owner-drawn LISTBOX child of `hwnd`.
    list: ?win32.HWND = null,
    /// From `open` until `close` starts, or it is deactivated: the
    /// keyboard focus the window gives goes to the field (`focusTarget`).
    open: bool = false,
    /// While the palette is being activated (`activate`): the frame's
    /// caption stays active (`Window`'s WM_NCACTIVATE), as the palette is
    /// part of it.
    activating: bool = false,
    /// The terminal entries run on, live while open: the one it was
    /// opened for, then the one with the focus in the shown tab
    /// (`focusMoved`).
    surface: ?*Surface = null,
    /// What it lists; the list's items hold indices into it.
    entries: ?Entries = null,
    /// The filter's result, reused for each query.
    shown: std.ArrayList(u32) = .empty,
    /// The query, folded (`fold`), whose matches the rows show
    /// (`matchSpan`); owned.
    query: []const u8 = &.{},
    /// The row the left button went down on; it runs if the button comes
    /// up on it too.
    pressed: ?usize = null,
    /// While a wheel message is being forwarded to the list (`wndProc`).
    wheeling: bool = false,
    /// The tooltip showing the description of the row under the pointer
    /// (`hover`), owned by the palette's window, which destroys it; null
    /// where the system could not make one.
    tip: ?win32.HWND = null,
    /// The list's row under the pointer, whose description the tooltip
    /// holds; null while the pointer is off the rows.
    hover_row: ?usize = null,
    /// Whether the list has asked for the WM_MOUSELEAVE that ends
    /// `hover_row`.
    tracking_leave: bool = false,
    /// Whether the list has the dark theme class, null before it has had
    /// either (`applyListTheme`).
    list_dark: ?bool = null,
    /// The palette's fonts at `font_dpi`, and the height of a line of
    /// each (`applyFont`).
    fonts: Fonts = .{},
    font_dpi: u32 = 0,
    heights: Heights = .{},
    /// The brush the field and the list are painted with, of
    /// `brush_color`.
    brush: ?win32.HGDIOBJ = null,
    brush_color: win32.COLORREF = 0,

    /// Where the keyboard focus the window gives goes: the field while
    /// the palette is open; else null. Hidden with its hidden frame, it
    /// still holds the frame's focus, which it gets when that shows.
    pub fn focusTarget(self: *const Palette) ?win32.HWND {
        if (!self.open) return null;
        if (self.hwnd == null) return null;
        return self.edit;
    }

    /// Whether the keyboard focus is in the palette now.
    fn holdsFocus(self: *const Palette) bool {
        const hwnd = self.hwnd orelse return false;
        const focus = Window.keyboardFocus() orelse return false;
        return focus == hwnd or win32.IsChild(hwnd, focus).toBool();
    }

    /// Make the palette's fonts at `dpi`, once for each DPI, give the
    /// field its own and the list the titles', measure a line of each,
    /// and size the rows for them.
    fn applyFont(self: *Palette, dpi: u32) void {
        if (self.fonts.field != null and self.font_dpi == dpi) return;
        const edit = self.edit orelse return;
        const fonts = Fonts.init(dpi);
        const field = fonts.field orelse {
            var f = fonts;
            f.deinit();
            return;
        };
        _ = win32.SendMessageW(edit, win32.WM_SETFONT, @intFromPtr(field), 1);
        if (self.list) |list| if (fonts.title) |t| {
            _ = win32.SendMessageW(list, win32.WM_SETFONT, @intFromPtr(t), 0);
        };
        self.fonts.deinit();
        self.fonts = fonts;
        self.font_dpi = dpi;
        self.heights = .{
            .field = SearchBar.textHeight(edit, field),
            .title = if (fonts.title) |t| SearchBar.textHeight(edit, t) else 0,
            .small = if (fonts.small) |t| SearchBar.textHeight(edit, t) else 0,
        };
        self.sizeRows();
    }

    /// The list's rows as tall as `rowHeight` at `font_dpi`, the DPI
    /// every part of the palette is measured at (`dpiOf`).
    fn sizeRows(self: *const Palette) void {
        const list = self.list orelse return;
        const row: win32.LPARAM = Metrics.init(self.font_dpi).rowHeight(self.heights);
        _ = win32.SendMessageW(list, win32.LB_SETITEMHEIGHT, 0, row);
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
        alloc.free(self.query);
        self.fonts.deinit();
        if (self.brush) |b| _ = win32.DeleteObject(b);
        self.* = .{};
    }
};

/// The palette's fonts at a DPI, from the system's message font, so that
/// a larger text size in Settings, which grows that font, grows them all:
/// the field's larger and light, as macOS's query is 20 points light; the
/// titles' and the small one's (the second lines, the shortcuts) at
/// Windows 11's body and caption sizes, 14 and 12 pixels to the message
/// font's 12 at 96 DPI, and each of those bold, for the letters a query
/// matched. Any one the system will not make is null.
pub const Fonts = struct {
    field: ?win32.HGDIOBJ = null,
    title: ?win32.HGDIOBJ = null,
    small: ?win32.HGDIOBJ = null,
    title_bold: ?win32.HGDIOBJ = null,
    small_bold: ?win32.HGDIOBJ = null,

    pub fn init(dpi: u32) Fonts {
        const base = TabBar.messageLogFont(dpi) orelse TabBar.fallbackLogFont(dpi);
        return .{
            .field = make(base, 20, win32.FW_LIGHT),
            .title = make(base, 14, base.lfWeight),
            .small = make(base, 12, base.lfWeight),
            .title_bold = make(base, 14, win32.FW_BOLD),
            .small_bold = make(base, 12, win32.FW_BOLD),
        };
    }

    /// `base` at `px` of its 12, of `weight`.
    fn make(base: win32.LOGFONTW, px: i32, weight: win32.LONG) ?win32.HGDIOBJ {
        var lf = base;
        lf.lfHeight = scaleHeight(base.lfHeight, px);
        lf.lfWidth = 0;
        lf.lfWeight = weight;
        const font = win32.CreateFontIndirectW(&lf);
        if (font == null) log.warn("cannot make a command palette font err={}", .{win32.GetLastError()});
        return font;
    }

    pub fn deinit(self: *Fonts) void {
        inline for (.{ self.field, self.title, self.small, self.title_bold, self.small_bold }) |f| if (f) |font| {
            _ = win32.DeleteObject(font);
        };
        self.* = .{};
    }
};

/// A LOGFONTW height, `height`, scaled by `px` / 12, rounded half away
/// from zero; its sign kept, as a negative height is the characters'
/// and a positive one the cells'. Never zero, which would ask for the
/// system's default size.
pub fn scaleHeight(height: i32, px: i32) i32 {
    const scaled = TabBar.scaleDpi(height, @intCast(px), 12);
    return if (scaled != 0) scaled else if (height < 0) -1 else 1;
}

/// The height of a line of each of `Fonts`.
pub const Heights = struct {
    field: i32 = 0,
    title: i32 = 0,
    small: i32 = 0,
};

/// The palette's colours, from its terminal's background, as macOS tints
/// its palette with the terminal's background and picks its light or
/// dark look by that background's luminance. A Win32 window has no
/// material behind GDI's drawing, so the tint is a solid colour: the
/// background lifted towards white on a dark one, towards black on a
/// light one. The selection is tinted with the system's highlight, as
/// macOS's is with the accent, and the letters a query matched are drawn
/// in it, lightened on a dark background to stand out from the tint.
pub const Look = struct {
    dark: bool,
    back: win32.COLORREF,
    border: win32.COLORREF,
    text: win32.COLORREF,
    dim: win32.COLORREF,
    selected: win32.COLORREF,
    hover: win32.COLORREF,
    match: win32.COLORREF,

    pub fn of(background: win32.COLORREF, accent: win32.COLORREF) Look {
        const white = win32.rgb(0xff, 0xff, 0xff);
        const black = win32.rgb(0, 0, 0);
        const dark = !isLight(background);
        // Lifted towards white, or darkened, unless that crosses the line
        // between light and dark, as it does for a background near it:
        // then the other way, so the back stays on the side the text was
        // chosen for, as macOS's tint keeps its material's luminance.
        const lifted = if (dark) lerp(background, white, 80) else lerp(background, black, 30);
        const back = if (isLight(lifted) != dark)
            lifted
        else if (dark)
            lerp(background, black, 30)
        else
            lerp(background, white, 80);
        const text = if (dark) win32.rgb(0xf2, 0xf2, 0xf2) else win32.rgb(0x1a, 0x1a, 0x1a);
        return .{
            .dark = dark,
            .back = back,
            .border = if (dark) lerp(background, white, 240) else lerp(background, black, 180),
            .text = text,
            .dim = lerp(text, back, 400),
            .selected = lerp(back, accent, if (dark) 300 else 220),
            .hover = lerp(back, text, 100),
            .match = if (dark) lerp(accent, white, 450) else lerp(accent, black, 150),
        };
    }
};

/// Whether `c` is light, by the measure macOS and GTK take of a terminal
/// background's luminance (`RGB.perceivedLuminance`).
pub fn isLight(c: win32.COLORREF) bool {
    const bg: terminal.color.RGB = .{
        .r = @truncate(c),
        .g = @truncate(c >> 8),
        .b = @truncate(c >> 16),
    };
    return bg.perceivedLuminance() > 0.5;
}

/// The DPI `window`'s palette is measured and drawn at: its frame's, at
/// which its fonts were made (`Palette.applyFont`). Not the palette's own
/// window's: a pop-up has its own DPI, of the monitor it is on, which for
/// one just made at the screen's origin is the primary monitor's, and the
/// palette is drawn for its frame's.
fn dpiOf(window: *const Window) u32 {
    const p = &window.palette;
    return if (p.font_dpi != 0) p.font_dpi else Window.dpiOf(window.app, window.hwnd);
}

/// `window`'s palette's look, for its terminal's background.
fn lookOf(window: *const Window) Look {
    const p = &window.palette;
    const background = if (p.surface) |s| Overlays.terminalBackground(s) else if (window.dark_frame) win32.rgb(0x1c, 0x1c, 0x1c) else win32.rgb(0xff, 0xff, 0xff);
    return .of(background, win32.GetSysColor(win32.COLOR_HIGHLIGHT));
}

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
    // The two are never open together.
    TabOverview.close(window);
    const entries = forApp(app, null) catch |err| {
        log.warn("cannot list the command palette's entries err={}", .{err});
        return false;
    };
    const hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        null,
        win32.WS_POPUP | win32.WS_CLIPCHILDREN,
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
    applyFrame(window);
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
    // GTK's and macOS's placeholder, shown while the field has the focus,
    // as it always has.
    _ = win32.SendMessageW(edit, win32.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(placeholder.one("Execute a command\u{2026}"))));
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
    if (p.fonts.title) |f| _ = win32.SendMessageW(list, win32.WM_SETFONT, @intFromPtr(f), 0);
    p.sizeRows();
    applyListTheme(window);
    p.tip = makeTip(hwnd, list, app.hinstance);
    _ = refill(window, "");
    p.open = true;
    if (!place(window)) return false;
    activate(window);
    return true;
}

/// The palette's frame in Windows 11's look: rounded corners, which bring
/// DWM's shadow, as macOS's palette has, and its border (`applyBorder`).
/// A Windows that refuses either keeps a square frame.
fn applyFrame(window: *Window) void {
    const hwnd = window.palette.hwnd orelse return;
    const round: win32.DWORD = win32.DWMWCP_ROUND;
    const hr = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_WINDOW_CORNER_PREFERENCE, &round, @sizeOf(win32.DWORD));
    if (hr < 0) log.info("cannot round the command palette's corners hr=0x{x}", .{@as(u32, @bitCast(hr))});
    applyBorder(window);
}

/// The frame's border in the palette's look (`Look.border`).
fn applyBorder(window: *Window) void {
    const hwnd = window.palette.hwnd orelse return;
    const border: win32.COLORREF = lookOf(window).border;
    // Not logged: a Windows that has no border colour refuses it each
    // time, and this runs as the palette moves and refits.
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_BORDER_COLOR, &border, @sizeOf(win32.COLORREF));
}

/// Give the open palette's field the keyboard focus, which activates the
/// palette, while the frame or the palette is the active window: the
/// frame's caption stays active through it (`Palette.activating`).
fn activate(window: *Window) void {
    const p = &window.palette;
    const edit = p.edit orelse return;
    p.activating = true;
    defer p.activating = false;
    window.setKeyboardFocus(edit, true);
}

/// The frame took the keyboard focus (its WM_SETFOCUS) while its palette
/// is open, as when it is activated with a palette opened while it was
/// not: the palette is activated once the frame's activation is over, by
/// a message to itself, rather than inside it.
pub fn activateLater(window: *Window) void {
    const hwnd = window.palette.hwnd orelse return;
    _ = win32.PostMessageW(hwnd, WM_PALETTE_ACTIVATE, 0, 0);
}

/// Whether `makeTip` has said once that there is no tooltip.
var tip_missing_logged = false;

/// The tooltip for `list`'s descriptions, one tool covering the list, its
/// text set row by row (`hover`). Made by class name: the app's manifest
/// asks for Common Controls v6, which registers the class. A process with
/// no such manifest, the test runner, may get none; the palette works
/// without it, and says so once.
fn makeTip(owner: win32.HWND, list: win32.HWND, hinstance: ?win32.HINSTANCE) ?win32.HWND {
    const tip = win32.CreateWindowExW(
        win32.WS_EX_TOPMOST,
        L(win32.TOOLTIPS_CLASS),
        null,
        win32.WS_POPUP | win32.TTS_NOPREFIX | win32.TTS_ALWAYSTIP,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        owner,
        null,
        hinstance,
        null,
    ) orelse {
        tipMissing("cannot make one", win32.GetLastError());
        return null;
    };
    var info = toolInfo(list);
    info.lpszText = L("");
    if (win32.SendMessageW(tip, win32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&info))) == 0) {
        tipMissing("cannot add the list to it", win32.GetLastError());
        _ = win32.DestroyWindow(tip);
        return null;
    }
    return tip;
}

fn tipMissing(why: []const u8, err: anytype) void {
    if (tip_missing_logged) return;
    tip_missing_logged = true;
    log.info("no tooltips for the command palette's descriptions, {s} err={}", .{ why, err });
}

/// The palette's one tool: all of the list.
fn toolInfo(list: win32.HWND) win32.TOOLINFOW {
    return .{ .uFlags = win32.TTF_IDISHWND, .hwnd = list, .uId = @intFromPtr(list) };
}

/// The pointer is over the list's `row`, or off its rows (null): the
/// tooltip takes what that row's tip is (`tipFor`), or nothing, which it
/// does not show, once the pointer moves to another row.
fn hover(window: *Window, row: ?usize) void {
    const p = &window.palette;
    if (row == p.hover_row) return;
    redrawRow(window, p.hover_row);
    redrawRow(window, row);
    p.hover_row = row;
    setTip(window, if (row) |r| tipFor(window, r) else "");
}

/// The tooltip for the list's `row`: its description (`Entry.tooltip`)
/// when the row's second line cuts it short, as a tooltip that repeated
/// the line just above it would only cover the next row; else nothing.
pub fn tipFor(window: *Window, row: usize) []const u8 {
    const entry = rowEntry(window, row) orelse return "";
    const text = entry.tooltip() orelse return "";
    return if (cutShort(window, row, entry)) text else "";
}

/// Whether the list's `row` draws `entry`'s second line cut short
/// (`drawRow`).
fn cutShort(window: *Window, row: usize, entry: *const Entry) bool {
    const p = &window.palette;
    const list = p.list orelse return false;
    const font = p.fonts.small orelse return false;
    var item: RECT = undefined;
    if (win32.SendMessageW(list, win32.LB_GETITEMRECT, row, @bitCast(@intFromPtr(&item))) < 0) return false;
    const hdc = win32.GetDC(list) orelse return false;
    defer _ = win32.ReleaseDC(list, hdc);
    const old = win32.SelectObject(hdc, font);
    defer if (old) |o| {
        _ = win32.SelectObject(hdc, o);
    };
    const alloc = window.app.core_app.alloc;
    const shortcut_w = textWidth(hdc, alloc, entry.shortcut);
    const m = Metrics.init(dpiOf(window));
    const r = Row.init(m, item, p.heights, shortcut_w);
    return textWidth(hdc, alloc, entry.subtitle()) > r.subtitle.right - r.subtitle.left;
}

/// The width of `text` in `hdc`'s font, on one line; 0 for none, or
/// what cannot be measured.
fn textWidth(hdc: win32.HDC, alloc: Allocator, text: []const u8) i32 {
    if (text.len == 0) return 0;
    const wide = wideFromUtf8(alloc, text) catch return 0;
    defer alloc.free(wide);
    return wideWidth(hdc, wide);
}

/// `textWidth` of text already in UTF-16, as it is drawn.
fn wideWidth(hdc: win32.HDC, wide: []const u16) i32 {
    if (wide.len == 0) return 0;
    var r: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = win32.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &r, win32.DT_SINGLELINE | win32.DT_NOPREFIX | win32.DT_CALCRECT);
    return r.right - r.left;
}

/// Forget the row under the pointer and hide the tooltip: the rows under
/// it changed (`refill`, a scroll), or it left the list.
fn unhover(window: *Window) void {
    redrawRow(window, window.palette.hover_row);
    window.palette.hover_row = null;
    setTip(window, "");
}

/// Draw the list's `row` again, as the pointer came onto it or left it.
fn redrawRow(window: *Window, row: ?usize) void {
    const r = row orelse return;
    const list = window.palette.list orelse return;
    var rect: RECT = undefined;
    if (win32.SendMessageW(list, win32.LB_GETITEMRECT, r, @bitCast(@intFromPtr(&rect))) < 0) return;
    _ = win32.InvalidateRect(list, &rect, .FALSE);
}

/// The tooltip, hidden, with `text`, shown again after the pointer rests.
fn setTip(window: *Window, text: []const u8) void {
    const p = &window.palette;
    const tip = p.tip orelse return;
    const list = p.list orelse return;
    _ = win32.SendMessageW(tip, win32.TTM_POP, 0, 0);
    const wide = wideFromUtf8(window.app.core_app.alloc, text) catch return;
    defer window.app.core_app.alloc.free(wide);
    // A long description wraps at the list's width.
    var client: RECT = undefined;
    if (win32.GetClientRect(list, &client).toBool() and client.right > 0) {
        _ = win32.SendMessageW(tip, win32.TTM_SETMAXTIPWIDTH, 0, client.right);
    }
    var info = toolInfo(list);
    info.lpszText = wide.ptr;
    _ = win32.SendMessageW(tip, win32.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&info)));
}

/// The entry on the list's `row`, if there is one.
fn rowEntry(window: *Window, row: usize) ?*const Entry {
    const p = &window.palette;
    const list = p.list orelse return null;
    const entries = p.entries orelse return null;
    const data = win32.SendMessageW(list, win32.LB_GETITEMDATA, row, 0);
    if (data < 0 or @as(usize, @intCast(data)) >= entries.items.len) return null;
    return &entries.items[@intCast(data)];
}

/// Pass a mouse message of the list's to the tooltip, which shows itself
/// when the pointer rests and hides on a click.
fn relay(window: *Window, list: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const tip = window.palette.tip orelse return;
    var pt: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    _ = win32.ClientToScreen(list, &pt);
    var m: win32.MSG = .{
        .hwnd = list,
        .message = msg,
        .wParam = wparam,
        .lParam = lparam,
        .time = 0,
        .pt = pt,
    };
    _ = win32.SendMessageW(tip, win32.TTM_RELAYEVENT, 0, @bitCast(@intFromPtr(&m)));
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
pub fn closedByKey(app: *App, lparam: win32.LPARAM) void {
    const focus = Window.keyboardFocus() orelse return;
    for (app.surfaces.items) |surface| {
        if (surface.hwnd != focus) continue;
        surface.withholdKeyUp(lparam);
        return;
    }
}

/// `window` was deactivated (its WM_ACTIVATE), for `to`: its palette
/// closes, as GTK's dialog does, unless `to` is the palette itself, once
/// the deactivation is over, by a message to itself:
/// inside WM_ACTIVATE the focus is still in the field, and destroying it
/// there would hand the focus to the frame, and from there to a terminal,
/// in a window that is losing it, perhaps to a confirmation prompt whose
/// core frame is on the stack.
pub fn deactivated(window: *Window, to: ?win32.HWND) void {
    const hwnd = window.palette.hwnd orelse return;
    if (to == hwnd) return;
    _ = win32.PostMessageW(hwnd, WM_PALETTE_CLOSE, 0, 0);
}

/// `window` moved (its WM_MOVE): its open palette moves with it.
pub fn frameMoved(window: *Window) void {
    if (window.palette.hwnd == null or !window.palette.open) return;
    _ = place(window);
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
    // The rows hold indices into the old entries until they are filled
    // again: a palette that could not be refilled closes, rather than
    // run, or read past the end of, the wrong entry.
    if (!textChanged(window)) {
        log.warn("cannot list the command palette's entries again", .{});
        return close(window);
    }
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

/// Draw the palette again, as the theme or the configuration changed.
pub fn invalidate(window: *Window) void {
    const p = &window.palette;
    applyListTheme(window);
    applyBorder(window);
    if (p.hwnd) |h| _ = win32.InvalidateRect(h, null, .TRUE);
    if (p.edit) |h| _ = win32.InvalidateRect(h, null, .TRUE);
    if (p.list) |h| _ = win32.InvalidateRect(h, null, .TRUE);
}

/// The list's scrollbar in the palette's mode (`Look.dark`). The list is
/// a system LISTBOX: WM_CTLCOLORLISTBOX colours its rows' background, but
/// Windows draws its scrollbar with the window's visual style, light by
/// default, a white track beside the dark rows. So in a dark palette the
/// list takes the "DarkMode_Explorer" theme class, which gives it the
/// dark scrollbar, as Explorer, Notepad++ and Windows Terminal give their
/// controls; and "Explorer" back in a light one. The class name is not documented: a
/// Windows without it keeps the light scrollbar. Only when the mode
/// changes, as each call sends the list WM_THEMECHANGED.
fn applyListTheme(window: *Window) void {
    const p = &window.palette;
    const list = p.list orelse return;
    const want = lookOf(window).dark;
    if (p.list_dark) |dark| if (dark == want) return;
    p.list_dark = want;
    const class = if (want) L("DarkMode_Explorer") else L("Explorer");
    const hr = win32.SetWindowTheme(list, class, null);
    if (hr < 0) log.info("cannot set the command palette list's theme hr=0x{x}", .{@as(u32, @bitCast(hr))});
}

/// The system's message font changed: made again and placed.
pub fn fontChanged(window: *Window) void {
    if (window.palette.hwnd == null) return;
    window.palette.font_dpi = 0;
    _ = place(window);
}

/// Place `window`'s open palette near the top centre of the area under
/// the tab bar (`area`), over the terminals and their search bars, as
/// tall as its rows (`paletteRect`); whether it is open there. It shows
/// while its frame does: a hidden owner does not hide what it owns. One
/// that no longer fits there closes. Called by every layout
/// (`Window.relayout`), which never runs inside a core frame, and as the
/// frame moves (`frameMoved`).
pub fn place(window: *Window) bool {
    return position(window, .close);
}

/// The query changed what the list shows: the palette grows or shrinks
/// to its rows, where it is. Whether a palette fits does not depend on
/// its rows (`paletteRect`), so this never closes it: only a layout
/// changes that.
fn refit(window: *Window) void {
    _ = position(window, .keep);
}

fn position(window: *Window, no_room: enum { close, keep }) bool {
    const p = &window.palette;
    const hwnd = p.hwnd orelse return false;
    if (!p.open) return false;
    const dpi = Window.dpiOf(window.app, window.hwnd);
    p.applyFont(dpi);
    const m = Metrics.init(dpi);
    const area = paletteArea(window) orelse return false;
    const count = p.shown.items.len;
    const at = paletteRect(m, area, p.heights, count) orelse {
        if (no_room == .keep) return false;
        log.info("no room for the command palette", .{});
        close(window);
        return false;
    };
    const width = at.right - at.left;
    const height = at.bottom - at.top;
    // In the screen's coordinates, a pop-up's.
    var origin: win32.POINT = .{ .x = at.left, .y = at.top };
    _ = win32.ClientToScreen(window.hwnd, &origin);
    const show: win32.UINT = if (win32.IsWindowVisible(window.hwnd).toBool() and !win32.IsIconic(window.hwnd).toBool())
        win32.SWP_SHOWWINDOW
    else
        win32.SWP_HIDEWINDOW;
    _ = win32.SetWindowPos(hwnd, null, origin.x, origin.y, width, height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | show);
    const l = Layout.init(m, width, height, p.heights);
    if (p.edit) |edit| _ = win32.SetWindowPos(edit, null, l.edit.left, l.edit.top, l.edit.right - l.edit.left, l.edit.bottom - l.edit.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    // With no rows, "No matches" in its place (`paint`).
    if (p.list) |list| {
        const list_show: win32.UINT = if (count > 0) win32.SWP_SHOWWINDOW else win32.SWP_HIDEWINDOW;
        _ = win32.SetWindowPos(list, null, l.list.left, l.list.top, l.list.right - l.list.left, l.list.bottom - l.list.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | list_show);
    }
    invalidate(window);
    return true;
}

/// The field's text changed (EN_CHANGE): the list shows what matches it,
/// the first selected, as GTK's list selects its first item. Whether the
/// list was filled again; if not, it is as it was.
fn textChanged(window: *Window) bool {
    const p = &window.palette;
    const edit = p.edit orelse return false;
    const alloc = window.app.core_app.alloc;
    const len: usize = @intCast(@max(win32.GetWindowTextLengthW(edit), 0));
    const wide = alloc.alloc(u16, len + 1) catch |err| {
        log.warn("cannot read the command palette's field err={}", .{err});
        return false;
    };
    defer alloc.free(wide);
    const n: usize = @intCast(@max(win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));
    const query = utf8FromWide(alloc, wide[0..n]) catch |err| {
        log.warn("cannot read the command palette's field err={}", .{err});
        return false;
    };
    defer alloc.free(query);
    if (!refill(window, query)) return false;
    refit(window);
    return true;
}

/// Fill the list with the entries that match `query` (`filter`), the
/// first selected; whether it was, which it is, with no rows, when the
/// filter has no memory.
fn refill(window: *Window, query: []const u8) bool {
    const p = &window.palette;
    const list = p.list orelse return false;
    const entries = p.entries orelse return false;
    const alloc = window.app.core_app.alloc;
    // Folded once, for the filter and for the matches the rows show; with
    // no memory, no rows, and no query to show matches of.
    alloc.free(p.query);
    p.query = &.{};
    if (fold(alloc, query)) |folded| {
        p.query = folded;
        filter(alloc, entries.items, folded, &p.shown) catch |err| {
            log.warn("cannot filter the command palette err={}", .{err});
            p.shown.clearRetainingCapacity();
        };
    } else |err| {
        log.warn("cannot filter the command palette err={}", .{err});
        p.shown.clearRetainingCapacity();
    }
    unhover(window);
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
    return true;
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
    const p = &window.palette;

    switch (msg) {
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            paint(window, hwnd);
            return 0;
        },

        // The field and the list in the palette's colours.
        win32.WM_CTLCOLOREDIT, win32.WM_CTLCOLORLISTBOX => {
            const look = lookOf(window);
            const hdc: win32.HDC = @ptrFromInt(wparam);
            _ = win32.SetTextColor(hdc, look.text);
            _ = win32.SetBkColor(hdc, look.back);
            const brush = p.brushOf(look.back) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return @bitCast(@intFromPtr(brush));
        },

        win32.WM_COMMAND => {
            if (win32.hiword(wparam) == win32.EN_CHANGE and p.edit != null and
                lparam == @as(win32.LPARAM, @bitCast(@intFromPtr(p.edit.?)))) _ = textChanged(window);
            return 0;
        },

        win32.WM_MEASUREITEM => {
            const measure: *win32.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            measure.itemHeight = @intCast(Metrics.init(dpiOf(window)).rowHeight(p.heights));
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

        // Deactivated, for the window lParam names, or none: it closes
        // once the deactivation is over (WM_PALETTE_CLOSE), and the
        // keyboard focus the frame gives goes to its terminal from now
        // (`focusTarget`), as a click on the frame activates it. To
        // another window, the frame's caption, kept active while the
        // palette was (`activating`), is drawn inactive, and a quick
        // terminal may hide, as its frame would on losing the activation.
        //
        // Activated other than by `activate`, by a click on its padding:
        // the frame's caption, drawn inactive as the frame lost the
        // activation, is drawn active again, as `activating` keeps it.
        win32.WM_ACTIVATE => if (@as(u16, @truncate(wparam)) == win32.WA_INACTIVE) {
            const to: ?win32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            p.open = false;
            if (to != window.hwnd) {
                _ = win32.SendMessageW(window.hwnd, win32.WM_NCACTIVATE, 0, 0);
                if (window.quick) window.quickDeactivated(to);
            }
            _ = win32.PostMessageW(hwnd, WM_PALETTE_CLOSE, 0, 0);
        } else if (!p.activating) {
            _ = win32.SendMessageW(window.hwnd, win32.WM_NCACTIVATE, 1, 0);
        },

        // The keyboard focus the palette's own window gets, as it is
        // activated by a click on its padding, goes to the field, as the
        // list's does (`listProc`): typing there would reach nothing.
        win32.WM_SETFOCUS => {
            if (p.focusTarget()) |edit| window.setKeyboardFocus(edit, true);
            return 0;
        },

        // The field's Alt+Space, for the window menu, and an Alt+F4 that
        // no binding took (SC_CLOSE), come here, the field's top-level
        // window: they are the frame's, as with the focus in a terminal.
        // The palette, which has no window menu, closes, and the frame
        // carries them out. A bare Alt or F10 does nothing, as on the
        // frame (`Window.isBareKeyMenu`).
        win32.WM_SYSCOMMAND => {
            if (Window.isBareKeyMenu(wparam, lparam)) return 0;
            switch (wparam & win32.SC_MASK) {
                win32.SC_KEYMENU, win32.SC_CLOSE => {
                    const frame = window.hwnd;
                    // Frees the palette: nothing of it is read after.
                    close(window);
                    return win32.SendMessageW(frame, msg, wparam, lparam);
                },
                else => {},
            }
        },

        WM_PALETTE_CLOSE => {
            // Deactivated itself; or its frame was, unless the frame or
            // the palette was activated meanwhile.
            const active = Window.activeWindow();
            if (!p.open or (active != window.hwnd and active != hwnd)) close(window);
            return 0;
        },

        WM_PALETTE_ACTIVATE => {
            if (p.open) activate(window);
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
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
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
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
    const proc = list_proc.?;
    const window = windowOfChild(hwnd) orelse return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
    const p = &window.palette;
    switch (msg) {
        // The tooltip follows the row under the pointer until it leaves.
        win32.WM_MOUSEMOVE => {
            if (!p.tracking_leave) {
                var tme: win32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = win32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                p.tracking_leave = win32.TrackMouseEvent(&tme).toBool();
            }
            hover(window, rowAt(hwnd, lparam));
            relay(window, hwnd, msg, wparam, lparam);
        },
        win32.WM_MOUSELEAVE => {
            p.tracking_leave = false;
            unhover(window);
        },
        // The rows move under a still pointer.
        win32.WM_MOUSEWHEEL, win32.WM_VSCROLL => unhover(window),
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK => {
            relay(window, hwnd, msg, wparam, lparam);
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

/// The palette behind its field and list: its background, the divider
/// under the field, as macOS draws one, and "No matches" where the list
/// would be when nothing matches, as macOS says it.
fn paint(window: *Window, hwnd: win32.HWND) void {
    const p = &window.palette;
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = win32.EndPaint(hwnd, &ps);
    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) return;
    const look = lookOf(window);
    const m = Metrics.init(dpiOf(window));
    const l = Layout.init(m, client.right, client.bottom, p.heights);
    SearchBar.fill(hdc, client, look.back);
    SearchBar.fill(hdc, l.divider, look.border);
    if (p.shown.items.len > 0) return;
    const font = p.fonts.title orelse return;
    const old_font = win32.SelectObject(hdc, font);
    defer if (old_font) |f| {
        _ = win32.SelectObject(hdc, f);
    };
    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    _ = win32.SetTextColor(hdc, look.dim);
    var none: Question = .{};
    const text = none.one("No matches");
    var r = l.none;
    _ = win32.DrawTextW(hdc, text, -1, &r, win32.DT_SINGLELINE | win32.DT_NOPREFIX | win32.DT_VCENTER | win32.DT_END_ELLIPSIS);
}

/// One of the list's rows, as macOS's: the selected one, or the one under
/// the pointer, on a rounded tint; the title, under it the description or
/// the action key, smaller and dimmer, and the shortcut on the right,
/// centred down the row.
fn drawRow(window: *Window, dis: *const win32.DRAWITEMSTRUCT) void {
    const p = &window.palette;
    const look = lookOf(window);
    const hdc = dis.hDC;
    SearchBar.fill(hdc, dis.rcItem, look.back);
    // An empty list's focus rect has no item.
    if (dis.itemID == std.math.maxInt(win32.UINT)) return;
    const entries = p.entries orelse return;
    if (dis.itemData >= entries.items.len) return;
    const entry = &entries.items[dis.itemData];
    const alloc = window.app.core_app.alloc;
    const m = Metrics.init(dpiOf(window));

    const selected = dis.itemState & win32.ODS_SELECTED != 0;
    const hovered = p.hover_row != null and p.hover_row.? == dis.itemID;
    const old_font = win32.SelectObject(hdc, p.fonts.small orelse return);
    defer if (old_font) |f| {
        _ = win32.SelectObject(hdc, f);
    };
    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    const flags = win32.DT_SINGLELINE | win32.DT_NOPREFIX;

    // The shortcut's width first, as the title gives way to it.
    const shortcut = wideFromUtf8(alloc, entry.shortcut) catch null;
    defer if (shortcut) |s| alloc.free(s);
    const row = Row.init(m, dis.rcItem, p.heights, if (shortcut) |s| wideWidth(hdc, s) else 0);
    if (selected or hovered) roundFill(hdc, row.fill, m.row_corner, if (selected) look.selected else look.hover);
    _ = win32.SetTextColor(hdc, look.dim);
    if (shortcut) |s| if (s.len > 0) {
        var r = row.shortcut;
        _ = win32.DrawTextW(hdc, s.ptr, @intCast(s.len), &r, flags | win32.DT_RIGHT | win32.DT_VCENTER);
    };
    // The letters the query matched (`Entry.spans`).
    const spans = entry.spans(p.query);
    drawSpanned(hdc, alloc, entry.subtitle(), spans.subtitle, row.subtitle, .{ .normal = p.fonts.small, .bold = p.fonts.small_bold }, look.dim, look.match);
    drawSpanned(hdc, alloc, entry.title, spans.title, row.title, .{ .normal = p.fonts.title, .bold = p.fonts.title_bold }, look.text, look.match);
}

/// Draw `text` on one line in `r`, in `fonts.normal` and `color`, but
/// for its `span`, in `fonts.bold` and `match_color`; cut short with an
/// ellipsis where it does not fit. A right-to-left line is drawn whole,
/// with no span (`holdsRtl`): DrawTextW lays out each run on its own, so
/// the pieces of one cut at the span would come out in the wrong order.
fn drawSpanned(
    hdc: win32.HDC,
    alloc: Allocator,
    text: []const u8,
    span: ?Span,
    r: RECT,
    fonts: struct { normal: ?win32.HGDIOBJ, bold: ?win32.HGDIOBJ },
    color: win32.COLORREF,
    match_color: win32.COLORREF,
) void {
    if (text.len == 0) return;
    const flags = win32.DT_SINGLELINE | win32.DT_NOPREFIX;
    const whole: Span = .{ .start = text.len, .end = text.len };
    const s = if (holdsRtl(text)) whole else span orelse whole;
    std.debug.assert(s.start <= s.end and s.end <= text.len);
    const parts = [_]struct { []const u8, bool }{
        .{ text[0..s.start], false },
        .{ text[s.start..s.end], true },
        .{ text[s.end..], false },
    };
    var x = r.left;
    for (parts) |part| {
        const piece, const bold = part;
        if (piece.len == 0) continue;
        if (x >= r.right) return;
        const font = (if (bold) fonts.bold orelse fonts.normal else fonts.normal) orelse return;
        _ = win32.SelectObject(hdc, font);
        _ = win32.SetTextColor(hdc, if (bold) match_color else color);
        const wide = wideFromUtf8(alloc, piece) catch return;
        defer alloc.free(wide);
        var at: RECT = .{ .left = x, .top = r.top, .right = r.right, .bottom = r.bottom };
        _ = win32.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &at, flags | win32.DT_END_ELLIPSIS);
        x += wideWidth(hdc, wide);
    }
}

/// Fill `r` in `color` with corners of `radius`.
fn roundFill(hdc: win32.HDC, r: RECT, radius: i32, color: win32.COLORREF) void {
    const brush = win32.CreateSolidBrush(color) orelse return;
    defer _ = win32.DeleteObject(brush);
    const pen = win32.GetStockObject(win32.NULL_PEN) orelse return;
    const old_brush = win32.SelectObject(hdc, brush);
    const old_pen = win32.SelectObject(hdc, pen);
    defer {
        if (old_pen) |o| _ = win32.SelectObject(hdc, o);
        if (old_brush) |o| _ = win32.SelectObject(hdc, o);
    }
    // The null pen leaves the right and bottom edges out: one more.
    _ = win32.RoundRect(hdc, r.left, r.top, r.right + 1, r.bottom + 1, 2 * radius, 2 * radius);
}

/// The palette's sizes at a DPI, from their values at 96 DPI, macOS's
/// (CommandPalette.swift): 500 wide, a field 48 tall with its text 16 in,
/// a divider, then the list, 10 in from the edges, its rows 4 apart and
/// 8 in, with corners of 5. macOS's list is at most 200 points tall,
/// about four rows: five here.
pub const Metrics = struct {
    /// Between the palette and the sides of the area under the tab bar,
    /// and its top, after a twentieth of the area's height, as macOS's
    /// palette is a twentieth of its view's height down.
    margin: i32,
    /// Its width, and the least it narrows to before it no longer fits.
    width: i32,
    min_width: i32,
    /// The field, at least, and between the palette's sides and its text.
    field_height: i32,
    field_inset: i32,
    /// The divider under the field.
    line: i32,
    /// Between the list and the palette's edges.
    list_pad: i32,
    /// Between rows; inside a row, around its text; between its lines.
    row_gap: i32,
    row_pad: i32,
    title_gap: i32,
    /// The corners of the selected row's tint.
    row_corner: i32,
    /// Above and below "No matches".
    none_pad: i32,
    /// The rows the list shows at most.
    rows: i32,

    pub fn init(dpi: u32) Metrics {
        const s = SearchBar.Metrics.scale;
        return .{
            .margin = s(8, dpi),
            .width = s(500, dpi),
            .min_width = s(240, dpi),
            .field_height = s(48, dpi),
            .field_inset = s(16, dpi),
            .line = @max(1, s(1, dpi)),
            .list_pad = s(10, dpi),
            .row_gap = s(4, dpi),
            .row_pad = s(8, dpi),
            .title_gap = s(2, dpi),
            .row_corner = s(5, dpi),
            .none_pad = s(16, dpi),
            .rows = 5,
        };
    }

    /// The field: `field_height`, or taller for a large font.
    pub fn fieldHeight(self: Metrics, h: Heights) i32 {
        return @max(self.field_height, @max(0, h.field) + 2 * self.row_pad);
    }

    /// A row: the gap, the padding, the title and the second line.
    pub fn rowHeight(self: Metrics, h: Heights) i32 {
        return self.row_gap + 2 * self.row_pad + @max(0, h.title) + self.title_gap + @max(0, h.small);
    }

    /// Above the list: the field and the divider.
    pub fn head(self: Metrics, h: Heights) i32 {
        return self.fieldHeight(h) + self.line;
    }

    /// "No matches", in place of the list.
    pub fn noneHeight(self: Metrics, h: Heights) i32 {
        return 2 * self.none_pad + @max(0, h.title);
    }
};

/// The area the palette goes in: the frame's client area under the tab
/// bar (`Window.layoutArea`), less the scroll bar each terminal along its
/// right edge has (`ScrollBar.width`), so that the palette never covers
/// those. Over the terminals left of others it covers their bars as it
/// covers them.
pub fn paletteArea(window: *const Window) ?RECT {
    var area = window.layoutArea() orelse return null;
    // The window's terminals all have the bar or none has, as `run`
    // gives it or takes it from all of them (`ScrollBar.restyle`).
    const any = window.tab().focused orelse return area;
    area.right = @max(area.left, area.right - ScrollBar.width(any));
    return area;
}

/// Where the palette goes in `area`, the terminals' part of the frame's
/// client area (`paletteArea`), listing `count` rows: a twentieth of the
/// area's height and `margin` below its top, centred across it, `width`
/// wide or as wide as the area leaves, as tall as up to `rows` of the
/// rows, as many as its height leaves, or "No matches" with none. Null
/// when it leaves less than `min_width`, or less than one row, whatever
/// `count`: that a palette fits never depends on the query.
pub fn paletteRect(m: Metrics, area: RECT, h: Heights, count: usize) ?RECT {
    const room_w = area.right - area.left - 2 * m.margin;
    const width = @min(m.width, room_w);
    if (width < m.min_width) return null;
    const top = area.top + @divTrunc(area.bottom - area.top, 20) + m.margin;
    const row = m.rowHeight(h);
    const room_h = area.bottom - m.margin - top - m.head(h) - 2 * m.list_pad;
    if (row <= 0 or room_h < row) return null;
    const fit: usize = @intCast(@divTrunc(room_h, row));
    const rows: i32 = @intCast(@min(@as(usize, @intCast(m.rows)), fit, count));
    const body = if (count == 0)
        @min(m.noneHeight(h), room_h + 2 * m.list_pad)
    else
        2 * m.list_pad + rows * row;
    const left = area.left + @divTrunc(area.right - area.left - width, 2);
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + m.head(h) + body };
}

/// What a palette `width` by `height` holds, in its own client
/// coordinates: the field across the top (the EDIT in it, as tall as a
/// line of its text, centred down it), the divider under it, and the list
/// under that to the bottom, or "No matches" in its place.
pub const Layout = struct {
    edit: RECT,
    divider: RECT,
    list: RECT,
    none: RECT,

    pub fn init(m: Metrics, width: i32, height: i32, h: Heights) Layout {
        const field_h = m.fieldHeight(h);
        const text_h = @max(0, h.field);
        const edit_top = @divTrunc(field_h - text_h, 2);
        const edit: RECT = .{
            .left = m.field_inset,
            .top = edit_top,
            .right = @max(m.field_inset, width - m.field_inset),
            .bottom = edit_top + text_h,
        };
        const head = m.head(h);
        const divider: RECT = .{ .left = 0, .top = field_h, .right = @max(0, width), .bottom = head };
        const list_top = head + m.list_pad;
        const list: RECT = .{
            .left = m.list_pad,
            .top = list_top,
            .right = @max(m.list_pad, width - m.list_pad),
            .bottom = @max(list_top, height - m.list_pad),
        };
        const none: RECT = .{ .left = edit.left, .top = head, .right = edit.right, .bottom = @max(head, height) };
        return .{ .edit = edit, .divider = divider, .list = list, .none = none };
    }
};

/// A row of the list at `item`: its tint, `row_gap` shorter, then inside
/// that, `row_pad` in, the title on the first line and the second line
/// under it, leaving the shortcut, `shortcut_w` wide, on the right,
/// centred down the row.
pub const Row = struct {
    fill: RECT,
    title: RECT,
    subtitle: RECT,
    shortcut: RECT,

    pub fn init(m: Metrics, item: RECT, h: Heights, shortcut_w: i32) Row {
        const half = @divTrunc(m.row_gap, 2);
        const fill: RECT = .{
            .left = item.left,
            .top = item.top + half,
            .right = item.right,
            .bottom = @max(item.top + half, item.bottom - (m.row_gap - half)),
        };
        const left = fill.left + m.row_pad;
        const right = @max(left, fill.right - m.row_pad);
        const shortcut_left = @max(left, right - @max(0, shortcut_w));
        const text_right = if (shortcut_w > 0) @max(left, shortcut_left - m.row_pad) else right;
        const title_top = fill.top + m.row_pad;
        const title_bottom = title_top + @max(0, h.title);
        const sub_top = title_bottom + m.title_gap;
        return .{
            .fill = fill,
            .title = .{ .left = left, .top = title_top, .right = text_right, .bottom = title_bottom },
            .subtitle = .{ .left = left, .top = sub_top, .right = text_right, .bottom = sub_top + @max(0, h.small) },
            .shortcut = .{ .left = shortcut_left, .top = fill.top, .right = right, .bottom = fill.bottom },
        };
    }
};

const testing = std.testing;
const Config = @import("../../config.zig").Config;

test "win32: the command palette sits near the top centre of the area under the tab bar, as tall as its rows, or not at all" {
    const m = Metrics.init(96);
    const h: Heights = .{ .field = 27, .title = 19, .small = 16 };
    try testing.expectEqual(48, m.fieldHeight(h));
    // A large font makes the field taller.
    try testing.expectEqual(40 + 16, m.fieldHeight(.{ .field = 40, .title = 19, .small = 16 }));
    try testing.expectEqual(4 + 16 + 19 + 2 + 16, m.rowHeight(h));
    try testing.expectEqual(750, Metrics.init(144).width);
    const head = 48 + 1;
    const row = 57;
    // A wide area: 500 wide, centred, a twentieth of its height and 8
    // below its top, with five rows, or as many as it lists.
    const area: RECT = .{ .left = 0, .top = 30, .right = 1000, .bottom = 800 };
    const top = 30 + 770 / 20 + 8;
    try testing.expectEqual(RECT{ .left = 250, .top = top, .right = 750, .bottom = top + head + 10 + 5 * row + 10 }, paletteRect(m, area, h, 60).?);
    try testing.expectEqual(RECT{ .left = 250, .top = top, .right = 750, .bottom = top + head + 10 + 2 * row + 10 }, paletteRect(m, area, h, 2).?);
    // None: "No matches", 16 above and below it.
    try testing.expectEqual(RECT{ .left = 250, .top = top, .right = 750, .bottom = top + head + 16 + 19 + 16 }, paletteRect(m, area, h, 0).?);
    // A narrower one: the palette narrows to it, down to 240.
    const narrow = paletteRect(m, .{ .left = 100, .top = 0, .right = 500, .bottom = 800 }, h, 60).?;
    try testing.expectEqual(RECT{ .left = 108, .top = 48, .right = 492, .bottom = 48 + head + 10 + 5 * row + 10 }, narrow);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 256, .bottom = 800 }, h, 60) != null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 255, .bottom = 800 }, h, 60) == null);
    // A short one: fewer rows, down to one.
    const short = paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 328 }, h, 60).?;
    try testing.expectEqual(head + 10 + 3 * row + 10, short.bottom - short.top);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 149 }, h, 60) != null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 148 }, h, 60) == null);
    // Whether it fits does not depend on what it lists.
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 149 }, h, 0) != null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 1000, .bottom = 148 }, h, 0) == null);
    try testing.expect(paletteRect(m, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, h, 60) == null);
}

test "win32: the command palette's field, divider and list, and a row's parts" {
    const m = Metrics.init(96);
    const h: Heights = .{ .field = 27, .title = 19, .small = 16 };
    const l = Layout.init(m, 500, 300, h);
    try testing.expectEqual(RECT{ .left = 16, .top = 10, .right = 484, .bottom = 37 }, l.edit);
    try testing.expectEqual(RECT{ .left = 0, .top = 48, .right = 500, .bottom = 49 }, l.divider);
    try testing.expectEqual(RECT{ .left = 10, .top = 59, .right = 490, .bottom = 290 }, l.list);
    try testing.expectEqual(RECT{ .left = 16, .top = 49, .right = 484, .bottom = 300 }, l.none);
    // No room: nothing negative.
    const none = Layout.init(m, 0, 0, .{});
    try testing.expect(none.edit.right >= none.edit.left and none.list.bottom >= none.list.top);
    try testing.expect(none.none.right >= none.none.left and none.divider.right >= none.divider.left);

    const item: RECT = .{ .left = 0, .top = 40, .right = 480, .bottom = 97 };
    const r = Row.init(m, item, h, 100);
    try testing.expectEqual(RECT{ .left = 0, .top = 42, .right = 480, .bottom = 95 }, r.fill);
    try testing.expectEqual(RECT{ .left = 372, .top = 42, .right = 472, .bottom = 95 }, r.shortcut);
    try testing.expectEqual(RECT{ .left = 8, .top = 50, .right = 364, .bottom = 69 }, r.title);
    try testing.expectEqual(RECT{ .left = 8, .top = 71, .right = 364, .bottom = 87 }, r.subtitle);
    // No shortcut: the text goes to the right edge.
    try testing.expectEqual(472, Row.init(m, item, h, 0).title.right);
}

test "win32: the command palette's colours follow its terminal's background" {
    const white = win32.rgb(0xff, 0xff, 0xff);
    const black = win32.rgb(0, 0, 0);
    // macOS's measure: Ghostty's default background is dark, a pale one
    // light, and mid-grey on either side of a half.
    try testing.expect(!isLight(win32.rgb(0x28, 0x2c, 0x34)));
    try testing.expect(isLight(win32.rgb(0xfd, 0xf6, 0xe3)));
    try testing.expect(isLight(win32.rgb(0x80, 0x80, 0x80)));
    try testing.expect(!isLight(win32.rgb(0x7f, 0x7f, 0x7f)));
    // Green weighs most, blue least.
    try testing.expect(isLight(win32.rgb(0, 0xdb, 0)));
    try testing.expect(!isLight(win32.rgb(0, 0, 0xff)));
    try testing.expectEqual(black, lerp(black, white, 0));
    try testing.expectEqual(white, lerp(black, white, 1000));
    try testing.expectEqual(win32.rgb(0x80, 0x80, 0x80), lerp(black, white, 500));
    // Each channel apart.
    try testing.expectEqual(win32.rgb(0x10, 0x20, 0x30), lerp(win32.rgb(0x10, 0x20, 0x30), win32.rgb(0x10, 0x20, 0x30), 300));
    try testing.expectEqual(win32.rgb(0x33, 0, 0), lerp(black, win32.rgb(0xff, 0, 0), 200));

    const accent = win32.rgb(0x00, 0x78, 0xd7);
    for ([_]win32.COLORREF{ black, win32.rgb(0x28, 0x2c, 0x34), white, win32.rgb(0xfd, 0xf6, 0xe3) }) |bg| {
        const look = Look.of(bg, accent);
        try testing.expectEqual(!isLight(bg), look.dark);
        // Lifted off the terminal, the border further, the text readable
        // on it: lighter on a dark one, darker on a light one.
        try testing.expect(look.back != bg);
        try testing.expectEqual(look.dark, !isLight(look.back));
        try testing.expectEqual(look.dark, isLight(look.text));
        try testing.expect(distance(look.border, bg) > distance(look.back, bg));
        // The selection's tint, and the hover's, set apart from the back;
        // a match's letters, from the selection's tint and the text.
        try testing.expect(look.selected != look.back and look.hover != look.back and look.selected != look.hover);
        try testing.expect(look.match != look.selected and look.match != look.text and look.match != look.back);
    }
    // Near the line between light and dark too, the back stays on the
    // side of its look, under text of the other: every grey, and greys
    // tinted each way.
    for (0..256) |v| for ([_][3]u8{ .{ 0, 0, 0 }, .{ 12, 0, 0 }, .{ 0, 12, 0 }, .{ 0, 0, 12 } }) |tint| {
        const c: u8 = @intCast(v);
        const bg = win32.rgb(c -| tint[0], c -| tint[1], c -| tint[2]);
        const look = Look.of(bg, accent);
        try testing.expect(look.back != bg);
        try testing.expectEqual(look.dark, !isLight(look.back));
        try testing.expectEqual(look.dark, isLight(look.text));
    };
}

/// The largest of the channels' differences between `a` and `b`.
fn distance(a: win32.COLORREF, b: win32.COLORREF) u32 {
    var most: u32 = 0;
    for (0..3) |i| {
        const shift: u5 = @intCast(8 * i);
        const x: i32 = @intCast((a >> shift) & 0xff);
        const y: i32 = @intCast((b >> shift) & 0xff);
        most = @max(most, @abs(x - y));
    }
    return most;
}

test "win32: the command palette's fonts scale the message font's height" {
    // The message font's 12 at 96 DPI: 20, 14 and 12.
    try testing.expectEqual(-20, scaleHeight(-12, 20));
    try testing.expectEqual(-14, scaleHeight(-12, 14));
    try testing.expectEqual(-12, scaleHeight(-12, 12));
    // At 150%, or a larger text size: in proportion, rounded.
    try testing.expectEqual(-30, scaleHeight(-18, 20));
    try testing.expectEqual(-27, scaleHeight(-16, 20));
    // A cell height stays one.
    try testing.expectEqual(14, scaleHeight(12, 14));
    // Never zero, the system's default.
    try testing.expectEqual(-1, scaleHeight(-1, 1));
    try testing.expectEqual(1, scaleHeight(0, 12));
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
    // Some are left out: the GTK inspector, for one.
    try testing.expect(commands_kept < commands.len);
    try testing.expectEqual(commands_kept + jumps.len, entries.items.len);

    // Sorted as GTK sorts them; nothing unsupported.
    for (entries.items[0 .. entries.items.len - 1], entries.items[1..]) |a, b| {
        try testing.expect(!lessThan({}, b, a));
    }
    var saw_split = false;
    var saw_tab = false;
    var saw_inspector = false;
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
                // Its description, as macOS's second line.
                try testing.expect(e.description.len > 0);
                try testing.expectEqualStrings(e.description, e.subtitle());
            }
            if (std.mem.eql(u8, e.action_key, "new_tab")) {
                saw_tab = true;
                try testing.expectEqualStrings("Ctrl+Shift+T", e.shortcut);
            }
            if (std.mem.eql(u8, e.action_key, "inspector:toggle")) {
                saw_inspector = true;
                try testing.expectEqualStrings("Toggle Inspector", e.title);
                try testing.expectEqualStrings("Ctrl+Shift+I", e.shortcut);
            }
            try testing.expect(!std.mem.eql(u8, e.action_key, "show_gtk_inspector"));
            try testing.expect(!std.mem.eql(u8, e.action_key, "check_for_updates"));
        },
        .jump => {},
    };
    try testing.expect(saw_split and saw_tab and saw_inspector);

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

test "win32: the palette's commands and jumps are in the user's language" {
    if (comptime !i18n.windows.embedded) return error.SkipZigTest;
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    const commands = config.@"command-palette-entry".value.items;
    const jumps = [_]Jump{
        .{ .surface = @ptrFromInt(0x10000), .title = null },
        .{ .surface = @ptrFromInt(0x20000), .title = "vim" },
    };

    const catalog = try @import("../../os/i18n_catalog.zig").write(alloc, &.{
        .{ "Split Right", "Rechts teilen" },
        .{ "Split the terminal to the right.", "Das Terminal nach rechts teilen." },
        .{ "Focus", "Fokus" },
        .{ "Untitled", "Unbenannt" },
    });
    defer alloc.free(catalog);
    try i18n.windows.testUse(catalog);
    defer i18n.windows.testUse(null) catch unreachable;

    var entries = try build(alloc, commands, &config.keybind.set, &jumps);
    defer entries.deinit();
    var saw_split = false;
    var saw_tab = false;
    var titles: [2][]const u8 = undefined;
    for (entries.items) |*e| switch (e.run) {
        .action => {
            if (std.mem.eql(u8, e.action_key, "new_split:right")) {
                saw_split = true;
                try testing.expectEqualStrings("Rechts teilen", e.title);
                try testing.expectEqualStrings("Das Terminal nach rechts teilen.", e.description);
                // What the filter matches is what shows.
                try testing.expect(std.mem.indexOf(u8, e.folded_title, "rechts") != null);
            }
            // One the catalog has nothing for, as written.
            if (std.mem.eql(u8, e.action_key, "new_tab")) {
                saw_tab = true;
                try testing.expectEqualStrings("New Tab", e.title);
            }
        },
        .jump => |surface| titles[@intFromPtr(surface) / 0x10000 - 1] = e.title,
    };
    try testing.expect(saw_split and saw_tab);
    try testing.expectEqualStrings("Fokus: Unbenannt", titles[0]);
    try testing.expectEqualStrings("Fokus: vim", titles[1]);

    // The configuration's own are untouched: another language's palette
    // starts from them.
    for (commands) |c| {
        if (c.action == .new_split and c.action.new_split == .right) {
            try testing.expectEqualStrings("Split Right", c.title);
        }
    }
}

test "win32: a jump's working directory cannot reorder or hide the palette's text" {
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    // As a shell can report them (src/termio/windows_pwd.zig takes a bidi
    // control); the text not UTF-8 stays, and its line is left out.
    const jumps = [_]Jump{
        .{ .surface = @ptrFromInt(0x10000), .title = "a", .pwd = "C:\\a\u{202E}gpj.exe" },
        .{ .surface = @ptrFromInt(0x20000), .title = "b", .pwd = "C:\\b\u{200B}\u{2066}c\u{85}" },
        .{ .surface = @ptrFromInt(0x30000), .title = "c", .pwd = "C:\\caf\u{E9}" },
        .{ .surface = @ptrFromInt(0x40000), .title = "d", .pwd = "C:\\d\xff" },
    };
    var entries = try build(alloc, &.{}, &config.keybind.set, &jumps);
    defer entries.deinit();
    const want = [_][]const u8{ "C:\\aU+202Egpj.exe", "C:\\bU+200BU+2066cU+0085", "C:\\caf\u{E9}", "C:\\d\xff" };
    try testing.expectEqual(want.len, entries.items.len);
    for (entries.items) |e| {
        const i = @intFromPtr(e.run.jump) / 0x10000 - 1;
        try testing.expectEqualStrings(want[i], e.description);
    }
}

test "win32: a palette row's second line is its description, which a command's tooltip shows whole" {
    const jump: Entry.Run = .{ .jump = @ptrFromInt(0x10000) };
    const action: Entry.Run = .{ .action = .new_tab };
    // A command's description, as macOS's second line and help, which
    // shows all of one the line cuts short.
    const described: Entry = .{ .title = "New Tab", .action_key = "new_tab", .description = "Open a new tab.", .run = action };
    try testing.expectEqualStrings("Open a new tab.", described.subtitle());
    try testing.expectEqualStrings("Open a new tab.", described.tooltip().?);
    // A command with none: its action on the second line, no tooltip.
    const bare: Entry = .{ .title = "New Tab", .action_key = "new_tab", .run = action };
    try testing.expectEqualStrings("new_tab", bare.subtitle());
    try testing.expect(bare.tooltip() == null);
    // A jump's working directory is its second line already; a jump with
    // none has nothing.
    const dir: Entry = .{ .title = "Focus: vim", .description = "C:\\src", .run = jump };
    try testing.expectEqualStrings("C:\\src", dir.subtitle());
    try testing.expect(dir.tooltip() == null);
    const plain: Entry = .{ .title = "Focus: vim", .run = jump };
    try testing.expect(plain.tooltip() == null);

    // The default commands as listed: each has its description as its
    // tooltip, and the default configuration describes them all.
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    const jumps = [_]Jump{.{ .surface = @ptrFromInt(0x10000), .title = "vim", .pwd = "C:\\src" }};
    var entries = try build(alloc, config.@"command-palette-entry".value.items, &config.keybind.set, &jumps);
    defer entries.deinit();
    for (entries.items) |*e| switch (e.run) {
        .action => {
            try testing.expect(e.description.len > 0);
            try testing.expectEqualStrings(e.description, e.tooltip().?);
        },
        .jump => try testing.expect(e.tooltip() == null),
    };
}

test "win32: the palette shows the letters a query matched, by the code points they fold from" {
    const alloc = testing.allocator;
    const Case = struct { text: []const u8, query: []const u8, span: ?Span };
    const cases = [_]Case{
        .{ .text = "Split Right", .query = "right", .span = .{ .start = 6, .end = 11 } },
        .{ .text = "Split Right", .query = "SPLIT R", .span = .{ .start = 0, .end = 7 } },
        // The first occurrence, as the filter finds it.
        .{ .text = "Close Other Tabs", .query = "o", .span = .{ .start = 2, .end = 3 } },
        // "ß" folds to "ss": a match of either "s", or both, takes it.
        .{ .text = "Straße", .query = "asse", .span = .{ .start = 3, .end = 7 } },
        .{ .text = "Straße", .query = "as", .span = .{ .start = 3, .end = 6 } },
        .{ .text = "Straße", .query = "se", .span = .{ .start = 4, .end = 7 } },
        // Code points of two and three bytes, and a byte that is not UTF-8.
        .{ .text = "Über", .query = "üb", .span = .{ .start = 0, .end = 3 } },
        .{ .text = "a\xffb", .query = "\xffb", .span = .{ .start = 1, .end = 3 } },
        .{ .text = "x\u{2026}y", .query = "y", .span = .{ .start = 4, .end = 5 } },
        // Whole grapheme clusters: a combining mark, a skin tone, a
        // joined emoji; but a control character stands alone.
        .{ .text = "Cafe\u{301} x", .query = "cafe", .span = .{ .start = 0, .end = 6 } },
        .{ .text = "Cafe\u{301} x", .query = "\u{301}", .span = .{ .start = 3, .end = 6 } },
        .{ .text = "x\u{1F44D}\u{1F3FD}y", .query = "x\u{1F44D}", .span = .{ .start = 0, .end = 9 } },
        .{ .text = "a\u{1F468}\u{200D}\u{1F469}b", .query = "\u{1F469}b", .span = .{ .start = 1, .end = 13 } },
        .{ .text = "a\x01\u{301}", .query = "a", .span = .{ .start = 0, .end = 1 } },
        // None: an empty query, or no match.
        .{ .text = "Split Right", .query = "", .span = null },
        .{ .text = "Split Right", .query = "left", .span = null },
    };
    for (cases) |c| {
        const folded_text = try fold(alloc, c.text);
        defer alloc.free(folded_text);
        const folded = try fold(alloc, c.query);
        defer alloc.free(folded);
        try testing.expectEqual(c.span, matchSpan(c.text, folded_text, folded));
    }

    // A right-to-left line is drawn whole: Ghostty's Hebrew titles, an
    // Arabic letter in a jump's directory; not a left-to-right one.
    try testing.expect(holdsRtl("\u{05e4}\u{05d9}\u{05e6}\u{05d5}\u{05dc} \u{05d9}\u{05de}\u{05d9}\u{05e0}\u{05d4}"));
    try testing.expect(holdsRtl("C:\\\u{0627}"));
    try testing.expect(holdsRtl("\xff\u{05d0}"));
    try testing.expect(!holdsRtl("Split Right"));
    try testing.expect(!holdsRtl("Stra\u{00df}e \u{1F44D}\xff"));

    // Whatever the text and query, the span's own folding holds the
    // query, and it starts and ends on a code point.
    const texts = [_][]const u8{ "New Split: Right", "ΣΊΣΥΦΟΣ straße", "İstanbul ǅ ﬁle", "a\xffΣ\xfe" };
    for (texts) |text| {
        const folded_text = try fold(alloc, text);
        defer alloc.free(folded_text);
        for (0..folded_text.len) |from| for (from + 1..@min(folded_text.len, from + 4) + 1) |to| {
            const query = folded_text[from..to];
            const span = matchSpan(text, folded_text, query).?;
            const again = try fold(alloc, text[span.start..span.end]);
            defer alloc.free(again);
            try testing.expect(std.mem.indexOf(u8, again, query) != null);
            try testing.expect(text[span.start] & 0xc0 != 0x80);
            try testing.expect(span.end == text.len or text[span.end] & 0xc0 != 0x80);
        };
    }
}

test "win32: a palette row bolds a match in its title, else in its action key when that is its second line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try testFolded(a, &.{
        .{ .title = "Split Right", .action_key = "new_split:right", .description = "Split the terminal to the right.", .run = .{ .action = .ignore } },
        .{ .title = "Reload", .action_key = "reload_config", .run = .{ .action = .ignore } },
        .{ .title = "Copy", .action_key = "copy_to_clipboard", .description = "Copy the selection.", .run = .{ .action = .ignore } },
    });
    const folded = try fold(a, "Split");
    // The title's match, and none on the second line.
    try testing.expectEqual(Spans{ .title = .{ .start = 0, .end = 5 } }, entries[0].spans(folded));
    // A match in the action key alone, its second line: there.
    try testing.expectEqual(Spans{ .subtitle = .{ .start = 0, .end = 6 } }, entries[1].spans(try fold(a, "RELOAD_")));
    try testing.expectEqualStrings("reload_config", entries[1].subtitle());
    // A match in the action key alone under a description, which the
    // second line shows: none.
    try testing.expectEqual(Spans{}, entries[2].spans(try fold(a, "clipboard")));
    // Each span lies in the line it is drawn on.
    for (&entries) |*e| for ([_][]const u8{ "s", "re", "co", "_", "p" }) |q| {
        const s = e.spans(try fold(a, q));
        if (s.title) |t| try testing.expect(t.end <= e.title.len);
        if (s.subtitle) |t| try testing.expect(t.end <= e.subtitle().len);
    };
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
    const folded = try fold(testing.allocator, query);
    defer testing.allocator.free(folded);
    try filter(testing.allocator, entries, folded, &out);
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
            try filter(alloc, items, folded, &next);
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
