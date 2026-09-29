//! DirectWrite declarations for the DirectWrite font backends.
//!
//! The COM interfaces are vtable structs in the order of the mingw headers
//! Zig ships (lib/libc/include/any-windows-any: dwrite.h, dwrite_1.h,
//! dwrite_2.h, dwrite_3.h, winerror.h), the same headers the C compiler
//! would read. Only the methods the backend calls are typed; every other
//! slot is an untyped pointer, so a vtable keeps its size and each typed
//! slot keeps its index. A derived interface embeds its parent's vtable as
//! its first field, which is how COM lays them out. Interfaces the backend
//! implements itself (the text analysis source, the font file stream) have
//! every slot typed.
//!
//! The tests check every vtable's slot count and every struct's layout
//! against the header, so a dropped or shuffled slot fails on any host
//! instead of calling the wrong function in a Windows run. No extern
//! function lives here so that those tests link everywhere; directwrite/
//! main.zig declares DWriteCreateFactory.
//!
//! This mirrors src/renderer/d3d11/api.zig; the handful of helpers below
//! are duplicated from it rather than imported, so the font package does
//! not depend on the renderer.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

/// The calling convention of every COM method: the platform convention on
/// Windows (stdcall on x86, the C convention on x86_64 and aarch64). On
/// other hosts only the layout tests analyze these types, and the Windows
/// convention is not compilable there, so the C convention stands in; it
/// never gets called.
pub const cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const UINT = u32;
pub const INT = i32;
pub const ULONG = u32;
pub const UINT8 = u8;
pub const UINT16 = u16;
pub const INT16 = i16;
pub const INT32 = i32;
pub const UINT32 = u32;
pub const UINT64 = u64;
pub const SIZE_T = usize;
pub const FLOAT = f32;
/// WINBOOL in the headers: a C int.
pub const BOOL = i32;
pub const WCHAR = u16;
pub const GUID = windows.GUID;
pub const REFIID = *const GUID;

/// A Windows LONG, 32 bits on every Windows target. Spelled as i32 rather
/// than c_long so the constants below mean the same thing when the tests
/// run on a host where c_long is 64 bits.
pub const HRESULT = i32;

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub inline fn failed(hr: HRESULT) bool {
    return hr < 0;
}

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));

// IUnknown's IID is the one GUID every COM header agrees on; the rest come
// from the DEFINE_GUID lines of the headers named above.
pub const IID_IUnknown: GUID = GUID.parse("{00000000-0000-0000-C000-000000000046}");

// ---------------------------------------------------------------------------
// COM helpers

/// Any COM object pointer viewed through its IUnknown prefix.
pub inline fn unknown(obj: anytype) *IUnknown {
    return @ptrCast(obj);
}

/// Drops one reference. COM returns the remaining count, which nothing
/// here needs.
pub fn release(obj: anytype) void {
    const u = unknown(obj);
    _ = u.vtable.Release(u);
}

/// Takes one reference, for a pointer that is stored beyond the call that
/// produced it.
pub fn addRef(obj: anytype) void {
    const u = unknown(obj);
    _ = u.vtable.AddRef(u);
}

pub const QueryInterfaceError = error{QueryInterfaceFailed};

/// QueryInterface for `T`, which must carry its IID as `T.IID`. The
/// returned reference is owned by the caller.
pub fn queryInterface(obj: anytype, comptime T: type) QueryInterfaceError!*T {
    const u = unknown(obj);
    var out: ?*anyopaque = null;
    if (failed(u.vtable.QueryInterface(u, &T.IID, &out))) return error.QueryInterfaceFailed;
    return @ptrCast(@alignCast(out orelse return error.QueryInterfaceFailed));
}

/// An untyped vtable slot. The backend never calls it, but it has to be
/// there so the slots after it keep their index.
pub const Slot = *const anyopaque;

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IUnknown;

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, REFIID, *?*anyopaque) callconv(cc) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(cc) ULONG,
        Release: *const fn (*IUnknown) callconv(cc) ULONG,
    };
};

// ---------------------------------------------------------------------------
// Interfaces
//
// Parameter names follow the headers. Interfaces that the backend only ever
// receives as opaque pointers are declared opaque.

// ---------------------------------------------------------------------------
// Factories: IDWriteFactory (dwrite.h), IDWriteFactory1 (dwrite_1.h) and
// IDWriteFactory2 (dwrite_2.h), with the enums their typed methods take.

pub const IID_IDWriteFactory: GUID = GUID.parse("{b859ee5a-d838-4b5b-a2e8-1adc7d93db48}");
pub const IID_IDWriteFactory1: GUID = GUID.parse("{30572f99-dac6-41db-a16e-0486307e606a}");
pub const IID_IDWriteFactory2: GUID = GUID.parse("{0439fc60-ca44-4994-8dee-3a9af7b732ec}");

pub const DWRITE_FACTORY_TYPE = enum(c_int) {
    SHARED = 0,
    ISOLATED = 1,
    _,
};

pub const DWRITE_FONT_FILE_TYPE = enum(c_int) {
    UNKNOWN = 0,
    CFF = 1,
    TRUETYPE = 2,
    OPENTYPE_COLLECTION = 3,
    TYPE1_PFM = 4,
    TYPE1_PFB = 5,
    VECTOR = 6,
    BITMAP = 7,
    _,

    /// The header's second name for OPENTYPE_COLLECTION. A Zig enum cannot
    /// hold two tags with one value, so the alias is a declaration.
    pub const TRUETYPE_COLLECTION: DWRITE_FONT_FILE_TYPE = .OPENTYPE_COLLECTION;
};

pub const DWRITE_FONT_FACE_TYPE = enum(c_int) {
    CFF = 0,
    TRUETYPE = 1,
    OPENTYPE_COLLECTION = 2,
    TYPE1 = 3,
    VECTOR = 4,
    BITMAP = 5,
    UNKNOWN = 6,
    RAW_CFF = 7,
    _,

    /// The header's second name for OPENTYPE_COLLECTION; see
    /// DWRITE_FONT_FILE_TYPE.TRUETYPE_COLLECTION.
    pub const TRUETYPE_COLLECTION: DWRITE_FONT_FACE_TYPE = .OPENTYPE_COLLECTION;
};

// DWRITE_FONT_SIMULATIONS is an enum in the header with
// DEFINE_ENUM_FLAG_OPERATORS, that is a flag set passed as a C int; UINT has
// the same size and the same argument passing.
pub const DWRITE_FONT_SIMULATIONS_NONE: UINT = 0;
pub const DWRITE_FONT_SIMULATIONS_BOLD: UINT = 1;
pub const DWRITE_FONT_SIMULATIONS_OBLIQUE: UINT = 2;

