//! A terminal window: the top-level frame, and what belongs to the window
//! rather than to a terminal -- its size, caption, maximize state, the size
//! Windows suggests on a DPI change, its system modal loops. Its terminals
//! are `Surface`s, child windows the frame lays out from the split tree of
//! the tab it shows (`Tab.tree`, `layout`); `split` opens another beside
//! one.
//!
//! Ownership, as for surfaces (`App.surfaceDestroyed`): membership in
//! `App.windows` is ownership of the allocation. The frame's WM_NCDESTROY,
//! which Windows sends after its child windows are destroyed, frees a
//! window that is in the list; one that is not yet (`create` or
//! `App.moveTabToNewWindow` failing) is freed by `discard`.
//!
//! Each tab's tree holds its terminals by pointer and owns none of them. It
//! never holds a freed one: a terminal that closes on its own leaves it
//! before it is destroyed (`removePane`), and the frame's WM_DESTROY, which
//! comes before its child windows are destroyed, empties every tab's.

const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const terminal = @import("../../terminal/main.zig");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
pub const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");
const SearchBar = @import("SearchBar.zig");
const Overlays = @import("Overlays.zig");
const Dividers = @import("Dividers.zig");
const ScrollBar = @import("ScrollBar.zig");
const TitleDialog = @import("TitleDialog.zig");
const CommandPalette = @import("CommandPalette.zig");
const SplitTree = @import("../../datastruct/main.zig").SplitTree;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const WM_GHOSTTY_DESTROY = @import("App.zig").WM_GHOSTTY_DESTROY;
const postTeardown = @import("App.zig").postTeardown;
const confirm = @import("dialog.zig").confirm;

const log = std.log.scoped(.win32);

/// The frame's window class, registered in `App.init`.
pub const class_name = "GhosttyWindowClass";

/// A tab's terminals. `Surface.ref` and `Surface.unref` do
/// nothing; see the ownership note above.
pub const Tree = SplitTree(Surface);

/// What `toggleFullscreen` puts back.
pub const Restore = struct {
    /// For a maximized window, which comes back maximized with its restore
    /// rect, and for one whose rect no monitor shows any more.
    placement: win32.WINDOWPLACEMENT,

    /// For any other, which comes back where it was. A window snapped to a
    /// side of the screen is not at its placement's rect, which is where
    /// it was before the snap.
    rect: win32.RECT,
};

app: *App,

/// The frame. Written from WM_NCCREATE, the first message it receives, so
/// it is valid in every other handler.
hwnd: win32.HWND,

/// The window's tabs, in the order they show; never empty from `create`
/// until the window is freed (`deinitTabs`). Each is allocated, so that a
/// pointer to one stays put.
tabs: std.ArrayListUnmanaged(*Tab),

/// The index in `tabs` of the tab the window shows.
selected: usize,

/// The tab bar over the terminals, shown as `window-show-tab-bar` asks
/// (`barShown`).
bar: TabBar.Bar,

/// A close of the whole window is being asked about, or was agreed to and
/// its teardown posted (`requestClose`). Stops a second WM_CLOSE or
/// close_window from asking or posting twice. Cleared when the user
/// declines or the post fails; otherwise the teardown frees the window.
closing: bool,

/// WM_GHOSTTY_DESTROY arrived while teardown was not allowed; re-posted by
/// `App.repostDeferredDestroys`, as a terminal's is
/// (`Surface.destroy_deferred`).
destroy_deferred: bool,

/// Whether the title bar was last made dark (`applyTheme`). A new frame
/// has a light one.
dark_frame: bool,

/// Where and how the window was before it covered its monitor, to put it
/// back (`toggleFullscreen`); null while it does not.
fullscreen: ?Restore,

/// This window's own `window-decoration`, from
/// `toggle_window_decorations`, or null while it follows the
/// configuration's, as GTK keeps one per window (`toggleDecorations`).
decoration: ?configpkg.WindowDecoration,

/// This window's share of `App.modal_loop_depth`; see `ModalLoops`.
modal_loops: ModalLoops,

/// Explorer said the frame's taskbar button exists (`App.taskbar_created`),
/// which ITaskbarList3 asks to wait for (`showProgress`).
taskbar_button: bool,

/// Disabled by `App.beginPrompt` for a prompt in another window, or left
/// disabled by a title prompt that closed while a prompt was open
/// (`TitleDialog.close`), for `App.endPrompt` to enable again.
prompt_disabled: bool,

/// The window's title prompt, open or not (`TitleDialog`), which holds the
/// frame disabled while it is open.
title_prompt: TitleDialog.Prompt,

/// The window's command palette, open or not (`CommandPalette`).
palette: CommandPalette.Palette,

/// The divider being dragged with the pointer, from the press in its band
/// until the drag ends (`Dividers.Drag`); null without one.
divider_drag: ?Dividers.Drag,

/// While a wheel from a divider's band is being passed on to a terminal
/// (`Dividers.wheel`).
divider_wheel: bool,

/// The tab the window shows, whose terminals are laid out in its client
/// area.
pub fn tab(self: *const Window) *Tab {
    return self.tabs.items[self.selected];
}

/// A new, empty tab at the end of `tabs`.
pub fn appendTab(self: *Window, alloc: Allocator) Allocator.Error!*Tab {
    try self.tabs.ensureUnusedCapacity(alloc, 1);
    const t = try alloc.create(Tab);
    t.* = .{};
    self.tabs.appendAssumeCapacity(t);
    return t;
}

/// Free the tabs, with what their trees still hold: nothing once the
/// frame's WM_DESTROY has run.
pub fn deinitTabs(self: *Window, alloc: Allocator) void {
    for (self.tabs.items) |t| freeTab(alloc, t);
    self.tabs.deinit(alloc);
}

fn freeTab(alloc: Allocator, t: *Tab) void {
    t.tree.deinit();
    if (t.title_override) |title| alloc.free(title);
    alloc.destroy(t);
}

/// Where a terminal is: its tab's index in `tabs`, and its node in that
/// tab's tree.
pub const Place = struct {
    index: usize,
    handle: Tree.Node.Handle,
};

/// Where `surface` is, in whichever tab holds it, shown or not.
pub fn find(self: *const Window, surface: *const Surface) ?Place {
    for (self.tabs.items, 0..) |t, index| {
        if (t.tree.locate(surface)) |handle| return .{ .index = index, .handle = handle };
    }
    return null;
}

/// The tab holding `surface`, which need not be the one shown.
pub fn tabOf(self: *const Window, surface: *const Surface) ?*Tab {
    const place = self.find(surface) orelse return null;
    return self.tabs.items[place.index];
}

/// The index of `t` in `tabs`.
pub fn tabIndex(self: *const Window, t: *Tab) ?usize {
    return std.mem.indexOfScalar(*Tab, self.tabs.items, t);
}

/// What the window is titled after while `t` is shown, and its tab's
/// label: its title from `set_tab_title` or the tab's title prompt, or
/// else its focused terminal's (`Surface.effectiveTitle`), as GTK's tab
/// computes its title.
pub fn tabTitle(t: *const Tab) ?[:0]const u8 {
    if (t.title_override) |title| return title;
    const surface = t.focused orelse return null;
    return surface.effectiveTitle();
}

/// Put `surface`, a new terminal not yet shown, in a tab of its own after
/// the shown one or at the end, as `window-new-tab-position` asks; its
/// index. The tab is not shown yet (`selectTab`).
pub fn insertTab(self: *Window, surface: *Surface) !usize {
    const t = try self.tabFor(surface);
    errdefer comptime unreachable;
    const at = switch (self.app.config.@"window-new-tab-position") {
        .current => self.selected + 1,
        .end => self.tabs.items.len,
    };
    self.tabs.insertAssumeCapacity(at, t);
    self.bar.tabsChanged(self);
    return at;
}

/// A new tab holding only `surface`, focused, with room made for it in
/// `tabs`, for the caller to put there.
fn tabFor(self: *Window, surface: *Surface) Allocator.Error!*Tab {
    const alloc = self.app.core_app.alloc;
    try self.tabs.ensureUnusedCapacity(alloc, 1);
    const t = try alloc.create(Tab);
    errdefer alloc.destroy(t);
    t.* = .{ .tree = try .init(alloc, surface), .focused = surface };
    return t;
}

/// A new terminal, made with `opts` at the size of the client area, in a
/// tab of its own (`insertTab`); the tab's index. Hidden until the tab is
/// shown (`selectTab`), once the app owns the terminal (`App.newTab`).
pub fn newTab(self: *Window, opts: Surface.Options) !usize {
    const area = self.newTabArea() orelse return App.Error.Win32CallFailed;
    const surface = try Surface.create(self.app, self, area, opts);
    // Nothing owns the terminal until it is in a tab.
    errdefer surface.discard();
    return try self.insertTab(surface);
}

/// Where a new tab's terminal goes: under the bar as it will be with
/// that tab, so that its shell starts at the size it keeps.
pub fn newTabArea(self: *const Window) ?win32.RECT {
    return self.layoutAreaFor(self.tabs.items.len + 1);
}

/// Where a tab's terminals go: the client area under the bar
/// (`layoutAreaFor`).
pub fn layoutArea(self: *const Window) ?win32.RECT {
    return self.layoutAreaFor(self.tabs.items.len);
}

/// Where a tab's terminals go with `count` tabs: the client area under
/// the bar. A minimized frame has none, so then the place the shown tab's
/// terminals keep, which the frame's WM_SIZE leaves them while it is
/// minimized: a terminal made at 0x0 would start its shell on a grid of
/// one cell.
fn layoutAreaFor(self: *const Window, count: usize) ?win32.RECT {
    var client: win32.RECT = undefined;
    if (!win32.GetClientRect(self.hwnd, &client).toBool()) return null;
    if (!win32.IsIconic(self.hwnd).toBool()) {
        client.top = @min(client.bottom, client.top + self.barHeightFor(count));
        return client;
    }
    var area: ?win32.RECT = null;
    var it = self.tab().tree.iterator();
    while (it.next()) |entry| {
        var rect: win32.RECT = undefined;
        if (!win32.GetWindowRect(entry.view.hwnd, &rect).toBool() or !self.toClient(&rect)) continue;
        area = if (area) |a| .{
            .left = @min(a.left, rect.left),
            .top = @min(a.top, rect.top),
            .right = @max(a.right, rect.right),
            .bottom = @max(a.bottom, rect.bottom),
        } else rect;
    }
    return area orelse client;
}

/// Show the tab at `index` in place of the one shown, as GTK selects a
/// tab: a divider's drag in the other ends; its terminals are laid out and
/// shown, and its focused one gets the focus and titles the window; then
/// the other's are hidden, and their renderers see themselves occluded.
/// Never inside a core frame (`App.requests`): the layout sends WM_SIZE,
/// and the focus moves.
pub fn selectTab(self: *Window, index: usize) void {
    assert(index < self.tabs.items.len);
    if (index == self.selected) return;
    const old = self.tab();
    Dividers.tabChanged(self, old);
    self.selected = index;
    self.showTab();
    // A focus move a goto_split left waiting there would outlive its tab.
    old.pending_focus = null;
    hideTab(old);
    // The layout scrolled the bar to show it (`placeBar`).
    self.bar.invalidate();
}

/// Lay the shown tab out and give its focused terminal the focus.
fn showTab(self: *Window) void {
    self.relayout();
    if (self.tab().focused) |surface| self.giveFocus(surface);
}

fn hideTab(t: *Tab) void {
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        _ = win32.ShowWindow(entry.view.hwnd, win32.SW_HIDE);
        // Its search bar with it; it stays open for when the tab shows.
        // So does what its overlays show.
        entry.view.search_bar.hideWindow();
        entry.view.overlays.hideWindows();
        entry.view.occlusionChanged(false);
    }
}

/// Take `t`, whose last terminal is closing, out of the window. A shown
/// tab gives its place to the one after it, or else the one before, as a
/// browser's do.
pub fn removeTab(self: *Window, t: *Tab) void {
    const index = self.tabIndex(t) orelse return;
    // Its title prompt goes with it, before it is freed.
    TitleDialog.tabRemoved(self, t);
    // The next tab first, then the closing terminal hidden, so that it is
    // not shown, nor clicked, while its core stops (`Surface.destroy`).
    if (self.unlinkTab(index)) {
        self.showTab();
        hideTab(t);
    } else {
        // Laid out again: with one tab left the bar may go.
        self.relayout();
    }
    freeTab(self.app.core_app.alloc, t);
}

/// Take the tab at `index` out of `tabs`, for `removeTab` and `takeTab`,
/// and return whether it was the one shown, whose place then goes to the
/// tab after it, or else the one before; the caller shows that one. The
/// bar's press is cancelled, as its indexes now name other tabs, and so is
/// a divider's drag in the tab.
fn unlinkTab(self: *Window, index: usize) bool {
    assert(self.tabs.items.len > 1);
    Dividers.tabChanged(self, self.tabs.orderedRemove(index));
    const shown = index == self.selected;
    if (index < self.selected or (shown and index == self.tabs.items.len)) self.selected -= 1;
    self.bar.tabsChanged(self);
    return shown;
}

/// `move_tab_to_new_window`: move the tab at `index`, whole, into `to`, a
/// window `createBare` made and nobody has shown yet, as its only tab, as
/// GTK moves a tab's page to a new window's tab view
/// (`moveTabToNewWindow` in src/apprt/gtk/class/window.zig). The tab keeps
/// its split tree with its zoom, its focused terminal and its title from
/// `set_tab_title`; its terminals keep their windows and cores, which only
/// change frames. This window carries on as when a tab closes
/// (`removeTab`).
///
/// The one step that can fail, moving the terminals' windows to the new
/// frame, comes first and is undone if it fails, so that the tab is then
/// still here, as it was; if it cannot be undone, the move is finished
/// instead (`reparentTab`), and a terminal that still cannot go stays here
/// in a tab of its own (`keepLeftOut`). Never inside a core frame
/// (`App.requests`): it lays terminals out and moves the focus.
pub fn moveTabTo(self: *Window, index: usize, to: *Window) !Moved {
    assert(self.tabs.items.len > 1);
    const t = self.tabs.items[index];
    const moved = try reparentTab(t, to.hwnd, self.hwnd);
    errdefer comptime unreachable;
    const kept = if (moved == .after_failure) self.keepLeftOut(t, index, to.hwnd) else 0;
    to.adoptTab(self.takeTab(index), dpiOf(self.app, self.hwnd));
    // The first of them is shown in the tab's place if the tab was shown
    // (`takeTab`); the others were shown with it, and are hidden now.
    for (self.tabs.items[index..][0..kept]) |own| {
        if (own != self.tab()) hideTab(own);
    }
    const result: Moved = if (kept > 0) .split else moved;
    return result;
}

/// How `moveTabTo` moved a tab.
pub const Moved = enum {
    /// Every terminal went to the new frame.
    whole,
    /// A terminal could not go, and then one already gone could not come
    /// back, so the move was finished instead (`reparentTab`); the caller
    /// says so.
    after_failure,
    /// As `after_failure`, but a terminal could not go even then, and
    /// stayed in the old window, in a tab of its own (`keepLeftOut`); the
    /// caller says so.
    split,
};

/// Make each terminal of `t` a child window of the frame `to` in place of
/// `back`, the one they are in, so that they all end in the frame of the
/// window holding the tab. A terminal in another frame would be destroyed
/// with that frame while its tab still holds it, or else outlive its own
/// window's frame, whose destruction is what frees it
/// (`App.surfaceDestroyed`): then nothing frees it, and the app, which
/// quits once it has no terminal, never quits.
///
/// If one cannot be moved, those moved go back to `back` and the error is
/// returned: the tab stays, and `to` holds no terminal (`discard`). If
/// one of those cannot go back either, the tab cannot stay whole where it
/// was, so the move is finished instead: every terminal not in `to` yet
/// is moved there again, and `.after_failure` is returned. A terminal
/// that `to` does not take even then is still in `back`, and no single
/// frame can hold the tab: the caller takes it out of the tab, to stay
/// with `back`'s window (`keepLeftOut`). None of this is known to happen:
/// SetParent is not known to fail between live windows of one thread, and
/// a tab never holds a terminal whose window is gone (`removePane`); tests
/// make it fail (`test_set_parent`).
fn reparentTab(t: *Tab, to: win32.HWND, back: win32.HWND) !Moved {
    if (moveInto(t, to, null)) return .whole;
    if (moveInto(t, back, to)) return App.Error.Win32CallFailed;
    // A warning: the caller reports it (`App.createRequested`).
    log.warn("a terminal could not go back after a failed move to a new window: the move is finished instead", .{});
    if (!moveInto(t, to, null)) {
        log.warn("a terminal could not change frames even then: it stays in its old window", .{});
    }
    // Not known to happen, as a terminal that could not go back is still
    // in `to`; but should none be, the tab stays whole where it was, and
    // `to` holds no terminal (`discard`).
    if (!anyIn(t, to)) return App.Error.Win32CallFailed;
    return .after_failure;
}

