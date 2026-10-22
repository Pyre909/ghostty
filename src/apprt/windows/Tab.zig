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
/// window is next activated, and the one the window is titled after: set
/// by each terminal's WM_SETFOCUS, and moved off a terminal that closes on
/// its own by `Window.removePane` (`Window.setFocused`). Null only while
/// the tree is empty.
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
/// keys pressed in a burst. One per tab, as an `all:` binding moves the
/// focus in each window. Live when set; cleared when it begins to close
/// (`App.forgetClosing`).
pending_focus: ?*Surface = null,
