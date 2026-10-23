//! A terminal's search bar, as GTK's search overlay floats over the
//! top-right corner of its surface (src/apprt/gtk/class/search_overlay.zig
//! and search-overlay.blp): a field for the text to find, the
//! `selected/total` count, buttons for the previous and next match, and a
//! close button.
//!
//! The bar is a child window of the terminal's **frame**, placed above the
//! terminal's own window, not a child of it: GDI drawn in a child of the
//! window that owns a flip-model swap chain is never composed (the overlay
//! plan's O1 probe, ~/ghostty-win/notes/win32-overlay-plan.md: such a box
//! stayed invisible at every step while it took clicks, focus and typing),
//! while a sibling above the terminal drew steadily during full-speed
//! output. So every path that lays terminals out places their bars too
//! (`place`, from `Window.relayout`), a hidden tab's are hidden with its
//! terminals, and a bar follows its terminal to a new frame. It is raised
//! above the terminals each time it is placed.
//!
//! The field is the system's EDIT control, which brings IME, the
//! clipboard, undo and accessibility. It is subclassed
//! (`SetWindowLongPtrW(GWLP_WNDPROC)`), not with comctl32's
//! SetWindowSubclass, which would be the runtime's first comctl32 import.
//! There is no dialog manager here, so the subclass does what O1 found an
//! EDIT does not: its WM_CHAR for Enter, Tab and Escape beeps, so those
//! are swallowed, and Ctrl+Backspace inserts U+007F, so the word before the
//! caret is deleted by hand (`wordStart`). The terminal's bindings for the
//! app, the window, its tabs and splits still act from the field, and its
//! copy, paste and select all act on the field (`overlay_keys`).
//!
//! The count and the buttons are painted with GDI and hit-tested by a pure
//! `Layout` of the bar's size, its DPI and the field's text height, as the
//! tab bar's are (TabBar.zig), in the colours `window-theme` gives the
//! frame.

const std = @import("std");
const builtin = @import("builtin");

