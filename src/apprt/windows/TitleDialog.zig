//! The title prompt, GTK's title dialog (src/apprt/gtk/class/title_dialog.zig
//! and title-dialog.blp): `prompt_surface_title` asks for a terminal's own
//! title and `prompt_tab_title` for its tab's. The caption is the heading,
//! the text under it says that an empty title restores the default one,
//! and the field starts with the title shown now. OK, the default button,
//! sets the title, or clears it when the field is empty; Cancel changes
//! nothing.
//!
//! It is a dialog box made from a template in memory (`build`, `spec`) and
//! run modeless: `App.run` hands its keys to IsDialogMessageW, for Tab,
//! Enter and Escape, while ticks, output and `App.requests` keep running
//! in every window, with no nested message loop. It is modal to its
//! window, as GTK's alert is: its frame is disabled while it is open.
//!
//! A frame is enabled only when nothing holds it. Three things hold one:
//! a confirmation prompt holds every frame but its owner
//! (`App.beginPrompt`, `Window.prompt_disabled`), MessageBoxW holds that
//! owner while it runs, and this dialog holds its frame while it is open
//! (`Window.title_prompt`). Whoever lets go last enables it: a dialog that
//! closes while a prompt is open leaves its frame to the prompt's end
//! (`close`), and a prompt's end leaves the frame of a dialog still open
//! disabled, whatever MessageBoxW did to its owner (`App.endPrompt`). A
//! prompt also holds the dialog itself, as it holds every window of the
//! app.
//!
//! Opened from `App.run` (`App.Request.title_prompt`), never inside the
//! core frame that asked: disabling the frame takes the keyboard focus
//! from its terminal, and the dialog takes it next. It closes when its
//! terminal begins to close (`forget`), which a window's close begins with
//! (`Window.destroy`) and the app's quit too (`App.terminate`), and when
//! the terminal's tab moves to a new window (`followMove`). Windows
//! destroys it with its frame in any case, as an owned window.

const std = @import("std");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const App = @import("App.zig").App;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const utf8FromWide = @import("clipboard.zig").utf8FromWide;

const W = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32);

/// Whose title the prompt asks for: the terminal's own, or its tab's.
pub const Target = enum { surface, tab };

/// A window's title prompt (`Window.title_prompt`): at most one per
/// window, as its frame takes no input while one is open.
pub const Prompt = struct {
    /// The dialog; null while none is open.
    hwnd: ?win32.HWND = null,
    /// The terminal that asked, live while the dialog is open: it closes
    /// the dialog when it begins to close (`forget`).
    surface: ?*Surface = null,
    target: Target = .surface,
    /// Disabled by `App.beginPrompt`, for `App.endPrompt` to enable again.
    prompt_disabled: bool = false,
    /// The title bar was made dark (`setDark`).
    dark: bool = false,
};

/// The field's control id.
pub const edit_id = 100;

/// Room for either prompt's template, in 16-bit units (`spec`).
pub const template_capacity = 512;

