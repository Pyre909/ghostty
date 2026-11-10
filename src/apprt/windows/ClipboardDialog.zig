//! The Kitty clipboard prompt (OSC 5522), GTK's clipboard confirmation
//! dialog (src/apprt/gtk/class/clipboard_confirmation_dialog.zig and
//! ui/1.5/clipboard-confirmation-dialog.blp) and the macOS app's
//! (macos/Sources/Features/ClipboardConfirmation): it shows what a program
//! would read or write, one part per MIME type, picked from a list when
//! there is more than one, as GTK lists them. A part shows as an image if
//! it is one this runtime decodes (`clipboard.picture`), else as its text
//! if it is UTF-8, else as "No preview available" and its size, the order
//! GTK tries (`previewPart`). A write names the types Windows has no
//! format for, which it leaves out (`clipboard.formatOf`).
//!
//! Deny is the default button, as in GTK (`default-response: "cancel"`)
//! and in this runtime's other clipboard prompts (`dialog.ConfirmDefault`):
//! a program can raise one at any moment, so a key the user was already
//! typing must not answer it. Allow allows; with the box checked it also
//! keeps a session grant (`CompleteClipboard.remember`), which the box is
//! offered for only when the program gave a password, as GTK offers it
//! (surface.zig `showClipboardConfirmation`). Deny is never remembered, as
//! in GTK and the macOS app.
//!
//! The program's name for itself is never shown: the macOS app leaves it
//! out because a program could put any text in a prompt the user trusts
//! (Ghostty.ClipboardConfirmationRequest.swift `text`). What is shown of
//! the program's, its MIME types and its text, has every control,
//! bidirectional and zero-width code point escaped (`App.unsafeCodepoint`),
//! as a link's preview has (`LinkPreview`).
//!
//! A modal dialog box made from a template in memory (`TitleDialog.build`).
//! DialogBoxIndirectParamW, as MessageBoxW does, disables its owner and
//! runs its own message loop until the dialog ends, so it is run as
//! `dialog.messageBox` runs MessageBoxW: inside `App.beginPrompt` and
//! `App.endPrompt`, owned by `App.promptOwner`, and answered with no dialog
//! once the windows close for good (`App.terminating`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const win32 = @import("win32.zig");
const App = @import("App.zig").App;
const unsafeCodepoint = @import("App.zig").unsafeCodepoint;
const TitleDialog = @import("TitleDialog.zig");
const Window = @import("Window.zig");
const clipboard = @import("clipboard.zig");

const Content = terminal.clipboard.Content;
const Item = TitleDialog.Item;
const W = std.unicode.utf8ToUtf16LeStringLiteral;
const Question = @import("dialog.zig").Question;
const log = std.log.scoped(.win32);

/// The user's answer.
pub const Answer = enum {
    deny,
    allow,
    /// Allow, and keep a session grant for the request's password.
    allow_and_remember,
};

/// The controls, by id.
pub const id_heading = 100;
pub const id_note = 101;
/// The list of parts, or the one part's name when there is only one.
pub const id_parts = 102;
/// The previews, one shown at a time (`Dialog.show`).
pub const id_text = 103;
pub const id_image = 104;
pub const id_none = 105;
pub const id_unwritten = 106;
pub const id_remember = 107;

/// The most of a text part the preview shows, in bytes of UTF-8. An EDIT
/// control lays out all it holds, and a part may be as long as a whole
/// write (`terminal.kitty.clipboard.max_write_size`).
pub const max_preview_text = 64 * 1024;

/// For tests: what runs the dialog in place of DialogBoxIndirectParamW,
/// given it made from the same template and procedure, modeless and
/// hidden. It answers as the user would, by the controls and WM_COMMAND;
/// unanswered is Deny, as the close button answers.
pub var test_run: if (builtin.is_test) ?*const fn (win32.HWND) void else void =
    if (builtin.is_test) null else {};

/// For tests: the dialog cannot be made, as when DialogBoxIndirectParamW
/// fails.
pub var test_fail: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// For tests: the allocator the dialog makes its text and pictures with,
/// in place of the app's.
pub var test_alloc: if (builtin.is_test) ?Allocator else void = if (builtin.is_test) null else {};

