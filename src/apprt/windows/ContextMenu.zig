//! A terminal's context menu, as GTK lists its items (`context_menu_model`
//! in src/apprt/gtk/ui/1.0/surface.blp): Copy, Paste and Notify on Next
//! Command Finish; Clear and Reset; the Split, Tab and Window submenus;
//! the Config submenu. Left out are what this runtime does not carry out,
//! Change Window Title… (a window's caption is its shown tab's) and Open
//! Configuration in New Window (`App.openConfig`). Added, as macOS has it
//! ("Terminal Read-only" in `menu(for:)`, SurfaceView_AppKit.swift), is a
//! checked "Read-only", after Reset. Copy is greyed without a selection, as
//! GTK disables its action (`syncActions` in
//! src/apprt/gtk/class/window.zig). Notify on Next Command Finish is no
//! binding's action but GTK's surface's own, a check its next finished
//! command clears (`Surface.notify_next_command`); it is checked while set,
//! as GTK shows its state. Each other item shows the shortcut its action
//! is bound to after a tab, in Windows' key names, as the command palette
//! shows one (`CommandPalette.shortcutLabel`) (`menuItems`).
//!
//! It is the system's popup menu, light in dark mode as well, and the
//! terminal's frame owns it (`TrackPopupMenuEx`), so that the frame hears
//! WM_ENTERMENULOOP and WM_EXITMENULOOP and the app keeps ticking while it
//! is open (`App.modal_loop_depth`). It opens where the terminal's right
//! button comes up, if the core left that button's press to it
//! (`Surface.Mouse.menu`): on the release, the Windows convention, rather
//! than on the press, as GTK and macOS open theirs, so that the menu's loop
//! never takes the capture from the terminal in the middle of a click. No
//! key opens it.
//!
//! The loop runs inside the terminal's WM_RBUTTONUP handler and dispatches
//! whatever is posted meanwhile, so no teardown runs until it ends
//! (`App.beginTerminalLoop`). The terminal has the focus back when it
//! closes, and its chosen item's action is then performed on it, as the
//! command palette performs an entry (`perform`), unless the terminal or
//! its window began to close meanwhile.

const std = @import("std");
const builtin = @import("builtin");

const input = @import("../../input.zig");
const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const unsafeCodepoint = @import("App.zig").unsafeCodepoint;
const Surface = @import("Surface.zig").Surface;
const SearchBar = @import("SearchBar.zig");
const CommandPalette = @import("CommandPalette.zig");

const Binding = input.Binding;
const log = std.log.scoped(.win32);

/// GTK's submenus.
pub const Submenu = enum {
    split,
    tab,
    window,
    config,

    pub fn label(self: Submenu) []const u8 {
        return switch (self) {
            .split => "Split",
            .tab => "Tab",
            .window => "Window",
            .config => "Config",
        };
    }
};

/// What an item does: a binding's action, performed as a key's would be,
/// or GTK's one item that is not one, which checks or clears the
/// terminal's `notify_next_command`.
pub const Command = union(enum) {
    binding: Binding.Action,
    notify_next_command,
};

/// An item as the menu always lists it.
const Entry = struct {
    label: []const u8,
    action: Command,
    /// GTK's section it is in; a line divides one section from the next.
    section: u8,
    /// The submenu it is in, null for the menu itself.
    submenu: ?Submenu = null,
};

