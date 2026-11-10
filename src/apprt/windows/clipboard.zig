const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const wuffs = @import("wuffs");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;
const ConfirmDefault = @import("dialog.zig").ConfirmDefault;
const Question = @import("dialog.zig").Question;
const drop = @import("drop.zig");

const log = std.log.scoped(.win32);

/// The most a program may write in one Kitty clipboard transaction. A PNG
/// whose pixels would take as much gets no DIB beside it.
const max_write_size = terminal.kitty.clipboard.max_write_size;

/// The MIME type we serve and accept for clipboard text. The core's
/// `terminal.clipboard.isTextMime` accepts this spelling.
pub const text_mime = "text/plain;charset=utf-8";

/// How many times `open` tries a clipboard another program holds, and the
/// wait asked for between tries. Sleep counts in timer ticks, so the wait
/// is longer than asked: on Windows 11 at the default timer resolution,
/// Sleep(5) took 13 to 19 ms, 16.6 ms in the middle of 40. A clipboard
/// held throughout therefore holds up the thread for about 65 ms over the
/// four waits.
const open_tries = 5;
const open_wait_ms = 5;

/// For tests: run in place of `open`'s wait between tries.
pub var test_busy: if (builtin.is_test) ?*const fn () void else void = if (builtin.is_test) null else {};

/// OpenClipboard, tried again while another program holds the clipboard.
/// Windows' clipboard history service (cbdhsvc) and clipboard sync tools
/// (rdpclip, Parallels' prl_cc) each open it for a moment after every
/// change, so a read or write that soon after a change can find it held,
/// and OpenClipboard fails with ERROR_ACCESS_DENIED. Chromium also tries
/// five times, 5 ms apart (ScopedClipboard::Acquire in
/// ui/base/clipboard/clipboard_win.cc). No wait follows the last try, so
/// the error it leaves is OpenClipboard's.
///
/// One holder cannot be outwaited. A program that empties a clipboard this
/// process owns sends WM_DESTROYCLIPBOARD to the owner, a window of this
/// thread, and keeps the clipboard open until it is answered, which Sleep
/// does not do. The tries then fail, and a later read or write finds the
/// clipboard free; answering sent messages here instead would run window
/// procedures in the middle of a read or write.
fn open(hwnd: ?win32.HWND) bool {
    for (0..open_tries) |tried| {
        if (win32.OpenClipboard(hwnd).toBool()) return true;
        if (tried + 1 == open_tries) break;
        if (builtin.is_test) if (test_busy) |busy| {
            busy();
            continue;
        };
        win32.Sleep(open_wait_ms);
    }
    return false;
}

