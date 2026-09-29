//! The text that DirectWrite's font fallback is asked about: a run of
//! UTF-16 in one locale, read left to right, which is all a terminal has
//! to say about a codepoint it needs a font for.
//!
//! DirectWrite reads the text through IDWriteTextAnalysisSource, which the
//! caller implements. The object is counted and frees itself with its
//! last reference, so it is right whether or not DirectWrite keeps the
//! source beyond the call it was passed to.
const TextAnalysisSource = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const object = @import("object.zig");

const Object = object.Object(api.IDWriteTextAnalysisSource, TextAnalysisSource);

/// A codepoint is one or two units.
text: [2]u16,
len: u32,

/// NUL-terminated, and alive for longer than the source: the locale of
/// the process's DirectWrite state.
locale: [*:0]const u16,

pub const iids: []const *const api.GUID = &.{&api.IID_IDWriteTextAnalysisSource};

/// How many sources exist. DirectWrite is given a source for the length
/// of a call and may keep it for longer; the tests read here that it
/// does not.
pub var live: std.atomic.Value(usize) = .init(0);

pub fn deinit(self: *TextAnalysisSource) void {
    _ = self;
    _ = live.fetchSub(1, .monotonic);
}

const vtable: api.IDWriteTextAnalysisSource.VTable = .{
    .base = Object.unknown,
    .GetTextAtPosition = getTextAtPosition,
    .GetTextBeforePosition = getTextBeforePosition,
    .GetParagraphReadingDirection = getParagraphReadingDirection,
    .GetLocaleName = getLocaleName,
    .GetNumberSubstitution = getNumberSubstitution,
};

/// A source for one codepoint, with one reference that is the caller's.
pub fn create(
    alloc: Allocator,
    codepoint: u21,
    locale: [*:0]const u16,
) Allocator.Error!*api.IDWriteTextAnalysisSource {
    var self: TextAnalysisSource = .{
        .text = undefined,
        .len = 0,
        .locale = locale,
    };
    if (codepoint < 0x10000) {
        self.text[0] = @intCast(codepoint);
        self.len = 1;
    } else {
        const v = codepoint - 0x10000;
        self.text[0] = @intCast(0xD800 + (v >> 10));
        self.text[1] = @intCast(0xDC00 + (v & 0x3FF));
        self.len = 2;
    }

    const obj = try Object.create(alloc, &vtable, self);
    _ = live.fetchAdd(1, .monotonic);
    return &obj.interface;
}

/// The text from a position on, or nothing at its end.
fn getTextAtPosition(
    this: *api.IDWriteTextAnalysisSource,
    position: api.UINT,
    text: *?[*]const api.WCHAR,
    text_len: *api.UINT,
) callconv(api.cc) api.HRESULT {
    const self = &Object.from(this).impl;
    if (position >= self.len) {
        text.* = null;
        text_len.* = 0;
        return api.S_OK;
    }
    text.* = self.text[position..].ptr;
    text_len.* = self.len - position;
    return api.S_OK;
}

/// The text up to a position, or nothing at its start.
fn getTextBeforePosition(
    this: *api.IDWriteTextAnalysisSource,
    position: api.UINT,
    text: *?[*]const api.WCHAR,
    text_len: *api.UINT,
) callconv(api.cc) api.HRESULT {
    const self = &Object.from(this).impl;
    if (position == 0 or position > self.len) {
        text.* = null;
        text_len.* = 0;
        return api.S_OK;
    }
    text.* = &self.text;
    text_len.* = position;
    return api.S_OK;
}

fn getParagraphReadingDirection(
    this: *api.IDWriteTextAnalysisSource,
) callconv(api.cc) api.DWRITE_READING_DIRECTION {
    _ = this;
    return .LEFT_TO_RIGHT;
}

/// One locale for all of the text.
fn getLocaleName(
    this: *api.IDWriteTextAnalysisSource,
    position: api.UINT,
    text_len: *api.UINT,
    locale: *?[*:0]const api.WCHAR,
) callconv(api.cc) api.HRESULT {
    const self = &Object.from(this).impl;
    text_len.* = self.len -| position;
    locale.* = self.locale;
    return api.S_OK;
}

/// No number substitution anywhere in the text.
fn getNumberSubstitution(
    this: *api.IDWriteTextAnalysisSource,
    position: api.UINT,
    text_len: *api.UINT,
    substitution: *?*api.IDWriteNumberSubstitution,
) callconv(api.cc) api.HRESULT {
    const self = &Object.from(this).impl;
    text_len.* = self.len -| position;
    substitution.* = null;
    return api.S_OK;
}

