//! Translations on Windows, which has no libintl: the catalogs msgfmt
//! compiles from po/ are part of the program (the build's
//! `i18n_catalogs` module), and one of them is read in place
//! (`i18n_catalog.zig`) for the language the user reads Windows in, or
//! the one the `language` option names.
//!
//! As gettext, a language with no catalog falls back to the next the
//! user listed, and a message with no translation shows as it is written
//! in the source. Unlike gettext, English ends the search: the source is
//! in English, so a user who lists it before a language Ghostty is
//! translated to is not shown that one.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const Catalog = @import("i18n_catalog.zig");
const locales = @import("i18n_locales.zig").locales;

const log = std.log.scoped(.i18n);

/// Whether the catalogs are part of this program: of the Windows app that
/// translates, and of nothing else.
const embedded = build_config.i18n and
    builtin.os.tag == .windows and
    build_config.app_runtime == .windows;

/// The catalog in use, null for the source's English. Written by `use`
/// alone, which the app calls once as it starts, before anything
/// translates.
var catalog: ?Catalog = null;

/// What a language the user names comes to.
pub const Match = union(enum) {
    /// A catalog: its place in `locales`.
    locale: usize,
    /// English, or "C": the source's own strings.
    source,
    /// Nothing Ghostty is translated to.
    none,
};

/// The catalog for a language, named as Windows names one ("de-DE",
/// "zh-Hans-CN", "sr-Latn-RS") or as gettext does ("de", "de_DE.UTF-8",
/// "sr@latin"). A region Ghostty has no catalog for takes the
/// language's own, and failing that the first of the language's in
/// `locales`, as that list's order is for: "es-MX" reads "es_BO".
pub fn match(name: []const u8) Match {
    // gettext's form: language[_region][.encoding][@modifier].
    const at = std.mem.lastIndexOfScalar(u8, name, '@');
    const modifier: ?[]const u8 = if (at) |i| name[i + 1 ..] else null;
    const before = name[0 .. at orelse name.len];
    const tag = before[0 .. std.mem.indexOfScalar(u8, before, '.') orelse before.len];
    if (std.mem.eql(u8, tag, "C") or std.mem.eql(u8, tag, "POSIX")) return .source;

    // Windows' form: language[-script][-region], then variants. A script
    // is four letters, a region two letters or three digits.
    var it = std.mem.tokenizeAny(u8, tag, "-_");
    var language_buf: [8]u8 = undefined;
    const language = lower(&language_buf, it.next() orelse return .none) orelse return .none;
    var script_buf: [4]u8 = undefined;
    var script: ?[]const u8 = null;
    var region_buf: [3]u8 = undefined;
    var region: ?[]const u8 = null;
    while (it.next()) |part| {
        if (region != null) break;
        if (part.len == 4 and script == null) {
            script = lower(&script_buf, part);
        } else if (part.len == 2 or (part.len == 3 and std.ascii.isDigit(part[0]))) {
            region = std.ascii.upperString(&region_buf, part);
        }
    }

    if (std.mem.eql(u8, language, "en")) return .source;

    // The two languages whose catalogs differ by script, which Windows
    // names and gettext leaves to the region or a modifier.
    if (std.mem.eql(u8, language, "zh")) {
        const traditional = if (script) |s|
            std.mem.eql(u8, s, "hant")
        else if (region) |r|
            std.mem.eql(u8, r, "TW") or std.mem.eql(u8, r, "HK") or std.mem.eql(u8, r, "MO")
        else
            false;
        return if (traditional) named("zh_TW") else named("zh_CN");
    }
    if (std.mem.eql(u8, language, "sr")) {
        const latin = if (script) |s|
            std.mem.eql(u8, s, "latn")
        else if (modifier) |m|
            std.mem.eql(u8, m, "latin")
        else
            false;
        return if (latin) named("sr@latin") else named("sr");
    }

    if (region) |r| {
        var buf: [language_buf.len + 1 + region_buf.len]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}_{s}", .{ language, r }) catch unreachable;
        if (indexOf(full)) |i| return .{ .locale = i };
    }
    if (indexOf(language)) |i| return .{ .locale = i };
    for (locales, 0..) |locale, i| {
        if (locale.len > language.len and
            locale[language.len] == '_' and
            std.mem.startsWith(u8, locale, language)) return .{ .locale = i };
    }
    return .none;
}