/// The terminal of `t` not in the frame `frame`, after the first `skip`
/// of those, in the tree's order; null if there is none.
fn leftOut(t: *const Tab, frame: win32.HWND, skip: usize) ?*Surface {
    var seen: usize = 0;
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        if (win32.GetAncestor(entry.view.hwnd, win32.GA_PARENT) == frame) continue;
        if (seen == skip) return entry.view;
        seen += 1;
    }
    return null;
}

/// Whether a terminal of `t` is in the frame `frame`.
fn anyIn(t: *const Tab, frame: win32.HWND) bool {
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        if (win32.GetAncestor(entry.view.hwnd, win32.GA_PARENT) == frame) return true;
    }
    return false;
}

/// After `reparentTab` finished a move that failed, take each terminal of
/// `t`, the tab at `index`, that is still not in the frame `to` out of the
/// tab, and keep it in this window, whose frame holds it, in a tab of its
/// own after `t`; the number of those tabs. The rest of `t` then goes to
/// `to`'s window, and its terminals go with it (`adoptTab`), so that each
/// terminal belongs to the one window whose frame holds it, and closing
/// that window frees it (`destroy`): a tab in `to`'s window holding one
/// in this frame would see it freed with this frame, or a terminal of
/// this window outlive it in `to`'s.
///
/// Out of memory, a terminal that cannot have a tab of its own is closed:
/// out of every tab, in this frame and of this window, its teardown finds
/// no tab to leave (`Surface.destroy`). One that cannot even leave `t`
/// stays there, logged: then no frame holds the tab.
fn keepLeftOut(self: *Window, t: *Tab, index: usize, to: win32.HWND) usize {
    const alloc = self.app.core_app.alloc;
    var kept: usize = 0;
    var skip: usize = 0;
    while (leftOut(t, to, skip)) |surface| {
        const handle = t.tree.locate(surface).?;
        // Made before it leaves `t`, which then cannot fail.
        const own: ?*Tab = self.tabFor(surface) catch null;
        // From the tree as it is, as `removePane` picks it.
        const focus: ?*Surface = if (t.focused != surface) t.focused else focus: {
            const next = (t.tree.goto(alloc, handle, .previous) catch null) orelse
                (t.tree.goto(alloc, handle, .next) catch null) orelse
                break :focus null;
            break :focus t.tree.nodes[next.idx()].leaf;
        };
        const tree = t.tree.remove(alloc, handle) catch {
            if (own) |o| freeTab(alloc, o);
            log.err("out of memory: a terminal in its old frame stays in its tab's new window", .{});
            skip += 1;
            continue;
        };
        self.setTree(t, tree);
        t.focused = focus;
        if (own) |o| {
            self.tabs.insertAssumeCapacity(index + 1 + kept, o);
            kept += 1;
            log.warn("a terminal that could not change frames stays in its old window, in a tab of its own", .{});
        } else {
            log.err("out of memory: a terminal that could not change frames is closed", .{});
            _ = win32.ShowWindow(surface.hwnd, win32.SW_HIDE);
            surface.close(false);
        }
    }
    if (kept > 0) self.bar.tabsChanged(self);
    return kept;
}

/// Make each terminal of `t` that is not in the frame `into` yet a child
/// window of it, only those in the frame `from` if not null; whether all
/// of those are in `into` now. A failure is a warning: the caller reports
/// it (`App.createRequested`).
fn moveInto(t: *Tab, into: win32.HWND, from: ?win32.HWND) bool {
    var all = true;
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        const hwnd = entry.view.hwnd;
        const parent = win32.GetAncestor(hwnd, win32.GA_PARENT);
        if (parent == into) continue;
        if (from) |f| if (parent != f) continue;
        if (setParent(hwnd, into)) continue;
        log.warn("SetParent failed for a terminal changing frames err={}", .{win32.GetLastError()});
        all = false;
    }
    return all;
}

/// SetParent, for `moveInto`, outside tests. A test replaces it to make a
/// call fail, which the live windows of one thread are not known to do.
pub var test_set_parent: if (builtin.is_test) *const SetParentFn else void =
    if (builtin.is_test) &win32.SetParent else {};
const SetParentFn = fn (win32.HWND, ?win32.HWND) callconv(.winapi) ?win32.HWND;

fn setParent(child: win32.HWND, parent: win32.HWND) bool {
    const set: *const SetParentFn = if (builtin.is_test) test_set_parent else &win32.SetParent;
    return set(child, parent) != null;
}

/// Take the tab at `index`, whose terminals another frame holds now
/// (`moveTabTo`), out of the window, which shows the next tab in its place
/// if it was shown, as `removeTab` does, and lays itself out again: with
/// one tab left the bar may go. A focus move pending on the tab is
/// dropped, as `selectTab` drops one: it is a key's, made in this window.
fn takeTab(self: *Window, index: usize) *Tab {
    const t = self.tabs.items[index];
    if (self.unlinkTab(index)) self.showTab() else self.relayout();
    t.pending_focus = null;
    return t;
}

/// Make `t`, which another window gave up with its terminals already in
/// this frame (`moveTabTo`), this window's only tab, in place of the empty
/// one `createBare` made: its terminals point back here, take this frame's
/// scale if it is not `from_dpi`, the old frame's, as the frame's
/// WM_DPICHANGED gives it, before the layout sizes them; and the window is
/// titled after the tab, even if it is never activated, as `create` titles
/// a new window.
fn adoptTab(self: *Window, t: *Tab, from_dpi: u32) void {
    assert(self.tabs.items.len == 1 and self.tab().tree.isEmpty());
    freeTab(self.app.core_app.alloc, self.tabs.items[0]);
    self.tabs.items[0] = t;
    self.selected = 0;
    const dpi = dpiOf(self.app, self.hwnd);
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        entry.view.window = self;
        if (dpi != from_dpi) entry.view.scaleChanged(std.math.lossyCast(u16, dpi));
    }
    self.bar.tabsChanged(self);
    self.relayout();
    if (t.focused) |surface| self.setFocused(surface);
}

/// Move the tab holding `surface` by `amount`, wrapping round, as GTK
/// moves it (`Window.moveTab` in src/apprt/gtk/class/window.zig); false
/// with one tab, or when it would not move. Only the order changes: no
/// terminal is laid out again, but the bar scrolls to keep the shown tab
/// in sight.
pub fn moveTab(self: *Window, surface: *const Surface, amount: isize) bool {
    const total = self.tabs.items.len;
    if (total <= 1) return false;
    const from = (self.find(surface) orelse return false).index;
    const to: usize = @intCast(@mod(@as(isize, @intCast(from)) + amount, @as(isize, @intCast(total))));
    if (to == from) return false;
    self.reorderTab(from, to);
    self.bar.scrollToShow(self, self.selected);
    self.bar.tabsChanged(self);
    return true;
}

/// Put the tab at index `from` at index `to`, the tabs between making
/// room, the shown one still shown: only the order changes, and no
/// terminal is laid out again. For `moveTab`, and for a drag in the bar,
/// which keeps its press (`TabBar.Bar.drag`) where `moveTab` cancels it.
pub fn reorderTab(self: *Window, from: usize, to: usize) void {
    assert(from < self.tabs.items.len and to < self.tabs.items.len);
    if (from == to) return;
    const shown = self.tab();
    const t = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, t);
    self.selected = self.tabIndex(shown).?;
}

/// Where a tab dragged out of the bar was dropped (`dropTabOut`), for
/// placing the window it moves to (`placeForDrop`).
pub const Drop = struct {
    /// The pointer, in screen coordinates.
    at: win32.POINT,
    /// Where the tab's label was grabbed, from its top-left corner.
    grab: win32.POINT,
};

/// The tab at `index`, dragged out of the bar and dropped outside the
/// window, moves to a new window as `move_tab_to_new_window` moves it, as
/// GTK's tab bar lets a tab be dragged out; the new frame placed so that
/// the label is where it was dropped (`placeForDrop`). Nothing for the
/// window's only tab, nor for a window being torn down. At once whenever
/// the core may be re-entered, whichever loop dispatched the release:
/// `run`'s, a system modal loop, or the pump inside a terminal's teardown
/// (`App.moveTabOut`); else, under a prompt or a core frame, recorded for
/// `run`, naming the tab's focused terminal, which must be live, as
/// `clickTab` records a click (`App.requests`).
pub fn dropTabOut(self: *Window, index: usize, drop: Drop) void {
    if (self.closing or self.app.terminating) return;
    if (index >= self.tabs.items.len or self.tabs.items.len <= 1) return;
    const t = self.tabs.items[index];
    if (self.app.canReenterCore()) return self.app.moveTabOut(self, index, drop);
    const from = t.focused orelse return;
    if (from.closing) return;
    const core = from.liveCore() orelse return;
    self.app.requests.append(self.app.core_app.alloc, .{ .move_tab_to_new_window = .{
        .from = core,
        .drop = drop,
    } }) catch |err| {
        log.warn("cannot record a tab to move to a new window err={}", .{err});
        return;
    };
    self.app.wakeup();
}

/// Move the frame, which `createBare` made and nobody has shown yet, for
/// a tab dropped at `drop` (`dropTabOut`): the point of its client area
/// where the label was grabbed goes under the pointer, where the tab's
/// label is when the bar shows (`dropRect`), on the monitor the pointer
/// is on. Logged, and left where it is, if it cannot be.
///
/// The frame was made on whichever monitor Windows chose, at its DPI, and
/// is placed from its size and caption there. On a monitor with another
/// DPI it gets WM_DPICHANGED as it arrives, whose suggested rect, applied
/// over the placed one, is scaled and moved: the label would no longer be
/// under the pointer, nor the frame inside the work area. So once its DPI
/// has changed it is placed again, from its size and caption at the new
/// DPI.
pub fn placeForDrop(self: *Window, drop: Drop) void {
    const dpi = dpiOf(self.app, self.hwnd);
    self.placeAt(drop);
    if (dpiOf(self.app, self.hwnd) != dpi) self.placeAt(drop);
}

/// One placing of `placeForDrop`, from the frame as it is now.
fn placeAt(self: *Window, drop: Drop) void {
    var frame: win32.RECT = undefined;
    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    if (!win32.GetWindowRect(self.hwnd, &frame).toBool() or
        !win32.ClientToScreen(self.hwnd, &origin).toBool())
    {
        log.warn("unable to read the new window's frame, not placed at the drop err={}", .{win32.GetLastError()});
        return;
    }
    const monitor = monitorInfo(win32.MonitorFromPoint(drop.at, win32.MONITOR_DEFAULTTONEAREST)) orelse return;
    const rect = dropRect(frame, origin, drop, monitor.rcWork);
    if (!win32.SetWindowPos(
        self.hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    ).toBool()) {
        log.warn("unable to place the new window at the drop err={}", .{win32.GetLastError()});
    }
}

/// The rect for a frame now at `frame`, its client area's top-left corner
/// at `client` on the screen, moved so that the client point `drop.grab`
/// is at `drop.at`, then kept inside the work area `work` as
/// `constrainToWorkArea` keeps it.
pub fn dropRect(frame: win32.RECT, client: win32.POINT, drop: Drop, work: win32.RECT) win32.RECT {
    const left = drop.at.x - drop.grab.x - (client.x - frame.left);
    const top = drop.at.y - drop.grab.y - (client.y - frame.top);
    return constrainToWorkArea(left, top, frame.right - frame.left, frame.bottom - frame.top, work);
}

/// The index `goto_tab` goes to from the shown tab, as GTK selects it
/// (`Window.selectTab`): previous and next wrap round, an index counts
/// from 1 and stops at the last tab; null for 0, or for the shown tab, so
/// that the key reaches the terminal.
pub fn gotoTabIndex(self: *const Window, to: apprt.action.GotoTab) ?usize {
    const total = self.tabs.items.len;
    const current = self.selected;
    const index: usize = switch (to) {
        .previous => if (current > 0) current - 1 else total - 1,
        .next => if (current + 1 < total) current + 1 else 0,
        .last => total - 1,
        _ => n: {
            const n = @backingInt(to);
            if (n <= 0) return null;
            break :n @min(@as(usize, @intCast(n)) - 1, total - 1);
        },
    };
    return if (index == current) null else index;
}

/// `set_tab_title`, and OK in a tab's title prompt (`TitleDialog.commit`),
/// for the tab holding `surface`: `title` shows in place of its focused
/// terminal's, or an empty one ends that. False if it could not be stored.
pub fn setTabTitle(self: *Window, surface: *const Surface, title: [:0]const u8) bool {
    const alloc = self.app.core_app.alloc;
    const t = self.tabOf(surface) orelse return false;
    const copy: ?[:0]u8 = if (title.len == 0) null else alloc.dupeSentinel(u8, title, 0) catch |err| {
        log.warn("failed to store the tab title err={}", .{err});
        return false;
    };
    if (t.title_override) |old| alloc.free(old);
    t.title_override = copy;
    self.bar.invalidate();
    if (t == self.tab()) return self.showTitle(tabTitle(t));
    return true;
}

/// Create a window holding a new terminal, still hidden: `show` shows it
/// once the app owns both (`App.newWindow`). The frame is created at
/// CW_USEDEFAULT size so that the terminal, which fills it, starts with a
/// non-zero size (`CoreSurface.init` reads it).
pub fn create(app: *App, opts: Surface.Options) !*Window {
    const alloc = app.core_app.alloc;
    const self = try createBare(app);
    errdefer self.discard();

    // Under the bar, if `window-show-tab-bar = always` shows it already.
    const area = self.layoutArea() orelse return App.Error.Win32CallFailed;
    const surface = try Surface.create(app, self, area, opts);
    // Nothing owns the terminal until it is in the tree.
    self.tab().tree = Tree.init(alloc, surface) catch |err| {
        surface.discard();
        return err;
    };
    // A title the core set while it started is shown, even if the window
    // is never activated (launched minimized, or behind another).
    self.setFocused(surface);

    // The frame is still hidden, so this shows nothing yet.
    _ = win32.ShowWindow(surface.hwnd, win32.SW_SHOWNA);
    return self;
}

/// A new window, still hidden and not yet the app's, with one empty tab:
/// `create` puts a new terminal in it, `moveTabTo` a tab from another
/// window in its place. Its frame is made at CW_USEDEFAULT, with its bar
/// and its title bar's theme. Undone by `discard` until it is in
/// `App.windows`.
pub fn createBare(app: *App) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tabs = .empty,
        .selected = 0,
        .bar = .{},
        .dark_frame = false,
        .fullscreen = null,
        .decoration = null,
        .modal_loops = .{},
        .taskbar_button = false,
        .prompt_disabled = false,
        .title_prompt = .{},
        .palette = .{},
        .divider_drag = null,
        .divider_wheel = false,
        .closing = false,
        .destroy_deferred = false,
    };
    // Before the frame: its first messages read the shown tab. The
    // errdefer comes first, as the list's room outlives a failure to make
    // the tab.
    errdefer self.deinitTabs(alloc);
    _ = try self.appendTab(alloc);

    _ = try self.createFrame(
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
    );
    errdefer comptime unreachable;
    self.bar.create(self);

    // Windows announces a change of its app mode only to the top-level
    // windows there are, so one made before this frame existed is read now.
    // Then the title bar, before the frame is first shown, so that it
    // never shows the wrong one.
    app.systemSchemeChanged();
    self.applyTheme();
    return self;
}

/// Undo `createBare`: destroy the frame, which frees nothing, as the
/// window is not in `App.windows` (WM_NCDESTROY), then free the window.
/// No terminal may be in the frame, which would destroy it while a tab
/// still holds it; a failed `moveTabTo` leaves none there (`reparentTab`).
pub fn discard(self: *Window) void {
    if (std.debug.runtime_safety) for (self.app.surfaces.items) |surface| {
        assert(win32.GetAncestor(surface.hwnd, win32.GA_PARENT) != self.hwnd);
    };
    const alloc = self.app.core_app.alloc;
    _ = win32.DestroyWindow(self.hwnd);
    self.deinitTabs(alloc);
    alloc.destroy(self);
}

/// Create the hidden frame of `self` at `x`, `y`, `width` by `height`
/// (CW_USEDEFAULT for where and how large Windows makes a new window),
/// with the decorations it should have (`applyDecorations`), before
/// anything measures its client area. CreateWindowExW gives every window
/// that is neither a child nor a popup a caption, so the frame is made with
/// one, and loses it after.
pub fn createFrame(self: *Window, x: c_int, y: c_int, width: c_int, height: c_int) !win32.HWND {
    const hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        L("Ghostty"),
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN,
        x,
        y,
        width,
        height,
        null,
        null,
        self.app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed for a window frame", .{});
        return App.Error.Win32WindowCreationFailed;
    };
    self.applyDecorations();
    // Explorer runs at medium integrity, so an elevated Ghostty would not
    // hear of its button otherwise.
    if (self.app.taskbar_created != 0) {
        _ = win32.ChangeWindowMessageFilterEx(hwnd, self.app.taskbar_created, win32.MSGFLT_ALLOW, null);
    }
    return hwnd;
}

