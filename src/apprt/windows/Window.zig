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
const CoreSurface = @import("../../Surface.zig");
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
const Transparency = @import("Transparency.zig");
const CommandPalette = @import("CommandPalette.zig");
const TabOverview = @import("TabOverview.zig");
const SplitTree = @import("../../datastruct/main.zig").SplitTree;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const WM_GHOSTTY_DESTROY = @import("App.zig").WM_GHOSTTY_DESTROY;
const WM_GHOSTTY_QUICK_HIDE = @import("App.zig").WM_GHOSTTY_QUICK_HIDE;
const postTeardown = @import("App.zig").postTeardown;
const confirm = @import("dialog.zig").confirm;
const Question = @import("dialog.zig").Question;

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

/// What `create` makes: a terminal window, or the quick terminal
/// (`quick`).
pub const Kind = enum { normal, quick };

/// What `toggle_visibility` did to a window that nothing has undone since
/// (`hidden`).
pub const Hidden = enum {
    no,
    /// Hidden by the toggle, which shows it again.
    hidden,
    /// Hidden by it while in the foreground: the one its show brings
    /// forward.
    front,
};

app: *App,

/// The frame. Written from WM_NCCREATE; a message before it
/// (WM_GETMINMAXINFO, for one) finds no pointer and goes to
/// DefWindowProcW (`wndProc`), so it is valid in every handler that reads
/// it.
hwnd: win32.HWND,

/// The window's tabs, in the order they show; never empty from `create`
/// until the window is freed (`deinit`). Each is allocated, so that a
/// pointer to one stays put.
tabs: std.ArrayList(*Tab),

/// The index in `tabs` of the tab the window shows.
selected: usize,

/// The window's own title, from `set_window_title` or its title prompt,
/// which its caption shows in place of its shown tab's (`showTitle`);
/// null while it has none. GTK's window title override
/// (`setTitleOverride` in src/apprt/gtk/class/window.zig).
title_override: ?[:0]u8,

/// The tab bar over the terminals, shown as `window-show-tab-bar` asks
/// (`barShown`).
bar: TabBar.Bar,

/// A close of the whole window is being asked about, or was agreed to and
/// its teardown posted (`requestClose`). Stops a second WM_CLOSE or
/// close_window from asking or posting twice. Cleared when the user
/// declines or the post fails; otherwise the teardown frees the window.
closing: bool,

/// Whether the question that `closing` waits on is still open
/// (`requestClose`): the user has not said yes, and may yet say no. What
/// is saved of the windows counts such a window as open
/// (`Session.snapshot`), as a session's end can come while it asks.
asking: bool = false,

/// WM_GHOSTTY_DESTROY arrived while teardown was not allowed; re-posted by
/// `App.repostDeferredDestroys`, as a terminal's is
/// (`Surface.destroy_deferred`).
destroy_deferred: bool,

/// WM_DPICHANGED is applying Windows' suggested rect, which
/// `minTrackSize` leaves as it is; `growToLeast` keeps the least after it.
dpi_changing: bool,

/// Whether the title bar was last made dark (`applyTheme`). A new frame
/// has a light one.
dark_frame: bool,

/// Whether the frame lets the desktop through where its terminals'
/// background is translucent (Transparency.zig): set as the frame is made
/// (`makeTransparent`), never changed. Its terminals' renderers are asked
/// to present with alpha (`Surface.presentsAlpha`), which each does unless
/// it could not make a composition chain (`renderer.D3D11`), and the
/// terminals paint black under their chains; its chrome is layered. A
/// terminal only ever moves to a frame of the same kind (`App.moveTabAt`).
transparent: bool,

/// The system backdrop DWM was last given for the frame
/// (`Transparency.applyBlur`): acrylic while `background-blur` is on in a
/// transparent window. A new frame has the default.
backdrop: Transparency.Backdrop,

/// Where and how the window was before it covered its monitor, to put it
/// back (`toggleFullscreen`); null while it does not.
fullscreen: ?Restore,

/// This window's own `window-decoration`, from
/// `toggle_window_decorations`, or null while it follows the
/// configuration's, as GTK keeps one per window (`toggleDecorations`).
decoration: ?configpkg.WindowDecoration,

/// The quick terminal (`App.quick`), which `toggle_quick_terminal` shows
/// and hides (`showQuick`, `hideQuick`): a pop-up on a monitor's edge
/// (`quickPlace`), in neither the taskbar nor Alt+Tab (WS_EX_TOOLWINDOW),
/// above every window that is not topmost while it shows. It keeps the
/// place and size it is given: maximizing, fullscreen, decorations,
/// floating and the sizes from the configuration or a program leave it as
/// it is, as GTK refuses a quick terminal's resizes. Set when it is made,
/// never changed.
quick: bool,

/// For the quick terminal: the window that was in the foreground as it
/// last showed, unless that was one of Ghostty's (`ofApp`), to give the
/// foreground back to as a toggle hides it (`hideQuick`), as macOS gives
/// it back to the app it came from. Forgotten once another of Ghostty's
/// windows takes the activation from it (`quickDeactivated`).
quick_return: ?win32.HWND,

/// For the quick terminal: its show or hide animation while one runs
/// (`QuickAnimation`), else null.
quick_animation: ?QuickAnimation,

/// Whether `toggle_visibility` hid this window (`hideForToggle`), so that
/// its next show shows it again (`App.toggleVisibility`). Forgotten once
/// the window is restored, or the quick terminal shown, by the toggle or
/// by the user: one the user then minimizes is the user's to restore.
hidden: Hidden,

/// This window's share of `App.modal_loop_depth`; see `ModalLoops`.
modal_loops: ModalLoops,

/// A drag of the frame's border in steps (`window-step-resize`): what its
/// sizes count from and step by, from the drag's first WM_SIZING
/// (`stepSizing`). WM_ENTERSIZEMOVE forgets the last drag's, and a cell
/// that changes forgets this one's (`App.cellSize`).
step_drag: ?StepDrag,

/// The bounds Windows itself keeps a drag of this frame's border within,
/// as its last WM_GETMINMAXINFO carried them, before `minTrackSize` raised
/// the least. A drag in steps keeps within them too (`stepDragNow`).
system_track: TrackBounds,

/// Explorer said the frame's taskbar button exists (`App.taskbar_created`),
/// which ITaskbarList3 asks to wait for (`showProgress`).
taskbar_button: bool,

/// Disabled by `App.beginPrompt` for a prompt in another window, or left
/// disabled by a title prompt that closed while a prompt was open
/// (`TitleDialog.close`), for `App.endPrompt` to enable again.
prompt_disabled: bool,

/// The quick terminal, taken out of the band of windows always on top by
/// `App.beginPrompt` for a prompt it does not own, for `App.endPrompt` to
/// put back.
prompt_lowered: bool,

/// The window's title prompt, open or not (`TitleDialog`), which holds the
/// frame disabled while it is open.
title_prompt: TitleDialog.Prompt,

/// The Kitty clipboard prompt asked for from one of the window's
/// terminals, while it is open (`ClipboardDialog.ask`), whose title bar
/// `applyTheme` gives the frame's mode.
clipboard_prompt: ?win32.HWND,

/// The window's command palette, open or not (`CommandPalette`).
palette: CommandPalette.Palette,
/// The window's tab overview, open or not (`TabOverview`).
overview: TabOverview.Overview,

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
    t.* = .{ .id = Tab.newId() };
    self.tabs.appendAssumeCapacity(t);
    return t;
}

/// Free what the window holds: its tabs (`deinitTabs`) and its title.
pub fn deinit(self: *Window, alloc: Allocator) void {
    self.deinitTabs(alloc);
    if (self.title_override) |title| alloc.free(title);
}

/// Free the tabs, with what their trees still hold: nothing once the
/// frame's WM_DESTROY has run.
pub fn deinitTabs(self: *Window, alloc: Allocator) void {
    for (self.tabs.items) |t| freeTab(alloc, t);
    self.tabs.deinit(alloc);
}