pub const IDWriteFactory = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFactory;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(cc) HRESULT,
        CreateCustomFontCollection: Slot,
        RegisterFontCollectionLoader: Slot,
        UnregisterFontCollectionLoader: Slot,
        CreateFontFileReference: Slot,
        /// The key is an opaque blob that the loader knows how to read.
        CreateCustomFontFileReference: *const fn (
            *IDWriteFactory,
            *const anyopaque,
            UINT,
            *IDWriteFontFileLoader,
            *?*IDWriteFontFile,
        ) callconv(cc) HRESULT,
        /// The UINT after the files is the face's index in them, the one
        /// after that a set of DWRITE_FONT_SIMULATIONS_* flags.
        CreateFontFace: *const fn (
            *IDWriteFactory,
            DWRITE_FONT_FACE_TYPE,
            UINT,
            [*]const *IDWriteFontFile,
            UINT,
            UINT,
            *?*IDWriteFontFace,
        ) callconv(cc) HRESULT,
        CreateRenderingParams: Slot,
        CreateMonitorRenderingParams: Slot,
        CreateCustomRenderingParams: Slot,
        RegisterFontFileLoader: *const fn (*IDWriteFactory, *IDWriteFontFileLoader) callconv(cc) HRESULT,
        UnregisterFontFileLoader: *const fn (*IDWriteFactory, *IDWriteFontFileLoader) callconv(cc) HRESULT,
        CreateTextFormat: Slot,
        CreateTypography: Slot,
        GetGdiInterop: Slot,
        CreateTextLayout: Slot,
        CreateGdiCompatibleTextLayout: Slot,
        CreateEllipsisTrimmingSign: Slot,
        CreateTextAnalyzer: Slot,
        CreateNumberSubstitution: Slot,
        CreateGlyphRunAnalysis: Slot,
    };
};

pub const IDWriteFactory1 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFactory1;

    pub const VTable = extern struct {
        base: IDWriteFactory.VTable,
        GetEudcFontCollection: Slot,
        /// An overload of IDWriteFactory's method of the same name; the
        /// header's C vtable spells it
        /// IDWriteFactory1_CreateCustomRenderingParams.
        CreateCustomRenderingParams: Slot,
    };
};

pub const IDWriteFactory2 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFactory2;

    pub const VTable = extern struct {
        base: IDWriteFactory1.VTable,
        GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(cc) HRESULT,
        CreateFontFallbackBuilder: Slot,
        TranslateColorGlyphRun: Slot,
        /// Overloads; the header's C vtable spells these two
        /// IDWriteFactory2_CreateCustomRenderingParams and
        /// IDWriteFactory2_CreateGlyphRunAnalysis.
        CreateCustomRenderingParams: Slot,
        CreateGlyphRunAnalysis: Slot,
    };
};

test "directwrite api: factory vtable slot counts" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(24 * p, @sizeOf(IDWriteFactory.VTable));
    try testing.expectEqual(26 * p, @sizeOf(IDWriteFactory1.VTable));
    try testing.expectEqual(31 * p, @sizeOf(IDWriteFactory2.VTable));
}

test "directwrite api: factory typed slot indices" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFactory.VTable, "GetSystemFontCollection"));
    try testing.expectEqual(8 * p, @offsetOf(IDWriteFactory.VTable, "CreateCustomFontFileReference"));
    try testing.expectEqual(9 * p, @offsetOf(IDWriteFactory.VTable, "CreateFontFace"));
    try testing.expectEqual(13 * p, @offsetOf(IDWriteFactory.VTable, "RegisterFontFileLoader"));
    try testing.expectEqual(14 * p, @offsetOf(IDWriteFactory.VTable, "UnregisterFontFileLoader"));
    try testing.expectEqual(24 * p, @offsetOf(IDWriteFactory1.VTable, "GetEudcFontCollection"));
    try testing.expectEqual(26 * p, @offsetOf(IDWriteFactory2.VTable, "GetSystemFontFallback"));
}

test "directwrite api: factory enums" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(DWRITE_FACTORY_TYPE));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(DWRITE_FONT_FACE_TYPE));
    try testing.expectEqual(2, @intFromEnum(DWRITE_FONT_FACE_TYPE.TRUETYPE_COLLECTION));
    try testing.expectEqual(3, @intFromEnum(DWRITE_FONT_FILE_TYPE.TRUETYPE_COLLECTION));
}

test "directwrite api: factory iids" {
    const testing = std.testing;
    try testing.expectEqual(0xb859ee5a, IID_IDWriteFactory.Data1);
    try testing.expectEqual(0xd838, IID_IDWriteFactory.Data2);
    try testing.expectEqual(0x48, IID_IDWriteFactory.Data4[7]);
    try testing.expectEqual(0x30572f99, IID_IDWriteFactory1.Data1);
    try testing.expectEqual(0xdac6, IID_IDWriteFactory1.Data2);
    try testing.expectEqual(0x6a, IID_IDWriteFactory1.Data4[7]);
    try testing.expectEqual(0x0439fc60, IID_IDWriteFactory2.Data1);
    try testing.expectEqual(0xca44, IID_IDWriteFactory2.Data2);
    try testing.expectEqual(0xec, IID_IDWriteFactory2.Data4[7]);
}

// ---------------------------------------------------------------------------
// Fonts: collections, families, fonts and their localized strings, from
// dwrite.h, dwrite_1.h (IDWriteFont1) and dwrite_2.h (IDWriteFont2).

// IID_IDWriteFont1 is IID_IDWriteFont with the last byte one higher; that is
// what the headers say, not a typo. IID_IDWriteFont2 is unrelated to both.
pub const IID_IDWriteFontCollection: GUID = GUID.parse("{a84cee02-3eea-4eee-a827-87c1a02a0fcc}");
pub const IID_IDWriteFontList: GUID = GUID.parse("{1a0d8438-1d97-4ec1-aef9-a2fb86ed6acb}");
pub const IID_IDWriteFontFamily: GUID = GUID.parse("{da20d8ef-812a-4c43-9802-62ec4abd7add}");
pub const IID_IDWriteFont: GUID = GUID.parse("{acd16696-8c14-4f5d-877e-fe3fc1d32737}");
pub const IID_IDWriteFont1: GUID = GUID.parse("{acd16696-8c14-4f5d-877e-fe3fc1d32738}");
pub const IID_IDWriteFont2: GUID = GUID.parse("{29748ed6-8c9c-4a6a-be0b-d912e8538944}");
pub const IID_IDWriteLocalizedStrings: GUID = GUID.parse("{08256209-099a-4b34-b86d-c22b110e7771}");

