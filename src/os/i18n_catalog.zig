//! A message catalog in GNU gettext's binary format (.mo), read in place:
//! what `msgfmt` compiles a .po into, and all of gettext that a lookup by
//! message id needs. For a platform with no libintl (Windows).
//!
//! The format is "The Format of GNU MO Files" in the gettext manual
//! (https://www.gnu.org/software/gettext/manual/html_node/MO-Files.html):
//! a header, a table of the original strings and one of their
//! translations, each entry a length and an offset, and the strings
//! themselves, each followed by a NUL its length leaves out. "The
//! strings are sorted in lexicographical order" of the originals, which
//! is what a lookup's binary search relies on. The hash table, which is
//! optional, is not read. A message with a context is stored as
//! "context\x04id" and one with a plural as "singular\x00plural", its
//! translation the forms with a NUL between: a lookup by a plain id
//! finds neither, and none is asked for here.
const Catalog = @This();

const std = @import("std");

/// The whole file. Every string handed out points into it.
bytes: []const u8,
count: u32,
originals: u32,
translations: u32,

pub const Error = error{
    /// Not a little-endian .mo file of major revision 0, or too short to
    /// hold what its header says it holds.
    InvalidCatalog,
};

const magic: u32 = 0x950412de;
const header_len = 28;
const entry_len = 8;

/// Read `bytes` as a catalog, which must outlive it. Checked here, once:
/// that both tables and every string they name lie inside the file with
/// their NULs, and that the originals are in order, so that `get` cannot
/// read outside it or miss a message that is there.
pub fn init(bytes: []const u8) Error!Catalog {
    if (bytes.len < header_len) return error.InvalidCatalog;
    // The format's offsets are 32 bits, and so is the arithmetic on them
    // here once this holds.
    if (bytes.len > std.math.maxInt(u32)) return error.InvalidCatalog;
    // msgfmt writes in the byte order of the machine it runs on unless
    // told which; the build tells it little-endian.
    if (word(bytes, 0) != magic) return error.InvalidCatalog;
    // "The major revision is 0 or 1"; revision 1 only adds system
    // dependent strings after the tables, which a reader of 0 ignores.
    if (word(bytes, 4) >> 16 > 1) return error.InvalidCatalog;
    const self: Catalog = .{
        .bytes = bytes,
        .count = word(bytes, 8),
        .originals = word(bytes, 12),
        .translations = word(bytes, 16),
    };
    const table = @as(u64, self.count) * entry_len;
    if (@as(u64, self.originals) + table > bytes.len) return error.InvalidCatalog;
    if (@as(u64, self.translations) + table > bytes.len) return error.InvalidCatalog;

    var previous: ?[]const u8 = null;
    for (0..self.count) |i| {
        const index: u32 = @intCast(i);
        const original = try self.checked(self.originals, index);
        _ = try self.checked(self.translations, index);
        if (previous) |p| {
            if (std.mem.order(u8, p, original) != .lt) return error.InvalidCatalog;
        }
        previous = original;
    }
    return self;
}

/// The translation of `msgid`, or null if the catalog has none: the
/// message is not in it, or is there untranslated (an empty string, which
/// msgfmt leaves out but another compiler may not).
pub fn get(self: *const Catalog, msgid: []const u8) ?[:0]const u8 {
    // The header entry, whose id is empty: its "translation" is the
    // catalog's own description, not a message's.
    if (msgid.len == 0) return null;
    var low: u32 = 0;
    var high: u32 = self.count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, self.string(self.originals, mid), msgid)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => {
                const found = self.string(self.translations, mid);
                return if (found.len == 0) null else found;
            },
        }
    }
    return null;
}

/// Whether every translation is UTF-8, as one compiled from a .po whose
/// charset is UTF-8 is. The format itself holds bytes in any charset its
/// header names.
pub fn utf8(self: *const Catalog) bool {
    for (0..self.count) |i| {
        if (!std.unicode.utf8ValidateSlice(self.string(self.translations, @intCast(i)))) return false;
    }
    return true;
}

