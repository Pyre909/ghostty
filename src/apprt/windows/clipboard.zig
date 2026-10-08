const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;
const ConfirmDefault = @import("dialog.zig").ConfirmDefault;

const log = std.log.scoped(.win32);

/// The MIME type we serve and accept for clipboard text. The core's
/// `terminal.clipboard.isTextMime` accepts this spelling.
pub const text_mime = "text/plain;charset=utf-8";

/// Read CF_UNICODETEXT as UTF-8. Returns null when the clipboard holds no
/// text. The caller owns the result.
pub fn readClipboardText(alloc: Allocator, hwnd: win32.HWND) !?[]u8 {
    if (!win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT).toBool()) return null;

    // OpenClipboard takes a process-wide lock; the defer guarantees no path
    // out of this function leaves it held.
    if (!win32.OpenClipboard(hwnd).toBool()) {
        log.warn("failed to open the clipboard for reading err={}", .{win32.GetLastError()});
        return null;
    }
    defer _ = win32.CloseClipboard();

    // The handle belongs to the clipboard, not to us: it must not be freed,
    // and it is only valid until CloseClipboard.
    const mem = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;
    const raw = win32.GlobalLock(mem) orelse return null;
    defer _ = win32.GlobalUnlock(mem);

    // Another process wrote this block, so only its size bounds it.
    const units: [*]const u16 = @ptrCast(@alignCast(raw));
    return try utf8FromClipboard(alloc, units[0 .. win32.GlobalSize(mem) / @sizeOf(u16)]);
}

