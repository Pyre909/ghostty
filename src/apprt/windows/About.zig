//! About Ghostty and Ghostty Help, as items of every window's window menu
//! (Alt+Space, or a right click on the title bar or on the taskbar
//! button's thumbnail): Win32's counterpart of the main menu where GTK
//! lists About Ghostty (src/apprt/gtk/ui/1.4/window.blp) and macOS lists
//! both (AppDelegate.showAbout, showHelp). The quick terminal has no
//! window menu, and so neither item.
//!
//! About Ghostty shows a task dialog, as GTK's about dialog has it
//! (`actionAbout` in src/apprt/gtk/class/window.zig): the app's icon and
//! name, its version, "Ghostty Developers" and a link to the website,
//! which opens in the browser. Ghostty Help opens the documentation, as
//! macOS's Help menu does.
//!
//! TaskDialogIndirect is comctl32's, and only version 6's, which the
//! executable's manifest asks for (dist/windows/ghostty.manifest). It is
//! looked up when the dialog is first shown, not imported: an executable
//! without the manifest, such as the test runner, would get version 5,
//! which lacks it, and the loader would then refuse to start the whole
//! process. Without it the same text shows in a message box, links as
//! plain addresses.

const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("../../build_config.zig");
const i18n = @import("../../os/main.zig").i18n;
const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const openLink = @import("App.zig").openLink;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32);

const HRESULT = win32.HRESULT;
const HWND = win32.HWND;
const LPCWSTR = win32.LPCWSTR;
const UINT = win32.UINT;

/// The items' command ids, as WM_SYSCOMMAND's wParam carries them. Below
/// 0xF000, where the system's own (SC_*) begin, and with the low four bits
/// clear, which the system uses for itself (`win32.SC_MASK`).
pub const about_id: win32.UINT_PTR = 0x0010;
pub const help_id: win32.UINT_PTR = 0x0020;

/// As GTK's about dialog has them.
pub const website = "https://ghostty.org";
/// As macOS's Help menu opens it.
pub const docs = "https://ghostty.org/docs";

/// GTK's label, which the catalogs translate.
const about_label = "About Ghostty";
/// macOS's, which no catalog has yet: it shows as written.
const help_label = "Ghostty Help";

/// Add the two items, below a line, to the end of `hwnd`'s window menu.
/// GetSystemMenu gives the frame a copy of the system's own to change.
pub fn addToWindowMenu(hwnd: HWND) void {
    const menu = win32.GetSystemMenu(hwnd, .FALSE) orelse {
        log.warn("no window menu for About and Help err={}", .{win32.GetLastError()});
        return;
    };
    var buf: [128]u16 = undefined;
    const ok = win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null).toBool() and
        win32.AppendMenuW(menu, win32.MF_STRING, about_id, menuLabel(&buf, about_label)).toBool() and
        win32.AppendMenuW(menu, win32.MF_STRING, help_id, menuLabel(&buf, help_label)).toBool();
    if (!ok) log.warn("About and Help not added to the window menu err={}", .{win32.GetLastError()});
}