/// Ask whether the Kitty clipboard request `state` may go ahead, from the
/// terminal `hwnd` in `window`, showing what it would read, `read`, or
/// write. The title bar takes the window's mode and follows it while the
/// dialog is open (`Window.clipboard_prompt`), as the title prompt's does
/// (`TitleDialog.setDark`). Deny if the dialog cannot be made, or if a
/// write has more parts than it holds (`writeParts`), each logged: the
/// program is told it was refused.
pub fn ask(
    app: *App,
    hwnd: ?win32.HWND,
    window: *Window,
    state: apprt.ClipboardRequest,
    read: []const Content,
) Answer {
    if (app.terminating) {
        log.warn("a Kitty clipboard prompt while the windows close is answered Deny", .{});
        return .deny;
    }

    var buf: [max_write_parts]Content = undefined;
    const alloc = if (builtin.is_test) test_alloc orelse app.core_app.alloc else app.core_app.alloc;
    var self: Dialog = switch (state) {
        .kitty_read => |kitty| .{
            .alloc = alloc,
            .request = .kitty_read,
            .parts = read,
            .can_remember = kitty.pw.len > 0,
            .window = window,
        },
        .kitty_write => |kitty| .{
            .alloc = alloc,
            .request = .kitty_write,
            .parts = writeParts(kitty.contents, &buf) orelse {
                log.warn("a Kitty clipboard write of {d} types, more than its prompt holds, is denied", .{kitty.contents.len});
                return .deny;
            },
            .can_remember = kitty.pw.len > 0,
            .window = window,
        },
        else => unreachable,
    };
    defer self.forgetPicture();

    var template_buf: [template_capacity]u16 align(4) = undefined;
    var items: [max_items]Item = undefined;
    var question: Question = .{};
    // The largest template fits, which a test checks.
    const template = TitleDialog.build(&template_buf, self.spec(&items, &question)) catch unreachable;

    const owner = app.promptOwner(hwnd);
    app.beginPrompt(owner);
    defer app.endPrompt();
    // Once the dialog returns it is gone, and the window's prompt is again
    // the one open before it, if any.
    const outer = window.clipboard_prompt;
    defer window.clipboard_prompt = outer;
    const result = if (builtin.is_test)
        self.testDialog(app.hinstance, owner, template)
    else
        win32.DialogBoxIndirectParamW(
            app.hinstance,
            @ptrCast(template.ptr),
            owner,
            dialogProc,
            @bitCast(@intFromPtr(&self)),
        );
    // `end` passes 1, so 0 is a failure too: an owner that is no window.
    if (result <= 0) {
        log.warn("the Kitty clipboard prompt could not be shown, denied err={}", .{win32.GetLastError()});
        return .deny;
    }
    return self.answer;
}

/// The most parts a write holds. The core commits each type a program
/// sends, at most `max_write_mimes`, then each alias that names a new
/// type, at most `max_write_aliases`, as a part of its own
/// (src/terminal/kitty/clipboard_write.zig:25-26 and `WriteState.commit`).
const max_write_parts = terminal.kitty.clipboard.max_write_mimes + terminal.kitty.clipboard.max_write_aliases;

/// What a write would write: every part it carries, or for an empty write,
/// which clears the clipboard, the empty text the core writes then
/// (`Surface.completeClipboardRequest`). Null when there are more parts
/// than `buf` holds, which the core never commits: a prompt that showed
/// only some of them could hide the one that lands.
fn writeParts(contents: []const apprt.ClipboardContent, buf: []Content) ?[]const Content {
    if (contents.len == 0) {
        buf[0] = .{ .mime = "text/plain", .data = "" };
        return buf[0..1];
    }
    if (contents.len > buf.len) return null;
    for (contents, buf[0..contents.len]) |c, *p| p.* = .{ .mime = c.mime, .data = c.data };
    return buf[0..contents.len];
}

/// Room for the largest template (`Dialog.spec`), in 16-bit units.
const template_capacity = 1024;
const max_items = 10;