test "directwrite text analysis source" {
    const testing = std.testing;
    const locale: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

    // Outside the basic plane: two units, read as DirectWrite reads
    // them, through the vtable.
    const source = try create(testing.allocator, 0x1F600, locale);
    defer api.release(source);

    var text: ?[*]const u16 = null;
    var len: api.UINT = 99;
    try testing.expectEqual(api.S_OK, source.vtable.GetTextAtPosition(source, 0, &text, &len));
    try testing.expectEqual(2, len);
    try testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE00 }, text.?[0..len]);

    try testing.expectEqual(api.S_OK, source.vtable.GetTextAtPosition(source, 1, &text, &len));
    try testing.expectEqual(1, len);
    try testing.expectEqual(0xDE00, text.?[0]);

    // The end of the text is a null text.
    try testing.expectEqual(api.S_OK, source.vtable.GetTextAtPosition(source, 2, &text, &len));
    try testing.expect(text == null);
    try testing.expectEqual(0, len);

    // The text before a position is as long as the position is far in,
    // and there is none before the start or from beyond the end. Each
    // call follows one that left another answer behind, so an answer
    // that is not written is not taken for the right one.
    try testing.expectEqual(api.S_OK, source.vtable.GetTextBeforePosition(source, 2, &text, &len));
    try testing.expectEqual(2, len);
    try testing.expectEqual(0xD83D, text.?[0]);
    try testing.expectEqual(api.S_OK, source.vtable.GetTextBeforePosition(source, 0, &text, &len));
    try testing.expect(text == null);
    try testing.expectEqual(0, len);
    try testing.expectEqual(api.S_OK, source.vtable.GetTextBeforePosition(source, 1, &text, &len));
    try testing.expectEqual(1, len);
    try testing.expectEqual(0xD83D, text.?[0]);
    try testing.expectEqual(api.S_OK, source.vtable.GetTextBeforePosition(source, 3, &text, &len));
    try testing.expect(text == null);
    try testing.expectEqual(0, len);

    try testing.expectEqual(
        api.DWRITE_READING_DIRECTION.LEFT_TO_RIGHT,
        source.vtable.GetParagraphReadingDirection(source),
    );

    // The locale and the number substitution hold from a position to the
    // end of the text, which is no length at all from beyond it.
    for ([_][2]api.UINT{ .{ 0, 2 }, .{ 1, 1 }, .{ 3, 0 } }) |case| {
        const position, const want = case;

        var name: ?[*:0]const u16 = null;
        len = 99;
        try testing.expectEqual(
            api.S_OK,
            source.vtable.GetLocaleName(source, position, &len, &name),
        );
        try testing.expectEqual(want, len);
        try testing.expectEqualSlices(u16, std.mem.span(locale), std.mem.span(name.?));

        var substitution: ?*api.IDWriteNumberSubstitution = @ptrFromInt(0x1000);
        len = 99;
        try testing.expectEqual(
            api.S_OK,
            source.vtable.GetNumberSubstitution(source, position, &len, &substitution),
        );
        try testing.expectEqual(want, len);
        try testing.expect(substitution == null);
    }

    // It answers to its own interface and to IUnknown, as the one object
    // that it is.
    {
        const same = try api.queryInterface(source, api.IDWriteTextAnalysisSource);
        defer api.release(same);
        try testing.expectEqual(@intFromPtr(source), @intFromPtr(same));
        const base = try api.queryInterface(source, api.IUnknown);
        defer api.release(base);
        try testing.expectEqual(@intFromPtr(source), @intFromPtr(base));
    }

    // It is the first version of the interface and says so: a caller
    // that asks for the second gets no for an answer, not this object.
    var out: ?*anyopaque = null;
    const unk = api.unknown(source);
    try testing.expectEqual(
        api.E_NOINTERFACE,
        unk.vtable.QueryInterface(unk, &api.IID_IDWriteTextAnalysisSource1, &out),
    );
    try testing.expect(out == null);

    // Inside the basic plane: one unit. The count of the sources is of
    // the process, and is read against what it was before this one.
    const before = live.load(.monotonic);
    {
        const bmp = try create(testing.allocator, 0x4E2D, locale);
        defer api.release(bmp);
        try testing.expectEqual(api.S_OK, bmp.vtable.GetTextAtPosition(bmp, 0, &text, &len));
        try testing.expectEqual(1, len);
        try testing.expectEqual(0x4E2D, text.?[0]);
        try testing.expectEqual(before + 1, live.load(.monotonic));
    }
    try testing.expectEqual(before, live.load(.monotonic));
}