/// GTK's items in GTK's order, but for what this runtime leaves out and
/// the read-only item it adds (see the top of this file).
const layout = [_]Entry{
    .{ .label = "Copy", .action = .{ .binding = .{ .copy_to_clipboard = .mixed } }, .section = 0 },
    .{ .label = "Paste", .action = .{ .binding = .paste_from_clipboard }, .section = 0 },
    .{ .label = "Notify on Next Command Finish", .action = .notify_next_command, .section = 0 },
    .{ .label = "Clear", .action = .{ .binding = .clear_screen }, .section = 1 },
    .{ .label = "Reset", .action = .{ .binding = .reset }, .section = 1 },
    .{ .label = "Read-only", .action = .{ .binding = .toggle_readonly }, .section = 1 },
    .{ .label = "Change Title\u{2026}", .action = .{ .binding = .prompt_surface_title }, .section = 2, .submenu = .split },
    .{ .label = "Split Up", .action = .{ .binding = .{ .new_split = .up } }, .section = 2, .submenu = .split },
    .{ .label = "Split Down", .action = .{ .binding = .{ .new_split = .down } }, .section = 2, .submenu = .split },
    .{ .label = "Split Left", .action = .{ .binding = .{ .new_split = .left } }, .section = 2, .submenu = .split },
    .{ .label = "Split Right", .action = .{ .binding = .{ .new_split = .right } }, .section = 2, .submenu = .split },
    .{ .label = "Close Split", .action = .{ .binding = .close_surface }, .section = 2, .submenu = .split },
    .{ .label = "Change Tab Title\u{2026}", .action = .{ .binding = .prompt_tab_title }, .section = 2, .submenu = .tab },
    .{ .label = "New Tab", .action = .{ .binding = .new_tab }, .section = 2, .submenu = .tab },
    .{ .label = "Close Tab", .action = .{ .binding = .{ .close_tab = .this } }, .section = 2, .submenu = .tab },
    .{ .label = "New Window", .action = .{ .binding = .new_window }, .section = 2, .submenu = .window },
    .{ .label = "Close Window", .action = .{ .binding = .close_window }, .section = 2, .submenu = .window },
    .{ .label = "Open Configuration in OS Editor", .action = .{ .binding = .{ .open_config = .os_open } }, .section = 3, .submenu = .config },
    .{ .label = "Reload Configuration", .action = .{ .binding = .reload_config }, .section = 3, .submenu = .config },
};

comptime {
    // Only what this runtime carries out, as the command palette lists
    // only that (`CommandPalette.supported`); `open_config:new_window` is
    // refused by `App.openConfig`. A submenu's items are next to one
    // another, all in one section.
    for (layout, 0..) |entry, i| {
        switch (entry.action) {
            .binding => |action| {
                if (!CommandPalette.supported(action)) @compileError("not carried out: " ++ entry.label);
                if (action == .open_config and action.open_config != .os_open) @compileError("refused: " ++ entry.label);
            },
            .notify_next_command => {},
        }
        if (i == 0) continue;
        const prev = layout[i - 1];
        if (entry.section < prev.section) @compileError("out of order: " ++ entry.label);
        const sub = entry.submenu orelse continue;
        for (layout[0 .. i - 1]) |earlier| {
            if (earlier.submenu == sub and prev.submenu != sub) @compileError("apart from its submenu: " ++ entry.label);
        }
        if (prev.submenu == sub and prev.section != entry.section) @compileError("across sections: " ++ entry.label);
    }
}

/// How many items the menu has.
pub const count = layout.len;

/// The most bytes of a shortcut's label (`CommandPalette.shortcutLabel`)
/// an item keeps; a longer one is not shown. "Win+Ctrl+Alt+Shift+" and the
/// longest key name take less than half of it.
const shortcut_max = 64;

/// An item of the menu for one terminal (`menuItems`).
pub const Item = struct {
    /// Its command id: its place in the list, from 1, since
    /// TrackPopupMenuEx returns 0 when nothing is chosen.
    id: u16,
    label: []const u8,
    action: Command,
    section: u8,
    submenu: ?Submenu,
    /// False for Copy without a selection, shown greyed.
    enabled: bool,
    /// Shown with a check: Read-only, while the terminal is, and Notify on
    /// Next Command Finish, while it is set.
    checked: bool,
    shortcut_buf: [shortcut_max]u8,
    shortcut_len: u8,

    /// The label of the shortcut its action is bound to, or empty.
    pub fn shortcut(self: *const Item) []const u8 {
        return self.shortcut_buf[0..self.shortcut_len];
    }
};

/// What the menu's items show of the terminal it is for.
pub const State = struct {
    /// Copy is enabled.
    selection: bool = false,
    /// Read-only is checked.
    readonly: bool = false,
    /// Notify on Next Command Finish is checked.
    notify_next_command: bool = false,
};