/// Read CF_UNICODETEXT as UTF-8. Returns null when the clipboard holds no
/// text. The caller owns the result.
pub fn readClipboardText(alloc: Allocator, hwnd: win32.HWND) !?[]u8 {
    if (!win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT).toBool()) return null;

    // OpenClipboard takes a process-wide lock; the defer guarantees no path
    // out of this function leaves it held.
    if (!open(hwnd)) {
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

/// A clipboard format this runtime writes, by the MIME type a program names
/// it with (`formatOf`).
pub const Format = enum { text, html, png, bmp, rtf };

/// The format `mime` is written as; null if Windows has none this runtime
/// writes. Text takes every name the core treats as text. Writing other
/// types under their MIME names would register each name for the rest of
/// the session, in an atom table every program shares
/// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/about-atom-tables).
pub fn formatOf(mime: []const u8) ?Format {
    if (terminal.clipboard.isTextMime(mime)) return .text;
    const names = [_]struct { []const u8, Format }{
        .{ "text/html", .html },
        .{ "image/png", .png },
        .{ "image/bmp", .bmp },
        .{ "text/rtf", .rtf },
    };
    for (names) |n| if (std.mem.eql(u8, mime, n[0])) return n[1];
    return null;
}

/// One representation to write: data as the program sent it, in `format`.
pub const Rep = struct { format: Format, data: []const u8 };

/// The representations of one write, at most one for each format, in the
/// order they were given. Made only by `of` and `text`, which keep that.
pub const Reps = struct {
    buf: [std.enums.values(Format).len]Rep = undefined,
    len: usize = 0,

    /// The first representation of each format in `contents`, in their
    /// order; a type with no format is logged and left out. `text_only`
    /// keeps the text alone, as GTK and macOS write after their prompts.
    pub fn of(contents: []const apprt.ClipboardContent, text_only: bool) Reps {
        var reps: Reps = .{};
        var seen: std.EnumSet(Format) = .empty;
        for (contents) |c| {
            const format = formatOf(c.mime) orelse {
                log.info("clipboard type left out, Windows has no format for it mime={f}", .{
                    std.zig.fmtString(c.mime),
                });
                continue;
            };
            if (seen.contains(format)) continue;
            seen.insert(format);
            if (text_only and format != .text) continue;
            reps.buf[reps.len] = .{ .format = format, .data = c.data };
            reps.len += 1;
        }
        return reps;
    }

    /// `data` as text alone.
    pub fn text(data: []const u8) Reps {
        var reps: Reps = .{};
        reps.buf[0] = .{ .format = .text, .data = data };
        reps.len = 1;
        return reps;
    }

    pub fn slice(self: *const Reps) []const Rep {
        return self.buf[0..self.len];
    }
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

/// One clipboard format's data, made and ready for SetClipboardData.
const Block = struct {
    /// Each is one Windows format: CF_UNICODETEXT, "HTML Format", "PNG",
    /// CF_DIBV5, CF_DIB and "Rich Text Format".
    const Kind = enum { text, html, png, dibv5, dib, rtf };
    kind: Kind,
    format: win32.UINT,
    /// Ours until SetClipboardData takes it; null once it has.
    mem: ?win32.HGLOBAL,
};

/// `NothingWritable` is a write that could make no representation: of
/// types Windows has no format for, data that is not what its type says,
/// or memory that could not be had. It is returned before the clipboard is
/// opened.
pub const WriteError = App.Error || error{NothingWritable};

/// Replace the clipboard's contents with `reps`, each in its Windows
/// format: text as CF_UNICODETEXT, HTML as CF_HTML ("HTML Format"), PNG as
/// "PNG" with a CF_DIBV5 of its pixels beside it (`dibv5Block`), BMP as the
/// CF_DIB or CF_DIBV5 inside the file (`dibOfBmp`), and RTF as "Rich Text
/// Format". They go in the order given with the text last, most
/// descriptive first as Windows asks, since a reader takes the first format
/// it knows
/// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations).
/// Each Windows format is written once, from the first representation that
/// makes it. All go in one opening of the clipboard, so no reader sees some
/// without the others.
///
/// Text that cannot be made or handed over fails the write, and nothing
/// else is left without it: Notepad, and this runtime's own paste, which
/// reads only CF_UNICODETEXT, would find nothing. Any other type that
/// cannot be is logged and left out, and the rest are written, as GTK
/// falls back to the text. The write fails when nothing could be had: the
/// core must not believe a copy landed when it did not. A write that fails
/// before the clipboard is emptied leaves it as it was; one refused after
/// leaves it empty.
pub fn writeClipboard(alloc: Allocator, hwnd: win32.HWND, reps: Reps) WriteError!void {
    // All are made before the clipboard is opened, so the process-wide
    // clipboard lock is held only to hand them over: the text first, so a
    // write that cannot have its text makes nothing else.
    var text: ?Block = null;
    var blocks: [std.enums.values(Block.Kind).len]Block = undefined;
    var len: usize = 0;
    // SetClipboardData takes ownership only on success (`setBlock` then
    // nulls `mem`); freeing a block after that would be a double free the
    // moment anything pastes.
    defer {
        if (text) |b| if (b.mem) |mem| free(mem);
        for (blocks[0..len]) |b| if (b.mem) |mem| free(mem);
    }

    for (reps.slice()) |r| if (r.format == .text) {
        text = textBlock(r.data) orelse return App.Error.Win32CallFailed;
    };
    // `Reps` holds one of each format, so the only kind two can make is
    // CF_DIBV5, from a PNG and from a BMP: the first is kept.
    var made: std.EnumSet(Block.Kind) = .empty;
    for (reps.slice()) |r| {
        var two: [2]?Block = .{ null, null };
        switch (r.format) {
            .text => continue,
            .html => two[0] = htmlBlock(alloc, r.data),
            .png => if (pngSize(r.data)) |size| {
                two[0] = bytesBlock(.png, r.data, false);
                if (!made.contains(.dibv5)) two[1] = dibv5Block(alloc, r.data, size);
            } else log.info("clipboard PNG left out: it does not start as a PNG does", .{}),
            .bmp => if (dibOfBmp(r.data)) |dib| {
                if (!made.contains(dib.kind)) two[0] = dibBlock(dib);
            } else |err| log.info("clipboard BMP left out err={}", .{err}),
            .rtf => if (std.mem.startsWith(u8, r.data, "{\\rtf")) {
                // A NUL after the data, as for CF_HTML.
                two[0] = bytesBlock(.rtf, r.data, true);
            } else log.info("clipboard RTF left out: it does not start as RTF does", .{}),
        }
        for (two) |block| if (block) |b| {
            std.debug.assert(!made.contains(b.kind));
            made.insert(b.kind);
            blocks[len] = b;
            len += 1;
        };
    }
    if (text == null and len == 0) return error.NothingWritable;

    if (!open(hwnd)) {
        log.warn("OpenClipboard failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    defer _ = win32.CloseClipboard();

    if (!win32.EmptyClipboard().toBool()) {
        log.warn("EmptyClipboard failed err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }

    var set: usize = 0;
    for (blocks[0..len]) |*b| {
        if (setBlock(b)) set += 1;
    }
    if (text) |*b| if (!setBlock(b)) {
        // Nothing else without its text.
        _ = win32.EmptyClipboard();
        return App.Error.Win32CallFailed;
    };
    if (text == null and set == 0) return App.Error.Win32CallFailed;
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

/// `html` as CF_HTML; null, logged, if it cannot be made or holds a
/// fragment marker (`hasFragmentMarker`). Invalid UTF-8 and NULs become
/// U+FFFD first (`cleanHtml`).
fn htmlBlock(alloc: Allocator, html: []const u8) ?Block {
    const cleaned = cleanHtml(alloc, html) catch |err| {
        log.warn("clipboard HTML left out err={}", .{err});
        return null;
    };
    defer if (cleaned) |c| alloc.free(c);
    const fragment = cleaned orelse html;
    if (hasFragmentMarker(fragment)) {
        log.info("clipboard HTML left out: it holds a fragment marker", .{});
        return null;
    }

    const format = registeredFormat(.html) orelse return null;
    const len = cfHtmlLen(fragment.len) orelse {
        log.warn("clipboard HTML too long len={d}", .{fragment.len});
        return null;
    };

    // A NUL after the data, for readers that look for one.
    const block = lockedMemory(.html, len + 1) orelse return null;
    {
        defer _ = win32.GlobalUnlock(block.mem);
        const dst: [*]u8 = @ptrCast(block.ptr);
        cfHtml(dst[0..len], fragment);
        dst[len] = 0;
    }
    return .{ .kind = .html, .format = format, .mem = block.mem };
}

/// `html` with each invalid UTF-8 sequence and each NUL as U+FFFD; null if
/// it holds neither, and is written as it is. CF_HTML is UTF-8 by
/// definition (html-clipboard-format), and a NUL ends the data for readers
/// that look for the one written after it, while the offsets point past
/// it. Invalid bytes are replaced as the text's are (`textBlock`), so the
/// two read alike. The caller frees the result.
fn cleanHtml(alloc: Allocator, html: []const u8) (Allocator.Error || App.Error)!?[]u8 {
    const valid = std.unicode.utf8ValidateSlice(html);
    if (valid and std.mem.indexOfScalar(u8, html, 0) == null) return null;
    const utf8 = if (valid) try alloc.dupe(u8, html) else utf8: {
        const wide = try wideFromUtf8(alloc, html);
        defer alloc.free(wide);
        break :utf8 try utf8FromWide(alloc, wide);
    };
    if (std.mem.indexOfScalar(u8, utf8, 0) == null) return utf8;
    defer alloc.free(utf8);
    return try std.mem.replaceOwned(u8, alloc, utf8, "\x00", "\u{FFFD}");
}

/// Whether `html` holds a comment that marks where a CF_HTML fragment
/// starts or ends, matched as loosely as readers match one: without case,
/// and with whitespace inside the comment. The format's page writes
/// `<!--StartFragment -->` in its grammar, asks for the comments "verbatim,
/// with no whitespace" in its prose, and shows `<!-- StartFragment-->` in
/// its examples (html-clipboard-format). A reader that finds the markers
/// rather than the offsets would cut the program's HTML at its own.
fn hasFragmentMarker(html: []const u8) bool {
    var rest = html;
    while (std.mem.indexOf(u8, rest, "<!--")) |at| {
        rest = rest[at + "<!--".len ..];
        const body = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
        for ([_][]const u8{ "startfragment", "endfragment" }) |marker| {
            if (!std.ascii.startsWithIgnoreCase(body, marker)) continue;
            const after = std.mem.trimStart(u8, body[marker.len..], &std.ascii.whitespace);
            if (std.mem.startsWith(u8, after, "-->")) return true;
        }
    }
    return false;
}

/// The registered formats this runtime writes and their names: "HTML
/// Format" from its page, "PNG" by the convention programs share, and "Rich
/// Text Format", which richedit.h defines CF_RTF as.
const Registered = enum {
    html,
    png,
    rtf,

    fn name(self: Registered) win32.LPCWSTR {
        return switch (self) {
            .html => L("HTML Format"),
            .png => L("PNG"),
            .rtf => L("Rich Text Format"),
        };
    }
};

/// The id of a registered clipboard format; null, logged, if it cannot be
/// registered.
fn registeredFormat(which: Registered) ?win32.UINT {
    // Every process that registers the same name gets the same id.
    const format = win32.RegisterClipboardFormatW(which.name());
    if (format == 0) {
        log.warn("RegisterClipboardFormatW failed format={t} err={}", .{ which, win32.GetLastError() });
        return null;
    }
    return format;
}

/// `data` as it is, in the registered format of `kind` (`.png` or `.rtf`),
/// with a NUL after it if `nul`; null, logged, if it cannot be made.
fn bytesBlock(comptime kind: Block.Kind, data: []const u8, nul: bool) ?Block {
    const format = registeredFormat(switch (kind) {
        .png => .png,
        .rtf => .rtf,
        else => @compileError("not a registered format of opaque bytes"),
    }) orelse return null;
    const block = lockedMemory(kind, data.len + @intFromBool(nul)) orelse return null;
    {
        defer _ = win32.GlobalUnlock(block.mem);
        const dst: [*]u8 = @ptrCast(block.ptr);
        @memcpy(dst[0..data.len], data);
        if (nul) dst[data.len] = 0;
    }
    return .{ .kind = kind, .format = format, .mem = block.mem };
}

const PngSize = struct { width: u32, height: u32 };

/// The width and height in a PNG's header; null if `data` does not start
/// as a PNG does, with its signature and an IHDR chunk of 13 bytes
/// (https://www.w3.org/TR/png-3/#5PNG-file-signature and #11IHDR).
fn pngSize(data: []const u8) ?PngSize {
    if (data.len < 24) return null;
    if (!std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (std.mem.readInt(u32, data[8..12], .big) != 13) return null;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const size: PngSize = .{
        .width = std.mem.readInt(u32, data[16..20], .big),
        .height = std.mem.readInt(u32, data[20..24], .big),
    };
    // Zero is not a valid size (#11IHDR).
    if (size.width == 0 or size.height == 0) return null;
    return size;
}

/// A CF_DIBV5 of the pixels of `png`, `size` as its header says, beside the
/// "PNG" for readers that know only the documented image formats: the
/// system makes CF_DIB and CF_BITMAP from it for those that want them
/// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats).
/// The pixels are 32-bit BGRA, bottom-up, with their alpha as the PNG has
/// it, not premultiplied, which the header's alpha mask describes. Null,
/// logged, if it cannot be made, or if the pixels would take as much as a
/// whole write may (`max_write_size`): the PNG is still written.
fn dibv5Block(alloc: Allocator, png: []const u8, size: PngSize) ?Block {
    const header_len = @sizeOf(win32.BITMAPV5HEADER);
    const bits_len = dibBitsLen(size) orelse {
        log.info("no DIB beside a PNG this large width={d} height={d}", .{ size.width, size.height });
        return null;
    };
    const image = wuffs.png.decode(alloc, png) catch |err| {
        log.warn("PNG could not be decoded for its DIB err={}", .{err});
        return null;
    };
    defer alloc.free(image.data);
    if (image.width != size.width or image.height != size.height or image.data.len != bits_len) {
        log.warn("PNG decoded to {d}x{d} where its header says {d}x{d}", .{
            image.width, image.height, size.width, size.height,
        });
        return null;
    }

    const block = lockedMemory(.dibv5, header_len + bits_len) orelse return null;
    {
        defer _ = win32.GlobalUnlock(block.mem);
        const dst: [*]u8 = @ptrCast(block.ptr);
        const header: win32.BITMAPV5HEADER = .{
            .bV5Size = header_len,
            // Both fit: their product is under max_write_size.
            .bV5Width = @intCast(size.width),
            // Positive: the rows go from the bottom up.
            .bV5Height = @intCast(size.height),
            .bV5Planes = 1,
            .bV5BitCount = 32,
            .bV5Compression = win32.BI_BITFIELDS,
            .bV5SizeImage = @intCast(bits_len),
            .bV5XPelsPerMeter = 0,
            .bV5YPelsPerMeter = 0,
            .bV5ClrUsed = 0,
            .bV5ClrImportant = 0,
            .bV5RedMask = 0x00FF0000,
            .bV5GreenMask = 0x0000FF00,
            .bV5BlueMask = 0x000000FF,
            .bV5AlphaMask = 0xFF000000,
            .bV5CSType = win32.LCS_sRGB,
            .bV5Endpoints = @splat(0),
            .bV5GammaRed = 0,
            .bV5GammaGreen = 0,
            .bV5GammaBlue = 0,
            .bV5Intent = win32.LCS_GM_IMAGES,
            .bV5ProfileData = 0,
            .bV5ProfileSize = 0,
            .bV5Reserved = 0,
        };
        @memcpy(dst[0..header_len], std.mem.asBytes(&header));

        // RGBA top-down from the decoder, BGRA bottom-up here, which the
        // masks above describe in a little-endian DWORD.
        const row = @as(usize, size.width) * 4;
        const bits = dst[header_len..][0..bits_len];
        for (0..size.height) |y| {
            const from = image.data[(size.height - 1 - y) * row ..][0..row];
            const to = bits[y * row ..][0..row];
            var x: usize = 0;
            while (x < row) : (x += 4) {
                to[x + 0] = from[x + 2];
                to[x + 1] = from[x + 1];
                to[x + 2] = from[x + 0];
                to[x + 3] = from[x + 3];
            }
        }
    }
    return .{ .kind = .dibv5, .format = win32.CF_DIBV5, .mem = block.mem };
}

/// The bytes of 32-bit pixels of `size`; null if they would take as much as
/// a whole write may (`max_write_size`).
fn dibBitsLen(size: PngSize) ?usize {
    const pixels = std.math.mul(usize, size.width, size.height) catch return null;
    const len = std.math.mul(usize, pixels, 4) catch return null;
    return if (len < max_write_size) len else null;
}

/// Why a DIB, or the BMP file around one, is not taken: what this runtime
/// does not read or write.
const DibError = error{
    /// Too short for a BMP file's header, or without its "BM".
    NotBmp,
    /// An info header Windows has no clipboard format for.
    UnknownHeader,
    HeaderCutShort,
    /// A width, height or number of planes no bitmap has.
    NotBitmap,
    /// A compression or depth a DIB cannot hold.
    UnsupportedCompression,
    /// A color profile, which a DIB keeps apart from its header, past the
    /// bits.
    ColorProfile,
    /// More colors than the depth has.
    TooManyColors,
    /// RLE bits with no size.
    NoBitsSize,
    /// A color table or bits longer than memory.
    TooLong,
    /// Bits a BMP file says start inside its header.
    BitsInHeader,
    BitsCutShort,
};

/// Where the parts of a DIB are
/// (https://learn.microsoft.com/en-us/windows/win32/gdi/bitmap-storage):
/// its info header, the masks and color table after it, then its bits.
const DibLayout = struct {
    /// CF_DIB for a BITMAPINFOHEADER, CF_DIBV5 for a BITMAPV4HEADER or a
    /// BITMAPV5HEADER, as each format's page names its header
    /// (standard-clipboard-formats).
    kind: Block.Kind,
    header_len: usize,
    /// The masks after a BITMAPINFOHEADER, then the color table.
    table_len: usize,
    bits_len: usize,
};

/// The layout of the DIB that `info` starts with its info header.
fn dibLayout(info: []const u8) DibError!DibLayout {
    // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader,
    // whose fields start the later headers too.
    if (info.len < 40) return error.HeaderCutShort;
    const size = std.mem.readInt(u32, info[0..4], .little);
    const kind: Block.Kind = switch (size) {
        40 => .dib,
        108, 124 => .dibv5,
        else => return error.UnknownHeader,
    };
    if (info.len < size) return error.HeaderCutShort;
    const width = std.mem.readInt(i32, info[4..8], .little);
    const height = std.mem.readInt(i32, info[8..12], .little);
    const planes = std.mem.readInt(u16, info[12..14], .little);
    const bpp = std.mem.readInt(u16, info[14..16], .little);
    const compression = std.mem.readInt(u32, info[16..20], .little);
    const size_image = std.mem.readInt(u32, info[20..24], .little);
    const clr_used = std.mem.readInt(u32, info[32..36], .little);
    if (width <= 0 or height == 0 or height == std.math.minInt(i32) or planes != 1)
        return error.NotBitmap;
    // RLE bitmaps must be bottom-up.
    const depth_ok = switch (compression) {
        win32.BI_RGB => switch (bpp) {
            1, 4, 8, 16, 24, 32 => true,
            else => false,
        },
        win32.BI_BITFIELDS => bpp == 16 or bpp == 32,
        win32.BI_RLE8 => bpp == 8 and height > 0,
        win32.BI_RLE4 => bpp == 4 and height > 0,
        else => false,
    };
    if (!depth_ok) return error.UnsupportedCompression;
    if (size >= 108) {
        const cs_type = std.mem.readInt(u32, info[56..60], .little);
        if (cs_type == win32.PROFILE_EMBEDDED or cs_type == win32.PROFILE_LINKED)
            return error.ColorProfile;
    }

    // A BITMAPINFOHEADER's three masks follow it; the later headers hold
    // their own. A depth of 8 or less has a color table of biClrUsed
    // entries, or all 2^depth when that is 0; a greater depth has one only
    // when biClrUsed says so.
    const masks: usize = if (size == 40 and compression == win32.BI_BITFIELDS) 12 else 0;
    const colors: usize = if (bpp <= 8) colors: {
        const most = @as(usize, 1) << @intCast(bpp);
        if (clr_used > most) return error.TooManyColors;
        break :colors if (clr_used == 0) most else clr_used;
    } else clr_used;
    const table_len = std.math.add(usize, masks, std.math.mul(usize, colors, 4) catch
        return error.TooLong) catch return error.TooLong;

    // RLE bits are as long as biSizeImage says; others are rows of whole
    // DWORDs.
    const bits_len: usize = if (compression == win32.BI_RLE8 or compression == win32.BI_RLE4) len: {
        if (size_image == 0) return error.NoBitsSize;
        break :len size_image;
    } else len: {
        const row_bits = std.math.mul(usize, @intCast(width), bpp) catch return error.TooLong;
        const stride = (row_bits / 32 + @intFromBool(row_bits % 32 != 0)) * 4;
        break :len std.math.mul(usize, stride, @abs(height)) catch return error.TooLong;
    };
    return .{ .kind = kind, .header_len = size, .table_len = table_len, .bits_len = bits_len };
}

/// The parts of a BMP file's DIB (`dibOfBmp`).
const Dib = struct {
    kind: Block.Kind,
    /// The info header as the file has it.
    header: []const u8,
    /// The masks after a BITMAPINFOHEADER, then the color table.
    table: []const u8,
    bits: []const u8,
};

/// The length of a BITMAPFILEHEADER
/// (https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapfileheader),
/// whose bfOffBits is the offset of the bits from the file's start.
const bmp_header_len = 14;

/// The DIB inside a BMP file
/// (https://learn.microsoft.com/en-us/windows/win32/gdi/bitmap-storage):
/// the BITMAPFILEHEADER, then the info header with its masks and color
/// table. A clipboard DIB has the bits right after the table, so the gap
/// the file may leave before them is not copied. Refused for a DIB this
/// runtime does not write (`dibLayout`), or bits the file does not hold.
fn dibOfBmp(bmp: []const u8) DibError!Dib {
    if (bmp.len < bmp_header_len or !std.mem.startsWith(u8, bmp, "BM")) return error.NotBmp;
    const off_bits = std.mem.readInt(u32, bmp[10..14], .little);
    const info = bmp[bmp_header_len..];
    const layout = try dibLayout(info);
    const table_end = std.math.add(usize, bmp_header_len + layout.header_len, layout.table_len) catch
        return error.TooLong;
    if (table_end > off_bits) return error.BitsInHeader;
    const bits_end = std.math.add(usize, off_bits, layout.bits_len) catch return error.TooLong;
    if (bits_end > bmp.len) return error.BitsCutShort;
    return .{
        .kind = layout.kind,
        .header = info[0..layout.header_len],
        .table = bmp[bmp_header_len + layout.header_len .. table_end],
        .bits = bmp[off_bits..bits_end],
    };
}

/// `dib` as a packed DIB, its header, table and bits in one block; a
/// BITMAPV4HEADER is widened to the BITMAPV5HEADER that CF_DIBV5 holds.
/// Null, logged, if it cannot be made.
fn dibBlock(dib: Dib) ?Block {
    const header_len: usize = switch (dib.kind) {
        .dib => 40,
        .dibv5 => @sizeOf(win32.BITMAPV5HEADER),
        else => unreachable,
    };
    const len = std.math.add(usize, header_len + dib.table.len, dib.bits.len) catch {
        log.warn("clipboard BMP too long len={d}", .{dib.bits.len});
        return null;
    };
    const block = lockedMemory(dib.kind, len) orelse return null;
    {
        defer _ = win32.GlobalUnlock(block.mem);
        const dst: [*]u8 = @ptrCast(block.ptr);
        @memcpy(dst[0..dib.header.len], dib.header);
        if (dib.header.len < header_len) {
            // The fields a BITMAPV5HEADER adds after a BITMAPV4HEADER:
            // the intent, and no profile.
            @memset(dst[dib.header.len..header_len], 0);
            std.mem.writeInt(u32, dst[0..4], @sizeOf(win32.BITMAPV5HEADER), .little);
            std.mem.writeInt(u32, dst[@offsetOf(win32.BITMAPV5HEADER, "bV5Intent")..][0..4], win32.LCS_GM_IMAGES, .little);
        }
        @memcpy(dst[header_len..][0..dib.table.len], dib.table);
        @memcpy(dst[header_len + dib.table.len ..][0..dib.bits.len], dib.bits);
    }
    return .{
        .kind = dib.kind,
        .format = if (dib.kind == .dib) win32.CF_DIB else win32.CF_DIBV5,
        .mem = block.mem,
    };
}

/// An image as the Kitty clipboard prompt draws it (`ClipboardDialog`):
/// a DIB as StretchDIBits takes it, its info apart from its bits.
pub const Picture = struct {
    /// A BITMAPINFO: the info header, then any masks and color table.
    info: []align(4) u8,
    bits: []u8,
    width: i32,
    /// How many rows, whichever way they go.
    height: i32,

    pub fn deinit(self: Picture, alloc: Allocator) void {
        alloc.free(self.info);
        alloc.free(self.bits);
    }
};

/// `data` as a Picture if it is a PNG or a BMP file, the image formats this
/// runtime writes (`formatOf`): a PNG decoded, its transparency over
/// `background` as the prompt's face shows through it; a BMP file's DIB as
/// it is, which GDI draws. Null if it is neither, does not decode, or has
/// as many pixels as a whole write may hold bytes (`dibBitsLen`), which is
/// checked before anything is decoded or copied.
pub fn picture(alloc: Allocator, data: []const u8, background: win32.COLORREF) ?Picture {
    if (pngSize(data)) |size| return pngPicture(alloc, data, size, background);
    const dib = dibOfBmp(data) catch return null;
    return bmpPicture(alloc, dib);
}

fn pngPicture(alloc: Allocator, png: []const u8, size: PngSize, background: win32.COLORREF) ?Picture {
    const bits_len = dibBitsLen(size) orelse {
        log.info("no picture of a PNG this large width={d} height={d}", .{ size.width, size.height });
        return null;
    };
    const image = wuffs.png.decode(alloc, png) catch |err| {
        log.info("PNG could not be decoded for its picture err={}", .{err});
        return null;
    };
    if (image.width != size.width or image.height != size.height or image.data.len != bits_len) {
        log.warn("PNG decoded to {d}x{d} where its header says {d}x{d}", .{
            image.width, image.height, size.width, size.height,
        });
        alloc.free(image.data);
        return null;
    }
    const info = alloc.alignedAlloc(u8, .of(win32.BITMAPINFOHEADER), @sizeOf(win32.BITMAPINFOHEADER)) catch {
        alloc.free(image.data);
        return null;
    };
    // Both fit: their product is under max_write_size.
    const width: i32 = @intCast(size.width);
    const height: i32 = @intCast(size.height);
    const header: win32.BITMAPINFOHEADER = .{
        .biSize = @sizeOf(win32.BITMAPINFOHEADER),
        .biWidth = width,
        // Negative: the rows go from the top down, as decoded.
        .biHeight = -height,
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = win32.BI_RGB,
        .biSizeImage = 0,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    };
    @memcpy(info, std.mem.asBytes(&header));
    over(image.data, background);
    return .{ .info = info, .bits = image.data, .width = width, .height = height };
}

/// RGBA pixels, not premultiplied, as the decoder gives them, made in place
/// into what a 32-bit BI_RGB DIB holds, blue, green, red and a byte GDI
/// ignores, each over `background` by its alpha, rounded.
fn over(pixels: []u8, background: win32.COLORREF) void {
    const bg_r: u32 = background & 0xFF;
    const bg_g: u32 = (background >> 8) & 0xFF;
    const bg_b: u32 = (background >> 16) & 0xFF;
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const p = pixels[i..][0..4];
        const a: u32 = p[3];
        const r = blend(p[0], a, bg_r);
        const g = blend(p[1], a, bg_g);
        const b = blend(p[2], a, bg_b);
        p.* = .{ b, g, r, 0 };
    }
}

fn blend(c: u8, a: u32, bg: u32) u8 {
    // At most (255 * 255 + 127) / 255, so it fits.
    return @intCast((@as(u32, c) * a + bg * (255 - a) + 127) / 255);
}

fn bmpPicture(alloc: Allocator, dib: Dib) ?Picture {
    const width = std.mem.readInt(i32, dib.header[4..8], .little);
    const height = std.mem.readInt(i32, dib.header[8..12], .little);
    // dibLayout took neither as zero or less, nor minInt(i32) rows. GDI
    // makes the pixels of a compressed bitmap, whatever its bits' length.
    const size: PngSize = .{ .width = @intCast(width), .height = @abs(height) };
    if (dibBitsLen(size) == null) {
        log.info("no picture of a BMP this large width={d} height={d}", .{ size.width, size.height });
        return null;
    }
    const info = alloc.alignedAlloc(u8, .of(win32.BITMAPINFOHEADER), dib.header.len + dib.table.len) catch return null;
    @memcpy(info[0..dib.header.len], dib.header);
    @memcpy(info[dib.header.len..], dib.table);
    const bits = alloc.dupe(u8, dib.bits) catch {
        alloc.free(info);
        return null;
    };
    return .{ .info = info, .bits = bits, .width = width, .height = @intCast(size.height) };
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

/// For tests: the CF_HTML on the clipboard, as written, header and all, or
/// null if it holds none. The app reads HTML only for a Kitty read, and
/// only its fragment or document (`readClipboard`, `htmlOf`).
pub fn readClipboardHtml(alloc: Allocator, hwnd: win32.HWND) !?[]u8 {
    const format = registeredFormat(.html) orelse return error.TestUnexpectedResult;
    if (!win32.IsClipboardFormatAvailable(format).toBool()) return null;
    if (!open(hwnd)) return error.TestUnexpectedResult;
    defer _ = win32.CloseClipboard();
    const mem = win32.GetClipboardData(format) orelse return error.TestUnexpectedResult;
    const raw = win32.GlobalLock(mem) orelse return error.TestUnexpectedResult;
    defer _ = win32.GlobalUnlock(mem);
    const bytes: [*]const u8 = @ptrCast(raw);
    const block = bytes[0..win32.GlobalSize(mem)];
    return try alloc.dupe(u8, block[0 .. std.mem.indexOfScalar(u8, block, 0) orelse block.len]);
}

/// The fragment of CF_HTML `data`, found as a reader finds it, from the
/// StartFragment and EndFragment offsets; null if they are missing or out
/// of the data.
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

// Reads by MIME type, for the Kitty clipboard protocol. Whatever another
// program placed is checked as a write checks what a program sends.

/// For tests: the most of one type a read takes (`readCap`).
pub var test_read_cap: if (builtin.is_test) usize else void = if (builtin.is_test) max_write_size else {};

/// The most of one type a read takes: what a program may write in one
/// transaction. The core base64-encodes everything a read serves into one
/// reply, so without a bound an image of several hundred MB would cost
/// about 2.4 times its size at once.
fn readCap() usize {
    return if (builtin.is_test) test_read_cap else max_write_size;
}

/// What a clipboard format holds, as a read takes it.
const Held = enum {
    /// CF_UNICODETEXT.
    text,
    /// CF_HTML ("HTML Format").
    html,
    /// "PNG".
    png,
    /// CF_DIB or CF_DIBV5, read as a BMP file.
    dib,
    /// "Rich Text Format".
    rtf,
    /// CF_HDROP, read as text/uri-list.
    files,
    /// A format registered under a MIME type's name, read as it is.
    other,
};

/// A clipboard format a read can serve, and the MIME type it serves it as.
const Offered = struct {
    format: win32.UINT,
    mime: []const u8,
    held: Held,
};

/// What a read serves `format` as; null for a format it does not serve.
/// `known` holds the ids of the registered formats this runtime writes.
/// Any other registered format is known by its name, which is never
/// registered here: registering the names a program sends would let it
/// fill the session's atom table, whose "space exhaustion ... will result
/// in serious issues; for example, all applications may fail to launch"
/// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/about-atom-tables).
/// A registered name that is a MIME type is served as it is, unless it
/// is one a format above is served as: text, HTML, PNG, BMP, RTF and file
/// lists come only from the formats Windows and programs share for them.
fn offered(
    alloc: Allocator,
    format: win32.UINT,
    known: *const std.EnumArray(Registered, ?win32.UINT),
) Allocator.Error!?Offered {
    return switch (format) {
        win32.CF_UNICODETEXT => .{ .format = format, .mime = "text/plain", .held = .text },
        win32.CF_DIB, win32.CF_DIBV5 => .{ .format = format, .mime = "image/bmp", .held = .dib },
        win32.CF_HDROP => .{ .format = format, .mime = "text/uri-list", .held = .files },
        // Registered formats (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclipboardformatw).
        0xC000...0xFFFF => registered: {
            const ours = [_]struct { Registered, []const u8, Held }{
                .{ .html, "text/html", .html },
                .{ .png, "image/png", .png },
                .{ .rtf, "text/rtf", .rtf },
            };
            for (ours) |o| if (known.get(o[0])) |id| if (id == format)
                break :registered .{ .format = format, .mime = o[1], .held = o[2] };

            // A registered name is at most 255 characters (about-atom-tables).
            var wide: [256]u16 = undefined;
            const n = win32.GetClipboardFormatNameW(format, &wide, wide.len);
            if (n <= 0 or !isMimeName(wide[0..@intCast(n)])) break :registered null;
            const name = try alloc.alloc(u8, @intCast(n));
            for (name, wide[0..@intCast(n)]) |*b, unit| b.* = @intCast(unit);
            if (formatOf(name) != null or std.mem.eql(u8, name, "text/uri-list")) break :registered null;
            break :registered .{ .format = format, .mime = name, .held = .other };
        },
        else => null,
    };
}

/// Whether `name` is a MIME type, `type/subtype`, each a restricted-name
/// (RFC 6838 section 4.2): ASCII, with no space to split the listing,
/// which joins types with spaces.
fn isMimeName(name: []const u16) bool {
    const slash = std.mem.indexOfScalar(u16, name, '/') orelse return false;
    return isRestrictedName(name[0..slash]) and isRestrictedName(name[slash + 1 ..]);
}

fn isRestrictedName(name: []const u16) bool {
    if (name.len == 0 or name.len > 127) return false;
    for (name, 0..) |unit, i| {
        if (unit > 0x7F) return false;
        const c: u8 = @intCast(unit);
        if (std.ascii.isAlphanumeric(c)) continue;
        if (i == 0 or std.mem.indexOfScalar(u8, "!#$&-^_.+", c) == null) return false;
    }
    return true;
}

/// Whether a read of `o` serves `mime`: by name, and any name the core
/// treats as text for the text.
fn serves(o: Offered, mime: []const u8) bool {
    return std.mem.eql(u8, o.mime, mime) or (o.held == .text and terminal.clipboard.isTextMime(mime));
}

/// What `readClipboard` found.
pub const Found = struct {
    contents_buf: [max_read_mimes]terminal.clipboard.Content = undefined,
    contents_len: usize = 0,
    available_buf: [max_listing_mimes][]const u8 = undefined,
    available_len: usize = 0,

    /// Each type asked for that the clipboard holds, once for each
    /// format, in the order asked, under the name it is served as. The
    /// core serves each type asked for from these, a text to every name
    /// it treats as text.
    pub fn contents(self: *const Found) []const terminal.clipboard.Content {
        return self.contents_buf[0..self.contents_len];
    }

    /// The listing, when asked for.
    pub fn available(self: *const Found) []const []const u8 {
        return self.available_buf[0..self.available_len];
    }

    fn addListed(self: *Found, mime: []const u8) void {
        if (self.available_len == self.available_buf.len) return;
        for (self.available()) |m| if (std.mem.eql(u8, m, mime)) return;
        self.available_buf[self.available_len] = mime;
        self.available_len += 1;
    }
};

const max_read_mimes = terminal.kitty.clipboard.max_read_mimes;
const max_listing_mimes = terminal.kitty.clipboard.max_listing_mimes;

/// Read the clipboard's representations of `mimes`, the first
/// `max_read_mimes` of them, and its listing if `list`, in one opening of
/// the clipboard, which is closed before this returns: it is a lock for
/// the whole session, and no prompt may hold it. What is read is copied
/// into `alloc`, an arena the caller frees.
///
/// The listing names each type once, `text/plain` first as macOS lists
/// it, then the rest in the order the clipboard enumerates them, which is
/// the order they were placed, each synthesized format after its source
/// (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumclipboardformats);
/// at most `max_listing_mimes`, as GTK lists them. It reads no data.
///
/// A type the clipboard does not hold is left out, and so is one whose
/// data is not what its type says or is larger than `readCap`, logged: a
/// program learns a type is unavailable by its absence. Fails only when
/// the clipboard cannot be opened, or memory runs out.
pub fn readClipboard(
    alloc: Allocator,
    hwnd: win32.HWND,
    mimes: []const []const u8,
    list: bool,
) (Allocator.Error || App.Error)!Found {
    var found: Found = .{};
    const asked = mimes[0..@min(mimes.len, max_read_mimes)];
    var wanted: [max_read_mimes]?Offered = @splat(null);

    // The formats this runtime writes are known by id. Their names are
    // fixed, so registering them, as every program that writes them does,
    // registers nothing new.
    var known: std.EnumArray(Registered, ?win32.UINT) = .initUndefined();
    for (std.enums.values(Registered)) |which| known.set(which, registeredFormat(which));

    if (!open(hwnd)) {
        log.warn("OpenClipboard failed for a read err={}", .{win32.GetLastError()});
        return App.Error.Win32CallFailed;
    }
    defer _ = win32.CloseClipboard();

    if (list and win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT).toBool()) found.addListed("text/plain");
    var format: win32.UINT = 0;
    while (true) {
        // GetClipboardFormatNameW fails for the predefined formats, so the
        // error left from it is not EnumClipboardFormats'.
        win32.SetLastError(.SUCCESS);
        format = win32.EnumClipboardFormats(format);
        if (format == 0) {
            // Zero with ERROR_SUCCESS is the end of the formats.
            const err = win32.GetLastError();
            if (err != .SUCCESS) log.warn("EnumClipboardFormats failed err={}", .{err});
            break;
        }
        const o = (try offered(alloc, format, &known)) orelse continue;
        if (list) found.addListed(o.mime);
        for (asked, wanted[0..asked.len]) |mime, *w| {
            if (w.* == null and serves(o, mime)) w.* = o;
        }
    }

    next: for (wanted[0..asked.len], 0..) |w, i| {
        const o = w orelse continue;
        for (wanted[0..i]) |before| if (before) |b| if (b.format == o.format) continue :next;
        const data = readOffered(alloc, o) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                log.info("clipboard type left out of a read mime={f} err={}", .{ std.zig.fmtString(o.mime), e });
                continue;
            },
        };
        found.contents_buf[found.contents_len] = .{ .mime = o.mime, .data = data };
        found.contents_len += 1;
    }
    return found;
}

/// Why a type the clipboard holds is not read.
const ReadOneError = Allocator.Error || DibError || error{
    /// GetClipboardData or GlobalLock gave nothing: an owner that
    /// renders on request can fail to.
    NoData,
    /// Larger than `readCap`.
    TooLarge,
    /// "PNG" that is not a PNG's chunks.
    NotPng,
    /// CF_HTML with neither its fragment's offsets nor its document's.
    NotCfHtml,
    /// A file list with no path a URI can name.
    NoFiles,
};

/// The data of `o` as its MIME type has it, copied into `alloc`. The
/// clipboard must be open.
fn readOffered(alloc: Allocator, o: Offered) ReadOneError![]const u8 {
    const handle = win32.GetClipboardData(o.format) orelse return error.NoData;
    if (o.held == .files) return uriList(alloc, @ptrCast(handle));
    const raw = win32.GlobalLock(handle) orelse return error.NoData;
    defer _ = win32.GlobalUnlock(handle);

    // Another process wrote this block, so only its size bounds it, and
    // that can be more than was written: "The size of a memory block may
    // be larger than the size requested"
    // (https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-globalsize).
    const size = win32.GlobalSize(handle);
    if (o.held == .text) {
        const units: [*]const u16 = @ptrCast(@alignCast(raw));
        return textOf(alloc, units[0 .. size / @sizeOf(u16)]);
    }
    const bytes: [*]const u8 = @ptrCast(raw);
    const block = bytes[0..size];
    const data: []const u8 = switch (o.held) {
        .text, .files => unreachable,
        .html => try htmlOf(block),
        .png => try pngOf(block),
        .dib => return bmpOfDib(alloc, block),
        // RTF is text, which ends at its NUL (writeClipboard puts one
        // after it). An opaque type is as GlobalSize gives it.
        .rtf => untilNul(block),
        .other => block,
    };
    if (data.len > readCap()) return error.TooLarge;
    return try alloc.dupe(u8, data);
}

fn untilNul(block: []const u8) []const u8 {
    return block[0 .. std.mem.indexOfScalar(u8, block, 0) orelse block.len];
}

/// UTF-8 for a CF_UNICODETEXT block (`utf8FromClipboard`), at most
/// `readCap` bytes of it.
fn textOf(alloc: Allocator, block: []const u16) (Allocator.Error || error{TooLarge})![]const u8 {
    const units = block[0 .. std.mem.indexOfScalar(u16, block, 0) orelse block.len];
    // Each unit is at least a byte of UTF-8, so text of more units than
    // the cap is refused before it is converted.
    if (units.len > readCap()) return error.TooLarge;
    const text = try utf8FromWide(alloc, units);
    if (text.len > readCap()) return error.TooLarge;
    return text;
}

/// The HTML in CF_HTML `block`: its fragment, as a Kitty write puts it
/// there, else its document, StartHTML to EndHTML, when the fragment's
/// offsets are missing or out of the data. The data is UTF-8 and ends at
/// its NUL.
fn htmlOf(block: []const u8) error{NotCfHtml}![]const u8 {
    const data = untilNul(block);
    if (cfHtmlFragment(data)) |fragment| return fragment;
    const start = cfHtmlOffset(data, "StartHTML:") orelse return error.NotCfHtml;
    const end = cfHtmlOffset(data, "EndHTML:") orelse return error.NotCfHtml;
    if (start > end or end > data.len) return error.NotCfHtml;
    return data[start..end];
}

/// The PNG `block` starts with, to the end of its IEND chunk: each chunk
/// is a length, a type, that many bytes and a CRC
/// (https://www.w3.org/TR/png-3/#5Chunk-layout).
fn pngOf(block: []const u8) error{NotPng}![]const u8 {
    const signature = "\x89PNG\r\n\x1a\n";
    if (!std.mem.startsWith(u8, block, signature)) return error.NotPng;
    var at: usize = signature.len;
    while (block.len - at >= 12) {
        const len = std.mem.readInt(u32, block[at..][0..4], .big);
        const end = std.math.add(usize, at + 12, len) catch return error.NotPng;
        if (end > block.len) return error.NotPng;
        if (std.mem.eql(u8, block[at + 4 ..][0..4], "IEND")) return block[0..end];
        at = end;
    }
    return error.NotPng;
}

/// A BMP file of the DIB that `block`, a CF_DIB or CF_DIBV5, holds: the
/// BITMAPFILEHEADER, then the DIB as long as its header says it is,
/// without what GlobalSize gives past it. A DIB has its bits right after
/// its table, which is where bfOffBits points.
fn bmpOfDib(alloc: Allocator, block: []const u8) (Allocator.Error || DibError || error{TooLarge})![]const u8 {
    const layout = try dibLayout(block);
    const bits_at = layout.header_len + layout.table_len;
    const dib_len = std.math.add(usize, bits_at, layout.bits_len) catch return error.TooLong;
    if (dib_len > block.len) return error.BitsCutShort;
    const len = bmp_header_len + dib_len;
    if (len > readCap()) return error.TooLarge;
    const out = try alloc.alloc(u8, len);
    @memcpy(out[0..2], "BM");
    // The cap is far under 4 GiB, so both fit.
    std.mem.writeInt(u32, out[2..6], @intCast(len), .little);
    @memset(out[6..10], 0);
    std.mem.writeInt(u32, out[10..14], @intCast(bmp_header_len + bits_at), .little);
    @memcpy(out[bmp_header_len..], block[0..dib_len]);
    return out;
}

/// The files of CF_HDROP `hdrop` as text/uri-list (RFC 2483): a `file:`
/// URI for each path, each line ended by CRLF, as macOS serves copied
/// files (`ghosttyData` in
/// macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift). A
/// path a URI cannot name is left out and logged.
fn uriList(alloc: Allocator, hdrop: win32.HDROP) (Allocator.Error || error{ NoFiles, TooLarge })![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var paths: drop.Paths = .init(hdrop);
    defer paths.deinit(alloc);
    while (try paths.next(alloc)) |path| {
        defer alloc.free(path);
        appendFileUri(alloc, &out, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotAbsolute => {
                log.info("a file list's path left out of text/uri-list err={}", .{err});
                continue;
            },
        };
        try out.appendSlice(alloc, "\r\n");
        if (out.items.len > readCap()) return error.TooLarge;
    }
    if (out.items.len == 0) return error.NoFiles;
    return try out.toOwnedSlice(alloc);
}

/// Append the `file:` URI of `path`, an absolute Windows path (RFC 8089
/// appendix E.2 and E.3): `file:///C:/a%20b` for a drive's, and
/// `file://host/share/a` for a UNC path's, either also with the `\\?\`
/// prefix of a long path. Each byte but the unreserved ones (RFC 3986
/// section 2.3), a separator and the drive's colon is percent-escaped.
fn appendFileUri(alloc: Allocator, out: *std.ArrayList(u8), path: []const u8) (Allocator.Error || error{NotAbsolute})!void {
    const long = "\\\\?\\";
    const long_unc = long ++ "UNC\\";
    var rest = path;
    var unc = false;
    if (std.mem.startsWith(u8, rest, long_unc)) {
        rest = rest[long_unc.len..];
        unc = true;
    } else if (std.mem.startsWith(u8, rest, long)) {
        rest = rest[long.len..];
    } else if (std.mem.startsWith(u8, rest, "\\\\")) {
        rest = rest[2..];
        unc = true;
    }

    if (unc) {
        if (rest.len == 0 or rest[0] == '\\') return error.NotAbsolute;
        try out.appendSlice(alloc, "file://");
        return appendEscaped(alloc, out, rest);
    }
    if (rest.len < 3 or !std.ascii.isAlphabetic(rest[0]) or rest[1] != ':' or rest[2] != '\\')
        return error.NotAbsolute;
    try out.appendSlice(alloc, "file:///");
    try out.appendSlice(alloc, rest[0..2]);
    try appendEscaped(alloc, out, rest[2..]);
}

fn appendEscaped(alloc: Allocator, out: *std.ArrayList(u8), part: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (part) |b| switch (b) {
        '\\' => try out.append(alloc, '/'),
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try out.append(alloc, b),
        else => try out.appendSlice(alloc, &.{ '%', hex[b >> 4], hex[b & 0xF] }),
    };
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

/// The text of the prompt for a clipboard request the core would not
/// complete unasked. A paste puts the text into the terminal; a read hands
/// the clipboard to whatever program is running, which can send it
/// anywhere; a write replaces what the user copied. None may share wording,
/// or the user approves one believing it is another. The GTK and macOS
/// confirmation dialogs word them apart too.
pub fn clipboardPrompt(state: apprt.ClipboardRequestType, question: *Question) win32.LPCWSTR {
    return switch (state) {
        // GTK's dialog, its heading and its body, which are translated.
        // Its words for a read and a write say that the contents are
        // shown below, which a message box does not do.
        .paste => question.text(
            "Warning: Potentially Unsafe Paste",
            "Pasting this text into the terminal may be dangerous as it looks like some commands may be executed.",
        ),
        .osc_52_read, .kitty_read => L("An application wants to read the clipboard. Allow it?"),
        .osc_52_write, .kitty_write => L("An application wants to write to the clipboard. Allow it?"),

        // A paste event's listing never needs consent.
        .list => unreachable,
    };
}

/// For tests: a representation `testPut` puts on the clipboard as it is.
pub const TestPut = struct { format: win32.UINT, data: []const u8 };

/// For tests: replace the clipboard's contents with `puts`, in order, each
/// as it is, then the files `names` as CF_HDROP if there are any.
pub fn testPut(hwnd: win32.HWND, puts: []const TestPut, names: []const []const u16) !void {
    if (!open(hwnd)) return error.TestUnexpectedResult;
    defer _ = win32.CloseClipboard();
    if (!win32.EmptyClipboard().toBool()) return error.TestUnexpectedResult;
    for (puts) |p| {
        const mem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, @max(p.data.len, 1)) orelse
            return error.TestUnexpectedResult;
        errdefer _ = win32.GlobalFree(mem);
        const dst: [*]u8 = @ptrCast(win32.GlobalLock(mem) orelse return error.TestUnexpectedResult);
        @memcpy(dst[0..p.data.len], p.data);
        _ = win32.GlobalUnlock(mem);
        if (win32.SetClipboardData(p.format, mem) == null) return error.TestUnexpectedResult;
    }
    if (names.len != 0) {
        const hdrop = try drop.testDrop(names);
        errdefer _ = win32.GlobalFree(@ptrCast(hdrop));
        if (win32.SetClipboardData(win32.CF_HDROP, @ptrCast(hdrop)) == null) return error.TestUnexpectedResult;
    }
}

/// For tests: the id of the registered format `name`, registering it. A
/// name stays registered until the session ends, so tests register only
/// fixed names.
fn testRegister(name: [:0]const u16) !win32.UINT {
    const format = win32.RegisterClipboardFormatW(name);
    return if (format == 0) error.TestUnexpectedResult else format;
}

/// For tests: whether `name` is registered, found without registering it:
/// GetClipboardFormatNameW names every registered id, 0xC000 to 0xFFFF,
/// whether the clipboard holds it or not.
fn testRegistered(name: []const u8) bool {
    var wide: [256]u16 = undefined;
    for (0xC000..0x10000) |id| {
        const n = win32.GetClipboardFormatNameW(@intCast(id), &wide, wide.len);
        if (n <= 0 or @as(usize, @intCast(n)) != name.len) continue;
        for (wide[0..@intCast(n)], name) |w, c| {
            if (w != c) break;
        } else return true;
    }
    return false;
}

/// For tests: another thread holding the clipboard open, as another
/// program can. OpenClipboard "fails if another window has the clipboard
/// open" (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard).
pub const TestHolder = struct {
    const State = enum(u8) { start, open, refused, release, closed };
    var state: std.atomic.Value(State) = .init(.start);
    thread: std.Thread,

    fn hold() void {
        if (!open(null)) return state.store(.refused, .release);
        state.store(.open, .release);
        while (state.load(.acquire) != .release) win32.Sleep(1);
        _ = win32.CloseClipboard();
        state.store(.closed, .release);
    }

    /// Close the clipboard the holder holds, and wait until it has. As
    /// `test_busy`, another program letting go between `open`'s tries.
    pub fn letGo() void {
        if (state.cmpxchgStrong(.open, .release, .acq_rel, .acquire) != null) return;
        while (state.load(.acquire) != .closed) win32.Sleep(1);
    }

    /// The clipboard, held open by another thread until `release`.
    pub fn start() !TestHolder {
        state.store(.start, .release);
        const thread = try std.Thread.spawn(.{}, hold, .{});
        while (state.load(.acquire) == .start) win32.Sleep(1);
        if (state.load(.acquire) != .open) {
            thread.join();
            return error.TestUnexpectedResult;
        }
        return .{ .thread = thread };
    }

    pub fn release(self: TestHolder) void {
        letGo();
        self.thread.join();
    }
};

/// For tests: `found` served `want`, in order.
fn expectServed(found: *const Found, want: []const terminal.clipboard.Content) !void {
    errdefer for (found.contents()) |c| std.debug.print("served mime={s} data={f}\n", .{ c.mime, std.zig.fmtString(c.data) });
    try std.testing.expectEqual(want.len, found.contents().len);
    for (want, found.contents()) |w, c| {
        try std.testing.expectEqualStrings(w.mime, c.mime);
        try std.testing.expectEqualSlices(u8, w.data, c.data);
    }
}

/// For tests: `found` listed `want`, in order.
fn expectListed(found: *const Found, want: []const []const u8) !void {
    errdefer for (found.available()) |m| std.debug.print("listed {s}\n", .{m});
    try std.testing.expectEqual(want.len, found.available().len);
    for (want, found.available()) |w, m| try std.testing.expectEqualStrings(w, m);
}

test "win32: clipboard prompts word pastes, reads and writes apart, and default to Cancel" {
    var question: Question = .{};
    var other: Question = .{};
    const paste = std.mem.span(clipboardPrompt(.paste, &question));
    const words = std.unicode.utf8ToUtf16LeStringLiteral;
    for ([_]apprt.ClipboardRequestType{ .osc_52_read, .kitty_read }) |state| {
        const read = std.mem.span(clipboardPrompt(state, &other));
        try std.testing.expect(!std.mem.eql(u16, paste, read));
        try std.testing.expect(std.mem.indexOf(u16, read, words("aste")) == null);
        try std.testing.expect(std.mem.indexOf(u16, read, words("read")) != null);
    }
    for ([_]apprt.ClipboardRequestType{ .osc_52_write, .kitty_write }) |state| {
        const write = std.mem.span(clipboardPrompt(state, &other));
        try std.testing.expect(std.mem.indexOf(u16, write, words("aste")) == null);
        try std.testing.expect(std.mem.indexOf(u16, write, words("read")) == null);
        try std.testing.expect(std.mem.indexOf(u16, write, words("write")) != null);
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

/// For tests: put back the text the clipboard held when `save` ran. Other
/// formats are lost, which is acceptable for a test.
pub const TestSaved = struct {
    text: ?[]u8,

    pub fn save(hwnd: win32.HWND) !TestSaved {
        return .{ .text = try readClipboardText(std.testing.allocator, hwnd) };
    }

    pub fn restore(self: TestSaved, hwnd: win32.HWND) void {
        const text = self.text orelse return;
        writeClipboard(std.testing.allocator, hwnd, .text(text)) catch {};
        std.testing.allocator.free(text);
    }
};

/// For tests: the formats on the clipboard, in the order
/// EnumClipboardFormats gives them, synthesized ones included.
fn testFormats(hwnd: win32.HWND, buf: []win32.UINT) ![]win32.UINT {
    if (!open(hwnd)) return error.TestUnexpectedResult;
    defer _ = win32.CloseClipboard();
    var len: usize = 0;
    var format: win32.UINT = 0;
    while (true) {
        format = win32.EnumClipboardFormats(format);
        if (format == 0) break;
        if (len == buf.len) return error.TestUnexpectedResult;
        buf[len] = format;
        len += 1;
    }
    return buf[0..len];
}

/// For tests: all GlobalSize gives of the clipboard's `format`, or null if
/// it holds none. The block can be longer than what was written.
fn testData(alloc: Allocator, hwnd: win32.HWND, format: win32.UINT) !?[]u8 {
    if (!win32.IsClipboardFormatAvailable(format).toBool()) return null;
    if (!open(hwnd)) return error.TestUnexpectedResult;
    defer _ = win32.CloseClipboard();
    const mem = win32.GetClipboardData(format) orelse return error.TestUnexpectedResult;
    const raw = win32.GlobalLock(mem) orelse return error.TestUnexpectedResult;
    defer _ = win32.GlobalUnlock(mem);
    const bytes: [*]const u8 = @ptrCast(raw);
    return try alloc.dupe(u8, bytes[0..win32.GlobalSize(mem)]);
}

/// For tests: whether the clipboard's `format` holds `want`, as written.
fn testHolds(hwnd: win32.HWND, format: win32.UINT, want: []const u8) !bool {
    const alloc = std.testing.allocator;
    const data = (try testData(alloc, hwnd, format)) orelse return false;
    defer alloc.free(data);
    return std.mem.startsWith(u8, data, want);
}

/// For tests: a 2x2 PNG, RGBA at 8 bits a channel. Its pixels, top row
/// first: opaque red, green at an alpha of 128; blue at an alpha of 0,
/// and (16, 32, 48) at 64.
pub const test_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
    "\x00\x00\x00\x02\x00\x00\x00\x02\x08\x06\x00\x00\x00\x72\xb6\x0d" ++
    "\x24\x00\x00\x00\x16\x49\x44\x41\x54\x78\xda\x63\xf8\xcf\xc0\xf0" ++
    "\x1f\x08\x1b\x18\x40\xb4\x80\x82\x81\x03\x00\x37\x21\x05\x1d\x77" ++
    "\xf1\xb9\x99\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

/// For tests: whether CF_DIBV5 holds `test_png`'s pixels as `dibv5Block`
/// makes them, read against the header's fields. The system makes a
/// CF_DIBV5 from a CF_DIB, which this tells apart.
fn testHoldsPngDib(hwnd: win32.HWND) !bool {
    const alloc = std.testing.allocator;
    const data = (try testData(alloc, hwnd, win32.CF_DIBV5)) orelse return false;
    defer alloc.free(data);
    const header_len = @sizeOf(win32.BITMAPV5HEADER);
    if (data.len < header_len + 16) return false;
    const h = std.mem.bytesToValue(win32.BITMAPV5HEADER, data[0..header_len]);
    const want: win32.BITMAPV5HEADER = .{
        .bV5Size = header_len,
        .bV5Width = 2,
        .bV5Height = 2,
        .bV5Planes = 1,
        .bV5BitCount = 32,
        .bV5Compression = win32.BI_BITFIELDS,
        .bV5SizeImage = 16,
        .bV5XPelsPerMeter = 0,
        .bV5YPelsPerMeter = 0,
        .bV5ClrUsed = 0,
        .bV5ClrImportant = 0,
        .bV5RedMask = 0x00FF0000,
        .bV5GreenMask = 0x0000FF00,
        .bV5BlueMask = 0x000000FF,
        .bV5AlphaMask = 0xFF000000,
        .bV5CSType = win32.LCS_sRGB,
        .bV5Endpoints = @splat(0),
        .bV5GammaRed = 0,
        .bV5GammaGreen = 0,
        .bV5GammaBlue = 0,
        .bV5Intent = win32.LCS_GM_IMAGES,
        .bV5ProfileData = 0,
        .bV5ProfileSize = 0,
        .bV5Reserved = 0,
    };
    if (!std.meta.eql(want, h)) return false;
    // Bottom-up BGRA: the PNG's bottom row first, its alpha unchanged.
    return std.mem.eql(u8, data[header_len..][0..16], &.{
        255, 0, 0,   0,   48, 32,  16, 64,
        0,   0, 255, 255, 0,  255, 0,  128,
    });
}

/// For tests: a BMP file of a bitmap two pixels wide, and the DIB the
/// clipboard should hold for it. Every byte not a header field is from a
/// pattern, so a table, gap or bits copied from the wrong place shows.
const TestBmp = struct {
    header: u32 = 40,
    compression: u32 = win32.BI_RGB,
    bpp: u16 = 24,
    height: i32 = 2,
    clr_used: u32 = 0,
    cs_type: u32 = win32.LCS_sRGB,
    /// Bytes between the color table and the bits.
    gap: usize = 0,

    const width = 2;
    /// biSizeImage of an RLE bitmap: as many bytes as its bits are said
    /// to take.
    const rle_len = 8;

    fn rle(self: TestBmp) bool {
        return self.compression == win32.BI_RLE8 or self.compression == win32.BI_RLE4;
    }

    fn tableLen(self: TestBmp) usize {
        const masks: usize = if (self.header == 40 and self.compression == win32.BI_BITFIELDS) 12 else 0;
        const colors: usize = if (self.bpp > 8)
            self.clr_used
        else if (self.clr_used == 0)
            @as(usize, 1) << @intCast(self.bpp)
        else
            self.clr_used;
        return masks + colors * 4;
    }

    fn offBits(self: TestBmp) usize {
        return 14 + self.header + self.tableLen() + self.gap;
    }

    fn bitsLen(self: TestBmp) usize {
        if (self.rle()) return rle_len;
        const stride = (width * @as(usize, self.bpp) + 31) / 32 * 4;
        return stride * @abs(self.height);
    }

    /// The file, in `buf`, with a NUL after it as the core gives data.
    fn file(self: TestBmp, buf: []u8) [:0]u8 {
        const len = self.offBits() + self.bitsLen();
        buf[len] = 0;
        const out = buf[0..len :0];
        for (out, 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);
        out[0] = 'B';
        out[1] = 'M';
        std.mem.writeInt(u32, out[2..6], @intCast(out.len), .little);
        @memset(out[6..10], 0);
        std.mem.writeInt(u32, out[10..14], @intCast(self.offBits()), .little);
        const info = out[14..][0..self.header];
        @memset(info, 0);
        std.mem.writeInt(u32, info[0..4], self.header, .little);
        std.mem.writeInt(i32, info[4..8], width, .little);
        std.mem.writeInt(i32, info[8..12], self.height, .little);
        std.mem.writeInt(u16, info[12..14], 1, .little);
        std.mem.writeInt(u16, info[14..16], self.bpp, .little);
        std.mem.writeInt(u32, info[16..20], self.compression, .little);
        if (self.rle()) std.mem.writeInt(u32, info[20..24], rle_len, .little);
        std.mem.writeInt(u32, info[32..36], self.clr_used, .little);
        if (self.header >= 108) {
            std.mem.writeInt(u32, info[40..44], 0x00FF0000, .little);
            std.mem.writeInt(u32, info[44..48], 0x0000FF00, .little);
            std.mem.writeInt(u32, info[48..52], 0x000000FF, .little);
            std.mem.writeInt(u32, info[52..56], 0xFF000000, .little);
            std.mem.writeInt(u32, info[56..60], self.cs_type, .little);
        }
        return out;
    }

    /// The DIB for `bmp`, this bitmap's file, in `buf`: its header,
    /// widened to a BITMAPV5HEADER from a BITMAPV4HEADER, its table, then
    /// its bits with no gap.
    fn dib(self: TestBmp, bmp: []const u8, buf: []u8) []u8 {
        const header_len: usize = if (self.header == 40) 40 else 124;
        const table_at = 14 + self.header;
        const len = header_len + self.tableLen() + self.bitsLen();
        const out = buf[0..len];
        @memset(out[0..header_len], 0);
        @memcpy(out[0..self.header], bmp[14..table_at]);
        if (self.header == 108) {
            std.mem.writeInt(u32, out[0..4], 124, .little);
            std.mem.writeInt(u32, out[108..112], win32.LCS_GM_IMAGES, .little);
        }
        @memcpy(out[header_len..][0..self.tableLen()], bmp[table_at..][0..self.tableLen()]);
        @memcpy(out[header_len + self.tableLen() ..], bmp[self.offBits()..][0..self.bitsLen()]);
        return out;
    }

    fn clipboardFormat(self: TestBmp) win32.UINT {
        return if (self.header == 40) win32.CF_DIB else win32.CF_DIBV5;
    }
};

test "win32: clipboard writes read back, with invalid UTF-8 replaced" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    const Case = struct { text: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .text = "", .want = "" },
        .{ .text = "café \u{1F600}", .want = "café \u{1F600}" },
        // Latin-1 from a legacy program, as OSC 52 can deliver it.
        .{ .text = "abc\xe9", .want = "abc\u{FFFD}" },
    };
    for (cases) |c| {
        try writeClipboard(alloc, hwnd, .text(c.text));
        const got = (try readClipboardText(alloc, hwnd)) orelse
            return error.TestUnexpectedResult;
        defer alloc.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "win32: the clipboard takes each type in the order given, the text last, and each write replaces them all" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const html = registeredFormat(.html) orelse return error.TestUnexpectedResult;
    const png = registeredFormat(.png) orelse return error.TestUnexpectedResult;

    // Placed most descriptive first, which the program's order is taken
    // to be: a reader that takes the first format it knows takes the PNG.
    // The text goes last wherever it was. The system's own formats, made
    // from these, are not counted.
    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "text/plain", .data = "plain café" },
        .{ .mime = "image/png", .data = test_png },
        .{ .mime = "text/html", .data = "<div>rich café</div>" },
    }, false));
    try expectClipboard(hwnd, "plain café", "<div>rich café</div>");
    try std.testing.expect(try testHolds(hwnd, png, test_png));
    try std.testing.expect(try testHoldsPngDib(hwnd));
    {
        var buf: [32]win32.UINT = undefined;
        var ours: [4]win32.UINT = undefined;
        var len: usize = 0;
        for (try testFormats(hwnd, &buf)) |f| {
            if (f != png and f != win32.CF_DIBV5 and f != html and f != win32.CF_UNICODETEXT) continue;
            ours[len] = f;
            len += 1;
        }
        try std.testing.expectEqualSlices(
            win32.UINT,
            &.{ png, win32.CF_DIBV5, html, win32.CF_UNICODETEXT },
            ours[0..len],
        );
    }

    // The HTML alone, as a `copy_to_clipboard:html` writes it: the rest
    // before it go.
    try writeClipboard(alloc, hwnd, .of(&.{.{ .mime = "text/html", .data = "<div>only</div>" }}, false));
    try expectClipboard(hwnd, null, "<div>only</div>");
    try std.testing.expect(!win32.IsClipboardFormatAvailable(png).toBool());

    // The text alone: the HTML before it goes.
    try writeClipboard(alloc, hwnd, .text("text"));
    try expectClipboard(hwnd, "text", null);
}

test "win32: of two types the clipboard holds as one, the first is written" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    // Every name the core takes for text is one CF_UNICODETEXT.
    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "UTF8_STRING", .data = "first" },
        .{ .mime = "text/plain", .data = "second" },
        .{ .mime = text_mime, .data = "third" },
        .{ .mime = "text/html", .data = "<b>first</b>" },
        .{ .mime = "text/html", .data = "<b>second</b>" },
    }, false));
    try expectClipboard(hwnd, "first", "<b>first</b>");

    // A BMP's CF_DIBV5 and a PNG's: the first of them.
    var bmp_buf: [512]u8 = undefined;
    var dib_buf: [512]u8 = undefined;
    const v5: TestBmp = .{ .header = 124, .compression = win32.BI_BITFIELDS, .bpp = 32 };
    const bmp = v5.file(&bmp_buf);
    const dib = v5.dib(bmp, &dib_buf);
    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "image/png", .data = test_png },
        .{ .mime = "image/bmp", .data = bmp },
    }, false));
    try std.testing.expect(try testHoldsPngDib(hwnd));
    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "image/bmp", .data = bmp },
        .{ .mime = "image/png", .data = test_png },
    }, false));
    try std.testing.expect(try testHolds(hwnd, win32.CF_DIBV5, dib));
    try std.testing.expect(try testHolds(hwnd, registeredFormat(.png).?, test_png));
    try std.testing.expectEqual(0, test_held);
}