/// Ask for `surface`'s title, or its tab's, in a dialog over its window;
/// whether it opened. Not while the window or the terminal is closing, nor
/// while the window has a prompt open already. Called by `App.run`, where
/// `App.canReenterCore` holds: no confirmation prompt is open, so the
/// frame is enabled now.
pub fn open(surface: *Surface, target: Target) bool {
    const window = surface.window;
    const app = window.app;
    if (window.title_prompt.hwnd != null) {
        log.info("a title prompt is open in this window already", .{});
        return false;
    }
    if (surface.closing or window.closing) return false;

    // The field starts with the title shown now: the override, else the
    // program's, as GTK starts it (surface.zig `promptTitle`, tab.zig
    // `promptTabTitle`).
    const initial: []const u8 = switch (target) {
        .surface => surface.effectiveTitle(),
        .tab => if (window.tabOf(surface)) |t| Window.tabTitle(t) else null,
    } orelse "";

    var buf: [template_capacity]u16 align(4) = undefined;
    // `spec` is fixed, and a test checks that it fits.
    const template = build(&buf, spec(target)) catch unreachable;

    window.title_prompt = .{ .surface = surface, .target = target };
    const hwnd = win32.CreateDialogIndirectParamW(
        app.hinstance,
        @ptrCast(template.ptr),
        window.hwnd,
        dialogProc,
        @bitCast(@intFromPtr(window)),
    ) orelse {
        log.err("CreateDialogIndirectParamW failed err={}", .{win32.GetLastError()});
        window.title_prompt = .{};
        return false;
    };
    window.title_prompt.hwnd = hwnd;

    const edit = win32.GetDlgItem(hwnd, edit_id);
    if (edit) |e| {
        const alloc = app.core_app.alloc;
        if (wideFromUtf8(alloc, initial)) |wide| {
            defer alloc.free(wide);
            _ = win32.SetWindowTextW(e, wide.ptr);
        } else |err| log.warn("cannot show the title in the prompt err={}", .{err});
        _ = win32.SendMessageW(e, win32.EM_SETSEL, 0, -1);
    }
    setDark(window, window.dark_frame);
    placeOverOwner(hwnd, window.hwnd);

    // Disabled after the dialog exists and before it shows, the order
    // DialogBox keeps, so that the activation goes from the frame straight
    // to the dialog ("The correct order for disabling and enabling
    // windows", The Old New Thing).
    _ = win32.EnableWindow(window.hwnd, .FALSE);

    // Shown with its window: a frame not on screen yet has no place for
    // it, and showing it would take the activation from another app.
    if (win32.IsWindowVisible(window.hwnd).toBool()) {
        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        if (edit) |e| _ = win32.SetFocus(e);
    }
    return true;
}

/// Close `window`'s title prompt, if it has one, and let go of its frame
/// (see the module's note): enabled now, or by `App.endPrompt` if a
/// confirmation prompt is open. The frame is enabled before the dialog is
/// destroyed, so that the activation comes back to it.
pub fn close(window: *Window) void {
    const hwnd = window.title_prompt.hwnd orelse return;
    release(window);
    _ = win32.DestroyWindow(hwnd);
}

/// Forget `window`'s open prompt and let go of its frame (`close`).
fn release(window: *Window) void {
    window.title_prompt = .{};
    if (window.app.prompt_depth > 0) {
        window.prompt_disabled = true;
    } else {
        _ = win32.EnableWindow(window.hwnd, .TRUE);
    }
}

/// `surface` is beginning to close, or is freed: the prompt it asked for,
/// in whichever window, closes. Called by `App.forgetClosing` and
/// `App.surfaceDestroyed`.
pub fn forget(app: *App, surface: *Surface) void {
    for (app.windows.items) |window| {
        if (window.title_prompt.surface == surface) close(window);
    }
}

/// A tab of `old` moved to a new window: if it took the terminal that
/// asked, the prompt closes as Cancel would. It is modal to `old`, which
/// it would otherwise keep disabled for a terminal now elsewhere; taking
/// it to the new frame would move the hold with it and change the owner
/// of a window on screen, for a move that can only come from another
/// window while this one takes no input.
pub fn followMove(old: *Window) void {
    const surface = old.title_prompt.surface orelse return;
    if (surface.window != old) close(old);
}

/// OK: the title in the field becomes the terminal's or the tab's, or an
/// empty one clears it, as GTK's `titleDialogSet` does; then the dialog
/// closes. Reached from `App.run`'s loop (IsDialogMessageW for Enter, the
/// button's click), never inside a core frame, and only with no
/// confirmation prompt open, which disables the dialog (`App.beginPrompt`).
/// Neither title changes the core's; the frame's caption and the tab bar
/// show it at once.
pub fn commit(window: *Window) void {
    const prompt = window.title_prompt;
    const hwnd = prompt.hwnd orelse return;
    const surface = prompt.surface orelse return;
    const alloc = window.app.core_app.alloc;
    const text = fieldText(alloc, hwnd) catch |err| {
        log.warn("cannot read the title prompt's field err={}", .{err});
        return;
    };
    defer alloc.free(text);
    switch (prompt.target) {
        .surface => _ = surface.setTitleOverride(text),
        .tab => _ = surface.window.setTabTitle(surface, text),
    }
    close(window);
}