const input = @import("../../input.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const overlay_keys = @import("overlay_keys.zig");
const messageFont = @import("TabBar.zig").messageFont;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const utf8FromWide = @import("clipboard.zig").utf8FromWide;

const RECT = win32.RECT;
const L = win32.L;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttySearchBarClass";

/// A terminal's bar (`Surface.search_bar`). Its window is made by the
/// first `start_search` and kept, hidden, after `end_search`, so that the
/// text stays for the next one, as GTK's overlay keeps its entry's.
pub const Bar = struct {
    /// The bar's window, a child of the terminal's frame; null before the
    /// first `start_search`, and once it is destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// The field, an EDIT child of `hwnd`.
    edit: ?win32.HWND = null,
    /// Between `start_search` and `end_search`: the bar shows whenever its
    /// terminal does and has room for it (`place`).
    open: bool = false,
    /// The field had the keyboard focus last, rather than the terminal: the
    /// focus given to the terminal goes to the field instead
    /// (`focusTarget`), as when its frame is activated again, or its tab
    /// shown. Set by `start_search` and by the field's WM_SETFOCUS; cleared
    /// by the terminal's WM_SETFOCUS, and when the bar closes.
    field_focus: bool = false,
    /// The core's count of matches and the index of the one selected,
    /// 0-based (`search_total`, `search_selected`), null for none.
    total: ?usize = null,
    selected: ?usize = null,
    /// What the pointer is over, and what the left button went down on: a
    /// button acts only if the button comes up on it too. The bar holds the
    /// mouse capture meanwhile.
    hover: Hit = .none,
    pressed: Hit = .none,
    /// Whether WM_MOUSELEAVE was asked for since the pointer came over.
    tracking: bool = false,
    /// The system's message font at `font_dpi`, the field's and the
    /// count's, and the height of a line of it (`applyFont`).
    font: ?win32.HGDIOBJ = null,
    font_dpi: u32 = 0,
    text_height: i32 = 0,
    /// The field's background brush for WM_CTLCOLOREDIT, of `brush_color`.
    brush: ?win32.HGDIOBJ = null,
    brush_color: win32.COLORREF = 0,
    /// A change of the field's text not yet searched for, and its timer
    /// (`search_timer`).
    debounce: Debounce = .{},

    /// Search for the field's text once `delay` milliseconds have passed
    /// with no other change (`search_timer`); a new call starts the wait
    /// again, as SetTimer replaces a timer of the same id.
    fn arm(self: *Bar, delay: u32) void {
        const hwnd = self.hwnd orelse return;
        if (win32.SetTimer(hwnd, search_timer, @max(delay, win32.USER_TIMER_MINIMUM), null) == 0) {
            log.warn("cannot start the search field's timer err={}", .{win32.GetLastError()});
        }
    }

    /// Drop a search not yet made.
    fn disarm(self: *Bar) void {
        self.debounce.cancel();
        if (self.hwnd) |hwnd| _ = win32.KillTimer(hwnd, search_timer);
    }

    /// Make the bar's window and its field, hidden, in the terminal's
    /// frame, unless it has them already. False, logged, if they cannot be
    /// made.
    fn create(self: *Bar, surface: *Surface) bool {
        if (self.hwnd != null) return true;
        const app = surface.app;
        const hwnd = win32.CreateWindowExW(
            0,
            L(class_name),
            null,
            win32.WS_CHILD | win32.WS_CLIPSIBLINGS | win32.WS_CLIPCHILDREN,
            0,
            0,
            0,
            0,
            surface.window.hwnd,
            null,
            app.hinstance,
            surface,
        ) orelse {
            log.warn("cannot make a search bar err={}", .{win32.GetLastError()});
            return false;
        };
        self.hwnd = hwnd;
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
        ) orelse {
            log.warn("cannot make a search field err={}", .{win32.GetLastError()});
            // Its WM_DESTROY clears `hwnd`.
            _ = win32.DestroyWindow(hwnd);
            return false;
        };
        self.edit = edit;
        // Every EDIT has the class's procedure, kept once for all.
        const old = win32.SetWindowLongPtrW(edit, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
        if (edit_proc == null) edit_proc = @ptrFromInt(@as(usize, @bitCast(old)));
        // GTK's placeholder; Common Controls v6 shows it while the field
        // is empty, and an older EDIT ignores the message.
        _ = win32.SendMessageW(edit, win32.EM_SETCUEBANNER, 0, @bitCast(@intFromPtr(L("Find\u{2026}"))));
        return true;
    }

    /// Hide the bar's window, as when its terminal is hidden or has no room
    /// for it; it stays open.
    pub fn hideWindow(self: *Bar) void {
        self.hover = .none;
        const hwnd = self.hwnd orelse return;
        _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    }

    /// Destroy the bar's window, for a terminal leaving its window
    /// (`Surface.destroy`): nothing shows it, nor is clicked, while the
    /// terminal's core stops.
    pub fn destroy(self: *Bar) void {
        const hwnd = self.hwnd orelse return;
        _ = win32.DestroyWindow(hwnd);
    }

    /// Let go of the bar's window and free what it drew with, as its
    /// terminal is freed (`Surface.deinit`). The window may outlive the
    /// terminal by a few messages: when a frame is destroyed, Windows sends
    /// WM_DESTROY to its children in an order of its own, and the
    /// terminal's frees it (`App.surfaceDestroyed`) before or after its
    /// bar's. So the window is not destroyed here but loses its
    /// back-pointer, as the terminal's does, and is destroyed with its frame.
    pub fn deinit(self: *Bar) void {
        if (self.hwnd) |hwnd| _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        self.hwnd = null;
        self.edit = null;
        if (self.font) |f| _ = win32.DeleteObject(f);
        self.font = null;
        self.font_dpi = 0;
        if (self.brush) |b| _ = win32.DeleteObject(b);
        self.brush = null;
    }

    /// Where the focus given to the terminal goes: to the field while it
    /// had the focus last and the bar shows; else null, the terminal.
    pub fn focusTarget(self: *const Bar) ?win32.HWND {
        if (!self.field_focus) return null;
        const hwnd = self.hwnd orelse return null;
        if (!visibleStyle(hwnd)) return null;
        return self.edit;
    }

    /// Draw the bar again: its count changed, or the theme.
    pub fn invalidate(self: *const Bar) void {
        if (self.hwnd) |hwnd| _ = win32.InvalidateRect(hwnd, null, .FALSE);
        if (self.edit) |edit| _ = win32.InvalidateRect(edit, null, .TRUE);
    }

    /// The system's message font changed: made again at the next placement.
    pub fn fontChanged(self: *Bar) void {
        self.font_dpi = 0;
    }

    /// Give the field the message font at `dpi`, made once for each DPI,
    /// and measure a line of it. The new font is made before the old one
    /// goes, which is kept if it cannot be.
    fn applyFont(self: *Bar, dpi: u32) void {
        if (self.font != null and self.font_dpi == dpi) return;
        const edit = self.edit orelse return;
        const font = messageFont(dpi) orelse return;
        _ = win32.SendMessageW(edit, win32.WM_SETFONT, @intFromPtr(font), 1);
        if (self.font) |old| _ = win32.DeleteObject(old);
        self.font = font;
        self.font_dpi = dpi;
        self.text_height = textHeight(edit, font);
    }

    /// The brush WM_CTLCOLOREDIT answers, of `color`, made again when the
    /// theme changes it.
    fn brushOf(self: *Bar, color: win32.COLORREF) ?win32.HGDIOBJ {
        if (self.brush != null and self.brush_color == color) return self.brush;
        const brush: win32.HGDIOBJ = win32.CreateSolidBrush(color) orelse return self.brush;
        if (self.brush) |old| _ = win32.DeleteObject(old);
        self.brush = brush;
        self.brush_color = color;
        return brush;
    }
};

/// The height of a line of `font`, as the field draws it; 0 if it cannot
/// be measured.
fn textHeight(edit: win32.HWND, font: win32.HGDIOBJ) i32 {
    const hdc = win32.GetDC(edit) orelse return 0;
    defer _ = win32.ReleaseDC(edit, hdc);
    const old = win32.SelectObject(hdc, font);
    defer if (old) |o| {
        _ = win32.SelectObject(hdc, o);
    };
    var tm: win32.TEXTMETRICW = undefined;
    if (!win32.GetTextMetricsW(hdc, &tm).toBool()) return 0;
    return tm.tmHeight;
}

/// The bar's timer for a search not yet made (`Bar.arm`).
pub const search_timer: win32.UINT_PTR = 1;

/// When a change of the field's text goes to the core as a search, as
/// GTK's GtkSearchEntry, which the overlay's entry is, emits
/// search-changed: once the text has not changed for its `search-delay`,
/// 150 ms by default (the overlay's blueprint sets none), and at once when
/// it was emptied. Both are GTK 4's documented behaviour, not checked in
/// this tree. A search not yet made goes first when Enter asks for the
/// next match (`take`), and is dropped when the bar closes.
pub const Debounce = struct {
    pub const delay_ms: u32 = 150;

    pending: bool = false,

    /// The text changed, `empty` if it was emptied: how many milliseconds
    /// to wait before searching.
    pub fn changed(self: *Debounce, empty: bool) u32 {
        self.pending = true;
        return if (empty) 0 else delay_ms;
    }

    /// Whether a search is due, the wait over or Enter pressed: once for
    /// each change.
    pub fn take(self: *Debounce) bool {
        const due = self.pending;
        self.pending = false;
        return due;
    }

    pub fn cancel(self: *Debounce) void {
        self.pending = false;
    }
};

/// The procedure every EDIT had before it was subclassed (`Bar.create`).
var edit_proc: ?win32.WNDPROC = null;

/// For tests: how many WM_CHARs the subclass passed on to the EDIT.
pub var test_forwarded: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

/// For tests: called with each binding action the bar would perform on its
/// terminal's core (`perform`), in place of performing it, and answering
/// whether it was; a test's terminal has no core.
pub var test_perform: if (builtin.is_test) ?*const fn (*Surface, input.Binding.Action) bool else void =
    if (builtin.is_test) null else {};

/// `start_search` on `surface`: open its bar, with `needle` in the field
/// unless it is empty, everything in the field selected, and the focus to
/// go there, as GTK's `setSearchActive` grabs the entry's focus and
/// selects its text; again on an open bar, the same. False, so that the
/// key reaches the terminal, if the bar cannot be made.
///
/// The core performs this inside its key callback, where moving the focus
/// would send the terminal WM_KILLFOCUS, which enters the core
/// (`Tab.pending_focus`): the focus moves once the callback has returned
/// (`App.search_focus`).
pub fn start(surface: *Surface, needle: [:0]const u8) bool {
    const bar = &surface.search_bar;
    if (!bar.create(surface)) return false;
    const edit = bar.edit.?;
    // A needle is searched for at once, as GTK's `setSearchContents`
    // emits search-changed itself; so is the text a closed bar kept when
    // it opens again (`setSearchActive`). From a timer all the same: this
    // runs inside a core frame.
    const now = needle.len > 0 or (!bar.open and win32.GetWindowTextLengthW(edit) > 0);
    if (needle.len > 0) {
        const alloc = surface.app.core_app.alloc;
        const wide = wideFromUtf8(alloc, needle) catch |err| {
            log.warn("cannot put the text to find in the search field err={}", .{err});
            return false;
        };
        defer alloc.free(wide);
        // Its EN_CHANGE arms the usual wait, which this replaces.
        _ = win32.SetWindowTextW(edit, wide.ptr);
    }
    if (now) {
        _ = bar.debounce.changed(false);
        bar.arm(0);
    }
    bar.open = true;
    bar.field_focus = true;
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 0, -1);
    place(surface);
    surface.app.search_focus = surface;
    return true;
}