fn lower(buf: []u8, text: []const u8) ?[]const u8 {
    if (text.len > buf.len) return null;
    return std.ascii.lowerString(buf, text);
}

fn indexOf(name: []const u8) ?usize {
    for (locales, 0..) |locale, i| {
        if (std.mem.eql(u8, locale, name)) return i;
    }
    return null;
}

/// A locale `match` names outright, which must be one of `locales`.
fn named(comptime name: []const u8) Match {
    const index = comptime for (locales, 0..) |locale, i| {
        if (std.mem.eql(u8, locale, name)) break i;
    } else @compileError("no such locale: " ++ name);
    return .{ .locale = index };
}

/// The first of `names`, in the user's order, that Ghostty has an answer
/// for: a catalog, or English. Null if it has none for any of them.
pub fn first(names: []const []const u8) ?Match {
    for (names) |name| switch (match(name)) {
        .none => {},
        else => |m| return m,
    };
    return null;
}

/// Choose the language to translate to: `language`, the configuration's,
/// if it is set, or else the first of the languages the user reads
/// Windows in that Ghostty has. Called once, as the app starts.
///
/// Not in a test, which names its own catalog (`testUse`): what it
/// expects must not follow the language of the machine it runs on.
pub fn use(language: ?[]const u8) void {
    if (comptime !embedded or builtin.is_test) return;
    switch (choose(language, system())) {
        .source, .none => {
            catalog = null;
            log.info("translations: none, the source's English", .{});
        },
        .locale => |i| {
            catalog = usable(@import("i18n_catalogs").catalogs[i]) catch |err| {
                catalog = null;
                log.warn("translations: catalog unusable locale={s} err={}", .{ locales[i], err });
                return;
            };
            log.info("translations: locale={s}", .{locales[i]});
        },
    }
}

/// What `use` translates to: `language` if it is set, whatever
/// `display`, the user's display languages' answer, is; a language
/// Ghostty is not translated to reads the source's English, as it does
/// with gettext.
fn choose(language: ?[]const u8, display: Match) Match {
    const name = language orelse return display;
    return switch (match(name)) {
        .none => none: {
            log.warn("no translation for language={s}", .{name});
            break :none .source;
        },
        else => |m| m,
    };
}

/// `bytes` as a catalog whose every translation is UTF-8, which is what
/// those who show one take it for.
fn usable(bytes: []const u8) error{ InvalidCatalog, NotUtf8 }!Catalog {
    const c = try Catalog.init(bytes);
    if (!c.utf8()) return error.NotUtf8;
    return c;
}

/// The names of the user's display languages in their order, each ended
/// by a NUL, in `buf`; null if Windows does not say.
fn displayLanguages(buf: *[1024]u16) ?[]const u16 {
    // Each name is at most LOCALE_NAME_MAX_LENGTH (85) with its NUL; a
    // user lists a handful.
    var len: std.os.windows.ULONG = buf.len;
    var count: std.os.windows.ULONG = 0;
    if (!GetUserPreferredUILanguages(MUI_LANGUAGE_NAME, &count, buf, &len).toBool()) {
        log.warn("GetUserPreferredUILanguages failed err={}", .{std.os.windows.GetLastError()});
        return null;
    }
    return buf[0..@min(len, buf.len)];
}

/// The user's display languages' answer, as `first` gives it; English if
/// Ghostty has none.
fn system() Match {
    var buf: [1024]u16 = undefined;
    return listed(displayLanguages(&buf) orelse return .source);
}

/// `system`, of the names Windows gave.
fn listed(names: []const u16) Match {
    var it = std.mem.tokenizeScalar(u16, names, 0);
    while (it.next()) |wide| {
        var name_buf: [85]u8 = undefined;
        if (wide.len > name_buf.len) continue;
        // A language's name is ASCII.
        for (wide, name_buf[0..wide.len]) |unit, *byte| byte.* = if (unit < 0x80) @intCast(unit) else '?';
        switch (match(name_buf[0..wide.len])) {
            .none => {},
            else => |m| return m,
        }
    }
    return .source;
}