/// Size the still-hidden frame to `window-width`/`window-height`, maximize
/// it if `maximize` asks, cover its monitor if `fullscreen` asks, and show
/// it. The first WM_SETFOCUS and WM_PAINT (and the first WM_SIZE, unless
/// the size already sent one) reach the terminal from here; its core is
/// live by now.
pub fn show(self: *Window) void {
    if (self.tab().focused) |surface| {
        if (surface.initial_size) |size| self.applyInitialSize(surface, size);
    }

    // `maximize` starts every window maximized, as on GTK, which applies it
    // before `fullscreen`, so that a window that starts covering its
    // monitor comes back maximized. The first ShowWindow then both shows
    // and maximizes it. It also wins over the show state a launcher asks
    // for (STARTF_USESHOWWINDOW, as a shortcut set to run minimized does):
    // Windows takes that in place of SW_SHOWNORMAL, but not of
    // SW_SHOWMAXIMIZED, by heuristics Raymond Chen describes as
    // implementation details ("When does STARTF_USESHOWWINDOW override the
    // parameter passed to ShowWindow()?", The Old New Thing), and does not
    // give it to a later window shown with SW_SHOWNORMAL instead.
    const maximize = self.app.config.maximize;
    if (maximize) _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWMAXIMIZED);

    // `fullscreen` starts every window covering its monitor, as on GTK;
    // the macOS-only kinds of it are taken as the one kind there is. After
    // the size above, which leaving fullscreen goes back to.
    if (self.app.config.fullscreen != .false) self.toggleFullscreen();

    if (!maximize) _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNORMAL);
    _ = win32.UpdateWindow(self.hwnd);

    // A title prompt opened before the window was on screen, which holds
    // it disabled, shows with it.
    TitleDialog.frameShown(self);
}

/// The frame's window procedure.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    // As in Surface.wndProc: WM_NCCREATE carries the CREATESTRUCTW, and
    // messages before it find no pointer and fall through.
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            const self: *Window = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self: *Window = ptr: {
        const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
    };
    return self.handleMessage(hwnd, msg, wparam, lparam);
}

fn handleMessage(
    self: *Window,
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    // Registered at startup, so not a constant the switch could take: the
    // button exists now, or again after Explorer restarted.
    if (msg == self.app.taskbar_created and msg != 0) {
        self.taskbar_button = true;
        _ = self.app.taskbarList();
        self.showProgress();
        return 0;
    }

    switch (msg) {
        // The title bar button, Alt+F4 when no binding consumed it, and the
        // window menu's Close.
        win32.WM_CLOSE => {
            self.requestClose();
            return 0;
        },

        WM_GHOSTTY_DESTROY => {
            // Frees `self` unless deferred; nothing may follow it.
            self.destroyPosted();
            return 0;
        },

        win32.WM_SIZE => {
            // A child window is not resized when its frame is minimized
            // or restored at the same size, so it never sees either:
            // report the visibility from here, and from `relayout`, which
            // also knows which terminals a zoom hides. The core ignores
            // repeats.
            //
            // A minimized frame reports a 0x0 client area. The terminals
            // keep their sizes, since the core clamps the grid to at least
            // 1x1 and would reflow every line to one column and back.
            if (wparam == win32.SIZE_MINIMIZED) {
                var it = self.tab().tree.iterator();
                while (it.next()) |entry| entry.view.occlusionChanged(false);
                return 0;
            }

            // Each terminal gets its WM_SIZE synchronously, which resizes
            // its core.
            self.relayout();
            return 0;
        },

        win32.WM_DPICHANGED => {
            // The new scale first: the suggested rect below lays the
            // terminals out synchronously, and their cores must see the
            // scale before the sizes computed for them. A child window gets
            // no WM_DPICHANGED of its own. wParam carries the new DPI in
            // both words; they are always equal for a window.
            for (self.tabs.items) |t| {
                var it = t.tree.iterator();
                while (it.next()) |entry| entry.view.scaleChanged(win32.hiword(wparam));
            }
            if (self.fullscreen == null) {
                applySuggestedRect(hwnd, lparam);
            } else {
                // The suggested rect is the window's, scaled, which no longer
                // covers a monitor: it covers the monitor that rect is on.
                const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (monitorRect(win32.MonitorFromRect(suggested, win32.MONITOR_DEFAULTTONEAREST))) |rect| {
                    self.moveTo(rect, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                }
            }

            // The rect lays the terminals out through WM_SIZE only if it
            // changes the client size, but the divider width depends on the
            // DPI too. Terminals already in place get no second WM_SIZE.
            self.relayout();
            return 0;
        },

        // Sent to every top-level window, so to every frame: the app reads
        // the system's light or dark mode again once and ignores repeats.
        // DefWindowProcW below as well.
        win32.WM_SETTINGCHANGE => {
            if (isColorSetChange(lparam)) self.app.systemSchemeChanged();
            // The bar's font is the system's message font (`TabBar.messageFont`).
            if (wparam == win32.SPI_SETNONCLIENTMETRICS) {
                self.bar.freeFont();
                self.bar.invalidate();
                // And the search bars' and overlays', made again as they
                // are placed.
                for (self.tabs.items) |t| {
                    var it = t.tree.iterator();
                    while (it.next()) |entry| {
                        entry.view.search_bar.fontChanged();
                        entry.view.overlays.fontChanged();
                    }
                }
                self.placeOverlays();
                self.placeSearchBars();
                // And the command palette's.
                CommandPalette.fontChanged(self);
            }
        },

        // Deactivated: an open command palette closes, as GTK's dialog
        // does, once the deactivation is over (`CommandPalette.deactivated`).
        // DefWindowProcW below as well.
        win32.WM_ACTIVATE => if (@as(u16, @truncate(wparam)) == win32.WA_INACTIVE) {
            CommandPalette.deactivated(self);
        },

        // Keyboard focus belongs to a terminal: the frame gets it on
        // activation (DefWindowProcW's WM_ACTIVATE), and passes it on.
        win32.WM_SETFOCUS => {
            if (self.tab().focused) |surface| self.setKeyboardFocus(focusTarget(surface), false);
            return 0;
        },

        // The system modal loops. See App.wndProc's WM_GHOSTTY_WAKEUP.
        win32.WM_ENTERSIZEMOVE, win32.WM_ENTERMENULOOP => {
            self.modal_loops.enter(&self.app.modal_loop_depth);
            return 0;
        },
        win32.WM_EXITSIZEMOVE, win32.WM_EXITMENULOOP => {
            self.modal_loops.exit(&self.app.modal_loop_depth);
            return 0;
        },

        // A frame without a caption maximizes over its whole monitor. See
        // keepToWorkArea. DefWindowProcW below as well.
        win32.WM_WINDOWPOSCHANGING => if (!self.isDecorated() and self.fullscreen == null) {
            keepToWorkArea(hwnd, @ptrFromInt(@as(usize, @bitCast(lparam))));
        },

        // Sent to the top-level window, not to the terminal with the focus.
        win32.WM_SYSCOMMAND => {
            if (isBareKeyMenu(wparam, lparam)) return 0;

            // A window that covers its monitor keeps WS_MAXIMIZE if it had
            // it, so Win+Down's restore would put it back at its restore
            // rect with no frame, and Win+Up's maximize would give it the
            // work area. A restore leaves fullscreen instead, as Windows
            // Terminal's does (microsoft/terminal#10607), and a maximize does
            // nothing, as toggle_maximize does then. A minimized window is
            // restored by DefWindowProcW, and comes back covering its
            // monitor, as it was.
            if (self.fullscreen != null) switch (wparam & win32.SC_MASK) {
                win32.SC_RESTORE => if (!win32.IsIconic(hwnd).toBool()) {
                    self.toggleFullscreen();
                    return 0;
                },
                win32.SC_MAXIMIZE => return 0,
                else => {},
            };
        },

        // The resize pointer on a divider, and beside it, where a terminal
        // lets the pointer through to the frame (`Dividers`). Elsewhere,
        // and for the pointer over the frame's other windows,
        // DefWindowProcW below, as before.
        win32.WM_SETCURSOR => if (Dividers.setCursor(self, wparam, lparam)) return 1,

        // Dragging a divider (`Dividers.Drag`): a press in a band starts
        // it and takes the capture, so that the moves and the release
        // come here wherever the pointer goes; a double click in a band
        // equalizes the tab's splits. Elsewhere, and with no drag on,
        // DefWindowProcW below, as before.
        win32.WM_LBUTTONDOWN => if (Dividers.press(self, lparam)) return 0,
        win32.WM_LBUTTONDBLCLK => if (Dividers.doubleClick(self, lparam)) return 0,
        win32.WM_MOUSEMOVE => if (Dividers.dragTo(self, wparam, lparam)) return 0,
        win32.WM_LBUTTONUP => if (Dividers.release(self, lparam)) return 0,

        // The wheel in a band, which the terminal there lets through to the
        // frame: on to that terminal (`Dividers.wheel`). On a line, and
        // outside the bands, DefWindowProcW below, as before.
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => if (Dividers.wheel(self, msg, wparam, lparam)) return 0,

        // The frame lost the capture, to another window or released, as
        // DefWindowProcW releases it when a prompt disables the frame
        // (WM_CANCELMODE): a drag ends where it is. DefWindowProcW below
        // as well.
        win32.WM_CAPTURECHANGED => Dividers.captureLost(self),

        // Erased by WM_PAINT below, all of it at once.
        win32.WM_ERASEBKGND => return 1,

        // What the terminals leave of the client area: the dividers
        // between them. WS_CLIPCHILDREN keeps the paint out of the
        // terminals, which their own swap chains draw.
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &paint) orelse return 0;
            defer _ = win32.EndPaint(hwnd, &paint);
            const color = dividerColor(&self.app.config);
            const brush = win32.CreateSolidBrush(win32.rgb(color.r, color.g, color.b)) orelse return 0;
            defer _ = win32.DeleteObject(brush);
            _ = win32.FillRect(hdc, &paint.rcPaint, brush);
            return 0;
        },

        win32.WM_DESTROY => {
            // Destroyed inside its own size/move or menu loop (e.g. the
            // shell exited mid-drag): the WM_EXIT* for that loop will not
            // come, so return this window's share of the depth now.
            // Otherwise every later wakeup would tick from whatever loop
            // dispatched it.
            self.modal_loops.release(&self.app.modal_loop_depth);

            // The child windows are destroyed next, and each frees its
            // terminal (App.surfaceDestroyed): the tree lets go of them
            // first. Nothing lays the window out after this.
            for (self.tabs.items) |t| {
                t.tree.deinit();
                t.tree = .empty;
                t.focused = null;
            }
            return 0;
        },

        // After the child windows: frees `self`, so nothing may follow.
        win32.WM_NCDESTROY => {
            self.app.windowDestroyed(self);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => {},
    }

    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// WM_CLOSE and `close_window`: close the window and every terminal in it,
/// asking once if any of them would be asked about on its own
/// (`CoreSurface.needsConfirmQuit`). The window is then torn down in one
/// step (`destroyPosted`), as GTK closes a window and as `App.terminate`
/// does, not one terminal at a time, which would lay the window out again
/// after each. It leaves the screen as that teardown starts (`destroyPosted`).
///
/// `close_window` runs inside a core frame, so this only posts, as
/// `Surface.close` does.
pub fn requestClose(self: *Window) void {
    if (self.app.terminating or self.closing) return;
    self.closing = true;

    // No tree changes while the prompt is open: only `run` adds
    // terminals, and a teardown is deferred (`App.canReenterCore`).
    const ask = for (self.tabs.items) |t| {
        if (needsConfirm(t)) break true;
    } else false;
    if (ask and !confirm(
        self.app,
        self.hwnd,
        L("A process is still running in this window. Close it anyway?"),
        .ok,
    )) {
        self.closing = false;
        return;
    }

    self.postDestroy();
}

/// `close_tab`: the tabs `mode` names from the one at index `at`, as GTK
/// closes them: that one itself, every other tab, or the tabs after it.
/// Asks first, as `requestClose` does, if a process is still running in
/// one; then each of their terminals is torn down from a message loop, and
/// a tab goes with its last (`Surface.destroy`). False when `mode` names
/// no tab. Closing the window's only tab is closing the window
/// (`closeTabs`).
///
/// `close_tab` runs inside a core frame, so this only posts.
pub fn requestCloseTabs(self: *Window, at: usize, mode: apprt.action.CloseTabMode) bool {
    if (at >= self.tabs.items.len) return false;
    const closes = struct {
        fn f(index: usize, from: usize, m: apprt.action.CloseTabMode) bool {
            return switch (m) {
                .this => index == from,
                .other => index != from,
                .right => index > from,
            };
        }
    }.f;

    var any = false;
    var ask = false;
    for (self.tabs.items, 0..) |x, i| {
        if (!closes(i, at, mode)) continue;
        any = true;
        if (needsConfirm(x)) ask = true;
    }
    if (!any) return false;
    if (self.app.terminating or self.closing) return true;
    if (ask and !confirm(
        self.app,
        self.hwnd,
        L("A process is still running in a tab. Close it anyway?"),
        .ok,
    )) return true;

    // The tabs do not change while the prompt was open: only `run` adds a
    // terminal, and a teardown is deferred (`App.canReenterCore`).
    for (self.tabs.items, 0..) |x, i| {
        if (!closes(i, at, mode)) continue;
        var it = x.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.closing) continue;
            entry.view.closing = true;
            entry.view.postDestroy();
        }
    }
    return true;
}

/// Whether the tab bar shows: as `window-show-tab-bar` asks, `auto` with
/// two tabs or more, and never while the window covers its monitor, as
/// Windows Terminal hides its tabs then.
pub fn barShown(self: *const Window) bool {
    return self.barShownFor(self.tabs.items.len);
}

/// Whether the bar shows with `count` tabs (`barShown`).
fn barShownFor(self: *const Window, count: usize) bool {
    if (self.bar.hwnd == null or self.fullscreen != null) return false;
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => count >= 2,
        .never => false,
    };
}

/// The bar's height while it shows, else 0.
fn barHeight(self: *const Window) i32 {
    return self.barHeightFor(self.tabs.items.len);
}

/// The bar's height with `count` tabs (`barShownFor`).
fn barHeightFor(self: *const Window, count: usize) i32 {
    if (!self.barShownFor(count)) return 0;
    return TabBar.Metrics.init(dpiOf(self.app, self.hwnd)).height;
}

/// Show the bar along the top of the client area, or hide it, scrolled
/// to show the shown tab at its new width.
fn placeBar(self: *Window) void {
    const hwnd = self.bar.hwnd orelse return;
    var client: win32.RECT = undefined;
    if (!win32.GetClientRect(self.hwnd, &client).toBool()) return;
    const height = self.barHeight();
    const flags: win32.UINT = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE |
        if (height > 0) win32.SWP_SHOWWINDOW else win32.SWP_HIDEWINDOW;
    _ = win32.SetWindowPos(hwnd, null, 0, 0, client.right, height, flags);
    self.bar.scrollToShow(self, self.selected);
    self.bar.invalidate();
}

/// A click on tab `index` in the bar shows it, as GTK's tab bar selects
/// a clicked tab. At once when the core may be re-entered, as it may when
/// `run`'s loop dispatched the click; else, under a prompt or a tick, from
/// `run` as `goto_tab` is, since showing it lays terminals out and moves
/// the focus (`App.requests`). Nothing for a window being torn down.
///
/// Shown at once, a click runs ahead of tab requests already queued from
/// the same burst of input, such as a `goto_tab:next` key dispatched just
/// before it, which `run` then applies from the clicked tab; GTK takes the
/// two in the order they came. That is the price of selecting at once,
/// which keeps the index the click named from going stale behind them.
pub fn clickTab(self: *Window, index: usize) void {
    if (self.closing or self.app.terminating) return;
    if (index >= self.tabs.items.len or index == self.selected) return;
    if (self.app.canReenterCore()) return self.selectTab(index);
    const from = self.tab().focused orelse return;
    if (from.closing) return;
    // Every surface a request names is live (`App.requests`): a stopping
    // one's are dropped already (`App.forgetClosing`).
    const core = from.liveCore() orelse return;
    self.app.requests.append(self.app.core_app.alloc, .{ .goto_tab = .{
        .from = core,
        .to = @fromBackingInt(@intCast(index + 1)),
    } }) catch |err| {
        log.warn("cannot record a tab to show err={}", .{err});
        return;
    };
    self.app.wakeup();
}