/// The menu's items for a terminal in `state`, with the shortcuts `set`
/// binds their actions to, as the command palette finds them
/// (`Binding.Set.getTrigger`). Items keep what they show: nothing points
/// into `set`, which a reload frees.
pub fn menuItems(state: State, set: *const Binding.Set) [count]Item {
    var items: [count]Item = undefined;
    for (layout, &items, 0..) |entry, *item, i| {
        item.* = .{
            .id = @intCast(i + 1),
            .label = entry.label,
            .action = entry.action,
            .section = entry.section,
            .submenu = entry.submenu,
            .enabled = switch (entry.action) {
                .binding => |action| action != .copy_to_clipboard or state.selection,
                .notify_next_command => true,
            },
            .checked = switch (entry.action) {
                .binding => |action| action == .toggle_readonly and state.readonly,
                .notify_next_command => state.notify_next_command,
            },
            .shortcut_buf = undefined,
            .shortcut_len = 0,
        };
        const action = switch (entry.action) {
            .binding => |action| action,
            .notify_next_command => continue,
        };
        const trigger = set.getTrigger(action) orelse continue;
        var w: std.Io.Writer = .fixed(&item.shortcut_buf);
        const shown = CommandPalette.shortcutLabel(&w, trigger) catch false;
        if (shown) item.shortcut_len = @intCast(w.buffered().len);
    }
    return items;
}

/// The longest text `itemText` writes: the longest label, a tab, and a
/// shortcut whose every byte is a code point written as "U+XXXX".
const text_max = 512;

/// `item`'s text as AppendMenuW takes it: its label, then a tab and its
/// shortcut, which the menu right-aligns. In the shortcut, which comes
/// from the configuration, an '&' is doubled, as a single one would
/// underline the next character, and a code point that can reorder or
/// hide text (`App.unsafeCodepoint`) is written as "U+XXXX", as the link
/// preview writes one; a shortcut that is not UTF-8 is left out.
pub fn itemText(buf: *[text_max:0]u16, item: *const Item) [:0]const u16 {
    var out: Wide = .{ .buf = buf };
    out.utf8(item.label);
    const shortcut = item.shortcut();
    if (shortcut.len > 0) if (std.unicode.Utf8View.init(shortcut)) |view| {
        out.unit('\t');
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp == '&') {
                out.unit('&');
                out.unit('&');
            } else if (unsafeCodepoint(cp)) {
                var hex: [10]u8 = undefined;
                out.utf8(std.fmt.bufPrint(&hex, "U+{X:0>4}", .{cp}) catch unreachable);
            } else {
                out.codepoint(cp);
            }
        }
    } else |_| {};
    buf[out.len] = 0;
    return buf[0..out.len :0];
}

/// UTF-16 into a fixed buffer, dropping what does not fit.
const Wide = struct {
    buf: *[text_max:0]u16,
    len: usize = 0,

    fn unit(self: *Wide, u: u16) void {
        if (self.len == text_max) return;
        self.buf[self.len] = u;
        self.len += 1;
    }

    fn codepoint(self: *Wide, cp: u21) void {
        if (cp < 0x10000) return self.unit(@intCast(cp));
        if (self.len + 2 > text_max) return;
        const v = cp - 0x10000;
        self.unit(@intCast(0xD800 + (v >> 10)));
        self.unit(@intCast(0xDC00 + (v & 0x3FF)));
    }

    /// The labels and the escapes are valid UTF-8.
    fn utf8(self: *Wide, s: []const u8) void {
        var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
        while (it.nextCodepoint()) |cp| self.codepoint(cp);
    }
};