/// https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-getuserpreferreduilanguages
extern "kernel32" fn GetUserPreferredUILanguages(
    flags: std.os.windows.DWORD,
    count: *std.os.windows.ULONG,
    buffer: ?[*]u16,
    len: *std.os.windows.ULONG,
) callconv(.winapi) std.os.windows.BOOL;
/// Names ("de-DE") rather than language ids.
const MUI_LANGUAGE_NAME: std.os.windows.DWORD = 0x8;

/// `msgid` in the language in use, or itself.
pub fn translate(msgid: [*:0]const u8) [*:0]const u8 {
    const c = catalog orelse return msgid;
    return (c.get(std.mem.span(msgid)) orelse return msgid).ptr;
}

/// For tests: translate with `bytes`, a catalog, or with none.
pub fn testUse(bytes: ?[]const u8) error{ InvalidCatalog, NotUtf8 }!void {
    catalog = if (bytes) |b| try usable(b) else null;
}

test "each locale's own name finds it, as gettext and as Windows write it" {
    const testing = std.testing;
    for (locales, 0..) |locale, i| {
        try testing.expectEqual(Match{ .locale = i }, match(locale));
        var buf: [32]u8 = undefined;
        const utf8 = try std.fmt.bufPrint(&buf, "{s}.UTF-8", .{locale});
        // gettext writes a modifier after the encoding.
        if (std.mem.indexOfScalar(u8, locale, '@') == null) {
            try testing.expectEqual(Match{ .locale = i }, match(utf8));
            const dashed = try std.fmt.bufPrint(&buf, "{s}", .{locale});
            std.mem.replaceScalar(u8, dashed, '_', '-');
            try testing.expectEqual(Match{ .locale = i }, match(dashed));
        }
    }
}

test "a language Windows names finds its catalog" {
    const testing = std.testing;
    const Case = struct { []const u8, ?[]const u8 };
    for ([_]Case{
        .{ "de-DE", "de" },
        .{ "de-AT", "de" },
        .{ "fr-CA", "fr" },
        .{ "ja-JP", "ja" },
        .{ "nb-NO", "nb" },
        .{ "ko-KR", "ko_KR" },
        .{ "ko", "ko_KR" },
        .{ "pt-BR", "pt_BR" },
        // No catalog of its own, nor one for the language alone: the
        // language's first.
        .{ "pt-PT", "pt_BR" },
        .{ "es-ES", "es_ES" },
        .{ "es-AR", "es_AR" },
        .{ "es-MX", "es_BO" },
        .{ "es-419", "es_BO" },
        .{ "es", "es_BO" },
        // By script, then by region.
        .{ "zh-Hans-CN", "zh_CN" },
        .{ "zh-Hans-SG", "zh_CN" },
        .{ "zh-Hant-TW", "zh_TW" },
        .{ "zh-Hant-HK", "zh_TW" },
        .{ "zh-Hans-HK", "zh_CN" },
        .{ "zh-CN", "zh_CN" },
        .{ "zh-TW", "zh_TW" },
        .{ "zh-HK", "zh_TW" },
        .{ "zh", "zh_CN" },
        // An extended language is no region.
        .{ "zh-yue-HK", "zh_TW" },
        .{ "sr-Latn-RS", "sr@latin" },
        .{ "sr-Cyrl-RS", "sr" },
        .{ "sr-RS", "sr" },
        .{ "sr_RS.UTF-8@latin", "sr@latin" },
        // A variant after the region, and any case.
        .{ "ca-ES-valencia", "ca" },
        .{ "DE-de", "de" },
        .{ "PT_br", "pt_BR" },
        // Not translated to.
        .{ "nn-NO", null },
        .{ "sv-SE", null },
        .{ "fil-PH", null },
        .{ "", null },
        .{ "-", null },
        .{ "@latin", null },
        .{ "abcdefghi-DE", null },
    }) |case| {
        const want: Match = if (case[1]) |name| .{ .locale = indexOf(name).? } else .none;
        testing.expectEqual(want, match(case[0])) catch |err| {
            std.debug.print("language {s}\n", .{case[0]});
            return err;
        };
    }
    for ([_][]const u8{ "en-US", "en-GB", "en", "en_US.UTF-8", "C", "POSIX", "C.UTF-8" }) |name| {
        try testing.expectEqual(Match.source, match(name));
    }
}