/// The bar's "+", or a double click on its empty part: a new tab from
/// the shown tab's focused terminal. Performed as the `new_tab` binding
/// is, as GTK's "+" does (`btnNewTab` in src/apprt/gtk/class/window.zig),
/// when the core may be re-entered; else recorded for `run` as that
/// binding records it (`App.requestTab`).
pub fn clickNewTab(self: *Window) void {
    if (self.closing or self.app.terminating) return;
    const from = self.tab().focused orelse return;
    const core = from.liveCore() orelse return;
    if (self.app.canReenterCore()) {
        _ = core.performBindingAction(.new_tab) catch |err|
            return log.warn("cannot open a new tab err={}", .{err});
        self.app.wakeup();
        return;
    }
    self.app.requests.append(self.app.core_app.alloc, .{ .tab = core }) catch |err| {
        log.warn("cannot record a new tab request err={}", .{err});
        return;
    };
    self.app.wakeup();
}

/// `close_tab` from the tab at index `at` (`requestCloseTabs`), where
/// closing the window's only tab closes the window (`requestClose`); for
/// a binding (`App.closeTab`) and for the bar's close glyph and middle
/// click alike. False when `mode` names no tab.
pub fn closeTabs(self: *Window, at: usize, mode: apprt.action.CloseTabMode) bool {
    if (at >= self.tabs.items.len) return false;
    if (mode == .this and self.tabs.items.len == 1) {
        // It only posts: this runs inside a core frame for a binding
        // (see `App.closeWindow`).
        self.requestClose();
        return true;
    }
    return self.requestCloseTabs(at, mode);
}

/// Whether a terminal of `t` asks before it closes.
fn needsConfirm(t: *const Tab) bool {
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        const core_surface = entry.view.liveCore() orelse continue;
        if (core_surface.needsConfirmQuit()) return true;
    }
    return false;
}

/// Ask for the window to be torn down from a message loop.
pub fn postDestroy(self: *Window) void {
    postTeardown(self.hwnd, &self.closing);
}

/// WM_GHOSTTY_DESTROY on the frame: the window's teardown, run or deferred
/// as a terminal's is (`App.canTearDown`). **`self` is freed by
/// `destroy`**: only `app`, read beforehand, is used after it.
fn destroyPosted(self: *Window) void {
    const app = self.app;

    // terminate drives teardown itself; see App.terminate.
    if (app.terminating) return;

    if (!app.canTearDown()) {
        self.destroy_deferred = true;
        return;
    }

    // Off the screen at once, as a GTK window goes: `destroy` waits for
    // the threads of every terminal in it, one core after another. Here,
    // not in `requestClose`: that runs inside a core call for
    // close_window, and hiding the active window there could activate
    // another Ghostty window and send its terminal a focus change inside
    // that call. A posted teardown runs from a message loop.
    _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
    _ = self.destroy();

    // As in Surface.destroyPosted.
    if (app.canTearDown()) app.repostDeferredDestroys();
}

/// Stop the core of every terminal in the window, then destroy the frame,
/// which destroys their windows. Returns whether the frame was destroyed;
/// **when it was, `self` and every terminal in it have been freed**
/// (WM_DESTROY -> App.surfaceDestroyed, WM_NCDESTROY ->
/// App.windowDestroyed).
///
/// Each stopCore pumps messages, and a handler they run may add terminals
/// to `App.surfaces` or remove them, which can move the list: it is
/// searched afresh after each, until no terminal of this window has a
/// live core left.
pub fn destroy(self: *Window) bool {
    // The title prompt first, which would otherwise stay on screen until
    // its own terminal's turn, while the cores before it stop and their
    // threads are waited for, or after the frame was hidden
    // (`destroyPosted`). The command palette too.
    TitleDialog.close(self);
    CommandPalette.close(self);
    search: while (true) {
        for (self.app.surfaces.items) |surface| {
            if (surface.window != self or surface.liveCore() == null) continue;
            surface.stopCore();
            continue :search;
        }
        break;
    }
    return win32.DestroyWindow(self.hwnd).toBool();
}

/// Open a terminal beside `parent` in `direction`, in the half of
/// `parent`'s place that `layout` gives it, and created at that size
/// (`CoreSurface.init` reads it), so that it starts at its final size. It
/// is still hidden: `showPane` shows it once the app owns it
/// (`App.newSplit`).
pub fn split(
    self: *Window,
    parent: *Surface,
    direction: apprt.action.SplitDirection,
    opts: Surface.Options,
) !*Surface {
    const alloc = self.app.core_app.alloc;
    // A parent leaves its tab only when it closes, and the core's request
    // is dropped then (`App.forgetClosing`). Its tab need not be shown.
    const at = self.find(parent) orelse return error.SplitParentGone;
    const t = self.tabs.items[at.index];
    const handle = at.handle;
    const where: Tree.Split.Direction = switch (direction) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };

    const place = self.tiledPlace(parent) orelse return App.Error.Win32CallFailed;
    const cell = parent.core_surface.size.cell;
    const across = where == .left or where == .right;
    const min = std.math.lossyCast(i32, if (across) cell.width else cell.height);
    // Across, a cell and the scroll bar each side has, the new terminal's
    // as the parent's (`fitsCell`).
    const bar = if (across) ScrollBar.width(parent) else 0;
    const rect = newPaneArea(
        place,
        where,
        dividerWidth(dpiOf(self.app, self.hwnd)),
        @max(1, min) +| bar,
    ) orelse return error.SplitTooSmall;

    const surface = surface: {
        if (builtin.is_test) if (test_create_pane) |make| break :surface try make(self);
        break :surface try Surface.create(self.app, self, rect, opts);
    };
    // Nothing owns the terminal until it is in the tree.
    errdefer surface.discard();
    var single: Tree = try .init(alloc, surface);
    defer single.deinit();
    const tree = try t.tree.split(alloc, handle, where, new_split_ratio, &single);
    errdefer comptime unreachable;
    self.setTree(t, tree);
    return surface;
}

/// For tests: makes the terminal `split` opens, in place of
/// `Surface.create`, which starts a core and its program; a test's
/// terminals have no core.
pub var test_create_pane: if (builtin.is_test) ?*const fn (*Window) anyerror!*Surface else void =
    if (builtin.is_test) null else {};

/// Make `tree` `t`'s tree in place of the one it has, which is freed. A
/// split, a resize or equalize (`adopt`) and a terminal leaving
/// (`removePane`, `keepLeftOut`) put their new tree here, which ends a
/// drag of a divider in the tab (`Dividers.tabChanged`): the split it
/// moves may be gone, and its handle name another. A zoom ends it too
/// (`toggleZoom`).
pub fn setTree(self: *Window, t: *Tab, tree: Tree) void {
    t.tree.deinit();
    t.tree = tree;
    Dividers.tabChanged(self, t);
}

/// Where `pane` is in the client area with no zoom, as `layout` tiles it.
/// A split divides that place, since it ends any zoom (`SplitTree.split`),
/// whereas a zoomed terminal's window covers the whole client area.
pub fn tiledPlace(self: *Window, pane: *Surface) ?win32.RECT {
    const client = self.layoutArea() orelse return null;
    var tiled = (self.tabOf(pane) orelse return null).tree;
    tiled.zoomed = null;
    var found: PlaceOf = .{ .target = pane };
    layout(&tiled, client, dividerWidth(dpiOf(self.app, self.hwnd)), &found);
    return found.place;
}

/// What `tiledPlace` asks `layout` for: one terminal's place.
const PlaceOf = struct {
    target: *Surface,
    place: ?win32.RECT = null,

    pub fn pane(self: *PlaceOf, surface: *Surface, rect: win32.RECT) void {
        if (surface == self.target) self.place = rect;
    }

    pub fn divider(self: *PlaceOf, handle: Tree.Node.Handle, line: win32.RECT, across: bool, area: win32.RECT) void {
        _ = self;
        _ = handle;
        _ = line;
        _ = across;
        _ = area;
    }

    pub fn hidden(self: *PlaceOf, surface: *Surface) void {
        _ = self;
        _ = surface;
    }
};

/// Show a terminal `split` opened, now that the app owns it, with room
/// made for it, and give it the focus.
pub fn showPane(self: *Window, surface: *Surface) void {
    // The layout shows it (`Placer.pane`).
    self.relayout();
    self.giveFocus(surface);
}

/// The terminal `to` names from `from`, for `goto_split`, as GTK goes
/// (`gotoSplit` in src/apprt/gtk/class/application.zig): previous and next
/// wrap around, and a direction is the nearest terminal that way
/// (`SplitTree.goto`). Null when there is none but `from`.
pub fn goto(self: *Window, from: *Surface, to: apprt.action.GotoSplit) ?*Surface {
    const place = self.find(from) orelse return null;
    const t = self.tabs.items[place.index];
    const handle = place.handle;
    const found = t.tree.goto(self.app.core_app.alloc, handle, switch (to) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    }) catch |err| switch (err) {
        // Only the search by direction allocates, and only a little.
        error.OutOfMemory => {
            log.warn("cannot find the split to go to err={}", .{err});
            return null;
        },
    };
    const target = found orelse return null;
    if (target == handle) return null;
    return t.tree.nodes[target.idx()].leaf;
}

/// For `resize_split`: move the divider of the split nearest `from` that
/// runs across `value.direction`, by `value.amount` device-independent
/// pixels measured against the whole window, as GTK does (`resize` in
/// src/apprt/gtk/class/split_tree.zig, then `SplitTree.resize`). Nothing
/// moves if a terminal would shrink below a cell (`adopt`).
pub fn resizeSplit(self: *Window, from: *Surface, value: apprt.action.ResizeSplit) void {
    const place = self.find(from) orelse return;
    const t = self.tabs.items[place.index];
    const handle = place.handle;
    const client = self.layoutArea() orelse return;
    const across = value.direction == .left or value.direction == .right;
    const extent = if (across) client.right - client.left else client.bottom - client.top;
    if (extent <= 0) return;
    const ratio = resizeShare(value.amount, dpiOf(self.app, self.hwnd), extent, value.direction);

    const layout_of: Tree.Split.Layout = if (across) .horizontal else .vertical;
    var tree = t.tree.resize(self.app.core_app.alloc, handle, layout_of, ratio) catch |err| {
        log.warn("cannot resize the split err={}", .{err});
        return;
    };
    self.adopt(t, &tree, client);
}

/// `resize_split`'s move as `SplitTree.resize` takes it: `amount`
/// device-independent pixels at `dpi` as a share of `extent`, the window's
/// width or height in pixels, positive to the right and down, and within
/// the [-1, 1] that SplitTree.resize asserts: a larger amount moves the
/// divider as far as it goes.
fn resizeShare(
    amount: u16,
    dpi: u32,
    extent: i32,
    direction: apprt.action.ResizeSplit.Direction,
) f16 {
    assert(extent > 0);
    const reference: f64 = @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI);
    const pixels = @as(f64, @floatFromInt(amount)) * @as(f64, @floatFromInt(dpi)) / reference;
    const share = @min(pixels / @as(f64, @floatFromInt(extent)), 1);
    return @floatCast(switch (direction) {
        .right, .down => share,
        .left, .up => -share,
    });
}

/// For `equalize_splits`: give each split a share by the number of
/// terminals on each side of it, as GTK and macOS do (`SplitTree.equalize`).
/// Nothing moves if a terminal would shrink below a cell (`adopt`).
pub fn equalize(self: *Window, from: *Surface) void {
    self.equalizeTab(self.tabOf(from) orelse return);
}

/// `equalize` for the tab `t`, as a double click on a divider asks
/// (`Dividers.doubleClick`).
pub fn equalizeTab(self: *Window, t: *Tab) void {
    const client = self.layoutArea() orelse return;
    var tree = t.tree.equalize(self.app.core_app.alloc) catch |err| {
        log.warn("cannot equalize the splits err={}", .{err});
        return;
    };
    self.adopt(t, &tree, client);
}

/// Keep `tree`, a resized or equalized copy of `t.tree`, laying its
/// terminals out if `t` is shown; or, if that would leave a terminal it
/// shrinks less than a cell across or down in `client`, free it and change
/// nothing. A split refuses the same (`newPaneArea`): a terminal with no
/// room shows nothing, and `SplitTree.resize` would clamp a ratio as far
/// as 0 or 1.
fn adopt(self: *Window, t: *Tab, tree: *Tree, client: win32.RECT) void {
    const divider = dividerWidth(dpiOf(self.app, self.hwnd));
    if (!keepsCells(&t.tree, tree, client, divider)) {
        tree.deinit();
        return;
    }
    self.setTree(t, tree.*);
    if (t == self.tab()) self.relayout();
}

/// Whether laying the terminals out by `new` instead of `old` in `area`
/// leaves each one it shrinks at least a cell across and down: the cell of
/// its own font, or a pixel for a terminal with no core. `new` is `old`
/// with only its ratios changed (`SplitTree.resize` and `SplitTree.equalize`
/// copy the nodes and rewrite ratios), so the two are laid out side by
/// side, as `layout` would lay out each.
pub fn keepsCells(old: *const Tree, new: *const Tree, area: win32.RECT, divider: i32) bool {
    assert(old.nodes.len == new.nodes.len);
    if (new.isEmpty()) return true;
    return keepsCellsAt(old, new, .root, area, area, divider);
}

/// `keepsCells` for the terminals at and under `handle`: laid out by `old`
/// in `was` and by `new` in `now`. A divider's drag asks it of each side of
/// its split, laid out from where it is to where the drag would put it
/// (`Dividers.dragRatio`), so that the drag and `adopt` keep the same
/// least.
pub fn keepsCellsAt(
    old: *const Tree,
    new: *const Tree,
    handle: Tree.Node.Handle,
    was: win32.RECT,
    now: win32.RECT,
    divider: i32,
) bool {
    switch (new.nodes[handle.idx()]) {
        .leaf => |surface| {
            assert(old.nodes[handle.idx()].leaf == surface);
            return fitsCell(surface, was, now);
        },
        .split => |s| {
            const across = s.layout == .horizontal;
            const before = splitArea(was, across, old.nodes[handle.idx()].split.ratio, divider);
            const after = splitArea(now, across, s.ratio, divider);
            return keepsCellsAt(old, new, s.left, before.first, after.first, divider) and
                keepsCellsAt(old, new, s.right, before.second, after.second, divider);
        },
    }
}

/// Whether `surface`, moving from `was` to `now`, keeps a cell across and
/// down wherever it shrinks (`keepsCells`): in what its scroll bar leaves
/// of its window across, the client area the grid is laid out in.
fn fitsCell(surface: *Surface, was: win32.RECT, now: win32.RECT) bool {
    const w = now.right - now.left;
    const h = now.bottom - now.top;
    if (w < was.right - was.left and w - ScrollBar.width(surface) < cellExtent(surface, true)) return false;
    if (h < was.bottom - was.top and h < cellExtent(surface, false)) return false;
    return true;
}

/// The least a terminal is given across (`across`) or down by a change
/// that shrinks it: a cell of its own font, or a pixel for a terminal with
/// no core. `adopt` refuses a resize below it, and a divider's drag stops
/// at it (`fitsCell`).
fn cellExtent(surface: *Surface, across: bool) i32 {
    const core = surface.liveCore() orelse return 1;
    const cell = core.size.cell;
    return @max(1, std.math.lossyCast(i32, if (across) cell.width else cell.height));
}

/// `toggle_split_zoom`: make `from` fill the window alone, or end the
/// zoom, as GTK's `split-tree.zoom` does. A zoomed tab has no divider, so
/// a divider's drag in it ends (`Dividers.tabChanged`). Never inside a
/// core frame: the layout sends WM_SIZE (`App.requests`).
pub fn toggleZoom(self: *Window, from: *Surface) void {
    const place = self.find(from) orelse return;
    const t = self.tabs.items[place.index];
    if (t.tree.zoomed != null) {
        t.tree.zoom(null);
    } else {
        t.tree.zoom(place.handle);
    }
    Dividers.tabChanged(self, t);
    if (t == self.tab()) self.relayout();
}

/// Give the focus to `surface`, which a `goto_split` chose. A zoom ends
/// first, as on GTK, or with `split-preserve-zoom = navigation` moves to
/// `surface` (`goto` in src/apprt/gtk/class/split_tree.zig), so that the
/// focus never goes to a hidden terminal. Never inside a core frame: the
/// layout sends WM_SIZE.
pub fn focusFromGoto(self: *Window, surface: *Surface) void {
    // In its own tab, shown first, as GTK presents a terminal: the focus
    // and the zoom below are the shown tab's.
    const place = self.find(surface) orelse return;
    self.selectTab(place.index);
    if (self.followZoom(self.tab(), surface)) self.relayout();
    self.giveFocus(surface);
}