/// Show `surface`'s menu at `at`, a point in its client area, where its
/// right button came up, once the core has had that release and the
/// terminal has let go of the capture (`Surface.handleMessage`); then
/// give the terminal the keyboard focus back, chosen or not, as GTK's
/// popover gives it back when it closes, and perform the chosen item.
/// Copy and Read-only follow the core's selection and flag; a terminal
/// with no core has neither. Notify on Next Command Finish follows the
/// terminal's own flag, core or not. All three are read once, as the menu
/// opens. Nothing shows if Windows cannot make the menu.
///
/// `surface` is alive when the menu returns: its loop is counted in
/// `App.terminal_loops`, so a teardown posted meanwhile (its shell
/// exiting, a close from another window) waits for it to end
/// (`App.canTearDown`). An item chosen once the terminal or its window
/// began to close is not performed, as GTK's popover, a part of its
/// surface, goes with it: what it did or asked `run` for would be for a
/// terminal about to go.
pub fn show(surface: *Surface, at: win32.POINT) void {
    const app = surface.app;
    const window = surface.window;
    const core = surface.liveCore();
    const items = menuItems(.{
        .selection = if (core) |c| c.hasSelection() else false,
        .readonly = if (core) |c| c.readonly else false,
        .notify_next_command = surface.notify_next_command,
    }, &app.config.keybind.set);
    const menu = build(&items) orelse return;
    var screen = at;
    _ = win32.ClientToScreen(surface.hwnd, &screen);

    app.beginTerminalLoop();
    const id = track(menu, window.hwnd, screen);
    app.endTerminalLoop();
    _ = win32.DestroyMenu(menu);

    // To the terminal itself, not to whatever its window gives the focus
    // to (`Window.focusTarget`): the menu opened only with the focus on the
    // terminal, as a click that moves it there is eaten
    // (WM_MOUSEACTIVATE), and an open command palette's field would take
    // the keys meant for the shell. GTK's popover gives its surface the
    // focus back in the same way. First, so that it comes back whether the
    // item is then performed or not.
    window.setKeyboardFocus(surface.hwnd, true);
    if (surface.closing or window.closing) return;
    if (id == 0 or id > items.len) return;
    const item = &items[id - 1];
    // Windows chooses no greyed item, nor is one performed here.
    if (!item.enabled) return;
    perform(surface, item);
}

/// For tests: stands in for TrackPopupMenuEx (`track`), given the menu,
/// its owner and the point on the screen it opens at, and answering the
/// id of the item chosen, or 0, as `Window.test_set_focus` stands for
/// SetFocus. Unset, no menu shows in a test, as one would wait for the
/// user.
pub var test_track: if (builtin.is_test) ?*const fn (win32.HMENU, win32.HWND, win32.POINT) u32 else void =
    if (builtin.is_test) null else {};

/// Run `menu`, owned by `owner`, at `at` on the screen until an item is
/// chosen, its id, or it is dismissed, 0. A menu Windows cannot show is
/// logged and answers 0 as well.
fn track(menu: win32.HMENU, owner: win32.HWND, at: win32.POINT) u32 {
    if (builtin.is_test) return if (test_track) |seen| seen(menu, owner, at) else 0;
    // TrackPopupMenuEx answers 0 both when the menu is dismissed and when
    // it fails, which sets the last error.
    win32.SetLastError(.SUCCESS);
    const id = win32.TrackPopupMenuEx(menu, win32.TPM_RETURNCMD | win32.TPM_RIGHTBUTTON, at.x, at.y, owner, null);
    if (id > 0) return @intCast(id);
    const err = win32.GetLastError();
    if (err != .SUCCESS) log.warn("cannot show a context menu err={}", .{err});
    return 0;
}