/// Non-exhaustive: a font can report any weight from 1 to 999, not only the
/// named ones. The header's synonyms share a value, which a Zig enum cannot
/// have twice, so they are declarations that alias the first name.
pub const DWRITE_FONT_WEIGHT = enum(c_int) {
    THIN = 100,
    EXTRA_LIGHT = 200,
    LIGHT = 300,
    SEMI_LIGHT = 350,
    NORMAL = 400,
    MEDIUM = 500,
    DEMI_BOLD = 600,
    BOLD = 700,
    EXTRA_BOLD = 800,
    BLACK = 900,
    EXTRA_BLACK = 950,
    _,

    pub const ULTRA_LIGHT: DWRITE_FONT_WEIGHT = .EXTRA_LIGHT;
    pub const REGULAR: DWRITE_FONT_WEIGHT = .NORMAL;
    pub const SEMI_BOLD: DWRITE_FONT_WEIGHT = .DEMI_BOLD;
    pub const ULTRA_BOLD: DWRITE_FONT_WEIGHT = .EXTRA_BOLD;
    pub const HEAVY: DWRITE_FONT_WEIGHT = .BLACK;
    pub const ULTRA_BLACK: DWRITE_FONT_WEIGHT = .EXTRA_BLACK;
};

pub const DWRITE_FONT_STRETCH = enum(c_int) {
    UNDEFINED = 0,
    ULTRA_CONDENSED = 1,
    EXTRA_CONDENSED = 2,
    CONDENSED = 3,
    SEMI_CONDENSED = 4,
    NORMAL = 5,
    SEMI_EXPANDED = 6,
    EXPANDED = 7,
    EXTRA_EXPANDED = 8,
    ULTRA_EXPANDED = 9,
    _,

    pub const MEDIUM: DWRITE_FONT_STRETCH = .NORMAL;
};

pub const DWRITE_FONT_STYLE = enum(c_int) {
    NORMAL = 0,
    OBLIQUE = 1,
    ITALIC = 2,
    _,
};

/// The header's members are DWRITE_INFORMATIONAL_STRING_<name>, without the
/// _ID of the type name.
pub const DWRITE_INFORMATIONAL_STRING_ID = enum(c_int) {
    NONE = 0,
    COPYRIGHT_NOTICE = 1,
    VERSION_STRINGS = 2,
    TRADEMARK = 3,
    MANUFACTURER = 4,
    DESIGNER = 5,
    DESIGNER_URL = 6,
    DESCRIPTION = 7,
    FONT_VENDOR_URL = 8,
    LICENSE_DESCRIPTION = 9,
    LICENSE_INFO_URL = 10,
    WIN32_FAMILY_NAMES = 11,
    WIN32_SUBFAMILY_NAMES = 12,
    TYPOGRAPHIC_FAMILY_NAMES = 13,
    TYPOGRAPHIC_SUBFAMILY_NAMES = 14,
    SAMPLE_TEXT = 15,
    FULL_NAME = 16,
    POSTSCRIPT_NAME = 17,
    POSTSCRIPT_CID_NAME = 18,
    WEIGHT_STRETCH_STYLE_FAMILY_NAME = 19,
    DESIGN_SCRIPT_LANGUAGE_TAG = 20,
    SUPPORTED_SCRIPT_LANGUAGE_TAG = 21,
    _,

    pub const PREFERRED_FAMILY_NAMES: DWRITE_INFORMATIONAL_STRING_ID = .TYPOGRAPHIC_FAMILY_NAMES;
    pub const PREFERRED_SUBFAMILY_NAMES: DWRITE_INFORMATIONAL_STRING_ID = .TYPOGRAPHIC_SUBFAMILY_NAMES;
    pub const WWS_FAMILY_NAME: DWRITE_INFORMATIONAL_STRING_ID = .WEIGHT_STRETCH_STYLE_FAMILY_NAME;
};

/// Everything is in font design units. The INT16 fields are signed in the
/// header: lineGap, underlinePosition and strikethroughPosition.
pub const DWRITE_FONT_METRICS = extern struct {
    designUnitsPerEm: UINT16,
    ascent: UINT16,
    descent: UINT16,
    lineGap: INT16,
    capHeight: UINT16,
    xHeight: UINT16,
    underlinePosition: INT16,
    underlineThickness: UINT16,
    strikethroughPosition: INT16,
    strikethroughThickness: UINT16,
};

pub const IDWriteFontCollection = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontCollection;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(cc) UINT,
        GetFontFamily: *const fn (*IDWriteFontCollection, UINT, *?*IDWriteFontFamily) callconv(cc) HRESULT,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const WCHAR, *UINT, *BOOL) callconv(cc) HRESULT,
        GetFontFromFontFace: Slot,
    };
};

pub const IDWriteFontList = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontList;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFontCollection: Slot,
        GetFontCount: *const fn (*IDWriteFontList) callconv(cc) UINT,
        GetFont: *const fn (*IDWriteFontList, UINT, *?*IDWriteFont) callconv(cc) HRESULT,
    };
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFamily;

    pub const VTable = extern struct {
        base: IDWriteFontList.VTable,
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(cc) HRESULT,
        GetFirstMatchingFont: Slot,
        GetMatchingFonts: *const fn (
            *IDWriteFontFamily,
            DWRITE_FONT_WEIGHT,
            DWRITE_FONT_STRETCH,
            DWRITE_FONT_STYLE,
            *?*IDWriteFontList,
        ) callconv(cc) HRESULT,
    };

    /// The family viewed as the list of its fonts, which it derives from.
    pub inline fn fontList(self: *IDWriteFontFamily) *IDWriteFontList {
        return @ptrCast(self);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFont;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetFontFamily: *const fn (*IDWriteFont, *?*IDWriteFontFamily) callconv(cc) HRESULT,
        GetWeight: *const fn (*IDWriteFont) callconv(cc) DWRITE_FONT_WEIGHT,
        GetStretch: Slot,
        GetStyle: *const fn (*IDWriteFont) callconv(cc) DWRITE_FONT_STYLE,
        IsSymbolFont: Slot,
        GetFaceNames: *const fn (*IDWriteFont, *?*IDWriteLocalizedStrings) callconv(cc) HRESULT,
        GetInformationalStrings: *const fn (
            *IDWriteFont,
            DWRITE_INFORMATIONAL_STRING_ID,
            *?*IDWriteLocalizedStrings,
            *BOOL,
        ) callconv(cc) HRESULT,
        /// A set of DWRITE_FONT_SIMULATIONS_* flags.
        GetSimulations: *const fn (*IDWriteFont) callconv(cc) UINT,
        GetMetrics: Slot,
        HasCharacter: *const fn (*IDWriteFont, UINT, *BOOL) callconv(cc) HRESULT,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(cc) HRESULT,
    };
};