/// A `goto_split` focus move in `t`, a hidden tab, which an `all:`
/// binding reaches (`CoreApp.performAllAction`): `surface` is the terminal
/// it shows with the focus when it is next selected (`showTab`), its zoom
/// moved as `focusFromGoto` moves it, as GTK's goto_split sets a hidden
/// tab's last focused terminal and zoom (`goto` in
/// src/apprt/gtk/class/split_tree.zig). Sends no window message, so it may
/// run inside a core frame.
pub fn focusHidden(self: *const Window, t: *Tab, surface: *Surface) void {
    assert(t != self.tab());
    _ = self.followZoom(t, surface);
    t.focused = surface;
}

/// Move `t`'s zoom, if any, for a focus move to `surface`: onto it with
/// `split-preserve-zoom = navigation`, or else ended. Returns whether there
/// was one.
fn followZoom(self: *const Window, t: *Tab, surface: *Surface) bool {
    if (t.tree.zoomed == null) return false;
    if (self.app.config.@"split-preserve-zoom".navigation) {
        if (t.tree.locate(surface)) |handle| t.tree.zoom(handle);
    } else {
        t.tree.zoom(null);
    }
    return true;
}

/// Make `surface` the window's focused terminal and give it the keyboard
/// focus, or its search field if that had it last (`focusTarget`). Only
/// the active window sets the keyboard focus at once; another one would be
/// activated by it, so it hands the focus over when it is activated
/// (WM_SETFOCUS).
pub fn giveFocus(self: *Window, surface: *Surface) void {
    self.setFocused(surface);
    self.setKeyboardFocus(focusTarget(surface), true);
}

/// Make `surface` its tab's focused terminal and, in the tab shown, name
/// the window after it, as GTK and macOS title a window after its focused
/// split. A terminal in no tab yet, still being made, is not recorded.
pub fn setFocused(self: *Window, surface: *Surface) void {
    const t = self.tabOf(surface) orelse return;
    t.focused = surface;
    // Its label is its focused terminal's title, shown or not.
    self.bar.invalidate();
    if (t != self.tab()) return;
    // An open command palette runs on the terminal with the focus.
    CommandPalette.focusMoved(self, surface);
    _ = self.showTitle(tabTitle(t));
    self.showProgress();
}

/// Show the focused terminal's progress on the window's taskbar button, as
/// Windows Terminal shows its focused pane's; nothing before the button
/// exists (`taskbar_button`).
pub fn showProgress(self: *Window) void {
    if (!self.taskbar_button) return;
    const list = self.app.taskbar_list orelse return;
    const surface = self.tab().focused orelse return;
    list.show(self.hwnd, surface.progress);
}

/// Show `title`, the focused terminal's, as the window's caption, or
/// "Ghostty" while it has none. Returns whether it is shown.
///
/// Invalid UTF-8 is shown as U+FFFD, as macOS does (`Surface.setTitle`).
pub fn showTitle(self: *Window, title: ?[:0]const u8) bool {
    const alloc = self.app.core_app.alloc;
    const wide = wideFromUtf8(alloc, title orelse "Ghostty") catch |err| {
        log.warn("failed to encode the window title err={}", .{err});
        return false;
    };
    defer alloc.free(wide);
    if (!win32.SetWindowTextW(self.hwnd, wide.ptr).toBool()) {
        log.warn("SetWindowTextW failed err={}", .{win32.GetLastError()});
        return false;
    }
    return true;
}

/// Map `rect`, in screen coordinates, to the frame's client area.
pub fn toClient(self: *const Window, rect: *win32.RECT) bool {
    var corners = [2]win32.POINT{
        .{ .x = rect.left, .y = rect.top },
        .{ .x = rect.right, .y = rect.bottom },
    };
    for (&corners) |*pt| {
        if (!win32.ScreenToClient(self.hwnd, pt).toBool()) return false;
    }
    rect.* = .{
        .left = corners[0].x,
        .top = corners[0].y,
        .right = corners[1].x,
        .bottom = corners[1].y,
    };
    return true;
}

/// Take the terminal at `handle` in the tree out of this window ahead of
/// its teardown (`Surface.destroy`), when another terminal stays. The others
/// are laid out again over its place, and if it had the focus, the focus
/// moves to the terminal before it, else the one after it, as on GTK
/// (`closeConfirmationClose` in src/apprt/gtk/class/split_tree.zig). It is
/// hidden, so that nothing shows it while its core stops.
///
/// Fails only to allocate the new tree, and then changes nothing.
pub fn removePane(self: *Window, t: *Tab, handle: Tree.Node.Handle) !void {
    const alloc = self.app.core_app.alloc;
    const surface = t.tree.nodes[handle.idx()].leaf;

    // From the tree as it is, which still has `handle`. `.previous` and
    // `.next` allocate nothing.
    const focus: ?*Surface = if (t.focused != surface) t.focused else focus: {
        const to = (t.tree.goto(alloc, handle, .previous) catch null) orelse
            (t.tree.goto(alloc, handle, .next) catch null) orelse
            break :focus null;
        break :focus t.tree.nodes[to.idx()].leaf;
    };

    const tree = try t.tree.remove(alloc, handle);
    errdefer comptime unreachable;
    self.setTree(t, tree);
    t.focused = focus;

    // A hidden tab's terminals are hidden already, and the focus and the
    // layout are the shown tab's.
    if (t != self.tab()) return;
    // The focus moves first, so that it is never left on a hidden window.
    if (focus) |f| self.giveFocus(f);
    _ = win32.ShowWindow(surface.hwnd, win32.SW_HIDE);
    self.relayout();
}

/// Lay the terminals out over the client area (`layout`), then place their
/// overlays and search bars over them. Not while the window is minimized
/// and its client area is empty (see WM_SIZE).
pub fn relayout(self: *Window) void {
    if (self.tab().tree.isEmpty() or win32.IsIconic(self.hwnd).toBool()) return;
    self.placeBar();
    const client = self.layoutArea() orelse return;
    self.placeTerminals(client);
    self.placeOverlays();
    self.placeSearchBars();
    // Above them all, or closed if it no longer fits.
    _ = CommandPalette.place(self);
}

/// Place each search bar of the shown tab's terminals where its terminal
/// is now, above it, or hide it (`SearchBar.place`): a terminal a zoom
/// hides has its bar hidden, and one that came back from a zoom, or was
/// made since, is under the bars again.
pub fn placeSearchBars(self: *Window) void {
    var it = self.tab().tree.iterator();
    while (it.next()) |entry| SearchBar.place(entry.view);
}

/// Place the overlays of each of the shown tab's terminals where the
/// terminal is now, just above it, or hide them (`Overlays.place`), as
/// `placeSearchBars` places their search bars.
pub fn placeOverlays(self: *Window) void {
    var it = self.tab().tree.iterator();
    while (it.next()) |entry| Overlays.place(entry.view);
}

/// The window that gets the keyboard focus for `surface`: the field of its
/// window's command palette while that is open and shows, which holds the
/// keyboard until it closes (`CommandPalette.Palette.focusTarget`); else
/// its search field while the field had it last and shows, else the
/// terminal (`SearchBar.Bar.focusTarget`).
pub fn focusTarget(surface: *const Surface) win32.HWND {
    return surface.window.palette.focusTarget() orelse
        surface.search_bar.focusTarget() orelse
        surface.hwnd;
}

/// For tests: told the window SetFocus would be given by `giveFocus` and
/// the frame's WM_SETFOCUS, in place of SetFocus, which activates the
/// window, so that a test sees where the focus goes without taking the
/// foreground.
pub var test_set_focus: if (builtin.is_test) ?*const fn (win32.HWND) void else void =
    if (builtin.is_test) null else {};

/// For tests: answers in place of GetFocus (`keyboardFocus`), as
/// `test_set_focus` stands for SetFocus.
pub var test_get_focus: if (builtin.is_test) ?*const fn () ?win32.HWND else void =
    if (builtin.is_test) null else {};

/// The window with the keyboard focus on this thread, GetFocus's answer.
pub fn keyboardFocus() ?win32.HWND {
    if (builtin.is_test) if (test_get_focus) |get| return get();
    return win32.GetFocus();
}

/// SetFocus(`hwnd`), a window of this frame; with `active_only`, only
/// while the frame is the active window, as another would be activated by
/// it.
pub fn setKeyboardFocus(self: *const Window, hwnd: win32.HWND, active_only: bool) void {
    if (builtin.is_test) if (test_set_focus) |seen| return seen(hwnd);
    if (active_only and win32.GetActiveWindow() != self.hwnd) return;
    _ = win32.SetFocus(hwnd);
}

/// The focus move `start_search` or `end_search` asked for
/// (`App.search_focus`): `surface`, or its search field
/// (`focusTarget`), gets the focus if it shows: a hidden tab's terminals
/// are hidden (`selectTab`), and so is one a zoom hides (`layout`).
pub fn giveSearchFocus(self: *Window, surface: *Surface) void {
    const visible: isize = win32.WS_VISIBLE;
    if (win32.GetWindowLongPtrW(surface.hwnd, win32.GWL_STYLE) & visible == 0) return;
    self.giveFocus(surface);
}

/// Move each terminal of the shown tab where `layout` puts it in `client`.
fn placeTerminals(self: *Window, client: win32.RECT) void {
    const divider = dividerWidth(dpiOf(self.app, self.hwnd));

    // One batch, so that the terminals move together.
    const count = std.math.lossyCast(c_int, self.tab().tree.nodes.len);
    var placer: Placer = .{ .batch = win32.BeginDeferWindowPos(count) };
    layout(&self.tab().tree, client, divider, &placer);
    if (placer.batch) |batch| {
        if (win32.EndDeferWindowPos(batch).toBool()) return;
    } else if (!placer.dropped) {
        // There was no batch, and each terminal is already in place.
        return;
    }

    // The batch failed, and none of its positions were applied: each
    // terminal is placed on its own instead.
    var direct: Placer = .{ .batch = null };
    layout(&self.tab().tree, client, divider, &direct);
}

/// Moves each terminal where `layout` puts it: in a batch while there is
/// one, else at once.
const Placer = struct {
    batch: ?win32.HDWP,

    /// A DeferWindowPos failed. The batch is then abandoned, as its
    /// documentation says, so none of its positions are applied.
    dropped: bool = false,

    // Not SWP_NOCOPYBITS: it would repaint a terminal on every step of a
    // shrink, which the class styles avoid (`App.registerClasses`), and a
    // flip-model swap chain moves with its window. A terminal placed is
    // shown, as one a zoom hid comes back when the zoom ends.
    const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW;
    const hide_flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOMOVE |
        win32.SWP_NOSIZE | win32.SWP_HIDEWINDOW;

    pub fn pane(self: *Placer, surface: *Surface, rect: win32.RECT) void {
        surface.occlusionChanged(true);
        self.place(surface.hwnd, rect, flags);
    }

    /// A terminal a zoom hides (`layout`): its core stops drawing.
    pub fn hidden(self: *Placer, surface: *Surface) void {
        surface.occlusionChanged(false);
        self.place(surface.hwnd, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, hide_flags);
    }

    fn place(self: *Placer, hwnd: win32.HWND, rect: win32.RECT, how: win32.UINT) void {
        if (self.dropped) return;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (self.batch) |batch| {
            self.batch = win32.DeferWindowPos(batch, hwnd, null, rect.left, rect.top, w, h, how);
            self.dropped = self.batch == null;
        } else {
            _ = win32.SetWindowPos(hwnd, null, rect.left, rect.top, w, h, how);
        }
    }

    /// Nothing to place: the frame paints the gaps between terminals
    /// itself (WM_PAINT).
    pub fn divider(self: *Placer, handle: Tree.Node.Handle, line: win32.RECT, across: bool, area: win32.RECT) void {
        _ = self;
        _ = handle;
        _ = line;
        _ = across;
        _ = area;
    }
};

/// Where each terminal of `tree` goes in `area`, and the dividers between
/// them, in whole pixels: `ctx.pane(view, rect)` for every leaf, and
/// `ctx.divider(handle, line, across, area)` for every split that has a
/// line, before the splits inside it: its handle, its line, whether its
/// sides are left and right of the line (`.horizontal`) rather than above
/// and below it, and the area it divides. A split gives `divider` pixels to
/// the line between its sides, fewer if it is narrower than that, and
/// divides the rest by its ratio, to the nearest pixel, so that the panes
/// and dividers tile `area` exactly. `tree.spatial` describes the same
/// layout without dividers, but normalized to f16, which is up to two
/// pixels off at 3840 pixels across.
///
/// A zoomed terminal (`toggleZoom`) fills `area` alone, and every other
/// one is `ctx.hidden(view)`, with no dividers.
///
/// Generic over the tree so that tests can lay out a tree of their own.
pub fn layout(tree: anytype, area: win32.RECT, divider: i32, ctx: anytype) void {
    if (tree.isEmpty()) return;
    const zoomed = tree.zoomed orelse {
        layoutNode(tree, .root, area, divider, ctx);
        return;
    };
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.handle != zoomed) ctx.hidden(entry.view);
    }
    layoutNode(tree, zoomed, area, divider, ctx);
}

fn layoutNode(
    tree: anytype,
    handle: @TypeOf(tree.*).Node.Handle,
    area: win32.RECT,
    divider: i32,
    ctx: anytype,
) void {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| ctx.pane(view, area),
        .split => |s| {
            const across = s.layout == .horizontal;
            const sides = splitArea(area, across, s.ratio, divider);
            if (sides.line > 0) ctx.divider(handle, sides.divider, across, area);
            layoutNode(tree, s.left, sides.first, divider, ctx);
            layoutNode(tree, s.right, sides.second, divider, ctx);
        },
    }
}

/// How a split divides `area` (`layout`): `divider` pixels for the line
/// between its sides, fewer if it is narrower than that, and the rest by
/// `ratio`, to the nearest pixel, for the first side (left or top).
pub fn splitArea(area: win32.RECT, across: bool, ratio: f16, divider: i32) Sides {
    const total = @max(0, if (across) area.right - area.left else area.bottom - area.top);
    const line = std.math.clamp(divider, 0, total);
    return splitAt(area, across, line, firstExtent(total - line, ratio));
}

/// A split's two sides and its line in its area (`splitArea`).
pub const Sides = struct {
    first: win32.RECT,
    divider: win32.RECT,
    second: win32.RECT,
    line: i32,
};

/// How a split divides `area` with its first side `first` pixels across
/// (`across`) or down and its line `line` pixels after it, the second side
/// taking the rest: `splitArea` for a ratio that lays out `first`, as a
/// divider's drag tries places for its line (`Dividers.dragRatio`).
pub fn splitAt(area: win32.RECT, across: bool, line: i32, first: i32) Sides {
    var a = area;
    var d = area;
    var b = area;
    if (across) {
        a.right = area.left + first;
        d.left = a.right;
        d.right = d.left + line;
        b.left = d.right;
    } else {
        a.bottom = area.top + first;
        d.top = a.bottom;
        d.bottom = d.top + line;
        b.top = d.bottom;
    }
    return .{ .first = a, .divider = d, .second = b, .line = line };
}

/// How many of `rest` pixels, a split's area less its line, `splitArea`
/// gives its first side at `ratio`: to the nearest pixel.
pub fn firstExtent(rest: i32, ratio: f16) i32 {
    const scaled = @round(@as(f32, @floatFromInt(rest)) * @as(f32, ratio));
    return std.math.clamp(std.math.lossyCast(i32, scaled), 0, rest);
}

/// Where `split` puts a new terminal beside one at `area`: the side
/// `where` names of `area` split as `layout` will split it, at
/// `new_split_ratio`. Null if it, or what it leaves of `area`, would be less
/// than `min` pixels across the split: a terminal with no room takes the
/// focus and shows nothing.
fn newPaneArea(
    area: win32.RECT,
    where: Tree.Split.Direction,
    divider: i32,
    min: i32,
) ?win32.RECT {
    const across = where == .left or where == .right;
    const sides = splitArea(area, across, new_split_ratio, divider);
    const new, const left = switch (where) {
        .left, .up => .{ sides.first, sides.second },
        .right, .down => .{ sides.second, sides.first },
    };
    const extent = struct {
        fn extent(r: win32.RECT, a: bool) i32 {
            return if (a) r.right - r.left else r.bottom - r.top;
        }
    }.extent;
    if (extent(new, across) < min or extent(left, across) < min) return null;
    return new;
}

/// A new split's share of its parent's place: half, as on GTK, which
/// says "Always split equally for new splits"
/// (src/apprt/gtk/class/split_tree.zig).
pub const new_split_ratio: f16 = 0.5;

/// The colour of the line between two terminals: `split-divider-color`, or
/// the one macOS derives from the background (`splitDividerColor` in
/// macos/Sources/Ghostty/Ghostty.Config.swift): darkened by 8% on a light
/// background and by 40% on a dark one. macOS darkens the HSB brightness,
/// which scales red, green and blue alike, and calls a background light
/// above a perceived luminance of 0.5.
pub fn dividerColor(config: *const configpkg.Config) terminal.color.RGB {
    if (config.@"split-divider-color") |color| return color.toTerminalRGB();
    const bg = config.background.toTerminalRGB();
    const keep: f64 = if (bg.perceivedLuminance() > 0.5) 0.92 else 0.6;
    const darken = struct {
        fn darken(c: u8, k: f64) u8 {
            return @intFromFloat(@round(@as(f64, @floatFromInt(c)) * k));
        }
    }.darken;
    return .{ .r = darken(bg.r, keep), .g = darken(bg.g, keep), .b = darken(bg.b, keep) };
}