test "the first language with an answer is taken, and English is one" {
    const testing = std.testing;
    const de: Match = .{ .locale = indexOf("de").? };
    try testing.expectEqual(de, first(&.{ "de-DE", "fr-FR" }).?);
    try testing.expectEqual(de, first(&.{ "sv-SE", "de-DE", "fr-FR" }).?);
    try testing.expectEqual(Match.source, first(&.{ "en-US", "de-DE" }).?);
    try testing.expectEqual(Match.source, first(&.{ "sv-SE", "en-GB", "de-DE" }).?);
    try testing.expect(first(&.{ "sv-SE", "fi-FI" }) == null);
    try testing.expect(first(&.{}) == null);
}

test "the configuration's language is chosen before the display languages', and one unknown reads English" {
    const testing = std.testing;
    const de: Match = .{ .locale = indexOf("de").? };
    const fr: Match = .{ .locale = indexOf("fr").? };
    try testing.expectEqual(de, choose(null, de));
    try testing.expectEqual(Match.source, choose(null, .source));
    try testing.expectEqual(fr, choose("fr", de));
    try testing.expectEqual(fr, choose("fr_FR.UTF-8", .source));
    try testing.expectEqual(Match.source, choose("en", de));
    try testing.expectEqual(Match.source, choose("sv", de));
}

test "the display languages Windows lists are read in their order" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const de: Match = .{ .locale = indexOf("de").? };
    try testing.expectEqual(de, listed(L("de-DE\x00fr-FR\x00\x00")));
    try testing.expectEqual(de, listed(L("sv-SE\x00de-DE\x00en-US\x00\x00")));
    try testing.expectEqual(Match.source, listed(L("en-US\x00de-DE\x00\x00")));
    try testing.expectEqual(Match.source, listed(L("sv-SE\x00\x00")));
    try testing.expectEqual(Match.source, listed(L("\x00")));
    try testing.expectEqual(Match.source, listed(L("")));
    // A name that is not ASCII is no language's.
    try testing.expectEqual(de, listed(L("d\u{e9}-DE\x00de-DE\x00\x00")));

    if (builtin.os.tag != .windows) return;
    // Windows lists one at least, each a name `match` can read.
    var buf: [1024]u16 = undefined;
    const names = displayLanguages(&buf) orelse return error.TestUnexpectedResult;
    var it = std.mem.tokenizeScalar(u16, names, 0);
    var count: usize = 0;
    while (it.next()) |name| : (count += 1) {
        try testing.expect(name.len >= 2 and name.len < 85);
        for (name) |unit| try testing.expect(unit < 0x80);
    }
    try testing.expect(count >= 1);
}

test "a message is translated by the catalog in use, or shown as written" {
    const testing = std.testing;
    const bytes = try Catalog.write(testing.allocator, &.{
        .{ "Copy", "Kopieren" },
        .{ "Paste", "" },
    });
    defer testing.allocator.free(bytes);
    try testUse(bytes);
    defer testUse(null) catch unreachable;
    try testing.expectEqualStrings("Kopieren", std.mem.span(translate("Copy")));
    try testing.expectEqualStrings("Paste", std.mem.span(translate("Paste")));
    try testing.expectEqualStrings("Cut", std.mem.span(translate("Cut")));
    try testUse(null);
    try testing.expectEqualStrings("Copy", std.mem.span(translate("Copy")));

    // One with a translation that is not UTF-8 is not used.
    const bad = try Catalog.write(testing.allocator, &.{.{ "Copy", "Kop\xffieren" }});
    defer testing.allocator.free(bad);
    try testing.expectError(error.NotUtf8, testUse(bad));
    try testing.expectEqualStrings("Copy", std.mem.span(translate("Copy")));
}

test "every catalog the build carries is one, and says something" {
    if (comptime !embedded) return error.SkipZigTest;
    const testing = std.testing;
    const catalogs = @import("i18n_catalogs").catalogs;
    try testing.expectEqual(locales.len, catalogs.len);
    for (catalogs, locales) |bytes, locale| {
        const c = Catalog.init(bytes) catch |err| {
            std.debug.print("locale {s}\n", .{locale});
            return err;
        };
        // Its header, and a message at least: msgfmt leaves out what is
        // not translated.
        try testing.expect(c.count >= 2);
        try testing.expect(c.get("") == null);
        try testing.expect(c.utf8());
    }
}