pub const IDWriteFont1 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFont1;

    pub const VTable = extern struct {
        base: IDWriteFont.VTable,
        /// The header's name for this slot: the C vtable is flat, so the
        /// DWRITE_FONT_METRICS1 overload cannot be a second GetMetrics.
        IDWriteFont1_GetMetrics: Slot,
        GetPanose: Slot,
        GetUnicodeRanges: Slot,
        IsMonospacedFont: *const fn (*IDWriteFont1) callconv(cc) BOOL,
    };

    pub inline fn font(self: *IDWriteFont1) *IDWriteFont {
        return @ptrCast(self);
    }
};

pub const IDWriteFont2 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFont2;

    pub const VTable = extern struct {
        base: IDWriteFont1.VTable,
        IsColorFont: *const fn (*IDWriteFont2) callconv(cc) BOOL,
    };

    pub inline fn font(self: *IDWriteFont2) *IDWriteFont {
        return @ptrCast(self);
    }
};

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteLocalizedStrings;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetCount: *const fn (*IDWriteLocalizedStrings) callconv(cc) UINT,
        FindLocaleName: *const fn (*IDWriteLocalizedStrings, [*:0]const WCHAR, *UINT, *BOOL) callconv(cc) HRESULT,
        GetLocaleNameLength: Slot,
        GetLocaleName: Slot,
        /// The length excludes the terminating NUL.
        GetStringLength: *const fn (*IDWriteLocalizedStrings, UINT, *UINT) callconv(cc) HRESULT,
        /// The buffer's length is in WCHARs and has to include room for
        /// the terminating NUL, one more than GetStringLength reports.
        GetString: *const fn (*IDWriteLocalizedStrings, UINT, [*]WCHAR, UINT) callconv(cc) HRESULT,
    };
};

test "directwrite api: fonts vtable slot counts" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(7 * p, @sizeOf(IDWriteFontCollection.VTable));
    try testing.expectEqual(6 * p, @sizeOf(IDWriteFontList.VTable));
    try testing.expectEqual(9 * p, @sizeOf(IDWriteFontFamily.VTable));
    try testing.expectEqual(14 * p, @sizeOf(IDWriteFont.VTable));
    try testing.expectEqual(18 * p, @sizeOf(IDWriteFont1.VTable));
    try testing.expectEqual(19 * p, @sizeOf(IDWriteFont2.VTable));
    try testing.expectEqual(9 * p, @sizeOf(IDWriteLocalizedStrings.VTable));
}

test "directwrite api: fonts typed slot indices" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFontCollection.VTable, "GetFontFamilyCount"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteFontCollection.VTable, "GetFontFamily"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteFontCollection.VTable, "FindFamilyName"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteFontList.VTable, "GetFontCount"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteFontList.VTable, "GetFont"));
    try testing.expectEqual(6 * p, @offsetOf(IDWriteFontFamily.VTable, "GetFamilyNames"));
    try testing.expectEqual(8 * p, @offsetOf(IDWriteFontFamily.VTable, "GetMatchingFonts"));
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFont.VTable, "GetFontFamily"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteFont.VTable, "GetWeight"));
    try testing.expectEqual(6 * p, @offsetOf(IDWriteFont.VTable, "GetStyle"));
    try testing.expectEqual(8 * p, @offsetOf(IDWriteFont.VTable, "GetFaceNames"));
    try testing.expectEqual(9 * p, @offsetOf(IDWriteFont.VTable, "GetInformationalStrings"));
    try testing.expectEqual(10 * p, @offsetOf(IDWriteFont.VTable, "GetSimulations"));
    try testing.expectEqual(12 * p, @offsetOf(IDWriteFont.VTable, "HasCharacter"));
    try testing.expectEqual(13 * p, @offsetOf(IDWriteFont.VTable, "CreateFontFace"));
    try testing.expectEqual(17 * p, @offsetOf(IDWriteFont1.VTable, "IsMonospacedFont"));
    try testing.expectEqual(18 * p, @offsetOf(IDWriteFont2.VTable, "IsColorFont"));
    try testing.expectEqual(3 * p, @offsetOf(IDWriteLocalizedStrings.VTable, "GetCount"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteLocalizedStrings.VTable, "FindLocaleName"));
    try testing.expectEqual(7 * p, @offsetOf(IDWriteLocalizedStrings.VTable, "GetStringLength"));
    try testing.expectEqual(8 * p, @offsetOf(IDWriteLocalizedStrings.VTable, "GetString"));
}

test "directwrite api: fonts struct layouts" {
    const testing = std.testing;
    try testing.expectEqual(20, @sizeOf(DWRITE_FONT_METRICS));
    try testing.expectEqual(2, @alignOf(DWRITE_FONT_METRICS));
    try testing.expectEqual(0, @offsetOf(DWRITE_FONT_METRICS, "designUnitsPerEm"));
    try testing.expectEqual(6, @offsetOf(DWRITE_FONT_METRICS, "lineGap"));
    try testing.expectEqual(12, @offsetOf(DWRITE_FONT_METRICS, "underlinePosition"));
    try testing.expectEqual(18, @offsetOf(DWRITE_FONT_METRICS, "strikethroughThickness"));
    // The enums cross the ABI by value, so they have to be int-sized.
    try testing.expectEqual(4, @sizeOf(DWRITE_FONT_WEIGHT));
    try testing.expectEqual(4, @sizeOf(DWRITE_FONT_STRETCH));
    try testing.expectEqual(4, @sizeOf(DWRITE_FONT_STYLE));
    try testing.expectEqual(4, @sizeOf(DWRITE_INFORMATIONAL_STRING_ID));
    try testing.expectEqual(DWRITE_FONT_WEIGHT.NORMAL, DWRITE_FONT_WEIGHT.REGULAR);
    try testing.expectEqual(13, @intFromEnum(DWRITE_INFORMATIONAL_STRING_ID.PREFERRED_FAMILY_NAMES));
}