/// Free `t`, its tree and its title. The terminals its tree names are not
/// touched: they are the app's (`App.surfaces`), and go with their frame.
pub fn freeTab(alloc: Allocator, t: *Tab) void {
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

/// What the window is titled after while `t` is shown, unless it has a
/// title of its own (`title_override`), and its tab's label: its title
/// from `set_tab_title` or the tab's title prompt, or else its focused
/// terminal's (`Surface.effectiveTitle`), as GTK's tab computes its title.
pub fn tabTitle(t: *const Tab) ?[:0]const u8 {
    if (t.title_override) |title| return title;
    const surface = t.focused orelse return null;
    return surface.effectiveTitle();
}

/// GTK's prefix to a ringing terminal's title (`bell-features` `title`),
/// src/apprt/gtk/class/tab.zig:522.
pub const bell_prefix = "🔔 ";

/// What `t`'s label shows, and the window's caption while `t` is shown
/// and the window has no title of its own, in UTF-16: its title
/// (`tabTitle`), or "Ghostty" while it has none, after `bell_prefix`
/// while its focused terminal's bell rings (`Surface.bell_ringing`) and
/// `bell-features` has `title`, as GTK computes its tab's title. The
/// caller frees it.
///
/// Invalid UTF-8 is shown as U+FFFD, as macOS does (`Surface.setTitle`).
pub fn shownTitle(self: *const Window, alloc: std.mem.Allocator, t: *const Tab) ![:0]u16 {
    const text = try self.labelText(alloc, t);
    defer alloc.free(text);
    return wideFromUtf8(alloc, text);
}

/// `shownTitle`'s text as it is kept, in UTF-8, for the tab overview's
/// card, which shows and filters on what the bar's label says. The caller
/// frees it.
pub fn labelText(self: *const Window, alloc: std.mem.Allocator, t: *const Tab) ![]u8 {
    const title = tabTitle(t) orelse "Ghostty";
    const ringing = if (t.focused) |s| s.bell_ringing else false;
    if (!ringing or !self.app.config.@"bell-features".title) return alloc.dupe(u8, title);
    return std.mem.concat(alloc, u8, &.{ bell_prefix, title });
}

/// Put `surface`, a new terminal not yet shown, in a tab of its own after
/// the shown one or at the end, as `window-new-tab-position` asks; its
/// index. The tab is not shown yet (`selectTab`).
pub fn insertTab(self: *Window, surface: *Surface) !usize {
    return self.insertTabAt(surface, .configured);
}

/// Where a new tab goes among the others.
pub const TabPlace = enum {
    /// Where `window-new-tab-position` asks.
    configured,
    /// After them all: a saved window's tabs come back in their order.
    end,
};

/// `insertTab`, at `place`.
pub fn insertTabAt(self: *Window, surface: *Surface, place: TabPlace) !usize {
    const t = try self.tabFor(surface);
    errdefer comptime unreachable;
    const at = switch (place) {
        .configured => switch (self.app.config.@"window-new-tab-position") {
            .current => self.selected + 1,
            .end => self.tabs.items.len,
        },
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
    t.* = .{ .id = Tab.newId(), .tree = try .init(alloc, surface), .focused = surface };
    return t;
}

/// A new terminal, made with `opts` at the size of the client area, in a
/// tab of its own at `place` (`insertTabAt`); the tab's index. Hidden
/// until the tab is shown (`selectTab`), once the app owns the terminal
/// (`App.newTab`).
pub fn newTab(self: *Window, opts: Surface.Options, place: TabPlace) !usize {
    const area = self.newTabArea() orelse return App.Error.Win32CallFailed;
    const surface = surface: {
        if (builtin.is_test) if (test_create_pane) |make| break :surface try make(self, opts);
        break :surface try Surface.create(self.app, self, area, opts);
    };
    // Nothing owns the terminal until it is in a tab.
    errdefer surface.discard();
    return try self.insertTabAt(surface, place);
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
    // Its title prompt goes with it, before it is freed, and so does
    // what `undo` would put back in it.
    TitleDialog.tabRemoved(self, t);
    self.app.undo.forgetTab(self.app, t);
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

/// `removeTab` for a tab that `undo` may put back (`Undo`): it leaves the
/// window's tabs, but is kept, with every terminal of its parked. After
/// `Undo.parks`, in a window with another tab.
pub fn parkTab(self: *Window, t: *Tab) void {
    const index = self.tabIndex(t).?;
    // Its title prompt goes; the title it has stays with it.
    TitleDialog.tabRemoved(self, t);
    if (self.unlinkTab(index)) {
        self.showTab();
        hideTab(t);
    } else {
        self.relayout();
    }
    t.pending_focus = null;
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        entry.view.closing = true;
        entry.view.park();
    }
    self.app.undo.pushTab(self.app, self, t, index);
}

/// Put `t`, which `parkTab` took out, back among the tabs at `index`, or
/// at the end if fewer are left, and show it. Room for it was made.
pub fn relinkTab(self: *Window, t: *Tab, index: usize) void {
    const at = @min(index, self.tabs.items.len);
    // `selected` goes on naming the tab that shows, which `selectTab`
    // then hides.
    if (at <= self.selected) self.selected += 1;
    self.tabs.insertAssumeCapacity(at, t);
    self.bar.tabsChanged(self);
    self.selectTab(at);
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
    // What `undo` would put back in it was parked in this frame, which
    // the tab leaves.
    self.app.undo.forgetTab(self.app, t);
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

/// `window-position-x` and `window-position-y`, when both are set: move
/// the still-hidden frame, at the size it has, so that what shows of it
/// has its top-left corner there, counted in pixels from the primary
/// monitor's top-left corner as the screen's coordinates are, and kept
/// inside the work area of the monitor nearest to that point
/// (`positionRect`). Every new window goes there, as on macOS, which
/// places each at the position (`setInitialWindowPosition` in
/// TerminalWindow.swift). Logged, and left where Windows put it, if it
/// cannot be placed.
///
/// On a monitor with another DPI the frame gets WM_DPICHANGED as it
/// arrives, whose suggested rect is scaled and moved: it is placed
/// again from the size it has then, as a dropped tab's window is
/// (`placeForDrop`).
fn applyInitialPosition(self: *Window) void {
    const x = self.app.config.@"window-position-x" orelse return;
    const y = self.app.config.@"window-position-y" orelse return;
    const at: win32.POINT = .{ .x = x, .y = y };
    const dpi = dpiOf(self.app, self.hwnd);
    self.placeAtPosition(at);
    if (dpiOf(self.app, self.hwnd) != dpi) self.placeAtPosition(at);
}

/// One placing of `applyInitialPosition`, from the frame as it is now.
fn placeAtPosition(self: *Window, at: win32.POINT) void {
    var frame: win32.RECT = undefined;
    if (!win32.GetWindowRect(self.hwnd, &frame).toBool()) {
        log.warn("unable to read the new window's frame, not placed at its position err={}", .{win32.GetLastError()});
        return;
    }
    const visible = TabBar.visibleBounds(self.hwnd) orelse frame;
    const monitor = monitorInfo(win32.MonitorFromPoint(at, win32.MONITOR_DEFAULTTONEAREST)) orelse return;
    const rect = positionRect(frame, visible, at, monitor.rcWork);
    if (!win32.SetWindowPos(
        self.hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    ).toBool()) {
        log.warn("unable to place the new window at its position err={}", .{win32.GetLastError()});
    }
}

/// The rect for a frame now at `frame`, of which `visible` shows (a
/// resize border Windows draws nothing of is part of the frame, and
/// outside it: `TabBar.visibleBounds`), moved so that what shows has its
/// top-left corner at `at`, then what shows kept inside the work area
/// `work` as `constrainToWorkArea` keeps a window: a window asked for at
/// the work area's corner shows flush with it, its unseen border past
/// the edge, as a window snapped there by Windows has it.
pub fn positionRect(frame: win32.RECT, visible: win32.RECT, at: win32.POINT, work: win32.RECT) win32.RECT {
    const shown = constrainToWorkArea(
        at.x,
        at.y,
        visible.right - visible.left,
        visible.bottom - visible.top,
        work,
    );
    return .{
        .left = shown.left - (visible.left - frame.left),
        .top = shown.top - (visible.top - frame.top),
        .right = shown.right + (frame.right - visible.right),
        .bottom = shown.bottom + (frame.bottom - visible.bottom),
    };
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
    if (t == self.tab()) return self.showTitle();
    return true;
}

/// `set_window_title`, and OK in the window's title prompt
/// (`TitleDialog.commit`): `title` shows as the caption in place of the
/// shown tab's, in every tab, or an empty one ends that, as GTK's
/// `setWindowTitle` does. The tabs' labels keep their own titles. False
/// if it could not be stored or shown.
pub fn setWindowTitle(self: *Window, title: [:0]const u8) bool {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]u8 = if (title.len == 0) null else alloc.dupeSentinel(u8, title, 0) catch |err| {
        log.warn("failed to store the window title err={}", .{err});
        return false;
    };
    if (self.title_override) |old| alloc.free(old);
    self.title_override = copy;
    return self.showTitle();
}

/// Create a window of `kind` holding a new terminal, still hidden: `show`
/// shows it once the app owns both (`App.newWindow`), or `showQuick` the
/// quick terminal. The frame is created at CW_USEDEFAULT size, or the
/// quick terminal's at its place (`quickPlace`), so that the terminal,
/// which fills it, starts with a non-zero size (`CoreSurface.init` reads
/// it).
pub fn create(app: *App, opts: Surface.Options, kind: Kind) !*Window {
    const alloc = app.core_app.alloc;
    const self = try createBare(app, kind, Transparency.wanted(&app.config));
    errdefer self.discard();

    // Under the bar, if `window-show-tab-bar = always` shows it already.
    const area = self.layoutArea() orelse return App.Error.Win32CallFailed;
    const surface = surface: {
        if (builtin.is_test) if (test_create_pane) |make| break :surface try make(self, opts);
        break :surface try Surface.create(app, self, area, opts);
    };
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

/// A new window of `kind`, still hidden and not yet the app's, with one
/// empty tab: `create` puts a new terminal in it, `moveTabTo` a tab from
/// another window in its place. Its frame is made at CW_USEDEFAULT, or the
/// quick terminal's at its place, transparent if `transparent` asks and
/// DWM lets it (`makeTransparent`), with its bar and its title bar's
/// theme. Undone by `discard` until it is in `App.windows`.
pub fn createBare(app: *App, kind: Kind, transparent: bool) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tabs = .empty,
        .selected = 0,
        .title_override = null,
        .bar = .{},
        .dark_frame = false,
        .transparent = false,
        .backdrop = .default,
        .fullscreen = null,
        .decoration = null,
        .quick = kind == .quick,
        .quick_return = null,
        .hidden = .no,
        .quick_animation = null,
        .modal_loops = .{},
        .step_drag = null,
        .system_track = .{},
        .taskbar_button = false,
        .prompt_disabled = false,
        .prompt_lowered = false,
        .title_prompt = .{},
        .clipboard_prompt = null,
        .palette = .{},
        .overview = .{},
        .divider_drag = null,
        .divider_wheel = false,
        .closing = false,
        .destroy_deferred = false,
        .dpi_changing = false,
    };
    // Before the frame: its first messages read the shown tab. The
    // errdefer comes first, as the list's room outlives a failure to make
    // the tab.
    errdefer self.deinitTabs(alloc);
    _ = try self.appendTab(alloc);

    switch (kind) {
        .normal => _ = try self.createFrame(
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
        ),
        // CW_USEDEFAULT is for an overlapped window only: a pop-up's is
        // made at 0, 0 and empty (CreateWindowExW). Made at its place at
        // 96 DPI, on the monitor it goes on, whose DPI it then has, and
        // placed at that before its terminal is made at its size, and
        // before its bar.
        .quick => {
            const work = quickWork(app, .pointer) orelse return App.Error.Win32CallFailed;
            const rect = quickPlace(
                app.config.@"quick-terminal-position",
                app.config.@"quick-terminal-size",
                work,
                win32.USER_DEFAULT_SCREEN_DPI,
            );
            _ = try self.createFrame(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
            _ = self.placeQuick(work, null, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        },
    }
    errdefer comptime unreachable;
    // Before the bar, which is layered in a transparent frame.
    if (transparent) self.makeTransparent();
    self.bar.create(self);

    // Windows announces a change of its app mode only to the top-level
    // windows there are, so one made before this frame existed is read now.
    // Then the title bar, before the frame is first shown, so that it
    // never shows the wrong one.
    app.systemSchemeChanged();
    self.applyTheme();
    Transparency.applyBlur(self);
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
    self.deinit(alloc);
    alloc.destroy(self);
}

/// Create the hidden frame of `self` at `x`, `y`, `width` by `height`
/// (CW_USEDEFAULT for where and how large Windows makes a new window),
/// with the decorations it should have (`applyDecorations`), before
/// anything measures its client area. CreateWindowExW gives every window
/// that is neither a child nor a popup a caption, so the frame is made with
/// one, and loses it after. The quick terminal's is a pop-up with no
/// caption, sizing border or window menu, and no taskbar button
/// (`quick`).
pub fn createFrame(self: *Window, x: c_int, y: c_int, width: c_int, height: c_int) !win32.HWND {
    const style: win32.DWORD = if (self.quick)
        win32.WS_POPUP | win32.WS_CLIPCHILDREN
    else
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN;
    const hwnd = win32.CreateWindowExW(
        if (self.quick) win32.WS_EX_TOOLWINDOW else 0,
        L(class_name),
        L("Ghostty"),
        style,
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

/// Make the new, still hidden and empty frame let the desktop through
/// (`Transparency.frameMade`), before anything is made in it: its chrome
/// is layered as it is made, and its terminals present with alpha. Left
/// opaque, logged, if DWM does not let it.
pub fn makeTransparent(self: *Window) void {
    assert(!self.transparent);
    self.transparent = Transparency.frameMade(self.hwnd);
}

/// Where `show` leaves the frame it shows.
pub const Placing = union(enum) {
    /// A new window: at `window-position-x` and `window-position-y`, when
    /// both are set (`applyInitialPosition`).
    configured,
    /// Where it is: where its maker put it (`placeForDrop`), or Windows.
    as_is,
    /// A saved window (`window-save-state`), as `placeRestored` found it
    /// is to show: as it was, whatever the configuration asks of a new
    /// window's size, position, `maximize` and `fullscreen`.
    restored: Restored,

    pub const Restored = struct {
        /// Where it is when neither maximized nor covering its monitor.
        rect: win32.RECT,
        maximized: bool,
        fullscreen: bool,
    };
};

/// Put the still-hidden frame of a saved window where it will show, for
/// its terminals to be made at the size they will have: at the place
/// `restoredRect` gives it on the monitor nearest to where it was, or,
/// for one that will be maximized or cover its monitor, over that
/// monitor's work area or all of it. Splits are refused where a terminal
/// would not fit (`split`), so a frame left at the size Windows made it
/// would lose terminals that fit the window as it shows. `show` then
/// shows it as the returned placing says. Left as it is, logged, if its
/// monitor cannot be read.
pub fn placeRestored(self: *Window, saved: SavedPlace) Placing {
    const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOOWNERZORDER;
    const was: win32.RECT = .{
        .left = saved.rect[0],
        .top = saved.rect[1],
        .right = saved.rect[2],
        .bottom = saved.rect[3],
    };
    const info = monitorInfo(win32.MonitorFromRect(&was, win32.MONITOR_DEFAULTTONEAREST)) orelse
        return .as_is;
    const before = dpiOf(self.app, self.hwnd);
    var rect = restoredRect(saved.rect, saved.dpi, before, info.rcWork);
    self.moveTo(rect, flags);
    // On a monitor with another DPI the frame got WM_DPICHANGED as it
    // arrived, and has the rect Windows suggested: placed again at the
    // scale it has there, as a new window's position is
    // (`applyInitialPosition`). The DPI says so, not the two rects,
    // which are the same where both are held to the work area.
    const dpi = dpiOf(self.app, self.hwnd);
    if (dpi != before) {
        rect = restoredRect(saved.rect, saved.dpi, dpi, info.rcWork);
        self.moveTo(rect, flags);
    }
    if (saved.fullscreen) {
        self.moveTo(info.rcMonitor, flags);
    } else if (saved.maximized) {
        self.moveTo(info.rcWork, flags);
    }
    return .{ .restored = .{ .rect = rect, .maximized = saved.maximized, .fullscreen = saved.fullscreen } };
}

/// Size the still-hidden frame to `window-width`/`window-height`, place it
/// as `placing` says, maximize it if `maximize` asks, cover its monitor if
/// `fullscreen` asks, and show it. The first WM_SETFOCUS and WM_PAINT (and
/// the first WM_SIZE, unless the size already sent one) reach the terminal
/// from here; its core is live by now.
pub fn show(self: *Window, placing: Placing) void {
    // Placed before the size as well as after it: the size is counted at
    // the scale of the frame's monitor and kept inside that monitor's
    // work area, which must be the one the position is on, not the one
    // Windows made the frame on.
    if (placing == .configured) self.applyInitialPosition();
    if (placing != .restored) if (self.tab().focused) |surface| {
        if (surface.initial_size) |size| self.applyInitialSize(surface, size);
    };

    // Again after the size, from the frame it left, which the placing
    // keeps inside a work area, and before `maximize` and `fullscreen`,
    // which leave the placed rect as the one the window comes back to.
    if (placing == .configured) self.applyInitialPosition();

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
    const maximize = switch (placing) {
        .restored => |r| r.maximized,
        else => self.app.config.maximize,
    };
    // A saved window that was either goes back to its own rect: until
    // now its frame was over what it will cover (`placeRestored`).
    switch (placing) {
        .restored => |r| if (r.maximized or r.fullscreen) self.moveTo(
            r.rect,
            win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOOWNERZORDER,
        ),
        else => {},
    }
    if (maximize) _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWMAXIMIZED);

    // `fullscreen` starts every window covering its monitor, as on GTK;
    // the macOS-only kinds of it are taken as the one kind there is. After
    // the size above, which leaving fullscreen goes back to.
    const fullscreen = switch (placing) {
        .restored => |r| r.fullscreen,
        else => self.app.config.fullscreen != .false,
    };
    if (fullscreen) self.toggleFullscreen();

    if (!maximize) _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNORMAL);
    _ = win32.UpdateWindow(self.hwnd);

    // A title prompt opened before the window was on screen, which holds
    // it disabled, shows with it.
    TitleDialog.frameShown(self);
}

/// `toggle_quick_terminal` with the quick terminal hidden, or just made
/// (`App.toggleQuick`), or a request to bring it forward (`present`) or to
/// close it with a question to ask (`requestClose`): place it again, on
/// the monitor it goes on now (`quickWork`), above every window that is
/// not, and bring it forward with the keyboard, as GTK and macOS show
/// theirs. Its shown tab's terminals are told they show (`relayout`): a
/// hidden frame's children are told nothing (`hideQuick`). Shown where it
/// was if its monitor cannot be read. The window in the foreground first
/// is remembered (`quick_return`). It comes in by its animation
/// (`QuickAnimation`), from none of it, or from what a hide still running
/// left of it. False if it could not be shown, or was shown without the
/// keyboard.
pub fn showQuick(self: *Window) bool {
    assert(self.quick);
    // Whoever shows it: no longer `toggle_visibility`'s to show.
    self.hidden = .no;
    self.quick_return = if (App.foregroundWindow()) |front|
        (if (ofApp(self.app, front)) null else front)
    else
        null;
    // Before it shows, so that it does not show whole first.
    if (!self.animateQuick(true)) self.stopQuickAnimation();
    const flags = win32.SWP_SHOWWINDOW | win32.SWP_NOACTIVATE;
    if (quickWork(self.app, .pointer)) |work| {
        if (!self.placeQuick(work, win32.HWND_TOPMOST, flags)) {
            self.stopQuickAnimation();
            return false;
        }
    } else if (!win32.SetWindowPos(
        self.hwnd,
        win32.HWND_TOPMOST,
        0,
        0,
        0,
        0,
        flags | win32.SWP_NOMOVE | win32.SWP_NOSIZE,
    ).toBool()) {
        log.warn("unable to show the quick terminal err={}", .{win32.GetLastError()});
        self.stopQuickAnimation();
        return false;
    }
    // Laid out here too: WM_SIZE comes only if the size changed.
    self.relayout();
    _ = win32.UpdateWindow(self.hwnd);
    // FALSE under Windows' foreground lock (`bringForward`): it shows,
    // above the window in front, which keeps the keyboard.
    if (self.bringToFront()) return true;
    log.info("the quick terminal shows without the keyboard: SetForegroundWindow refused", .{});
    return false;
}

/// `toggle_visibility`'s hide, for this window if it shows
/// (`App.toggleVisibility`): minimized, or the quick terminal hidden as
/// its own toggle hides it (`hideQuick`) unless nothing could then show it
/// again (`App.quickAlone`, with no global toggle_visibility), and
/// remembered for the toggle's show (`hidden`). `front` says it is the one in the foreground, which then
/// goes to the next window in the Z order; any other is minimized with
/// the activation left where it is.
pub fn hideForToggle(self: *Window, front: bool) void {
    if (self.quick) {
        if (!self.quickShown()) return;
        // A global toggle_visibility shows again what this hides.
        if (self.app.quickAlone() and !self.app.togglesBack()) return;
        self.hideQuick();
    } else {
        if (!win32.IsWindowVisible(self.hwnd).toBool() or win32.IsIconic(self.hwnd).toBool()) return;
        // The BOOL is the previous visibility, not success.
        _ = win32.ShowWindow(self.hwnd, if (front) win32.SW_MINIMIZE else win32.SW_SHOWMINNOACTIVE);
    }
    self.hidden = if (front) .front else .hidden;
}

/// `toggle_visibility`'s show, for a window it hid that is not the one to
/// come forward, which `present` shows (`App.toggleVisibility`): restored
/// as it was, maximized if it was, or the quick terminal shown.
pub fn showForToggle(self: *Window) void {
    if (self.quick) {
        _ = self.showQuick();
        return;
    }
    // Without the activation, which is the window's that comes forward:
    // its terminals would be told of a focus they lose at once. A
    // minimized window comes back as it was, maximized if it was. The
    // BOOL is the previous visibility, not success. WM_SIZE forgets that
    // the toggle hid it.
    _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
}

/// `toggle_quick_terminal` with the quick terminal shown, or autohide
/// (`quickAutohide`): hide it, with its tabs, splits and programs kept for
/// the next show, as on GTK and macOS. Its command palette and title
/// prompt close first: "Hiding an owner window has no effect on the
/// visibility state of the owned windows" (Window Features, Microsoft
/// Learn), and the palette's tooltip and the prompt are owned. While it or
/// a window it owns is in the foreground, as when a toggle hides it, the
/// foreground goes back to the window it came from (`quick_return`)
/// before it hides, as macOS gives it back, if that window still shows
/// and is not minimized. Autohide hides it only once the activation has
/// gone elsewhere, so gives nothing back: the user chose where it went.
/// It goes by its animation (`QuickAnimation`), from all of it or from
/// what a show still running has shown, as macOS gives the foreground
/// back before its own; then it hides (`quickHidden`). Nothing if it is
/// hidden or already hiding, as a posted autohide can find it once a
/// toggle has started hiding it (`quickAutohide`).
pub fn hideQuick(self: *Window) void {
    assert(self.quick);
    if (!self.quickShown()) return;
    // Asked before its prompt closes and the activation moves.
    const front = App.inForeground(self);
    CommandPalette.close(self);
    TabOverview.close(self);
    TitleDialog.close(self);
    if (front) if (self.quick_return) |hwnd| giveBack(hwnd);
    if (self.animateQuick(false)) return;
    self.quickHidden();
    self.stopQuickAnimation();
}

/// The quick terminal, at the end of a hide (`hideQuick`, `quickStep`):
/// off screen, with its shown tab's terminals told they no longer show, as
/// a minimized frame's are (WM_SIZE); the other tabs' were told when they
/// were hidden (`hideTab`).
fn quickHidden(self: *Window) void {
    // The BOOL is the previous visibility, not success.
    _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
    var it = self.tab().tree.iterator();
    while (it.next()) |entry| entry.view.occlusionChanged(false);
}

/// Put the quick terminal in the band of windows always on top, where it
/// is while it shows (`showQuick`), or take it out of it, for a prompt
/// another window owns (`App.beginPrompt`); it neither moves nor takes
/// the activation. False if it could not, logged.
pub fn setTopmost(self: *Window, on: bool) bool {
    assert(self.quick);
    const after = if (on) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
    const flags = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE;
    if (win32.SetWindowPos(self.hwnd, after, 0, 0, 0, 0, flags).toBool()) return true;
    log.warn("unable to move the quick terminal between bands topmost={} err={}", .{ on, win32.GetLastError() });
    return false;
}

/// Whether the quick terminal shows, or is coming in: it is visible and
/// not on its way out (`QuickAnimation`). What a toggle hides
/// (`App.toggleQuick`).
pub fn quickShown(self: *const Window) bool {
    assert(self.quick);
    if (!win32.IsWindowVisible(self.hwnd).toBool()) return false;
    const animation = self.quick_animation orelse return true;
    return animation.showing;
}

/// Give the foreground to `hwnd`, the window the quick terminal came from
/// (`hideQuick`), unless it has closed (IsWindowVisible is FALSE for a
/// window that no longer exists), is hidden or is minimized. Allowed:
/// Ghostty is the foreground process, which SetForegroundWindow's
/// documentation lists as a process that can set it.
fn giveBack(hwnd: win32.HWND) void {
    if (!win32.IsWindowVisible(hwnd).toBool() or win32.IsIconic(hwnd).toBool()) return;
    if (!bringForward(hwnd, hwnd)) log.info("the foreground stays with Ghostty: SetForegroundWindow refused", .{});
}

/// The quick terminal, as it closes while it or a window it owns is in
/// the foreground (`App.inForeground`), as when its last terminal exits:
/// the foreground goes back to the window it came from (`quick_return`),
/// as a toggle's hide gives it back (`hideQuick`) and as macOS gives its
/// previous application back as an emptied quick terminal goes
/// (QuickTerminalController.animateWindowOut), rather than to whichever
/// window Windows picks next. Nothing while the app quits, as every
/// window goes (`App.terminating`). Called by both ways a window leaves
/// the screen as it closes: its teardown hides it (`destroyPosted`), or
/// its last terminal's destroys it (`destroy`); once hidden, it is no
/// longer in front.
fn giveBackClosing(self: *Window) void {
    if (!self.quick or self.app.terminating) return;
    if (!App.inForeground(self)) return;
    if (self.quick_return) |hwnd| giveBack(hwnd);
}

/// The quick terminal lost the activation (WM_ACTIVATE) to `to`, which
/// Windows does not always name. To a window it owns, a prompt or its
/// title dialog, nothing changes, as macOS keeps its quick terminal while
/// a sheet is up. To another of Ghostty's windows, it forgets the window
/// to give the foreground back to, as macOS forgets the app it came from
/// once its own app keeps the activation. With `quick-terminal-autohide`
/// it then hides, as GTK and macOS hide theirs, by a message to itself
/// (`quickAutohide`) once this activation change is over: the activation
/// can come straight back, and its command palette is not destroyed
/// inside the change (`CommandPalette.deactivated`). Hidden, or on its
/// way out (`quickShown`), it has nothing to hide, and posts nothing.
pub fn quickDeactivated(self: *Window, to: ?win32.HWND) void {
    assert(self.quick);
    if (to) |hwnd| {
        if (win32.GetAncestor(hwnd, win32.GA_ROOTOWNER) == self.hwnd) return;
        if (ofApp(self.app, hwnd)) self.quick_return = null;
    }
    if (!self.app.config.@"quick-terminal-autohide") return;
    if (!self.quickShown()) return;
    if (!win32.PostMessageW(self.hwnd, WM_GHOSTTY_QUICK_HIDE, 0, 0).toBool()) {
        log.warn("unable to hide the quick terminal as it loses the activation err={}", .{win32.GetLastError()});
    }
}

/// `quick-terminal-autohide`, once the activation the quick terminal lost
/// has settled (`quickDeactivated`): it hides unless the activation has
/// come back to it or to a window it owns, as GTK checks that its quick
/// terminal is still inactive. With nothing to show it again once hidden
/// (`App.quickAlone`), it stays: the activation going elsewhere does not
/// ask to close it, as a toggle then does (`App.toggleQuick`).
fn quickAutohide(self: *Window) void {
    assert(self.quick);
    if (App.inForeground(self)) return;
    if (self.app.quickAlone()) return;
    self.hideQuick();
}

/// Whether `hwnd` is one of `app`'s frames or a window one of them owns,
/// such as a prompt or a title dialog: its root owner is a frame.
fn ofApp(app: *const App, hwnd: win32.HWND) bool {
    return app.windowOf(hwnd) != null;
}

/// The quick terminal's show or hide animation, as macOS animates its own
/// (`quick-terminal-animation-duration`): over the duration, with macOS's
/// easing (`easeIn`), from the share of it that shows as it starts to all
/// of it or none, so that a toggle partway turns it back from where it
/// is, as macOS's animator does. It is at its place from the first step:
/// a window region grows from the edge it is on, or shrinks back to it,
/// as Windows Terminal's quake window grows one, so that nothing is moved
/// or resized, its terminals keep their size, and no part of it is ever
/// on another monitor. `center`, which has no edge, fades, as macOS fades
/// it, by a layered window's alpha. DWM clips the terminals' swap chains
/// to the region and blends them by the alpha while they keep presenting,
/// and animates neither the pop-up's show nor its hide itself (measured
/// in the Windows 11 VM). Its timer steps it (`quickStep`); the share
/// comes from the time since it started, so that a late step moves it
/// further rather than drawing it out.
const QuickAnimation = struct {
    /// Coming in, or going out, which ends hidden.
    showing: bool,
    /// The share of it that showed as it started, from 0 to 1.
    from: f64,
    /// When it started, in `quickNow`'s nanoseconds.
    start: u64,
};

/// The frame's timer that steps the quick terminal's animation
/// (`QuickAnimation`), its only timer. Asked for at USER_TIMER_MINIMUM;
/// it fires with the system tick, every 15.3 to 17.8 ms as measured in
/// the Windows 11 VM.
pub const quick_timer_id: win32.UINT_PTR = 1;

/// For tests: the time the quick terminal's animation is driven with
/// (`quickNow`), in nanoseconds, in place of the performance counter's.
pub var test_quick_now: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {};

/// For tests: SetTimer failing (`startQuickTimer`), as it does when the
/// process has used up its timers.
pub var test_quick_timer_fails: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// For tests: answers in place of CreateRectRgn (`quickReveal`), as
/// BellBorder.test_create_rgn does for the bell's border.
pub var test_quick_rgn: if (builtin.is_test) ?*const fn (i32, i32, i32, i32) ?win32.HRGN else void =
    if (builtin.is_test) null else {};

/// Nanoseconds by the performance counter, which the animation's share is
/// measured in, not GetTickCount64, whose resolution "is limited to the
/// resolution of the system timer, which is typically in the range of 10
/// milliseconds to 16 milliseconds" (Learn, GetTickCount64): about as
/// often as the timer fires.
fn quickNow() u64 {
    if (builtin.is_test) if (test_quick_now) |t| return t;
    var count: i64 = 0;
    var frequency: i64 = 0;
    // Both "always succeed" since Windows XP (Learn); the frequency is
    // kept above 0 all the same, for the division.
    _ = win32.QueryPerformanceCounter(&count);
    _ = win32.QueryPerformanceFrequency(&frequency);
    const ticks: u128 = @intCast(@max(count, 0));
    const per_second: u128 = @intCast(@max(frequency, 1));
    return std.math.lossyCast(u64, ticks * std.time.ns_per_s / per_second);
}

/// `quick-terminal-animation-duration` in nanoseconds: 0, no animation,
/// for 0, as the option says, and for anything that is not a finite
/// number of seconds above 0, which its parser lets through
/// (std.fmt.parseFloat reads "nan", "inf" and negative numbers).
fn quickDuration(app: *const App) u64 {
    const seconds = app.config.@"quick-terminal-animation-duration";
    if (!(seconds > 0) or !std.math.isFinite(seconds)) return 0;
    return std.math.lossyCast(u64, seconds * std.time.ns_per_s);
}

/// macOS's easeIn, which its quick terminal animates by
/// (QuickTerminalController.swift, animateWindowIn and animateWindowOut):
/// CAMediaTimingFunction(name: .easeIn), the cubic Bezier curve through
/// (0, 0), (0.42, 0), (1, 1) and (1, 1), as its getControlPoint answers on
/// macOS, and CSS's ease-in. The share of the way done after `x` of the
/// time: the curve's y where its x is `x`, found by halving, for its x
/// rises from 0 to 1.
pub fn easeIn(x: f64) f64 {
    if (!(x > 0)) return 0;
    if (x >= 1) return 1;
    var low: f64 = 0;
    var high: f64 = 1;
    // Each halves the interval: 2^-48 of t, well below a pixel.
    for (0..48) |_| {
        const t = (low + high) / 2;
        if (bezier(t, 0.42, 1) < x) low = t else high = t;
    }
    return bezier((low + high) / 2, 0, 1);
}

/// One coordinate at `t` of a cubic Bezier curve from 0 to 1 whose inner
/// control points have `p1` and `p2` for it.
fn bezier(t: f64, p1: f64, p2: f64) f64 {
    const u = 1 - t;
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
}

/// The share of the quick terminal that shows at `now` in `animation`,
/// which runs for `duration`, and whether it is over.
fn quickShare(animation: QuickAnimation, now: u64, duration: u64) struct { f64, bool } {
    const to: f64 = if (animation.showing) 1 else 0;
    const elapsed = now -| animation.start;
    if (elapsed >= duration) return .{ to, true };
    const x = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(duration));
    return .{ animation.from + (to - animation.from) * easeIn(x), false };
}

/// The part of a `width` x `height` quick terminal at `position` that
/// shows when `share` of it does, in its window's coordinates, which
/// SetWindowRgn takes: a band along its edge, as deep as the share of it
/// rounded up, so that any share of it shows. All of it for `center`,
/// which fades instead.
fn quickBand(position: configpkg.Config.QuickTerminalPosition, width: i32, height: i32, share: f64) win32.RECT {
    const depth = struct {
        fn of(size: i32, s: f64) i32 {
            return std.math.clamp(std.math.lossyCast(i32, @ceil(@as(f64, @floatFromInt(size)) * s)), 0, size);
        }
    }.of;
    return switch (position) {
        .top => .{ .left = 0, .top = 0, .right = width, .bottom = depth(height, share) },
        .bottom => .{ .left = 0, .top = height - depth(height, share), .right = width, .bottom = height },
        .left => .{ .left = 0, .top = 0, .right = depth(width, share), .bottom = height },
        .right => .{ .left = width - depth(width, share), .top = 0, .right = width, .bottom = height },
        .center => .{ .left = 0, .top = 0, .right = width, .bottom = height },
    };
}

/// Start the quick terminal's show (`showing`) or hide animation from the
/// share of it that shows now, taking over from one that runs, and show
/// that share. False if there is none to run, its duration being 0, or if
/// its timer or that share cannot be set, logged: the caller then shows
/// it whole or hides it at once, and stops it (`stopQuickAnimation`).
fn animateQuick(self: *Window, showing: bool) bool {
    const duration = quickDuration(self.app);
    const now = quickNow();
    const from: f64 = if (self.quick_animation) |running|
        quickShare(running, now, duration)[0]
    else if (showing) 0 else 1;
    if (duration == 0) return false;
    self.quick_animation = .{ .showing = showing, .from = from, .start = now };
    return self.quickReveal(from) and self.startQuickTimer();
}

/// The quick terminal's animation timer, started or started again; false,
/// logged, if it cannot be.
fn startQuickTimer(self: *Window) bool {
    const fails = if (builtin.is_test) test_quick_timer_fails else false;
    if (!fails and win32.SetTimer(self.hwnd, quick_timer_id, win32.USER_TIMER_MINIMUM, null) != 0) return true;
    log.warn("unable to animate the quick terminal err={}", .{win32.GetLastError()});
    return false;
}

/// No animation runs any more (`QuickAnimation`): its timer stopped, and
/// the quick terminal shown whole (`quickRevealAll`), on screen or not.
fn stopQuickAnimation(self: *Window) void {
    self.quick_animation = null;
    // FALSE if no timer ran.
    _ = win32.KillTimer(self.hwnd, quick_timer_id);
    self.quickRevealAll();
}

/// The quick terminal's animation timer fired (`quick_timer_id`): the
/// share that shows now, or at the end, it shows whole or, at the end of a
/// hide, hides first, so that it does not show whole as it goes. A step
/// that cannot be shown ends it there, at once. Nothing if none runs: the
/// timer's message can be in the queue after it stopped, as KillTimer
/// "does not remove WM_TIMER messages already posted to the message queue"
/// (Learn).
fn quickStep(self: *Window) void {
    const animation = self.quick_animation orelse return;
    const share, const over = quickShare(animation, quickNow(), quickDuration(self.app));
    if (!over and self.quickReveal(share)) return;
    if (!animation.showing) self.quickHidden();
    self.stopQuickAnimation();
}

/// Show `share` of the quick terminal (`QuickAnimation`): a band along its
/// edge by a window region (`quickBand`), or for `center` its alpha, as a
/// layered window. False, logged, if it cannot be shown so.
fn quickReveal(self: *Window, share: f64) bool {
    const position = self.app.config.@"quick-terminal-position";
    if (position == .center) {
        const style = win32.GetWindowLongPtrW(self.hwnd, win32.GWL_EXSTYLE);
        const layered: isize = win32.WS_EX_LAYERED;
        if (style & layered == 0) _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_EXSTYLE, style | layered);
        const alpha = std.math.lossyCast(u8, @round(share * 255));
        if (win32.SetLayeredWindowAttributes(self.hwnd, 0, alpha, win32.LWA_ALPHA).toBool()) return true;
        log.warn("unable to fade the quick terminal err={}", .{win32.GetLastError()});
        return false;
    }
    var frame: win32.RECT = undefined;
    if (!win32.GetWindowRect(self.hwnd, &frame).toBool()) {
        log.warn("cannot read the quick terminal's size err={}", .{win32.GetLastError()});
        return false;
    }
    const band = quickBand(position, frame.right - frame.left, frame.bottom - frame.top, share);
    const rgn = quickRgn(band) orelse {
        log.warn("unable to make the quick terminal's region err={}", .{win32.GetLastError()});
        return false;
    };
    // Once set, "the system owns the region"; not set, it is still ours.
    if (win32.SetWindowRgn(self.hwnd, rgn, .TRUE) != 0) return true;
    log.warn("unable to set the quick terminal's region err={}", .{win32.GetLastError()});
    _ = win32.DeleteObject(rgn);
    return false;
}

fn quickRgn(band: win32.RECT) ?win32.HRGN {
    if (builtin.is_test) if (test_quick_rgn) |make| return make(band.left, band.top, band.right, band.bottom);
    return win32.CreateRectRgn(band.left, band.top, band.right, band.bottom);
}

/// The quick terminal whole again, as it was made: no region, and not
/// layered. Asked to redraw once it is not layered, as "Using Layered
/// Windows" (Learn) asks for a window to be opaque again.
fn quickRevealAll(self: *Window) void {
    if (win32.SetWindowRgn(self.hwnd, null, .TRUE) == 0) {
        log.warn("unable to show all of the quick terminal err={}", .{win32.GetLastError()});
    }
    const style = win32.GetWindowLongPtrW(self.hwnd, win32.GWL_EXSTYLE);
    const layered: isize = win32.WS_EX_LAYERED;
    if (style & layered == 0) return;
    _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWL_EXSTYLE, style & ~layered);
    const flags = win32.RDW_INVALIDATE | win32.RDW_ERASE | win32.RDW_FRAME | win32.RDW_ALLCHILDREN;
    _ = win32.RedrawWindow(self.hwnd, null, null, flags);
}