test "win32: a type Windows has no format for is left out and registers nothing, and a write of nothing else fails" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    const unknown = "application/x-kc";
    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = unknown, .data = "data" },
        .{ .mime = "text/plain", .data = "t" },
    }, false));
    try expectClipboard(hwnd, "t", null);
    var buf: [32]win32.UINT = undefined;
    for (try testFormats(hwnd, &buf)) |f| {
        var name: [256]u16 = undefined;
        const n = win32.GetClipboardFormatNameW(f, &name, name.len);
        // Zero for the predefined formats, which have no name.
        if (n <= 0) continue;
        try std.testing.expect(!std.mem.eql(
            u16,
            name[0..@intCast(n)],
            std.unicode.utf8ToUtf16LeStringLiteral(unknown),
        ));
    }

    // Nothing to write: refused before the clipboard is opened, so it
    // keeps what it had, and so for data that is not what its type says.
    try writeClipboard(alloc, hwnd, .text("kept"));
    try std.testing.expectEqual(0, (Reps.of(&.{.{ .mime = unknown, .data = "x" }}, false)).len);
    for ([_]Reps{
        .of(&.{.{ .mime = unknown, .data = "x" }}, false),
        .of(&.{}, false),
        .of(&.{
            .{ .mime = "image/png", .data = "not a png" },
            .{ .mime = "image/bmp", .data = "not a bmp" },
            .{ .mime = "text/rtf", .data = "not rtf" },
        }, false),
    }) |reps| {
        try std.testing.expectError(error.NothingWritable, writeClipboard(alloc, hwnd, reps));
        try expectClipboard(hwnd, "kept", null);
    }

    // After a prompt, the text alone.
    const asked: Reps = .of(&.{
        .{ .mime = "text/html", .data = "<b>h</b>" },
        .{ .mime = "text/plain", .data = "t" },
        .{ .mime = "image/png", .data = test_png },
    }, true);
    try std.testing.expectEqual(1, asked.len);
    try std.testing.expectEqual(Format.text, asked.slice()[0].format);
    try std.testing.expectEqualStrings("t", asked.slice()[0].data);
}

