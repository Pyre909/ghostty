//! Closes that `undo` takes back, as macOS keeps a closed split for
//! `undo-timeout`: a terminal that closes while another of its tab stays
//! is parked instead of torn down, hidden and in no tab's tree but with
//! its core running, and an entry here remembers the tree it left. `undo`
//! puts that tree back; the entry's time running out posts the teardown
//! the close would have run.
//!
//! Nothing is parked unless an `undo` binding exists and `undo-timeout`
//! is not zero (`reachable`): Windows binds none by default, and a closed
//! shell kept running that nobody can bring back is only a surprise.
//!
//! What an entry names outlives it: an entry goes before its window
//! (`dropWindow`), its tab (`forgetTab`) or any terminal of its tree
//! (`forgetSurface`) does. A parked terminal stays a child window of its
//! own frame and keeps `closing` set, so its window's end is its end too
//! (`Window.destroy`), and whatever passes over closing terminals passes
//! over it.

const Undo = @This();

const std = @import("std");
const builtin = @import("builtin");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// The timer on the app's message window that ends the entry due first.
pub const timer_id: win32.UINT_PTR = 2;

/// Whether a close parks (`reachable`), as of the configuration last
/// given (`configure`).
enabled: bool = false,

/// `undo-timeout`, in milliseconds.
timeout: u64 = 0,

/// The closes that can be taken back, the last one last.
entries: std.ArrayList(Entry) = .empty,

/// For tests: the time `now` gives, in place of the tick count.
pub var test_now: if (builtin.is_test) ?u64 else void =
    if (builtin.is_test) null else {};

pub const Entry = struct {
    window: *Window,
    /// The tab the terminal left.
    tab: *Window.Tab,
    /// The tab's tree as it was with the terminal in it. Owned.
    tree: Window.Tree,
    /// The parked terminal.
    surface: *Surface,
    /// When it is torn down for good, as `now` counts.
    expires: u64,
    /// The scale its terminal was last told, which the frame's may no
    /// longer be: a parked terminal is not told of a change.
    dpi: u32,
};

/// Whether `config` lets a close be taken back: some key performs `undo`,
/// alone, at the end of a sequence, in a chain or in a key table, and the
/// time to do it in is not zero.
pub fn reachable(config: *const configpkg.Config) bool {
    if (config.@"undo-timeout".duration == 0) return false;
    if (binds(&config.keybind.set)) return true;
    for (config.keybind.tables.values()) |*table| {
        if (binds(table)) return true;
    }
    return false;
}

fn binds(set: *const input.Binding.Set) bool {
    var it = set.bindings.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.*) {
        .leader => |next| if (binds(next)) return true,
        .leaf => |leaf| if (leaf.action == .undo) return true,
        .leaf_chained => |leaf| for (leaf.actions.items) |action| {
            if (action == .undo) return true;
        },
    };
    return false;
}

fn now() u64 {
    if (builtin.is_test) if (test_now) |v| return v;
    return win32.GetTickCount64();
}

/// Take `config`'s word on whether closes park and for how long. What is
/// parked is torn down: its terminals were told nothing of what changed
/// while they were out of every tab (the scroll bar's style among it), and
/// with `undo` unbound nothing could bring them back.
pub fn configure(self: *Undo, app: *App, config: *const configpkg.Config) void {
    self.enabled = reachable(config);
    self.timeout = config.@"undo-timeout".duration / std.time.ns_per_ms;
    self.expireAll(app);
}

/// Free the list. Its entries' terminals went with their windows.
pub fn deinit(self: *Undo, app: *App) void {
    _ = win32.KillTimer(app.msg_hwnd, timer_id);
    for (self.entries.items) |*entry| entry.tree.deinit();
    self.entries.deinit(app.core_app.alloc);
    self.* = .{};
}

/// Whether `surface`, about to leave `window` while other terminals of
/// its tab stay, is parked rather than torn down; room for its entry is
/// then made, so that `pushPane` cannot fail. Not in the quick terminal,
/// which hides whole: a terminal parked in it would come back into a
/// window nobody sees. Not a terminal whose core is already stopping.
pub fn parks(self: *Undo, app: *App, window: *const Window, surface: *const Surface) bool {
    if (!self.enabled or app.terminating) return false;
    if (window.closing or window.quick) return false;
    if (surface.core_state == .stopping) return false;
    self.entries.ensureUnusedCapacity(app.core_app.alloc, 1) catch |err| {
        log.warn("a closed terminal cannot be kept for undo err={}", .{err});
        return false;
    };
    return true;
}