/// For `quick-terminal-screen = mouse`, whose monitor the quick terminal
/// goes on (`quickWork`): the pointer's, as it is made and as it shows;
/// or, as it is placed again (`placeQuickAgain`, `quickDpiChanged`), the
/// one the centre of `on`, its frame, is on: the monitor it is on,
/// wherever the pointer has gone since.
pub const Mouse = union(enum) { pointer, on: win32.HWND };

/// For tests: answers in place of MonitorFromPoint and GetMonitorInfoW,
/// with the point and flags `quickWork` gives the first, so that a test
/// has monitors the VM does not.
pub var test_monitor: if (builtin.is_test) ?*const fn (win32.POINT, win32.DWORD) ?win32.MONITORINFO else void =
    if (builtin.is_test) null else {};

/// The work area of the monitor the quick terminal goes on now, the part
/// of it the taskbar leaves, by `quick-terminal-screen`: the primary
/// monitor for `main`, as GTK takes it, and for `macos-menu-bar`, as the
/// option says Linux does; for `mouse`, the monitor of the point `mouse`
/// names, or the nearest, or the primary if Windows cannot say where the
/// pointer is. Null, logged, if its place or the monitor cannot be read.
fn quickWork(app: *const App, mouse: Mouse) ?win32.RECT {
    const primary: struct { win32.POINT, win32.DWORD } = .{ .{ .x = 0, .y = 0 }, win32.MONITOR_DEFAULTTOPRIMARY };
    const at: win32.POINT, const flags: win32.DWORD = switch (app.config.@"quick-terminal-screen") {
        .main, .@"macos-menu-bar" => primary,
        .mouse => switch (mouse) {
            .pointer => if (Dividers.cursorPos()) |pos| .{ pos, win32.MONITOR_DEFAULTTONEAREST } else primary,
            .on => |hwnd| centre: {
                var frame: win32.RECT = undefined;
                if (!win32.GetWindowRect(hwnd, &frame).toBool()) {
                    log.warn("cannot read the quick terminal's place err={}", .{win32.GetLastError()});
                    return null;
                }
                break :centre .{ .{
                    .x = frame.left + @divTrunc(frame.right - frame.left, 2),
                    .y = frame.top + @divTrunc(frame.bottom - frame.top, 2),
                }, win32.MONITOR_DEFAULTTONEAREST };
            },
        },
    };
    if (builtin.is_test) if (test_monitor) |answer| {
        const info = answer(at, flags) orelse return null;
        return info.rcWork;
    };
    const info = monitorInfo(win32.MonitorFromPoint(at, flags)) orelse return null;
    return info.rcWork;
}

/// Move the quick terminal to its place on `work` at its DPI, with
/// SetWindowPos's `after` and `flags`; false, logged, if it cannot be.
/// A move onto a monitor with another DPI changes the frame's (`dpiOf`),
/// and its place is then that DPI's (`quickDpiChanged`). WM_DPICHANGED
/// says so as the frame arrives, but whether a hidden frame, which
/// `createBare` places and `showQuick` moves as it shows it, hears of the
/// change, as `placeForDrop` takes it to, is unverified, and its terminals
/// would keep the old scale: so the change is made here too, which a
/// terminal told its scale twice ignores (the core's
/// `Surface.contentScaleCallback`).
fn placeQuick(self: *Window, work: win32.RECT, after: ?win32.HWND, flags: win32.UINT) bool {
    const dpi = dpiOf(self.app, self.hwnd);
    if (!self.moveQuick(work, dpi, after, flags)) return false;
    const now = dpiOf(self.app, self.hwnd);
    if (now != dpi) self.quickDpiChanged(std.math.lossyCast(u16, now));
    return true;
}

/// SetWindowPos for the quick terminal to its place on `work` at `dpi`
/// (`quickPlace`); false, logged, if it fails.
fn moveQuick(self: *Window, work: win32.RECT, dpi: u32, after: ?win32.HWND, flags: win32.UINT) bool {
    const rect = quickPlace(
        self.app.config.@"quick-terminal-position",
        self.app.config.@"quick-terminal-size",
        work,
        dpi,
    );
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (win32.SetWindowPos(self.hwnd, after, rect.left, rect.top, w, h, flags).toBool()) return true;
    log.warn("unable to place the quick terminal err={}", .{win32.GetLastError()});
    return false;
}