/// The field's text, as UTF-8; the caller frees it.
fn fieldText(alloc: std.mem.Allocator, hwnd: win32.HWND) ![:0]u8 {
    const edit = win32.GetDlgItem(hwnd, edit_id) orelse return alloc.dupeSentinel(u8, "", 0);
    const len: usize = @intCast(@max(0, win32.GetWindowTextLengthW(edit)));
    const wide = try alloc.alloc(u16, len + 1);
    defer alloc.free(wide);
    const n: usize = @intCast(@max(0, win32.GetWindowTextW(edit, wide.ptr, @intCast(wide.len))));
    const utf8 = try utf8FromWide(alloc, wide[0..n]);
    defer alloc.free(utf8);
    return alloc.dupeSentinel(u8, utf8, 0);
}

/// Give the prompt's title bar the frame's mode (`Window.applyTheme`): the
/// dialog follows `window-theme` as the frames do. Its body stays light, as
/// MessageBoxW's does; only undocumented APIs change that.
pub fn setDark(window: *Window, dark: bool) void {
    const hwnd = window.title_prompt.hwnd orelse return;
    const value: win32.BOOL = if (dark) .TRUE else .FALSE;
    const hr = win32.DwmSetWindowAttribute(
        hwnd,
        win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &value,
        @sizeOf(win32.BOOL),
    );
    if (hr < 0) {
        log.warn("cannot set the title prompt's mode dark={} hr=0x{x}", .{ dark, @as(u32, @bitCast(hr)) });
        return;
    }
    window.title_prompt.dark = dark;
}

/// Centre the dialog over its frame, kept inside the work area of the
/// frame's monitor, as GTK centres its alert over its window.
fn placeOverOwner(hwnd: win32.HWND, owner: win32.HWND) void {
    var dialog: win32.RECT = undefined;
    var frame: win32.RECT = undefined;
    if (!win32.GetWindowRect(hwnd, &dialog).toBool()) return;
    if (!win32.GetWindowRect(owner, &frame).toBool()) return;
    const monitor = win32.MonitorFromWindow(owner, win32.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: win32.MONITORINFO = std.mem.zeroes(win32.MONITORINFO);
    info.cbSize = @sizeOf(win32.MONITORINFO);
    if (!win32.GetMonitorInfoW(monitor, &info).toBool()) return;
    const at = centred(frame, dialog.right - dialog.left, dialog.bottom - dialog.top, info.rcWork);
    _ = win32.SetWindowPos(
        hwnd,
        null,
        at.left,
        at.top,
        0,
        0,
        win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    );
}

/// The rect of a `width` x `height` window centred over `owner`, kept
/// inside `work` (`Window.constrainToWorkArea`).
pub fn centred(owner: win32.RECT, width: i32, height: i32, work: win32.RECT) win32.RECT {
    const x = owner.left + @divTrunc((owner.right - owner.left) - width, 2);
    const y = owner.top + @divTrunc((owner.bottom - owner.top) - height, 2);
    return Window.constrainToWorkArea(x, y, width, height, work);
}

/// The dialog's procedure. The window comes with WM_INITDIALOG; messages
/// before it find none and are left to the dialog manager.
fn dialogProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) isize {
    switch (msg) {
        // FALSE: no default focus. `open` gives the field the focus once
        // the dialog shows, and a dialog never shown takes none.
        win32.WM_INITDIALOG => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, lparam);
            return 0;
        },
        // Enter and OK are IDOK; Escape, Cancel and the close button are
        // IDCANCEL, which the dialog manager sends for WM_CLOSE too.
        win32.WM_COMMAND => {
            const window = windowOf(hwnd) orelse return 0;
            switch (@as(u16, @truncate(wparam))) {
                win32.IDOK => commit(window),
                win32.IDCANCEL => close(window),
                else => return 0,
            }
            return 1;
        },
        // Destroyed other than by `close`: by Windows, before its frame,
        // whose terminals then find no prompt to close (`forget`), or by
        // anything else, which must not leave the frame disabled.
        win32.WM_NCDESTROY => {
            const window = windowOf(hwnd) orelse return 0;
            if (window.title_prompt.hwnd == hwnd) release(window);
            return 0;
        },
        else => return 0,
    }
}