/// `end_search` on `surface`: hide its bar, and give the terminal back the
/// focus if the field had it, as GTK's `searchStop` does. The text stays.
/// From inside a core frame too, so the focus moves later, as for `start`.
pub fn finish(surface: *Surface) void {
    const bar = &surface.search_bar;
    const t = surface.window.tabOf(surface);
    const had_focus = bar.field_focus and t != null and t.?.focused == surface;
    bar.open = false;
    bar.field_focus = false;
    bar.pressed = .none;
    // A search still to be made would start the search again.
    bar.disarm();
    bar.hideWindow();
    if (had_focus) surface.app.search_focus = surface;
}

/// `search_total` and `search_selected`: the count the bar shows
/// (`countLabel`), kept while it is closed too.
pub fn setTotal(surface: *Surface, total: ?usize) void {
    surface.search_bar.total = total;
    if (surface.search_bar.hwnd) |hwnd| _ = win32.InvalidateRect(hwnd, null, .FALSE);
}

pub fn setSelected(surface: *Surface, selected: ?usize) void {
    surface.search_bar.selected = selected;
    if (surface.search_bar.hwnd) |hwnd| _ = win32.InvalidateRect(hwnd, null, .FALSE);
}

/// The field's text changed (EN_CHANGE, sent synchronously, so also from
/// `start` inside a core frame): searched for after the wait
/// (`Debounce`), from the bar's timer, which `run`'s loop dispatches.
fn textChanged(surface: *Surface) void {
    const bar = &surface.search_bar;
    const edit = bar.edit orelse return;
    bar.arm(bar.debounce.changed(win32.GetWindowTextLengthW(edit) == 0));
}

/// The bar's timer, or Enter: perform `search:<text>` with the field's
/// text if a change is still to be searched for, as GTK's overlay does on
/// search-changed; empty text stops the search (`CoreSurface`'s `.search`).
/// While the core may not be re-entered, as under a prompt whose loop
/// dispatches timers, the search waits for the next tick of the timer.
fn searchNow(surface: *Surface) void {
    const bar = &surface.search_bar;
    if (!bar.debounce.pending) return;
    if (!surface.app.canReenterCore()) return bar.arm(Debounce.delay_ms);
    _ = bar.debounce.take();
    if (bar.hwnd) |hwnd| _ = win32.KillTimer(hwnd, search_timer);
    const edit = bar.edit orelse return;
    const alloc = surface.app.core_app.alloc;
    const len: usize = @intCast(@max(win32.GetWindowTextLengthW(edit), 0));
    const wide = alloc.alloc(u16, len + 1) catch |err| return log.warn("cannot read the search field err={}", .{err});
    defer alloc.free(wide);
    const n: usize = @intCast(@max(win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));
    // An unpaired surrogate becomes U+FFFD.
    const text = utf8FromWide(alloc, wide[0..n]) catch |err| return log.warn("cannot read the search field err={}", .{err});
    defer alloc.free(text);
    _ = perform(surface, .{ .search = text });
}

/// Enter, Shift+Enter or the up and down buttons: the next or previous
/// match, as GTK's overlay asks for them, after any search still to be
/// made for the text as it is now, as GtkSearchEntry emits a pending
/// search-changed before activating. Nothing while the core may not be
/// re-entered, as under a prompt.
fn navigate(surface: *Surface, to: input.Binding.Action.NavigateSearch) void {
    if (!surface.app.canReenterCore()) return;
    searchNow(surface);
    _ = perform(surface, .{ .navigate_search = to });
}

/// The bar's close button, or Escape in its field: `end_search` on the
/// terminal, as GTK's close button and Escape do (D4). The core answers
/// with the apprt `end_search` (`finish`); a terminal whose core cannot
/// answer, as one that is stopping, closes its bar all the same. Nothing
/// while the core may not be re-entered, as under a prompt, when the
/// search it runs could not be stopped.
fn close(surface: *Surface) void {
    if (!surface.app.canReenterCore()) return;
    _ = perform(surface, .end_search);
    if (surface.search_bar.open) finish(surface);
    surface.app.applyPendingFocus();
}