/// Perform `item`, the chosen one, on `surface`: Notify on Next Command
/// Finish sets the terminal's flag, which no core reads, to the reverse
/// of the check the menu showed, not of the flag now: the app ticks while
/// the menu is open, and a command that finished meanwhile cleared it, so
/// unchecking would set it again. A binding's action is performed as a
/// key's binding would be (`SearchBar.perform`), then the focus move it
/// chose, as the command palette performs an entry
/// (`CommandPalette.perform`).
///
/// The core may always be re-entered here: the menu opens only for a
/// release that reached the core (`consumed` in `Surface.handleMessage`),
/// which `Surface.syncMouse` lets through only while
/// `App.canReenterCore`. Nothing between that and here changes it:
/// a prompt opened meanwhile, by the release's own callback or by a tick
/// the menu's loop dispatches, runs its loop inside that call and has
/// closed when it returns (`App.endPrompt`), and `App.tick` clears
/// `ticking` as it returns. Were it ever not so, the item is dropped with
/// a warning rather than performed under a core frame or a prompt.
///
/// Copy, Paste, Clear, Reset, Read-only, Close Split, Close Tab, Close
/// Window and Open Configuration take effect at once, a close posting its
/// teardown or asking first (`Surface.close`, `Window.requestClose`). The
/// splits, New Tab, New Window, the two title prompts and Reload
/// Configuration are recorded by `App.performAction` itself, as they are
/// from a key's binding (`App.requests`), and made by `run` once the
/// terminal's handler has returned.
fn perform(surface: *Surface, item: *const Item) void {
    const action = switch (item.action) {
        .binding => |action| action,
        .notify_next_command => {
            surface.notify_next_command = !item.checked;
            return;
        },
    };
    const app = surface.app;
    if (!app.canReenterCore()) {
        log.warn("context menu item dropped, the core cannot be re-entered action={t}", .{action});
        return;
    }
    _ = SearchBar.perform(surface, action);
    app.applyPendingFocus();
}

/// For tests: how many of the menu calls `build` makes may still
/// succeed; the next one fails, and every one after it, as Windows' would
/// once it can make no more. Null for all of them.
pub var test_calls_left: if (builtin.is_test) ?usize else void =
    if (builtin.is_test) null else {};

fn failNow() bool {
    if (!builtin.is_test) return false;
    const left = test_calls_left orelse return false;
    if (left == 0) return true;
    test_calls_left = left - 1;
    return false;
}

fn createMenu() ?win32.HMENU {
    if (failNow()) return null;
    return win32.CreatePopupMenu();
}

fn append(menu: win32.HMENU, flags: win32.UINT, id: win32.UINT_PTR, text: ?win32.LPCWSTR) bool {
    if (failNow()) return false;
    return win32.AppendMenuW(menu, flags, id, text).toBool();
}

/// The menu of `items`: their sections divided by lines, each submenu a
/// popup in the section of its items. Null, with nothing left of what
/// was made, if Windows cannot make it.
fn build(items: *const [count]Item) ?win32.HMENU {
    const menu = createMenu() orelse {
        log.warn("cannot make a context menu err={}", .{win32.GetLastError()});
        return null;
    };
    const err = fill(menu, items) orelse return menu;
    log.warn("cannot fill a context menu err={}", .{err});
    // With the submenus it holds.
    _ = win32.DestroyMenu(menu);
    return null;
}

/// Put `items` in `menu`: null, or the error the call that failed left,
/// read before anything is destroyed.
fn fill(menu: win32.HMENU, items: *const [count]Item) ?win32.Win32Error {
    var i: usize = 0;
    while (i < items.len) {
        const first = &items[i];
        if (i > 0 and items[i - 1].section != first.section) {
            if (!append(menu, win32.MF_SEPARATOR, 0, null)) return win32.GetLastError();
        }
        const sub = first.submenu orelse {
            if (!appendItem(menu, first)) return win32.GetLastError();
            i += 1;
            continue;
        };
        var end = i;
        while (end < items.len and items[end].submenu == sub) end += 1;
        const popup = createMenu() orelse return win32.GetLastError();
        var buf: [text_max:0]u16 = undefined;
        var out: Wide = .{ .buf = &buf };
        out.utf8(sub.label());
        buf[out.len] = 0;
        for (items[i..end]) |*item| {
            if (!appendItem(popup, item)) break;
        } else if (append(menu, win32.MF_POPUP, @intFromPtr(popup), &buf)) {
            i = end;
            continue;
        }
        const err = win32.GetLastError();
        // Not yet the menu's, so not destroyed with it.
        _ = win32.DestroyMenu(popup);
        return err;
    }
    return null;
}

