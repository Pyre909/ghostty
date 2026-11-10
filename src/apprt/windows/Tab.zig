//! A window's tab (`Window.tabs`): its terminals, in a split tree, and
//! which of them has the focus, as GTK's tab holds its split tree
//! (src/apprt/gtk/class/tab.zig). The window shows its selected tab
//! (`Window.tab`).

const Tab = @This();

const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");

/// The tab's terminals: never empty from `Window.create` until the frame's
/// WM_DESTROY empties it.
tree: Window.Tree = .empty,

/// The terminal with the keyboard focus, or the one to give it to when the
/// window is next activated or the tab next shown, and the one the window
/// is titled after unless `title_override` is set: set by each terminal's
/// WM_SETFOCUS, and moved off a terminal that closes on its own by
/// `Window.removePane` (`Window.setFocused`). Null only while the tree is
/// empty.
focused: ?*Surface = null,

/// The terminal a `goto_split` binding chose to give the focus to, not yet
/// given it. The action runs inside the core's key callback, where moving
/// the focus would send WM_KILLFOCUS into the surface whose callback is on
/// the stack, and losing the focus makes the core send that surface a key
/// release through its key callback (`CoreSurface.focusCallback`). So the
/// terminal's key handler gives it as soon as the callback has returned,
/// before the next key is read, so that a second press or the text typed
/// after it goes to the new terminal (`App.applyPendingFocus`). `App.run`
/// applies it too, but only once it has drained the queue, too late for
/// keys pressed in a burst. Only in the tab shown: a move in a hidden one
/// is made at once (`Window.focusHidden`), and one left on a tab when it
/// is hidden is dropped (`Window.selectTab`). One per tab, as an `all:`
/// binding moves the focus in each window. Live when set; cleared when it
/// begins to close (`App.forgetClosing`).
pending_focus: ?*Surface = null,

/// The tab is closing whole (`Window.requestCloseTabs`): each of its
/// terminals has a teardown posted, and with `undo` bound the first to
/// run parks the whole tab (`Surface.destroy`). Cleared when `undo` puts
/// the tab back. It means nothing once a terminal of the tab is not
/// closing (`closingWhole`): a teardown that could not be posted takes
/// its terminal's close back, and the tab then stays.
closing: bool = false,

/// The number shared by the tabs closed with this one by one action, or
/// zero (`Undo.Entry.group`).
group: u64 = 0,

/// The tab's title as `set_tab_title` gave it, which the window shows in
/// place of its focused terminal's (`Window.tabTitle`); null for none.
/// Owned, from the app's allocator.
title_override: ?[:0]u8 = null,

/// Whether the tab is still closing whole: it was marked so, and every
/// terminal of it is closing. A mark left by a close that did not post
/// all its teardowns is cleared, so that a later close of one terminal
/// of the tab is only that.
pub fn closingWhole(self: *Tab) bool {
    if (!self.closing) return false;
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.closing) continue;
        self.closing = false;
        self.group = 0;
        return false;
    }
    return true;
}