/// Remember `surface`, parked, as having left `tab` of `window`, whose
/// tree was `tree`, now this entry's. After `parks`.
pub fn pushPane(
    self: *Undo,
    app: *App,
    window: *Window,
    tab: *Window.Tab,
    tree: Window.Tree,
    surface: *Surface,
) void {
    self.entries.appendAssumeCapacity(.{
        .window = window,
        .tab = tab,
        .tree = tree,
        .surface = surface,
        .expires = now() +| self.timeout,
        .dpi = Window.dpiOf(app, window.hwnd),
    });
    self.arm(app);
}

/// Set the timer for the entry due first, or stop it when there is none.
/// A timer that cannot be set only delays the end of what is parked to
/// the next close or `undo`, which both look at the time (`expireDue`).
fn arm(self: *Undo, app: *App) void {
    var first: ?u64 = null;
    for (self.entries.items) |entry| {
        if (first == null or entry.expires < first.?) first = entry.expires;
    }
    const due = first orelse {
        _ = win32.KillTimer(app.msg_hwnd, timer_id);
        return;
    };
    // SetTimer's bounds (USER_TIMER_MINIMUM, USER_TIMER_MAXIMUM).
    const wait = std.math.clamp(due -| now(), win32.USER_TIMER_MINIMUM, 0x7FFFFFFF);
    if (win32.SetTimer(app.msg_hwnd, timer_id, @intCast(wait), null) == 0) {
        log.warn("cannot set the undo timer err={}", .{win32.GetLastError()});
    }
}

/// End the entry at `index`: it is taken out, and its terminal's teardown
/// posted, as its close would have posted it. Only posted, so this is safe
/// in any message loop; the teardown itself waits its turn
/// (`Surface.destroyPosted`).
fn expire(self: *Undo, index: usize) void {
    var entry = self.entries.orderedRemove(index);
    entry.tree.deinit();
    unpark(entry.surface);
}

/// Post the teardown of `surface`, parked until now. `closing` is still
/// set from its close. Should the post fail, the teardown is left as one
/// deferred, which the app posts again (`App.repostDeferredDestroys`):
/// nothing else would ever end a hidden terminal that no entry names.
fn unpark(surface: *Surface) void {
    surface.parked = false;
    surface.postDestroy();
    if (!surface.closing) {
        surface.closing = true;
        surface.destroy_deferred = true;
    }
}

/// End every entry whose time is up, and set the timer for the next.
pub fn expireDue(self: *Undo, app: *App) void {
    const t = now();
    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (self.entries.items[i].expires <= t) self.expire(i) else i += 1;
    }
    self.arm(app);
}

fn expireAll(self: *Undo, app: *App) void {
    while (self.entries.items.len > 0) self.expire(self.entries.items.len - 1);
    self.arm(app);
}

/// `window`'s frame is being destroyed, and its terminals with it, the
/// parked ones too: its entries go, and nothing is posted.
pub fn dropWindow(self: *Undo, app: *App, window: *const Window) void {
    const held = self.entries.items.len;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (self.entries.items[i].window != window) {
            i += 1;
            continue;
        }
        var entry = self.entries.orderedRemove(i);
        entry.tree.deinit();
    }
    if (self.entries.items.len != held) self.arm(app);
}

/// `tab` is leaving its window, freed or moved to another: the terminals
/// parked out of it are torn down, as nothing could put them back.
pub fn forgetTab(self: *Undo, app: *App, tab: *const Window.Tab) void {
    const held = self.entries.items.len;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (self.entries.items[i].tab == tab) self.expire(i) else i += 1;
    }
    if (self.entries.items.len != held) self.arm(app);
}