/// A dialog while it is up: what it shows, and the answer.
const Dialog = struct {
    alloc: Allocator,
    request: apprt.ClipboardRequestType,
    parts: []const Content,
    can_remember: bool,
    /// The window of the terminal that asked, whose mode the title bar
    /// takes.
    window: *Window,
    /// The picture of the part shown, while it is one.
    picture: ?clipboard.Picture = null,
    answer: Answer = .deny,

    /// The dialog's template: the heading and the note under it, the parts,
    /// the previews in one place, what a write leaves out, the box to
    /// remember, then Allow and Deny, the default, in dialog units.
    /// `question` holds the heading's text, so it has to live as long as
    /// what this returns.
    fn spec(self: *const Dialog, items: *[max_items]Item, question: *Question) TitleDialog.Spec {
        const child = win32.WS_CHILD | win32.WS_VISIBLE;
        const line = win32.SS_NOPREFIX | win32.SS_LEFTNOWORDWRAP | win32.SS_ENDELLIPSIS;
        const width = 300;
        const inner = width - 14;
        var list: std.ArrayList(Item) = .initBuffer(items);

        list.appendAssumeCapacity(.{
            .class = .static,
            .id = id_heading,
            .style = child | line,
            .x = 7,
            .y = 7,
            .cx = inner,
            .cy = 9,
            .text = std.mem.span(clipboard.clipboardPrompt(self.request, question)),
        });
        // The macOS app's second line (`ClipboardRequest.text`).
        list.appendAssumeCapacity(.{
            .class = .static,
            .id = id_note,
            .style = child | line,
            .x = 7,
            .y = 17,
            .cx = inner,
            .cy = 9,
            .text = switch (self.request) {
                .kitty_read => W("The current clipboard contents are shown below."),
                else => W("The content to write is shown below."),
            },
        });
        list.appendAssumeCapacity(if (self.parts.len > 1) .{
            .class = .combobox,
            .id = id_parts,
            // The height takes in the open list.
            .style = child | win32.WS_TABSTOP | win32.WS_GROUP | win32.WS_VSCROLL | win32.CBS_DROPDOWNLIST,
            .x = 7,
            .y = 30,
            .cx = inner,
            .cy = 120,
            .text = W(""),
        } else .{
            .class = .static,
            .id = id_parts,
            .style = child | line,
            .x = 7,
            .y = 32,
            .cx = inner,
            .cy = 9,
            .text = W(""),
        });

        const top = 47;
        const height = 120;
        list.appendAssumeCapacity(.{
            .class = .edit,
            .id = id_text,
            .style = win32.WS_CHILD | win32.WS_BORDER | win32.WS_TABSTOP | win32.WS_VSCROLL |
                win32.ES_MULTILINE | win32.ES_READONLY | win32.ES_AUTOVSCROLL,
            .x = 7,
            .y = top,
            .cx = inner,
            .cy = height,
            .text = W(""),
        });
        list.appendAssumeCapacity(.{
            .class = .static,
            .id = id_image,
            .style = win32.WS_CHILD | win32.SS_OWNERDRAW,
            .x = 7,
            .y = top,
            .cx = inner,
            .cy = height,
            .text = W(""),
        });
        list.appendAssumeCapacity(.{
            .class = .static,
            .id = id_none,
            .style = win32.WS_CHILD | win32.SS_CENTER | win32.SS_NOPREFIX,
            .x = 7,
            .y = top + height / 2 - 9,
            .cx = inner,
            .cy = 18,
            .text = W(""),
        });

        var y: i16 = top + height + 5;
        if (self.unwritten() > 0) {
            list.appendAssumeCapacity(.{
                .class = .static,
                .id = id_unwritten,
                .style = child | line,
                .x = 7,
                .y = y,
                .cx = inner,
                .cy = 9,
                .text = W(""),
            });
            y += 12;
        }
        if (self.can_remember) {
            // The macOS app's words (ClipboardConfirmationView.swift).
            list.appendAssumeCapacity(.{
                .class = .button,
                .id = id_remember,
                .style = child | win32.WS_TABSTOP | win32.WS_GROUP | win32.BS_AUTOCHECKBOX,
                .x = 7,
                .y = y,
                .cx = inner,
                .cy = 10,
                .text = W("Remember this choice for the session"),
            });
            y += 14;
        }
        y += 3;
        list.appendAssumeCapacity(.{
            .class = .button,
            .id = win32.IDOK,
            .style = child | win32.WS_TABSTOP | win32.WS_GROUP | win32.BS_PUSHBUTTON,
            .x = width - 7 - 50 - 4 - 50,
            .y = y,
            .cx = 50,
            .cy = 14,
            .text = W("Allow"),
        });
        list.appendAssumeCapacity(.{
            .class = .button,
            .id = win32.IDCANCEL,
            .style = child | win32.WS_TABSTOP | win32.BS_DEFPUSHBUTTON,
            .x = width - 7 - 50,
            .y = y,
            .cx = 50,
            .cy = 14,
            .text = W("Deny"),
        });

        return .{
            // DS_CENTER where `init` cannot place it over its owner.
            .style = win32.WS_POPUP | win32.WS_CAPTION | win32.WS_SYSMENU |
                win32.DS_MODALFRAME | win32.DS_SETFONT | win32.DS_CENTER,
            .x = 0,
            .y = 0,
            .cx = width,
            .cy = y + 14 + 7,
            // GTK's heading.
            .caption = W("Authorize Clipboard Access"),
            .point_size = 9,
            .face = W("Segoe UI"),
            .items = list.items,
        };
    }

    /// How many of a write's types Windows has no format for.
    fn unwritten(self: *const Dialog) usize {
        if (self.request != .kitty_write) return 0;
        var n: usize = 0;
        for (self.parts) |part| n += @intFromBool(clipboard.formatOf(part.mime) == null);
        return n;
    }

    /// WM_INITDIALOG: the title bar's mode, the place over the owner, the
    /// parts, what a write leaves out, and the first part shown, with the
    /// keyboard focus on Deny.
    fn init(self: *Dialog, hwnd: win32.HWND) void {
        TitleDialog.darkTitleBar(hwnd, self.window.dark_frame);
        self.window.clipboard_prompt = hwnd;
        if (win32.GetWindow(hwnd, win32.GW_OWNER)) |owner| TitleDialog.placeOverOwner(hwnd, owner);

        if (self.parts.len > 1) {
            // One entry per part, in order, even for a part that cannot be
            // named: the entry picked is the part shown (`show`).
            const list = win32.GetDlgItem(hwnd, id_parts);
            for (self.parts, 0..) |part, i| {
                var buf: [64]u16 = undefined;
                const named = self.partName(part);
                defer if (named) |n| self.alloc.free(n) else |_| {};
                const name = named catch |err| unnamed: {
                    log.warn("a Kitty clipboard prompt cannot name a part err={}", .{err});
                    break :unnamed unnamedPart(&buf, i, part);
                };
                if (list) |l| _ = win32.SendMessageW(l, win32.CB_ADDSTRING, 0, @bitCast(@intFromPtr(name.ptr)));
            }
            if (list) |l| _ = win32.SendMessageW(l, win32.CB_SETCURSEL, 0, 0);
        } else if (self.parts.len == 1) {
            var buf: [64]u16 = undefined;
            const named = self.partName(self.parts[0]);
            defer if (named) |n| self.alloc.free(n) else |_| {};
            const name = named catch |err| unnamed: {
                log.warn("a Kitty clipboard prompt cannot name a part err={}", .{err});
                break :unnamed unnamedPart(&buf, 0, self.parts[0]);
            };
            _ = win32.SetDlgItemTextW(hwnd, id_parts, name.ptr);
        } else {
            // A read of types the clipboard has none of, with its listing.
            _ = win32.SetDlgItemTextW(hwnd, id_parts, W("The clipboard holds none of the types asked for."));
        }

        if (self.unwritten() > 0) {
            if (self.unwrittenText()) |text| {
                defer self.alloc.free(text);
                _ = win32.SetDlgItemTextW(hwnd, id_unwritten, text.ptr);
            } else |err| {
                log.warn("a Kitty clipboard prompt cannot name what is left out err={}", .{err});
                _ = win32.SetDlgItemTextW(hwnd, id_unwritten, W("Some types are not written: Windows has no clipboard format for them"));
            }
        }

        self.show(hwnd, 0);
        if (win32.GetDlgItem(hwnd, win32.IDCANCEL)) |deny| _ = win32.SetFocus(deny);
    }

    /// Show the part at `index`, or that there is none to show.
    fn show(self: *Dialog, hwnd: win32.HWND, index: usize) void {
        self.forgetPicture();
        const shown: c_int = if (index < self.parts.len) self.preview(hwnd, self.parts[index]) else none: {
            _ = win32.SetDlgItemTextW(hwnd, id_none, W("No preview available"));
            break :none id_none;
        };
        for ([_]c_int{ id_text, id_image, id_none }) |id| {
            const control = win32.GetDlgItem(hwnd, id) orelse continue;
            _ = win32.ShowWindow(control, if (id == shown) win32.SW_SHOWNA else win32.SW_HIDE);
        }
        if (shown == id_image) if (win32.GetDlgItem(hwnd, id_image)) |image| {
            _ = win32.InvalidateRect(image, null, .TRUE);
        };
    }

    /// Fill the preview `part` shows as, as GTK picks it
    /// (clipboard_confirmation_dialog.zig `previewPart`); its id.
    fn preview(self: *Dialog, hwnd: win32.HWND, part: Content) c_int {
        if (std.mem.startsWith(u8, part.mime, "image/")) {
            if (clipboard.picture(self.alloc, part.data, win32.GetSysColor(win32.COLOR_BTNFACE))) |p| {
                self.picture = p;
                return id_image;
            }
        }
        if (std.unicode.utf8ValidateSlice(part.data)) text: {
            const text = previewText(self.alloc, part.data) catch |err| {
                log.warn("a Kitty clipboard prompt cannot show a text err={}", .{err});
                break :text;
            };
            defer self.alloc.free(text);
            _ = win32.SetDlgItemTextW(hwnd, id_text, text.ptr);
            return id_text;
        }
        var buf: [96]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, "No preview available\r\n{f}", .{size(part.data.len)}) catch unreachable;
        var wide: [buf.len + 1]u16 = undefined;
        // ASCII.
        const n = std.unicode.utf8ToUtf16Le(&wide, note) catch unreachable;
        wide[n] = 0;
        _ = win32.SetDlgItemTextW(hwnd, id_none, wide[0..n :0]);
        return id_none;
    }

    fn forgetPicture(self: *Dialog) void {
        const p = self.picture orelse return;
        p.deinit(self.alloc);
        self.picture = null;
    }

    /// "type (N bytes)", the type escaped.
    fn partName(self: *const Dialog, part: Content) ![:0]u16 {
        var out: std.ArrayList(u16) = .empty;
        errdefer out.deinit(self.alloc);
        try appendEscaped(self.alloc, &out, part.mime);
        var buf: [40]u8 = undefined;
        try appendAscii(self.alloc, &out, std.fmt.bufPrint(&buf, " ({f})", .{size(part.data.len)}) catch unreachable);
        return out.toOwnedSliceSentinel(self.alloc, 0);
    }

    /// A part's name when `partName` cannot make it: its place and size,
    /// made in `buf`, which nothing the program sent can make unsafe.
    fn unnamedPart(buf: *[64]u16, index: usize, part: Content) [:0]const u16 {
        var utf8: [buf.len]u8 = undefined;
        const text = std.fmt.bufPrint(&utf8, "Part {d} ({f})", .{ index + 1, size(part.data.len) }) catch unreachable;
        // ASCII, so as many units as bytes, and one left for the NUL.
        const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch unreachable;
        buf[n] = 0;
        return buf[0..n :0];
    }

    /// The types of a write Windows has no format for, escaped.
    fn unwrittenText(self: *const Dialog) ![:0]u16 {
        var out: std.ArrayList(u16) = .empty;
        errdefer out.deinit(self.alloc);
        try appendAscii(self.alloc, &out, "Not written, Windows has no clipboard format for: ");
        var first = true;
        for (self.parts) |part| {
            if (clipboard.formatOf(part.mime) != null) continue;
            if (!first) try appendAscii(self.alloc, &out, ", ");
            first = false;
            try appendEscaped(self.alloc, &out, part.mime);
        }
        return out.toOwnedSliceSentinel(self.alloc, 0);
    }

    /// WM_DRAWITEM for the picture: drawn over the dialog's face, as large
    /// as its place allows, its shape kept (GTK's `content-fit: contain`).
    /// The stretch mode and brush origin it sets are put back, as
    /// WM_DRAWITEM asks that the control's DC be left in its default state.
    fn draw(self: *const Dialog, item: *const win32.DRAWITEMSTRUCT) void {
        if (win32.GetSysColorBrush(win32.COLOR_BTNFACE)) |face| _ = win32.FillRect(item.hDC, &item.rcItem, face);
        const p = self.picture orelse return;
        const at = fit(item.rcItem, p.width, p.height);
        const saved = win32.SaveDC(item.hDC);
        defer if (saved != 0) {
            _ = win32.RestoreDC(item.hDC, saved);
        };
        _ = win32.SetStretchBltMode(item.hDC, win32.HALFTONE);
        _ = win32.SetBrushOrgEx(item.hDC, 0, 0, null);
        const lines = win32.StretchDIBits(
            item.hDC,
            at.left,
            at.top,
            at.right - at.left,
            at.bottom - at.top,
            0,
            0,
            p.width,
            p.height,
            p.bits.ptr,
            p.info.ptr,
            win32.DIB_RGB_COLORS,
            win32.SRCCOPY,
        );
        if (lines == 0) log.warn("StretchDIBits failed for a clipboard picture width={d} height={d}", .{ p.width, p.height });
    }

    fn end(self: *Dialog, hwnd: win32.HWND, answer: Answer) void {
        self.answer = answer;
        _ = win32.EndDialog(hwnd, 1);
    }

    /// Whether the box to remember is checked; never when it is not offered.
    fn remembered(self: *const Dialog, hwnd: win32.HWND) bool {
        if (!self.can_remember) return false;
        const box = win32.GetDlgItem(hwnd, id_remember) orelse return false;
        return win32.SendMessageW(box, win32.BM_GETCHECK, 0, 0) == win32.BST_CHECKED;
    }

    /// Run in place of DialogBoxIndirectParamW in tests (`test_run`).
    fn testDialog(self: *Dialog, instance: ?win32.HINSTANCE, owner: ?win32.HWND, template: []align(4) const u16) isize {
        if (test_fail) return -1;
        const run = test_run orelse {
            log.err("a Kitty clipboard prompt in a test with no test_run", .{});
            return -1;
        };
        const hwnd = win32.CreateDialogIndirectParamW(
            instance,
            @ptrCast(template.ptr),
            owner,
            dialogProc,
            @bitCast(@intFromPtr(self)),
        ) orelse return -1;
        defer _ = win32.DestroyWindow(hwnd);
        run(hwnd);
        return 1;
    }
};

