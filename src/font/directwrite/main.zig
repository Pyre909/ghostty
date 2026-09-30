//! The process-wide DirectWrite state and the helpers the DirectWrite font
//! backends share.
//!
//! The factory is DirectWrite's shared one, of which a process has exactly
//! one, created here on first use. The font library borrows this state
//! rather than owning it because font discovery warms up on a thread of its
//! own with no library to hand (`Discover.warmup`, src/App.zig), and because
//! font objects taken from the factory outlive any one library.
//!
//! `Shared` and everything that calls DirectWrite are Windows only: this
//! file declares DWriteCreateFactory, so only the DirectWrite backends'
//! switch arms may reference them. The pure helpers below them, and their
//! tests, compile on every host.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");
const font = @import("../main.zig");
pub const api = @import("api.zig");
pub const TextAnalysisSource = @import("TextAnalysisSource.zig");
pub const FontFileLoader = @import("FontFileLoader.zig");

const log = std.log.scoped(.directwrite);

extern "dwrite" fn DWriteCreateFactory(
    factory_type: api.DWRITE_FACTORY_TYPE,
    iid: api.REFIID,
    factory: *?*api.IUnknown,
) callconv(.winapi) api.HRESULT;

extern "kernel32" fn GetACP() callconv(.winapi) u32;

extern "kernel32" fn GetUserDefaultLocaleName(
    name: [*]u16,
    len: c_int,
) callconv(.winapi) c_int;

/// LOCALE_NAME_MAX_LENGTH, which counts the terminator.
const locale_max = 85;

/// The UTF-8 code page.
const CP_UTF8 = 65001;

pub const Error = error{
    /// DirectWrite could not be initialized, or a call on it failed. The
    /// HRESULT is in the log.
    DirectWriteFailed,
};