/// Replace the clipboard's contents with `text` as CF_UNICODETEXT.
///
/// Bytes that are not valid UTF-8 become U+FFFD rather than failing the
/// write: an OSC 52 payload is whatever the program sent, and macOS stores it
/// as given.
pub fn writeClipboardText(hwnd: win32.HWND, text: []const u8) App.Error!void {
    const len = std.math.cast(c_int, text.len) orelse {
        log.warn("clipboard text too long len={d}", .{text.len});
        return App.Error.Win32CallFailed;
    };

    // Without MB_ERR_INVALID_CHARS, MultiByteToWideChar replaces invalid
    // sequences with U+FFFD. std has no lossy UTF-8 to UTF-16 conversion.
    // A zero length is an error to MultiByteToWideChar, hence the guard.
    const units: usize = if (len == 0) 0 else units: {
        const n = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, null, 0);
        if (n == 0) {
            log.warn("MultiByteToWideChar failed err={}", .{win32.GetLastError()});
            return App.Error.Win32CallFailed;
        }
        break :units @intCast(n);
    };

    // The buffer is built before the clipboard is opened, so the only failure
    // after EmptyClipboard is SetClipboardData itself, and the process-wide
    // clipboard lock is held for as short a time as possible.
    const bytes = (units + 1) * @sizeOf(u16);
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse {
        log.warn("GlobalAlloc failed bytes={d} err={}", .{ bytes, win32.GetLastError() });
        return App.Error.Win32CallFailed;
    };
    // SetClipboardData takes ownership on success; freeing it after that
    // would be a double free the moment anything pastes.
    errdefer _ = win32.GlobalFree(mem);

    {
        const raw = win32.GlobalLock(mem) orelse {
            log.warn("GlobalLock failed err={}", .{win32.GetLastError()});
            return App.Error.Win32CallFailed;
        };
        defer _ = win32.GlobalUnlock(mem);

        const dst: [*]u16 = @ptrCast(@alignCast(raw));
        if (units > 0) {
            // The same input as the measuring call, so the same count.
            const n = win32.MultiByteToWideChar(
                win32.CP_UTF8,
                0,
                text.ptr,
                len,
                dst,
                @intCast(units),
            );
            std.debug.assert(n == units);
        }
        dst[units] = 0;
    }

    if (!win32.OpenClipboard(hwnd).toBool()) {
        log.warn("OpenClipboard failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    defer _ = win32.CloseClipboard();

    if (!win32.EmptyClipboard().toBool()) {
        log.warn("EmptyClipboard failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }

    if (win32.SetClipboardData(win32.CF_UNICODETEXT, mem) == null) {
        log.warn("SetClipboardData failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }
}

/// UTF-8 for a CF_UNICODETEXT block. The text ends at the first NUL, or at
/// the end of the block: Windows does not enforce the terminator, so an
/// owner that leaves it out must not make us read past the block. The text
/// is WTF-16, so an unpaired surrogate becomes U+FFFD, as
/// WideCharToMultiByte does, instead of failing the whole paste.
fn utf8FromClipboard(alloc: Allocator, block: []const u16) Allocator.Error![]u8 {
    return try utf8FromWide(alloc, block[0 .. std.mem.indexOfScalar(u16, block, 0) orelse block.len]);
}

/// UTF-8 for text from Windows, which is WTF-16: an unpaired surrogate
/// becomes U+FFFD, as WideCharToMultiByte does, instead of failing. The
/// caller frees the result.
pub fn utf8FromWide(alloc: Allocator, units: []const u16) Allocator.Error![]u8 {
    const buf = try std.unicode.wtf16LeToWtf8Alloc(alloc, units);
    // In place: a surrogate's WTF-8 and U+FFFD are both three bytes, and
    // wtf16LeToWtf8 never produces invalid WTF-8.
    std.unicode.wtf8ToUtf8Lossy(buf, buf) catch unreachable;
    return buf;
}

/// NUL-terminated UTF-16 for `text`: each invalid UTF-8 sequence becomes
/// U+FFFD instead of failing, as in writeClipboardText. The caller frees
/// the result.
pub fn wideFromUtf8(alloc: Allocator, text: []const u8) (Allocator.Error || App.Error)![:0]u16 {
    // A zero length is an error to MultiByteToWideChar.
    if (text.len == 0) return try alloc.allocSentinel(u16, 0, 0);
    const len = std.math.cast(c_int, text.len) orelse {
        log.warn("text too long to convert len={d}", .{text.len});
        return App.Error.Win32CallFailed;
    };

    // Without MB_ERR_INVALID_CHARS, MultiByteToWideChar replaces invalid
    // sequences with U+FFFD. std has no lossy UTF-8 to UTF-16 conversion.
    const n = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, null, 0);
    if (n == 0) {
        log.warn("MultiByteToWideChar failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    const wide = try alloc.allocSentinel(u16, @intCast(n), 0);
    // The same input as the measuring call, so the same count.
    const written = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, wide.ptr, n);
    std.debug.assert(written == n);
    return wide;
}

/// The text of the prompt for a clipboard read the core would not complete
/// unasked. A paste puts the text into the terminal; a read hands the
/// clipboard to whatever program is running, which can send it anywhere.
/// The two must not share wording, or the user approves the second believing
/// it is the first. The GTK and macOS confirmation dialogs word them apart
/// too.
pub fn clipboardReadPrompt(state: apprt.ClipboardRequestType) win32.LPCWSTR {
    return switch (state) {
        .paste => L("Pasting this text could be unsafe. Paste anyway?"),
        .osc_52_read, .kitty_read => L("An application wants to read the clipboard. Allow it?"),

        // Writes go to setClipboard and lists never need consent.
        .osc_52_write, .kitty_write, .list => unreachable,
    };
}

test "win32: clipboard reads are not worded as pastes and default to Cancel" {
    const paste = std.mem.span(clipboardReadPrompt(.paste));
    for ([_]apprt.ClipboardRequestType{ .osc_52_read, .kitty_read }) |state| {
        const read = std.mem.span(clipboardReadPrompt(state));
        try std.testing.expect(!std.mem.eql(u16, paste, read));
        try std.testing.expect(std.mem.indexOf(
            u16,
            read,
            std.unicode.utf8ToUtf16LeStringLiteral("aste"),
        ) == null);
    }

    try std.testing.expectEqual(
        win32.MB_DEFBUTTON2,
        ConfirmDefault.cancel.style() & win32.MB_DEFMASK,
    );
}

test "win32: clipboard text stops at the block and survives bad surrogates" {
    const alloc = std.testing.allocator;
    const Case = struct { block: []const u16, want: []const u8 };
    const cases = [_]Case{
        .{ .block = &.{}, .want = "" },
        .{ .block = &.{ 'a', 'b', 0 }, .want = "ab" },
        // Text after the terminator, such as the rest of an oversized block,
        // is not part of the text.
        .{ .block = &.{ 'a', 0, 'b', 'c' }, .want = "a" },
        .{ .block = &.{ 0xD83D, 0xDE00, 0 }, .want = "\u{1F600}" },
        .{ .block = &.{ 'a', 'b', 'c', 0xD83D, 0 }, .want = "abc\u{FFFD}" },
        .{ .block = &.{ 0xDE00, 'a' }, .want = "\u{FFFD}a" },
        .{ .block = &.{ 0xD83D, 0xD83D, 0xDE00 }, .want = "\u{FFFD}\u{1F600}" },
    };
    for (cases) |c| {
        const got = try utf8FromClipboard(alloc, c.block);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }

    // No terminator: the block's end is the text's end, even when the
    // memory after it holds more text.
    const backing = [_]u16{ 'x', 'y', 'z', 'q' };
    const got = try utf8FromClipboard(alloc, backing[0..2]);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("xy", got);
}

test "win32: clipboard writes read back, with invalid UTF-8 replaced" {
    const alloc = std.testing.allocator;

    // SetClipboardData fails for a clipboard opened without an owner window,
    // so the test needs one. A message-only STATIC window is enough.
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

    // Put back whatever text the clipboard held. Other formats are lost,
    // which is acceptable for a test.
    const saved = try readClipboardText(alloc, hwnd);
    defer if (saved) |text| {
        writeClipboardText(hwnd, text) catch {};
        alloc.free(text);
    };

    const Case = struct { text: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .text = "", .want = "" },
        .{ .text = "caf\u{e9} \u{1F600}", .want = "caf\u{e9} \u{1F600}" },
        // Latin-1 from a legacy program, as OSC 52 can deliver it.
        .{ .text = "caf\xe9", .want = "caf\u{FFFD}" },
    };
    for (cases) |c| {
        try writeClipboardText(hwnd, c.text);
        const got = (try readClipboardText(alloc, hwnd)) orelse
            return error.TestUnexpectedResult;
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "win32: wide strings become UTF-8 with unpaired surrogates replaced" {
    const alloc = std.testing.allocator;
    const Case = struct { units: []const u16, want: []const u8 };
    const cases = [_]Case{
        .{ .units = &.{}, .want = "" },
        .{ .units = &.{ 0x65E5, 0x672C }, .want = "\u{65E5}\u{672C}" },
        .{ .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}" },
        .{ .units = &.{ 'a', 0x000A, 'b' }, .want = "a\nb" },
        .{ .units = &.{ 'a', 0xD83D }, .want = "a\u{FFFD}" },
        .{ .units = &.{ 0xDE00, 'a' }, .want = "\u{FFFD}a" },
        .{ .units = &.{ 0xD83D, 'a', 0xDE00 }, .want = "\u{FFFD}a\u{FFFD}" },
        .{ .units = &.{ 0xD83D, 0xD83D, 0xDE00 }, .want = "\u{FFFD}\u{1F600}" },
    };
    for (cases) |c| {
        const got = try utf8FromWide(alloc, c.units);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "win32: utf-8 becomes wide text with invalid sequences replaced" {
    const alloc = std.testing.allocator;
    const Case = struct { text: []const u8, want: []const u16 };
    const cases = [_]Case{
        .{ .text = "", .want = &.{} },
        .{ .text = "\u{65E5}\u{1F600}", .want = &.{ 0x65E5, 0xD83D, 0xDE00 } },
        // Latin-1, as from a config saved in a legacy code page.
        .{ .text = "caf\xe9", .want = &.{ 'c', 'a', 'f', 0xFFFD } },
    };
    for (cases) |c| {
        const got = try wideFromUtf8(alloc, c.text);
        defer alloc.free(got);
        try std.testing.expectEqualSlices(u16, c.want, got);
        try std.testing.expectEqual(0, got[got.len]);
    }
}
