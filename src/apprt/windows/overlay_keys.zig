//! Keys typed into an overlay's field, as the search bar's: which of the
//! terminal's bindings still act while the field has the keyboard focus.
//!
//! GTK's overlays keep the window's accelerators working while their entry
//! has the focus; the entry takes everything else. Here the field's own
//! keys come first: Escape, Enter, Tab and Ctrl+Backspace as the search
//! bar's subclass takes them (`SearchBar.editKey`), the editing keys
//! (`fieldOwns`) and anything that types a character. Any other press is
//! looked up as the terminal's key path would look it up, in the
//! terminal's root binding set (the set `CoreSurface.keyEventIsBinding`
//! reads), and the binding is performed only if every action in it is on
//! the allow-list (`route`): actions of the app, the window, its tabs and
//! splits, the search actions, the command palette, the terminal's title,
//! and the rest of GTK's window accelerators, reset and clear.
//! Three act on the field instead of the terminal behind it: copy, paste
//! and select all. A key whose binding is not allowed, or that has none,
//! is the field's: typed into it or ignored by it. Nothing typed in the
//! field reaches the terminal's pty.
//!
//! Leader sequences and key tables are not started from a field: a key
//! that leads a sequence, or that only a key table binds, is the field's,
//! and a sequence or table already active in the terminal is not consulted.
//! This is a known limit: a field would need the sequence and table state
//! the core keeps for the terminal's own key path.

const std = @import("std");
const builtin = @import("builtin");

const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const SearchBar = @import("SearchBar.zig");
const currentMods = @import("key.zig").currentMods;
const keyAction = @import("key.zig").keyAction;
const scanCode = @import("key.zig").scanCode;
const keyFromScan = @import("key.zig").keyFromScan;
const numpadKey = @import("key.zig").numpadKey;
const unshiftedCodepoint = @import("key.zig").unshiftedCodepoint;

const Binding = input.Binding;
const log = std.log.scoped(.win32);

/// Where an action of a binding performed from a field goes.
pub const Route = enum {
    /// To the terminal's core (`performBindingAction`).
    core,
    /// Onto the field: WM_COPY, WM_PASTE, EM_SETSEL 0,-1.
    copy,
    paste,
    select_all,
    /// Nowhere: a binding with such an action is not performed, and its
    /// key is the field's.
    field,
};

/// The allow-list. An exhaustive switch, as `actionCommands` in
/// src/input/command.zig is, so that a new action does not compile until
/// it is given a route here.
pub fn route(key: Binding.Action.Key) Route {
    return switch (key) {
        // The app's.
        .new_window,
        .open_config,
        .reload_config,
        .close_all_windows,
        .quit,
        .toggle_quick_terminal,
        .toggle_visibility,
        .check_for_updates,
        .show_gtk_inspector,
        .undo,
        .redo,
        // The window's.
        .close_window,
        .goto_window,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_background_opacity,
        .reset_window_size,
        .prompt_window_title,
        .set_window_title,
        // Its tabs'.
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .close_tab,
        .prompt_tab_title,
        .set_tab_title,
        // Its splits'; closing the terminal is closing its split.
        .new_split,
        .goto_split,
        .toggle_split_zoom,
        .resize_split,
        .equalize_splits,
        .close_surface,
        // Search: `search:<text>` is not here, as the field's text is the
        // search.
        .start_search,
        .navigate_search,
        .search_selection,
        .end_search,
        // The palette, and the terminal's title, which titles its tab and
        // window as `set_tab_title` does, and writes nothing to the pty.
        .toggle_command_palette,
        .prompt_surface_title,
        .set_surface_title,
        // GTK's window accelerators, so they act from its overlays' entries
        // too (`syncActionAccelerators` in
        // src/apprt/gtk/class/application.zig): they reset or clear the
        // terminal behind the field, and take no input from it.
        .reset,
        .clear_screen,
        => .core,

        .copy_to_clipboard => .copy,
        .paste_from_clipboard => .paste,
        .select_all => .select_all,

        // Everything else that acts on the terminal behind the field,
        // writes to its pty, or starts a key table; and `ignore`, which
        // would make a key the field takes dead.
        .ignore,
        .unbind,
        .csi,
        .esc,
        .text,
        .cursor_key,
        .paste_from_selection,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
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
        .write_scrollback_file,
        .write_screen_file,
        .write_selection_file,
        .toggle_readonly,
        // GTK's accelerators have it, but this runtime has no inspector to
        // open (`App.performAction` does not handle the apprt's
        // `inspector`), so the key stays the field's.
        .inspector,
        .show_on_screen_keyboard,
        .toggle_secure_input,
        .toggle_mouse_reporting,
        .end_key_sequence,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .crash,
        => .field,
    };
}