fn appendItem(menu: win32.HMENU, item: *const Item) bool {
    var buf: [text_max:0]u16 = undefined;
    const text = itemText(&buf, item);
    var flags = win32.MF_STRING;
    if (!item.enabled) flags |= win32.MF_GRAYED;
    if (item.checked) flags |= win32.MF_CHECKED;
    return append(menu, flags, item.id, text.ptr);
}

const testing = std.testing;

fn testItem(items: []const Item, label: []const u8) !*const Item {
    for (items) |*item| {
        if (std.mem.eql(u8, item.label, label)) return item;
    }
    return error.TestUnexpectedResult;
}

test "win32: the context menu greys Copy without a selection and checks Read-only and Notify on Next Command Finish while set" {
    var set: Binding.Set = .{};
    defer set.deinit(testing.allocator);
    const copy = "Copy";
    const readonly = "Read-only";
    const notify = "Notify on Next Command Finish";
    for (0..8) |bits| {
        const state: State = .{
            .selection = bits & 1 != 0,
            .readonly = bits & 2 != 0,
            .notify_next_command = bits & 4 != 0,
        };
        const items = menuItems(state, &set);
        try testing.expectEqual(state.selection, (try testItem(&items, copy)).enabled);
        try testing.expectEqual(state.readonly, (try testItem(&items, readonly)).checked);
        try testing.expectEqual(state.notify_next_command, (try testItem(&items, notify)).checked);
        // Nothing else follows any of them.
        for (&items) |*item| {
            if (!std.mem.eql(u8, item.label, copy)) try testing.expect(item.enabled);
            if (!std.mem.eql(u8, item.label, readonly) and !std.mem.eql(u8, item.label, notify)) {
                try testing.expect(!item.checked);
            }
        }
    }
}

test "win32: the context menu is GTK's, less what this runtime does not carry out, and Read-only" {
    var set: Binding.Set = .{};
    defer set.deinit(testing.allocator);
    const items = menuItems(.{ .selection = true }, &set);
    // Label, action, submenu, in order, written out by hand from
    // surface.blp's `context_menu_model`. GTK's own action is named as the
    // union names it.
    const want = [_]struct { []const u8, []const u8, ?Submenu }{
        .{ "Copy", "copy_to_clipboard:mixed", null },
        .{ "Paste", "paste_from_clipboard", null },
        .{ "Notify on Next Command Finish", "notify_next_command", null },
        .{ "Clear", "clear_screen", null },
        .{ "Reset", "reset", null },
        .{ "Read-only", "toggle_readonly", null },
        .{ "Change Title\u{2026}", "prompt_surface_title", .split },
        .{ "Split Up", "new_split:up", .split },
        .{ "Split Down", "new_split:down", .split },
        .{ "Split Left", "new_split:left", .split },
        .{ "Split Right", "new_split:right", .split },
        .{ "Close Split", "close_surface", .split },
        .{ "Change Tab Title\u{2026}", "prompt_tab_title", .tab },
        .{ "New Tab", "new_tab", .tab },
        .{ "Close Tab", "close_tab:this", .tab },
        .{ "New Window", "new_window", .window },
        .{ "Close Window", "close_window", .window },
        .{ "Open Configuration in OS Editor", "open_config:os_open", .config },
        .{ "Reload Configuration", "reload_config", .config },
    };
    try testing.expectEqual(want.len, items.len);
    var buf: [64]u8 = undefined;
    for (want, &items, 1..) |w, *item, id| {
        try testing.expectEqualStrings(w[0], item.label);
        const name = switch (item.action) {
            .binding => |action| try std.fmt.bufPrint(&buf, "{f}", .{action}),
            .notify_next_command => @tagName(item.action),
        };
        try testing.expectEqualStrings(w[1], name);
        try testing.expectEqual(w[2], item.submenu);
        try testing.expectEqual(id, item.id);
        // Only what this runtime carries out: no window title of its own,
        // no configuration in a new window.
        const action = switch (item.action) {
            .binding => |action| action,
            .notify_next_command => continue,
        };
        try testing.expect(CommandPalette.supported(action));
        try testing.expect(action != .prompt_window_title);
        if (action == .open_config) try testing.expect(action.open_config == .os_open);
    }
}