/// The quick terminal's DPI is now `dpi`, by WM_DPICHANGED or a move
/// (`placeQuick`): its terminals take the new scale, then it takes its
/// place at it (`quickWork`, on the monitor it is on for `mouse`), not
/// the rect Windows suggests, which is its old one scaled, as a frame
/// covering its monitor covers it again; then it is laid out if it shows
/// (`relayout`), for the dividers' width is the DPI's too.
fn quickDpiChanged(self: *Window, dpi: u16) void {
    self.scaleTerminals(dpi);
    if (quickWork(self.app, .{ .on = self.hwnd })) |work| {
        _ = self.moveQuick(work, dpi, null, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    }
    self.relayout();
}

/// The quick terminal, if it shows, placed again as its work area, the
/// displays or the configuration change: on the primary monitor for
/// `main`, which may be another by now, and on the monitor it is on for
/// `mouse` (`Mouse`). A hidden one is placed as it shows (`showQuick`).
pub fn placeQuickAgain(self: *Window) void {
    assert(self.quick);
    if (!win32.IsWindowVisible(self.hwnd).toBool()) return;
    const work = quickWork(self.app, .{ .on = self.hwnd }) orelse return;
    _ = self.placeQuick(work, null, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
}

/// The rect of a quick terminal at `position`, `size` from the
/// configuration, on the work area `work`, in its pixels at `dpi`: as
/// large as the core's `QuickTerminalSize.calculate` makes it over the
/// work area in DIPs, as macOS works it out over its screen's visible
/// frame in points, so that `300px`, and the 400 it is when no size is
/// set, are as many pixels at 96 DPI and half as many again at 144;
/// but no larger than the work area, which `calculate` does not keep to,
/// and at least a pixel; flush with the work area's edge at `position`
/// and centred along it, or centred both ways for `center`, as macOS
/// places it (QuickTerminalPosition.swift).
///
/// The work area is made DIPs rounding up, and the size pixels again
/// rounding down, so that all of the work area, `100%` or the whole edge
/// it takes when no size is set, is all of it at any DPI: rounding down
/// both ways would leave it a pixel or two short. A `dpi` of 0, which no
/// window has, is taken as 96.
pub fn quickPlace(
    position: configpkg.Config.QuickTerminalPosition,
    size: configpkg.Config.QuickTerminalSize,
    work: win32.RECT,
    dpi: u32,
) win32.RECT {
    const d: u64 = if (dpi == 0) win32.USER_DEFAULT_SCREEN_DPI else dpi;
    const work_w: u32 = @intCast(@max(0, work.right - work.left));
    const work_h: u32 = @intCast(@max(0, work.bottom - work.top));
    const dims = boundedSize(size).calculate(position, .{
        .width = toDips(work_w, d),
        .height = toDips(work_h, d),
    });
    // Both fit an i32: no larger than the work area's.
    const w: i32 = @intCast(@max(1, @min(fromDips(dims.width, d), work_w)));
    const h: i32 = @intCast(@max(1, @min(fromDips(dims.height, d), work_h)));
    const centred_x = work.left + @divTrunc(work.right - work.left - w, 2);
    const centred_y = work.top + @divTrunc(work.bottom - work.top - h, 2);
    const left: i32, const top: i32 = switch (position) {
        .top => .{ centred_x, work.top },
        .bottom => .{ centred_x, work.bottom - h },
        .left => .{ work.left, centred_y },
        .right => .{ work.right - w, centred_y },
        .center => .{ centred_x, centred_y },
    };
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// `px` pixels at `dpi`, not 0, in DIPs, rounded up (`quickPlace`), or
/// as many as a u32 holds.
fn toDips(px: u32, dpi: u64) u32 {
    const dips = std.math.divCeil(u64, @as(u64, px) * win32.USER_DEFAULT_SCREEN_DPI, dpi) catch unreachable;
    return std.math.lossyCast(u32, dips);
}

/// `dips` at `dpi` in pixels, rounded down (`quickPlace`). No u32 times a
/// u32 overflows a u64.
fn fromDips(dips: u32, dpi: u64) u64 {
    return @as(u64, dips) * dpi / win32.USER_DEFAULT_SCREEN_DPI;
}

/// `size` with each percentage at most 100 and a NaN one left unset, for
/// `calculate`: its `toPixels` makes a percentage of the work area into a
/// u32, which one far above 100 or a NaN does not fit (`@intFromFloat`,
/// a safety panic, or undefined behaviour in a release build), and the
/// parser takes any float that is not negative. More than all of the work
/// area is all of it anyway (`quickPlace`).
fn boundedSize(size: configpkg.Config.QuickTerminalSize) configpkg.Config.QuickTerminalSize {
    return .{ .primary = boundedPart(size.primary), .secondary = boundedPart(size.secondary) };
}

fn boundedPart(part: ?configpkg.Config.QuickTerminalSize.Size) ?configpkg.Config.QuickTerminalSize.Size {
    const v = part orelse return null;
    return switch (v) {
        .pixels => v,
        .percentage => |p| if (std.math.isNan(p)) null else .{ .percentage = @min(p, 100) },
    };
}

/// The frame's window procedure.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
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

        WM_GHOSTTY_QUICK_HIDE => {
            if (self.quick) self.quickAutohide();
            return 0;
        },

        // Shutdown, restart, sign-out, or the Restart Manager closing
        // Ghostty for an installer. Never refused, even with a command
        // running: macOS asks nothing at shutdown, restart or logout
        // (`AppDelegate.applicationShouldTerminate`), and GTK takes no
        // part in ending a session. The windows close at WM_ENDSESSION,
        // as WM_QUERYENDSESSION's documentation asks.
        win32.WM_QUERYENDSESSION => return 1,

        win32.WM_ENDSESSION => {
            // Frees `self` when it tears down; nothing may follow it.
            if (wparam != 0) self.app.endSession(lparam);
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
                // The tab overview is not there when the window is back.
                TabOverview.close(self);
                var it = self.tab().tree.iterator();
                while (it.next()) |entry| entry.view.occlusionChanged(false);
                return 0;
            }

            // Not minimized, so restored if `toggle_visibility` minimized
            // it: no longer the toggle's to show. The quick terminal is
            // sized while it is hidden, and forgets as it shows
            // (`showQuick`).
            if (!self.quick) self.hidden = .no;

            // Each terminal gets its WM_SIZE synchronously, which resizes
            // its core.
            self.relayout();
            return 0;
        },

        win32.WM_DPICHANGED => {
            // wParam carries the new DPI in both words; they are always
            // equal for a window. The quick terminal takes its own place.
            if (self.quick) {
                self.quickDpiChanged(win32.hiword(wparam));
                return 0;
            }
            // The new scale first: the suggested rect below lays the
            // terminals out synchronously, and their cores must see the
            // scale before the sizes computed for them.
            self.scaleTerminals(win32.hiword(wparam));
            if (self.fullscreen == null) {
                // Windows' rect as it suggests it: the frame's least is
                // measured from the frame (`minTrackSize`), which may still
                // be the old DPI's here, as WM_NCCALCSIZE measures it again
                // only after WM_WINDOWPOSCHANGING. The least is kept after,
                // from the new frame.
                self.dpi_changing = true;
                applySuggestedRect(hwnd, lparam);
                self.dpi_changing = false;
                if (self.isRestored()) self.growToLeast();
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

        // The least the frame may be made, by its borders or by
        // SetWindowPos, which DefWindowProcW holds to it in
        // WM_WINDOWPOSCHANGING.
        win32.WM_GETMINMAXINFO => {
            const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.system_track = .{ .least = info.ptMinTrackSize, .most = info.ptMaxTrackSize };
            self.minTrackSize(info);
            return 0;
        },

        // A drag of the frame's border, by the mouse or the keys, is about
        // to size it to the rect at lParam, which `window-step-resize`
        // makes whole cells (`stepSizing`). DefWindowProcW below otherwise.
        win32.WM_SIZING => if (self.stepSizing(wparam, @ptrFromInt(@as(usize, @bitCast(lparam))))) {
            return 1;
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
                // And the command palette's, and the tab overview's.
                CommandPalette.fontChanged(self);
                TabOverview.fontChanged(self);
            }
            // A work area changed, as when the taskbar moves.
            if (wparam == win32.SPI_SETWORKAREA and self.quick) self.placeQuickAgain();
        },

        // Sent to every top-level window; DefWindowProcW below as well.
        win32.WM_DISPLAYCHANGE => if (self.quick) self.placeQuickAgain(),

        // The quick terminal's animation steps (`quickStep`).
        win32.WM_TIMER => if (wparam == quick_timer_id) {
            if (self.quick) self.quickStep();
            return 0;
        },

        // Deactivated: an open command palette closes, as GTK's dialog
        // does, once the deactivation is over (`CommandPalette.deactivated`),
        // unless the palette itself is being activated, and the quick
        // terminal may hide (`quickDeactivated`); lParam is the window
        // being activated. DefWindowProcW below as well.
        win32.WM_ACTIVATE => if (@as(u16, @truncate(wparam)) == win32.WA_INACTIVE) {
            const to: ?win32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            CommandPalette.deactivated(self, to);
            if (self.quick) self.quickDeactivated(to);
        },

        // The caption stays active while the command palette, a pop-up
        // of the frame's, is activated, as a menu keeps it: the palette
        // is part of the window to the user.
        win32.WM_NCACTIVATE => if (wparam == 0 and self.palette.activating) {
            return win32.DefWindowProcW(hwnd, msg, 1, lparam);
        },

        // The command palette moves with the frame.
        win32.WM_MOVE => CommandPalette.frameMoved(self),

        // Keyboard focus belongs to a terminal: the frame gets it on
        // activation (DefWindowProcW's WM_ACTIVATE), and passes it on; or
        // to an open command palette, which is activated once this
        // activation is over (`CommandPalette.activateLater`).
        win32.WM_SETFOCUS => {
            if (self.palette.focusTarget() != null) {
                CommandPalette.activateLater(self);
                return 0;
            }
            if (self.tab().focused) |surface| self.setKeyboardFocus(focusTarget(surface), false);
            return 0;
        },

        // The system modal loops. See App.wndProc's WM_GHOSTTY_WAKEUP.
        win32.WM_ENTERSIZEMOVE, win32.WM_ENTERMENULOOP => {
            // A drag of the border counts its steps anew (`stepSizing`).
            if (msg == win32.WM_ENTERSIZEMOVE) self.step_drag = null;
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
        // terminals, which their own swap chains draw. Opaque in a
        // transparent frame too (`Transparency.fillOpaque`).
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &paint) orelse return 0;
            defer _ = win32.EndPaint(hwnd, &paint);
            const color = dividerColor(&self.app.config);
            const brush = win32.CreateSolidBrush(win32.rgb(color.r, color.g, color.b)) orelse return 0;
            defer _ = win32.DeleteObject(brush);
            if (self.transparent) {
                Transparency.fillOpaque(hdc, &paint.rcPaint, brush);
            } else {
                _ = win32.FillRect(hdc, &paint.rcPaint, brush);
            }
            return 0;
        },

        win32.WM_DESTROY => {
            // Destroyed inside its own size/move or menu loop (e.g. the
            // shell exited mid-drag): the WM_EXIT* for that loop will not
            // come, so return this window's share of the depth now.
            // Otherwise every later wakeup would tick from whatever loop
            // dispatched it.
            self.modal_loops.release(&self.app.modal_loop_depth);

            // The terminals parked for `undo` go with the others below:
            // no close of this window's is left to take back.
            self.app.undo.dropWindow(self.app, self);

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
            if (self.transparent) Transparency.frameDestroyed();
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
    if (ask) {
        // A quick terminal that is hidden, or on its way out, shows first,
        // as macOS shows its own before it asks
        // (QuickTerminalController.confirmCloseAsync): what the question
        // closes is in view, and the question is its own
        // (`App.promptOwner`). Cancelled, it stays shown.
        if (self.quick and !self.quickShown()) _ = self.showQuick();
        var question: Question = .{};
        self.asking = true;
        defer self.asking = false;
        if (!confirm(
            self.app,
            self.hwnd,
            question.text("Close Window?", "All terminal sessions in this window will be terminated."),
            .ok,
        )) {
            self.closing = false;
            return;
        }
    }

    self.postDestroy();
}

/// `toggle_quick_terminal` with the quick terminal shown and nothing that
/// could show it again once hidden (`App.quickAlone`): closed rather than
/// hidden, which would leave its programs running out of reach, but only
/// once the user says so, even with no program running, since the key
/// they pressed asked for a hide (`requestClose` asks only when one runs).
/// The question says why it closes, and Cancel is its default button, as
/// closing ends what runs in it. Cancelled, it stays, shown.
pub fn requestCloseAlone(self: *Window) void {
    assert(self.quick);
    if (self.app.terminating or self.closing) return;
    self.closing = true;
    self.asking = true;
    defer self.asking = false;
    if (!confirm(self.app, self.hwnd, alone_prompt, .cancel)) {
        self.closing = false;
        return;
    }
    self.postDestroy();
}

/// The question `requestCloseAlone` asks. Its conversion at compile time
/// takes more than the default branch quota.
pub const alone_prompt = blk: {
    @setEvalBranchQuota(10_000);
    break :blk L("The quick terminal cannot hide, as nothing could show it again: " ++
        "no other window is open, and no global keybind shows it. Close it instead?");
};

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
    // The tab the user is in is the one that stays in two of the three,
    // so those are asked in the words the action is listed with.
    var question: Question = .{};
    if (ask and !confirm(
        self.app,
        self.hwnd,
        switch (mode) {
            .this => question.text("Close Tab?", "All terminal sessions in this tab will be terminated."),
            .other => question.text("Close Other Tabs", "Close all tabs in this window except the current one."),
            .right => question.text("Close Tabs to the Right", "Close all tabs to the right of the current one."),
        },
        .ok,
    )) return true;

    // The tabs do not change while the prompt was open: only `run` adds a
    // terminal, and a teardown is deferred (`App.canReenterCore`). Marked
    // as closing whole, and as one, for `undo`.
    const group = self.app.undo.newGroup();
    for (self.tabs.items, 0..) |x, i| {
        if (!closes(i, at, mode)) continue;
        x.closing = true;
        x.group = group;
        var it = x.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.closing) continue;
            entry.view.closing = true;
            entry.view.postDestroy();
        }
        // Not one teardown posted, or not all: the tab is not closing
        // whole after all.
        _ = x.closingWhole();
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
    if (builtin.is_test) if (test_needs_confirm) return true;
    var it = t.tree.iterator();
    while (it.next()) |entry| {
        const core_surface = entry.view.liveCore() orelse continue;
        if (core_surface.needsConfirmQuit()) return true;
    }
    return false;
}