/// The dialog's procedure. The dialog comes with WM_INITDIALOG; messages
/// before it find none and are left to the dialog manager.
fn dialogProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) isize {
    App.handler_depth += 1;
    defer App.handler_depth -= 1;
    switch (msg) {
        // FALSE: `init` gives Deny the focus.
        win32.WM_INITDIALOG => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, lparam);
            const self = dialogOf(hwnd) orelse return 0;
            self.init(hwnd);
            return 0;
        },
        // Allow is IDOK. Deny, Escape and the close button are IDCANCEL,
        // which the dialog manager sends for WM_CLOSE too.
        win32.WM_COMMAND => {
            const self = dialogOf(hwnd) orelse return 0;
            const id: u16 = @truncate(wparam);
            switch (id) {
                win32.IDOK => self.end(hwnd, if (self.remembered(hwnd)) .allow_and_remember else .allow),
                win32.IDCANCEL => self.end(hwnd, .deny),
                id_parts => {
                    if (@as(u16, @truncate(wparam >> 16)) != win32.CBN_SELCHANGE) return 0;
                    const list = win32.GetDlgItem(hwnd, id_parts) orelse return 0;
                    const index = win32.SendMessageW(list, win32.CB_GETCURSEL, 0, 0);
                    if (index < 0) return 0;
                    self.show(hwnd, @intCast(index));
                },
                else => return 0,
            }
            return 1;
        },
        win32.WM_DRAWITEM => {
            const self = dialogOf(hwnd) orelse return 0;
            const item: *const win32.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (item.CtlID != id_image) return 0;
            self.draw(item);
            return 1;
        },
        else => return 0,
    }
}