/// The width of the line between two terminals: a pixel at 96 DPI, scaled
/// to the nearest whole pixel (halves up) and never less than one.
pub fn dividerWidth(dpi: u32) i32 {
    const base = win32.USER_DEFAULT_SCREEN_DPI;
    return @intCast(@max(1, (dpi +| base / 2) / base));
}

/// Whether a frame's title bar is dark, by `window-theme`. `auto` follows
/// the background, light above a perceived luminance of 0.5 as on GTK and
/// macOS, except with a light and a dark `theme`, when it follows the
/// system: `Config.finalize` turns such an `auto` into `system`. `ghostty`,
/// the GTK header bar in the terminal's colors, is taken as `auto`, as GTK
/// takes it when it picks its color scheme, and finalize leaves it alone,
/// so the pair is checked here. Followed by the background, a pair would
/// pick the scheme from the half it picked: stuck on one half, or, if the
/// light half is dark, flipping between them for good.
pub fn frameDark(config: *const configpkg.Config, system: apprt.ColorScheme) bool {
    return switch (config.@"window-theme") {
        .light => false,
        .dark => true,
        .system => system == .dark,
        .auto, .ghostty => if (config._conditional_set.contains(.theme))
            system == .dark
        else
            config.background.toTerminalRGB().perceivedLuminance() <= 0.5,
    };
}

/// Give the frame the title bar `frameDark` asks for, through DWM's
/// immersive dark mode. A visible frame repaints its title bar by itself.
/// A failed call leaves `dark_frame` as it was, so the next one tries
/// again.
pub fn applyTheme(self: *Window) void {
    const dark = frameDark(&self.app.config, self.app.system_scheme);
    if (dark == self.dark_frame) return;

    const value: win32.BOOL = if (dark) .TRUE else .FALSE;
    const hr = win32.DwmSetWindowAttribute(
        self.hwnd,
        win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &value,
        @sizeOf(win32.BOOL),
    );
    if (hr < 0) {
        log.warn("cannot set the title bar's mode dark={} hr=0x{x}", .{ dark, @as(u32, @bitCast(hr)) });
        return;
    }
    self.dark_frame = dark;
    // And its title prompt's title bar, if one is open.
    TitleDialog.setDark(self, dark);
    self.bar.invalidate();
    for (self.tabs.items) |t| {
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            entry.view.search_bar.invalidate();
            entry.view.overlays.invalidate();
            ScrollBar.applyTheme(entry.view);
        }
    }
    CommandPalette.invalidate(self);
}

/// Whether a WM_SETTINGCHANGE is about the light or dark mode of apps,
/// which Windows announces as "ImmersiveColorSet".
fn isColorSetChange(lparam: win32.LPARAM) bool {
    if (lparam == 0) return false;
    const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
    return std.mem.orderZ(u16, name, L("ImmersiveColorSet")) == .eq;
}

/// The DPI of `hwnd`, falling back to the reference 96 when it cannot be
/// determined. Never returns 0: scaling by zero would silently produce a
/// zero-size grid rather than an error anybody could see.
pub fn dpiOf(app: *const App, hwnd: win32.HWND) u32 {
    // Resolved at runtime, not statically imported -- GetDpiForWindow does
    // not exist before Windows 10 1607 and a static import would stop the
    // binary loading there at all. See App.init.
    if (app.get_dpi_for_window) |f| {
        // Returns 0 for an invalid window.
        const v = f(hwnd);
        if (v != 0) return v;
    }

    // Pre-1607 fallback. This is the *correct* answer on those versions:
    // they have no per-monitor DPI, so the system-wide value is the only
    // one there is.
    if (win32.GetDC(null)) |screen| {
        defer _ = win32.ReleaseDC(null, screen);
        const v = win32.GetDeviceCaps(screen, win32.LOGPIXELSX);
        if (v > 0) return @intCast(v);
    }

    return win32.USER_DEFAULT_SCREEN_DPI;
}

/// Resize the window so that its client area, less `surface`'s scroll
/// bar, is `size` scaled by `surface`'s content scale: the client area of
/// a terminal that fills the window. The whole value is scaled,
/// as macOS and GTK also treat it, so the core's device-pixel padding
/// comes out larger by the scale factor: the grid is never smaller than
/// requested, at most a little larger, unless the window would not fit its
/// monitor's work area (`resizeClient`).
pub fn applyInitialSize(self: *Window, surface: *const Surface, size: apprt.action.InitialSize) void {
    const scale = (surface.getContentScale() catch unreachable).x;
    // SetWindowPos sends WM_SIZE synchronously; the core is live, so it
    // sees the new size before the first paint. That WM_SIZE also reports
    // the window visible (occlusionCallback) while it is still hidden,
    // which is harmless only because ShowWindow follows immediately. The
    // tab bar, if it shows, comes on top of the terminal's size, and the
    // terminal's scroll bar beside it, so that `window-width` counts the
    // grid's columns.
    _ = resizeClient(
        self.hwnd,
        scaledSize(size.width, scale) +| ScrollBar.width(surface),
        scaledSize(size.height, scale) +| self.barHeight(),
    );
}

/// `points` at `scale`, in device pixels, rounded up.
pub fn scaledSize(points: u32, scale: f32) i32 {
    return std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(points)) * scale));
}

/// Resize the window so its client area is `client_w` by `client_h`
/// device pixels, its top-left corner kept, unless it would not fit its
/// monitor's work area; false, logged, if it could not be. The frame is
/// measured from the window itself rather than with
/// AdjustWindowRectExForDpi, which does not exist before Windows 10 1607
/// (see the dynamic imports in App.init): the window already exists at its
/// final DPI, so its window rect minus its client rect is exactly the frame.
/// The sizes saturate, since `window-width` is only clamped from below.
fn resizeClient(hwnd: win32.HWND, client_w: i32, client_h: i32) bool {
    var window: win32.RECT = undefined;
    var client: win32.RECT = undefined;
    if (!win32.GetWindowRect(hwnd, &window).toBool() or !win32.GetClientRect(hwnd, &client).toBool()) {
        log.warn("unable to read the window frame, window not resized err={}", .{win32.GetLastError()});
        return false;
    }
    const monitor = monitorInfo(win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST)) orelse
        return false;
    const frame_w = (window.right - window.left) - (client.right - client.left);
    const frame_h = (window.bottom - window.top) - (client.bottom - client.top);

    // CW_USEDEFAULT placed the default-sized window inside the work
    // area, but nothing keeps a larger one grown from the same corner
    // there: SetWindowPos does not move a window back on screen, and
    // the only size limit Windows applies is the maximum track size,
    // about the whole virtual screen.
    const rect = constrainToWorkArea(
        window.left,
        window.top,
        client_w +| frame_w,
        client_h +| frame_h,
        monitor.rcWork,
    );

    if (!win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    ).toBool()) {
        log.warn("unable to resize the window err={}", .{win32.GetLastError()});
        return false;
    }
    return true;
}

/// Whether the window is at a size of its own, as Microsoft's IsRestored
/// example for IsWindowArranged decides it: not minimized, maximized or
/// snapped (arranged; not known before Windows 10 1903), nor covering its
/// monitor.
pub fn isRestored(self: *const Window) bool {
    if (self.fullscreen != null) return false;
    if (win32.IsIconic(self.hwnd).toBool() or win32.IsZoomed(self.hwnd).toBool()) return false;
    if (self.app.is_window_arranged) |arranged| {
        if (arranged(self.hwnd).toBool()) return false;
    }
    return true;
}

/// Whether `resize_window` may resize the window for `surface`: as on GTK
/// and macOS, only when it is the window's one terminal, since other
/// terminals would change too, and the window is at a size of its own
/// (`isRestored`), as `vt-window-resize-allowed` documents it.
pub fn terminalResizable(self: *const Window, surface: *const Surface) bool {
    if (self.tabs.items.len != 1) return false;
    if (self.tab().tree.isSplit() or self.tab().tree.locate(surface) == null) return false;
    return self.isRestored();
}

/// What `reset_window_size` gives the window, as macOS decides a new
/// window's size: maximized with `maximize`, or else the size
/// `window-width` and `window-height` ask for (`Surface.initial_size`);
/// null with neither, when a new window takes Windows' default, which
/// macOS does not go back to either.
pub const DefaultSize = union(enum) {
    maximized,
    initial: apprt.action.InitialSize,
};

/// The size `reset_window_size` would give the window now, or null when
/// it has none or covers its monitor, which `reset_window_size` leaves.
pub fn defaultSize(self: *const Window) ?DefaultSize {
    if (self.fullscreen != null) return null;
    if (self.app.config.maximize) return .maximized;
    const surface = self.tab().focused orelse return null;
    return .{ .initial = surface.initial_size orelse return null };
}

/// `reset_window_size`: give the window the size a new one is made with
/// (`defaultSize`), maximizing it, or restoring a maximized or snapped one
/// first and sizing its client area as `show` sizes a new one; nothing
/// when there is none. The terminals are laid out again, so this never
/// runs inside a core frame (`App.requests`).
pub fn resetSize(self: *Window) void {
    switch (self.defaultSize() orelse return) {
        .maximized => _ = win32.ShowWindow(self.hwnd, win32.SW_MAXIMIZE),
        .initial => |size| {
            if (!self.isRestored()) _ = win32.ShowWindow(self.hwnd, win32.SW_RESTORE);
            // defaultSize found one.
            self.applyInitialSize(self.tab().focused.?, size);
        },
    }
}

/// `resize_window`, which a program asks for (CSI 8 t): resize the window
/// so that `surface`, its one terminal, which fills the client area, is
/// `size` in points, a zero dimension kept as it is, its top-left corner
/// kept and clamped to the work area (`resizeClient`), as macOS does it.
/// Nothing changes when it may not be (`terminalResizable`).
pub fn resizeToTerminal(self: *Window, surface: *Surface, size: apprt.action.ResizeWindow) void {
    if (!self.terminalResizable(surface)) return;
    const scale = surface.getContentScale() catch unreachable;
    const area = self.layoutArea() orelse {
        log.warn("unable to read the client area, window not resized err={}", .{win32.GetLastError()});
        return;
    };
    // The tab bar, if it shows, comes on top of the terminal's size, and
    // its scroll bar beside it.
    _ = resizeClient(
        self.hwnd,
        if (size.width > 0) scaledSize(size.width, scale.x) +| ScrollBar.width(surface) else area.right - area.left,
        (if (size.height > 0) scaledSize(size.height, scale.y) else area.bottom - area.top) +| self.barHeight(),
    );
}

/// The rect for a `width` x `height` window at `x`, `y`, kept inside the
/// work area `work` as macOS keeps a window on screen
/// (`NSWindow.constrainToScreen`): it is moved up or left until it fits, and
/// made smaller only if it is larger than the work area.
pub fn constrainToWorkArea(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    work: win32.RECT,
) win32.RECT {
    const w = @min(width, work.right - work.left);
    const h = @min(height, work.bottom - work.top);
    const left = @max(work.left, @min(x, work.right - w));
    const top = @max(work.top, @min(y, work.bottom - h));
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// Bring the window to the front, restoring it first if it is
/// minimized, as GTK's `gtk.Window.present` does; for `goto_window`,
/// `present_terminal` and a toast's click. With a title prompt open over
/// it, the prompt comes forward with the keyboard focus in its field, not
/// the frame it holds disabled (`TitleDialog.front`).
pub fn present(self: *Window) bool {
    const ok = bringForward(self.hwnd, TitleDialog.front(self));
    TitleDialog.focusField(self);
    return ok;
}

/// For tests: told the window `bringForward` would give SetForegroundWindow,
/// which it then does not call, as `test_set_focus` stands for SetFocus.
pub var test_foreground: if (builtin.is_test) ?*const fn (win32.HWND) void else void =
    if (builtin.is_test) null else {};

/// Restore `frame` if it is minimized, then make `front`, the frame or a
/// window it owns, the foreground window. SetForegroundWindow alone only
/// activates a window: a minimized one stays minimized, and so do the
/// windows it owns, which Windows hides with it.
pub fn bringForward(frame: win32.HWND, front: win32.HWND) bool {
    if (win32.IsIconic(frame).toBool()) {
        // The BOOL is the previous visibility, not success.
        _ = win32.ShowWindow(frame, win32.SW_RESTORE);
    }
    if (builtin.is_test) if (test_foreground) |seen| {
        seen(front);
        return true;
    };

    // SetForegroundWindow returning FALSE is the documented *normal*
    // outcome under Windows' foreground lock -- the calling process is
    // not foreground and has had no recent input -- so hard-coding true
    // here would lie in the common case rather than the rare one.
    return win32.SetForegroundWindow(front).toBool();
}

/// `.toggle_fullscreen`: cover the monitor the window is mostly on, with
/// no frame, or put the window back where and as it was, maximized or not.
/// The overlapped-window styles come off and the window takes the
/// monitor's rect, and the placement saved first brings it back, as
/// Raymond Chen describes it ("How do I switch a window between normal
/// and fullscreen?", The Old New Thing). The terminals are laid out again,
/// from the frame's WM_SIZE and then here for the bar, so this never runs
/// inside a core frame (`App.requests`).
pub fn toggleFullscreen(self: *Window) void {
    const style = win32.GetWindowLongPtrW(self.hwnd, win32.GWL_STYLE);
    const overlapped: isize = win32.WS_OVERLAPPEDWINDOW;
    const reframe = win32.SWP_NOOWNERZORDER | win32.SWP_FRAMECHANGED;

    if (self.fullscreen) |restore| {
        self.fullscreen = null;
        // The bar comes back with the window's frame. Laid out here, not
        // only from WM_SIZE, which does not come when the client area keeps
        // its size (a monitor whose work area is all of it); terminals
        // already in place are not moved again.
        defer self.relayout();
        // With the frame `window-decoration` asks for now, which a toggle
        // while it covered the monitor may have changed.
        _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_STYLE, (style & ~overlapped) | frameStyle(self.isDecorated()));
        // By the placement for a window that was maximized, and for one
        // whose rect no monitor shows any more, as when one is unplugged or
        // a remote session comes back with fewer: SetWindowPlacement moves
        // a placement off every monitor onto one, SetWindowPos would not.
        const maximized = restore.placement.showCmd == win32.SW_SHOWMAXIMIZED;
        const gone = win32.MonitorFromRect(&restore.rect, win32.MONITOR_DEFAULTTONULL) == null;
        if (!maximized and !gone) {
            self.moveTo(restore.rect, win32.SWP_NOZORDER | reframe);
            return;
        }
        _ = win32.SetWindowPlacement(self.hwnd, &restore.placement);
        _ = win32.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | reframe,
        );
        // Windows holds a window that was maximized as maximized all along,
        // and does not always place it again for its new frame: one without
        // a caption stays at the monitor's rect.
        self.refitMaximized(win32.SWP_NOZORDER | reframe);
        return;
    }

    var restore: Restore = .{
        .placement = std.mem.zeroes(win32.WINDOWPLACEMENT),
        .rect = undefined,
    };
    restore.placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (!win32.GetWindowPlacement(self.hwnd, &restore.placement).toBool()) {
        log.warn("cannot go fullscreen: GetWindowPlacement failed err={}", .{win32.GetLastError()});
        return;
    }
    if (!win32.GetWindowRect(self.hwnd, &restore.rect).toBool()) {
        log.warn("cannot go fullscreen: GetWindowRect failed err={}", .{win32.GetLastError()});
        return;
    }
    const monitor = monitorRect(win32.MonitorFromWindow(self.hwnd, win32.MONITOR_DEFAULTTONEAREST)) orelse
        return;

    self.fullscreen = restore;
    _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_STYLE, style & ~overlapped);
    self.moveTo(monitor, reframe);
    // The bar goes, even if the client area kept its size (see above).
    self.relayout();
}

/// Move and size the frame to `rect`, in screen coordinates.
fn moveTo(self: *Window, rect: win32.RECT, flags: win32.UINT) void {
    _ = win32.SetWindowPos(
        self.hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        flags,
    );
}

/// The rect of `monitor`, or null, logged, if it cannot be read.
fn monitorRect(monitor: ?win32.HMONITOR) ?win32.RECT {
    const info = monitorInfo(monitor) orelse return null;
    return info.rcMonitor;
}