/// `msgid` in the language in use, in `buf`, with each '&' doubled: a
/// menu takes a single one for the mnemonic that follows. The source's
/// own text if the translation does not fit.
fn menuLabel(buf: []u16, comptime msgid: [:0]const u8) LPCWSTR {
    const text = std.mem.span(i18n._(msgid));
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return L(msgid)).iterator();
    while (it.nextCodepoint()) |cp| {
        // Room for a surrogate pair, a doubled '&', and the NUL after.
        if (n + 3 > buf.len) return L(msgid);
        if (cp == '&') {
            buf[n] = '&';
            n += 1;
        }
        if (cp < 0x10000) {
            buf[n] = @intCast(cp);
            n += 1;
        } else {
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
    }
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// A WM_SYSCOMMAND for one of the items: carried out, and true. False for
/// any other command, which the frame handles as before.
pub fn command(app: *App, hwnd: HWND, wparam: win32.WPARAM) bool {
    switch (wparam & win32.SC_MASK) {
        about_id => show(app, hwnd),
        help_id => open(docs),
        else => return false,
    }
    return true;
}

fn open(url: []const u8) void {
    if (builtin.is_test) {
        test_record.opened = url;
        return;
    }
    // A link of our own, not a program's, so `.html` rather than one of
    // the untrusted kinds.
    _ = openLink(.html, url); // logs its own failures
}

/// The dialog, modal to every window, as a prompt is (`App.beginPrompt`):
/// a task dialog, or a message box without TaskDialogIndirect. None once
/// the windows are closing for good, as `dialog.messageBox` has none then.
pub fn show(app: *App, hwnd: HWND) void {
    if (app.terminating) return;
    const alloc = app.core_app.alloc;
    var title_buf: [128]u16 = undefined;
    const title = text16(&title_buf, about_label);
    const developers = std.mem.span(i18n._("Ghostty Developers"));

    const owner = app.promptOwner(hwnd);
    app.beginPrompt(owner);
    defer app.endPrompt();

    if (taskDialog()) |task_dialog| {
        const content = std.fmt.allocPrintSentinel(alloc, "{s}\n{s}\n\n<a href=\"{s}\">{s}</a>", .{
            build_config.version_string,
            developers,
            website,
            website["https://".len..],
        }, 0) catch return oom();
        defer alloc.free(content);
        const wide = wideZ(alloc, content) orelse return oom();
        defer alloc.free(wide);
        const config: TASKDIALOGCONFIG = .{
            .cbSize = @sizeOf(TASKDIALOGCONFIG),
            .hwndParent = owner,
            .hInstance = app.hinstance,
            .dwFlags = TDF_ENABLE_HYPERLINKS | TDF_ALLOW_DIALOG_CANCELLATION |
                TDF_POSITION_RELATIVE_TO_WINDOW |
                if (i18n.windows.rightToLeft()) TDF_RTL_LAYOUT else 0,
            .dwCommonButtons = TDCBF_OK_BUTTON,
            .pszWindowTitle = title,
            .main_icon = .{ .pszMainIcon = @ptrFromInt(icon_resource_id) },
            .pszMainInstruction = L("Ghostty"),
            .pszContent = wide.ptr,
            .pfCallback = callback,
        };
        const hr = task_dialog(&config, null, null, null);
        if (hr < 0) log.warn("TaskDialogIndirect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return;
    }

    const content = std.fmt.allocPrintSentinel(alloc, "Ghostty {s}\n{s}\n\n{s}", .{
        build_config.version_string,
        developers,
        website,
    }, 0) catch return oom();
    defer alloc.free(content);
    const wide = wideZ(alloc, content) orelse return oom();
    defer alloc.free(wide);
    const flags = win32.MB_OK | win32.MB_ICONINFORMATION | if (i18n.windows.rightToLeft())
        win32.MB_RTLREADING | win32.MB_RIGHT
    else
        0;
    if (builtin.is_test) {
        test_record.message_box = true;
        return;
    }
    _ = win32.MessageBoxW(owner, wide.ptr, title, flags);
}

fn oom() void {
    log.warn("About Ghostty not shown err=OutOfMemory", .{});
}

/// `text`'s UTF-16, or null without the memory. Our own text and the
/// catalogs', valid UTF-8 both.
fn wideZ(alloc: std.mem.Allocator, text: []const u8) ?[:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => null,
        error.InvalidUtf8 => unreachable,
    };
}

/// `msgid` in the language in use, in `buf`, or as written if that does
/// not fit.
fn text16(buf: []u16, comptime msgid: [:0]const u8) LPCWSTR {
    const text = std.mem.span(i18n._(msgid));
    if (text.len >= buf.len) return L(msgid);
    const n = std.unicode.utf8ToUtf16Le(buf, text) catch return L(msgid);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// The dialog's link, opened in the browser. Only the website's: the
/// dialog's text is ours, and any other target is refused.
fn callback(
    _: ?HWND,
    msg: UINT,
    _: win32.WPARAM,
    lparam: win32.LPARAM,
    _: isize,
) callconv(.winapi) HRESULT {
    if (msg == TDN_HYPERLINK_CLICKED) {
        const href: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (std.mem.eql(u16, std.mem.span(href), L(website))) {
            open(website);
        } else {
            log.warn("the About dialog's link is not the website's", .{});
        }
    }
    return win32.S_OK;
}

/// The exe's icon (ID_ICON_GHOSTTY in dist/windows/ghostty.rc), which the
/// dialog loads from `hInstance`.
const icon_resource_id = 1;

// commctrl.h's task dialog.
// https://learn.microsoft.com/en-us/windows/win32/api/commctrl/nf-commctrl-taskdialogindirect

const TDF_ENABLE_HYPERLINKS: c_int = 0x0001;
const TDF_ALLOW_DIALOG_CANCELLATION: c_int = 0x0008;
const TDF_POSITION_RELATIVE_TO_WINDOW: c_int = 0x1000;
const TDF_RTL_LAYOUT: c_int = 0x2000;
const TDCBF_OK_BUTTON: c_int = 0x0001;
const TDN_HYPERLINK_CLICKED: UINT = 3;

const Callback = *const fn (?HWND, UINT, win32.WPARAM, win32.LPARAM, isize) callconv(.winapi) HRESULT;

/// commctrl.h declares it between pshpack1.h and poppack.h, so it is
/// packed: each field at byte alignment.
pub const TASKDIALOGCONFIG = extern struct {
    cbSize: UINT align(1),
    hwndParent: ?HWND align(1) = null,
    hInstance: ?win32.HINSTANCE align(1) = null,
    dwFlags: c_int align(1) = 0,
    dwCommonButtons: c_int align(1) = 0,
    pszWindowTitle: ?LPCWSTR align(1) = null,
    /// A resource's id (MAKEINTRESOURCE) or a name: an id is an odd
    /// address, so the pointer is byte aligned.
    main_icon: extern union { pszMainIcon: ?[*:0]align(1) const u16 align(1) } align(1) = .{ .pszMainIcon = null },
    pszMainInstruction: ?LPCWSTR align(1) = null,
    pszContent: ?LPCWSTR align(1) = null,
    cButtons: UINT align(1) = 0,
    pButtons: ?*const anyopaque align(1) = null,
    nDefaultButton: c_int align(1) = 0,
    cRadioButtons: UINT align(1) = 0,
    pRadioButtons: ?*const anyopaque align(1) = null,
    nDefaultRadioButton: c_int align(1) = 0,
    pszVerificationText: ?LPCWSTR align(1) = null,
    pszExpandedInformation: ?LPCWSTR align(1) = null,
    pszExpandedControlText: ?LPCWSTR align(1) = null,
    pszCollapsedControlText: ?LPCWSTR align(1) = null,
    footer_icon: extern union { pszFooterIcon: ?LPCWSTR align(1) } align(1) = .{ .pszFooterIcon = null },
    pszFooter: ?LPCWSTR align(1) = null,
    pfCallback: ?Callback align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: UINT align(1) = 0,
};

const TaskDialogIndirectFn = *const fn (
    config: *const TASKDIALOGCONFIG,
    button: ?*c_int,
    radio: ?*c_int,
    verified: ?*win32.BOOL,
) callconv(.winapi) HRESULT;

/// For tests: what was shown, in place of the dialogs. A test that shows
/// the dialog without setting `test_record.task_dialog` sees the message
/// box's path.
pub const TestRecord = struct {
    /// Stands for TaskDialogIndirect when set; it is given the config.
    task_dialog: ?TaskDialogIndirectFn = null,
    message_box: bool = false,
    /// The last link opened (`open`), in place of the browser.
    opened: ?[]const u8 = null,
};
pub var test_record: if (builtin.is_test) TestRecord else void =
    if (builtin.is_test) .{} else {};

/// TaskDialogIndirect, looked up once, or null where comctl32 is not
/// version 6.
fn taskDialog() ?TaskDialogIndirectFn {
    if (builtin.is_test) return test_record.task_dialog;
    const State = struct {
        var looked_up = false;
        var found: ?TaskDialogIndirectFn = null;
    };
    if (!State.looked_up) {
        State.looked_up = true;
        if (win32.LoadLibraryExW(L("comctl32.dll"), null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32)) |module| {
            if (win32.GetProcAddress(module, "TaskDialogIndirect")) |proc| {
                State.found = @ptrCast(@alignCast(proc));
            } else log.warn("comctl32 has no TaskDialogIndirect: not version 6", .{});
        } else log.warn("cannot load comctl32 err={}", .{win32.GetLastError()});
    }
    return State.found;
}

test "win32: the task dialog's config is the header's size" {
    // pshpack1: eight 32-bit fields and sixteen pointers, with no padding
    // after cbSize or any other 32-bit field.
    try std.testing.expectEqual(@as(usize, 8 * 4 + 16 * @sizeOf(usize)), @sizeOf(TASKDIALOGCONFIG));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(TASKDIALOGCONFIG));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(TASKDIALOGCONFIG, "hwndParent"));
}

test "win32: a menu label doubles its ampersands" {
    var buf: [32]u16 = undefined;
    const label = menuLabel(&buf, "Fish & Chips");
    try std.testing.expectEqualSlices(u16, L("Fish && Chips"), std.mem.span(label));
}

test "win32: the items' ids are the app's, not the system's" {
    inline for (.{ about_id, help_id }) |id| {
        try std.testing.expect(id < 0xF000);
        try std.testing.expectEqual(@as(usize, 0), id & ~win32.SC_MASK);
    }
}