test "directwrite api: fonts iids" {
    const testing = std.testing;
    try testing.expectEqual(0xa84cee02, IID_IDWriteFontCollection.Data1);
    try testing.expectEqual(0x3eea, IID_IDWriteFontCollection.Data2);
    try testing.expectEqual(0xcc, IID_IDWriteFontCollection.Data4[7]);
    try testing.expectEqual(0xacd16696, IID_IDWriteFont.Data1);
    try testing.expectEqual(0x8c14, IID_IDWriteFont.Data2);
    try testing.expectEqual(0x37, IID_IDWriteFont.Data4[7]);
    try testing.expectEqual(0xacd16696, IID_IDWriteFont1.Data1);
    try testing.expectEqual(0x38, IID_IDWriteFont1.Data4[7]);
    try testing.expectEqual(0x29748ed6, IID_IDWriteFont2.Data1);
    try testing.expectEqual(0x8c9c, IID_IDWriteFont2.Data2);
    try testing.expectEqual(0x44, IID_IDWriteFont2.Data4[7]);
    try testing.expectEqual(0x08256209, IID_IDWriteLocalizedStrings.Data1);
    try testing.expectEqual(0x71, IID_IDWriteLocalizedStrings.Data4[7]);
}

// ---------------------------------------------------------------------------
// Font faces, font files, file loaders and file streams (dwrite.h).

pub const IID_IDWriteFontFileStream: GUID = GUID.parse("{6d4865fe-0ab8-4d91-8f62-5dd6be34a3e0}");
pub const IID_IDWriteFontFileLoader: GUID = GUID.parse("{727cad4e-d6af-4c9e-8a08-d695b11caa49}");
pub const IID_IDWriteLocalFontFileLoader: GUID = GUID.parse("{b2d9f3ec-c9fe-4a11-a2ec-d86208f7c0a2}");
pub const IID_IDWriteFontFile: GUID = GUID.parse("{739d886a-cef5-47dc-8769-1a8b41bebbb0}");
pub const IID_IDWriteFontFace: GUID = GUID.parse("{5f49804d-7024-4d43-bfa9-d25984f53849}");

pub const IDWriteFontFileStream = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFileStream;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        /// The fragment stays valid until ReleaseFileFragment is called
        /// with the context this hands back.
        ReadFileFragment: *const fn (
            *IDWriteFontFileStream,
            *?*const anyopaque,
            UINT64,
            UINT64,
            *?*anyopaque,
        ) callconv(cc) HRESULT,
        ReleaseFileFragment: *const fn (
            *IDWriteFontFileStream,
            ?*anyopaque,
        ) callconv(cc) void,
        GetFileSize: *const fn (
            *IDWriteFontFileStream,
            *UINT64,
        ) callconv(cc) HRESULT,
        GetLastWriteTime: *const fn (
            *IDWriteFontFileStream,
            *UINT64,
        ) callconv(cc) HRESULT,
    };
};

pub const IDWriteFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFileLoader;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        CreateStreamFromKey: *const fn (
            *IDWriteFontFileLoader,
            *const anyopaque,
            UINT,
            *?*IDWriteFontFileStream,
        ) callconv(cc) HRESULT,
    };
};

pub const IDWriteLocalFontFileLoader = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteLocalFontFileLoader;

    pub const VTable = extern struct {
        base: IDWriteFontFileLoader.VTable,
        /// The length is in WCHARs and leaves out the terminating NUL.
        GetFilePathLengthFromKey: *const fn (
            *IDWriteLocalFontFileLoader,
            *const anyopaque,
            UINT,
            *UINT,
        ) callconv(cc) HRESULT,
        /// The buffer's length is in WCHARs and has to include room for
        /// the terminating NUL, one more than GetFilePathLengthFromKey
        /// reports.
        GetFilePathFromKey: *const fn (
            *IDWriteLocalFontFileLoader,
            *const anyopaque,
            UINT,
            [*]WCHAR,
            UINT,
        ) callconv(cc) HRESULT,
        GetLastWriteTimeFromKey: Slot,
    };
};

pub const IDWriteFontFile = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFile;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        /// The key is owned by the file and valid for as long as the file
        /// is alive.
        GetReferenceKey: *const fn (
            *IDWriteFontFile,
            *?*const anyopaque,
            *UINT,
        ) callconv(cc) HRESULT,
        GetLoader: *const fn (
            *IDWriteFontFile,
            *?*IDWriteFontFileLoader,
        ) callconv(cc) HRESULT,
        Analyze: *const fn (
            *IDWriteFontFile,
            *BOOL,
            *DWRITE_FONT_FILE_TYPE,
            *DWRITE_FONT_FACE_TYPE,
            *UINT,
        ) callconv(cc) HRESULT,
    };
};

pub const IDWriteFontFace = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFace;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetType: *const fn (*IDWriteFontFace) callconv(cc) DWRITE_FONT_FACE_TYPE,
        /// Two calls: with a null array it stores the number of files, and
        /// with an array of that many entries it fills the array. Each file
        /// it stores is a reference the caller owns.
        GetFiles: *const fn (
            *IDWriteFontFace,
            *UINT,
            ?[*]?*IDWriteFontFile,
        ) callconv(cc) HRESULT,
        GetIndex: *const fn (*IDWriteFontFace) callconv(cc) UINT,
        /// A set of DWRITE_FONT_SIMULATIONS_* flags.
        GetSimulations: *const fn (*IDWriteFontFace) callconv(cc) UINT,
        IsSymbolFont: Slot,
        GetMetrics: *const fn (
            *IDWriteFontFace,
            *DWRITE_FONT_METRICS,
        ) callconv(cc) void,
        GetGlyphCount: Slot,
        GetDesignGlyphMetrics: Slot,
        /// One glyph index per codepoint; a codepoint the face has no glyph
        /// for gets index 0.
        GetGlyphIndices: *const fn (
            *IDWriteFontFace,
            [*]const UINT,
            UINT,
            [*]UINT16,
        ) callconv(cc) HRESULT,
        /// The tag is the table's four characters with the first in the low
        /// byte (DWRITE_MAKE_OPENTYPE_TAG). The data stays valid until
        /// ReleaseFontTable is called with the context this hands back.
        TryGetFontTable: *const fn (
            *IDWriteFontFace,
            UINT,
            *?*const anyopaque,
            *UINT,
            *?*anyopaque,
            *BOOL,
        ) callconv(cc) HRESULT,
        ReleaseFontTable: *const fn (
            *IDWriteFontFace,
            ?*anyopaque,
        ) callconv(cc) void,
        GetGlyphRunOutline: Slot,
        GetRecommendedRenderingMode: Slot,
        GetGdiCompatibleMetrics: Slot,
        GetGdiCompatibleGlyphMetrics: Slot,
    };
};

