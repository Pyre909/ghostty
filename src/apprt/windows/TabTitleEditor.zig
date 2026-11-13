//! A tab's title edited in place, on its label in the tab bar, as macOS
//! edits it (TabTitleEditor.swift): a double click on a tab's label puts
//! a field over the label with the tab's title, all of it selected. Enter
//! commits it, Escape cancels, and the focus going elsewhere commits it,
//! as macOS's end of editing does. A committed title becomes the tab's
//! (`Window.setTabTitle`), shown in place of its terminal's; an empty one
//! ends the tab's own title, as macOS's empty title becomes nil.
//!
//! The field is an EDIT, a child of the bar, which clips it out of what
//! it paints (WS_CLIPCHILDREN); in a transparent window it is drawn into
//! the bar's layered surface, opaque with it, as the search field is into
//! its bar's (`Transparency.chrome`). It follows its tab's label as the
//! tabs move, scroll or resize (`place`, from the bar's paint), and goes,
//! committing nothing, if its tab leaves the window. A field Windows
//! cannot make falls back to the tab's title prompt (`prompt_tab_title`).
//!
//! The field is subclassed as the search field is
//! (`SetWindowLongPtrW(GWLP_WNDPROC)`), for its keys and the loss of its
//! focus.

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const Window = @import("Window.zig");
const SearchBar = @import("SearchBar.zig");
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const editText = @import("clipboard.zig").editText;

const L = win32.L;
const log = std.log.scoped(.win32);

/// A window's editor: its field while a tab's title is being edited.
pub const Editor = struct {
    /// The field, null while none is open.
    edit: ?win32.HWND = null,
    /// The tab whose title it edits; a tab is kept by its pointer, which
    /// stays its own as tabs move, not by its index.
    tab: ?*Window.Tab = null,
    /// The height of a line of the field's font, which it is centred on
    /// its label at; 0, the label's full height, if it was not measured.
    line: i32 = 0,
    /// The field's background brush for WM_CTLCOLOREDIT, of `brush_color`.
    brush: ?win32.HGDIOBJ = null,
    brush_color: win32.COLORREF = 0,

    /// The brush the bar answers WM_CTLCOLOREDIT with, of `color`, made
    /// again when the theme changes it; the old one kept if it cannot be.
    pub fn brushOf(self: *Editor, color: win32.COLORREF) ?win32.HGDIOBJ {
        if (self.brush != null and self.brush_color == color) return self.brush;
        const brush: win32.HGDIOBJ = win32.CreateSolidBrush(color) orelse return self.brush;
        if (self.brush) |old| _ = win32.DeleteObject(old);
        self.brush = brush;
        self.brush_color = color;
        return brush;
    }

    /// The bar's window is destroyed, and its field with it: nothing is
    /// committed, as the window is going; what it drew with is freed.
    pub fn deinit(self: *Editor) void {
        self.edit = null;
        self.tab = null;
        self.line = 0;
        if (self.brush) |b| _ = win32.DeleteObject(b);
        self.brush = null;
    }
};

/// The EDIT class's own procedure, which the subclass passes the rest to;
/// the same for every EDIT, kept once.
var edit_proc: ?win32.WNDPROC = null;

/// Begin editing the title of the tab at `index` of `window`, over its
/// label at `label`, a rectangle of the bar's client area; one already
/// open is committed first. A tab with no terminal has no title to edit.
/// If the field cannot be made, the tab's title prompt opens instead, if
/// the core may be re-entered (`App.canReenterCore`).
pub fn begin(window: *Window, index: usize, label: win32.RECT) void {
    finish(window, .commit);
    if (window.closing or index >= window.tabs.items.len) return;
    const bar = window.bar.hwnd orelse return;
    const t = window.tabs.items[index];
    const surface = t.focused orelse return;
    const editor = &window.bar.editor;
    const edit = create(window, bar, label, editor) orelse {
        if (window.app.canReenterCore()) _ = SearchBar.perform(surface, .prompt_tab_title);
        window.app.applyPendingFocus();
        return;
    };
    editor.edit = edit;
    editor.tab = t;
    place(window, label);

    const alloc = window.app.core_app.alloc;
    if (Window.tabTitle(t)) |title| {
        if (wideFromUtf8(alloc, title)) |wide| {
            defer alloc.free(wide);
            _ = win32.SetWindowTextW(edit, wide.ptr);
        } else |err| log.warn("cannot show a tab's title to edit err={}", .{err});
    }
    // All of it selected, so that typing replaces it, as macOS selects it.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 0, -1);
    window.setKeyboardFocus(edit, false);
}

/// For tests: whether `create` fails, as Windows' CreateWindowExW would.
pub var test_fail_create: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