/// Perform `action` on the terminal's core, as GTK's overlay does
/// (`performBindingAction`), from a message `run`'s loop dispatched to the
/// bar: whether it was performed. Each caller first checks that the core
/// may be re-entered, as a key is dropped under a prompt
/// (`Surface.handleMessage`); so do the bindings the field's keys perform
/// (`overlay_keys`).
pub fn perform(surface: *Surface, action: input.Binding.Action) bool {
    if (builtin.is_test) if (test_perform) |seen| return seen(surface, action);
    const core = surface.liveCore() orelse return false;
    return core.performBindingAction(action) catch |err| {
        log.warn("cannot perform a binding action from a search bar action={t} err={}", .{ action, err });
        return false;
    };
}

/// Place `surface`'s bar over the top-right corner of its terminal, above
/// it, or hide it while the bar is closed, the terminal hidden (a hidden
/// tab, a zoom) or too small for it. A bar whose terminal moved to another
/// frame (`Window.moveTabTo`) goes there first; one that cannot is
/// destroyed, logged, and made again by the next `start_search`.
pub fn place(surface: *Surface) void {
    const bar = &surface.search_bar;
    const hwnd = bar.hwnd orelse return;
    const window = surface.window;
    if (win32.GetAncestor(hwnd, win32.GA_PARENT) != window.hwnd) {
        if (win32.SetParent(hwnd, window.hwnd) == null) {
            log.warn("cannot move a search bar to its terminal's new frame err={}", .{win32.GetLastError()});
            _ = win32.DestroyWindow(hwnd);
            return;
        }
    }
    // A hidden tab's terminals are hidden (`Window.selectTab`), and so is
    // one a zoom hides (`Window.layout`).
    if (!bar.open or !visibleStyle(surface.hwnd)) return bar.hideWindow();
    var pane: RECT = undefined;
    if (!win32.GetWindowRect(surface.hwnd, &pane).toBool() or !window.toClient(&pane)) {
        return bar.hideWindow();
    }
    const dpi = Window.dpiOf(surface.app, window.hwnd);
    bar.applyFont(dpi);
    const m = Metrics.init(dpi);
    const at = barRect(m, pane, bar.text_height) orelse return bar.hideWindow();
    const width = at.right - at.left;
    const height = at.bottom - at.top;
    _ = win32.SetWindowPos(
        hwnd,
        win32.HWND_TOP,
        at.left,
        at.top,
        width,
        height,
        win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW,
    );
    if (bar.edit) |edit| {
        const e = Layout.init(m, width, height, bar.text_height).edit;
        _ = win32.SetWindowPos(edit, null, e.left, e.top, e.right - e.left, e.bottom - e.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    }
    bar.invalidate();
}

/// Whether a window is shown itself, whatever its parent is.
fn visibleStyle(hwnd: win32.HWND) bool {
    const visible: isize = win32.WS_VISIBLE;
    return win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE) & visible != 0;
}

/// The terminal whose bar the window `hwnd` is, null once it is freed.
fn surfaceOf(hwnd: win32.HWND) ?*Surface {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The bar's window procedure. WM_NCCREATE brings its terminal.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(param)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const surface = surfaceOf(hwnd) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const bar = &surface.search_bar;

    switch (msg) {
        // All of it is painted, from a bitmap.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_PAINT => {
            paint(surface, hwnd);
            return 0;
        },

        // The field in the bar's colours.
        win32.WM_CTLCOLOREDIT => {
            const colors = Colors.of(surface.window.dark_frame);
            const hdc: win32.HDC = @ptrFromInt(wparam);
            _ = win32.SetTextColor(hdc, colors.text);
            _ = win32.SetBkColor(hdc, colors.field);
            const brush = bar.brushOf(colors.field) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            return @bitCast(@intFromPtr(brush));
        },

        win32.WM_COMMAND => {
            if (win32.hiword(wparam) == win32.EN_CHANGE) textChanged(surface);
            return 0;
        },

        win32.WM_TIMER => {
            if (wparam == search_timer) {
                searchNow(surface);
                return 0;
            }
        },

        win32.WM_MOUSEMOVE => {
            if (!bar.tracking) {
                var track: win32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = win32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                bar.tracking = win32.TrackMouseEvent(&track).toBool();
            }
            setHover(bar, hitAt(surface, hwnd, lparam));
            return 0;
        },

        win32.WM_MOUSELEAVE => {
            bar.tracking = false;
            setHover(bar, .none);
            return 0;
        },

        // A press on a button acts when the button comes up on it; one
        // anywhere else in the bar puts the focus in the field.
        win32.WM_LBUTTONDOWN => {
            const at = hitAt(surface, hwnd, lparam);
            if (at == .none) {
                if (bar.edit) |edit| surface.window.setKeyboardFocus(edit, true);
                return 0;
            }
            // Captured first: SetCapture sends WM_CAPTURECHANGED to the
            // window that loses it, which cancels a press.
            if (win32.GetCapture() != hwnd) _ = win32.SetCapture(hwnd);
            bar.pressed = at;
            bar.invalidate();
            return 0;
        },

        win32.WM_LBUTTONUP => {
            const at = hitAt(surface, hwnd, lparam);
            const pressed = bar.pressed;
            bar.pressed = .none;
            if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
            bar.invalidate();
            if (at == .none or at != pressed) return 0;
            // As GTK's buttons: up is the next match, which goes toward
            // older output, as on macOS too (search-overlay.blp).
            switch (at) {
                .close => close(surface),
                .up => navigate(surface, .next),
                .down => navigate(surface, .previous),
                .none => {},
            }
            return 0;
        },

        // Another window took the capture: the button comes up unseen.
        win32.WM_CAPTURECHANGED => {
            if (bar.pressed != .none) {
                bar.pressed = .none;
                bar.invalidate();
            }
            return 0;
        },

        win32.WM_DESTROY => {
            // Nothing places or draws into a destroyed window; the next
            // `start_search` makes another.
            bar.hwnd = null;
            bar.edit = null;
            bar.open = false;
            bar.field_focus = false;
            bar.pressed = .none;
            bar.hover = .none;
            bar.tracking = false;
            return 0;
        },

        win32.WM_NCDESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        },

        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn setHover(bar: *Bar, at: Hit) void {
    if (at == bar.hover) return;
    bar.hover = at;
    bar.invalidate();
}

