const std = @import("std");
const builtin = @import("builtin");
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

/// What `writeClipboard` puts on the clipboard: text, HTML, or both, each
/// UTF-8.
pub const Contents = struct {
    text: ?[]const u8 = null,
    html: ?[]const u8 = null,
};

/// For tests: a representation that cannot be written (`TestFail`).
pub var test_fails: if (builtin.is_test) ?TestFail else void = if (builtin.is_test) null else {};

/// Where `test_fails` fails a representation of `kind`: `make` as
/// GlobalLock failing on its memory, after the allocation, so the free on
/// that path runs; `set` as SetClipboardData refusing it.
pub const TestFail = struct { kind: Block.Kind, at: enum { make, set } };

/// For tests: blocks of memory made and neither freed nor taken by the
/// clipboard. Zero after every write: each block is freed or handed over,
/// and only once.
pub var test_held: if (builtin.is_test) isize else void = if (builtin.is_test) 0 else {};

/// One representation, made and ready for SetClipboardData.
const Block = struct {
    const Kind = enum { text, html };
    kind: Kind,
    format: win32.UINT,
    /// Ours until SetClipboardData takes it; null once it has.
    mem: ?win32.HGLOBAL,
};

/// Replace the clipboard's contents with `contents`: the HTML as CF_HTML
/// ("HTML Format"), then the text as CF_UNICODETEXT, most descriptive
/// first as Windows asks, since a reader takes the first format it knows
/// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations).
/// Both go in one opening of the clipboard, so no reader sees one without
/// the other.
///
/// Text that cannot be made or handed over fails the write, and no HTML is
/// left without it: Notepad, and this runtime's own paste, which reads only
/// CF_UNICODETEXT, would find nothing. HTML that cannot be is logged and
/// left out, and the text is written alone, as GTK falls back to the text.
/// The write fails when no copy can be had: the core must not believe a
/// copy landed when it did not. A write that fails before the clipboard is
/// emptied leaves it as it was; one refused after leaves it empty.
pub fn writeClipboard(hwnd: win32.HWND, contents: Contents) App.Error!void {
    // Both are made before the clipboard is opened, so the process-wide
    // clipboard lock is held only to hand them over: the text first, so a
    // write that cannot have its text makes no HTML.
    var text: ?Block = null;
    var html: ?Block = null;
    // SetClipboardData takes ownership only on success (`setBlock` then
    // nulls `mem`); freeing a block after that would be a double free the
    // moment anything pastes.
    defer for ([_]?Block{ text, html }) |block| if (block) |b| if (b.mem) |mem| free(mem);

    if (contents.text) |t| text = textBlock(t) orelse return App.Error.Win32CallFailed;
    if (contents.html) |h| html = htmlBlock(h);
    if (text == null and html == null) return App.Error.Win32CallFailed;

    if (!win32.OpenClipboard(hwnd).toBool()) {
        log.warn("OpenClipboard failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    defer _ = win32.CloseClipboard();

    if (!win32.EmptyClipboard().toBool()) {
        log.warn("EmptyClipboard failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }

    const html_set = if (html) |*b| setBlock(b) else false;
    if (text) |*b| if (!setBlock(b)) {
        // Not the HTML without its text.
        _ = win32.EmptyClipboard();
        return App.Error.Win32CallFailed;
    };
    if (text == null and !html_set) return App.Error.Win32CallFailed;
}

/// Hand `b` to the open clipboard, which then owns its memory; false,
/// logged, if it is refused.
fn setBlock(b: *Block) bool {
    if (builtin.is_test) if (test_fails) |f| if (f.kind == b.kind and f.at == .set) return false;
    if (win32.SetClipboardData(b.format, b.mem) == null) {
        log.warn("SetClipboardData failed kind={t} err={}", .{ b.kind, win32.GetLastError() });
        return false;
    }
    b.mem = null;
    if (builtin.is_test) test_held -= 1;
    return true;
}

/// Free memory the clipboard has not taken.
fn free(mem: win32.HGLOBAL) void {
    _ = win32.GlobalFree(mem);
    if (builtin.is_test) test_held -= 1;
}

/// `text` as CF_UNICODETEXT; null, logged, if it cannot be made. Bytes
/// that are not valid UTF-8 become U+FFFD rather than failing the write:
/// an OSC 52 payload is whatever the program sent, and macOS stores it as
/// given.
fn textBlock(text: []const u8) ?Block {
    const len = std.math.cast(c_int, text.len) orelse {
        log.warn("clipboard text too long len={d}", .{text.len});
        return null;
    };

    // Without MB_ERR_INVALID_CHARS, MultiByteToWideChar replaces invalid
    // sequences with U+FFFD. std has no lossy UTF-8 to UTF-16 conversion.
    // A zero length is an error to MultiByteToWideChar, hence the guard.
    const units: usize = if (len == 0) 0 else units: {
        const n = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, len, null, 0);
        if (n == 0) {
            log.warn("MultiByteToWideChar failed err={}", .{win32.GetLastError()});
            return null;
        }
        break :units @intCast(n);
    };

    const block = lockedMemory(.text, (units + 1) * @sizeOf(u16)) orelse return null;
    {
        defer _ = win32.GlobalUnlock(block.mem);

        const dst: [*]u16 = @ptrCast(@alignCast(block.ptr));
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
    return .{ .kind = .text, .format = win32.CF_UNICODETEXT, .mem = block.mem };
}

/// `html` as CF_HTML; null, logged, if it cannot be made.
fn htmlBlock(html: []const u8) ?Block {
    const format = htmlFormat() orelse return null;
    const len = cfHtmlLen(html.len) orelse {
        log.warn("clipboard HTML too long len={d}", .{html.len});
        return null;
    };

    // A NUL after the data, for readers that look for one.
    const block = lockedMemory(.html, len + 1) orelse return null;
    {
        defer _ = win32.GlobalUnlock(block.mem);
        const dst: [*]u8 = @ptrCast(block.ptr);
        cfHtml(dst[0..len], html);
        dst[len] = 0;
    }
    return .{ .kind = .html, .format = format, .mem = block.mem };
}

/// The id of the "HTML Format" clipboard format; null, logged, if it
/// cannot be registered.
fn htmlFormat() ?win32.UINT {
    // Every process that registers the same name gets the same id.
    const format = win32.RegisterClipboardFormatW(L("HTML Format"));
    if (format == 0) {
        log.warn("RegisterClipboardFormatW failed err={}", .{win32.GetLastError()});
        return null;
    }
    return format;
}

/// `bytes` of movable memory for a `kind` block, as SetClipboardData
/// takes, locked for the caller to fill and unlock; null, logged, if it
/// cannot be had.
fn lockedMemory(kind: Block.Kind, bytes: usize) ?struct { mem: win32.HGLOBAL, ptr: *anyopaque } {
    const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, bytes) orelse {
        log.warn("GlobalAlloc failed kind={t} bytes={d} err={}", .{ kind, bytes, win32.GetLastError() });
        return null;
    };
    if (builtin.is_test) test_held += 1;
    const ptr = lock: {
        if (builtin.is_test) if (test_fails) |f| if (f.kind == kind and f.at == .make) break :lock null;
        break :lock win32.GlobalLock(mem);
    } orelse {
        log.warn("GlobalLock failed kind={t} err={}", .{ kind, win32.GetLastError() });
        free(mem);
        return null;
    };
    return .{ .mem = mem, .ptr = ptr };
}

// CF_HTML (https://learn.microsoft.com/en-us/windows/win32/dataxchg/html-clipboard-format):
// a header of byte offsets from the start of the data, then a minimal
// document holding the fragment between the comments that mark it. The
// format is always UTF-8 and allows offsets padded with zeros, so each is
// written in ten digits and the header's length is known before them.
const cf_html_header = "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\n" ++
    "StartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n";
const cf_html_header_len = ("Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\n" ++
    "StartFragment:0000000000\r\nEndFragment:0000000000\r\n").len;
const cf_html_prefix = "<html>\r\n<body>\r\n<!--StartFragment-->";
const cf_html_suffix = "<!--EndFragment-->\r\n</body>\r\n</html>";

/// The length of CF_HTML for a fragment of `len` bytes; null if its last
/// offset would not fit ten digits.
fn cfHtmlLen(len: usize) ?usize {
    const total = std.math.add(usize, len, cf_html_header_len + cf_html_prefix.len + cf_html_suffix.len) catch
        return null;
    return if (total <= 9_999_999_999) total else null;
}

/// Write CF_HTML for `fragment` into `out`, `cfHtmlLen(fragment.len)`
/// bytes long.
fn cfHtml(out: []u8, fragment: []const u8) void {
    const start_html = cf_html_header_len;
    const start_fragment = start_html + cf_html_prefix.len;
    const end_fragment = start_fragment + fragment.len;
    const end_html = end_fragment + cf_html_suffix.len;
    std.debug.assert(out.len == end_html);

    const header = std.fmt.bufPrint(out, cf_html_header, .{
        start_html,
        end_html,
        start_fragment,
        end_fragment,
    }) catch unreachable;
    std.debug.assert(header.len == start_html);
    @memcpy(out[start_html..start_fragment], cf_html_prefix);
    @memcpy(out[start_fragment..end_fragment], fragment);
    @memcpy(out[end_fragment..end_html], cf_html_suffix);
}

/// For tests: the CF_HTML on the clipboard, as written, or null if it
/// holds none. The app never reads HTML.
pub fn readClipboardHtml(alloc: Allocator, hwnd: win32.HWND) !?[]u8 {
    const format = htmlFormat() orelse return error.TestUnexpectedResult;
    if (!win32.IsClipboardFormatAvailable(format).toBool()) return null;
    if (!win32.OpenClipboard(hwnd).toBool()) return error.TestUnexpectedResult;
    defer _ = win32.CloseClipboard();
    const mem = win32.GetClipboardData(format) orelse return error.TestUnexpectedResult;
    const raw = win32.GlobalLock(mem) orelse return error.TestUnexpectedResult;
    defer _ = win32.GlobalUnlock(mem);
    const bytes: [*]const u8 = @ptrCast(raw);
    const block = bytes[0..win32.GlobalSize(mem)];
    return try alloc.dupe(u8, block[0 .. std.mem.indexOfScalar(u8, block, 0) orelse block.len]);
}

/// For tests: the fragment of CF_HTML `data`, found as a reader finds it,
/// from the StartFragment and EndFragment offsets; null if they are
/// missing or out of the data.
pub fn cfHtmlFragment(data: []const u8) ?[]const u8 {
    const start = cfHtmlOffset(data, "StartFragment:") orelse return null;
    const end = cfHtmlOffset(data, "EndFragment:") orelse return null;
    if (start > end or end > data.len) return null;
    return data[start..end];
}

fn cfHtmlOffset(data: []const u8, key: []const u8) ?usize {
    const at = std.mem.indexOf(u8, data, key) orelse return null;
    const digits = data[at + key.len ..];
    const len = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
    return std.fmt.parseInt(usize, digits[0..len], 10) catch null;
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
/// U+FFFD instead of failing, as the clipboard's text does. The caller frees
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

/// For tests: a window to own the clipboard. SetClipboardData fails for a
/// clipboard opened without an owner window; a message-only STATIC window
/// is enough.
fn testOwner() !win32.HWND {
    return win32.CreateWindowExW(
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
    ) orelse error.TestUnexpectedResult;
}

/// For tests: the clipboard holds `text` as text (none if null) and
/// `fragment` as the fragment of its HTML (none if null), the HTML's data
/// ending at its NUL where EndHTML says it ends; and the writes before
/// left no memory held (`test_held`).
pub fn expectClipboard(hwnd: win32.HWND, text: ?[]const u8, fragment: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(0, test_held);
    const got_text = try readClipboardText(alloc, hwnd);
    defer if (got_text) |t| alloc.free(t);
    if (text) |want| {
        try std.testing.expectEqualStrings(want, got_text orelse return error.TestUnexpectedResult);
    } else try std.testing.expect(got_text == null);

    const got_html = try readClipboardHtml(alloc, hwnd);
    defer if (got_html) |h| alloc.free(h);
    if (fragment) |want| {
        const html = got_html orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want, cfHtmlFragment(html) orelse return error.TestUnexpectedResult);
        try std.testing.expectEqual(html.len, cfHtmlOffset(html, "EndHTML:") orelse return error.TestUnexpectedResult);
    } else try std.testing.expect(got_html == null);
}

test "win32: clipboard writes read back, with invalid UTF-8 replaced" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);

    // Put back whatever text the clipboard held. Other formats are lost,
    // which is acceptable for a test.
    const saved = try readClipboardText(alloc, hwnd);
    defer if (saved) |text| {
        writeClipboard(hwnd, .{ .text = text }) catch {};
        alloc.free(text);
    };

    const Case = struct { text: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .text = "", .want = "" },
        .{ .text = "café \u{1F600}", .want = "café \u{1F600}" },
        // Latin-1 from a legacy program, as OSC 52 can deliver it.
        .{ .text = "abc\xe9", .want = "abc\u{FFFD}" },
    };
    for (cases) |c| {
        try writeClipboard(hwnd, .{ .text = c.text });
        const got = (try readClipboardText(alloc, hwnd)) orelse
            return error.TestUnexpectedResult;
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "win32: the clipboard takes HTML before text, and each write replaces both" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try readClipboardText(alloc, hwnd);
    defer if (saved) |text| {
        writeClipboard(hwnd, .{ .text = text }) catch {};
        alloc.free(text);
    };

    try writeClipboard(hwnd, .{ .text = "plain café", .html = "<div>rich café</div>" });
    try expectClipboard(hwnd, "plain café", "<div>rich café</div>");

    // Placed most descriptive first: a reader that takes the first format
    // it knows takes the HTML.
    {
        const html = htmlFormat() orelse return error.TestUnexpectedResult;
        if (!win32.OpenClipboard(hwnd).toBool()) return error.TestUnexpectedResult;
        defer _ = win32.CloseClipboard();
        var format: win32.UINT = 0;
        const first = while (true) {
            format = win32.EnumClipboardFormats(format);
            if (format == 0 or format == html or format == win32.CF_UNICODETEXT) break format;
        };
        try std.testing.expectEqual(html, first);
    }

    // The HTML alone, as a `copy_to_clipboard:html` writes it: the text
    // before it goes.
    try writeClipboard(hwnd, .{ .html = "<div>only</div>" });
    try expectClipboard(hwnd, null, "<div>only</div>");

    // The text alone: the HTML before it goes.
    try writeClipboard(hwnd, .{ .text = "text" });
    try expectClipboard(hwnd, "text", null);
}

test "win32: text that cannot be written fails the write, and HTML that cannot be leaves the text alone" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try readClipboardText(alloc, hwnd);
    defer if (saved) |text| {
        writeClipboard(hwnd, .{ .text = text }) catch {};
        alloc.free(text);
    };
    defer test_fails = null;

    // A failed write that could not make its memory leaves the clipboard
    // as it was; one refused is refused after the clipboard emptied.
    const failed = struct {
        fn expect(owner: win32.HWND, fail: TestFail) !void {
            switch (fail.at) {
                .make => try expectClipboard(owner, "kept", null),
                .set => try expectClipboard(owner, null, null),
            }
        }
    }.expect;

    for ([_]TestFail{
        .{ .kind = .text, .at = .make },
        .{ .kind = .text, .at = .set },
        .{ .kind = .html, .at = .make },
        .{ .kind = .html, .at = .set },
    }) |fail| {
        // With both: no HTML without its text, but the text without its
        // HTML.
        try writeClipboard(hwnd, .{ .text = "kept" });
        test_fails = fail;
        const both = writeClipboard(hwnd, .{ .text = "t", .html = "<b>h</b>" });
        test_fails = null;
        switch (fail.kind) {
            .text => {
                try std.testing.expectError(App.Error.Win32CallFailed, both);
                try failed(hwnd, fail);
            },
            .html => {
                try both;
                try expectClipboard(hwnd, "t", null);
            },
        }

        // Alone, it fails.
        try writeClipboard(hwnd, .{ .text = "kept" });
        test_fails = fail;
        const only: Contents = switch (fail.kind) {
            .text => .{ .text = "t" },
            .html => .{ .html = "<b>h</b>" },
        };
        try std.testing.expectError(App.Error.Win32CallFailed, writeClipboard(hwnd, only));
        test_fails = null;
        try failed(hwnd, fail);
    }
}