test "win32: a context menu item shows the shortcut its action is bound to" {
    const alloc = testing.allocator;
    // A set with a binding for Split Right and Copy, and one with none.
    var bound: Binding.Set = .{};
    defer bound.deinit(alloc);
    try bound.parseAndPut(alloc, "ctrl+alt+r=new_split:right");
    try bound.parseAndPut(alloc, "ctrl+shift+c=copy_to_clipboard:mixed");
    // Another direction is another action.
    try bound.parseAndPut(alloc, "ctrl+alt+d=new_split:left");
    var none: Binding.Set = .{};
    defer none.deinit(alloc);

    const with = menuItems(.{ .selection = true }, &bound);
    try testing.expectEqualStrings("Ctrl+Alt+R", (try testItem(&with, "Split Right")).shortcut());
    try testing.expectEqualStrings("Ctrl+Shift+C", (try testItem(&with, "Copy")).shortcut());
    try testing.expectEqualStrings("Ctrl+Alt+D", (try testItem(&with, "Split Left")).shortcut());
    try testing.expectEqualStrings("", (try testItem(&with, "Split Up")).shortcut());
    try testing.expectEqualStrings("", (try testItem(&with, "Paste")).shortcut());
    const without = menuItems(.{ .selection = true }, &none);
    for (&without) |*item| try testing.expectEqualStrings("", item.shortcut());

    // As the menu shows it: after a tab.
    var text: [text_max:0]u16 = undefined;
    try testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("Split Right\tCtrl+Alt+R"),
        itemText(&text, try testItem(&with, "Split Right")),
    );
    try testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("Change Title\u{2026}"),
        itemText(&text, try testItem(&with, "Change Title\u{2026}")),
    );
}

test "win32: a context menu item's shortcut cannot underline, reorder or hide its text" {
    const alloc = testing.allocator;
    var set: Binding.Set = .{};
    defer set.deinit(alloc);
    // '&' would underline the next character; U+202E would reverse what
    // follows it; U+0085 is a C1 control. The trigger parser takes each as
    // a key.
    try set.parseAndPut(alloc, "ctrl+&=paste_from_clipboard");
    try set.parseAndPut(alloc, "ctrl+\u{202E}=clear_screen");
    try set.parseAndPut(alloc, "ctrl+\u{0085}=reset");
    try set.parseAndPut(alloc, "ctrl+\u{1F600}=new_tab");
    const items = menuItems(.{ .selection = true }, &set);
    var text: [text_max:0]u16 = undefined;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Paste\tCtrl+&&"), itemText(&text, try testItem(&items, "Paste")));
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Clear\tCtrl+U+202E"), itemText(&text, try testItem(&items, "Clear")));
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Reset\tCtrl+U+0085"), itemText(&text, try testItem(&items, "Reset")));
    // Outside the BMP, as a surrogate pair.
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("New Tab\tCtrl+\u{1F600}"), itemText(&text, try testItem(&items, "New Tab")));
}

/// For tests: the text of `menu`'s item at `pos`, or of the item with the
/// id `pos` with `by` 0 (MF_BYCOMMAND), in `buf`.
fn testText(menu: win32.HMENU, pos: win32.UINT, by: win32.UINT, buf: []u16) []const u16 {
    const n = win32.GetMenuStringW(menu, pos, buf.ptr, @intCast(buf.len), by);
    return buf[0..@intCast(@max(n, 0))];
}