/// For tests: whether the clipboard holds the representation of `kind`
/// that `testAll` writes.
fn testHoldsKind(hwnd: win32.HWND, kind: Block.Kind, bmp: TestBmp, dib: []const u8) !bool {
    const alloc = std.testing.allocator;
    return switch (kind) {
        .text => text: {
            const got = (try readClipboardText(alloc, hwnd)) orelse break :text false;
            defer alloc.free(got);
            break :text std.mem.eql(u8, got, "t");
        },
        .html => html: {
            const got = (try readClipboardHtml(alloc, hwnd)) orelse break :html false;
            defer alloc.free(got);
            break :html std.mem.eql(u8, cfHtmlFragment(got) orelse "", "<b>h</b>");
        },
        .png => try testHolds(hwnd, registeredFormat(.png).?, test_png),
        .dibv5 => try testHoldsPngDib(hwnd),
        .dib => try testHolds(hwnd, bmp.clipboardFormat(), dib),
        .rtf => try testHolds(hwnd, registeredFormat(.rtf).?, "{\\rtf1 r}\x00"),
    };
}

test "win32: text that cannot be written fails the write, and any other type that cannot be is left out" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    defer test_fails = null;

    // One of every kind: a BITMAPINFOHEADER BMP makes CF_DIB, and the
    // PNG makes CF_DIBV5.
    const bmp: TestBmp = .{};
    var bmp_buf: [512]u8 = undefined;
    var dib_buf: [512]u8 = undefined;
    const bmp_file = bmp.file(&bmp_buf);
    const dib = bmp.dib(bmp_file, &dib_buf);
    const all: Reps = .of(&.{
        .{ .mime = "image/png", .data = test_png },
        .{ .mime = "text/html", .data = "<b>h</b>" },
        .{ .mime = "image/bmp", .data = bmp_file },
        .{ .mime = "text/rtf", .data = "{\\rtf1 r}" },
        .{ .mime = "text/plain", .data = "t" },
    }, false);

    try writeClipboard(alloc, hwnd, all);
    for (std.enums.values(Block.Kind)) |kind| try std.testing.expect(try testHoldsKind(hwnd, kind, bmp, dib));

    for (std.enums.values(Block.Kind)) |kind| for ([_]@FieldType(TestFail, "at"){ .make, .set }) |at| {
        const fail: TestFail = .{ .kind = kind, .at = at };
        errdefer std.debug.print("failing {t} at {t}\n", .{ kind, at });

        // With the others: no type without the text, but every other type
        // without the one.
        try writeClipboard(alloc, hwnd, .text("kept"));
        test_fails = fail;
        const with_all = writeClipboard(alloc, hwnd, all);
        test_fails = null;
        try std.testing.expectEqual(0, test_held);
        if (kind == .text) {
            try std.testing.expectError(App.Error.Win32CallFailed, with_all);
            // One that could not make its memory is refused before the
            // clipboard is emptied; one refused, after.
            switch (at) {
                .make => try expectClipboard(hwnd, "kept", null),
                .set => try expectClipboard(hwnd, null, null),
            }
            try std.testing.expect(!try testHoldsKind(hwnd, .png, bmp, dib));
            continue;
        }
        try with_all;
        for (std.enums.values(Block.Kind)) |other| {
            try std.testing.expectEqual(other != kind, try testHoldsKind(hwnd, other, bmp, dib));
        }

        // Alone, it fails. A PNG is not alone in its kinds: it makes the
        // other of its two.
        const only: Reps = switch (kind) {
            .text => unreachable,
            .html => .of(&.{.{ .mime = "text/html", .data = "<b>h</b>" }}, false),
            .dib => .of(&.{.{ .mime = "image/bmp", .data = bmp_file }}, false),
            .rtf => .of(&.{.{ .mime = "text/rtf", .data = "{\\rtf1 r}" }}, false),
            .png, .dibv5 => {
                try writeClipboard(alloc, hwnd, .text("kept"));
                test_fails = fail;
                try writeClipboard(alloc, hwnd, .of(&.{.{ .mime = "image/png", .data = test_png }}, false));
                test_fails = null;
                try std.testing.expectEqual(kind == .dibv5, try testHoldsKind(hwnd, .png, bmp, dib));
                try std.testing.expectEqual(kind == .png, try testHoldsKind(hwnd, .dibv5, bmp, dib));
                try expectClipboard(hwnd, null, null);
                continue;
            },
        };
        try writeClipboard(alloc, hwnd, .text("kept"));
        test_fails = fail;
        const alone = writeClipboard(alloc, hwnd, only);
        test_fails = null;
        switch (at) {
            .make => {
                try std.testing.expectError(error.NothingWritable, alone);
                try expectClipboard(hwnd, "kept", null);
            },
            .set => {
                try std.testing.expectError(App.Error.Win32CallFailed, alone);
                try expectClipboard(hwnd, null, null);
                try std.testing.expect(!try testHoldsKind(hwnd, kind, bmp, dib));
            },
        }
    };

    // Text that cannot be written alone fails, as with the others.
    for ([_]@FieldType(TestFail, "at"){ .make, .set }) |at| {
        try writeClipboard(alloc, hwnd, .text("kept"));
        test_fails = .{ .kind = .text, .at = at };
        const alone = writeClipboard(alloc, hwnd, .text("t"));
        test_fails = null;
        try std.testing.expectError(App.Error.Win32CallFailed, alone);
        switch (at) {
            .make => try expectClipboard(hwnd, "kept", null),
            .set => try expectClipboard(hwnd, null, null),
        }
    }
}

