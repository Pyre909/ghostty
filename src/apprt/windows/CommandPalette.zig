//! The command palette, as GTK's (src/apprt/gtk/class/command_palette.zig
//! and command-palette.blp) and macOS's (TerminalCommandPalette.swift)
//! list it: the configuration's `command-palette-entry` commands whose
//! action this runtime performs (`supported`), and one entry per terminal
//! that focuses it, "Focus: <title>"; sorted by title as both sort them
//! (`lessThan`); filtered by a case-insensitive substring of the title or
//! the action, the entries whose title matches first (`filter`); each with
//! the shortcut its action is bound to, in Windows' key names
//! (`shortcutLabel`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const Surface = @import("Surface.zig").Surface;
const App = @import("App.zig").App;

const Binding = input.Binding;

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
    /// in the app's list, the order they were made in, as GTK orders
    /// them by the core's surface id.
    sort_key: usize = 0,

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
        list.appendAssumeCapacity(.{
            .title = cloned.title,
            .action_key = try a.print("{f}", .{cloned.action}),
            .description = cloned.description,
            .shortcut = shortcut,
            .run = .{ .action = cloned.action },
        });
    }
    for (jumps, 0..) |jump, i| {
        const shown = jump.title orelse "Untitled";
        const pwd = jump.pwd orelse "";
        list.appendAssumeCapacity(.{
            .title = try a.print("Focus: {s}", .{shown}),
            .description = if (pwd.len > 0 and std.mem.indexOf(u8, shown, pwd) == null) try a.dupe(u8, pwd) else "",
            .run = .{ .jump = jump.surface },
            .sort_key = i,
        });
    }
    // Stable, as GTK's sort is.
    std.mem.sort(Entry, list.items, {}, lessThan);
    return .{ .arena = arena, .items = list.items };
}

/// The entries for `app` now: its configuration's commands and shortcuts,
/// as GTK's palette reads its window's configuration, and a jump to each
/// terminal that is not closing, in every window, titled as it shows
/// (`Surface.effectiveTitle`), as GTK's lists every surface of the core.
pub fn forApp(app: *App) Allocator.Error!Entries {
    const alloc = app.core_app.alloc;
    // The directories, read from the cores, only until `build` has copied
    // what it keeps.
    var scratch: std.heap.ArenaAllocator = .init(alloc);
    defer scratch.deinit();
    const s = scratch.allocator();
    var jumps: std.ArrayList(Jump) = try .initCapacity(s, app.surfaces.items.len);
    for (app.surfaces.items) |surface| {
        if (surface.closing) continue;
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

/// Whether `entry` matches `query`: a substring of its title, else of its
/// action key, ignoring ASCII case, as GTK's palette filters on either
/// (its StringFilters on `title` and `action-key`). An empty query
/// matches every title.
pub fn match(entry: *const Entry, query: []const u8) Match {
    if (containsIgnoreCase(entry.title, query)) return .title;
    if (entry.action_key.len > 0 and containsIgnoreCase(entry.action_key, query)) return .action_key;
    return .none;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The indices into `entries` of those that match `query`, into `out`
/// (cleared first): those whose title matches, then those whose action
/// key alone does, as macOS ranks a title match over the rest; each kind
/// in the entries' order.
pub fn filter(
    alloc: Allocator,
    entries: []const Entry,
    query: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(alloc, entries.len);
    for (entries, 0..) |*entry, i| {
        if (match(entry, query) == .title) out.appendAssumeCapacity(@intCast(i));
    }
    for (entries, 0..) |*entry, i| {
        if (match(entry, query) == .action_key) out.appendAssumeCapacity(@intCast(i));
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

const testing = std.testing;
const Config = @import("../../config.zig").Config;

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

test "win32: the palette filters on title and action, title matches first" {
    const entries = [_]Entry{
        .{ .title = "Previous", .action_key = "previous_tab", .run = .{ .action = .ignore } },
        .{ .title = "Close Tab", .action_key = "close_tab:this", .run = .{ .action = .ignore } },
        .{ .title = "New Split", .action_key = "new_split:right", .run = .{ .action = .ignore } },
        .{ .title = "Split Zoom", .action_key = "toggle_split_zoom", .run = .{ .action = .ignore } },
        .{ .title = "Focus: tab", .description = "C:\\split", .run = .{ .jump = @ptrFromInt(0x10000) } },
        .{ .title = "Next", .action_key = "next_tab", .run = .{ .action = .ignore } },
    };
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

test "win32: the palette's filter narrows as the query grows, and keeps the order" {
    // Metamorphic, over the default commands and their shortcuts and every
    // prefix of queries made from their own titles and action keys:
    // extending a query never adds an entry; within the title matches and
    // within the rest the entries' order is kept; and each result is
    // exactly the entries that match.
    const alloc = testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    var entries = try build(alloc, config.@"command-palette-entry".value.items, &config.keybind.set, &.{});
    defer entries.deinit();
    const items = entries.items;

    var prev: std.ArrayList(u32) = .empty;
    defer prev.deinit(alloc);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(alloc);
    var seed: std.Random.DefaultPrng = .init(0x9a1e77e);
    const rand = seed.random();
    var checked: usize = 0;
    for (0..200) |_| {
        // Part of an entry's title or action key, in a random case.
        const from = items[rand.uintLessThan(usize, items.len)];
        const source = if (rand.boolean()) from.title else from.action_key;
        const start = rand.uintLessThan(usize, source.len);
        var query_buf: [64]u8 = undefined;
        const len = @min(source.len - start, query_buf.len);
        for (source[start..][0..len], 0..) |c, i| {
            query_buf[i] = if (rand.boolean()) std.ascii.toUpper(c) else std.ascii.toLower(c);
        }
        try filter(alloc, items, "", &prev);
        for (0..len + 1) |n| {
            const query = query_buf[0..n];
            try filter(alloc, items, query, &next);
            // Narrower: everything in `next` was in `prev`.
            for (next.items) |i| try testing.expect(std.mem.indexOfScalar(u32, prev.items, i) != null);
            // Exactly the matches, title matches first, each kind in order.
            var count: usize = 0;
            for (items) |*e| {
                if (match(e, query) != .none) count += 1;
            }
            try testing.expectEqual(count, next.items.len);
            var past_titles = false;
            for (next.items, 0..) |i, k| {
                const m = match(&items[i], query);
                try testing.expect(m != .none);
                if (m == .action_key) past_titles = true;
                if (past_titles) try testing.expectEqual(Match.action_key, m);
                if (k > 0 and match(&items[next.items[k - 1]], query) == m) {
                    try testing.expect(next.items[k - 1] < i);
                }
            }
            std.mem.swap(std.ArrayList(u32), &prev, &next);
            checked += 1;
        }
        // The query it was made from finds its entry.
        try testing.expect(prev.items.len > 0);
    }
    try testing.expect(checked > 200);
}