/// For tests: a process still running in every terminal (`needsConfirm`),
/// as a test's terminals, which have no core, cannot have one.
pub var test_needs_confirm: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

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
    self.giveBackClosing();
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
    // Asked before its title prompt closes and the activation moves, as
    // `hideQuick` asks.
    self.giveBackClosing();
    // The title prompt first, which would otherwise stay on screen until
    // its own terminal's turn, while the cores before it stop and their
    // threads are waited for, or after the frame was hidden
    // (`destroyPosted`). The command palette too.
    TitleDialog.close(self);
    CommandPalette.close(self);
    TabOverview.close(self);
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
    const across = where == .left or where == .right;
    // Each side needs the parent's least, the new terminal too: it has the
    // parent's configuration and scroll bar, and by default its font size
    // (`window-inherit-font-size`).
    const rect = newPaneArea(
        place,
        where,
        dividerWidth(dpiOf(self.app, self.hwnd)),
        leastExtent(parent, across),
    ) orelse return error.SplitTooSmall;

    const surface = surface: {
        if (builtin.is_test) if (test_create_pane) |make| break :surface try make(self, opts);
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

/// For tests: makes the terminal `split` opens, the one `create` puts in
/// a new window and the one `newTab` puts in a new tab, from the options
/// it was to be made with, in place of `Surface.create`, which starts a
/// core and its program; a test's terminals have no core.
pub var test_create_pane: if (builtin.is_test) ?*const fn (*Window, Surface.Options) anyerror!*Surface else void =
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
/// src/apprt/gtk/class/split_tree.zig, then `SplitTree.resize`). However
/// far it moves, the layout keeps each side its least (`splitArea`). A
/// split held at a side's least moves from where it shows its line, not
/// from where its ratio would put it, as on GTK (`showHeld`): else a move
/// back from the end would not show until it came past the least.
pub fn resizeSplit(self: *Window, from: *Surface, value: apprt.action.ResizeSplit) void {
    const place = self.find(from) orelse return;
    const t = self.tabs.items[place.index];
    const handle = place.handle;
    const client = self.layoutArea() orelse return;
    const across = value.direction == .left or value.direction == .right;
    const extent = if (across) client.right - client.left else client.bottom - client.top;
    if (extent <= 0) return;
    const dpi = dpiOf(self.app, self.hwnd);
    const ratio = resizeShare(value.amount, dpi, extent, value.direction);

    const layout_of: Tree.Split.Layout = if (across) .horizontal else .vertical;
    const held = showHeld(&t.tree, handle, layout_of, client, dividerWidth(dpi));
    const tree = t.tree.resize(self.app.core_app.alloc, handle, layout_of, ratio) catch |err| {
        // As it was: the ratio it had, which lays out as it showed.
        if (held) |h| t.tree.resizeInPlace(h.handle, h.ratio);
        log.warn("cannot resize the split err={}", .{err});
        return;
    };
    self.adopt(t, tree);
}

/// A split's ratio from before `showHeld` wrote the one it shows.
const Held = struct {
    handle: Tree.Node.Handle,
    ratio: f16,
};

/// For `resizeSplit`: if the split it moves in `tree`, laid out in `area`
/// with dividers `divider` pixels wide, is held at a side's least, so that
/// its line is not where its ratio puts it (`splitArea`), write the ratio
/// that lays the line out where it is, and return the one it had. GTK
/// writes it so before it resizes (`clamped_to_tree` in
/// src/apprt/gtk/class/split_tree.zig, `syncSplitRatio`).
fn showHeld(
    tree: *Tree,
    leaf: Tree.Node.Handle,
    layout_of: Tree.Split.Layout,
    area: win32.RECT,
    divider: i32,
) ?Held {
    const found = switch (nearestSplit(tree, .root, leaf, layout_of, area, divider)) {
        .found => |v| v,
        .absent, .below => return null,
    };
    const s = tree.nodes[found.handle.idx()].split;
    const sides = lineAndRest(found.area, s.layout == .horizontal, divider);
    if (sides.rest == 0) return null;
    const range = firstRange(sides.rest, sidesLeast(tree, s, divider));
    const want = firstExtent(sides.rest, s.ratio);
    const shown = std.math.clamp(want, range.lo, range.hi);
    if (shown == want) return null;
    const share = @as(f32, @floatFromInt(shown)) / @as(f32, @floatFromInt(sides.rest));
    tree.resizeInPlace(found.handle, @floatCast(share));
    return .{ .handle = found.handle, .ratio = s.ratio };
}

/// What `nearestSplit` found under a node: not `leaf`; `leaf`, but no
/// split above it with the layout yet; or that split and the area it
/// divides.
const Nearest = union(enum) {
    absent,
    below,
    found: struct { handle: Tree.Node.Handle, area: win32.RECT },
};

/// The split nearest `leaf` above it, at or under `at`, whose sides are
/// laid out `layout_of`, which is the one `SplitTree.resize` moves
/// (`findParentSplit`), with the area `layout` gives it when `at` is laid
/// out in `area`. With no zoom: a resize moves the tree's ratios, not what
/// a zoom shows.
fn nearestSplit(
    tree: *const Tree,
    at: Tree.Node.Handle,
    leaf: Tree.Node.Handle,
    layout_of: Tree.Split.Layout,
    area: win32.RECT,
    divider: i32,
) Nearest {
    if (at == leaf) return .below;
    const s = switch (tree.nodes[at.idx()]) {
        .leaf => return .absent,
        .split => |s| s,
    };
    const sides = splitArea(area, s.layout == .horizontal, s.ratio, divider, sidesLeast(tree, s, divider));
    const under = switch (nearestSplit(tree, s.left, leaf, layout_of, sides.first, divider)) {
        .absent => nearestSplit(tree, s.right, leaf, layout_of, sides.second, divider),
        else => |v| v,
    };
    return switch (under) {
        .below => if (s.layout == layout_of) .{ .found = .{ .handle = at, .area = area } } else .below,
        .absent, .found => under,
    };
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
/// The layout still keeps each side its least (`splitArea`).
pub fn equalize(self: *Window, from: *Surface) void {
    self.equalizeTab(self.tabOf(from) orelse return);
}

/// `equalize` for the tab `t`, as a double click on a divider asks
/// (`Dividers.doubleClick`).
pub fn equalizeTab(self: *Window, t: *Tab) void {
    const tree = t.tree.equalize(self.app.core_app.alloc) catch |err| {
        log.warn("cannot equalize the splits err={}", .{err});
        return;
    };
    self.adopt(t, tree);
}

/// Make `tree`, a resized or equalized copy of `t.tree`, its tree, and lay
/// its terminals out if `t` is shown. Whatever its ratios, the layout
/// keeps each terminal its least where the tab has room for them all
/// (`splitArea`), as GTK keeps them whatever ratio its tree asks for, and
/// the ratios stay for when it has room again.
fn adopt(self: *Window, t: *Tab, tree: Tree) void {
    self.setTree(t, tree);
    if (t == self.tab()) self.relayout();
}

/// The least `surface` is laid out across (`across`) or down in a split:
/// a cell of its font and the padding the configuration asks for each
/// side of it, as GTK keeps a terminal (`syncSplitMinSize` in
/// src/apprt/gtk/class/surface.zig); across, also the scroll bar beside
/// them, which here takes its width from the grid's (GTK counts no bar).
/// With `window-padding-balance` too: the grid is what the configured
/// padding leaves, and balancing spreads only what the grid does not fill
/// (`renderer.Size.balancePadding`). In pixels at the DPI the core has its
/// font at (`DesiredSize.xdpi`), as the core scales the padding
/// (`DerivedConfig.scaledPadding` in src/Surface.zig): points times the
/// DPI over 72, rounded down. The core computes that in f32, from the
/// content scale times 96; integer division here gives the same for every
/// integer DPI from 48 to 960 and every padding from 0 to 255 points,
/// checked exhaustively. No test here can reach the core's function,
/// which is private: the split scenario (dv.ps1, steps 6, 7 and 7b)
/// compares this least with the cell and padding the real core logs. A
/// terminal with no core needs a pixel.
pub fn leastExtent(surface: *Surface, across: bool) i32 {
    const bar = if (across) ScrollBar.width(surface) else 0;
    const along = measureAlong(surface.liveCore() orelse return 1 +| bar, across);
    const least = @max(1, along.cell + along.padding);
    return std.math.lossyCast(i32, least) +| bar;
}

/// A terminal's core measured across or down, in pixels: its cell, and the
/// padding the configuration asks for on both sides of its grid together.
const Along = struct { cell: u64, padding: u64 };

/// `core` measured across (`across`) or down, the padding scaled as
/// `leastExtent` says.
fn measureAlong(core: *const CoreSurface, across: bool) Along {
    const config = &core.config;
    const dpi: u64 = if (across) core.font_size.xdpi else core.font_size.ydpi;
    const near: u64, const far: u64 = if (across)
        .{ config.window_padding_left, config.window_padding_right }
    else
        .{ config.window_padding_top, config.window_padding_bottom };
    return .{
        .cell = if (across) core.size.cell.width else core.size.cell.height,
        .padding = near * dpi / 72 + far * dpi / 72,
    };
}

/// The least `view` is laid out across (`across`) or down: a terminal's
/// own (`leastExtent`), or what a test's view says.
fn leastOf(view: anytype, across: bool) i32 {
    if (@TypeOf(view) == *Surface) return leastExtent(view, across);
    return view.least(across);
}

/// The least the terminals at and under `handle` of `tree` are laid out
/// across (`across`) or down in, as `splitArea` keeps them: a terminal's
/// own (`leastOf`); for a split along that axis, its sides' with its line,
/// `divider` pixels, between them; and for one across it, the larger of
/// its sides'. As GTK measures its split's least (gtk_paned_measure).
pub fn leastUnder(tree: anytype, handle: @TypeOf(tree.*).Node.Handle, across: bool, divider: i32) i32 {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| return leastOf(view, across),
        .split => |s| {
            const first = leastUnder(tree, s.left, across, divider);
            const second = leastUnder(tree, s.right, across, divider);
            if ((s.layout == .horizontal) == across) return first +| divider +| second;
            return @max(first, second);
        },
    }
}

/// The least of each side of the split `s` of `tree` along its axis
/// (`leastUnder`), as `splitArea` keeps them.
pub fn sidesLeast(tree: anytype, s: @TypeOf(tree.*).Split, divider: i32) Least {
    const across = s.layout == .horizontal;
    return .{
        .first = leastUnder(tree, s.left, across, divider),
        .second = leastUnder(tree, s.right, across, divider),
    };
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
    _ = self.showTitle();
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

/// Show the window's own title (`title_override`), else its shown tab's
/// (`shownTitle`), as its caption, as GTK's window computes its title
/// (`closureTitle`): the bell's prefix is the tab's, so its own title has
/// none. Returns whether it is shown.
pub fn showTitle(self: *Window) bool {
    const alloc = self.app.core_app.alloc;
    const wide = (if (self.title_override) |title|
        wideFromUtf8(alloc, title)
    else
        self.shownTitle(alloc, self.tab())) catch |err| {
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
    var left = try self.takePane(t, handle);
    left.deinit();
}

/// `removePane`, returning the tree the terminal left, the caller's now:
/// what `undo` puts back (`Undo`).
pub fn takePane(self: *Window, t: *Tab, handle: Tree.Node.Handle) !Tree {
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
    // As `setTree`, but for the old tree, which is kept.
    const left = t.tree;
    t.tree = tree;
    Dividers.tabChanged(self, t);
    t.focused = focus;

    // A hidden tab's terminals are hidden already, and the focus and the
    // layout are the shown tab's.
    if (t != self.tab()) return left;
    // The focus moves first, so that it is never left on a hidden window.
    if (focus) |f| self.giveFocus(f);
    _ = win32.ShowWindow(surface.hwnd, win32.SW_HIDE);
    self.relayout();
    return left;
}

/// Lay the terminals out over the client area (`layout`), then place their
/// overlays and search bars over them. Not while the window is minimized
/// and its client area is empty (see WM_SIZE), nor while the quick
/// terminal is hidden: its terminals would be told that they show
/// (`Placer.pane`), as a reloaded configuration lays every window out
/// (`App.Request.redecorate`); `showQuick` lays them out. Any other
/// window is laid out hidden before it first shows.
pub fn relayout(self: *Window) void {
    if (self.tab().tree.isEmpty() or win32.IsIconic(self.hwnd).toBool()) return;
    if (self.quick and !win32.IsWindowVisible(self.hwnd).toBool()) return;
    self.placeBar();
    const client = self.layoutArea() orelse return;
    self.placeTerminals(client);
    self.placeOverlays();
    self.placeSearchBars();
    // Above them all, or closed if it no longer fits. The tab overview
    // covers them, and the bar.
    _ = CommandPalette.place(self);
    _ = TabOverview.place(self);
}

/// Tell every terminal of every tab its new DPI, `dpi`: a child window
/// gets no WM_DPICHANGED of its own.
fn scaleTerminals(self: *Window, dpi: u16) void {
    for (self.tabs.items) |t| {
        var it = t.tree.iterator();
        while (it.next()) |entry| entry.view.scaleChanged(dpi);
    }
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
/// window's command palette, or of its tab overview, while that is open
/// and shows, which holds the keyboard until it closes
/// (`CommandPalette.Palette.focusTarget`); else
/// its search field while the field had it last and shows, else the
/// terminal (`SearchBar.Bar.focusTarget`).
pub fn focusTarget(surface: *const Surface) win32.HWND {
    return surface.window.palette.focusTarget() orelse
        surface.window.overview.focusTarget() orelse
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

/// For tests: answers in place of GetActiveWindow (`activeWindow`), as
/// `test_get_focus` does for GetFocus.
pub var test_get_active: if (builtin.is_test) ?*const fn () ?win32.HWND else void =
    if (builtin.is_test) null else {};

/// The active window on this thread, GetActiveWindow's answer.
pub fn activeWindow() ?win32.HWND {
    if (builtin.is_test) if (test_get_active) |get| return get();
    return win32.GetActiveWindow();
}

/// The window with the keyboard focus on this thread, GetFocus's answer.
pub fn keyboardFocus() ?win32.HWND {
    if (builtin.is_test) if (test_get_focus) |get| return get();
    return win32.GetFocus();
}

/// SetFocus(`hwnd`), a window of this frame or of its command palette;
/// with `active_only`, only while the frame or its palette is the active
/// window, as another would be activated by it.
pub fn setKeyboardFocus(self: *const Window, hwnd: win32.HWND, active_only: bool) void {
    if (builtin.is_test) if (test_set_focus) |seen| return seen(hwnd);
    if (active_only and !self.holdsActivation()) return;
    _ = win32.SetFocus(hwnd);
}

/// Whether the frame or its command palette, a pop-up of its own, is the
/// active window.
pub fn holdsActivation(self: *const Window) bool {
    const active = activeWindow() orelse return false;
    return active == self.hwnd or active == self.palette.hwnd;
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
/// and dividers tile `area` exactly, while keeping each side its least
/// (`splitArea`). `tree.spatial` describes the same layout without
/// dividers or leasts, but normalized to f16, which is up to two pixels
/// off at 3840 pixels across. Each split asks its sides' leasts, a walk of
/// the terminals under it (`leastUnder`), so a terminal's least is read
/// once for each split above it, without allocating.
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
            const sides = splitArea(area, across, s.ratio, divider, sidesLeast(tree, s, divider));
            if (sides.line > 0) ctx.divider(handle, sides.divider, across, area);
            layoutNode(tree, s.left, sides.first, divider, ctx);
            layoutNode(tree, s.right, sides.second, divider, ctx);
        },
    }
}

/// How a split divides `area` (`layout`): `divider` pixels for the line
/// between its sides, fewer if it is narrower than that, and the rest by
/// `ratio`, to the nearest pixel, for the first side (left or top), but
/// within `firstRange`: each side keeps its `least` where there is room
/// for both, and else the first does as far as there is room for it. As
/// GTK holds its split (`syncSplitRatio` in
/// src/apprt/gtk/class/split_tree.zig), with its first side's least
/// before the second's. The ratio is left as it is, for when the area
/// grows again, as GTK's tree keeps it.
pub fn splitArea(area: win32.RECT, across: bool, ratio: f16, divider: i32, least: Least) Sides {
    const sides = lineAndRest(area, across, divider);
    const range = firstRange(sides.rest, least);
    const first = std.math.clamp(firstExtent(sides.rest, ratio), range.lo, range.hi);
    return splitAt(area, across, sides.line, first);
}

/// The least pixels a split's sides are laid out in along its axis
/// (`splitArea`): what the terminals of each need (`sidesLeast`).
pub const Least = struct {
    first: i32,
    second: i32,
};

/// Of a split's `area`, the pixels across (`across`) or down its line
/// takes, `divider` or fewer if the area is narrower, and the rest, which
/// its sides share (`splitArea`).
pub fn lineAndRest(area: win32.RECT, across: bool, divider: i32) struct { line: i32, rest: i32 } {
    const total = @max(0, if (across) area.right - area.left else area.bottom - area.top);
    const line = std.math.clamp(divider, 0, total);
    return .{ .line = line, .rest = total - line };
}

/// Where a split's first side may end, of the `rest` pixels its line
/// leaves (`splitArea`): from `lo`, its least, to `hi`, what leaves the
/// second side its least. Where `rest` holds only the first side's least,
/// `lo` and `hi` are both that, or all of `rest` if it holds less.
pub fn firstRange(rest: i32, least: Least) struct { lo: i32, hi: i32 } {
    assert(rest >= 0 and least.first >= 0 and least.second >= 0);
    const lo = @min(least.first, rest);
    return .{ .lo = lo, .hi = @max(lo, rest - least.second) };
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
/// taking the rest: `splitArea` once it has found `first`.
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

/// How many of `rest` pixels, a split's area less its line, its first
/// side has at `ratio`, to the nearest pixel, before `splitArea` keeps
/// each side its least.
pub fn firstExtent(rest: i32, ratio: f16) i32 {
    const scaled = @round(@as(f32, @floatFromInt(rest)) * @as(f32, ratio));
    return std.math.clamp(std.math.lossyCast(i32, scaled), 0, rest);
}

/// Where `split` puts a new terminal beside one at `area`: the side
/// `where` names of `area` split as `layout` will split it, at
/// `new_split_ratio`, each side needing `least` pixels across the split.
/// Null if either would have less: a terminal with no room takes the
/// focus and shows nothing.
fn newPaneArea(
    area: win32.RECT,
    where: Tree.Split.Direction,
    divider: i32,
    least: i32,
) ?win32.RECT {
    const across = where == .left or where == .right;
    const sides = splitArea(area, across, new_split_ratio, divider, .{ .first = least, .second = least });
    const new, const left = switch (where) {
        .left, .up => .{ sides.first, sides.second },
        .right, .down => .{ sides.second, sides.first },
    };
    const extent = struct {
        fn extent(r: win32.RECT, a: bool) i32 {
            return if (a) r.right - r.left else r.bottom - r.top;
        }
    }.extent;
    if (extent(new, across) < least or extent(left, across) < least) return null;
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

/// Whether a frame's title bar is dark: by the theme `set_window_theme` set
/// for the session (`override`, `App.window_theme_override`), whatever
/// `window-theme` says, and by `window-theme` under `config`, as GTK picks
/// its color scheme (`Application.colorScheme`). `auto` follows the
/// background, light above a perceived luminance of 0.5 as on GTK and
/// macOS, except with a light and a dark `theme`, when it follows the
/// system: `Config.finalize` turns such an `auto` into `system`. `ghostty`,
/// the GTK header bar in the terminal's colors, is taken as `auto`, as GTK
/// takes it when it picks its color scheme, and finalize leaves it alone,
/// so the pair is checked here. Followed by the background, a pair would
/// pick the scheme from the half it picked: stuck on one half, or, if the
/// light half is dark, flipping between them for good.
pub fn frameDark(
    config: *const configpkg.Config,
    system: apprt.ColorScheme,
    override: apprt.action.WindowTheme,
) bool {
    return switch (override) {
        .config => switch (config.@"window-theme") {
            .light => false,
            .dark => true,
            .system => system == .dark,
            .auto, .ghostty => if (config._conditional_set.contains(.theme))
                system == .dark
            else
                config.background.toTerminalRGB().perceivedLuminance() <= 0.5,
        },
        .system => system == .dark,
        .light => false,
        .dark => true,
    };
}

/// Give the frame the title bar `frameDark` asks for, through DWM's
/// immersive dark mode. A visible frame repaints its title bar by itself.
/// A failed call leaves `dark_frame` as it was, so the next one tries
/// again.
pub fn applyTheme(self: *Window) void {
    const dark = frameDark(&self.app.config, self.app.system_scheme, self.app.window_theme_override);
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
    // And its title prompt's and Kitty clipboard prompt's title bars, if
    // they are open.
    TitleDialog.setDark(self, dark);
    if (self.clipboard_prompt) |prompt| TitleDialog.darkTitleBar(prompt, dark);
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
    TabOverview.invalidate(self);
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

/// WM_GETMINMAXINFO: the least size the frame may be made, so that its
/// terminals have what they need (`leastClient`), with its frame and the
/// bar, the frame measured as `resizeClient` measures it. As GTK's window,
/// which is never smaller than its content's minimum nor than the size
/// its first terminal asks for (`setSizeRequest` in
/// src/apprt/gtk/class/window.zig). No more than the work area of its
/// monitor, so that it still fits there, and no less than Windows' own
/// least. Not while it is minimized: its window rect is then the icon's.
/// Nor while a DPI change applies Windows' suggested rect
/// (`dpi_changing`): the frame may then still be the old DPI's, too large
/// or too small for the new one; `growToLeast` keeps the least after.
fn minTrackSize(self: *const Window, info: *win32.MINMAXINFO) void {
    if (self.dpi_changing or win32.IsIconic(self.hwnd).toBool()) return;
    var window: win32.RECT = undefined;
    var client: win32.RECT = undefined;
    if (!win32.GetWindowRect(self.hwnd, &window).toBool() or !win32.GetClientRect(self.hwnd, &client).toBool()) {
        log.warn("unable to read the window frame for its least size err={}", .{win32.GetLastError()});
        return;
    }
    const monitor = monitorInfo(win32.MonitorFromWindow(self.hwnd, win32.MONITOR_DEFAULTTONEAREST)) orelse return;
    const work = monitor.rcWork;
    const least = self.leastClient();
    const frame_w = (window.right - window.left) - (client.right - client.left);
    const frame_h = (window.bottom - window.top) - (client.bottom - client.top);
    const width = @min(least.width +| frame_w, work.right - work.left);
    const height = @min(least.height +| self.barHeight() +| frame_h, work.bottom - work.top);
    info.ptMinTrackSize.x = @max(info.ptMinTrackSize.x, width);
    info.ptMinTrackSize.y = @max(info.ptMinTrackSize.y, height);
}

/// The least client area under the bar the window's terminals need, the
/// largest across and down of: each tab's tree's least (`leastUnder`),
/// shown or not, and zoomed or not, so that showing it or ending its zoom
/// still fits; and each terminal's `min_size`, from the DPI of its pixels
/// to the window's.
fn leastClient(self: *const Window) struct { width: i32, height: i32 } {
    const dpi = dpiOf(self.app, self.hwnd);
    const divider = dividerWidth(dpi);
    var width: i32 = 0;
    var height: i32 = 0;
    for (self.tabs.items) |t| {
        if (t.tree.isEmpty()) continue;
        width = @max(width, leastUnder(&t.tree, .root, true, divider));
        height = @max(height, leastUnder(&t.tree, .root, false, divider));
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            const min = entry.view.min_size orelse continue;
            width = @max(width, atDpi(min.width, dpi, min.dpi));
            height = @max(height, atDpi(min.height, dpi, min.dpi));
        }
    }
    return .{ .width = width, .height = height };
}

/// WM_SIZING with `window-step-resize`: `rect`, the frame a drag of the
/// border at `edge` (a WMSZ_*) is about to give the window, becomes the
/// nearest that leaves the focused terminal whole cells, as macOS sizes a
/// window by its focused terminal's cell (`cellSizeDidChange` in
/// BaseTerminalController.swift). Windows asks from where the pointer is
/// each time, not from the last answer, so a slow drag steps too. The
/// steps are the drag's (`step_drag`), counted from the frame as its first
/// WM_SIZING finds it: with splits a frame a cell wider does not make the
/// focused terminal a cell wider, so no size leaves every terminal whole
/// cells, and counting anew at each message would give one place of the
/// pointer more than one size. Only a drag steps: a maximized or snapped
/// frame, and one `resizeClient` sizes, is as large as it was asked to be.
/// False, with `rect` as it was, without the option or without a terminal
/// to count by.
fn stepSizing(self: *Window, edge: win32.WPARAM, rect: *win32.RECT) bool {
    if (!self.app.config.@"window-step-resize") return false;
    const drag = self.step_drag orelse drag: {
        const now = self.stepDragNow() orelse return false;
        self.step_drag = now;
        break :drag now;
    };
    stepRect(rect, @fromBackingInt(edge), drag.across, drag.down);
    return true;
}

/// What a drag of the border that starts now steps by: the focused
/// terminal's cells, from the frame as it is, within Windows' bounds and
/// the window's own least (`minTrackSize`). Null with no terminal to count
/// by: none focused, or one with no core or no cell.
fn stepDragNow(self: *const Window) ?StepDrag {
    const surface = self.tab().focused orelse return null;
    const core = surface.liveCore() orelse return null;
    var frame: win32.RECT = undefined;
    if (!win32.GetWindowRect(self.hwnd, &frame).toBool()) {
        log.warn("unable to read the window frame for its steps err={}", .{win32.GetLastError()});
        return null;
    }
    var info = std.mem.zeroes(win32.MINMAXINFO);
    info.ptMinTrackSize = self.system_track.least;
    self.minTrackSize(&info);
    const least = info.ptMinTrackSize;
    const most = self.system_track.most;
    return .{
        .across = stepsAlong(core, true, frame.right - frame.left, least.x, most.x) orelse return null,
        .down = stepsAlong(core, false, frame.bottom - frame.top, least.y, most.y) orelse return null,
    };
}

/// One direction of a drag in steps by `core`'s cells, for a frame
/// `extent` long there now and kept from `least` to `most`. The steps
/// count from what the frame would be with whole cells in the terminal:
/// its length now less what the grid leaves over of the core's screen
/// after the configured padding. Not after the core's own padding
/// (`renderer.Size.padding`): with `window-padding-balance` that has what
/// is left over spread into it. Null with no cell.
fn stepsAlong(core: *const CoreSurface, across: bool, extent: i32, least: i32, most: i32) ?Steps {
    const along = measureAlong(core, across);
    if (along.cell == 0) return null;
    const screen: u64 = if (across) core.size.screen.width else core.size.screen.height;
    const over = (screen -| along.padding) % along.cell;
    return .{
        .base = extent -| std.math.lossyCast(i32, over),
        .step = std.math.lossyCast(i32, along.cell),
        .least = least,
        .most = most,
    };
}

/// After a DPI change applied Windows' suggested rect, which
/// `minTrackSize` left as it was: if that left the client area less than
/// its terminals need at the new DPI (`leastClient`) with the bar, grow it
/// to that, the frame now measured at the new DPI (`resizeClient`, which
/// keeps it in the work area).
fn growToLeast(self: *Window) void {
    var client: win32.RECT = undefined;
    if (!win32.GetClientRect(self.hwnd, &client).toBool()) {
        log.warn("unable to read the client area for its least size err={}", .{win32.GetLastError()});
        return;
    }
    const least = self.leastClient();
    const width = @max(client.right, least.width);
    const height = @max(client.bottom, least.height +| self.barHeight());
    if (width == client.right and height == client.bottom) return;
    _ = resizeClient(self.hwnd, width, height);
}

/// `pixels` at DPI `from`, at DPI `to`, rounded down.
fn atDpi(pixels: u32, to: u32, from: u16) i32 {
    if (from == 0) return std.math.lossyCast(i32, pixels);
    return std.math.lossyCast(i32, @as(u64, pixels) * to / from);
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
/// (`isRestored`), as `vt-window-resize-allowed` documents it; never the
/// quick terminal (`quick`).
pub fn terminalResizable(self: *const Window, surface: *const Surface) bool {
    if (self.quick or self.tabs.items.len != 1) return false;
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
/// it has none, covers its monitor or is the quick terminal (`quick`),
/// which `reset_window_size` leaves.
pub fn defaultSize(self: *const Window) ?DefaultSize {
    if (self.fullscreen != null or self.quick) return null;
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

/// Where a window saved at `rect` (left, top, right, bottom) on a
/// monitor of `saved_dpi` goes now (`window-save-state`), on a monitor
/// of `dpi` whose work area is `work`: at the corner it had, with its
/// size scaled by how the monitor's scale changed, so that its terminals
/// keep their cells, then kept inside the work area as a new window is
/// (`constrainToWorkArea`). The monitors there are now need not be the
/// ones it was saved on; with the same ones it goes where it was.
pub fn restoredRect(rect: [4]i32, saved_dpi: u32, dpi: u32, work: win32.RECT) win32.RECT {
    const l, const t, const r, const b = rect;
    return constrainToWorkArea(
        l,
        t,
        TabBar.scaleDpi(r - l, dpi, saved_dpi),
        TabBar.scaleDpi(b - t, dpi, saved_dpi),
        work,
    );
}

/// Bring the window to the front, restoring it first if it is
/// minimized, as GTK's `gtk.Window.present` does; for `goto_window`, a
/// toast's click (`App.notificationClicked`), the command palette's jump
/// to a terminal, and `present_terminal`, which the core performs only
/// for a `present_surface` message, which only GTK's runtime sends today.
/// With a title prompt open over it, the prompt comes forward with the
/// keyboard focus in its field, not the frame it holds disabled
/// (`TitleDialog.front`). A quick terminal that is hidden, or on its way
/// out (`quickShown`), shows first (`showQuick`), as macOS shows its own
/// for one of its terminals (QuickTerminalController.focusSurface):
/// SetForegroundWindow would give the keyboard to a window off screen.
pub fn present(self: *Window) bool {
    if (self.quick and !self.quickShown()) return self.showQuick();
    return self.bringToFront();
}

/// `present` for a window that shows.
fn bringToFront(self: *Window) bool {
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
/// inside a core frame (`App.requests`). Not the quick terminal (`quick`).
pub fn toggleFullscreen(self: *Window) void {
    if (self.quick) return;
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

/// A window's place as `window-save-state` keeps it.
pub const SavedPlace = struct {
    /// Where it is when neither maximized nor covering its monitor.
    rect: [4]i32,
    dpi: u32,
    maximized: bool,
    fullscreen: bool,
};

/// The place to save for a frame at `frame` with `placement`, covering
/// its monitor if `restore` is what that put aside, on a monitor of
/// `dpi`. A window covering its monitor is saved as what it comes back
/// to. One that is maximized, or minimized, is saved with the rect it
/// restores to; any other with the rect it has, which for a window
/// snapped to a side is not its placement's (`Restore.rect`).
///
/// A placement's rect is in workspace coordinates, which leave out the
/// taskbar and the other bars at the monitor's top and left, and a
/// frame's is in screen coordinates, as is everything a place is put
/// back with: `workspace` is where the monitor's work area starts
/// within the monitor, which makes the first the second. Saved as it
/// is, a maximized window would come back that much up and to the left
/// each time under a taskbar at the top or the left.
pub fn savedPlaceOf(
    placement: win32.WINDOWPLACEMENT,
    frame: win32.RECT,
    restore: ?Restore,
    dpi: u32,
    workspace: [2]i32,
) SavedPlace {
    const p = if (restore) |r| r.placement else placement;
    const shown = if (restore) |r| r.rect else frame;
    const minimized = p.showCmd == win32.SW_SHOWMINIMIZED;
    const maximized = p.showCmd == win32.SW_SHOWMAXIMIZED or
        (minimized and p.flags & win32.WPF_RESTORETOMAXIMIZED != 0);
    const rect: win32.RECT = if (maximized or minimized) .{
        .left = p.rcNormalPosition.left + workspace[0],
        .top = p.rcNormalPosition.top + workspace[1],
        .right = p.rcNormalPosition.right + workspace[0],
        .bottom = p.rcNormalPosition.bottom + workspace[1],
    } else shown;
    return .{
        .rect = .{ rect.left, rect.top, rect.right, rect.bottom },
        .dpi = dpi,
        .maximized = maximized,
        .fullscreen = restore != null,
    };
}

/// The window's place to save (`savedPlaceOf`), or null, logged, if it
/// cannot be read.
pub fn savedPlace(self: *const Window) ?SavedPlace {
    var placement = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    var frame: win32.RECT = undefined;
    if (!win32.GetWindowPlacement(self.hwnd, &placement).toBool() or
        !win32.GetWindowRect(self.hwnd, &frame).toBool())
    {
        log.warn("cannot read a window's place to save it err={}", .{win32.GetLastError()});
        return null;
    }
    // The monitor the window is on, or was before it was minimized, is
    // the one its placement's rect is counted on.
    const workspace: [2]i32 = if (monitorInfo(win32.MonitorFromWindow(self.hwnd, win32.MONITOR_DEFAULTTONEAREST))) |info|
        .{ info.rcWork.left - info.rcMonitor.left, info.rcWork.top - info.rcMonitor.top }
    else
        .{ 0, 0 };
    return savedPlaceOf(placement, frame, self.fullscreen, dpiOf(self.app, self.hwnd), workspace);
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
pub fn monitorInfo(monitor: ?win32.HMONITOR) ?win32.MONITORINFO {
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
/// so this never runs inside a core frame (`App.requests`). Not the quick
/// terminal, which has none (`quick`).
pub fn toggleDecorations(self: *Window) void {
    if (self.quick) return;
    self.decoration = if (self.decoration != null) null else switch (self.app.config.@"window-decoration") {
        .none => .auto,
        .auto, .client, .server => .none,
    };
    self.applyDecorations();
}

/// Give the frame the styles `isDecorated` asks for, keeping its rect, or a
/// maximized one the work area (`refitMaximized`). A window that covers its
/// monitor has none of them, and takes them when it leaves
/// (`toggleFullscreen`); the quick terminal never has them (`quick`). The
/// client area grows or shrinks by the caption, and the terminals are laid
/// out again from the frame's WM_SIZE, so this never runs inside a core
/// frame (`App.requests`).
pub fn applyDecorations(self: *Window) void {
    if (self.fullscreen != null or self.quick) return;
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
/// again. False, logged, if SetWindowPos fails or the window does not
/// float as asked afterwards.
///
/// SetWindowPos succeeding does not mean that it did: a window procedure
/// may take the change of z-order out of WM_WINDOWPOSCHANGING, and another
/// program may restack the window, or a window it owns, at any time (when
/// a topmost window is made non-topmost, so are its owners, SetWindowPos
/// documents). So the answer is whether the window floats as asked once
/// SetWindowPos returns, read as `isFloating` reads it. It is not tried
/// again. False for the quick terminal, which floats while it shows
/// (`showQuick`).
pub fn setFloating(self: *Window, on: bool) bool {
    if (self.quick) return false;
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
    if (self.isFloating() != on) {
        log.warn("the window does not float as asked although SetWindowPos succeeded on={}", .{on});
        return false;
    }
    return true;
}

/// `.toggle_maximize`: maximize the window, or restore it, by whether it
/// is maximized now, as GTK decides (`surfaceToggleMaximize`): the user
/// also maximizes and restores it with the caption buttons, a double click
/// and Win+Up and Win+Down. Not the quick terminal, which has neither
/// (`quick`).
pub fn toggleMaximize(self: *Window) void {
    if (self.quick) return;
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

/// The edge or corner of a frame a WM_SIZING says is dragged (WMSZ_*).
/// Any other value moves no edge.
pub const SizingEdge = enum(win32.WPARAM) {
    left = 1,
    right = 2,
    top = 3,
    top_left = 4,
    top_right = 5,
    bottom = 6,
    bottom_left = 7,
    bottom_right = 8,
    _,

    const Moves = struct { left: bool = false, right: bool = false, top: bool = false, bottom: bool = false };

    /// The edges of the frame's rect a drag of this one moves.
    fn moves(self: SizingEdge) Moves {
        return switch (self) {
            .left => .{ .left = true },
            .right => .{ .right = true },
            .top => .{ .top = true },
            .top_left => .{ .top = true, .left = true },
            .top_right => .{ .top = true, .right = true },
            .bottom => .{ .bottom = true },
            .bottom_left => .{ .bottom = true, .left = true },
            .bottom_right => .{ .bottom = true, .right = true },
            _ => .{},
        };
    }
};

/// One direction of a drag of a frame's border in steps
/// (`window-step-resize`), in pixels of the frame: the length the steps
/// count from, one step, and the bounds the frame is kept within.
pub const Steps = struct {
    base: i32,
    step: i32,
    least: i32,
    most: i32,

    /// The length nearest `proposed` that is `base` and a whole number of
    /// steps, half a step counting as the next one; then, by whole steps,
    /// not over `most`, and last not under `least`, which a `most` under
    /// it gives way to. `proposed` itself with no step.
    pub fn nearest(self: Steps, proposed: i32) i32 {
        if (self.step <= 0) return proposed;
        const step: i64 = self.step;
        const base: i64 = self.base;
        var n = @divFloor(proposed - base + @divTrunc(step, 2), step);
        n = @min(n, @divFloor(self.most - base, step));
        // Never an error: the step is over 0.
        n = @max(n, std.math.divCeil(i64, self.least - base, step) catch unreachable);
        return std.math.lossyCast(i32, base + n * step);
    }
};

/// What a drag of a frame's border steps by, across and down.
const StepDrag = struct { across: Steps, down: Steps };

/// Bounds for a drag of a frame's border, each a frame's width and height.
/// None until Windows gives its own (`system_track`).
const TrackBounds = struct {
    least: win32.POINT = .{ .x = 0, .y = 0 },
    most: win32.POINT = .{ .x = std.math.maxInt(i32), .y = std.math.maxInt(i32) },
};

/// `rect`, the frame a drag of `edge` asks for, at the nearest steps
/// across and down (`Steps.nearest`). Only the dragged edges move: the
/// others stay where Windows has them, which is where the drag began.
fn stepRect(rect: *win32.RECT, edge: SizingEdge, across: Steps, down: Steps) void {
    const m = edge.moves();
    if (m.left or m.right) {
        const width = across.nearest(rect.right -| rect.left);
        if (m.left) rect.left = rect.right -| width else rect.right = rect.left +| width;
    }
    if (m.top or m.bottom) {
        const height = down.nearest(rect.bottom -| rect.top);
        if (m.top) rect.top = rect.bottom -| height else rect.bottom = rect.top +| height;
    }
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

test "win32: a saved window goes where it was, at today's scale, on a monitor there is" {
    const work: win32.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const eq = struct {
        fn f(expected: [4]i32, actual: win32.RECT) !void {
            try std.testing.expectEqual(expected, [4]i32{ actual.left, actual.top, actual.right, actual.bottom });
        }
    }.f;

    // The same monitor: where it was, whatever the scale is.
    try eq(.{ 100, 50, 1300, 850 }, restoredRect(.{ 100, 50, 1300, 850 }, 144, 144, work));
    try eq(.{ 0, 0, 1920, 1040 }, restoredRect(.{ 0, 0, 1920, 1040 }, 96, 96, work));

    // A scale that changed keeps the corner and scales the size, up and
    // down, to the nearest pixel.
    try eq(.{ 100, 50, 700, 500 }, restoredRect(.{ 100, 50, 500, 350 }, 96, 144, work));
    try eq(.{ 100, 50, 500, 350 }, restoredRect(.{ 100, 50, 700, 500 }, 144, 96, work));
    try eq(.{ 10, 10, 14, 13 }, restoredRect(.{ 10, 10, 13, 12 }, 96, 120, work));

    // Off the monitors there are now: moved in, at its size.
    try eq(.{ 720, 240, 1920, 1040 }, restoredRect(.{ 3000, 2000, 4200, 2800 }, 96, 96, work));
    try eq(.{ 0, 0, 1200, 800 }, restoredRect(.{ -2500, -900, -1300, -100 }, 96, 96, work));
    // Larger than the work area, as it is once scaled: made to fit.
    try eq(.{ 0, 0, 1920, 1040 }, restoredRect(.{ 100, 50, 1700, 1050 }, 96, 144, work));

    // The widest rect a state holds, at the largest scale, overflows
    // nothing.
    try eq(.{ 0, 0, 1920, 1040 }, restoredRect(.{ -32767, -32767, 32767, 32767 }, 48, 960, work));
}

test "win32: a window is saved with the place it comes back to" {
    const normal: win32.RECT = .{ .left = 100, .top = 50, .right = 900, .bottom = 650 };
    const snapped: win32.RECT = .{ .left = 0, .top = 0, .right = 960, .bottom = 1040 };
    const monitor: win32.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    var placement = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.rcNormalPosition = normal;
    placement.showCmd = @intCast(win32.SW_SHOWNORMAL);

    // As it is: the rect it has, which for a snapped one is not its
    // placement's.
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 0, 0, 960, 1040 }, .dpi = 144, .maximized = false, .fullscreen = false },
        savedPlaceOf(placement, snapped, null, 144, .{ 0, 0 }),
    );

    // Maximized, or minimized from either: the rect it restores to.
    var maximized = placement;
    maximized.showCmd = @intCast(win32.SW_SHOWMAXIMIZED);
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 100, 50, 900, 650 }, .dpi = 96, .maximized = true, .fullscreen = false },
        savedPlaceOf(maximized, monitor, null, 96, .{ 0, 0 }),
    );
    var minimized = placement;
    minimized.showCmd = @intCast(win32.SW_SHOWMINIMIZED);
    const off: win32.RECT = .{ .left = -32000, .top = -32000, .right = -31840, .bottom = -31972 };
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 100, 50, 900, 650 }, .dpi = 96, .maximized = false, .fullscreen = false },
        savedPlaceOf(minimized, off, null, 96, .{ 0, 0 }),
    );
    minimized.flags = win32.WPF_RESTORETOMAXIMIZED;
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 100, 50, 900, 650 }, .dpi = 96, .maximized = true, .fullscreen = false },
        savedPlaceOf(minimized, off, null, 96, .{ 0, 0 }),
    );

    // Under a taskbar at the top or the left a placement's rect is not
    // where the window is on the screen; a frame's is.
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 172, 90, 972, 690 }, .dpi = 96, .maximized = true, .fullscreen = false },
        savedPlaceOf(maximized, monitor, null, 96, .{ 72, 40 }),
    );
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 172, 90, 972, 690 }, .dpi = 96, .maximized = true, .fullscreen = false },
        savedPlaceOf(minimized, off, null, 96, .{ 72, 40 }),
    );
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 0, 0, 960, 1040 }, .dpi = 144, .maximized = false, .fullscreen = false },
        savedPlaceOf(placement, snapped, null, 144, .{ 72, 40 }),
    );

    // Covering its monitor: what it comes back to, not the monitor.
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 0, 0, 960, 1040 }, .dpi = 96, .maximized = false, .fullscreen = true },
        savedPlaceOf(placement, monitor, .{ .placement = placement, .rect = snapped }, 96, .{ 0, 0 }),
    );
    try std.testing.expectEqual(
        SavedPlace{ .rect = .{ 100, 50, 900, 650 }, .dpi = 96, .maximized = true, .fullscreen = true },
        savedPlaceOf(placement, monitor, .{ .placement = maximized, .rect = monitor }, 96, .{ 0, 0 }),
    );
}

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