test "win32: a clipboard another thread holds open fails the write, which frees what it made" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    try writeClipboard(alloc, hwnd, .text("kept"));

    {
        const holder = try TestHolder.start();
        defer holder.release();
        try std.testing.expectError(
            App.Error.Win32CallFailed,
            writeClipboard(alloc, hwnd, .of(&.{
                .{ .mime = "text/plain", .data = "t" },
                .{ .mime = "text/html", .data = "<b>h</b>" },
                .{ .mime = "image/png", .data = test_png },
                .{ .mime = "text/rtf", .data = "{\\rtf1 r}" },
            }, false)),
        );
        try std.testing.expectEqual(0, test_held);
    }
    try expectClipboard(hwnd, "kept", null);
}

test "win32: HTML a program writes is UTF-8 without a NUL, and is left out if it marks a fragment" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    const Case = struct { html: [:0]const u8, want: ?[]const u8 };
    const cases = [_]Case{
        // Bytes that are not UTF-8 become U+FFFD as the text's do.
        .{ .html = "<b>abc\xe9</b>", .want = "<b>abc\u{FFFD}</b>" },
        .{ .html = "<b>\xed\xa0\x80</b>", .want = null },
        // A NUL would end the data for readers that look for one.
        .{ .html = "<b>a\x00b</b>", .want = "<b>a\u{FFFD}b</b>" },
        .{ .html = "\x00", .want = "\u{FFFD}" },
        .{ .html = "<b>\xff\x00</b>", .want = "<b>\u{FFFD}\u{FFFD}</b>" },
        // A marker in any spelling a reader may take refuses the HTML.
        .{ .html = "<b>x</b><!--EndFragment-->", .want = null },
        .{ .html = "<!-- endfragment --><b>x</b>", .want = null },
        .{ .html = "<b>x</b><!--StartFragment -->", .want = null },
        .{ .html = "<!--\tSTARTFRAGMENT\r\n-->", .want = null },
        // Comments that are not markers are kept as they are.
        .{ .html = "<!-- StartFragments --><b>x</b>", .want = "<!-- StartFragments --><b>x</b>" },
        .{ .html = "<!--Start Fragment--><!--EndFragment->", .want = "<!--Start Fragment--><!--EndFragment->" },
        .{ .html = "<!--<!--endfragment", .want = "<!--<!--endfragment" },
        // A copy's HTML, which is ASCII with entities, as it is.
        .{
            .html = "<div style=\"font-family: monospace; white-space: pre;\">a&lt;b x&#233;</div>",
            .want = "<div style=\"font-family: monospace; white-space: pre;\">a&lt;b x&#233;</div>",
        },
    };
    for (cases) |c| {
        errdefer std.debug.print("html={f}\n", .{std.zig.fmtString(c.html)});
        try writeClipboard(alloc, hwnd, .of(&.{
            .{ .mime = "text/html", .data = c.html },
            .{ .mime = "text/plain", .data = "t" },
        }, false));
        if (c.want) |want| {
            try expectClipboard(hwnd, "t", want);
        } else if (std.unicode.utf8ValidateSlice(c.html)) {
            try expectClipboard(hwnd, "t", null);
        } else {
            // A sequence MultiByteToWideChar replaces in its own way: only
            // that it is valid UTF-8 now, ending where the HTML ends.
            const got = (try readClipboardHtml(alloc, hwnd)) orelse return error.TestUnexpectedResult;
            defer alloc.free(got);
            const fragment = cfHtmlFragment(got) orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.unicode.utf8ValidateSlice(fragment));
            try std.testing.expect(std.mem.endsWith(u8, fragment, "</b>"));
        }
    }
}