/// The rects of `monitor`, or null, logged, if they cannot be read.
fn monitorInfo(monitor: ?win32.HMONITOR) ?win32.MONITORINFO {
    var info: win32.MONITORINFO = std.mem.zeroes(win32.MONITORINFO);
    info.cbSize = @sizeOf(win32.MONITORINFO);
    if (!win32.GetMonitorInfoW(monitor orelse return null, &info).toBool()) {
        log.warn("cannot read the monitor: GetMonitorInfoW failed err={}", .{win32.GetLastError()});
        return null;
    }
    return info;
}

/// Whether the window shows its title bar: its own `window-decoration`
/// (`decoration`), or else the configuration's, is not `none`.
pub fn isDecorated(self: *const Window) bool {
    return switch (self.decoration orelse self.app.config.@"window-decoration") {
        // One here: Windows draws every frame.
        .auto, .client, .server => true,
        .none => false,
    };
}

/// The overlapped-window styles of a frame `decorated` or not. Without
/// decorations only the caption comes off: the sizing border (WS_THICKFRAME)
/// stays, so that the window can still be resized from its edges and keeps
/// the rounded corners and shadow Windows 11 gives such a frame, and so do
/// the window menu and the minimize and maximize boxes.
fn frameStyle(decorated: bool) isize {
    const overlapped: isize = win32.WS_OVERLAPPEDWINDOW;
    const caption: isize = win32.WS_CAPTION;
    return if (decorated) overlapped else overlapped & ~caption;
}

/// `.toggle_window_decorations`, as GTK's (`toggleWindowDecorations`):
/// the window's own setting is dropped if it has one, back to
/// `window-decoration`, or else it takes the other one, `none` if that has
/// decorations and `auto` if not. The frame changes (`applyDecorations`),
/// so this never runs inside a core frame (`App.requests`).
pub fn toggleDecorations(self: *Window) void {
    self.decoration = if (self.decoration != null) null else switch (self.app.config.@"window-decoration") {
        .none => .auto,
        .auto, .client, .server => .none,
    };
    self.applyDecorations();
}

/// Give the frame the styles `isDecorated` asks for, keeping its rect, or a
/// maximized one the work area (`refitMaximized`). A window that covers its
/// monitor has none of them, and takes them when it leaves
/// (`toggleFullscreen`). The client area grows or shrinks by the caption,
/// and the terminals are laid out again from the frame's WM_SIZE, so this
/// never runs inside a core frame (`App.requests`).
pub fn applyDecorations(self: *Window) void {
    if (self.fullscreen != null) return;
    const style = win32.GetWindowLongPtrW(self.hwnd, win32.GWL_STYLE);
    const overlapped: isize = win32.WS_OVERLAPPEDWINDOW;
    const want = (style & ~overlapped) | frameStyle(self.isDecorated());
    if (want == style) return;
    _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_STYLE, want);

    const reframe = win32.SWP_NOZORDER | win32.SWP_NOOWNERZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED;
    _ = win32.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | reframe);
    self.refitMaximized(reframe);
}

/// Give each terminal of every tab the scroll bar the configuration asks
/// for (`ScrollBar.restyle`). Their client areas change, so this never runs
/// inside a core frame (`App.requests`), as `applyDecorations`.
pub fn applyScrollBars(self: *Window) void {
    for (self.tabs.items) |t| {
        var it = t.tree.iterator();
        while (it.next()) |entry| ScrollBar.restyle(entry.view);
    }
}

/// Place a maximized window, not minimized, on its work area again
/// (`maximizedRect`), after its styles changed: Windows does not work out
/// again where a window it already holds maximized goes.
fn refitMaximized(self: *Window, flags: win32.UINT) void {
    if (!win32.IsZoomed(self.hwnd).toBool() or win32.IsIconic(self.hwnd).toBool()) return;
    if (self.maximizedRect()) |rect| self.moveTo(rect, flags);
}

/// The rect a maximized frame takes with its present styles: its
/// monitor's work area grown by the sizing border, which Windows puts off
/// the edges. The border is measured from the window, which must not be
/// minimized, as `applyInitialSize` measures its frame.
fn maximizedRect(self: *Window) ?win32.RECT {
    var window: win32.RECT = undefined;
    if (!win32.GetWindowRect(self.hwnd, &window).toBool()) return null;
    var corner: win32.POINT = .{ .x = window.left, .y = window.top };
    if (!win32.ScreenToClient(self.hwnd, &corner).toBool()) return null;
    const border = -corner.x;
    const info = monitorInfo(win32.MonitorFromWindow(self.hwnd, win32.MONITOR_DEFAULTTONEAREST)) orelse
        return null;
    return .{
        .left = info.rcWork.left - border,
        .top = info.rcWork.top - border,
        .right = info.rcWork.right + border,
        .bottom = info.rcWork.bottom + border,
    };
}

/// WM_WINDOWPOSCHANGING for a frame without decorations. Windows
/// maximizes a frame with no caption over its whole monitor, the taskbar's
/// place included, with its sizing border off the monitor's edges, so a
/// maximized one is moved onto the work area instead (`onWorkArea`), as a
/// framed one is. WM_GETMINMAXINFO cannot ask for that: Windows reads its
/// ptMaxSize as a size on the primary monitor, and adds to it the
/// difference to the monitor the window maximizes on, a larger one's
/// included, when it is no smaller than the primary.
/// Ref: https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-minmaxinfo
fn keepToWorkArea(hwnd: win32.HWND, pos: *win32.WINDOWPOS) void {
    if (pos.flags & (win32.SWP_NOMOVE | win32.SWP_NOSIZE) != 0) return;
    if (!win32.IsZoomed(hwnd).toBool()) return;
    const rect: win32.RECT = .{
        .left = pos.x,
        .top = pos.y,
        .right = pos.x +| pos.cx,
        .bottom = pos.y +| pos.cy,
    };
    const info = monitorInfo(win32.MonitorFromRect(&rect, win32.MONITOR_DEFAULTTONEAREST)) orelse
        return;
    const moved = onWorkArea(rect, info.rcMonitor, info.rcWork) orelse return;
    pos.x = moved.left;
    pos.y = moved.top;
    pos.cx = moved.right - moved.left;
    pos.cy = moved.bottom - moved.top;
}

/// `rect`, a maximized frame's that covers `monitor` with its border off
/// the edges, as far off the edges of `work`, the monitor's work area; null
/// for a rect that does not cover the monitor, which includes one already
/// moved, unless the work area is the whole monitor, when nothing moves.
fn onWorkArea(rect: win32.RECT, monitor: win32.RECT, work: win32.RECT) ?win32.RECT {
    if (rect.left > monitor.left or rect.top > monitor.top or
        rect.right < monitor.right or rect.bottom < monitor.bottom) return null;
    return .{
        .left = work.left - (monitor.left - rect.left),
        .top = work.top - (monitor.top - rect.top),
        .right = work.right + (rect.right - monitor.right),
        .bottom = work.bottom + (rect.bottom - monitor.bottom),
    };
}

/// Whether the window floats above every window that does not
/// (`setFloating`).
pub fn isFloating(self: *const Window) bool {
    const topmost: isize = win32.WS_EX_TOPMOST;
    return win32.GetWindowLongPtrW(self.hwnd, win32.GWL_EXSTYLE) & topmost != 0;
}

/// `float_window`: keep the window above every window that does not
/// float, focused or not, as macOS floats it, or put it back among them.
/// Only its place in the z-order changes, so no terminal is laid out
/// again. False, logged, if it did not change.
pub fn setFloating(self: *Window, on: bool) bool {
    if (!win32.SetWindowPos(
        self.hwnd,
        if (on) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE,
    ).toBool()) {
        log.warn("cannot change whether the window floats err={}", .{win32.GetLastError()});
        return false;
    }
    return true;
}

/// `.toggle_maximize`: maximize the window, or restore it, by whether it
/// is maximized now, as GTK decides (`surfaceToggleMaximize`): the user
/// also maximizes and restores it with the caption buttons, a double click
/// and Win+Up and Win+Down.
pub fn toggleMaximize(self: *Window) void {
    // ShowWindow's BOOL is the window's *previous* visibility, not
    // whether the call succeeded, so it deliberately is not
    // propagated: a window that was hidden returns zero from a
    // call that worked perfectly.
    _ = win32.ShowWindow(
        self.hwnd,
        if (win32.IsZoomed(self.hwnd).toBool()) win32.SW_RESTORE else win32.SW_MAXIMIZE,
    );
}

/// WM_DPICHANGED's second half: lParam carries the suggested new window
/// rect. Not honoring it leaves the window the wrong physical size on the
/// new monitor, so it is applied verbatim. SetWindowPos sends WM_SIZE
/// synchronously, so the surfaces must have the new scale before this.
pub fn applySuggestedRect(hwnd: win32.HWND, lparam: win32.LPARAM) void {
    const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    _ = win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    );
}

/// Whether a WM_SYSCOMMAND is a bare Alt or F10 released without being
/// consumed: it arrives as SC_KEYMENU with lParam 0 and would put the
/// window into menu mode, swallowing the next keystroke. The window has no
/// menu bar, so that mode is never wanted. Alt+Space arrives with lParam
/// ' ' and still opens the window menu.
pub fn isBareKeyMenu(wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    return wparam & win32.SC_MASK == win32.SC_KEYMENU and lparam == 0;
}

/// A window's share of `App.modal_loop_depth`: the system modal loops
/// (size/move, menu) it has entered and not yet reported leaving. A window
/// destroyed inside its own loop never receives the matching WM_EXIT*, so
/// its share is returned with `release` instead.
pub const ModalLoops = struct {
    count: u32 = 0,

    /// WM_ENTERSIZEMOVE, WM_ENTERMENULOOP.
    pub fn enter(self: *ModalLoops, app_depth: *u32) void {
        self.count += 1;
        app_depth.* += 1;
    }

    /// WM_EXITSIZEMOVE, WM_EXITMENULOOP. Only undoes what this window added,
    /// so a stray exit can never take another window's loop out of the
    /// count.
    pub fn exit(self: *ModalLoops, app_depth: *u32) void {
        if (self.count == 0) return;
        self.count -= 1;
        app_depth.* -|= 1;
    }

    /// WM_DESTROY: give back whatever this window still holds.
    pub fn release(self: *ModalLoops, app_depth: *u32) void {
        app_depth.* -|= self.count;
        self.count = 0;
    }

    /// Whether this window is inside one of its loops.
    pub fn inLoop(self: ModalLoops) bool {
        return self.count != 0;
    }
};

test "win32: an initial size is kept inside the monitor work area" {
    const testing = std.testing;
    const RECT = win32.RECT;

    // 1920x1080 with a 40 px taskbar at the bottom.
    const work: RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };

    // Fits where it is: unchanged.
    try testing.expectEqual(
        RECT{ .left = 100, .top = 50, .right = 900, .bottom = 650 },
        constrainToWorkArea(100, 50, 800, 600, work),
    );

    // Fits the work area but not below and right of its origin: moved up
    // and left, at the size asked for.
    try testing.expectEqual(
        RECT{ .left = 1120, .top = 40, .right = 1920, .bottom = 1040 },
        constrainToWorkArea(1300, 80, 800, 1000, work),
    );

    // Larger than the work area, including the saturated size of an
    // enormous `window-width`: the whole work area.
    try testing.expectEqual(work, constrainToWorkArea(100, 50, 2500, 1200, work));
    try testing.expectEqual(work, constrainToWorkArea(
        100,
        50,
        std.math.maxInt(i32),
        std.math.maxInt(i32),
        work,
    ));

    // A monitor left of and above the primary, with the taskbar on its
    // left edge: the work area does not start at zero.
    try testing.expectEqual(
        RECT{ .left = -1232, .top = 524, .right = -632, .bottom = 824 },
        constrainToWorkArea(-1260, 700, 600, 300, .{
            .left = -1232,
            .top = -200,
            .right = 0,
            .bottom = 824,
        }),
    );
}

test "win32: a tab dropped outside its window is placed with its label at the pointer" {
    const testing = std.testing;
    const RECT = win32.RECT;
    const work: RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    // An 800x600 frame whose client area starts 8 px in and 31 px down.
    const frame: RECT = .{ .left = 100, .top = 50, .right = 900, .bottom = 650 };
    const client: win32.POINT = .{ .x = 108, .y = 81 };

    // Grabbed 30 px into the label and 12 down, dropped at 500, 400: the
    // client point 30, 12 goes there, the size kept.
    const placed = dropRect(frame, client, .{ .at = .{ .x = 500, .y = 400 }, .grab = .{ .x = 30, .y = 12 } }, work);
    try testing.expectEqual(RECT{ .left = 462, .top = 357, .right = 1262, .bottom = 957 }, placed);
    try testing.expectEqual(500, placed.left + (client.x - frame.left) + 30);
    try testing.expectEqual(400, placed.top + (client.y - frame.top) + 12);

    // Near the work area's ends: kept inside it, as a new window is.
    try testing.expectEqual(
        RECT{ .left = 1120, .top = 440, .right = 1920, .bottom = 1040 },
        dropRect(frame, client, .{ .at = .{ .x = 1900, .y = 1030 }, .grab = .{ .x = 30, .y = 12 } }, work),
    );
    try testing.expectEqual(
        RECT{ .left = 0, .top = 0, .right = 800, .bottom = 600 },
        dropRect(frame, client, .{ .at = .{ .x = 0, .y = 0 }, .grab = .{ .x = 30, .y = 12 } }, work),
    );
}

test "win32: a maximized frame without decorations is moved onto the work area" {
    const testing = std.testing;
    const RECT = win32.RECT;

    // Windows' rect for a frame without a caption, 8 px of sizing border,
    // maximized on a 1920x1080 primary with a 40 px taskbar at the bottom:
    // the client area is the work area, the border as far off its edges.
    const primary: RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const maximized: RECT = .{ .left = -8, .top = -8, .right = 1928, .bottom = 1088 };
    try testing.expectEqual(
        RECT{ .left = -8, .top = -8, .right = 1928, .bottom = 1048 },
        onWorkArea(maximized, primary, .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 }).?,
    );

    // On a larger 2560x1440 monitor right of it, with the taskbar on its
    // left edge: the work area there, whatever the primary's size.
    const larger: RECT = .{ .left = 1920, .top = 0, .right = 4480, .bottom = 1440 };
    const work: RECT = .{ .left = 1968, .top = 0, .right = 4480, .bottom = 1440 };
    const moved = onWorkArea(
        .{ .left = 1912, .top = -8, .right = 4488, .bottom = 1448 },
        larger,
        work,
    ).?;
    try testing.expectEqual(
        RECT{ .left = 1960, .top = -8, .right = 4488, .bottom = 1448 },
        moved,
    );

    // On the primary, with the taskbar on the right edge, or along the top.
    try testing.expectEqual(
        RECT{ .left = -8, .top = -8, .right = 1880, .bottom = 1088 },
        onWorkArea(maximized, primary, .{ .left = 0, .top = 0, .right = 1872, .bottom = 1080 }).?,
    );
    try testing.expectEqual(
        RECT{ .left = -8, .top = 40, .right = 1928, .bottom = 1088 },
        onWorkArea(maximized, primary, .{ .left = 0, .top = 48, .right = 1920, .bottom = 1080 }).?,
    );

    // A rect already moved is not moved again, nor one that does not
    // cover its monitor at all.
    try testing.expectEqual(null, onWorkArea(moved, larger, work));
    try testing.expectEqual(null, onWorkArea(
        .{ .left = 2000, .top = 100, .right = 2800, .bottom = 700 },
        larger,
        work,
    ));

    // With no taskbar on the monitor, nothing moves.
    const covering: RECT = .{ .left = 1912, .top = -8, .right = 4488, .bottom = 1448 };
    try testing.expectEqual(covering, onWorkArea(covering, larger, larger).?);
}

/// For the layout tests: a view with a name and no reference count.
const TestPane = struct {
    name: u8,

    pub fn ref(self: *TestPane) *TestPane {
        return self;
    }

    pub fn unref(self: *TestPane) void {
        _ = self;
    }
};

const TestTree = SplitTree(TestPane);