test "directwrite api: face vtable slot counts" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(7 * p, @sizeOf(IDWriteFontFileStream.VTable));
    try testing.expectEqual(4 * p, @sizeOf(IDWriteFontFileLoader.VTable));
    try testing.expectEqual(7 * p, @sizeOf(IDWriteLocalFontFileLoader.VTable));
    try testing.expectEqual(6 * p, @sizeOf(IDWriteFontFile.VTable));
    try testing.expectEqual(18 * p, @sizeOf(IDWriteFontFace.VTable));
}

test "directwrite api: face typed slot indices" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFontFileStream.VTable, "ReadFileFragment"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteFontFileStream.VTable, "ReleaseFileFragment"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteFontFileStream.VTable, "GetFileSize"));
    try testing.expectEqual(6 * p, @offsetOf(IDWriteFontFileStream.VTable, "GetLastWriteTime"));
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFontFileLoader.VTable, "CreateStreamFromKey"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteLocalFontFileLoader.VTable, "GetFilePathLengthFromKey"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteLocalFontFileLoader.VTable, "GetFilePathFromKey"));
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFontFile.VTable, "GetReferenceKey"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteFontFile.VTable, "GetLoader"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteFontFile.VTable, "Analyze"));
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFontFace.VTable, "GetType"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteFontFace.VTable, "GetFiles"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteFontFace.VTable, "GetIndex"));
    try testing.expectEqual(6 * p, @offsetOf(IDWriteFontFace.VTable, "GetSimulations"));
    try testing.expectEqual(8 * p, @offsetOf(IDWriteFontFace.VTable, "GetMetrics"));
    try testing.expectEqual(11 * p, @offsetOf(IDWriteFontFace.VTable, "GetGlyphIndices"));
    try testing.expectEqual(12 * p, @offsetOf(IDWriteFontFace.VTable, "TryGetFontTable"));
    try testing.expectEqual(13 * p, @offsetOf(IDWriteFontFace.VTable, "ReleaseFontTable"));
}

test "directwrite api: face iids" {
    const testing = std.testing;
    try testing.expectEqual(0x5f49804d, IID_IDWriteFontFace.Data1);
    try testing.expectEqual(0x7024, IID_IDWriteFontFace.Data2);
    try testing.expectEqual(0x49, IID_IDWriteFontFace.Data4[7]);
    try testing.expectEqual(0x739d886a, IID_IDWriteFontFile.Data1);
    try testing.expectEqual(0xcef5, IID_IDWriteFontFile.Data2);
    try testing.expectEqual(0xb0, IID_IDWriteFontFile.Data4[7]);
    try testing.expectEqual(0x727cad4e, IID_IDWriteFontFileLoader.Data1);
    try testing.expectEqual(0xd6af, IID_IDWriteFontFileLoader.Data2);
    try testing.expectEqual(0x49, IID_IDWriteFontFileLoader.Data4[7]);
    try testing.expectEqual(0xb2d9f3ec, IID_IDWriteLocalFontFileLoader.Data1);
    try testing.expectEqual(0xc9fe, IID_IDWriteLocalFontFileLoader.Data2);
    try testing.expectEqual(0xa2, IID_IDWriteLocalFontFileLoader.Data4[7]);
    try testing.expectEqual(0x6d4865fe, IID_IDWriteFontFileStream.Data1);
    try testing.expectEqual(0x0ab8, IID_IDWriteFontFileStream.Data2);
    try testing.expectEqual(0xe0, IID_IDWriteFontFileStream.Data4[7]);
}

// ---------------------------------------------------------------------------
// Font fallback: IDWriteFontFallback (dwrite_2.h), the
// IDWriteTextAnalysisSource it reads (dwrite.h), and the HRESULTs of
// winerror.h that the font code tells apart.

// HRESULTs from winerror.h. The DWRITE_E_ values are FACILITY_DWRITE
// (0x898) errors; the header writes them with an L suffix.
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
pub const DWRITE_E_FILEFORMAT: HRESULT = @bitCast(@as(u32, 0x88985000));
pub const DWRITE_E_UNEXPECTED: HRESULT = @bitCast(@as(u32, 0x88985001));
pub const DWRITE_E_NOFONT: HRESULT = @bitCast(@as(u32, 0x88985002));
pub const DWRITE_E_FILENOTFOUND: HRESULT = @bitCast(@as(u32, 0x88985003));
pub const DWRITE_E_FILEACCESS: HRESULT = @bitCast(@as(u32, 0x88985004));
pub const DWRITE_E_FONTCOLLECTIONOBSOLETE: HRESULT = @bitCast(@as(u32, 0x88985005));
pub const DWRITE_E_ALREADYREGISTERED: HRESULT = @bitCast(@as(u32, 0x88985006));
pub const DWRITE_E_NOCOLOR: HRESULT = @bitCast(@as(u32, 0x8898500C));

pub const IID_IDWriteTextAnalysisSource: GUID = GUID.parse("{688e1a58-5094-47c8-adc8-fbcea60ae92b}");
/// Only the IID: no IDWriteTextAnalysisSource1 is declared, so that an
/// IDWriteTextAnalysisSource implemented here can recognize a
/// QueryInterface for it and answer E_NOINTERFACE.
pub const IID_IDWriteTextAnalysisSource1: GUID = GUID.parse("{639cfad8-0fb4-4b21-a58a-067920120009}");
pub const IID_IDWriteFontFallback: GUID = GUID.parse("{efa008f9-f7a1-48bf-b05c-f224713cc0ff}");

pub const DWRITE_READING_DIRECTION = enum(c_int) {
    LEFT_TO_RIGHT = 0,
    RIGHT_TO_LEFT = 1,
    TOP_TO_BOTTOM = 2,
    BOTTOM_TO_TOP = 3,
    _,
};

pub const IDWriteNumberSubstitution = opaque {};