test "win32: HTML that needs no change is not copied" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", "<b>café</b>", "<!-- a -->" }) |html| {
        try std.testing.expect(try cleanHtml(alloc, html) == null);
    }
    try std.testing.expect(!hasFragmentMarker("<!--"));
    try std.testing.expect(!hasFragmentMarker("<!--startfragment"));
    try std.testing.expect(hasFragmentMarker("<!---->x<!--StartFragment-->"));
    try std.testing.expect(hasFragmentMarker("<!--\x0bendFRAGMENT\x0c-->"));
}

test "win32: a PNG goes as it is, with a DIB of its pixels unless it is too large or cannot be decoded" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const png = registeredFormat(.png) orelse return error.TestUnexpectedResult;

    try writeClipboard(alloc, hwnd, .of(&.{.{ .mime = "image/png", .data = test_png }}, false));
    try std.testing.expect(try testHolds(hwnd, png, test_png));
    try std.testing.expect(try testHoldsPngDib(hwnd));

    // The header says 4096x4096, whose pixels take all a write may: the
    // PNG goes without decoding, as it is.
    var large = test_png.*;
    std.mem.writeInt(u32, large[16..20], 4096, .big);
    std.mem.writeInt(u32, large[20..24], 4096, .big);
    try std.testing.expect(4096 * 4096 * 4 == max_write_size);
    // A PNG whose data cannot be decoded.
    var broken = test_png.*;
    @memset(broken[41..60], 0xAA);
    for ([_][:0]const u8{ &large, &broken }) |data| {
        try writeClipboard(alloc, hwnd, .of(&.{.{ .mime = "image/png", .data = data }}, false));
        try std.testing.expect(try testHolds(hwnd, png, data));
        try std.testing.expect(!win32.IsClipboardFormatAvailable(win32.CF_DIBV5).toBool());
        try std.testing.expectEqual(0, test_held);
    }

    // The bound is a write's whole size, not one byte under it.
    try std.testing.expectEqual(16, dibBitsLen(.{ .width = 2, .height = 2 }));
    try std.testing.expect(dibBitsLen(.{ .width = 4096, .height = 4096 }) == null);
    try std.testing.expectEqual(4096 * 4095 * 4, dibBitsLen(.{ .width = 4096, .height = 4095 }));
    try std.testing.expect(dibBitsLen(.{ .width = 1, .height = max_write_size / 4 }) == null);
    try std.testing.expectEqual(max_write_size - 4, dibBitsLen(.{ .width = 1, .height = max_write_size / 4 - 1 }));
    try std.testing.expect(dibBitsLen(.{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }) == null);

    try std.testing.expectEqual(PngSize{ .width = 2, .height = 2 }, pngSize(test_png).?);
    for ([_][]const u8{
        "",
        test_png[0..23],
        "\x89PNG\r\n\x1a\x0a" ++ test_png[8..],
        test_png[0..8] ++ "\x00\x00\x00\x0c" ++ test_png[12..],
        test_png[0..12] ++ "IHDX" ++ test_png[16..],
        test_png[0..16] ++ "\x00\x00\x00\x00" ++ test_png[20..],
        test_png[0..20] ++ "\x00\x00\x00\x00" ++ test_png[24..],
    }) |data| {
        if (std.mem.eql(u8, data, test_png)) continue;
        try std.testing.expect(pngSize(data) == null);
    }
}