/// Entry `index` of the table at `table`, as `init` checked it.
fn string(self: *const Catalog, table: u32, index: u32) [:0]const u8 {
    const at = table + index * entry_len;
    const len = word(self.bytes, at);
    const offset = word(self.bytes, at + 4);
    return self.bytes[offset..][0..len :0];
}

/// `string`, for `init`: an error if the entry's string or its NUL is
/// outside the file.
fn checked(self: *const Catalog, table: u32, index: u32) Error![]const u8 {
    const at = table + index * entry_len;
    const len: u64 = word(self.bytes, at);
    const offset: u64 = word(self.bytes, at + 4);
    if (offset + len >= self.bytes.len) return error.InvalidCatalog;
    const end: usize = @intCast(offset + len);
    if (self.bytes[end] != 0) return error.InvalidCatalog;
    return self.bytes[@intCast(offset)..end];
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// For tests: `pairs`, each an id and its translation, as a .mo file's
/// bytes, the ids sorted as the format asks. The caller frees it.
pub fn write(alloc: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    const sorted = try alloc.dupe([2][]const u8, pairs);
    defer alloc.free(sorted);
    std.mem.sort([2][]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return std.mem.order(u8, a[0], b[0]) == .lt;
        }
    }.lessThan);

    const count: u32 = @intCast(sorted.len);
    const originals: u32 = header_len;
    const translations: u32 = originals + count * entry_len;
    var size: usize = translations + count * entry_len;
    for (sorted) |pair| size += pair[0].len + 1 + pair[1].len + 1;
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    @memset(out, 0);

    put(out, 0, magic);
    put(out, 4, 0);
    put(out, 8, count);
    put(out, 12, originals);
    put(out, 16, translations);
    // No hash table: size 0, at the end of the tables.
    put(out, 20, 0);
    put(out, 24, translations + count * entry_len);

    var at: usize = translations + count * entry_len;
    for ([_]u32{ originals, translations }, 0..) |table, which| {
        for (sorted, 0..) |pair, i| {
            const text = pair[which];
            const entry = table + @as(u32, @intCast(i)) * entry_len;
            put(out, entry, @intCast(text.len));
            put(out, entry + 4, @intCast(at));
            @memcpy(out[at..][0..text.len], text);
            at += text.len + 1;
        }
    }
    std.debug.assert(at == size);
    return out;
}

fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

test "a catalog finds each message's translation, and nothing else" {
    const alloc = std.testing.allocator;
    const bytes = try write(alloc, &.{
        .{ "", "Content-Type: text/plain; charset=UTF-8\n" },
        .{ "Paste", "Einf\u{fc}gen" },
        .{ "Copy", "Kopieren" },
        .{ "Close Tab?", "Tab schlie\u{df}en?" },
        .{ "Untranslated", "" },
        .{ "Copy\x04context", "nie" },
    });
    defer alloc.free(bytes);
    const catalog = try init(bytes);
    try std.testing.expectEqualStrings("Kopieren", catalog.get("Copy").?);
    try std.testing.expectEqualStrings("Einf\u{fc}gen", catalog.get("Paste").?);
    try std.testing.expectEqualStrings("Tab schlie\u{df}en?", catalog.get("Close Tab?").?);
    // Its NUL is the file's own.
    try std.testing.expectEqual(0, catalog.get("Copy").?.ptr[8]);
    try std.testing.expect(catalog.utf8());
    // Not there, there untranslated, the header, and a prefix or an
    // extension of one that is.
    try std.testing.expect(catalog.get("Cut") == null);
    try std.testing.expect(catalog.get("Untranslated") == null);
    try std.testing.expect(catalog.get("") == null);
    try std.testing.expect(catalog.get("Cop") == null);
    try std.testing.expect(catalog.get("Copy ") == null);
    try std.testing.expect(catalog.get("copy") == null);
}