fn dialogOf(hwnd: win32.HWND) ?*Dialog {
    const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The rect a `width` x `height` picture takes in `area`: as large as fits,
/// its shape kept, centred; at least a pixel each way.
pub fn fit(area: win32.RECT, width: i32, height: i32) win32.RECT {
    const aw: i64 = area.right - area.left;
    const ah: i64 = area.bottom - area.top;
    var w = aw;
    var h = @divTrunc(aw * height, width);
    if (h > ah) {
        h = ah;
        w = @divTrunc(ah * width, height);
    }
    w = @max(w, 1);
    h = @max(h, 1);
    const x: i32 = @intCast(area.left + @divTrunc(aw - w, 2));
    const y: i32 = @intCast(area.top + @divTrunc(ah - h, 2));
    return .{ .left = x, .top = y, .right = x + @as(i32, @intCast(w)), .bottom = y + @as(i32, @intCast(h)) };
}

/// `data`, valid UTF-8, as the text preview shows it: each line ended by
/// CRLF, as a multiline EDIT control breaks lines only there, every other
/// code point `unsafeCodepoint` names escaped, and only the first
/// `max_preview_text` bytes, cut where a code point starts, with how many
/// more there are after them.
pub fn previewText(alloc: Allocator, data: []const u8) ![:0]u16 {
    var end = @min(data.len, max_preview_text);
    while (end < data.len and data[end] & 0xC0 == 0x80) end -= 1;

    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(alloc);
    const wide = try clipboard.wideFromUtf8(alloc, data[0..end]);
    defer alloc.free(wide);
    var i: usize = 0;
    while (i < wide.len) : (i += 1) {
        const unit = wide[i];
        switch (unit) {
            '\r' => if (i + 1 < wide.len and wide[i + 1] == '\n') {
                try out.appendSlice(alloc, W("\r\n"));
                i += 1;
            } else try appendEscape(alloc, &out, unit),
            '\n' => try out.appendSlice(alloc, W("\r\n")),
            '\t' => try out.append(alloc, unit),
            // Unit by unit: every such code point is in the BMP and none is
            // a surrogate, so a unit of a surrogate pair is never one.
            else => if (unsafeCodepoint(unit))
                try appendEscape(alloc, &out, unit)
            else
                try out.append(alloc, unit),
        }
    }
    if (end < data.len) {
        var buf: [64]u8 = undefined;
        try appendAscii(alloc, &out, std.fmt.bufPrint(&buf, "\r\n... {d} more bytes", .{data.len - end}) catch unreachable);
    }
    return out.toOwnedSliceSentinel(alloc, 0);
}

/// `text`, bytes from a program, with every code point `unsafeCodepoint`
/// names escaped, and invalid UTF-8 replaced (`clipboard.wideFromUtf8`).
fn appendEscaped(alloc: Allocator, out: *std.ArrayList(u16), text: []const u8) !void {
    const wide = try clipboard.wideFromUtf8(alloc, text);
    defer alloc.free(wide);
    for (wide) |unit| {
        if (unsafeCodepoint(unit)) try appendEscape(alloc, out, unit) else try out.append(alloc, unit);
    }
}

/// `unit` as `\u{202E}`, as a link's preview writes it.
fn appendEscape(alloc: Allocator, out: *std.ArrayList(u16), unit: u16) Allocator.Error!void {
    var buf: ["\\u{FEFF}".len]u8 = undefined;
    try appendAscii(alloc, out, std.fmt.bufPrint(&buf, "\\u{{{X}}}", .{unit}) catch unreachable);
}

fn appendAscii(alloc: Allocator, out: *std.ArrayList(u16), ascii: []const u8) Allocator.Error!void {
    try out.ensureUnusedCapacity(alloc, ascii.len);
    for (ascii) |c| out.appendAssumeCapacity(c);
}

/// A size in bytes, as "1 byte" or "N bytes".
fn size(n: usize) Size {
    return .{ .n = n };
}

const Size = struct {
    n: usize,

    pub fn format(self: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} {s}", .{ self.n, if (self.n == 1) "byte" else "bytes" });
    }
};