test "win32: a PNG's picture is its pixels over the background, top down" {
    const alloc = std.testing.allocator;
    // RGB(10, 20, 30).
    const p = picture(alloc, test_png, 0x001E140A) orelse return error.TestUnexpectedResult;
    defer p.deinit(alloc);
    try std.testing.expectEqual(2, p.width);
    try std.testing.expectEqual(2, p.height);
    try std.testing.expectEqual(@sizeOf(win32.BITMAPINFOHEADER), p.info.len);
    const header = std.mem.bytesToValue(win32.BITMAPINFOHEADER, p.info[0..@sizeOf(win32.BITMAPINFOHEADER)]);
    try std.testing.expectEqual(40, header.biSize);
    try std.testing.expectEqual(2, header.biWidth);
    try std.testing.expectEqual(-2, header.biHeight);
    try std.testing.expectEqual(1, header.biPlanes);
    try std.testing.expectEqual(32, header.biBitCount);
    try std.testing.expectEqual(win32.BI_RGB, header.biCompression);
    // Blue, green, red: opaque red as it is, green at 128 halfway over the
    // background, transparent blue the background, and (16, 32, 48) at 64
    // a quarter of the way.
    try std.testing.expectEqualSlices(u8, &.{
        0,  0,  255, 0, 15, 138, 5,  0,
        30, 20, 10,  0, 35, 23,  12, 0,
    }, p.bits);
}

test "win32: a picture is never made of what is too large, nor decoded to find out" {
    // The header says 4096x4096, whose pixels take all a write may.
    var large = test_png.*;
    std.mem.writeInt(u32, large[16..20], 4096, .big);
    std.mem.writeInt(u32, large[20..24], 4096, .big);
    var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    try std.testing.expect(picture(counting.allocator(), &large, 0) == null);
    try std.testing.expectEqual(0, counting.allocations);

    // An RLE bitmap's bits are short whatever its size, but GDI makes
    // all its pixels to draw it.
    var buf: [256]u8 = undefined;
    const rle: TestBmp = .{ .bpp = 8, .compression = win32.BI_RLE8, .clr_used = 2 };
    const bmp = rle.file(&buf);
    std.mem.writeInt(i32, bmp[18..22], 5000, .little);
    std.mem.writeInt(i32, bmp[22..26], 5000, .little);
    try std.testing.expect(picture(counting.allocator(), bmp, 0) == null);
    try std.testing.expectEqual(0, counting.allocations);
    // The bound is a write's whole size, as for a PNG (`dibBitsLen`).
    std.mem.writeInt(i32, bmp[22..26], 3356, .little);
    try std.testing.expect(5000 * 3356 * 4 >= max_write_size);
    try std.testing.expect(picture(counting.allocator(), bmp, 0) == null);
    try std.testing.expectEqual(0, counting.allocations);
    std.mem.writeInt(i32, bmp[22..26], 3355, .little);
    try std.testing.expect(5000 * 3355 * 4 < max_write_size);
    const p = picture(counting.allocator(), bmp, 0) orelse return error.TestUnexpectedResult;
    p.deinit(counting.allocator());
}

test "win32: a BMP's picture is its header, table and bits, without the file's gap" {
    const alloc = std.testing.allocator;
    var buf: [1200]u8 = undefined;
    for ([_]TestBmp{
        .{},
        .{ .bpp = 8, .gap = 3 },
        .{ .header = 124, .bpp = 32, .compression = win32.BI_BITFIELDS, .height = -2 },
        .{ .bpp = 4, .compression = win32.BI_RLE4, .clr_used = 3 },
    }) |t| {
        const bmp = t.file(&buf);
        const p = picture(alloc, bmp, 0) orelse return error.TestUnexpectedResult;
        defer p.deinit(alloc);
        const table_end = 14 + t.header + t.tableLen();
        try std.testing.expectEqualSlices(u8, bmp[14..table_end], p.info);
        try std.testing.expectEqualSlices(u8, bmp[t.offBits()..][0..t.bitsLen()], p.bits);
        try std.testing.expectEqual(TestBmp.width, p.width);
        try std.testing.expectEqual(2, p.height);
    }
}

test "win32: only a PNG or BMP that can be read is a picture" {
    const alloc = std.testing.allocator;
    var broken = test_png.*;
    @memset(broken[41..60], 0xAA);
    var buf: [256]u8 = undefined;
    const profile = (TestBmp{ .header = 124, .cs_type = win32.PROFILE_EMBEDDED }).file(&buf);
    for ([_][]const u8{ "", "text", "BM", &broken, test_png[0..30], profile }) |data| {
        try std.testing.expect(picture(alloc, data, 0) == null);
    }
}

test "win32: RTF goes as it is, with a NUL after it, and only if it starts as RTF does" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const rtf = registeredFormat(.rtf) orelse return error.TestUnexpectedResult;

    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "text/rtf", .data = "{\\rtf1\\ansi hi}" },
        .{ .mime = "text/plain", .data = "t" },
    }, false));
    try std.testing.expect(try testHolds(hwnd, rtf, "{\\rtf1\\ansi hi}\x00"));
    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "text/rtf", .data = "hi" },
        .{ .mime = "text/plain", .data = "t" },
    }, false));
    try std.testing.expect(!win32.IsClipboardFormatAvailable(rtf).toBool());
    try expectClipboard(hwnd, "t", null);
}

test "win32: a BMP is written as the DIB inside it, its bits after its table" {
    const alloc = std.testing.allocator;
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    for ([_]TestBmp{
        .{},
        .{ .gap = 5 },
        .{ .height = -2 },
        .{ .bpp = 1 },
        // As many colors as the depth has.
        .{ .bpp = 1, .clr_used = 2 },
        .{ .bpp = 4, .clr_used = 3 },
        .{ .bpp = 8 },
        .{ .bpp = 8, .clr_used = 2 },
        .{ .bpp = 16 },
        .{ .bpp = 32, .clr_used = 2 },
        .{ .compression = win32.BI_BITFIELDS, .bpp = 32 },
        .{ .compression = win32.BI_BITFIELDS, .bpp = 16, .gap = 3 },
        .{ .compression = win32.BI_RLE8, .bpp = 8, .clr_used = 4 },
        .{ .compression = win32.BI_RLE4, .bpp = 4 },
        .{ .header = 108, .compression = win32.BI_BITFIELDS, .bpp = 32 },
        .{ .header = 124, .compression = win32.BI_BITFIELDS, .bpp = 32 },
        .{ .header = 124, .bpp = 8, .clr_used = 2, .gap = 2 },
    }) |bmp| {
        errdefer std.debug.print("bmp={any}\n", .{bmp});
        var bmp_buf: [2048]u8 = undefined;
        var dib_buf: [2048]u8 = undefined;
        const file = bmp.file(&bmp_buf);
        const dib = bmp.dib(file, &dib_buf);
        try writeClipboard(alloc, hwnd, .of(&.{.{ .mime = "image/bmp", .data = file }}, false));
        try std.testing.expect(try testHolds(hwnd, bmp.clipboardFormat(), dib));
        try std.testing.expectEqual(0, test_held);

        // Read back, the DIB the clipboard holds after a file header whose
        // offset finds the bits written: the very file written, when it
        // left no gap and its header was not widened.
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const found = try readClipboard(arena.allocator(), hwnd, &.{"image/bmp"}, false);
        try std.testing.expectEqual(1, found.contents().len);
        const read = found.contents()[0].data;
        try std.testing.expectEqualStrings("BM", read[0..2]);
        try std.testing.expectEqual(read.len, std.mem.readInt(u32, read[2..6], .little));
        try std.testing.expectEqualSlices(u8, dib, read[14..]);
        try std.testing.expectEqualSlices(u8, (try dibOfBmp(file)).bits, (try dibOfBmp(read)).bits);
        if (bmp.gap == 0 and bmp.header != 108) try std.testing.expectEqualSlices(u8, file, read);
    }

    // A DIB block longer than its DIB, as GlobalSize can give one, reads as
    // the DIB alone.
    {
        const bmp: TestBmp = .{ .bpp = 8, .clr_used = 2 };
        var bmp_buf: [2048]u8 = undefined;
        var dib_buf: [2048]u8 = undefined;
        const file = bmp.file(&bmp_buf);
        const dib = bmp.dib(file, &dib_buf);
        var long_buf: [2048]u8 = undefined;
        const long = long_buf[0 .. dib.len + 5];
        @memcpy(long[0..dib.len], dib);
        @memcpy(long[dib.len..], "junk!");
        try testPut(hwnd, &.{.{ .format = win32.CF_DIB, .data = long }}, &.{});
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const found = try readClipboard(arena.allocator(), hwnd, &.{"image/bmp"}, false);
        try expectServed(&found, &.{.{ .mime = "image/bmp", .data = file }});
    }

    // Refused: each a well-formed file with one thing wrong, refused for
    // that and not for something it leads to.
    var buf: [2048]u8 = undefined;
    const Wrong = struct { bmp: TestBmp = .{}, at: usize = 0, bytes: []const u8 = "", cut: usize = 0, err: DibError };
    for ([_]Wrong{
        .{ .at = 0, .bytes = "MB", .err = error.NotBmp },
        .{ .at = 14, .bytes = "\x0c\x00\x00\x00", .err = error.UnknownHeader },
        .{ .at = 14, .bytes = "\x38\x00\x00\x00", .err = error.UnknownHeader },
        .{ .at = 14, .bytes = "\x40\x00\x00\x00", .err = error.UnknownHeader },
        // Width 0, height 0, height minInt, 2 planes.
        .{ .at = 18, .bytes = "\x00\x00\x00\x00", .err = error.NotBitmap },
        .{ .at = 22, .bytes = "\x00\x00\x00\x00", .err = error.NotBitmap },
        .{ .at = 22, .bytes = "\x00\x00\x00\x80", .err = error.NotBitmap },
        .{ .at = 26, .bytes = "\x02\x00", .err = error.NotBitmap },
        // Depths no compression takes, and JPEG.
        .{ .at = 28, .bytes = "\x02\x00", .err = error.UnsupportedCompression },
        .{ .bmp = .{ .compression = win32.BI_BITFIELDS, .bpp = 32 }, .at = 28, .bytes = "\x18\x00", .err = error.UnsupportedCompression },
        .{ .at = 30, .bytes = "\x04\x00\x00\x00", .err = error.UnsupportedCompression },
        // A top-down RLE bitmap, and one with no size.
        .{ .bmp = .{ .compression = win32.BI_RLE8, .bpp = 8 }, .at = 22, .bytes = "\xfe\xff\xff\xff", .err = error.UnsupportedCompression },
        .{ .bmp = .{ .compression = win32.BI_RLE8, .bpp = 8 }, .at = 34, .bytes = "\x00\x00\x00\x00", .err = error.NoBitsSize },
        // One color more than the depth has, its table and bits where
        // they would be.
        .{ .bmp = .{ .bpp = 1, .clr_used = 3 }, .err = error.TooManyColors },
        // Bits that start inside the header, and bits cut short.
        .{ .at = 10, .bytes = "\x35\x00\x00\x00", .err = error.BitsInHeader },
        .{ .cut = 1, .err = error.BitsCutShort },
        // A color profile.
        .{ .bmp = .{ .header = 124, .compression = win32.BI_BITFIELDS, .bpp = 32, .cs_type = win32.PROFILE_EMBEDDED }, .err = error.ColorProfile },
        .{ .bmp = .{ .header = 108, .compression = win32.BI_BITFIELDS, .bpp = 32, .cs_type = win32.PROFILE_LINKED }, .err = error.ColorProfile },
        // A header longer than the file.
        .{ .bmp = .{ .header = 124, .compression = win32.BI_BITFIELDS, .bpp = 32 }, .cut = 100, .err = error.HeaderCutShort },
    }) |w| {
        errdefer std.debug.print("wrong={any}\n", .{w});
        const file = w.bmp.file(&buf);
        @memcpy(file[w.at..][0..w.bytes.len], w.bytes);
        try std.testing.expectError(w.err, dibOfBmp(file[0 .. file.len - w.cut]));
    }
    // And files too short to have the headers.
    const short: [53]u8 = @splat(0);
    for ([_]struct { []const u8, DibError }{
        .{ "", error.NotBmp },
        .{ "BM", error.NotBmp },
        .{ "BM" ++ short[2..], error.HeaderCutShort },
    }) |c| {
        try std.testing.expectError(c[1], dibOfBmp(c[0]));
    }
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

test "win32: a read serves each type the clipboard holds once, in the order asked, and lists each once, the text first" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    try writeClipboard(alloc, hwnd, .of(&.{
        .{ .mime = "text/html", .data = "<b>h</b>" },
        .{ .mime = "image/png", .data = test_png },
        .{ .mime = "text/rtf", .data = "{\\rtf1 r}" },
        .{ .mime = "text/plain", .data = "t\u{e9}" },
    }, false));

    // Two names for the text, which is one format and read once, and a
    // type the clipboard does not hold.
    const first = try readClipboard(arena.allocator(), hwnd, &.{ "image/png", "UTF8_STRING", "image/gif", "text/plain" }, true);
    try expectServed(&first, &.{
        .{ .mime = "image/png", .data = test_png },
        .{ .mime = "text/plain", .data = "t\u{e9}" },
    });
    // CF_DIBV5 and the CF_DIB Windows makes of it are one type.
    try expectListed(&first, &.{ "text/plain", "text/html", "image/png", "image/bmp", "text/rtf" });

    // The text by another of its names alone, which serves it too.
    const alias = try readClipboard(arena.allocator(), hwnd, &.{"UTF8_STRING"}, false);
    try expectServed(&alias, &.{.{ .mime = "text/plain", .data = "t\u{e9}" }});

    // The HTML's fragment, the RTF as far as its NUL, and the DIB as a BMP
    // file; no listing unasked.
    const second = try readClipboard(arena.allocator(), hwnd, &.{ "text/rtf", "image/bmp", "text/html" }, false);
    try std.testing.expectEqual(0, second.available().len);
    const dibv5 = (try testData(alloc, hwnd, win32.CF_DIBV5)).?;
    defer alloc.free(dibv5);
    const dib = dibv5[0 .. @sizeOf(win32.BITMAPV5HEADER) + 2 * 2 * 4];
    var bmp_buf: [256]u8 = undefined;
    const bmp = bmp_buf[0 .. 14 + dib.len];
    @memcpy(bmp[0..2], "BM");
    std.mem.writeInt(u32, bmp[2..6], @intCast(bmp.len), .little);
    @memset(bmp[6..10], 0);
    std.mem.writeInt(u32, bmp[10..14], 14 + @sizeOf(win32.BITMAPV5HEADER), .little);
    @memcpy(bmp[14..], dib);
    try expectServed(&second, &.{
        .{ .mime = "text/rtf", .data = "{\\rtf1 r}" },
        .{ .mime = "image/bmp", .data = bmp },
        .{ .mime = "text/html", .data = "<b>h</b>" },
    });
}