/// `surface` is being freed. An entry whose tree holds it ends: the tree
/// could not be put back, and must not be compared with terminals made
/// later, one of which may get the freed one's address. An entry for the
/// terminal itself is only dropped; none should be left by now.
pub fn forgetSurface(self: *Undo, app: *App, surface: *const Surface) void {
    const held = self.entries.items.len;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const entry = &self.entries.items[i];
        if (entry.surface == surface) {
            log.warn("a parked terminal was freed with its undo entry still held", .{});
            var gone = self.entries.orderedRemove(i);
            gone.tree.deinit();
        } else if (entry.tree.locate(surface) != null) {
            self.expire(i);
        } else i += 1;
    }
    if (self.entries.items.len != held) self.arm(app);
}

/// Whether the terminal of `core_surface` is parked here. By address
/// alone: asked of every action's target, some of which are no terminal
/// of this runtime's making.
pub fn holds(self: *const Undo, core_surface: *const CoreSurface) bool {
    for (self.entries.items) |entry| {
        if (&entry.surface.core_surface == core_surface) return true;
    }
    return false;
}

/// Whether `undo` now has a close to take back: the last one, if its time
/// is not up. Changes nothing.
pub fn pending(self: *const Undo) bool {
    const entries = self.entries.items;
    return entries.len > 0 and entries[entries.len - 1].expires > now();
}

/// Take the last close back: its terminal returns to its tab, where and
/// as large as it was, with the focus, and its window comes forward.
/// Returns whether it did. A close that cannot be taken back, because its
/// tab's terminals are no longer the ones it left, is torn down instead.
/// Run where a window may be laid out and the focus moved (`App.run`).
pub fn undo(self: *Undo, app: *App) bool {
    self.expireDue(app);
    var entry = self.entries.pop() orelse return false;
    self.arm(app);

    const window = entry.window;
    const surface = entry.surface;
    if (window.closing or window.tabIndex(entry.tab) == null or !fits(&entry.tree, &entry.tab.tree, surface)) {
        log.warn("a closed terminal's tab has changed since; it cannot be put back", .{});
        entry.tree.deinit();
        unpark(surface);
        return false;
    }

    surface.parked = false;
    surface.closing = false;
    window.setTree(entry.tab, entry.tree);
    const dpi = Window.dpiOf(app, window.hwnd);
    if (dpi != entry.dpi) surface.scaleChanged(@intCast(dpi));
    if (entry.tab == window.tab()) {
        window.showPane(surface);
    } else {
        entry.tab.focused = surface;
    }
    _ = window.present();
    return true;
}

/// Whether `old`, a tab's tree when `surface` left it, can be put back
/// over `current`, the tab's tree now: the terminals of `current` are
/// those of `old` but for `surface`. A terminal split off since would be
/// in no tree afterwards, running and never shown.
fn fits(old: *const Window.Tree, current: *const Window.Tree, surface: *const Surface) bool {
    var kept: usize = 0;
    var it = old.iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) continue;
        if (current.locate(entry.view) == null) return false;
        kept += 1;
    }
    var count: usize = 0;
    var now_it = current.iterator();
    while (now_it.next()) |_| count += 1;
    return count == kept;
}

test "win32: a close is kept for undo only where a key can take it back" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { binds: []const []const u8, want: bool }{
        .{ .binds = &.{}, .want = false },
        .{ .binds = &.{"ctrl+shift+z=undo"}, .want = true },
        .{ .binds = &.{"global:ctrl+shift+z=undo"}, .want = true },
        // At the end of a sequence, which the reverse map leaves out.
        .{ .binds = &.{"ctrl+a>z=undo"}, .want = true },
        .{ .binds = &.{ "ctrl+a=copy_to_clipboard", "chain=undo" }, .want = true },
        .{ .binds = &.{"edit/z=undo"}, .want = true },
        // `redo` alone has nothing to take back.
        .{ .binds = &.{"ctrl+shift+z=redo"}, .want = false },
    };
    for (cases) |c| {
        var config: configpkg.Config = try .default(alloc);
        defer config.deinit();
        const arena = config._arena.?.allocator();
        for (c.binds) |bind| try config.keybind.parseCLI(arena, bind);
        try std.testing.expectEqual(c.want, reachable(&config));

        // With no time to do it in, never.
        config.@"undo-timeout" = .{ .duration = 0 };
        try std.testing.expect(!reachable(&config));
    }
}