test "win32: the Kitty clipboard prompt's template fits, every control on a DWORD" {
    // The largest: a list of parts, what a write leaves out, and the box.
    const parts = [_]Content{
        .{ .mime = "text/plain", .data = "a" },
        .{ .mime = "application/x-a", .data = "b" },
    };
    for ([_]apprt.ClipboardRequestType{ .kitty_read, .kitty_write }) |request| {
        const d: Dialog = .{
            .alloc = std.testing.allocator,
            .request = request,
            .parts = &parts,
            .can_remember = true,
            // The template needs no window.
            .window = undefined,
        };
        var items: [max_items]Item = undefined;
        var question: Question = .{};
        const s = d.spec(&items, &question);
        const want: usize = if (request == .kitty_write) max_items else max_items - 1;
        try std.testing.expectEqual(want, s.items.len);
        var buf: [template_capacity]u16 align(4) = undefined;
        _ = try TitleDialog.build(&buf, s);
        // Deny is the one default button.
        for (s.items) |item| {
            const default = item.class == .button and item.style & 0xF == win32.BS_DEFPUSHBUTTON;
            try std.testing.expectEqual(item.id == win32.IDCANCEL, default);
        }
    }
}

test "win32: a picture fits its place, its shape kept, centred" {
    const area: win32.RECT = .{ .left = 10, .top = 20, .right = 410, .bottom = 220 };
    // Wider than the place: as wide, centred down.
    try std.testing.expectEqual(win32.RECT{ .left = 10, .top = 70, .right = 410, .bottom = 170 }, fit(area, 800, 200));
    // Taller: as tall, centred across.
    try std.testing.expectEqual(win32.RECT{ .left = 160, .top = 20, .right = 260, .bottom = 220 }, fit(area, 100, 200));
    // Smaller: made as large as fits, as GTK's `contain` does.
    try std.testing.expectEqual(win32.RECT{ .left = 110, .top = 20, .right = 310, .bottom = 220 }, fit(area, 2, 2));
    // A sliver keeps a pixel.
    try std.testing.expectEqual(win32.RECT{ .left = 10, .top = 119, .right = 410, .bottom = 120 }, fit(area, 100000, 1));
}