/// Whether a key press in a field is the field's own, before any binding
/// is looked up: one that types a character (`typed`: it queued a
/// printable WM_CHAR, or a dead key's WM_DEADCHAR), a modifier, an IME's
/// key, injected text, and the keys a single-line EDIT edits with: Tab
/// and Shift+Tab (swallowed: no dialog manager moves the focus),
/// Backspace, Delete, Insert, Left, Right, Home and End with any of Shift
/// and Ctrl, and Ctrl+A, C, V, X and Z. With Alt or the Windows key held,
/// only modifiers, IME keys and text are.
pub fn fieldOwns(vk: win32.UINT, mods: input.Mods, typed: bool) bool {
    if (typed) return true;
    switch (vk) {
        0x10...0x12, // Shift, Ctrl, Alt
        0xA0...0xA5, // their left and right keys
        0x5B,
        0x5C, // the Windows keys
        0x14,
        0x90,
        0x91, // Caps Lock, Num Lock, Scroll Lock
        0xE5, // VK_PROCESSKEY: the IME has the key
        0xE7, // VK_PACKET: injected text
        => return true,
        else => {},
    }
    if (mods.alt or mods.super) return false;
    return switch (vk) {
        0x09 => !mods.ctrl, // Tab
        0x08, // Backspace
        0x2E, // Delete
        0x2D, // Insert
        0x25,
        0x27, // Left, Right
        0x24,
        0x23, // Home, End
        => true,
        'A', 'C', 'V', 'X', 'Z' => mods.ctrl and !mods.shift,
        else => false,
    };
}

/// What a binding found for a field's key did.
const Outcome = enum {
    /// Performed, or recorded to be (`App.requests`).
    done,
    /// Performed, and the key goes on to the field too: an `unconsumed:`
    /// binding, or a `performable:` one none of whose actions could act,
    /// as the core then acts as though the binding did not exist.
    done_and_field,
};

/// A key press (WM_KEYDOWN, WM_SYSKEYDOWN) in the field `edit` of an
/// overlay of `surface`, whose own keys the caller has handled. True if
/// it was handled here: a binding was performed, or recorded; the key's
/// queued characters were then taken from the queue, so that the EDIT
/// does not act on them too (Ctrl+Shift+V's U+0016 would paste a second
/// time), and given back to it after the key if the key goes on to it.
/// `proc` is the EDIT's own procedure.
pub fn keyDown(
    surface: *Surface,
    edit: win32.HWND,
    proc: win32.WNDPROC,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) bool {
    if (msg != win32.WM_KEYDOWN and msg != win32.WM_SYSKEYDOWN) return false;
    const vk: win32.UINT = @truncate(wparam);
    const mods = currentMods();
    const queued = Queued.peek(edit);
    if (fieldOwns(vk, mods, queued.typed)) return false;

    const scan = scanCode(vk, lparam);
    const key = numpadKey(keyFromScan(scan), vk);
    if (key.modifier()) return false;
    var buf: [4]u8 = undefined;
    const event: input.KeyEvent = .{
        .action = keyAction(msg, lparam),
        .key = key,
        .mods = mods,
        .unshifted_codepoint = unshiftedCodepoint(vk, scan),
        .utf8 = queued.utf8(&buf),
    };
    const set = bindingsOf(surface) orelse return false;
    const entry = set.lookup(event) orelse return false;
    const leaf: Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        .leader => return false,
        inline .leaf, .leaf_chained => |*v| v.generic(),
    };
    if (!allowed(&leaf)) return false;

    var taken: Queued.Taken = .{};
    taken.take(edit);
    switch (perform(surface, edit, entry.key_ptr.*, &leaf, .now)) {
        .done => {},
        .done_and_field => {
            _ = win32.CallWindowProcW(proc, edit, msg, wparam, lparam);
            taken.give(edit);
        },
    }
    // A focus move the binding chose (start_search's field, goto_split),
    // now that the core has returned, as after the terminal's own keys.
    surface.app.applyPendingFocus();
    return true;
}