/// The layout of `surface`'s bar, whose window is `hwnd`, at its size now.
fn layoutOf(surface: *Surface, hwnd: win32.HWND) Layout {
    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) client = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const m = Metrics.init(Window.dpiOf(surface.app, hwnd));
    return .init(m, client.right, client.bottom, surface.search_bar.text_height);
}

fn hitAt(surface: *Surface, hwnd: win32.HWND, lparam: win32.LPARAM) Hit {
    return layoutOf(surface, hwnd).hit(win32.xLparam(lparam), win32.yLparam(lparam));
}

/// The field's subclass: the keys an EDIT gets wrong without a dialog
/// manager, the bindings that still act from the field
/// (`overlay_keys.keyDown`), and the focus. The bar is the field's parent.
fn editProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    const proc = edit_proc.?;
    const parent = win32.GetAncestor(hwnd, win32.GA_PARENT);
    const surface = (if (parent) |p| surfaceOf(p) else null) orelse
        return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);

    if (msg == win32.WM_SETFOCUS) {
        // The terminal's WM_KILLFOCUS told its core; the window is now
        // titled after it, and gives the field the focus back when it is
        // activated again (`focusTarget`).
        surface.search_bar.field_focus = true;
        surface.window.setFocused(surface);
    }

    switch (editKey(msg, wparam, win32.GetKeyState(win32.VK_SHIFT) < 0)) {
        .pass => {},
        .swallow => return 0,
        .next => {
            navigate(surface, .next);
            return 0;
        },
        .previous => {
            navigate(surface, .previous);
            return 0;
        },
        .close => {
            close(surface);
            return 0;
        },
        .delete_word => {
            deleteWord(surface, hwnd);
            return 0;
        },
    }
    // Then the terminal's bindings that still act from the field (D3).
    if (overlay_keys.keyDown(surface, hwnd, proc, msg, wparam, lparam)) return 0;
    if (builtin.is_test) if (msg == win32.WM_CHAR) {
        test_forwarded += 1;
    };
    return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

/// What the field's subclass does with a message.
pub const EditKey = enum {
    /// The EDIT's own handling.
    pass,
    /// Dropped: the WM_CHAR of Enter, Ctrl+Enter, Tab and Escape, which a
    /// single-line EDIT answers with a beep (O1).
    swallow,
    /// Escape: `end_search` (D4, as GTK).
    close,
    /// Enter and Shift+Enter: the next and previous match, as GTK's
    /// overlay takes them (`searchEntryKeyPressed`).
    next,
    previous,
    /// Ctrl+Backspace's WM_CHAR, U+007F, which the EDIT would insert:
    /// delete the word before the caret instead.
    delete_word,
};

pub fn editKey(msg: win32.UINT, wparam: win32.WPARAM, shift: bool) EditKey {
    return switch (msg) {
        win32.WM_KEYDOWN => switch (wparam) {
            win32.VK_ESCAPE => .close,
            win32.VK_RETURN => if (shift) .previous else .next,
            else => .pass,
        },
        win32.WM_CHAR => switch (wparam) {
            '\r', '\n', '\t', 0x1B => .swallow,
            0x7F => .delete_word,
            else => .pass,
        },
        else => .pass,
    };
}

/// Ctrl+Backspace in the field: the selection, or else the word before
/// the caret (`wordStart`), goes, as one undoable replacement.
fn deleteWord(surface: *Surface, edit: win32.HWND) void {
    var from: win32.DWORD = 0;
    var to: win32.DWORD = 0;
    _ = win32.SendMessageW(edit, win32.EM_GETSEL, @intFromPtr(&from), @bitCast(@intFromPtr(&to)));
    if (from == to) {
        const alloc = surface.app.core_app.alloc;
        const len: usize = @intCast(@max(win32.GetWindowTextLengthW(edit), 0));
        const text = alloc.alloc(u16, len + 1) catch return;
        defer alloc.free(text);
        const n: usize = @intCast(@max(win32.GetWindowTextW(edit, text.ptr, @intCast(text.len)), 0));
        from = @intCast(wordStart(text[0..n], to));
        _ = win32.SendMessageW(edit, win32.EM_SETSEL, from, to);
    }
    _ = win32.SendMessageW(edit, win32.EM_REPLACESEL, 1, @bitCast(@intFromPtr(L(""))));
}

/// Where Ctrl+Backspace deletes back to from `caret` in `text`: past any
/// spaces, then past a run of word characters or else a run of
/// punctuation, as the Windows text controls that have it go (Notepad,
/// RichEdit). A surrogate pair is two word characters, so it goes whole.
pub fn wordStart(text: []const u16, caret: usize) usize {
    var i = @min(caret, text.len);
    while (i > 0 and classOf(text[i - 1]) == .space) i -= 1;
    if (i == 0) return 0;
    const run = classOf(text[i - 1]);
    while (i > 0 and classOf(text[i - 1]) == run) i -= 1;
    return i;
}

const CharClass = enum { space, word, punctuation };

fn classOf(unit: u16) CharClass {
    return switch (unit) {
        ' ', '\t', 0x00A0, 0x3000 => .space,
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => .word,
        0...0x08, 0x0A...0x1F, '!'...'/', ':'...'@', '['...'^', '`', '{'...0x7F => .punctuation,
        else => .word,
    };
}

/// The count GTK's overlay shows (`closureMatchLabel` in
/// search_overlay.zig): `selected/total`, the selected match counted from
/// 1, as the core's index is 0-based (terminal/search/screen.zig); 0 with
/// none selected; `0/0` with no total or none found.
pub fn countLabel(buf: *[48]u8, total: ?usize, selected: ?usize) []const u8 {
    const t = total orelse 0;
    if (t == 0) return "0/0";
    const s: usize = if (selected) |v| v + 1 else 0;
    return std.mem.print(buf, "{d}/{d}", .{ s, t }) catch "0/0";
}