test "win32: the text preview escapes what could hide or add lines, ends lines with CRLF, and is cut" {
    const alloc = std.testing.allocator;
    const Case = struct { []const u8, []const u16 };
    for ([_]Case{
        .{ "a\u{202E}b", W("a\\u{202E}b") },
        .{ "a\nb\r\nc\rd\te", W("a\r\nb\r\nc\\u{D}d\te") },
        .{ "\u{1B}[31m\u{200B}\u{FEFF}", W("\\u{1B}[31m\\u{200B}\\u{FEFF}") },
        .{ "\u{1F600}\u{E9}", W("\u{1F600}\u{E9}") },
        .{ "", W("") },
    }) |c| {
        const got = try previewText(alloc, c[0]);
        defer alloc.free(got);
        try std.testing.expectEqualSlices(u16, c[1], got);
    }

    // Cut after max_preview_text bytes, where a code point starts: the
    // last one, two bytes, would end a byte past the limit.
    const long = try alloc.alloc(u8, max_preview_text + 9);
    defer alloc.free(long);
    @memset(long, 'x');
    @memcpy(long[max_preview_text - 1 ..][0..2], "\u{E9}");
    const got = try previewText(alloc, long);
    defer alloc.free(got);
    const tail = W("\r\n... 10 more bytes");
    try std.testing.expectEqual(max_preview_text - 1 + tail.len, got.len);
    try std.testing.expect(std.mem.endsWith(u16, got, W("xx") ++ tail));
}