/// A binding a field's key found while the core could not be re-entered,
/// recorded in `App.requests` by its trigger and carried out by `run`: it
/// is looked up again, so a reload in between gives the binding the
/// configuration now has, and performed if it is still allowed. Copy,
/// paste and select all act on `from`'s search field if it still has one.
pub fn replay(from: *CoreSurface, trigger: Binding.Trigger) void {
    const surface = from.rt_surface;
    const set = bindingsOf(surface) orelse return;
    const entry = set.set.get(trigger) orelse return;
    const leaf: Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        .leader => return,
        inline .leaf, .leaf_chained => |*v| v.generic(),
    };
    if (!allowed(&leaf)) return;
    _ = perform(surface, surface.search_bar.edit, trigger, &leaf, .replay);
    surface.app.applyPendingFocus();
}

/// Whether every action of `leaf` may be performed from a field. An `all:`
/// or `global:` binding, performed on every terminal, only with actions
/// for the core: the field it would copy into is this terminal's alone.
fn allowed(leaf: *const Binding.Set.GenericLeaf) bool {
    const actions = leaf.actionsSlice();
    if (actions.len == 0) return false;
    const everywhere = leaf.flags.all or leaf.flags.global;
    for (actions) |action| switch (route(action)) {
        .field => return false,
        .core => {},
        .copy, .paste, .select_all => if (everywhere) return false,
    };
    return true;
}

/// Perform an allowed binding found by `trigger`, as the core's
/// `maybeHandleBinding` does, from a field `edit` (null if it has gone).
/// A binding with an action for the core is recorded instead while the
/// core may not be re-entered, as under a prompt, as `Window.clickTab`
/// records a tab (`.now`; a replay runs where it may), and as the search
/// bar records its own Enter, Escape and buttons (`SearchBar.record`).
fn perform(
    surface: *Surface,
    edit: ?win32.HWND,
    trigger: Binding.Trigger,
    leaf: *const Binding.Set.GenericLeaf,
    when: enum { now, replay },
) Outcome {
    const app = surface.app;
    const actions = leaf.actionsSlice();
    const any_core = for (actions) |action| {
        if (route(action) == .core) break true;
    } else false;

    if (any_core and when == .now and !app.canReenterCore()) {
        // Every surface a request names is live (`App.requests`).
        const core = coreOf(surface) orelse return .done;
        app.requests.append(app.core_app.alloc, .{ .overlay_key = .{
            .from = core,
            .trigger = trigger,
        } }) catch |err| {
            log.warn("cannot record a binding from a search field err={}", .{err});
            return .done;
        };
        app.wakeup();
        return .done;
    }

    var performed = false;
    if (leaf.flags.all or leaf.flags.global) {
        performAll(surface, actions);
        performed = true;
    } else for (actions) |action| {
        // Each, as the core does: performed if any is.
        const on_field: win32.UINT = switch (route(action)) {
            .core => {
                if (SearchBar.perform(surface, action)) performed = true;
                continue;
            },
            .copy => win32.WM_COPY,
            .paste => win32.WM_PASTE,
            .select_all => win32.EM_SETSEL,
            .field => unreachable,
        };
        const e = edit orelse continue;
        // EM_SETSEL 0,-1 selects everything; the others take no arguments.
        const lparam: win32.LPARAM = if (on_field == win32.EM_SETSEL) -1 else 0;
        _ = win32.SendMessageW(e, on_field, 0, lparam);
        performed = true;
    }
    if (leaf.flags.performable and !performed) return .done_and_field;
    // The core consumes an `all:` or `global:` binding's key whatever its
    // `unconsumed:` says (`maybeHandleBinding`).
    if (!leaf.flags.consumed and !(leaf.flags.all or leaf.flags.global)) return .done_and_field;
    return .done;
}

/// An `all:` or `global:` binding: on every terminal, as the core performs
/// it (`CoreApp.performAllChainedAction`).
fn performAll(surface: *Surface, actions: []const Binding.Action) void {
    if (builtin.is_test) if (SearchBar.test_perform) |seen| {
        for (actions) |action| _ = seen(surface, action);
        return;
    };
    const core = surface.liveCore() orelse return;
    core.app.performAllChainedAction(core.rt_app, actions);
}

/// The surface a request names: the live core surface. A test's terminal
/// has none, and stands for its own.
pub fn coreOf(surface: *Surface) ?*CoreSurface {
    if (surface.liveCore()) |core| return core;
    if (builtin.is_test) return &surface.core_surface;
    return null;
}