/// The bar's colours, by whether the title bar is dark
/// (`Window.dark_frame`), as the tab bar's are.
const Colors = struct {
    bar: win32.COLORREF,
    border: win32.COLORREF,
    field: win32.COLORREF,
    text: win32.COLORREF,
    dim: win32.COLORREF,
    hover: win32.COLORREF,

    fn of(dark: bool) Colors {
        return if (dark) .{
            .bar = win32.rgb(0x2b, 0x2b, 0x2b),
            .border = win32.rgb(0x4a, 0x4a, 0x4a),
            .field = win32.rgb(0x1c, 0x1c, 0x1c),
            .text = win32.rgb(0xff, 0xff, 0xff),
            .dim = win32.rgb(0xb4, 0xb4, 0xb4),
            .hover = win32.rgb(0x3d, 0x3d, 0x3d),
        } else .{
            .bar = win32.rgb(0xf3, 0xf3, 0xf3),
            .border = win32.rgb(0xc8, 0xc8, 0xc8),
            .field = win32.rgb(0xff, 0xff, 0xff),
            .text = win32.rgb(0x1a, 0x1a, 0x1a),
            .dim = win32.rgb(0x5c, 0x5c, 0x5c),
            .hover = win32.rgb(0xe0, 0xe0, 0xe0),
        };
    }
};

fn paint(surface: *Surface, hwnd: win32.HWND) void {
    const bar = &surface.search_bar;
    var ps: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = win32.EndPaint(hwnd, &ps);

    var client: RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) return;
    if (client.right <= 0 or client.bottom <= 0) return;

    // Drawn off the screen, then copied at once, so that it never flickers.
    const mem = win32.CreateCompatibleDC(hdc) orelse return;
    defer _ = win32.DeleteDC(mem);
    const bitmap = win32.CreateCompatibleBitmap(hdc, client.right, client.bottom) orelse return;
    defer _ = win32.DeleteObject(bitmap);
    const old_bitmap = win32.SelectObject(mem, bitmap);
    defer if (old_bitmap) |b| {
        _ = win32.SelectObject(mem, b);
    };

    const dpi = Window.dpiOf(surface.app, hwnd);
    const colors = Colors.of(surface.window.dark_frame);
    const l = Layout.init(.init(dpi), client.right, client.bottom, bar.text_height);
    const line = @max(1, Metrics.scale(1, dpi));

    // The bar, framed; the field's box, framed, behind the EDIT.
    fill(mem, client, colors.border);
    fill(mem, inset(client, line), colors.bar);
    fill(mem, l.field, colors.border);
    fill(mem, inset(l.field, line), colors.field);

    _ = win32.SetBkMode(mem, win32.TRANSPARENT);
    const old_font = if (bar.font) |f| win32.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = win32.SelectObject(mem, f);
    };
    var buf: [48]u8 = undefined;
    const label = countLabel(&buf, bar.total, bar.selected);
    var wide: [48]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, label) catch 0;
    var label_rect = l.label;
    _ = win32.SetTextColor(mem, colors.dim);
    _ = win32.DrawTextW(mem, &wide, @intCast(n), &label_rect, win32.DT_SINGLELINE | win32.DT_VCENTER | win32.DT_RIGHT | win32.DT_NOPREFIX);

    const buttons = [_]struct { hit: Hit, rect: RECT }{
        .{ .hit = .up, .rect = l.up },
        .{ .hit = .down, .rect = l.down },
        .{ .hit = .close, .rect = l.close },
    };
    for (buttons) |b| {
        if (bar.pressed == b.hit) {
            fill(mem, b.rect, colors.border);
        } else if (bar.hover == b.hit) {
            fill(mem, b.rect, colors.hover);
        }
        drawGlyph(mem, b.rect, b.hit, colors.text, line);
    }

    _ = win32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, win32.SRCCOPY);
}

/// A button's glyph, drawn with lines so that it is the same in every
/// font: a chevron up or down, or a cross.
fn drawGlyph(hdc: win32.HDC, r: RECT, glyph: Hit, color: win32.COLORREF, width: i32) void {
    const pen = win32.CreatePen(win32.PS_SOLID, width, color) orelse return;
    defer _ = win32.DeleteObject(pen);
    const old = win32.SelectObject(hdc, pen);
    defer if (old) |o| {
        _ = win32.SelectObject(hdc, o);
    };
    const cx = @divTrunc(r.left + r.right, 2);
    const cy = @divTrunc(r.top + r.bottom, 2);
    const s = @max(2, @divTrunc(r.right - r.left, 6));
    const h = @divTrunc(s, 2);
    switch (glyph) {
        .up => {
            const p = [_]win32.POINT{ .{ .x = cx - s, .y = cy + h }, .{ .x = cx, .y = cy - h }, .{ .x = cx + s + 1, .y = cy + h + 1 } };
            _ = win32.Polyline(hdc, &p, p.len);
        },
        .down => {
            const p = [_]win32.POINT{ .{ .x = cx - s, .y = cy - h }, .{ .x = cx, .y = cy + h }, .{ .x = cx + s + 1, .y = cy - h - 1 } };
            _ = win32.Polyline(hdc, &p, p.len);
        },
        .close => {
            const a = [_]win32.POINT{ .{ .x = cx - h, .y = cy - h }, .{ .x = cx + h + 1, .y = cy + h + 1 } };
            const b = [_]win32.POINT{ .{ .x = cx + h, .y = cy - h }, .{ .x = cx - h - 1, .y = cy + h + 1 } };
            _ = win32.Polyline(hdc, &a, a.len);
            _ = win32.Polyline(hdc, &b, b.len);
        },
        .none => {},
    }
}

fn fill(hdc: win32.HDC, r: RECT, color: win32.COLORREF) void {
    const brush = win32.CreateSolidBrush(color) orelse return;
    defer _ = win32.DeleteObject(brush);
    _ = win32.FillRect(hdc, &r, brush);
}

fn inset(r: RECT, by: i32) RECT {
    return .{ .left = r.left + by, .top = r.top + by, .right = r.right - by, .bottom = r.bottom - by };
}