test "win32: the quick terminal is placed on the work area at its position" {
    const testing = std.testing;
    const RECT = win32.RECT;

    // 1920x1040, not at zero: taskbars on the left and at the top.
    const work: RECT = .{ .left = 10, .top = 20, .right = 1930, .bottom = 1060 };

    // By default all of its edge, 400 pixels deep, or 800x400 in the
    // middle (`QuickTerminalSize.calculate`), flush with the edge.
    try testing.expectEqual(RECT{ .left = 10, .top = 20, .right = 1930, .bottom = 420 }, quickPlace(.top, .{}, work, 96));
    try testing.expectEqual(RECT{ .left = 10, .top = 660, .right = 1930, .bottom = 1060 }, quickPlace(.bottom, .{}, work, 96));
    try testing.expectEqual(RECT{ .left = 10, .top = 20, .right = 410, .bottom = 1060 }, quickPlace(.left, .{}, work, 96));
    try testing.expectEqual(RECT{ .left = 1530, .top = 20, .right = 1930, .bottom = 1060 }, quickPlace(.right, .{}, work, 96));
    try testing.expectEqual(RECT{ .left = 570, .top = 340, .right = 1370, .bottom = 740 }, quickPlace(.center, .{}, work, 96));

    // Shorter than its edge: centred along it. The primary size is the
    // depth from the edge, the secondary the length along it.
    try testing.expectEqual(
        RECT{ .left = 490, .top = 20, .right = 1450, .bottom = 540 },
        quickPlace(.top, .{ .primary = .{ .percentage = 50 }, .secondary = .{ .percentage = 50 } }, work, 96),
    );
    try testing.expectEqual(
        RECT{ .left = 1630, .top = 270, .right = 1930, .bottom = 810 },
        quickPlace(.right, .{ .primary = .{ .pixels = 300 }, .secondary = .{ .pixels = 540 } }, work, 96),
    );

    // On a work area taller than it is wide, the middle's is 400x800.
    try testing.expectEqual(
        RECT{ .left = -500, .top = 100, .right = -100, .bottom = 900 },
        quickPlace(.center, .{}, .{ .left = -600, .top = 0, .right = 0, .bottom = 1000 }, 96),
    );

    // No larger than the work area, including percentages `toPixels`
    // could not make into a u32, and at least a pixel. A NaN one is the
    // default.
    try testing.expectEqual(work, quickPlace(.center, .{ .primary = .{ .pixels = 5000 }, .secondary = .{ .pixels = 5000 } }, work, 96));
    try testing.expectEqual(work, quickPlace(.center, .{
        .primary = .{ .percentage = 1e30 },
        .secondary = .{ .percentage = std.math.inf(f32) },
    }, work, 96));
    try testing.expectEqual(RECT{ .left = 10, .top = 20, .right = 1930, .bottom = 21 }, quickPlace(.top, .{ .primary = .{ .pixels = 0 } }, work, 96));
    try testing.expectEqual(quickPlace(.left, .{}, work, 96), quickPlace(.left, .{ .primary = .{ .percentage = std.math.nan(f32) } }, work, 96));
}