test "win32: the menu Windows shows has each item's text and state, GTK's lines and its submenus" {
    const alloc = testing.allocator;
    var set: Binding.Set = .{};
    defer set.deinit(alloc);
    try set.parseAndPut(alloc, "ctrl+alt+r=new_split:right");
    var buf: [text_max]u16 = undefined;
    var want: [text_max:0]u16 = undefined;
    for ([_]bool{ false, true }) |on| {
        const items = menuItems(.{ .selection = on, .readonly = on, .notify_next_command = on }, &set);
        const menu = build(&items) orelse return error.TestUnexpectedResult;
        defer _ = win32.DestroyMenu(menu);

        // The menu itself: GTK's four sections, divided by lines.
        const top = [_]?[]const u8{ "Copy", "Paste", "Notify on Next Command Finish", null, "Clear", "Reset", "Read-only", null, "Split", "Tab", "Window", null, "Config" };
        try testing.expectEqual(@as(c_int, top.len), win32.GetMenuItemCount(menu));
        for (top, 0..) |label, i| {
            const pos: win32.UINT = @intCast(i);
            const state = win32.GetMenuState(menu, pos, win32.MF_BYPOSITION);
            const name = label orelse {
                try testing.expect(state & win32.MF_SEPARATOR != 0);
                continue;
            };
            try testing.expect(state & win32.MF_SEPARATOR == 0);
            const text = testText(menu, pos, win32.MF_BYPOSITION, &buf);
            const tab = std.mem.indexOfScalar(u16, text, '\t') orelse text.len;
            var utf8: [64]u8 = undefined;
            const n = try std.unicode.utf16LeToUtf8(&utf8, text[0..tab]);
            try testing.expectEqualStrings(name, utf8[0..n]);
            // The submenus are popups, the others not.
            try testing.expectEqual(i >= 8, win32.GetSubMenu(menu, @intCast(i)) != null);
        }

        // Each submenu holds its items in order.
        for ([_]Submenu{ .split, .tab, .window, .config }, [_]c_int{ 8, 9, 10, 12 }) |sub, pos| {
            const popup = win32.GetSubMenu(menu, pos) orelse return error.TestUnexpectedResult;
            var k: c_int = 0;
            for (&items) |*item| {
                if (item.submenu != sub) continue;
                try testing.expectEqual(@as(win32.UINT, item.id), win32.GetMenuItemID(popup, k));
                k += 1;
            }
            try testing.expectEqual(k, win32.GetMenuItemCount(popup));
        }

        // Every item, wherever it is, by its id: its text, greyed if not
        // enabled, checked if checked.
        for (&items) |*item| {
            const state = win32.GetMenuState(menu, item.id, 0);
            try testing.expect(state != std.math.maxInt(win32.UINT));
            try testing.expectEqual(!item.enabled, state & win32.MF_GRAYED != 0);
            try testing.expectEqual(item.checked, state & win32.MF_CHECKED != 0);
            try testing.expectEqualSlices(u16, itemText(&want, item), testText(menu, item.id, 0, &buf));
        }
        const copy = win32.GetMenuState(menu, (try testItem(&items, "Copy")).id, 0);
        try testing.expectEqual(!on, copy & win32.MF_GRAYED != 0);
        const readonly = win32.GetMenuState(menu, (try testItem(&items, "Read-only")).id, 0);
        try testing.expectEqual(on, readonly & win32.MF_CHECKED != 0);
        const notify = win32.GetMenuState(menu, (try testItem(&items, "Notify on Next Command Finish")).id, 0);
        try testing.expectEqual(on, notify & win32.MF_CHECKED != 0);
    }
}

test "win32: a context menu Windows cannot make leaves no menu behind" {
    // Every call that makes the menu or puts an item in it fails in turn;
    // whatever was made before it is destroyed, the submenu not yet the
    // menu's as well (`fill`), as the process's count of USER objects,
    // menus among them, shows.
    var set: Binding.Set = .{};
    defer set.deinit(testing.allocator);
    const items = menuItems(.{ .selection = true }, &set);
    defer test_calls_left = null;
    test_calls_left = 1000;
    const whole = build(&items) orelse return error.TestUnexpectedResult;
    _ = win32.DestroyMenu(whole);
    const calls = 1000 - test_calls_left.?;
    // A menu, four submenus, thirteen entries in the menu and thirteen in
    // the submenus.
    try testing.expectEqual(31, calls);
    const before = win32.GetGuiResources(win32.current_process, win32.GR_USEROBJECTS);
    for (0..calls) |n| {
        test_calls_left = n;
        try testing.expect(build(&items) == null);
        try testing.expectEqual(before, win32.GetGuiResources(win32.current_process, win32.GR_USEROBJECTS));
    }
}