test "win32: a clipboard another thread holds open fails the write, which frees what it made" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try readClipboardText(alloc, hwnd);
    defer if (saved) |text| {
        writeClipboard(hwnd, .{ .text = text }) catch {};
        alloc.free(text);
    };
    try writeClipboard(hwnd, .{ .text = "kept" });

    // OpenClipboard "fails if another window has the clipboard open"
    // (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard).
    const Holder = struct {
        const State = enum(u8) { start, open, refused, release };
        var state: std.atomic.Value(State) = .init(.start);
        fn hold() void {
            if (!win32.OpenClipboard(null).toBool()) return state.store(.refused, .release);
            defer _ = win32.CloseClipboard();
            state.store(.open, .release);
            while (state.load(.acquire) != .release) win32.Sleep(1);
        }
    };
    Holder.state.store(.start, .release);
    const thread = try std.Thread.spawn(.{}, Holder.hold, .{});
    {
        defer thread.join();
        defer Holder.state.store(.release, .release);
        while (Holder.state.load(.acquire) == .start) win32.Sleep(1);
        try std.testing.expectEqual(.open, Holder.state.load(.acquire));

        try std.testing.expectError(
            App.Error.Win32CallFailed,
            writeClipboard(hwnd, .{ .text = "t", .html = "<b>h</b>" }),
        );
        try std.testing.expectEqual(0, test_held);
    }
    try expectClipboard(hwnd, "kept", null);
}

