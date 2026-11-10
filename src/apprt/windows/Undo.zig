//! Closes that `undo` takes back, as macOS keeps a closed split or tab
//! for `undo-timeout`: a terminal that closes while another of its tab
//! stays is parked instead of torn down, hidden and in no tab's tree but
//! with its core running, and an entry here remembers the tree it left;
//! a tab that closes while another of its window stays is parked whole,
//! out of the window's tabs with its terminals hidden, and its entry
//! owns it. `undo` puts the tree or the tab back; the entry's time
//! running out posts the teardowns the close would have run. `redo`
//! closes again what `undo` last brought back.
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

/// What `undo` brought back and `redo` closes again, the last one last.
/// Emptied by any close that is not a redo's.
redos: std.ArrayList(Redo) = .empty,

/// The last number given to closes made as one (`newGroup`).
groups: u64 = 0,

/// Set while `redo` closes, so that its closes keep `redos`.
redoing: bool = false,

/// For tests: the time `now` gives, in place of the tick count.
pub var test_now: if (builtin.is_test) ?u64 else void =
    if (builtin.is_test) null else {};

pub const Entry = struct {
    window: *Window,
    what: What,
    /// When it is torn down for good, as `now` counts.
    expires: u64,
    /// Closes made as one, which one `undo` takes back together, share a
    /// number that is not zero (`newGroup`).
    group: u64,
    /// The scale its terminals were last told, which the frame's may no
    /// longer be: a parked terminal is not told of a change.
    dpi: u32,

    const What = union(enum) {
        /// A terminal that left `tab`, which stays in the window.
        pane: struct {
            tab: *Window.Tab,
            /// The tab's tree as it was with the terminal in it. Owned.
            tree: Window.Tree,
            surface: *Surface,
        },
        /// A tab that left the window, with every terminal of its tree
        /// parked. Owned.
        tab: struct {
            tab: *Window.Tab,
            /// Where it was among the window's tabs.
            index: usize,
        },
    };

    /// Whether the terminal of `core_surface` is parked by this entry.
    fn holds(self: *const Entry, core_surface: *const CoreSurface) bool {
        switch (self.what) {
            .pane => |pane| return &pane.surface.core_surface == core_surface,
            .tab => |parked| {
                var it = parked.tab.tree.iterator();
                while (it.next()) |leaf| {
                    if (&leaf.view.core_surface == core_surface) return true;
                }
                return false;
            },
        }
    }
};

/// What `undo` brought back. It owns nothing, and goes before what it
/// names does.
pub const Redo = struct {
    window: *Window,
    what: union(enum) { pane: *Surface, tab: *Window.Tab },
    expires: u64,
    group: u64,
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

/// A number for closes about to be made as one (`Entry.group`).
pub fn newGroup(self: *Undo) u64 {
    self.groups += 1;
    return self.groups;
}

/// Take `config`'s word on whether closes park and for how long. What is
/// parked is torn down: its terminals were told nothing of what changed
/// while they were out of every tab (the scroll bar's style among it), and
/// with `undo` unbound nothing could bring them back.
pub fn configure(self: *Undo, app: *App, config: *const configpkg.Config) void {
    self.enabled = reachable(config);
    self.timeout = config.@"undo-timeout".duration / std.time.ns_per_ms;
    while (self.entries.items.len > 0) self.expire(app, self.entries.items.len - 1);
    self.redos.clearRetainingCapacity();
    self.arm(app);
}

/// Free the lists. Their entries' terminals went with their windows.
pub fn deinit(self: *Undo, app: *App) void {
    const alloc = app.core_app.alloc;
    _ = win32.KillTimer(app.msg_hwnd, timer_id);
    for (self.entries.items) |*entry| free(alloc, entry);
    self.entries.deinit(alloc);
    self.redos.deinit(alloc);
    self.* = .{};
}

/// Free what `entry` owns. Its terminals are not touched.
fn free(alloc: std.mem.Allocator, entry: *Entry) void {
    switch (entry.what) {
        .pane => |*pane| pane.tree.deinit(),
        .tab => |parked| Window.freeTab(alloc, parked.tab),
    }
}

/// Whether a close in `window` that `surface`'s teardown carries out, of
/// that terminal or of its tab, is parked rather than torn down; room
/// for its entry is then made, so that `pushPane` and `pushTab` cannot
/// fail. Not in the quick terminal, which hides whole: what is parked in
/// it would come back into a window nobody sees. Not for a terminal
/// whose core is already stopping.
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
    self.push(app, window, 0, .{ .pane = .{ .tab = tab, .tree = tree, .surface = surface } });
}

/// Remember `tab`, its terminals parked, as having left `window`, where
/// it was the tab at `index`. The tab is this entry's now. After `parks`.
pub fn pushTab(self: *Undo, app: *App, window: *Window, tab: *Window.Tab, index: usize) void {
    self.push(app, window, tab.group, .{ .tab = .{ .tab = tab, .index = index } });
}