fn windowOf(hwnd: win32.HWND) ?*Window {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// ---------------------------------------------------------------------
// The template
// ---------------------------------------------------------------------

/// A control of a dialog template, of one of the predefined classes.
pub const Item = struct {
    class: Class,
    id: u16,
    style: u32,
    x: i16,
    y: i16,
    cx: i16,
    cy: i16,
    text: []const u16,

    /// The predefined window classes, by the atoms a template names them
    /// with.
    pub const Class = enum(u16) {
        button = 0x0080,
        edit = 0x0081,
        static = 0x0082,
    };
};

/// A dialog template: the dialog, in dialog units, its caption and font,
/// and its controls.
pub const Spec = struct {
    style: u32,
    x: i16,
    y: i16,
    cx: i16,
    cy: i16,
    caption: []const u16,
    point_size: u16,
    face: []const u16,
    items: []const Item,
};

/// The title prompt's template: the heading as its caption, as GTK's
/// heading (title_dialog.zig `Target.title`), its note under it, the field,
/// then OK, the default button, and Cancel.
pub fn spec(target: Target) Spec {
    return .{
        .style = win32.WS_POPUP | win32.WS_CAPTION | win32.WS_SYSMENU |
            win32.DS_MODALFRAME | win32.DS_SETFONT,
        .x = 0,
        .y = 0,
        .cx = 232,
        .cy = 64,
        .caption = switch (target) {
            .surface => W("Change Terminal Title"),
            .tab => W("Change Tab Title"),
        },
        .point_size = 9,
        .face = W("Segoe UI"),
        .items = &prompt_items,
    };
}

/// The title prompt's controls, in dialog units: the note, the field, OK
/// and Cancel, in tab order.
const prompt_items = items: {
    const child = win32.WS_CHILD | win32.WS_VISIBLE;
    break :items [_]Item{
        .{
            .class = .static,
            .id = 0xFFFF,
            .style = child | win32.SS_NOPREFIX,
            .x = 7,
            .y = 7,
            .cx = 218,
            .cy = 9,
            .text = W("Leave blank to restore the default title."),
        },
        .{
            .class = .edit,
            .id = edit_id,
            .style = child | win32.WS_BORDER | win32.WS_TABSTOP | win32.WS_GROUP | win32.ES_AUTOHSCROLL,
            .x = 7,
            .y = 19,
            .cx = 218,
            .cy = 14,
            .text = W(""),
        },
        .{
            .class = .button,
            .id = win32.IDOK,
            .style = child | win32.WS_TABSTOP | win32.WS_GROUP | win32.BS_DEFPUSHBUTTON,
            .x = 121,
            .y = 43,
            .cx = 50,
            .cy = 14,
            .text = W("OK"),
        },
        .{
            .class = .button,
            .id = win32.IDCANCEL,
            .style = child | win32.WS_TABSTOP | win32.BS_PUSHBUTTON,
            .x = 175,
            .y = 43,
            .cx = 50,
            .cy = 14,
            .text = W("Cancel"),
        },
    };
};

/// Write the DLGTEMPLATE of `s` into `buf`: the header, an empty menu and
/// the default class, the caption, the font (DS_SETFONT), then each
/// control's DLGITEMTEMPLATE, by class atom, with its text and no creation
/// data. The header and every control start on a DWORD boundary, which
/// `buf`'s alignment makes every even index; strings are null-terminated
/// UTF-16 (the layout under "DLGTEMPLATE" and "DLGITEMTEMPLATE" in the
/// Win32 documentation). Windows reads it little-endian, as every target
/// of this runtime stores a u16.
pub fn build(buf: []align(4) u16, s: Spec) error{NoSpaceLeft}![]align(4) const u16 {
    var w: Writer = .{ .buf = buf };
    try w.dword(s.style);
    try w.dword(0); // extended style
    try w.word(@intCast(s.items.len));
    try w.short(s.x);
    try w.short(s.y);
    try w.short(s.cx);
    try w.short(s.cy);
    try w.word(0); // no menu
    try w.word(0); // the dialog class
    try w.string(s.caption);
    try w.word(s.point_size);
    try w.string(s.face);
    for (s.items) |item| {
        try w.alignDword();
        try w.dword(item.style);
        try w.dword(0); // extended style
        try w.short(item.x);
        try w.short(item.y);
        try w.short(item.cx);
        try w.short(item.cy);
        try w.word(item.id);
        try w.word(0xFFFF); // a class atom follows
        try w.word(@backingInt(item.class));
        try w.string(item.text);
        try w.word(0); // no creation data
    }
    return buf[0..w.len];
}

const Writer = struct {
    buf: []align(4) u16,
    len: usize = 0,

    fn word(self: *Writer, v: u16) error{NoSpaceLeft}!void {
        if (self.len == self.buf.len) return error.NoSpaceLeft;
        self.buf[self.len] = v;
        self.len += 1;
    }

    fn dword(self: *Writer, v: u32) error{NoSpaceLeft}!void {
        try self.word(@truncate(v));
        try self.word(@truncate(v >> 16));
    }

    fn short(self: *Writer, v: i16) error{NoSpaceLeft}!void {
        try self.word(@bitCast(v));
    }

    fn string(self: *Writer, s: []const u16) error{NoSpaceLeft}!void {
        for (s) |unit| try self.word(unit);
        try self.word(0);
    }

    fn alignDword(self: *Writer) error{NoSpaceLeft}!void {
        if (self.len % 2 != 0) try self.word(0);
    }
};

test "win32: a dialog template is laid out as DLGTEMPLATE says" {
    const s: Spec = .{
        .style = 0x80C000C0,
        .x = 0,
        .y = 0,
        .cx = 100,
        .cy = 50,
        .caption = W("Ab"),
        .point_size = 9,
        .face = W("S"),
        .items = &.{.{
            .class = .button,
            .id = 1,
            .style = 0x50010001,
            .x = 1,
            .y = 2,
            .cx = 3,
            .cy = 4,
            .text = W("OK"),
        }},
    };
    var buf: [64]u16 align(4) = undefined;
    const got = try build(&buf, s);
    const want = [_]u16{
        0x00C0, 0x80C0, // style, low word first
        0, 0, // extended style
        1, // one control
        0, 0, 100, 50, // x, y, cx, cy
        0, // no menu
        0, // the dialog class
        'A', 'b', 0, // caption
        9, // point size
        'S', 0, // face
        0, // to the DWORD boundary the control starts on
        0x0001, 0x5001, // its style
        0, 0, // extended style
        1, 2, 3, 4, // x, y, cx, cy
        1, // id
        0xFFFF, 0x0080, // the button class's atom
        'O', 'K', 0, // text
        0, // no creation data
    };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), std.mem.sliceAsBytes(got));

    // Too little room is an error, not a short template.
    var small: [32]u16 align(4) = undefined;
    try std.testing.expectError(error.NoSpaceLeft, build(&small, s));
}