/// The terminal's root binding set and its key remaps, which
/// `CoreSurface.keyEventIsBinding` reads. A test's terminal has no core,
/// and has the app's configuration's.
const Bindings = struct {
    set: *const Binding.Set,
    remaps: *const input.KeyRemapSet,

    /// The binding `event` triggers, as `keyEventIsBinding` finds it,
    /// with remapped modifiers, but in the root set only.
    fn lookup(self: Bindings, event_orig: input.KeyEvent) ?Binding.Set.Entry {
        var event = event_orig;
        if (self.remaps.isRemapped(event.mods)) event.mods = self.remaps.apply(event.mods);
        return self.set.getEvent(event);
    }
};

fn bindingsOf(surface: *Surface) ?Bindings {
    if (surface.liveCore()) |core| return .{
        .set = &core.config.keybind.set,
        .remaps = &core.config.key_remaps,
    };
    if (builtin.is_test) return .{
        .set = &surface.app.config.keybind.set,
        .remaps = &surface.app.config.@"key-remap",
    };
    return null;
}

/// The characters TranslateMessage queued for the key press being
/// handled, which it posts before the press is dispatched.
const Queued = struct {
    /// The press types a character: it queued a printable WM_CHAR or a
    /// WM_DEADCHAR. A control character (Ctrl+letter's) or a WM_SYSCHAR
    /// (Alt+letter's) types nothing in an EDIT.
    typed: bool = false,
    /// The first unit of a WM_SYSCHAR, which the terminal's key path gives
    /// the core as the key's text (`Surface.Text`), if printable.
    sys_unit: ?u16 = null,

    /// Look, leaving the queue as it is: the first of each kind.
    fn peek(edit: win32.HWND) Queued {
        var q: Queued = .{};
        var m: win32.MSG = undefined;
        if (win32.PeekMessageW(&m, edit, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_NOREMOVE).toBool()) {
            q.typed = m.message == win32.WM_DEADCHAR or printable(@truncate(m.wParam));
        }
        if (win32.PeekMessageW(&m, edit, win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR, win32.PM_NOREMOVE).toBool()) {
            const unit: u16 = @truncate(m.wParam);
            if (printable(unit) and !std.unicode.utf16IsHighSurrogate(unit) and !std.unicode.utf16IsLowSurrogate(unit)) {
                q.sys_unit = unit;
            }
        }
        return q;
    }

    /// The key's text for the binding lookup, as the terminal's key path
    /// gives it, control characters dropped.
    fn utf8(self: Queued, buf: *[4]u8) []const u8 {
        const unit = self.sys_unit orelse return "";
        const n = std.unicode.utf8Encode(unit, buf) catch return "";
        return buf[0..n];
    }

    fn printable(unit: u16) bool {
        return unit >= 0x20 and unit != 0x7F;
    }

    /// Characters taken from the queue, to be given back.
    const Taken = struct {
        msgs: [8]win32.MSG = undefined,
        len: usize = 0,

        /// Take every queued character message for `edit`, in two peeks
        /// as `Surface.Text.collect` does: one over 0x0102-0x0107 would
        /// take WM_SYSKEYDOWN and WM_SYSKEYUP too. Those past the buffer
        /// are dropped.
        fn take(self: *Taken, edit: win32.HWND) void {
            const ranges = [_][2]win32.UINT{
                .{ win32.WM_CHAR, win32.WM_DEADCHAR },
                .{ win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR },
            };
            var m: win32.MSG = undefined;
            for (ranges) |r| {
                while (win32.PeekMessageW(&m, edit, r[0], r[1], win32.PM_REMOVE).toBool()) {
                    if (self.len == self.msgs.len) continue;
                    self.msgs[self.len] = m;
                    self.len += 1;
                }
            }
        }

        /// Give them to `edit`, through its subclass, as their dispatch
        /// after the key would have.
        fn give(self: *const Taken, edit: win32.HWND) void {
            for (self.msgs[0..self.len]) |m| _ = win32.SendMessageW(edit, m.message, m.wParam, m.lParam);
        }
    };
};

test "win32: every app-scoped action may be performed from a field" {
    // The allow-list's first rule, checked against the actions' scopes:
    // only `ignore` and `unbind`, which do nothing, are app-scoped and not
    // allowed.
    var app_scoped: usize = 0;
    inline for (@typeInfo(Binding.Action).@"union".field_names) |name| {
        const key = @field(Binding.Action.Key, name);
        const scope = comptime @unionInit(Binding.Action, name, undefined).scope();
        if (scope == .app and key != .ignore and key != .unbind) {
            try std.testing.expectEqual(Route.core, route(key));
            app_scoped += 1;
        }
    }
    // The loop saw them: quit, new_window and the rest.
    try std.testing.expect(app_scoped >= 10);
}