fn push(self: *Undo, app: *App, window: *Window, group: u64, what: Entry.What) void {
    self.expireDue(app);
    self.entries.appendAssumeCapacity(.{
        .window = window,
        .what = what,
        .expires = now() +| self.timeout,
        .group = group,
        .dpi = Window.dpiOf(app, window.hwnd),
    });
    // A new close is a new history: what was undone before it is not
    // closed again after it.
    if (!self.redoing) self.redos.clearRetainingCapacity();
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

/// End the entry at `index`: it is taken out, and its terminals'
/// teardowns posted, as its close would have posted them. Only posted,
/// so this is safe in any message loop; each teardown waits its turn
/// (`Surface.destroyPosted`). A tab's entry takes with it those of the
/// terminals closed in the tab before it, which lie under it.
fn expire(self: *Undo, app: *App, index: usize) void {
    var entry = self.entries.orderedRemove(index);
    self.end(app, &entry, null);
}

/// `expire`, for an entry already taken out. `freed`, if any, is a
/// terminal of its that is being freed now, and is left alone.
fn end(self: *Undo, app: *App, entry: *Entry, freed: ?*const Surface) void {
    switch (entry.what) {
        .pane => |pane| if (pane.surface != freed) unpark(pane.surface),
        .tab => |parked| {
            self.forgetTab(app, parked.tab);
            var it = parked.tab.tree.iterator();
            while (it.next()) |leaf| {
                if (leaf.view != freed) unpark(leaf.view);
            }
        },
    }
    free(app.core_app.alloc, entry);
}

/// Post the teardown of `surface`, parked until now. `closing` is still
/// set from its close. Should the post fail, the teardown is left as one
/// deferred, which the app posts again until it is posted
/// (`App.repostDeferredDestroys`): nothing else would ever end a hidden
/// terminal that no entry names.
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
    // From the start again after each: a tab's entry takes others with it.
    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (self.entries.items[i].expires <= t) {
            self.expire(app, i);
            i = 0;
        } else i += 1;
    }
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
        free(app.core_app.alloc, &entry);
    }
    i = 0;
    while (i < self.redos.items.len) {
        if (self.redos.items[i].window == window) _ = self.redos.orderedRemove(i) else i += 1;
    }
    if (self.entries.items.len != held) self.arm(app);
}

/// `tab` is leaving its window, freed or moved to another: the terminals
/// parked out of it are torn down, as nothing could put them back, and
/// it is not closed again by `redo`.
pub fn forgetTab(self: *Undo, app: *App, tab: *const Window.Tab) void {
    const held = self.entries.items.len;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const of = switch (self.entries.items[i].what) {
            .pane => |pane| pane.tab == tab,
            .tab => false,
        };
        if (of) self.expire(app, i) else i += 1;
    }
    i = 0;
    while (i < self.redos.items.len) {
        const of = switch (self.redos.items[i].what) {
            .pane => false,
            .tab => |t| t == tab,
        };
        if (of) _ = self.redos.orderedRemove(i) else i += 1;
    }
    if (self.entries.items.len != held) self.arm(app);
}

/// `surface` is being freed. An entry whose tree holds it ends: the tree
/// could not be put back, and must not be compared with terminals made
/// later, one of which may get the freed one's address. An entry that
/// parked the terminal itself ends too; none should be left by now.
pub fn forgetSurface(self: *Undo, app: *App, surface: *const Surface) void {
    const held = self.entries.items.len;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const entry = &self.entries.items[i];
        const tree = switch (entry.what) {
            .pane => |*pane| &pane.tree,
            .tab => |parked| &parked.tab.tree,
        };
        if (tree.locate(surface) == null) {
            i += 1;
            continue;
        }
        if (surface.parked) log.warn("a parked terminal was freed with its undo entry still held", .{});
        var gone = self.entries.orderedRemove(i);
        self.end(app, &gone, surface);
        // A tab's entry took others with it.
        i = 0;
    }
    i = 0;
    while (i < self.redos.items.len) {
        const of = switch (self.redos.items[i].what) {
            .pane => |s| s == surface,
            .tab => false,
        };
        if (of) _ = self.redos.orderedRemove(i) else i += 1;
    }
    if (self.entries.items.len != held) self.arm(app);
}

/// Whether the terminal of `core_surface` is parked here. By address
/// alone: asked of every action's target, some of which are no terminal
/// of this runtime's making.
pub fn holds(self: *const Undo, core_surface: *const CoreSurface) bool {
    for (self.entries.items) |*entry| {
        if (entry.holds(core_surface)) return true;
    }
    return false;
}

/// Whether `undo` now has a close to take back: the last one, if its time
/// is not up. Changes nothing.
pub fn pending(self: *const Undo) bool {
    const entries = self.entries.items;
    return entries.len > 0 and entries[entries.len - 1].expires > now();
}

/// Whether `redo` now has something to close again. Changes nothing.
pub fn pendingRedo(self: *const Undo) bool {
    const redos = self.redos.items;
    return redos.len > 0 and redos[redos.len - 1].expires > now();
}