/// What `layout` reports, kept for the layout tests.
const TestLayout = struct {
    panes: [8]Pane = undefined,
    pane_count: usize = 0,
    dividers: [8]win32.RECT = undefined,
    divider_count: usize = 0,
    hiddens: [8]*TestPane = undefined,
    hidden_count: usize = 0,

    const Pane = struct { view: *TestPane, rect: win32.RECT };

    pub fn pane(self: *TestLayout, view: *TestPane, rect: win32.RECT) void {
        self.panes[self.pane_count] = .{ .view = view, .rect = rect };
        self.pane_count += 1;
    }

    pub fn divider(self: *TestLayout, handle: TestTree.Node.Handle, line: win32.RECT, across: bool, area: win32.RECT) void {
        _ = handle;
        _ = across;
        _ = area;
        self.dividers[self.divider_count] = line;
        self.divider_count += 1;
    }

    pub fn hidden(self: *TestLayout, view: *TestPane) void {
        self.hiddens[self.hidden_count] = view;
        self.hidden_count += 1;
    }

    fn rectOf(self: *const TestLayout, view: *const TestPane) win32.RECT {
        for (self.panes[0..self.pane_count]) |p| {
            if (p.view == view) return p.rect;
        }
        unreachable;
    }

    /// The panes and dividers cover `area` exactly once: every rect lies
    /// inside it, no two overlap, and together they are as large as it.
    fn expectTiles(self: *const TestLayout, area: win32.RECT) !void {
        var rects: [16]win32.RECT = undefined;
        var n: usize = 0;
        for (self.panes[0..self.pane_count]) |p| {
            rects[n] = p.rect;
            n += 1;
        }
        for (self.dividers[0..self.divider_count]) |d| {
            rects[n] = d;
            n += 1;
        }
        var covered: i64 = 0;
        for (rects[0..n], 0..) |a, i| {
            try std.testing.expect(a.left >= area.left and a.right <= area.right);
            try std.testing.expect(a.top >= area.top and a.bottom <= area.bottom);
            try std.testing.expect(a.left <= a.right and a.top <= a.bottom);
            covered += @as(i64, a.right - a.left) * (a.bottom - a.top);
            for (rects[i + 1 .. n]) |b| {
                const overlap = a.left < b.right and b.left < a.right and
                    a.top < b.bottom and b.top < a.bottom;
                try std.testing.expect(!overlap);
            }
        }
        try std.testing.expectEqual(
            @as(i64, area.right - area.left) * (area.bottom - area.top),
            covered,
        );
    }
};

/// `tree` with `pane` split off `at` in `direction`.
fn testSplit(
    tree: *const TestTree,
    at: TestTree.Node.Handle,
    direction: TestTree.Split.Direction,
    ratio: f16,
    pane: *TestPane,
) !TestTree {
    const alloc = std.testing.allocator;
    var single: TestTree = try .init(alloc, pane);
    defer single.deinit();
    return tree.split(alloc, at, direction, ratio, &single);
}

test "win32: dividers take their colour from the config or the background" {
    const alloc = std.testing.allocator;
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    // The default dark background, 0x282C34: 40% darker.
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0x18, .g = 0x1A, .b = 0x1F },
        dividerColor(&config),
    );

    // A light one: 8% darker.
    config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0xEB, .g = 0xEB, .b = 0xEB },
        dividerColor(&config),
    );

    // Set: used as it is.
    config.@"split-divider-color" = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 },
        dividerColor(&config),
    );
}

test "win32: the title bar follows window-theme" {
    const alloc = std.testing.allocator;
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    // Forced, whatever the system's mode.
    for ([_]apprt.ColorScheme{ .light, .dark }) |system| {
        config.@"window-theme" = .light;
        try std.testing.expect(!frameDark(&config, system));
        config.@"window-theme" = .dark;
        try std.testing.expect(frameDark(&config, system));
        config.@"window-theme" = .system;
        try std.testing.expectEqual(system == .dark, frameDark(&config, system));
    }

    // auto and ghostty: the background, whatever the system's mode. The
    // default one, 0x282C34, is dark.
    for ([_]configpkg.Config.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        config.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
        try std.testing.expect(frameDark(&config, .light));
        config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        try std.testing.expect(!frameDark(&config, .dark));
    }

    // With a light and a dark theme, which Config.finalize marks in the
    // conditional set: the system's mode, whatever the background. finalize
    // makes such an auto system ("theme specifying light/dark changes
    // window-theme from auto"); ghostty stays as it is.
    config._conditional_set.insert(.theme);
    for ([_]configpkg.Config.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        try std.testing.expect(frameDark(&config, .dark));
        config.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
        try std.testing.expect(!frameDark(&config, .light));
    }
}

test "win32: only the app mode setting is a color set change" {
    // Copies, as Windows passes the name in a buffer of its own: the
    // literal would be the one the function compares with.
    var name = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet").*;
    try std.testing.expect(isColorSetChange(@bitCast(@intFromPtr(&name))));
    var other = std.unicode.utf8ToUtf16LeStringLiteral("Policy").*;
    try std.testing.expect(!isColorSetChange(@bitCast(@intFromPtr(&other))));
    var longer = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSetX").*;
    try std.testing.expect(!isColorSetChange(@bitCast(@intFromPtr(&longer))));
    try std.testing.expect(!isColorSetChange(0));
}

test "win32: a divider is a pixel at 96 DPI, scaled to the nearest pixel" {
    // DPI, width: 125% rounds down, 150% and 250% round up.
    for ([_][2]u32{
        .{ 0, 1 },   .{ 96, 1 },  .{ 120, 1 }, .{ 144, 2 },
        .{ 168, 2 }, .{ 192, 2 }, .{ 240, 3 }, .{ 288, 3 },
    }) |c| {
        try std.testing.expectEqual(@as(i32, @intCast(c[1])), dividerWidth(c[0]));
    }
}

test "win32: a zoomed terminal fills the window alone" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var only_b: TestTree = try .init(alloc, &b);
    defer only_b.deinit();
    var tree = try only_a.split(alloc, .root, .right, 0.5, &only_b);
    defer tree.deinit();
    tree.zoom(tree.locate(&b).?);

    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 100, .bottom = 50 };
    var got: TestLayout = .{};
    layout(&tree, area, 2, &got);
    try std.testing.expectEqual(1, got.pane_count);
    try std.testing.expectEqual(&b, got.panes[0].view);
    try std.testing.expectEqual(area, got.panes[0].rect);
    try std.testing.expectEqual(0, got.divider_count);
    try std.testing.expectEqual(1, got.hidden_count);
    try std.testing.expectEqual(&a, got.hiddens[0]);
}

test "win32: split terminals and their dividers tile the window" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var c: TestPane = .{ .name = 'c' };

    // a | b, then b over c.
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var ab = try testSplit(&only_a, .root, .right, 0.5, &b);
    defer ab.deinit();
    var tree = try testSplit(&ab, ab.locate(&b).?, .down, 0.3, &c);
    defer tree.deinit();

    // Odd sizes, so that neither split divides evenly.
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 1001, .bottom = 601 };
    var got: TestLayout = .{};
    layout(&tree, area, 2, &got);
    try std.testing.expectEqual(3, got.pane_count);
    try std.testing.expectEqual(2, got.divider_count);
    try got.expectTiles(area);

    // 999 pixels left for the panes; half of it rounds up.
    try std.testing.expectEqual(500, got.rectOf(&a).right);
    try std.testing.expectEqual(502, got.rectOf(&b).left);
    // 599 left between b and c; 0.3 of it is 179.7.
    try std.testing.expectEqual(180, got.rectOf(&b).bottom);
    try std.testing.expectEqual(182, got.rectOf(&c).top);

    // Within a window that does not start at the origin, too.
    const moved: win32.RECT = .{ .left = 7, .top = 3, .right = 108, .bottom = 54 };
    var got_moved: TestLayout = .{};
    layout(&tree, moved, 1, &got_moved);
    try got_moved.expectTiles(moved);
}

test "win32: a split at either end gives one side all of it" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var tree = try testSplit(&only_a, .root, .down, 0.5, &b);
    defer tree.deinit();
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 80, .bottom = 50 };

    for ([_]f16{ 0, 1 }) |ratio| {
        tree.resizeInPlace(.root, ratio);
        var got: TestLayout = .{};
        layout(&tree, area, 1, &got);
        try got.expectTiles(area);
        const a_height = got.rectOf(&a).bottom - got.rectOf(&a).top;
        const b_height = got.rectOf(&b).bottom - got.rectOf(&b).top;
        try std.testing.expectEqual(@as(i32, if (ratio == 0) 0 else 49), a_height);
        try std.testing.expectEqual(@as(i32, if (ratio == 0) 49 else 0), b_height);
    }
}

test "win32: a divider wider than its split takes all of it" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var tree = try testSplit(&only_a, .root, .right, 0.5, &b);
    defer tree.deinit();

    // A window dragged down to almost nothing at a high DPI.
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 3, .bottom = 40 };
    var got: TestLayout = .{};
    layout(&tree, area, 10, &got);
    try got.expectTiles(area);
    try std.testing.expectEqual(0, got.rectOf(&a).right - got.rectOf(&a).left);
    try std.testing.expectEqual(0, got.rectOf(&b).right - got.rectOf(&b).left);
}

test "win32: the pixel layout agrees with the split tree's own" {
    // tree.spatial() places the same panes in a 1x1 square, without
    // dividers. Scaled up, each pane must be within its dividers and a
    // pixel of rounding per split above it.
    const alloc = std.testing.allocator;
    var panes: [4]TestPane = .{ .{ .name = 'a' }, .{ .name = 'b' }, .{ .name = 'c' }, .{ .name = 'd' } };
    var t0: TestTree = try .init(alloc, &panes[0]);
    defer t0.deinit();
    var t1 = try testSplit(&t0, .root, .right, 0.6, &panes[1]);
    defer t1.deinit();
    var t2 = try testSplit(&t1, t1.locate(&panes[0]).?, .down, 0.25, &panes[2]);
    defer t2.deinit();
    var tree = try testSplit(&t2, t2.locate(&panes[1]).?, .left, 0.7, &panes[3]);
    defer tree.deinit();

    var sp = try tree.spatial(alloc);
    defer sp.deinit(alloc);

    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const divider = 2;
    var got: TestLayout = .{};
    layout(&tree, area, divider, &got);
    try got.expectTiles(area);

    // Two splits above every pane here.
    const tolerance: f32 = 2 * (divider + 1);
    const w: f32 = @floatFromInt(area.right);
    const h: f32 = @floatFromInt(area.bottom);
    for (got.panes[0..got.pane_count]) |p| {
        const slot = sp.slots[tree.locate(p.view).?.idx()];
        const want = [4]f32{
            @as(f32, slot.x) * w,
            @as(f32, slot.y) * h,
            (@as(f32, slot.x) + @as(f32, slot.width)) * w,
            (@as(f32, slot.y) + @as(f32, slot.height)) * h,
        };
        const have = [4]i32{ p.rect.left, p.rect.top, p.rect.right, p.rect.bottom };
        for (want, have) |x, y| {
            try std.testing.expect(@abs(x - @as(f32, @floatFromInt(y))) <= tolerance);
        }
    }
}

test "win32: a new split starts where the layout puts it" {
    // `split` creates the new terminal at the size it will have, from the
    // parent's place alone; the layout of the tree with it, at the ratio
    // `split` gives it, must agree, or it would be resized as soon as it is
    // shown.
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    const area: win32.RECT = .{ .left = 3, .top = 5, .right = 1004, .bottom = 606 };
    const divider = 2;

    for ([_]TestTree.Split.Direction{ .left, .right, .up, .down }) |where| {
        var tree = try testSplit(&only_a, .root, where, new_split_ratio, &b);
        defer tree.deinit();
        var got: TestLayout = .{};
        layout(&tree, area, divider, &got);
        try std.testing.expectEqual(got.rectOf(&b), newPaneArea(area, where, divider, 1).?);
    }
}

test "win32: a split needs room for a cell on each side" {
    // A terminal with no room would take the focus and show nothing:
    // splitting the newest one again and again ends at no width at all.
    const divider = 2;
    const cell = 10;
    // 22 wide: 10 on each side of the divider, just enough.
    const fits: win32.RECT = .{ .left = 0, .top = 0, .right = 22, .bottom = 300 };
    for ([_]TestTree.Split.Direction{ .left, .right }) |where| {
        try std.testing.expect(newPaneArea(fits, where, divider, cell) != null);
    }
    // 21 wide: one side gets 9.
    const narrow: win32.RECT = .{ .left = 0, .top = 0, .right = 21, .bottom = 300 };
    for ([_]TestTree.Split.Direction{ .left, .right }) |where| {
        try std.testing.expect(newPaneArea(narrow, where, divider, cell) == null);
    }
    // Across the other axis, the height counts.
    const short: win32.RECT = .{ .left = 0, .top = 0, .right = 300, .bottom = 21 };
    for ([_]TestTree.Split.Direction{ .up, .down }) |where| {
        try std.testing.expect(newPaneArea(short, where, divider, cell) == null);
    }
    try std.testing.expect(newPaneArea(short, .right, divider, cell) != null);
}

test "win32: a resize is device-independent pixels over the window" {
    // 40 over 1000 pixels: 4% at 96 DPI, 6% at 144, 8% at 192. Left and up
    // are negative, and more than the window is all of it.
    for ([_]struct { dpi: u32, share: f32 }{
        .{ .dpi = 96, .share = 0.04 },
        .{ .dpi = 144, .share = 0.06 },
        .{ .dpi = 192, .share = 0.08 },
    }) |c| {
        try std.testing.expectApproxEqAbs(c.share, @as(f32, resizeShare(40, c.dpi, 1000, .right)), 0.0005);
        try std.testing.expectApproxEqAbs(-c.share, @as(f32, resizeShare(40, c.dpi, 1000, .up)), 0.0005);
    }
    try std.testing.expectEqual(@as(f16, 1), resizeShare(std.math.maxInt(u16), 96, 1000, .down));
    try std.testing.expectEqual(@as(f16, -1), resizeShare(std.math.maxInt(u16), 96, 1000, .left));
}

test "win32: a resize keeps each terminal its own cell where it shrinks" {
    // b's font has cells 50 pixels wide and 20 high; a has no core, so a
    // pixel will do for it. Over 200 pixels and a divider, b may shrink
    // across to 50 but not to 40, and down to 30, more than its 20.
    const s = struct {
        var a: Surface = undefined;
        var b: Surface = undefined;
    };
    s.a.core_state = .none;
    s.b.core_state = .live;
    s.b.core_surface.size.cell = .{ .width = 50, .height = 20 };

    var row = try testPair(&s.a, &s.b, .right);
    defer row.deinit();
    const wide: win32.RECT = .{ .left = 0, .top = 0, .right = 201, .bottom = 100 };
    try std.testing.expect(!try keepsAt(&row, 0.8, wide));
    try std.testing.expect(try keepsAt(&row, 0.75, wide));

    var column = try testPair(&s.a, &s.b, .down);
    defer column.deinit();
    const tall: win32.RECT = .{ .left = 0, .top = 0, .right = 100, .bottom = 201 };
    try std.testing.expect(try keepsAt(&column, 0.85, tall));
    try std.testing.expect(!try keepsAt(&column, 0.95, tall));
}

/// For tests: `a` with `b` split off it in `where`, at half.
fn testPair(a: *Surface, b: *Surface, where: Tree.Split.Direction) !Tree {
    const alloc = std.testing.allocator;
    var base: Tree = try .init(alloc, a);
    defer base.deinit();
    var single: Tree = try .init(alloc, b);
    defer single.deinit();
    return base.split(alloc, .root, where, 0.5, &single);
}

/// For tests: whether `keepsCells` lets `tree` have its root split at
/// `ratio` in `area`, with a one-pixel divider.
fn keepsAt(tree: *const Tree, ratio: f16, area: win32.RECT) !bool {
    var new = try tree.clone(std.testing.allocator);
    defer new.deinit();
    new.resizeInPlace(.root, ratio);
    return keepsCells(tree, &new, area, 1);
}

test "win32: modal loops are counted per window and returned on destroy" {
    // The app ticks the core from its window procedure while any window is
    // in a size/move or menu loop (WM_GHOSTTY_WAKEUP), so the count must
    // not leak past a loop's end or a window's. One message-only window
    // stands in for both frames: these handlers never use it.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    var app: App = undefined;
    app.modal_loop_depth = 0;
    // Read by the frame's procedure before any other message.
    app.taskbar_created = 0;

    var a: Window = undefined;
    var b: Window = undefined;
    for ([_]*Window{ &a, &b }) |window| {
        window.app = &app;
        window.hwnd = hwnd;
        window.tabs = .empty;
        window.selected = 0;
        window.modal_loops = .{};
    }

    _ = a.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    _ = a.handleMessage(hwnd, win32.WM_ENTERMENULOOP, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    // An exit with no loop of its own takes nothing from another window.
    _ = b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    _ = b.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    try std.testing.expectEqual(3, app.modal_loop_depth);

    // Destroyed inside both of its loops, so their exits never come.
    _ = a.handleMessage(hwnd, win32.WM_DESTROY, 0, 0);
    try std.testing.expectEqual(1, app.modal_loop_depth);

    _ = b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
    _ = b.handleMessage(hwnd, win32.WM_EXITMENULOOP, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
}

test "win32: presenting a minimized window restores it" {
    // A top-level window created minimized and hidden stands in for a
    // frame: `bringForward`, behind `present`, only uses the handles.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        win32.WS_OVERLAPPEDWINDOW | win32.WS_MINIMIZE,
        0,
        0,
        200,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);
    try std.testing.expect(win32.IsIconic(hwnd).toBool());

    _ = bringForward(hwnd, hwnd);
    try std.testing.expect(!win32.IsIconic(hwnd).toBool());
}