/// The text a font fallback or a text analyzer reads. DirectWrite only
/// consumes this interface; the caller implements it, so every method is
/// typed and the signatures are the header's exactly.
pub const IDWriteTextAnalysisSource = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteTextAnalysisSource;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        /// The text is not NUL-terminated: the length that comes back is
        /// what remains of the block from the position on. A null text
        /// marks the end of the text. (From the DirectWrite documentation;
        /// the header carries no annotations.)
        GetTextAtPosition: *const fn (
            *IDWriteTextAnalysisSource,
            UINT,
            *?[*]const WCHAR,
            *UINT,
        ) callconv(cc) HRESULT,
        GetTextBeforePosition: *const fn (
            *IDWriteTextAnalysisSource,
            UINT,
            *?[*]const WCHAR,
            *UINT,
        ) callconv(cc) HRESULT,
        GetParagraphReadingDirection: *const fn (*IDWriteTextAnalysisSource) callconv(cc) DWRITE_READING_DIRECTION,
        /// The locale name is NUL-terminated and has to stay valid until
        /// the next call or until the analysis returns. (From the
        /// DirectWrite documentation.)
        GetLocaleName: *const fn (
            *IDWriteTextAnalysisSource,
            UINT,
            *UINT,
            *?[*:0]const WCHAR,
        ) callconv(cc) HRESULT,
        GetNumberSubstitution: *const fn (
            *IDWriteTextAnalysisSource,
            UINT,
            *UINT,
            *?*IDWriteNumberSubstitution,
        ) callconv(cc) HRESULT,
    };
};

pub const IDWriteFontFallback = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFallback;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        /// The base collection and the base family name are optional. The
        /// mapped font comes back null, with S_OK, when no font can render
        /// the text; the mapped length is then the number of characters to
        /// skip. (From the DirectWrite documentation; the header carries no
        /// annotations.)
        MapCharacters: *const fn (
            *IDWriteFontFallback,
            *IDWriteTextAnalysisSource,
            UINT,
            UINT,
            ?*IDWriteFontCollection,
            ?[*:0]const WCHAR,
            DWRITE_FONT_WEIGHT,
            DWRITE_FONT_STYLE,
            DWRITE_FONT_STRETCH,
            *UINT,
            *?*IDWriteFont,
            *FLOAT,
        ) callconv(cc) HRESULT,
    };

    pub fn mapCharacters(
        self: *IDWriteFontFallback,
        source: *IDWriteTextAnalysisSource,
        position: UINT,
        length: UINT,
        basecollection: ?*IDWriteFontCollection,
        baseFamilyName: ?[*:0]const WCHAR,
        baseWeight: DWRITE_FONT_WEIGHT,
        baseStyle: DWRITE_FONT_STYLE,
        baseStretch: DWRITE_FONT_STRETCH,
        mappedLength: *UINT,
        mappedFont: *?*IDWriteFont,
        scale: *FLOAT,
    ) HRESULT {
        return self.vtable.MapCharacters(
            self,
            source,
            position,
            length,
            basecollection,
            baseFamilyName,
            baseWeight,
            baseStyle,
            baseStretch,
            mappedLength,
            mappedFont,
            scale,
        );
    }
};

test "directwrite api: fallback vtable slot counts" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(8 * p, @sizeOf(IDWriteTextAnalysisSource.VTable));
    try testing.expectEqual(4 * p, @sizeOf(IDWriteFontFallback.VTable));
}

test "directwrite api: fallback typed slot indices" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @offsetOf(IDWriteTextAnalysisSource.VTable, "GetTextAtPosition"));
    try testing.expectEqual(4 * p, @offsetOf(IDWriteTextAnalysisSource.VTable, "GetTextBeforePosition"));
    try testing.expectEqual(5 * p, @offsetOf(IDWriteTextAnalysisSource.VTable, "GetParagraphReadingDirection"));
    try testing.expectEqual(6 * p, @offsetOf(IDWriteTextAnalysisSource.VTable, "GetLocaleName"));
    try testing.expectEqual(7 * p, @offsetOf(IDWriteTextAnalysisSource.VTable, "GetNumberSubstitution"));
    try testing.expectEqual(3 * p, @offsetOf(IDWriteFontFallback.VTable, "MapCharacters"));
}

test "directwrite api: fallback iids" {
    const testing = std.testing;
    try testing.expectEqual(0xefa008f9, IID_IDWriteFontFallback.Data1);
    try testing.expectEqual(0xf7a1, IID_IDWriteFontFallback.Data2);
    try testing.expectEqual(0xff, IID_IDWriteFontFallback.Data4[7]);
    try testing.expectEqual(0x688e1a58, IID_IDWriteTextAnalysisSource.Data1);
    try testing.expectEqual(0x5094, IID_IDWriteTextAnalysisSource.Data2);
    try testing.expectEqual(0x2b, IID_IDWriteTextAnalysisSource.Data4[7]);
    try testing.expectEqual(0x639cfad8, IID_IDWriteTextAnalysisSource1.Data1);
    try testing.expectEqual(0x0fb4, IID_IDWriteTextAnalysisSource1.Data2);
    try testing.expectEqual(0x09, IID_IDWriteTextAnalysisSource1.Data4[7]);

    try testing.expectEqual(4, @sizeOf(DWRITE_READING_DIRECTION));
    try testing.expectEqual(3, @intFromEnum(DWRITE_READING_DIRECTION.BOTTOM_TO_TOP));

    try testing.expect(failed(E_NOINTERFACE));
    try testing.expect(failed(E_POINTER));
    try testing.expect(failed(E_OUTOFMEMORY));
    try testing.expect(failed(DWRITE_E_FILEFORMAT));
    try testing.expect(failed(DWRITE_E_UNEXPECTED));
    try testing.expect(failed(DWRITE_E_NOFONT));
    try testing.expect(failed(DWRITE_E_FILENOTFOUND));
    try testing.expect(failed(DWRITE_E_FILEACCESS));
    try testing.expect(failed(DWRITE_E_FONTCOLLECTIONOBSOLETE));
    try testing.expect(failed(DWRITE_E_ALREADYREGISTERED));
    try testing.expect(failed(DWRITE_E_NOCOLOR));
}

// ---------------------------------------------------------------------------
// The later font faces, dwrite_1.h to dwrite_3.h. An instance of a variable
// font reports the axis values that make it through IDWriteFontFace5.

pub const IID_IDWriteFontFace1: GUID = GUID.parse("{a71efdb4-9fdb-4838-ad90-cfc3be8c3daf}");
pub const IID_IDWriteFontFace2: GUID = GUID.parse("{d8b768ff-64bc-4e66-982b-ec8e87f693f7}");
pub const IID_IDWriteFontFace3: GUID = GUID.parse("{d37d7598-09be-4222-a236-2081341cc1f2}");
pub const IID_IDWriteFontFace4: GUID = GUID.parse("{27f2a904-4eb8-441d-9678-0563f53e3e2f}");
pub const IID_IDWriteFontFace5: GUID = GUID.parse("{98eff3a5-b667-479a-b145-e2fa5b9fdc29}");