test "win32: CF_HTML's offsets find the fragment, inside the document its markers close" {
    const alloc = std.testing.allocator;
    const fragments = [_][]const u8{
        "",
        "<div style=\"font-family: monospace; white-space: pre;\">hello</div>",
        // The core writes entities, but the offsets count bytes of UTF-8.
        "<div>café \u{65E5} \u{1F600}</div>",
    };
    for (fragments) |fragment| {
        const data = try alloc.alloc(u8, cfHtmlLen(fragment.len) orelse return error.TestUnexpectedResult);
        defer alloc.free(data);
        cfHtml(data, fragment);

        try std.testing.expectEqualStrings(fragment, cfHtmlFragment(data) orelse return error.TestUnexpectedResult);
        const start_html = cfHtmlOffset(data, "StartHTML:") orelse return error.TestUnexpectedResult;
        const end_html = cfHtmlOffset(data, "EndHTML:") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(data.len, end_html);
        try std.testing.expect(std.mem.startsWith(u8, data[start_html..], "<html>"));
        try std.testing.expect(std.mem.endsWith(u8, data, "</html>"));
        const start = cfHtmlOffset(data, "StartFragment:").?;
        const end = cfHtmlOffset(data, "EndFragment:").?;
        try std.testing.expect(std.mem.endsWith(u8, data[0..start], "<!--StartFragment-->"));
        try std.testing.expect(std.mem.startsWith(u8, data[end..], "<!--EndFragment-->"));
        try std.testing.expect(std.mem.startsWith(u8, data, "Version:0.9\r\n"));
    }

    // The last offset must fit its ten digits.
    const most = 9_999_999_999 - (cf_html_header_len + cf_html_prefix.len + cf_html_suffix.len);
    try std.testing.expectEqual(9_999_999_999, cfHtmlLen(most));
    try std.testing.expect(cfHtmlLen(most + 1) == null);
    try std.testing.expect(cfHtmlLen(std.math.maxInt(usize)) == null);
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
        .{ .text = "abc\xe9", .want = &.{ 'a', 'b', 'c', 0xFFFD } },
    };
    for (cases) |c| {
        const got = try wideFromUtf8(alloc, c.text);
        defer alloc.free(got);
        try std.testing.expectEqualSlices(u16, c.want, got);
        try std.testing.expectEqual(0, got[got.len]);
    }
}