/// Take the last close back, and with it those made as one with it: a
/// terminal returns to its tab, where and as large as it was, with the
/// focus; a tab returns to its place among the window's tabs, shown if
/// it alone comes back; and the window comes forward. Returns whether
/// anything came back. A close that cannot be taken back, because its
/// tab's terminals are no longer the ones it left, is torn down instead.
/// Run where a window may be laid out and the focus moved (`App.run`).
pub fn undo(self: *Undo, app: *App) bool {
    self.expireDue(app);
    var entry = self.entries.pop() orelse return false;
    const group = entry.group;
    const window = entry.window;
    // The tab the user is in stays the one shown when several come back.
    const shown = window.tab();
    var count: usize = 0;
    var back: usize = 0;
    while (true) {
        count += 1;
        if (self.restore(app, &entry)) back += 1;
        if (group == 0) break;
        const entries = self.entries.items;
        if (entries.len == 0 or entries[entries.len - 1].group != group) break;
        entry = self.entries.pop().?;
    }
    self.arm(app);
    if (back == 0) return false;
    if (count > 1) if (window.tabIndex(shown)) |index| window.selectTab(index);
    _ = window.present();
    return true;
}

/// Put back what `entry`, already taken out of the list, holds, or end
/// it. Returns whether it came back.
fn restore(self: *Undo, app: *App, entry: *Entry) bool {
    const alloc = app.core_app.alloc;
    const window = entry.window;
    const dpi = Window.dpiOf(app, window.hwnd);
    const expires = now() +| self.timeout;
    switch (entry.what) {
        .pane => |*pane| {
            const surface = pane.surface;
            if (window.closing or window.tabIndex(pane.tab) == null or !fits(&pane.tree, &pane.tab.tree, surface)) {
                log.warn("a closed terminal's tab has changed since; it cannot be put back", .{});
                self.end(app, entry, null);
                return false;
            }
            surface.parked = false;
            surface.closing = false;
            // The tab has the tree from here on.
            window.setTree(pane.tab, pane.tree);
            if (dpi != entry.dpi) surface.scaleChanged(@intCast(dpi));
            if (pane.tab == window.tab()) {
                window.showPane(surface);
            } else {
                pane.tab.focused = surface;
            }
            self.redos.append(alloc, .{
                .window = window,
                .what = .{ .pane = surface },
                .expires = expires,
                .group = entry.group,
            }) catch {};
            return true;
        },
        .tab => |parked| {
            const tab = parked.tab;
            if (window.closing) {
                self.end(app, entry, null);
                return false;
            }
            window.tabs.ensureUnusedCapacity(alloc, 1) catch |err| {
                log.warn("a closed tab cannot be put back err={}", .{err});
                self.end(app, entry, null);
                return false;
            };
            tab.closing = false;
            tab.group = 0;
            var it = tab.tree.iterator();
            while (it.next()) |leaf| {
                leaf.view.parked = false;
                leaf.view.closing = false;
                if (dpi != entry.dpi) leaf.view.scaleChanged(@intCast(dpi));
            }
            // The window has the tab from here on.
            window.relinkTab(tab, parked.index);
            self.redos.append(alloc, .{
                .window = window,
                .what = .{ .tab = tab },
                .expires = expires,
                .group = entry.group,
            }) catch {};
            return true;
        },
    }
}

/// Close again what `undo` last brought back, and what came back as one
/// with it, without asking: the user closed it once already. Each is
/// parked again, for `undo`. Returns whether anything closed. One that
/// has changed too much since is left as it is: a terminal that is now
/// its tab's only one, a tab that is now its window's only one.
pub fn redo(self: *Undo, app: *App) bool {
    var item = self.redos.pop() orelse return false;
    if (item.expires <= now()) {
        // Those under it are older still.
        self.redos.clearRetainingCapacity();
        return false;
    }
    self.redoing = true;
    defer self.redoing = false;
    const group = item.group;
    var closed = false;
    while (true) {
        if (self.close(app, item)) closed = true;
        if (group == 0) break;
        const redos = self.redos.items;
        if (redos.len == 0 or redos[redos.len - 1].group != group) break;
        item = self.redos.pop().?;
    }
    return closed;
}

fn close(self: *Undo, app: *App, item: Redo) bool {
    const window = item.window;
    switch (item.what) {
        .pane => |surface| {
            const at = window.find(surface) orelse return false;
            if (at.handle == .root or surface.closing) return false;
            if (!self.parks(app, window, surface)) return false;
            const t = window.tabs.items[at.index];
            const left = window.takePane(t, at.handle) catch |err| {
                log.warn("a terminal cannot be closed again err={}", .{err});
                return false;
            };
            surface.closing = true;
            surface.park();
            self.pushPane(app, window, t, left, surface);
            return true;
        },
        .tab => |tab| {
            if (window.tabIndex(tab) == null or window.tabs.items.len < 2) return false;
            const first = tab.focused orelse return false;
            if (!self.parks(app, window, first)) return false;
            tab.closing = true;
            tab.group = item.group;
            window.parkTab(tab);
            return true;
        },
    }
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