/// An axis of a variable font and a value on it. The tag is a
/// DWRITE_FONT_AXIS_TAG: the axis's four characters with the first in the
/// low byte.
pub const DWRITE_FONT_AXIS_VALUE = extern struct {
    axisTag: UINT,
    value: FLOAT,
};

pub const IDWriteFontResource = opaque {};

// Overloads carry the interface's name in the header's C vtables, which
// are flat; the names here are the header's.

pub const IDWriteFontFace1 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFace1;

    pub const VTable = extern struct {
        base: IDWriteFontFace.VTable,
        IDWriteFontFace1_GetMetrics: Slot,
        IDWriteFontFace1_GetGdiCompatibleMetrics: Slot,
        GetCaretMetrics: Slot,
        GetUnicodeRanges: Slot,
        IsMonospacedFont: Slot,
        GetDesignGlyphAdvances: Slot,
        GetGdiCompatibleGlyphAdvances: Slot,
        GetKerningPairAdjustments: Slot,
        HasKerningPairs: Slot,
        IDWriteFontFace1_GetRecommendedRenderingMode: Slot,
        GetVerticalGlyphVariants: Slot,
        HasVerticalGlyphVariants: Slot,
    };
};

pub const IDWriteFontFace2 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFace2;

    pub const VTable = extern struct {
        base: IDWriteFontFace1.VTable,
        IsColorFont: Slot,
        GetColorPaletteCount: Slot,
        GetPaletteEntryCount: Slot,
        GetPaletteEntries: Slot,
        IDWriteFontFace2_GetRecommendedRenderingMode: Slot,
    };
};

pub const IDWriteFontFace3 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFace3;

    pub const VTable = extern struct {
        base: IDWriteFontFace2.VTable,
        GetFontFaceReference: Slot,
        GetPanose: Slot,
        GetWeight: Slot,
        GetStretch: Slot,
        GetStyle: Slot,
        GetFamilyNames: Slot,
        GetFaceNames: Slot,
        GetInformationalStrings: Slot,
        HasCharacter: Slot,
        IDWriteFontFace3_GetRecommendedRenderingMode: Slot,
        IsCharacterLocal: Slot,
        IsGlyphLocal: Slot,
        AreCharactersLocal: Slot,
        AreGlyphsLocal: Slot,
    };
};

pub const IDWriteFontFace4 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFace4;

    pub const VTable = extern struct {
        base: IDWriteFontFace3.VTable,
        /// The header's name: the overload that takes one glyph.
        GetGlyphImageFormats_: Slot,
        GetGlyphImageFormats: Slot,
        GetGlyphImageData: Slot,
        ReleaseGlyphImageData: Slot,
    };
};

pub const IDWriteFontFace5 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDWriteFontFace5;

    pub const VTable = extern struct {
        base: IDWriteFontFace4.VTable,
        GetFontAxisValueCount: *const fn (*IDWriteFontFace5) callconv(cc) UINT,
        /// Fills as many values as the count says there are; a smaller
        /// buffer is an error.
        GetFontAxisValues: *const fn (*IDWriteFontFace5, [*]DWRITE_FONT_AXIS_VALUE, UINT) callconv(cc) HRESULT,
        /// Whether any axis has a value other than its default.
        HasVariations: *const fn (*IDWriteFontFace5) callconv(cc) BOOL,
        GetFontResource: Slot,
        Equals: Slot,
    };
};

test "directwrite api: later faces vtable slot counts" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(30 * p, @sizeOf(IDWriteFontFace1.VTable));
    try testing.expectEqual(35 * p, @sizeOf(IDWriteFontFace2.VTable));
    try testing.expectEqual(49 * p, @sizeOf(IDWriteFontFace3.VTable));
    try testing.expectEqual(53 * p, @sizeOf(IDWriteFontFace4.VTable));
    try testing.expectEqual(58 * p, @sizeOf(IDWriteFontFace5.VTable));
}

test "directwrite api: later faces typed slot indices" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(18 * p, @offsetOf(IDWriteFontFace1.VTable, "IDWriteFontFace1_GetMetrics"));
    try testing.expectEqual(30 * p, @offsetOf(IDWriteFontFace2.VTable, "IsColorFont"));
    try testing.expectEqual(35 * p, @offsetOf(IDWriteFontFace3.VTable, "GetFontFaceReference"));
    try testing.expectEqual(49 * p, @offsetOf(IDWriteFontFace4.VTable, "GetGlyphImageFormats_"));
    try testing.expectEqual(53 * p, @offsetOf(IDWriteFontFace5.VTable, "GetFontAxisValueCount"));
    try testing.expectEqual(54 * p, @offsetOf(IDWriteFontFace5.VTable, "GetFontAxisValues"));
    try testing.expectEqual(55 * p, @offsetOf(IDWriteFontFace5.VTable, "HasVariations"));
}

test "directwrite api: later faces struct layouts" {
    const testing = std.testing;
    try testing.expectEqual(8, @sizeOf(DWRITE_FONT_AXIS_VALUE));
    try testing.expectEqual(4, @offsetOf(DWRITE_FONT_AXIS_VALUE, "value"));
}

test "directwrite api: later faces iids" {
    const testing = std.testing;
    try testing.expectEqual(0xa71efdb4, IID_IDWriteFontFace1.Data1);
    try testing.expectEqual(0xaf, IID_IDWriteFontFace1.Data4[7]);
    try testing.expectEqual(0xd8b768ff, IID_IDWriteFontFace2.Data1);
    try testing.expectEqual(0xf7, IID_IDWriteFontFace2.Data4[7]);
    try testing.expectEqual(0xd37d7598, IID_IDWriteFontFace3.Data1);
    try testing.expectEqual(0xf2, IID_IDWriteFontFace3.Data4[7]);
    try testing.expectEqual(0x27f2a904, IID_IDWriteFontFace4.Data1);
    try testing.expectEqual(0x2f, IID_IDWriteFontFace4.Data4[7]);
    try testing.expectEqual(0x98eff3a5, IID_IDWriteFontFace5.Data1);
    try testing.expectEqual(0xb667, IID_IDWriteFontFace5.Data2);
    try testing.expectEqual(0x29, IID_IDWriteFontFace5.Data4[7]);
}