test "a catalog of any messages gives back what went in" {
    // Against the pairs themselves: every id finds its own translation,
    // whatever the order they were given in, and an id that is not among
    // them finds none.
    const alloc = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x6d6f);
    const random = prng.random();
    for (0..200) |_| {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
        var pairs: std.ArrayList([2][]const u8) = .empty;
        for (0..random.uintLessThan(usize, 40)) |_| {
            const id = try a.alloc(u8, 1 + random.uintLessThan(usize, 6));
            // Few letters, so that ids share prefixes and collide.
            for (id) |*c| c.* = "abc"[random.uintLessThan(usize, 3)];
            if (seen.contains(id)) continue;
            const text = try a.alloc(u8, 1 + random.uintLessThan(usize, 12));
            for (text) |*c| c.* = random.intRangeAtMost(u8, 1, 255);
            try seen.put(a, id, text);
            try pairs.append(a, .{ id, text });
        }
        const bytes = try write(a, pairs.items);
        const catalog = try init(bytes);
        var it = seen.iterator();
        while (it.next()) |entry| {
            try std.testing.expectEqualStrings(entry.value_ptr.*, catalog.get(entry.key_ptr.*).?);
        }
        for (0..50) |_| {
            var buf: [7]u8 = undefined;
            const id = buf[0 .. 1 + random.uintLessThan(usize, 7)];
            for (id) |*c| c.* = "abc"[random.uintLessThan(usize, 3)];
            try std.testing.expectEqual(seen.contains(id), catalog.get(id) != null);
        }
    }
}

test "a catalog with a translation that is not UTF-8 says so" {
    const alloc = std.testing.allocator;
    const bytes = try write(alloc, &.{ .{ "Copy", "Kopieren" }, .{ "Paste", "Einf\xfcgen" } });
    defer alloc.free(bytes);
    const catalog = try init(bytes);
    // Still found: it is the reader of the catalog who asks.
    try std.testing.expectEqualStrings("Einf\xfcgen", catalog.get("Paste").?);
    try std.testing.expect(!catalog.utf8());
}

test "a catalog that is not one, or that points outside itself, is refused" {
    const alloc = std.testing.allocator;
    const good = try write(alloc, &.{ .{ "Copy", "Kopieren" }, .{ "Paste", "Einf\u{fc}gen" } });
    defer alloc.free(good);
    _ = try init(good);

    try std.testing.expectError(error.InvalidCatalog, init(""));
    try std.testing.expectError(error.InvalidCatalog, init(good[0 .. header_len - 1]));
    // Cut anywhere, it no longer holds what its tables name.
    for (header_len..good.len) |len| {
        try std.testing.expectError(error.InvalidCatalog, init(good[0..len]));
    }

    const bad = try alloc.dupe(u8, good);
    defer alloc.free(bad);
    const Case = struct { at: usize, value: u32 };
    for ([_]Case{
        // Big-endian, or another file.
        .{ .at = 0, .value = 0xde120495 },
        // A major revision this does not know.
        .{ .at = 4, .value = 2 << 16 },
        // More strings than the file has room for; tables past its end.
        .{ .at = 8, .value = 1 << 30 },
        .{ .at = 12, .value = @intCast(good.len) },
        .{ .at = 16, .value = std.math.maxInt(u32) },
        // The first original's length runs past its NUL, then its offset
        // past the file; the first translation's likewise.
        .{ .at = header_len, .value = 5 },
        .{ .at = header_len + 4, .value = std.math.maxInt(u32) },
        .{ .at = header_len + 2 * entry_len, .value = 9 },
        .{ .at = header_len + 2 * entry_len + 4, .value = @intCast(good.len) },
    }) |case| {
        @memcpy(bad, good);
        put(bad, case.at, case.value);
        try std.testing.expectError(error.InvalidCatalog, init(bad));
    }

    // Originals out of order: a search would miss one.
    const unsorted = try write(alloc, &.{ .{ "a", "1" }, .{ "b", "2" } });
    defer alloc.free(unsorted);
    const first = unsorted[header_len..][0..entry_len].*;
    @memcpy(unsorted[header_len..][0..entry_len], unsorted[header_len + entry_len ..][0..entry_len]);
    @memcpy(unsorted[header_len + entry_len ..][0..entry_len], &first);
    try std.testing.expectError(error.InvalidCatalog, init(unsorted));
}
