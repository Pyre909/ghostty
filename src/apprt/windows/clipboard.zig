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

const log = std.log.scoped(.win32);

/// The most a program may write in one Kitty clipboard transaction. A PNG
/// whose pixels would take as much gets no DIB beside it.
const max_write_size = terminal.kitty.clipboard.max_write_size;

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

/// A clipboard format this runtime writes, by the MIME type a program names
/// it with (`formatOf`).
pub const Format = enum { text, html, png, bmp, rtf };

/// The format `mime` is written as; null if Windows has none this runtime
/// writes. Text takes every name the core treats as text. Writing other
/// types under their MIME names would register each name for the rest of
/// the session, in an atom table every program shares
/// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/about-atom-tables).
fn formatOf(mime: []const u8) ?Format {
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
            },
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

    if (!win32.OpenClipboard(hwnd).toBool()) {
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

/// The parts of a BMP file's DIB (`dibOfBmp`).
const Dib = struct {
    /// CF_DIB for a BITMAPINFOHEADER, CF_DIBV5 for a BITMAPV4HEADER or a
    /// BITMAPV5HEADER, as each format's page names its header
    /// (standard-clipboard-formats).
    kind: Block.Kind,
    /// The info header as the file has it.
    header: []const u8,
    /// The masks after a BITMAPINFOHEADER, then the color table.
    table: []const u8,
    bits: []const u8,
};

/// The DIB inside a BMP file
/// (https://learn.microsoft.com/en-us/windows/win32/gdi/bitmap-storage):
/// the 14-byte BITMAPFILEHEADER, whose bfOffBits is the offset of the bits
/// from the file's start, then the info header with its masks and color
/// table. A clipboard DIB has the bits right after the table, so the gap
/// the file may leave before them is not copied. Null, logged, for what
/// this runtime does not write: another header, a compression or depth a
/// DIB cannot hold, a color profile (the file keeps it apart from the
/// header, past the bits), or bits the file does not hold.
fn dibOfBmp(bmp: []const u8) ?Dib {
    const refuse = struct {
        fn refuse(comptime why: []const u8) ?Dib {
            log.info("clipboard BMP left out: " ++ why, .{});
            return null;
        }
    }.refuse;
    const file_header_len = 14;
    if (bmp.len < file_header_len + 40 or !std.mem.startsWith(u8, bmp, "BM")) return refuse("not a BMP file");
    const off_bits = std.mem.readInt(u32, bmp[10..14], .little);
    const info = bmp[file_header_len..];

    // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader,
    // whose fields start the later headers too.
    const size = std.mem.readInt(u32, info[0..4], .little);
    const kind: Block.Kind = switch (size) {
        40 => .dib,
        108, 124 => .dibv5,
        else => return refuse("an info header Windows has no clipboard format for"),
    };
    if (info.len < size) return refuse("its header is cut short");
    const width = std.mem.readInt(i32, info[4..8], .little);
    const height = std.mem.readInt(i32, info[8..12], .little);
    const planes = std.mem.readInt(u16, info[12..14], .little);
    const bpp = std.mem.readInt(u16, info[14..16], .little);
    const compression = std.mem.readInt(u32, info[16..20], .little);
    const size_image = std.mem.readInt(u32, info[20..24], .little);
    const clr_used = std.mem.readInt(u32, info[32..36], .little);
    if (width <= 0 or height == 0 or height == std.math.minInt(i32) or planes != 1)
        return refuse("its size or planes are not a bitmap's");
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
    if (!depth_ok) return refuse("a compression or depth a DIB cannot hold");
    if (size >= 108) {
        const cs_type = std.mem.readInt(u32, info[56..60], .little);
        if (cs_type == win32.PROFILE_EMBEDDED or cs_type == win32.PROFILE_LINKED)
            return refuse("it has a color profile");
    }

    // A BITMAPINFOHEADER's three masks follow it; the later headers hold
    // their own. A depth of 8 or less has a color table of biClrUsed
    // entries, or all 2^depth when that is 0; a greater depth has one only
    // when biClrUsed says so.
    const masks: usize = if (size == 40 and compression == win32.BI_BITFIELDS) 12 else 0;
    const colors: usize = if (bpp <= 8) colors: {
        const most = @as(usize, 1) << @intCast(bpp);
        if (clr_used > most) return refuse("more colors than its depth has");
        break :colors if (clr_used == 0) most else clr_used;
    } else clr_used;
    const table_len = std.math.add(usize, masks, std.math.mul(usize, colors, 4) catch
        return refuse("its color table is too long")) catch return refuse("its color table is too long");

    // RLE bits are as long as biSizeImage says; others are rows of whole
    // DWORDs.
    const bits_len: usize = if (compression == win32.BI_RLE8 or compression == win32.BI_RLE4) len: {
        if (size_image == 0) return refuse("its RLE bits have no size");
        break :len size_image;
    } else len: {
        const row_bits = std.math.mul(usize, @intCast(width), bpp) catch return refuse("its rows are too long");
        const stride = (row_bits / 32 + @intFromBool(row_bits % 32 != 0)) * 4;
        break :len std.math.mul(usize, stride, @abs(height)) catch return refuse("its bits are too long");
    };

    const table_end = std.math.add(usize, file_header_len + size, table_len) catch
        return refuse("its color table is too long");
    if (table_end > off_bits) return refuse("its bits start inside its header");
    const bits_end = std.math.add(usize, off_bits, bits_len) catch return refuse("its bits are too long");
    if (bits_end > bmp.len) return refuse("its bits are cut short");
    return .{
        .kind = kind,
        .header = info[0..size],
        .table = bmp[file_header_len + size .. table_end],
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
    const format = registeredFormat(.html) orelse return error.TestUnexpectedResult;
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

/// For tests: put back the text the clipboard held when `save` ran. Other
/// formats are lost, which is acceptable for a test.
const TestSaved = struct {
    text: ?[]u8,

    fn save(hwnd: win32.HWND) !TestSaved {
        return .{ .text = try readClipboardText(std.testing.allocator, hwnd) };
    }

    fn restore(self: TestSaved, hwnd: win32.HWND) void {
        const text = self.text orelse return;
        writeClipboard(std.testing.allocator, hwnd, .text(text)) catch {};
        std.testing.allocator.free(text);
    }
};

/// For tests: the formats on the clipboard, in the order
/// EnumClipboardFormats gives them, synthesized ones included.
fn testFormats(hwnd: win32.HWND, buf: []win32.UINT) ![]win32.UINT {
    if (!win32.OpenClipboard(hwnd).toBool()) return error.TestUnexpectedResult;
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
    if (!win32.OpenClipboard(hwnd).toBool()) return error.TestUnexpectedResult;
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
const test_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
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
    }

    // Refused: each a well-formed file with one thing wrong.
    var buf: [2048]u8 = undefined;
    const Wrong = struct { bmp: TestBmp = .{}, at: usize = 0, bytes: []const u8 = "", cut: usize = 0 };
    for ([_]Wrong{
        .{ .at = 0, .bytes = "MB" },
        .{ .at = 14, .bytes = "\x0c\x00\x00\x00" },
        .{ .at = 14, .bytes = "\x38\x00\x00\x00" },
        .{ .at = 14, .bytes = "\x40\x00\x00\x00" },
        // Width 0, height 0, height minInt, 2 planes.
        .{ .at = 18, .bytes = "\x00\x00\x00\x00" },
        .{ .at = 22, .bytes = "\x00\x00\x00\x00" },
        .{ .at = 22, .bytes = "\x00\x00\x00\x80" },
        .{ .at = 26, .bytes = "\x02\x00" },
        // Depths no compression takes, and JPEG.
        .{ .at = 28, .bytes = "\x02\x00" },
        .{ .bmp = .{ .compression = win32.BI_BITFIELDS, .bpp = 32 }, .at = 28, .bytes = "\x18\x00" },
        .{ .at = 30, .bytes = "\x04\x00\x00\x00" },
        // A top-down RLE bitmap, and one with no size.
        .{ .bmp = .{ .compression = win32.BI_RLE8, .bpp = 8 }, .at = 22, .bytes = "\xfe\xff\xff\xff" },
        .{ .bmp = .{ .compression = win32.BI_RLE8, .bpp = 8 }, .at = 34, .bytes = "\x00\x00\x00\x00" },
        // More colors than the depth has.
        .{ .bmp = .{ .bpp = 1 }, .at = 46, .bytes = "\x03\x00\x00\x00" },
        // Bits that start inside the header, and bits cut short.
        .{ .at = 10, .bytes = "\x35\x00\x00\x00" },
        .{ .cut = 1 },
        // A color profile.
        .{ .bmp = .{ .header = 124, .compression = win32.BI_BITFIELDS, .bpp = 32, .cs_type = win32.PROFILE_EMBEDDED } },
        .{ .bmp = .{ .header = 108, .compression = win32.BI_BITFIELDS, .bpp = 32, .cs_type = win32.PROFILE_LINKED } },
        // A header longer than the file.
        .{ .bmp = .{ .header = 124, .compression = win32.BI_BITFIELDS, .bpp = 32 }, .cut = 100 },
    }) |w| {
        errdefer std.debug.print("wrong={any}\n", .{w});
        const file = w.bmp.file(&buf);
        @memcpy(file[w.at..][0..w.bytes.len], w.bytes);
        try std.testing.expect(dibOfBmp(file[0 .. file.len - w.cut]) == null);
    }
    // And files too short to have the headers.
    const short: [53]u8 = @splat(0);
    for ([_][]const u8{ "", "BM", "BM" ++ short[2..] }) |file| {
        try std.testing.expect(dibOfBmp(file) == null);
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