test "win32: a field's own keys" {
    const none: input.Mods = .{};
    const ctrl: input.Mods = .{ .ctrl = true };
    const shift: input.Mods = .{ .shift = true };
    const ctrl_shift: input.Mods = .{ .ctrl = true, .shift = true };
    const alt: input.Mods = .{ .alt = true };

    // Typing, whatever the key and the modifiers (AltGr's Ctrl+Alt too).
    try std.testing.expect(fieldOwns('T', ctrl_shift, true));
    try std.testing.expect(fieldOwns('Q', .{ .ctrl = true, .alt = true }, true));
    // Modifiers, the IME's keys and injected text.
    for ([_]win32.UINT{ 0x10, 0x11, 0x12, 0xA0, 0xA5, 0x5B, 0x5C, 0x14, 0xE5, 0xE7 }) |vk| {
        try std.testing.expect(fieldOwns(vk, alt, false));
        try std.testing.expect(fieldOwns(vk, ctrl_shift, false));
    }
    // Editing keys, with Shift and Ctrl but not with Alt.
    for ([_]win32.UINT{ 0x08, 0x2E, 0x2D, 0x25, 0x27, 0x24, 0x23 }) |vk| {
        for ([_]input.Mods{ none, ctrl, shift, ctrl_shift }) |m| try std.testing.expect(fieldOwns(vk, m, false));
        try std.testing.expect(!fieldOwns(vk, alt, false));
        try std.testing.expect(!fieldOwns(vk, .{ .super = true }, false));
    }
    // Tab and Shift+Tab, not Ctrl+Tab (next_tab by default).
    try std.testing.expect(fieldOwns(0x09, none, false));
    try std.testing.expect(fieldOwns(0x09, shift, false));
    try std.testing.expect(!fieldOwns(0x09, ctrl, false));
    try std.testing.expect(!fieldOwns(0x09, ctrl_shift, false));
    // The EDIT's Ctrl+letters, not with Shift (Ctrl+Shift+V pastes by a
    // binding, Ctrl+Shift+T opens a tab).
    for ("ACVXZ") |c| {
        try std.testing.expect(fieldOwns(c, ctrl, false));
        try std.testing.expect(!fieldOwns(c, ctrl_shift, false));
    }
    try std.testing.expect(!fieldOwns('T', ctrl_shift, false));
    try std.testing.expect(!fieldOwns('Y', ctrl, false));
    // Function keys and the rest are looked up.
    try std.testing.expect(!fieldOwns(0x7A, none, false)); // F11
    try std.testing.expect(!fieldOwns(0x22, ctrl, false)); // Page Down
    try std.testing.expect(!fieldOwns(0x73, alt, false)); // F4
}

test "win32: the allow-list's choices" {
    // A few of each kind; the switch itself is exhaustive.
    for ([_]Binding.Action.Key{ .new_tab, .next_tab, .goto_tab, .new_split, .goto_split, .close_surface, .close_window, .toggle_fullscreen, .quit, .new_window, .start_search, .navigate_search, .search_selection, .end_search, .toggle_command_palette, .prompt_surface_title, .set_surface_title, .prompt_tab_title, .prompt_window_title }) |k| {
        try std.testing.expectEqual(Route.core, route(k));
    }
    // GTK's window accelerators act from its overlays, and so from the
    // field, but the inspector, which this runtime does not have.
    try std.testing.expectEqual(Route.core, route(.reset));
    try std.testing.expectEqual(Route.core, route(.clear_screen));
    try std.testing.expectEqual(Route.field, route(.inspector));
    try std.testing.expectEqual(Route.copy, route(.copy_to_clipboard));
    try std.testing.expectEqual(Route.paste, route(.paste_from_clipboard));
    try std.testing.expectEqual(Route.select_all, route(.select_all));
    for ([_]Binding.Action.Key{ .ignore, .text, .csi, .esc, .search, .scroll_page_up, .adjust_selection, .write_screen_file, .increase_font_size, .activate_key_table, .end_key_sequence, .paste_from_selection }) |k| {
        try std.testing.expectEqual(Route.field, route(k));
    }
}