fn create(window: *Window, bar: win32.HWND, label: win32.RECT, editor: *Editor) ?win32.HWND {
    if (builtin.is_test and test_fail_create) return null;
    const edit = win32.CreateWindowExW(
        0,
        L("EDIT"),
        L(""),
        win32.WS_CHILD | win32.WS_VISIBLE | win32.ES_AUTOHSCROLL,
        label.left,
        label.top,
        label.right - label.left,
        label.bottom - label.top,
        bar,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.warn("cannot make a tab title field err={}", .{win32.GetLastError()});
        return null;
    };
    const old = win32.SetWindowLongPtrW(edit, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
    if (edit_proc == null) edit_proc = @ptrFromInt(@as(usize, @bitCast(old)));
    // The bar's font, which the label is drawn in.
    editor.line = 0;
    if (window.bar.fontFor(Window.dpiOf(window.app, bar), window.app.config.@"window-title-font-family")) |font| {
        _ = win32.SendMessageW(edit, win32.WM_SETFONT, @intFromPtr(font), 0);
        editor.line = SearchBar.textHeight(edit, font);
    }
    return edit;
}

/// How an edit ends.
pub const End = enum { commit, cancel };

/// End the edit open in `window`, if any: with `commit`, its text becomes
/// its tab's title, or ends the tab's own title if empty, unless the tab
/// left the window or the window is closing. The field is let go of
/// before anything else, so that its loss of the focus as it is destroyed
/// does not end it again.
pub fn finish(window: *Window, end: End) void {
    const editor = &window.bar.editor;
    const edit = editor.edit orelse return;
    const t = editor.tab;
    editor.edit = null;
    editor.tab = null;
    if (end == .commit and !window.closing and !window.app.terminating) commit: {
        const tab = t orelse break :commit;
        if (std.mem.indexOfScalar(*Window.Tab, window.tabs.items, tab) == null) break :commit;
        const surface = tab.focused orelse break :commit;
        const alloc = window.app.core_app.alloc;
        const text = editText(alloc, edit) catch |err| {
            log.warn("cannot read a tab title field err={}", .{err});
            break :commit;
        };
        defer alloc.free(text);
        _ = window.setTabTitle(surface, text);
    }
    _ = win32.DestroyWindow(edit);
}

/// Keep the field over its tab's label, `label` (`TabBar.paint`), or end
/// it, committing nothing, if its tab is gone; null `label` for a tab no
/// longer in the window.
pub fn place(window: *Window, label: ?win32.RECT) void {
    const edit = window.bar.editor.edit orelse return;
    const r = fieldRect(label orelse return finish(window, .cancel), window.bar.editor.line);
    var now: win32.RECT = undefined;
    if (win32.GetWindowRect(edit, &now).toBool()) {
        var at: win32.POINT = .{ .x = now.left, .y = now.top };
        if (window.bar.hwnd) |bar| _ = win32.ScreenToClient(bar, &at);
        if (at.x == r.left and at.y == r.top and now.right - now.left == r.right - r.left and now.bottom - now.top == r.bottom - r.top) return;
    }
    _ = win32.SetWindowPos(edit, null, r.left, r.top, r.right - r.left, r.bottom - r.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
}

/// The field's place on `label`: centred on it, a line of its font high,
/// as the label's text is drawn centred (DT_VCENTER); all of it if the
/// line was not measured or does not fit.
pub fn fieldRect(label: win32.RECT, line: i32) win32.RECT {
    const h = label.bottom - label.top;
    if (line <= 0 or line >= h) return label;
    const top = label.top + @divTrunc(h - line, 2);
    return .{ .left = label.left, .top = top, .right = label.right, .bottom = top + line };
}

test "win32: a tab title field is centred on its label, a line high" {
    const label: win32.RECT = .{ .left = 10, .top = 0, .right = 110, .bottom = 34 };
    try std.testing.expectEqual(win32.RECT{ .left = 10, .top = 9, .right = 110, .bottom = 25 }, fieldRect(label, 16));
    try std.testing.expectEqual(win32.RECT{ .left = 10, .top = 8, .right = 110, .bottom = 25 }, fieldRect(label, 17));
    try std.testing.expectEqual(label, fieldRect(label, 0));
    try std.testing.expectEqual(label, fieldRect(label, 34));
    try std.testing.expectEqual(label, fieldRect(label, 40));
}

/// For tests: how many WM_CHARs and WM_SYSCHARs the subclass passed on to
/// the EDIT. A single-line EDIT puts no Tab in its text either, only
/// beeps, so a dropped Tab shows only here.
pub var test_forwarded: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

/// The field's subclass: its keys as the other fields' (`SearchBar.editKey`).
/// Enter commits and Escape cancels, each giving the shown tab's terminal
/// the focus back; the WM_CHARs a single-line EDIT beeps at or would put
/// in the title (Tab, Ctrl+Backspace's U+007F) are dropped, and
/// Ctrl+Backspace deletes a word. The focus leaving it otherwise commits
/// it, the focus left where it went.
fn editProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
    const proc = edit_proc.?;
    const window = windowOf(hwnd) orelse return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
    if (msg == win32.WM_KILLFOCUS) {
        const result = win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
        if (window.bar.editor.edit == hwnd) finish(window, .commit);
        return result;
    }
    switch (SearchBar.editKey(msg, wparam, false)) {
        .pass => {},
        .swallow => return 0,
        .next, .previous, .close => |key| {
            finish(window, if (key == .close) .cancel else .commit);
            if (window.tab().focused) |s| window.setKeyboardFocus(s.hwnd, true);
            return 0;
        },
        .delete_word => {
            SearchBar.deleteWord(window.app.core_app.alloc, hwnd);
            return 0;
        },
    }
    if (builtin.is_test) if (msg == win32.WM_CHAR or msg == win32.WM_SYSCHAR) {
        test_forwarded += 1;
    };
    return win32.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

/// The window whose bar holds `edit`, from the bar's own pointer to it.
fn windowOf(edit: win32.HWND) ?*Window {
    const bar = win32.GetAncestor(edit, win32.GA_PARENT) orelse return null;
    const v = win32.GetWindowLongPtrW(bar, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}