test "win32: the quick terminal's size is in DIPs, and all of the work area is all of it" {
    const testing = std.testing;
    const RECT = win32.RECT;
    const work: RECT = .{ .left = 10, .top = 20, .right = 1930, .bottom = 1060 };

    // `px` and the 400 when no size is set are DIPs: half as many pixels
    // again at 144 DPI, twice as many at 192. A percentage is the work
    // area's at any DPI, to within the DIP that rounding the work area up
    // may add.
    try testing.expectEqual(RECT{ .left = 10, .top = 20, .right = 1930, .bottom = 620 }, quickPlace(.top, .{}, work, 144));
    try testing.expectEqual(RECT{ .left = 10, .top = 20, .right = 810, .bottom = 1060 }, quickPlace(.left, .{}, work, 192));
    try testing.expectEqual(
        RECT{ .left = 1555, .top = 202, .right = 1930, .bottom = 877 },
        quickPlace(.right, .{ .primary = .{ .pixels = 300 }, .secondary = .{ .pixels = 540 } }, work, 120),
    );
    try testing.expectEqual(
        RECT{ .left = 490, .top = 20, .right = 1450, .bottom = 540 },
        quickPlace(.top, .{ .primary = .{ .percentage = 50 }, .secondary = .{ .percentage = 50 } }, work, 144),
    );
    // The middle's 800x400 too, from the work area in DIPs.
    try testing.expectEqual(RECT{ .left = 370, .top = 240, .right = 1570, .bottom = 840 }, quickPlace(.center, .{}, work, 144));
    // Still no larger than the work area.
    try testing.expectEqual(work, quickPlace(.center, .{ .primary = .{ .pixels = 1500 }, .secondary = .{ .pixels = 1500 } }, work, 192));
    // A DPI of 0 is 96's.
    try testing.expectEqual(quickPlace(.right, .{}, work, 96), quickPlace(.right, .{}, work, 0));

    // All of a work area whose sides no DPI divides evenly is all of it,
    // at every DPI from 96 to five times as many: `100%`, and the whole
    // edge when the length along it is not set.
    const odd: RECT = .{ .left = -1919, .top = 7, .right = 0, .bottom = 1048 };
    const all: configpkg.Config.QuickTerminalSize = .{
        .primary = .{ .percentage = 100 },
        .secondary = .{ .percentage = 100 },
    };
    var dpi: u32 = 96;
    while (dpi <= 480) : (dpi += 1) {
        try testing.expectEqual(odd, quickPlace(.center, all, odd, dpi));
        const top = quickPlace(.top, .{}, odd, dpi);
        try testing.expectEqual(odd.left, top.left);
        try testing.expectEqual(odd.right, top.right);
        const left = quickPlace(.left, .{}, odd, dpi);
        try testing.expectEqual(odd.top, left.top);
        try testing.expectEqual(odd.bottom, left.bottom);
    }
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

/// For the layout tests: a view with a name and no reference count, which
/// needs `across` pixels across and `down` down (`leastOf`), none unless
/// a test says.
const TestPane = struct {
    name: u8,
    across: i32 = 0,
    down: i32 = 0,

    pub fn ref(self: *TestPane) *TestPane {
        return self;
    }

    pub fn unref(self: *TestPane) void {
        _ = self;
    }

    pub fn least(self: *const TestPane, across: bool) i32 {
        return if (across) self.across else self.down;
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
        try std.testing.expect(!frameDark(&config, system, .config));
        config.@"window-theme" = .dark;
        try std.testing.expect(frameDark(&config, system, .config));
        config.@"window-theme" = .system;
        try std.testing.expectEqual(system == .dark, frameDark(&config, system, .config));
    }

    // auto and ghostty: the background, whatever the system's mode. The
    // default one, 0x282C34, is dark.
    for ([_]configpkg.Config.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        config.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
        try std.testing.expect(frameDark(&config, .light, .config));
        config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        try std.testing.expect(!frameDark(&config, .dark, .config));
    }

    // With a light and a dark theme, which Config.finalize marks in the
    // conditional set: the system's mode, whatever the background. finalize
    // makes such an auto system ("theme specifying light/dark changes
    // window-theme from auto"); ghostty stays as it is.
    config._conditional_set.insert(.theme);
    for ([_]configpkg.Config.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        try std.testing.expect(frameDark(&config, .dark, .config));
        config.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
        try std.testing.expect(!frameDark(&config, .light, .config));
    }
}

test "win32: a theme set for the session overrides window-theme" {
    // `set_window_theme`'s system, light and dark, over every
    // `window-theme`, background, system mode and pair of themes: the
    // system's mode, light and dark, whatever the configuration says.
    // `config` is the configuration's answer (the test above).
    const alloc = std.testing.allocator;
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    const themes = std.enums.values(configpkg.Config.WindowTheme);
    var checked: usize = 0;
    for ([_]bool{ false, true }) |pair| {
        config._conditional_set = .{};
        if (pair) config._conditional_set.insert(.theme);
        for (themes) |theme| {
            config.@"window-theme" = theme;
            for ([_]bool{ false, true }) |light_background| {
                config.background = if (light_background)
                    .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }
                else
                    .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
                for ([_]apprt.ColorScheme{ .light, .dark }) |system| {
                    try std.testing.expectEqual(system == .dark, frameDark(&config, system, .system));
                    try std.testing.expect(!frameDark(&config, system, .light));
                    try std.testing.expect(frameDark(&config, system, .dark));
                    checked += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(2 * themes.len * 2 * 2, checked);
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

test "win32: a split needs room for its least on each side" {
    // A terminal with no room would take the focus and show nothing:
    // splitting the newest one again and again ends at no width at all.
    const divider = 2;
    const least = 10;
    // 22 wide: 10 on each side of the divider, just enough.
    const fits: win32.RECT = .{ .left = 0, .top = 0, .right = 22, .bottom = 300 };
    for ([_]TestTree.Split.Direction{ .left, .right }) |where| {
        try std.testing.expect(newPaneArea(fits, where, divider, least) != null);
    }
    // 21 wide: one side gets 9.
    const narrow: win32.RECT = .{ .left = 0, .top = 0, .right = 21, .bottom = 300 };
    for ([_]TestTree.Split.Direction{ .left, .right }) |where| {
        try std.testing.expect(newPaneArea(narrow, where, divider, least) == null);
    }
    // Across the other axis, the height counts.
    const short: win32.RECT = .{ .left = 0, .top = 0, .right = 300, .bottom = 21 };
    for ([_]TestTree.Split.Direction{ .up, .down }) |where| {
        try std.testing.expect(newPaneArea(short, where, divider, least) == null);
    }
    try std.testing.expect(newPaneArea(short, .right, divider, least) != null);
}

test "win32: a split keeps each side its least, the first side's first" {
    // a | b over 101 pixels and a line of 1: 100 for the two. a needs 30
    // and b 20, so a's side ends from 30 to 80, whatever the ratio.
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a', .across = 30 };
    var b: TestPane = .{ .name = 'b', .across = 20 };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var tree = try testSplit(&only_a, .root, .right, 0.5, &b);
    defer tree.deinit();
    const width = struct {
        fn width(t: *const TestTree, view: *const TestPane, w: i32) !i32 {
            const area: win32.RECT = .{ .left = 0, .top = 0, .right = w, .bottom = 40 };
            var got: TestLayout = .{};
            layout(t, area, 1, &got);
            try got.expectTiles(area);
            const r = got.rectOf(view);
            return r.right - r.left;
        }
    }.width;
    for ([_][2]f16{ .{ 0, 30 }, .{ 0.1, 30 }, .{ 0.3, 30 }, .{ 0.31, 31 }, .{ 0.5, 50 }, .{ 0.8, 80 }, .{ 0.9, 80 }, .{ 1, 80 } }) |c| {
        tree.resizeInPlace(.root, c[0]);
        try std.testing.expectEqual(@as(i32, @intFromFloat(c[1])), try width(&tree, &a, 101));
    }
    // The ratio is kept: wider, a has 0.9 of it again.
    try std.testing.expectEqual(@as(f16, 1), tree.nodes[0].split.ratio);
    tree.resizeInPlace(.root, 0.9);
    try std.testing.expectEqual(80, try width(&tree, &a, 101));
    try std.testing.expectEqual(270, try width(&tree, &a, 301));

    // With room for less than both, a keeps its 30 and b has what is left;
    // with less than a's 30, a has it all.
    try std.testing.expectEqual(30, try width(&tree, &a, 41));
    try std.testing.expectEqual(10, try width(&tree, &b, 41));
    tree.resizeInPlace(.root, 0);
    try std.testing.expectEqual(10, try width(&tree, &b, 41));
    try std.testing.expectEqual(20, try width(&tree, &a, 21));
    try std.testing.expectEqual(0, try width(&tree, &b, 21));
}

test "win32: a split's least adds up along it and is the larger across it" {
    // a | (b over c), lines of 2: across, a's 30 and the larger of b's 20
    // and c's 25 with a line, 57; down, the larger of a's 10 and b's 15
    // and c's 5 with a line, 22.
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a', .across = 30, .down = 10 };
    var b: TestPane = .{ .name = 'b', .across = 20, .down = 15 };
    var c: TestPane = .{ .name = 'c', .across = 25, .down = 5 };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var ab = try testSplit(&only_a, .root, .right, 0.5, &b);
    defer ab.deinit();
    var tree = try testSplit(&ab, ab.locate(&b).?, .down, 0.5, &c);
    defer tree.deinit();
    try std.testing.expectEqual(57, leastUnder(&tree, .root, true, 2));
    try std.testing.expectEqual(22, leastUnder(&tree, .root, false, 2));
    try std.testing.expectEqual(Least{ .first = 30, .second = 25 }, sidesLeast(&tree, tree.nodes[0].split, 2));

    // In 57 by 22, each pane has its least or more.
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 57, .bottom = 22 };
    var got: TestLayout = .{};
    layout(&tree, area, 2, &got);
    try std.testing.expectEqual(win32.RECT{ .left = 0, .top = 0, .right = 30, .bottom = 22 }, got.rectOf(&a));
    try std.testing.expectEqual(win32.RECT{ .left = 32, .top = 0, .right = 57, .bottom = 15 }, got.rectOf(&b));
    try std.testing.expectEqual(win32.RECT{ .left = 32, .top = 17, .right = 57, .bottom = 22 }, got.rectOf(&c));
}

test "win32: with room for the tree's least, the layout keeps each terminal its own" {
    // Random trees of up to six panes with random leasts, at random ratios
    // (either end included), dividers and areas, some under the tree's
    // least (`leastUnder`). The panes and dividers tile the area; with the
    // tree's least each way, every pane has its own; and the ratios are
    // left as they were. Many rounds hold a pane that its ratio alone
    // would lay out smaller.
    var prng: std.Random.DefaultPrng = .init(0x4133_4c45);
    const random = prng.random();
    var panes: [6]TestPane = undefined;
    for (&panes, 0..) |*p, i| p.* = .{ .name = 'a' + @as(u8, @intCast(i)) };
    var roomy: usize = 0;
    var held: usize = 0;
    var round: usize = 0;
    while (round < 500) : (round += 1) {
        const n = random.intRangeAtMost(usize, 1, panes.len);
        for (panes[0..n]) |*p| {
            p.across = random.intRangeAtMost(i32, 0, 60);
            p.down = random.intRangeAtMost(i32, 0, 60);
        }
        var tree = try testRandomTree(TestTree, random, panes[0..n]);
        defer tree.deinit();
        const ratios = try std.testing.allocator.alloc(f16, tree.nodes.len);
        defer std.testing.allocator.free(ratios);
        for (tree.nodes, ratios) |node, *r| r.* = if (node == .split) node.split.ratio else 0;

        const divider = random.intRangeAtMost(i32, 1, 3);
        const need_w = leastUnder(&tree, .root, true, divider);
        const need_h = leastUnder(&tree, .root, false, divider);
        const fits = random.boolean();
        const area: win32.RECT = .{
            .left = random.intRangeAtMost(i32, -20, 20),
            .top = random.intRangeAtMost(i32, -20, 20),
            .right = 0,
            .bottom = 0,
        };
        var whole = area;
        whole.right = area.left + if (fits) need_w + random.intRangeAtMost(i32, 0, 200) else random.intRangeAtMost(i32, 0, need_w);
        whole.bottom = area.top + if (fits) need_h + random.intRangeAtMost(i32, 0, 200) else random.intRangeAtMost(i32, 0, need_h);
        var got: TestLayout = .{};
        layout(&tree, whole, divider, &got);
        try std.testing.expectEqual(n, got.pane_count);
        try got.expectTiles(whole);
        for (tree.nodes, ratios) |node, r| if (node == .split) try std.testing.expectEqual(r, node.split.ratio);
        if (!fits) continue;
        roomy += 1;

        for (got.panes[0..got.pane_count]) |p| {
            try std.testing.expect(p.rect.right - p.rect.left >= p.view.across);
            try std.testing.expect(p.rect.bottom - p.rect.top >= p.view.down);
        }

        // Laid out as its ratios alone put it, with no leasts.
        const kept = panes;
        for (panes[0..n]) |*p| {
            p.across = 0;
            p.down = 0;
        }
        var by_ratio: TestLayout = .{};
        layout(&tree, whole, divider, &by_ratio);
        panes = kept;
        for (by_ratio.panes[0..by_ratio.pane_count]) |p| {
            if (p.rect.right - p.rect.left < p.view.across or p.rect.bottom - p.rect.top < p.view.down) {
                held += 1;
                break;
            }
        }
    }
    try std.testing.expect(roomy > 200);
    try std.testing.expect(held > roomy / 4);
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

test "win32: a terminal's least is a cell and its padding, at its font's DPI" {
    // Cells 10 by 20 at 144 DPI, padding 2 and 3 points across, 5 and 7
    // down, 2 pixels a point: 10 + 4 + 6 = 20 across, 20 + 10 + 14 = 44
    // down. With no core, a pixel; no scroll bar until the end.
    const s = struct {
        var a: Surface = undefined;
    };
    s.a.scroll_bar = .{};
    s.a.core_state = .none;
    try std.testing.expectEqual(1, leastExtent(&s.a, true));
    try std.testing.expectEqual(1, leastExtent(&s.a, false));

    s.a.core_state = .live;
    const core = &s.a.core_surface;
    core.size.cell = .{ .width = 10, .height = 20 };
    core.font_size.xdpi = 144;
    core.font_size.ydpi = 144;
    core.config.window_padding_left = 2;
    core.config.window_padding_right = 3;
    core.config.window_padding_top = 5;
    core.config.window_padding_bottom = 7;
    try std.testing.expectEqual(20, leastExtent(&s.a, true));
    try std.testing.expectEqual(44, leastExtent(&s.a, false));

    // At 120 DPI, 5/3 pixels a point, each side rounds down on its own:
    // 3.33 and 5 across, 18; 8.33 and 11.67 down, 39.
    core.font_size.xdpi = 120;
    core.font_size.ydpi = 120;
    try std.testing.expectEqual(18, leastExtent(&s.a, true));
    try std.testing.expectEqual(39, leastExtent(&s.a, false));

    // With no padding, the cell; a cell of nothing still needs a pixel.
    core.config.window_padding_left = 0;
    core.config.window_padding_right = 0;
    try std.testing.expectEqual(10, leastExtent(&s.a, true));
    core.size.cell.width = 0;
    try std.testing.expectEqual(1, leastExtent(&s.a, true));

    // Across, the scroll bar beside them too, as wide as Windows draws it
    // at the window's DPI (`ScrollBar.width`); not down.
    const Bar = struct {
        var app: App = undefined;
        fn dpi(_: win32.HWND) callconv(.winapi) win32.UINT {
            return 144;
        }
        fn metric(index: c_int, at: win32.UINT) callconv(.winapi) c_int {
            return if (index == win32.SM_CXVSCROLL and at == 144) 25 else 0;
        }
    };
    Bar.app.bar_metric = .{ .dpi_of = &Bar.dpi, .metric_for = &Bar.metric };
    s.a.app = &Bar.app;
    s.a.hwnd = @ptrFromInt(0x1000);
    s.a.scroll_bar.on = true;
    core.size.cell.width = 10;
    try std.testing.expectEqual(10 + 25, leastExtent(&s.a, true));
    try std.testing.expectEqual(39, leastExtent(&s.a, false));
}

/// For the tests: `leaves` in a tree of type `T`, each split off a random
/// one before it in a random direction, and every split at a random
/// ratio, either end included.
pub fn testRandomTree(comptime T: type, random: std.Random, leaves: []T.View) !T {
    const alloc = std.testing.allocator;
    var tree: T = try .init(alloc, &leaves[0]);
    errdefer tree.deinit();
    for (leaves[1..]) |*leaf| {
        var pick: T.Node.Handle = .root;
        var seen: usize = 0;
        var it = tree.iterator();
        while (it.next()) |entry| {
            seen += 1;
            if (random.uintLessThan(usize, seen) == 0) pick = entry.handle;
        }
        var single: T = try .init(alloc, leaf);
        defer single.deinit();
        const next = try tree.split(alloc, pick, random.enumValue(T.Split.Direction), 0.5, &single);
        tree.deinit();
        tree = next;
    }
    for (tree.nodes, 0..) |node, i| if (node == .split) {
        const ratio: f16 = switch (random.uintLessThan(u8, 8)) {
            0 => 0,
            1 => 1,
            else => @floatCast(random.float(f32)),
        };
        tree.resizeInPlace(T.Node.Handle.root.offset(i), ratio);
    };
    return tree;
}

test "win32: a stepped length is the nearest whole steps within its bounds" {
    var prng: std.Random.DefaultPrng = .init(0x57e9_51ce);
    const random = prng.random();
    for (0..20_000) |_| {
        const s: Steps = .{
            .base = random.intRangeAtMost(i32, -50, 3000),
            .step = random.intRangeAtMost(i32, 1, 60),
            .least = random.intRangeAtMost(i32, 0, 1200),
            .most = random.intRangeAtMost(i32, 1100, 5000),
        };
        const proposed = random.intRangeAtMost(i32, -100, 6000);
        const got = s.nearest(proposed);

        // Whole steps from the base, and never under the least. Over the
        // most only as the first step at or over the least.
        try std.testing.expectEqual(0, @mod(got - s.base, s.step));
        try std.testing.expect(got >= s.least);
        if (got > s.most) {
            try std.testing.expect(got - s.step < s.least);
            continue;
        }
        // The nearest within the bounds: a step either way that is within
        // them is no nearer, and the one above is farther (half a step
        // goes up).
        const d = @abs(got - proposed);
        const below = got - s.step;
        const above = got + s.step;
        if (below >= s.least) try std.testing.expect(@abs(below - proposed) >= d);
        if (above <= s.most) try std.testing.expect(@abs(above - proposed) > d);
        // A stepped length stays.
        try std.testing.expectEqual(got, s.nearest(got));
    }
}

test "win32: a stepped length without a step, and at the ends of its type" {
    const none: Steps = .{ .base = 10, .step = 0, .least = 500, .most = 5 };
    try std.testing.expectEqual(123, none.nearest(123));

    // Half a step goes up, less stays.
    const s: Steps = .{ .base = 6, .step = 10, .least = 0, .most = 1000 };
    try std.testing.expectEqual(106, s.nearest(110));
    try std.testing.expectEqual(116, s.nearest(111));
    const odd: Steps = .{ .base = 0, .step = 9, .least = 0, .most = 1000 };
    try std.testing.expectEqual(90, odd.nearest(94));
    try std.testing.expectEqual(99, odd.nearest(95));

    // Nothing overflows.
    const min = std.math.minInt(i32);
    const max = std.math.maxInt(i32);
    const wide: Steps = .{ .base = min, .step = 7, .least = min, .most = max };
    try std.testing.expectEqual(max - 3, wide.nearest(max));
    try std.testing.expectEqual(min, wide.nearest(min));
    const high: Steps = .{ .base = min, .step = 7, .least = max, .most = min };
    try std.testing.expectEqual(max, high.nearest(0));
}

test "win32: a stepped rect moves only its dragged edges" {
    // 4 over across and 8 down, each under half a step: a dragged edge
    // moves in by them, and no other moves.
    const across: Steps = .{ .base = 16, .step = 9, .least = 100, .most = 5000 };
    const down: Steps = .{ .base = 40, .step = 19, .least = 80, .most = 5000 };
    const start: win32.RECT = .{
        .left = 100,
        .top = 50,
        .right = 100 + 16 + 9 * 40 + 4,
        .bottom = 50 + 40 + 19 * 10 + 8,
    };
    // WMSZ_LEFT to WMSZ_BOTTOMRIGHT are 1 to 8; 0 and 9 are no edge.
    const cases = [_]struct { usize, []const u8 }{
        .{ 0, "" },   .{ 1, "l" }, .{ 2, "r" },  .{ 3, "t" },  .{ 4, "tl" },
        .{ 5, "tr" }, .{ 6, "b" }, .{ 7, "bl" }, .{ 8, "br" }, .{ 9, "" },
    };
    for (cases) |case| {
        const code, const edges = case;
        const drags = struct {
            fn f(of: []const u8, edge: u8) bool {
                return std.mem.indexOfScalar(u8, of, edge) != null;
            }
        }.f;
        var rect = start;
        stepRect(&rect, @fromBackingInt(code), across, down);
        try std.testing.expectEqual(start.left + @as(i32, if (drags(edges, 'l')) 4 else 0), rect.left);
        try std.testing.expectEqual(start.right - @as(i32, if (drags(edges, 'r')) 4 else 0), rect.right);
        try std.testing.expectEqual(start.top + @as(i32, if (drags(edges, 't')) 8 else 0), rect.top);
        try std.testing.expectEqual(start.bottom - @as(i32, if (drags(edges, 'b')) 8 else 0), rect.bottom);
    }
}

test "win32: a window's position is where what shows of it starts, kept on its monitor" {
    const work: win32.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    // An 11 px border that does not show on three sides, none on top.
    const frame: win32.RECT = .{ .left = 300, .top = 200, .right = 1122, .bottom = 811 };
    const visible: win32.RECT = .{ .left = 311, .top = 200, .right = 1111, .bottom = 800 };
    const Case = struct { at: win32.POINT, shown: win32.POINT };
    for ([_]Case{
        // Where it is asked for, the corner included.
        .{ .at = .{ .x = 100, .y = 50 }, .shown = .{ .x = 100, .y = 50 } },
        .{ .at = .{ .x = 0, .y = 0 }, .shown = .{ .x = 0, .y = 0 } },
        // Past the right or the bottom: moved back until all of it shows.
        .{ .at = .{ .x = 1500, .y = 50 }, .shown = .{ .x = 1120, .y = 50 } },
        .{ .at = .{ .x = 100, .y = 900 }, .shown = .{ .x = 100, .y = 440 } },
        // Before the left or the top.
        .{ .at = .{ .x = -500, .y = -1 }, .shown = .{ .x = 0, .y = 0 } },
        .{ .at = .{ .x = 32767, .y = -32768 }, .shown = .{ .x = 1120, .y = 0 } },
    }) |case| {
        const rect = positionRect(frame, visible, case.at, work);
        // The part that shows is where it should be, and the frame keeps
        // its size and its borders around it.
        try std.testing.expectEqual(case.shown.x, rect.left + 11);
        try std.testing.expectEqual(case.shown.y, rect.top);
        try std.testing.expectEqual(frame.right - frame.left, rect.right - rect.left);
        try std.testing.expectEqual(frame.bottom - frame.top, rect.bottom - rect.top);
    }

    // A work area that does not start at the origin (a monitor to the
    // left of the primary one, a taskbar at its top).
    const left: win32.RECT = .{ .left = -2560, .top = 48, .right = 0, .bottom = 1440 };
    const there = positionRect(frame, visible, .{ .x = -2560, .y = 0 }, left);
    try std.testing.expectEqual(-2560 - 11, there.left);
    try std.testing.expectEqual(48, there.top);

    // Borders that do not show on all four sides, each of its own width.
    const odd: win32.RECT = .{ .left = 311 - 7, .top = 200 - 5, .right = 1111 + 9, .bottom = 800 + 13 };
    try std.testing.expectEqual(
        win32.RECT{ .left = 40 - 7, .top = 30 - 5, .right = 40 + 800 + 9, .bottom = 30 + 600 + 13 },
        positionRect(odd, visible, .{ .x = 40, .y = 30 }, work),
    );

    // A window whose bounds could not be told from its frame: the frame
    // itself is placed.
    const whole = positionRect(frame, frame, .{ .x = 10, .y = 20 }, work);
    try std.testing.expectEqual(win32.RECT{ .left = 10, .top = 20, .right = 832, .bottom = 631 }, whole);

    // Larger than the work area: its corner, and no larger than it.
    const big: win32.RECT = .{ .left = 0, .top = 0, .right = 3000, .bottom = 2000 };
    const fit = positionRect(big, big, .{ .x = 500, .y = 500 }, work);
    try std.testing.expectEqual(work, fit);
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
    // Read as a frame is destroyed.
    app.undo = .{};

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