/// The bar's sizes at a DPI, from their values at 96 DPI: GTK's entry is
/// 20 characters wide (`width-chars`), about 200 pixels of the message
/// font, and its count 6.
pub const Metrics = struct {
    /// Between the bar and its terminal's top and right edges.
    margin: i32,
    /// The bar's least height; a larger font makes it taller.
    height: i32,
    /// Inside the bar's edges.
    pad: i32,
    /// Between the field and the count, and the count and the buttons.
    gap: i32,
    /// The field's box: its widest, and the narrowest it shrinks to in a
    /// narrow terminal before the bar no longer shows.
    field_max: i32,
    field_min: i32,
    /// Between the field's box and its text.
    inset: i32,
    count: i32,
    /// Each button, square.
    button: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .margin = scale(8, dpi),
            .height = scale(36, dpi),
            .pad = scale(4, dpi),
            .gap = scale(4, dpi),
            .field_max = scale(200, dpi),
            .field_min = scale(64, dpi),
            .inset = scale(4, dpi),
            .count = scale(56, dpi),
            .button = scale(28, dpi),
        };
    }

    fn scale(v: i32, dpi: u32) i32 {
        const base: i32 = win32.USER_DEFAULT_SCREEN_DPI;
        return @divTrunc(v * @as(i32, @intCast(dpi)) + @divTrunc(base, 2), base);
    }

    /// Everything across but the field.
    fn fixed(self: Metrics) i32 {
        return 2 * self.pad + 2 * self.gap + self.count + 3 * self.button;
    }

    /// The bar's height for a line of text `text_height` tall.
    pub fn barHeight(self: Metrics, text_height: i32) i32 {
        return @max(self.height, @max(0, text_height) + 2 * self.inset + 2 * self.pad);
    }
};

/// Where the bar goes over a terminal at `pane`, in the frame's client
/// coordinates: `margin` in from its top-right corner, as wide as it can
/// be up to its widest; null when the terminal is too small for it.
pub fn barRect(m: Metrics, pane: RECT, text_height: i32) ?RECT {
    const height = m.barHeight(text_height);
    const room = pane.right - pane.left - 2 * m.margin;
    const width = @min(m.fixed() + m.field_max, room);
    if (width < m.fixed() + m.field_min) return null;
    if (pane.bottom - pane.top < height + 2 * m.margin) return null;
    const right = pane.right - m.margin;
    const top = pane.top + m.margin;
    return .{ .left = right - width, .top = top, .right = right, .bottom = top + height };
}

/// What a bar `width` by `height` holds, left to right, in its own client
/// coordinates: the field's box (the EDIT inside it, as tall as a line of
/// its text and centred in it), the count, and the up, down and close
/// buttons, each centred down the bar.
pub const Layout = struct {
    field: RECT,
    edit: RECT,
    label: RECT,
    up: RECT,
    down: RECT,
    close: RECT,

    pub fn init(m: Metrics, width: i32, height: i32, text_height: i32) Layout {
        const field_w = @max(0, width - m.fixed());
        const box_h = @min(@max(0, height - 2 * m.pad), @max(0, text_height) + 2 * m.inset);
        const box_top = @divTrunc(height - box_h, 2);
        const field: RECT = .{ .left = m.pad, .top = box_top, .right = m.pad + field_w, .bottom = box_top + box_h };
        const text_h = @min(@max(0, text_height), box_h);
        const text_top = box_top + @divTrunc(box_h - text_h, 2);
        const edit: RECT = .{
            .left = field.left + m.inset,
            .top = text_top,
            .right = @max(field.left + m.inset, field.right - m.inset),
            .bottom = text_top + text_h,
        };
        const label_left = field.right + m.gap;
        const label: RECT = .{ .left = label_left, .top = 0, .right = label_left + m.count, .bottom = height };
        const button_top = @divTrunc(height - m.button, 2);
        const first = label.right + m.gap;
        return .{
            .field = field,
            .edit = edit,
            .label = label,
            .up = square(first, button_top, m.button),
            .down = square(first + m.button, button_top, m.button),
            .close = square(first + 2 * m.button, button_top, m.button),
        };
    }

    /// What is at `x`, `y` in the bar: a button, or nothing of its own
    /// (the field is a window of its own, which takes its own clicks).
    pub fn hit(self: Layout, x: i32, y: i32) Hit {
        if (contains(self.up, x, y)) return .up;
        if (contains(self.down, x, y)) return .down;
        if (contains(self.close, x, y)) return .close;
        return .none;
    }
};

fn square(left: i32, top: i32, size: i32) RECT {
    return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
}

fn contains(r: RECT, x: i32, y: i32) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

pub const Hit = enum { none, up, down, close };

test "win32: the search bar sits in its terminal's top-right corner, or not at all" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(2 * 4 + 2 * 4 + 56 + 3 * 28, m.fixed());
    try testing.expectEqual(36, m.barHeight(16));
    // A larger font makes it taller, its text with room round it.
    try testing.expectEqual(30 + 8 + 8, m.barHeight(30));
    try testing.expectEqual(54, Metrics.init(144).height);

    // A wide terminal: the bar at its widest, 8 px in from the corner.
    const pane: RECT = .{ .left = 100, .top = 50, .right = 900, .bottom = 650 };
    try testing.expectEqual(RECT{ .left = 892 - 156 - 200, .top = 58, .right = 892, .bottom = 94 }, barRect(m, pane, 16).?);

    // A narrower one: the field shrinks, down to its least width.
    const narrow: RECT = .{ .left = 0, .top = 0, .right = 300, .bottom = 200 };
    try testing.expectEqual(RECT{ .left = 8, .top = 8, .right = 292, .bottom = 44 }, barRect(m, narrow, 16).?);
    const least = barRect(m, .{ .left = 0, .top = 0, .right = 156 + 64 + 16, .bottom = 200 }, 16).?;
    try testing.expectEqual(156 + 64, least.right - least.left);

    // Too narrow or too short by a pixel: no bar.
    try testing.expect(barRect(m, .{ .left = 0, .top = 0, .right = 156 + 64 + 15, .bottom = 200 }, 16) == null);
    try testing.expect(barRect(m, .{ .left = 0, .top = 0, .right = 800, .bottom = 36 + 16 - 1 }, 16) == null);
    try testing.expect(barRect(m, .{ .left = 0, .top = 0, .right = 800, .bottom = 36 + 16 }, 16) != null);
    try testing.expect(barRect(m, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, 16) == null);
}