test "win32: the title prompt's template fits, every control on a DWORD" {
    for ([_]Target{ .surface, .tab }) |target| {
        var buf: [template_capacity]u16 align(4) = undefined;
        const s = spec(target);
        const got = try build(&buf, s);
        // Walk it as the dialog manager does: past the header, menu,
        // class and caption, the font, then each control.
        var i: usize = 11;
        while (got[i] != 0) i += 1;
        i += 2;
        while (got[i] != 0) i += 1;
        i += 1;
        for (s.items) |item| {
            i += i % 2;
            try std.testing.expectEqual(0, (@intFromPtr(&got[i]) - @intFromPtr(got.ptr)) % 4);
            try std.testing.expectEqual(item.id, got[i + 8]);
            try std.testing.expectEqual(@backingInt(item.class), got[i + 10]);
            i += 11;
            while (got[i] != 0) i += 1;
            i += 2;
        }
        try std.testing.expectEqual(got.len, i);
    }
}

test "win32: the title prompt is centred over its window, inside the work area" {
    const work: win32.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const frame: win32.RECT = .{ .left = 100, .top = 100, .right = 900, .bottom = 700 };
    try std.testing.expectEqual(
        win32.RECT{ .left = 350, .top = 340, .right = 650, .bottom = 460 },
        centred(frame, 300, 120, work),
    );
    // A frame hanging off the right edge: the dialog stays on screen.
    const off: win32.RECT = .{ .left = 1800, .top = 100, .right = 2400, .bottom = 700 };
    try std.testing.expectEqual(
        win32.RECT{ .left = 1620, .top = 340, .right = 1920, .bottom = 460 },
        centred(off, 300, 120, work),
    );
}