test "win32: a read lists only MIME types, none twice, the formats it maps from no other, at most sixteen" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const u = std.unicode.utf8ToUtf16LeStringLiteral;

    var many: [20]TestPut = undefined;
    inline for (&many, 0..) |*p, i| p.* = .{
        .format = try testRegister(u(std.fmt.comptimePrint("application/x-kc-{d:0>2}", .{i}))),
        .data = "x",
    };
    // Not MIME types: a space, a letter outside ASCII, no slash, and a
    // first character a type cannot start with. Then names of types the
    // read makes from other formats, registered by another program.
    const others = [_]TestPut{
        .{ .format = try testRegister(u("Ghostty Test Format")), .data = "x" },
        .{ .format = try testRegister(u("application/x-kc\u{e7}")), .data = "x" },
        .{ .format = try testRegister(u("x-kc")), .data = "x" },
        .{ .format = try testRegister(u("-x/kc")), .data = "x" },
        .{ .format = try testRegister(u("image/png")), .data = test_png },
        .{ .format = try testRegister(u("text/plain")), .data = "x" },
        .{ .format = try testRegister(u("text/uri-list")), .data = "x" },
    };
    const text: TestPut = .{ .format = win32.CF_UNICODETEXT, .data = std.mem.sliceAsBytes(u("t")) };

    // The text first, though placed last, then the first fifteen others.
    try testPut(hwnd, &(others ++ many ++ [_]TestPut{text}), &.{});
    const capped = try readClipboard(arena.allocator(), hwnd, &.{}, true);
    var want: [16][]const u8 = undefined;
    want[0] = "text/plain";
    inline for (want[1..], 0..) |*w, i| w.* = std.fmt.comptimePrint("application/x-kc-{d:0>2}", .{i});
    try expectListed(&capped, &want);

    // A registered MIME type is read as it is, as long as GlobalSize says;
    // those the read makes from other formats are not read from these.
    try testPut(hwnd, &(others ++ many[0..1].*), &.{});
    const found = try readClipboard(arena.allocator(), hwnd, &.{ "image/png", "application/x-kc-00", "text/plain", "text/uri-list" }, true);
    try expectListed(&found, &.{"application/x-kc-00"});
    try std.testing.expectEqual(1, found.contents().len);
    try std.testing.expectEqualStrings("application/x-kc-00", found.contents()[0].mime);
    try std.testing.expect(std.mem.startsWith(u8, found.contents()[0].data, "x"));
}

test "win32: a read registers no name a program asks for" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);

    // A name no run has asked for, so none can have registered it.
    var counter: i64 = 0;
    _ = win32.QueryPerformanceCounter(&counter);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "application/x-kc-unregistered-{d}", .{counter});

    // The check finds a name registered and not on the clipboard.
    _ = try testRegister(std.unicode.utf8ToUtf16LeStringLiteral("application/x-kc-00"));
    try writeClipboard(alloc, hwnd, .text("t"));
    try std.testing.expect(testRegistered("application/x-kc-00"));

    try std.testing.expect(!testRegistered(name));
    const found = try readClipboard(arena.allocator(), hwnd, &.{ name, "text/plain" }, true);
    try std.testing.expect(!testRegistered(name));
    try expectServed(&found, &.{.{ .mime = "text/plain", .data = "t" }});
}

test "win32: a read of a clipboard another thread holds open fails" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    try writeClipboard(alloc, hwnd, .text("t"));

    // Five tries, so four waits between them: what a clipboard held
    // throughout costs.
    const waits = struct {
        var n: usize = 0;
        fn count() void {
            n += 1;
        }
    };
    {
        const holder = try TestHolder.start();
        defer holder.release();
        waits.n = 0;
        test_busy = &waits.count;
        defer test_busy = null;
        try std.testing.expectError(
            App.Error.Win32CallFailed,
            readClipboard(arena.allocator(), hwnd, &.{"text/plain"}, true),
        );
        try std.testing.expectEqual(4, waits.n);
    }
    const found = try readClipboard(arena.allocator(), hwnd, &.{"text/plain"}, true);
    try expectServed(&found, &.{.{ .mime = "text/plain", .data = "t" }});
}

test "win32: a clipboard another program holds for a moment is read and written once it lets go" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    try writeClipboard(alloc, hwnd, .text("t"));

    // Each finds the clipboard held at its first try, and the holder lets
    // go when it waits to try again.
    {
        const holder = try TestHolder.start();
        defer holder.release();
        test_busy = &TestHolder.letGo;
        defer test_busy = null;
        const found = try readClipboard(arena.allocator(), hwnd, &.{"text/plain"}, true);
        try expectServed(&found, &.{.{ .mime = "text/plain", .data = "t" }});
    }
    {
        const holder = try TestHolder.start();
        defer holder.release();
        test_busy = &TestHolder.letGo;
        defer test_busy = null;
        try writeClipboard(alloc, hwnd, .text("w"));
        try std.testing.expectEqual(0, test_held);
    }
    {
        const holder = try TestHolder.start();
        defer holder.release();
        test_busy = &TestHolder.letGo;
        defer test_busy = null;
        const text = (try readClipboardText(alloc, hwnd)) orelse return error.TestUnexpectedResult;
        defer alloc.free(text);
        try std.testing.expectEqualStrings("w", text);
    }
}

test "win32: a read leaves out a type larger than a program may write, and still lists it" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    defer test_read_cap = max_write_size;

    const Case = struct { cap: usize, mime: [:0]const u8, data: [:0]const u8, kept: bool };
    var bmp_buf: [2048]u8 = undefined;
    const bmp = (TestBmp{}).file(&bmp_buf);
    for ([_]Case{
        // Text by its UTF-8: four bytes of four units, or of two.
        .{ .cap = 4, .mime = "text/plain", .data = "abcd", .kept = true },
        .{ .cap = 4, .mime = "text/plain", .data = "abcde", .kept = false },
        .{ .cap = 4, .mime = "text/plain", .data = "\u{e9}\u{e9}", .kept = true },
        .{ .cap = 4, .mime = "text/plain", .data = "\u{e9}\u{e9}\u{e9}", .kept = false },
        .{ .cap = test_png.len, .mime = "image/png", .data = test_png, .kept = true },
        .{ .cap = test_png.len - 1, .mime = "image/png", .data = test_png, .kept = false },
        // A BMP by its file, header and all.
        .{ .cap = bmp.len, .mime = "image/bmp", .data = bmp, .kept = true },
        .{ .cap = bmp.len - 1, .mime = "image/bmp", .data = bmp, .kept = false },
    }) |c| {
        errdefer std.debug.print("case={any}\n", .{c});
        test_read_cap = max_write_size;
        try writeClipboard(alloc, hwnd, .of(&.{.{ .mime = c.mime, .data = c.data }}, false));
        test_read_cap = c.cap;
        const found = try readClipboard(arena.allocator(), hwnd, &.{c.mime}, true);
        try std.testing.expectEqualStrings(c.mime, found.available()[0]);
        if (c.kept) {
            try expectServed(&found, &.{.{ .mime = c.mime, .data = c.data }});
        } else try std.testing.expectEqual(0, found.contents().len);
    }

    // A file list by its URIs: one line of 14 bytes.
    for ([_]struct { usize, bool }{ .{ 14, true }, .{ 13, false } }) |c| {
        test_read_cap = max_write_size;
        try testPut(hwnd, &.{}, &.{std.unicode.utf8ToUtf16LeStringLiteral("C:\\a")});
        test_read_cap = c[0];
        const found = try readClipboard(arena.allocator(), hwnd, &.{"text/uri-list"}, false);
        if (c[1]) {
            try expectServed(&found, &.{.{ .mime = "text/uri-list", .data = "file:///C:/a\r\n" }});
        } else try std.testing.expectEqual(0, found.contents().len);
    }
}

test "win32: a file list reads as file URIs, escaped, each line ended by CRLF" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const u = std.unicode.utf8ToUtf16LeStringLiteral;

    // An unpaired surrogate, which NTFS allows in a name; paths that are
    // not absolute, or name no host.
    const bad = [_]u16{ 'C', ':', '\\', 0xD800 };
    try testPut(hwnd, &.{}, &.{
        u("C:\\a b\\\u{fc}#%~.txt"),
        &bad,
        u("\\\\srv\\share\\x y"),
        u("relative\\x"),
        u("\\\\?\\C:\\long"),
        u("\\\\\\x"),
        u("\\\\?\\UNC\\srv\\s\\z"),
        u("C:x"),
    });
    const found = try readClipboard(arena.allocator(), hwnd, &.{"text/uri-list"}, true);
    try expectListed(&found, &.{"text/uri-list"});
    try expectServed(&found, &.{.{
        .mime = "text/uri-list",
        .data = "file:///C:/a%20b/%C3%BC%23%25~.txt\r\n" ++
            "file://srv/share/x%20y\r\n" ++
            "file:///C:/long\r\n" ++
            "file://srv/s/z\r\n",
    }});

    // None it can name: listed, and not served.
    try testPut(hwnd, &.{}, &.{ &bad, u("relative") });
    const none = try readClipboard(arena.allocator(), hwnd, &.{"text/uri-list"}, true);
    try expectListed(&none, &.{"text/uri-list"});
    try std.testing.expectEqual(0, none.contents().len);
}

test "win32: a read of HTML takes its fragment, else its document, as far as its NUL" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const html = registeredFormat(.html).?;

    var written_buf: [256]u8 = undefined;
    const written = written_buf[0 .. cfHtmlLen(8).? + 5];
    cfHtml(written[0 .. written.len - 5], "<i>f</i>");
    @memcpy(written[written.len - 5 ..], "\x00<x>y");

    const head = "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\n";
    const head_len = std.fmt.comptimePrint(head, .{ 0, 0 }).len;
    const doc = "<p>d</p>";
    const no_fragment = std.fmt.comptimePrint(head, .{ head_len, head_len + doc.len }) ++ doc;
    const frag_head = head ++ "StartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n";
    const frag_len = std.fmt.comptimePrint(frag_head, .{ 0, 0, 0, 0 }).len;
    const outside = std.fmt.comptimePrint(frag_head, .{ frag_len, frag_len + doc.len, frag_len, 999 }) ++ doc;
    // A document whose end is past the NUL that ends the data.
    const cut = std.fmt.comptimePrint(head, .{ head_len, head_len + doc.len }) ++ "<p>\x00d</p>";

    for ([_]struct { []const u8, ?[]const u8 }{
        .{ written, "<i>f</i>" },
        .{ no_fragment, doc },
        .{ outside, doc },
        .{ cut, null },
        .{ "Version:0.9\r\n<b>x</b>", null },
    }) |c| {
        errdefer std.debug.print("html={f}\n", .{std.zig.fmtString(c[0])});
        try testPut(hwnd, &.{.{ .format = html, .data = c[0] }}, &.{});
        const found = try readClipboard(arena.allocator(), hwnd, &.{"text/html"}, true);
        try expectListed(&found, &.{"text/html"});
        if (c[1]) |want| {
            try expectServed(&found, &.{.{ .mime = "text/html", .data = want }});
        } else try std.testing.expectEqual(0, found.contents().len);
    }
}

test "win32: a read of PNG ends at its IEND chunk, and is left out if it is not a PNG's chunks" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const hwnd = try testOwner();
    defer _ = win32.DestroyWindow(hwnd);
    const saved = try TestSaved.save(hwnd);
    defer saved.restore(hwnd);
    const png = registeredFormat(.png).?;

    const iend = test_png.len - 12;
    var huge: [test_png.len]u8 = test_png.*;
    std.mem.writeInt(u32, huge[iend..][0..4], 0xFFFFFFFF, .big);
    for ([_]struct { []const u8, bool }{
        .{ test_png ++ "junk", true },
        .{ test_png, true },
        .{ "not a png", false },
        .{ test_png[0 .. test_png.len - 1], false },
        .{ test_png[0..iend], false },
        .{ &huge, false },
    }) |c| {
        errdefer std.debug.print("png={f}\n", .{std.zig.fmtString(c[0])});
        try testPut(hwnd, &.{.{ .format = png, .data = c[0] }}, &.{});
        const found = try readClipboard(arena.allocator(), hwnd, &.{"image/png"}, true);
        try expectListed(&found, &.{"image/png"});
        if (c[1]) {
            try expectServed(&found, &.{.{ .mime = "image/png", .data = test_png }});
        } else try std.testing.expectEqual(0, found.contents().len);
    }
}