test "win32: the search bar's parts and buttons" {
    const testing = std.testing;
    const m = Metrics.init(96);
    const l = Layout.init(m, 356, 36, 16);
    // The field's box: what the fixed parts leave, its text centred in it.
    try testing.expectEqual(RECT{ .left = 4, .top = 6, .right = 204, .bottom = 30 }, l.field);
    try testing.expectEqual(RECT{ .left = 8, .top = 10, .right = 200, .bottom = 26 }, l.edit);
    try testing.expectEqual(RECT{ .left = 208, .top = 0, .right = 264, .bottom = 36 }, l.label);
    try testing.expectEqual(RECT{ .left = 268, .top = 4, .right = 296, .bottom = 32 }, l.up);
    try testing.expectEqual(RECT{ .left = 296, .top = 4, .right = 324, .bottom = 32 }, l.down);
    try testing.expectEqual(RECT{ .left = 324, .top = 4, .right = 352, .bottom = 32 }, l.close);
    // The last button ends `pad` in from the bar's right edge.
    try testing.expectEqual(356 - m.pad, l.close.right);

    try testing.expectEqual(Hit.up, l.hit(268, 4));
    try testing.expectEqual(Hit.down, l.hit(296, 31));
    try testing.expectEqual(Hit.close, l.hit(351, 20));
    try testing.expectEqual(Hit.none, l.hit(352, 20));
    try testing.expectEqual(Hit.none, l.hit(300, 3));
    try testing.expectEqual(Hit.none, l.hit(100, 20));
    try testing.expectEqual(Hit.none, l.hit(230, 20));

    // No font measured yet, and no room: nothing negative.
    const none = Layout.init(m, 0, 0, 0);
    try testing.expect(none.field.right >= none.field.left and none.edit.bottom >= none.edit.top);
}

test "win32: Ctrl+Backspace in the search field deletes back to a word's start" {
    const testing = std.testing;
    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqual(6, wordStart(utf16("hello world"), 11));
    // Spaces before the caret go with the word before them.
    try testing.expectEqual(0, wordStart(utf16("hello   "), 8));
    try testing.expectEqual(6, wordStart(utf16("hello world  "), 13));
    // A run of punctuation is a word of its own.
    try testing.expectEqual(5, wordStart(utf16("path/to"), 7));
    try testing.expectEqual(4, wordStart(utf16("path/to"), 5));
    try testing.expectEqual(0, wordStart(utf16("path/to"), 4));
    try testing.expectEqual(0, wordStart(utf16("foo_bar9"), 8));
    // From the middle; at the start; past the end.
    try testing.expectEqual(0, wordStart(utf16("hello world"), 3));
    try testing.expectEqual(0, wordStart(utf16("hello"), 0));
    try testing.expectEqual(6, wordStart(utf16("hello world"), 99));
    // Other scripts and surrogate pairs are word characters.
    try testing.expectEqual(2, wordStart(utf16("a \u{65E5}\u{672C}"), 4));
    try testing.expectEqual(2, wordStart(utf16("a \u{1F600}"), 4));
    try testing.expectEqual(0, wordStart(utf16(""), 0));
}

test "win32: the search field's keys" {
    const testing = std.testing;
    for ([_]bool{ false, true }) |shift| {
        try testing.expectEqual(EditKey.close, editKey(win32.WM_KEYDOWN, win32.VK_ESCAPE, shift));
        for ([_]win32.WPARAM{ '\r', '\n', '\t', 0x1B }) |c| {
            try testing.expectEqual(EditKey.swallow, editKey(win32.WM_CHAR, c, shift));
        }
        try testing.expectEqual(EditKey.delete_word, editKey(win32.WM_CHAR, 0x7F, shift));
        try testing.expectEqual(EditKey.pass, editKey(win32.WM_CHAR, 'a', shift));
        try testing.expectEqual(EditKey.pass, editKey(win32.WM_CHAR, 0x08, shift));
        try testing.expectEqual(EditKey.pass, editKey(win32.WM_CHAR, 0x01, shift));
        try testing.expectEqual(EditKey.pass, editKey(win32.WM_KEYUP, win32.VK_ESCAPE, shift));
        try testing.expectEqual(EditKey.pass, editKey(win32.WM_KEYUP, win32.VK_RETURN, shift));
        try testing.expectEqual(EditKey.pass, editKey(win32.WM_KEYDOWN, win32.VK_TAB, shift));
    }
    // Enter is the next match, Shift+Enter the previous one.
    try testing.expectEqual(EditKey.next, editKey(win32.WM_KEYDOWN, win32.VK_RETURN, false));
    try testing.expectEqual(EditKey.previous, editKey(win32.WM_KEYDOWN, win32.VK_RETURN, true));
}

test "win32: the search waits for the text to settle, but not for an empty field" {
    const testing = std.testing;
    var d: Debounce = .{};
    // Nothing to search for until the text changes.
    try testing.expect(!d.take());
    try testing.expectEqual(150, d.changed(false));
    try testing.expectEqual(150, d.changed(false));
    // One search for any number of changes, once.
    try testing.expect(d.take());
    try testing.expect(!d.take());
    // Emptied: at once.
    try testing.expectEqual(0, d.changed(true));
    try testing.expect(d.take());
    // Dropped.
    _ = d.changed(false);
    d.cancel();
    try testing.expect(!d.take());
}

test "win32: the search count is GTK's" {
    const testing = std.testing;
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("0/0", countLabel(&buf, null, null));
    try testing.expectEqualStrings("0/0", countLabel(&buf, 0, null));
    try testing.expectEqualStrings("0/0", countLabel(&buf, null, 3));
    try testing.expectEqualStrings("0/5", countLabel(&buf, 5, null));
    try testing.expectEqualStrings("1/5", countLabel(&buf, 5, 0));
    try testing.expectEqualStrings("5/5", countLabel(&buf, 5, 4));
}