pub const Shared = struct {
    factory: *api.IDWriteFactory,

    /// The factory as of Windows 8.1, which is what rasterizes a glyph
    /// without fitting it to the pixel grid. Null before that.
    factory2: ?*api.IDWriteFactory2,

    /// What DirectWrite reads a font from memory through, for the backend
    /// that draws with DirectWrite: the fonts that are built in are bytes
    /// and not files. A loader is registered with a factory once, so it
    /// is the process's as the factory is.
    loader: if (loads_memory) *api.IDWriteFontFileLoader else void,

    /// The system's font fallback, which knows the font Windows shows a
    /// character in. Null where DirectWrite has none to offer.
    fallback: ?*api.IDWriteFontFallback,

    /// The user's locale, which decides between the fonts of the
    /// languages that share characters: the Han of Japanese is not drawn
    /// like the Han of Chinese.
    locale: [locale_max:0]u16,

    /// Whether fonts are loaded from memory by DirectWrite. With FreeType
    /// for a rasterizer they are loaded by FreeType.
    const loads_memory = font.options.backend == .directwrite;

    var instance: ?Shared = null;
    var mutex: std.Io.Mutex = .init;

    /// The process's DirectWrite state, created by whichever thread asks
    /// first. It is never destroyed: the factory belongs to the process.
    pub fn get() Error!*Shared {
        mutex.lockUncancelable(global.io());
        defer mutex.unlock(global.io());
        if (instance) |*v| return v;

        var unk: ?*api.IUnknown = null;
        const hr = DWriteCreateFactory(.SHARED, &api.IID_IDWriteFactory, &unk);
        if (api.failed(hr)) {
            log.err("DWriteCreateFactory failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.DirectWriteFailed;
        }
        const factory: *api.IDWriteFactory =
            @ptrCast(@alignCast(unk orelse return error.DirectWriteFailed));
        errdefer api.release(factory);

        var locale: [locale_max:0]u16 = @splat(0);
        if (GetUserDefaultLocaleName(&locale, locale_max) <= 0) {
            const default = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
            @memcpy(locale[0..default.len], default);
            locale[default.len] = 0;
        }

        const factory2: ?*api.IDWriteFactory2 =
            api.queryInterface(factory, api.IDWriteFactory2) catch null;
        errdefer if (factory2) |v| api.release(v);

        const fallback: ?*api.IDWriteFontFallback = fallback: {
            const v = factory2 orelse break :fallback null;
            var out: ?*api.IDWriteFontFallback = null;
            if (api.failed(v.vtable.GetSystemFontFallback(v, &out)))
                break :fallback null;
            break :fallback out;
        };
        errdefer if (fallback) |v| api.release(v);

        // The loader and its streams live as long as DirectWrite holds
        // them, which no allocator of a caller is known to outlive.
        const loader = if (comptime loads_memory) loader: {
            const v = FontFileLoader.create(std.heap.smp_allocator) catch {
                log.err("out of memory for the font file loader", .{});
                return error.DirectWriteFailed;
            };
            const loader_hr = factory.vtable.RegisterFontFileLoader(factory, v);
            if (api.failed(loader_hr)) {
                log.err("RegisterFontFileLoader failed hr=0x{x}", .{
                    @as(u32, @bitCast(loader_hr)),
                });
                api.release(v);
                return error.DirectWriteFailed;
            }
            break :loader v;
        } else {};

        instance = .{
            .factory = factory,
            .factory2 = factory2,
            .loader = loader,
            .fallback = fallback,
            .locale = locale,
        };
        return &instance.?;
    }

    /// The font the system shows a codepoint in, among the fonts of a
    /// collection: a reference the caller releases, or null when the
    /// system has no answer.
    ///
    /// The allocator holds the text source for the length of the call.
    pub fn mapCharacter(
        self: *const Shared,
        alloc: Allocator,
        codepoint: u21,
        collection: *api.IDWriteFontCollection,
        bold: bool,
        italic: bool,
    ) ?*api.IDWriteFont {
        const fallback = self.fallback orelse return null;
        const source = TextAnalysisSource.create(alloc, codepoint, &self.locale) catch
            return null;
        defer api.release(source);

        var mapped_len: api.UINT = 0;
        var mapped: ?*api.IDWriteFont = null;
        var scale: api.FLOAT = 1;
        const hr = fallback.mapCharacters(
            source,
            0,
            if (codepoint < 0x10000) 1 else 2,
            collection,
            null,
            if (bold) .BOLD else .NORMAL,
            if (italic) .ITALIC else .NORMAL,
            .NORMAL,
            &mapped_len,
            &mapped,
            &scale,
        );
        if (api.failed(hr)) {
            log.debug("MapCharacters failed cp={X} hr=0x{x}", .{
                codepoint,
                @as(u32, @bitCast(hr)),
            });
            return null;
        }
        return mapped;
    }

    /// The system font collection as it is now, a reference the caller
    /// releases.
    ///
    /// It is asked for anew each time rather than kept: a collection is a
    /// snapshot of the installed fonts, and DirectWrite hands out the same
    /// one until they change. The first call of a process is the slow one,
    /// which is what the warmup thread is for.
    pub fn systemFonts(self: *const Shared) Error!*api.IDWriteFontCollection {
        var out: ?*api.IDWriteFontCollection = null;
        const hr = self.factory.vtable.GetSystemFontCollection(self.factory, &out, 0);
        if (api.failed(hr)) {
            log.err("GetSystemFontCollection failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.DirectWriteFailed;
        }
        return out orelse error.DirectWriteFailed;
    }
};

/// The file a font's face is read from, when that file is a plain local
/// one: what FreeType needs to open the same face.
pub const LocalFile = struct {
    /// UTF-8, NUL-terminated, inside the caller's buffer.
    path: [:0]const u8,

    /// The face's index inside the file: which member of a collection.
    index: u32,
};

pub const LocalFileError = Error || error{
    /// The font has no single local file behind it: it is served by a
    /// custom or remote loader, or spans several files.
    FontHasNoFile,
    /// The path does not fit the buffer or is not valid UTF-16.
    FontPathCantDecode,
};

/// The size of a buffer that holds any path `localFile` resolves.
pub const path_max = path_units * 3 + 1;

/// The longest path, in UTF-16 units, that is taken from DirectWrite. Far
/// more than the paths fonts are installed at, and a small fraction of
/// what Windows allows, which would not fit a stack.
const path_units = 1024;

/// Whether FreeType can open a path that `localFile` resolved. FreeType
/// opens files by their narrow name, which Windows reads in the process's
/// code page: only an ASCII path means the same there as in UTF-8, unless
/// UTF-8 is that code page.
pub fn freetypeCanOpen(path: []const u8) bool {
    if (GetACP() == CP_UTF8) return true;
    for (path) |c| if (c >= 0x80) return false;
    return true;
}

/// The axis values of a font face that is an instance of a variable font,
/// in `buf`: what makes the face the bold or the light of its file. Empty
/// for every other face, and where DirectWrite predates variable fonts.
pub fn instanceAxes(
    face: *api.IDWriteFontFace,
    buf: []font.face.Variation,
) []const font.face.Variation {
    const face5 = api.queryInterface(face, api.IDWriteFontFace5) catch return &.{};
    defer api.release(face5);
    if (face5.vtable.HasVariations(face5) == 0) return &.{};

    var values: [32]api.DWRITE_FONT_AXIS_VALUE = undefined;
    const count = face5.vtable.GetFontAxisValueCount(face5);
    if (count == 0 or count > values.len or count > buf.len) return &.{};
    if (api.failed(face5.vtable.GetFontAxisValues(face5, &values, count))) return &.{};

    for (values[0..count], buf[0..count]) |value, *v| v.* = .{
        .id = @bitCast(@byteSwap(value.axisTag)),
        .value = value.value,
    };
    return buf[0..count];
}

/// Resolve the local file of a font's face into `buf`.
pub fn localFile(
    face: *api.IDWriteFontFace,
    buf: []u8,
) LocalFileError!LocalFile {
    // A face can in principle span files (Type 1); every format FreeType
    // and this backend share has one.
    var count: api.UINT = 0;
    if (api.failed(face.vtable.GetFiles(face, &count, null))) return error.DirectWriteFailed;
    if (count != 1) return error.FontHasNoFile;
    var files: [1]?*api.IDWriteFontFile = .{null};
    if (api.failed(face.vtable.GetFiles(face, &count, &files))) return error.DirectWriteFailed;
    const file = files[0] orelse return error.FontHasNoFile;
    defer api.release(file);

    // The key names the file to its loader; only the local file loader
    // can turn it into a path.
    var key: ?*const anyopaque = null;
    var key_size: api.UINT = 0;
    if (api.failed(file.vtable.GetReferenceKey(file, &key, &key_size))) return error.DirectWriteFailed;
    var loader: ?*api.IDWriteFontFileLoader = null;
    if (api.failed(file.vtable.GetLoader(file, &loader))) return error.DirectWriteFailed;
    const generic = loader orelse return error.FontHasNoFile;
    defer api.release(generic);
    const local = api.queryInterface(generic, api.IDWriteLocalFontFileLoader) catch
        return error.FontHasNoFile;
    defer api.release(local);

    var len: api.UINT = 0;
    const key_ptr = key orelse return error.FontHasNoFile;
    if (api.failed(local.vtable.GetFilePathLengthFromKey(local, key_ptr, key_size, &len)))
        return error.DirectWriteFailed;
    var wide: [path_units + 1]u16 = undefined;
    if (len + 1 > wide.len) return error.FontPathCantDecode;
    if (api.failed(local.vtable.GetFilePathFromKey(local, key_ptr, key_size, &wide, len + 1)))
        return error.DirectWriteFailed;

    // Room for the terminator FreeType wants.
    if (buf.len == 0) return error.FontPathCantDecode;
    const path = utf16ToUtf8(buf[0 .. buf.len - 1], wide[0..len]) catch
        return error.FontPathCantDecode;
    buf[path.len] = 0;
    return .{
        .path = buf[0..path.len :0],
        .index = face.vtable.GetIndex(face),
    };
}

/// The string of a set of localized strings that is in English, or the
/// first one when there is none, as UTF-8 in `buf`.
pub fn localizedString(
    strings: *api.IDWriteLocalizedStrings,
    buf: []u8,
) (Error || error{OutOfMemory})![]const u8 {
    var index: api.UINT = 0;
    var exists: api.BOOL = 0;
    const en_us = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
    if (api.failed(strings.vtable.FindLocaleName(strings, en_us, &index, &exists)) or
        exists == 0)
    {
        if (strings.vtable.GetCount(strings) == 0) return "";
        index = 0;
    }

    return localizedStringAt(strings, index, buf);
}

/// One string of a set of localized strings, as UTF-8 in `buf`.
pub fn localizedStringAt(
    strings: *api.IDWriteLocalizedStrings,
    index: api.UINT,
    buf: []u8,
) (Error || error{OutOfMemory})![]const u8 {
    var len: api.UINT = 0;
    if (api.failed(strings.vtable.GetStringLength(strings, index, &len)))
        return error.DirectWriteFailed;
    var wide: [name_max]u16 = undefined;
    if (len + 1 > wide.len) return error.OutOfMemory;
    if (api.failed(strings.vtable.GetString(strings, index, &wide, len + 1)))
        return error.DirectWriteFailed;
    return utf16ToUtf8(buf, wide[0..len]) catch error.OutOfMemory;
}

/// The longest name, in UTF-16 units, that is read from DirectWrite. Names
/// are family, style and full names; the name table allows more, no font
/// in practice comes close.
pub const name_max = 256;

/// UTF-16 to UTF-8 into a buffer, with the bounds checked: a name that
/// does not fit is an error rather than a truncated name.
pub fn utf16ToUtf8(
    buf: []u8,
    wide: []const u16,
) error{ NoSpaceLeft, InvalidUtf16 }![]const u8 {
    var it = std.unicode.Utf16LeIterator.init(wide);
    var i: usize = 0;
    while (it.nextCodepoint() catch return error.InvalidUtf16) |cp| {
        const n = std.unicode.utf8CodepointSequenceLength(cp) catch
            return error.InvalidUtf16;
        if (i + n > buf.len) return error.NoSpaceLeft;
        _ = std.unicode.utf8Encode(cp, buf[i..][0..n]) catch
            return error.InvalidUtf16;
        i += n;
    }
    return buf[0..i];
}

/// An OpenType table tag as DirectWrite takes it: the four characters
/// with the first in the low byte (DWRITE_MAKE_OPENTYPE_TAG).
pub fn tableTag(tag: *const [4]u8) u32 {
    return std.mem.readInt(u32, tag, .little);
}

/// A variation axis as DirectWrite names it (DWRITE_FONT_AXIS_TAG), which
/// is the byte-swapped form of the id the rest of the font code uses.
pub fn axisTag(id: font.face.Variation.Id) u32 {
    return @byteSwap(@as(u32, @bitCast(id)));
}

test "directwrite: table and axis tags" {
    const testing = std.testing;
    // DWRITE_FONT_AXIS_TAG_WEIGHT in dwrite_3.h.
    try testing.expectEqual(0x74686777, axisTag(.init("wght")));
    // DWRITE_MAKE_OPENTYPE_TAG('h','e','a','d').
    try testing.expectEqual(0x64616568, tableTag("head"));
    try testing.expectEqual(tableTag("wght"), axisTag(.init("wght")));

    // And back, as `instanceAxes` converts what DirectWrite reports.
    const id: font.face.Variation.Id = @bitCast(@byteSwap(@as(u32, 0x74686777)));
    try testing.expectEqualStrings("wght", &id.str());
}

test "directwrite: utf16 to utf8" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("Consolas", try utf16ToUtf8(&buf, L("Consolas")));
    // Two units outside the basic plane, four bytes in UTF-8.
    try testing.expectEqualStrings("\u{1F600}", try utf16ToUtf8(&buf, L("\u{1F600}")));
    try testing.expectEqualStrings("", try utf16ToUtf8(&buf, L("")));
    // A name that does not fit is an error, not a shorter name.
    try testing.expectError(error.NoSpaceLeft, utf16ToUtf8(buf[0..7], L("Consolas")));
    try testing.expectError(error.NoSpaceLeft, utf16ToUtf8(buf[0..3], L("\u{1F600}")));
    // A lone surrogate is not text.
    try testing.expectError(error.InvalidUtf16, utf16ToUtf8(&buf, &.{0xD83D}));
}
