//! The loader that lets DirectWrite read a font from bytes in memory,
//! which is how the fonts embedded in the binary become faces.
//!
//! DirectWrite knows a font file by a loader and a reference key, bytes
//! that mean something to that loader alone. It copies the key, and hands
//! it back to the loader for a stream whenever it wants to read the file.
//! The key here is the slice of the font itself and the stream hands out
//! pointers into it: nothing is copied and nothing is owned.
//!
//! The whole file rests on one invariant, which the callers keep: the
//! bytes behind a key outlive every stream made from it. They are static
//! data from @embedFile, or bytes that a face owns for as long as its
//! DirectWrite face lives. DirectWrite decides how long a stream lives,
//! so a stream is counted and frees itself with its last reference.
const FontFileLoader = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");
const object = @import("object.zig");

const Object = object.Object(api.IDWriteFontFileLoader, FontFileLoader);

pub const iids: []const *const api.GUID = &.{&api.IID_IDWriteFontFileLoader};

/// The reference key of a font in memory: the slice itself. The bytes
/// are not copied and have to outlive every stream that DirectWrite
/// makes from the key, which is for as long as a font file or a face
/// made from it lives.
pub const Key = extern struct {
    ptr: [*]const u8,
    len: usize,
};

const vtable: api.IDWriteFontFileLoader.VTable = .{
    .base = Object.unknown,
    .CreateStreamFromKey = createStreamFromKey,
};

/// A loader with one reference that is the caller's. Its streams are
/// allocated with the same allocator, from whichever thread DirectWrite
/// asks for them on, and may outlive the loader.
pub fn create(alloc: Allocator) Allocator.Error!*api.IDWriteFontFileLoader {
    const obj = try Object.create(alloc, &vtable, .{});
    return &obj.interface;
}

/// The key for a font in memory, to pass to CreateCustomFontFileReference
/// with @sizeOf(Key) as its size. The bytes have to outlive the font file
/// and everything made from it.
pub fn key(bytes: []const u8) Key {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

/// A stream over the bytes of a key, with one reference that is the
/// caller's.
fn createStreamFromKey(
    this: *api.IDWriteFontFileLoader,
    key_ptr: *const anyopaque,
    key_size: api.UINT,
    stream: *?*api.IDWriteFontFileStream,
) callconv(api.cc) api.HRESULT {
    stream.* = null;
    if (key_size != @sizeOf(Key)) return api.E_INVALIDARG;

    // The key is DirectWrite's copy of ours and is read as bytes, since
    // nothing says how the copy is aligned.
    var k: Key = undefined;
    const src: [*]const u8 = @ptrCast(key_ptr);
    @memcpy(std.mem.asBytes(&k), src[0..@sizeOf(Key)]);

    const obj = Stream.Object.create(
        Object.from(this).alloc,
        &Stream.vtable,
        .{ .bytes = k.ptr[0..k.len] },
    ) catch return api.E_OUTOFMEMORY;
    _ = Stream.live.fetchAdd(1, .monotonic);
    stream.* = &obj.interface;
    return api.S_OK;
}

/// The bytes of one font as DirectWrite reads them, a fragment at a time.
pub const Stream = struct {
    const Object = object.Object(api.IDWriteFontFileStream, Stream);

    /// Not owned, and alive for longer than the stream.
    bytes: []const u8,

    pub const iids: []const *const api.GUID = &.{&api.IID_IDWriteFontFileStream};

    /// How many streams exist. DirectWrite makes them and decides how
    /// long they live; the tests read here that they all go.
    pub var live: std.atomic.Value(usize) = .init(0);

    pub fn deinit(self: *Stream) void {
        _ = self;
        _ = live.fetchSub(1, .monotonic);
    }

    const vtable: api.IDWriteFontFileStream.VTable = .{
        .base = Stream.Object.unknown,
        .ReadFileFragment = readFileFragment,
        .ReleaseFileFragment = releaseFileFragment,
        .GetFileSize = getFileSize,
        .GetLastWriteTime = getLastWriteTime,
    };

    /// A pointer into the bytes, which there is nothing to release for:
    /// the context is null. A fragment that is not all inside the bytes
    /// is refused.
    fn readFileFragment(
        this: *api.IDWriteFontFileStream,
        fragment_start: *?*const anyopaque,
        offset: api.UINT64,
        fragment_size: api.UINT64,
        fragment_context: *?*anyopaque,
    ) callconv(api.cc) api.HRESULT {
        const self = &Stream.Object.from(this).impl;
        fragment_start.* = null;
        fragment_context.* = null;

        // The subtraction cannot wrap once the offset is known to be
        // inside, where the sum of the two could.
        const len: u64 = self.bytes.len;
        if (offset > len or fragment_size > len - offset) return api.E_FAIL;

        fragment_start.* = self.bytes.ptr + @as(usize, @intCast(offset));
        return api.S_OK;
    }

    fn releaseFileFragment(
        this: *api.IDWriteFontFileStream,
        fragment_context: ?*anyopaque,
    ) callconv(api.cc) void {
        _ = this;
        _ = fragment_context;
    }

    fn getFileSize(
        this: *api.IDWriteFontFileStream,
        size: *api.UINT64,
    ) callconv(api.cc) api.HRESULT {
        const self = &Stream.Object.from(this).impl;
        size.* = self.bytes.len;
        return api.S_OK;
    }

    /// Bytes in memory were never written to a file and have no time to
    /// report. The time is zeroed all the same for a caller that reads
    /// it without looking at the result.
    fn getLastWriteTime(
        this: *api.IDWriteFontFileStream,
        last_write_time: *api.UINT64,
    ) callconv(api.cc) api.HRESULT {
        _ = this;
        last_write_time.* = 0;
        return api.E_NOTIMPL;
    }
};

test "directwrite font file loader: stream over bytes" {
    const testing = std.testing;
    const bytes = "0123456789";

    const loader = try create(testing.allocator);
    defer api.release(loader);

    // The stream is made as DirectWrite makes it, through the vtable and
    // from the key and its size.
    const before = Stream.live.load(.monotonic);
    const k = key(bytes);
    var made: ?*api.IDWriteFontFileStream = null;
    try testing.expectEqual(
        api.S_OK,
        loader.vtable.CreateStreamFromKey(loader, &k, @sizeOf(Key), &made),
    );
    const stream = made.?;
    try testing.expectEqual(before + 1, Stream.live.load(.monotonic));

    var size: api.UINT64 = 0;
    try testing.expectEqual(api.S_OK, stream.vtable.GetFileSize(stream, &size));
    try testing.expectEqual(bytes.len, size);

    // A fragment inside the bytes is a pointer into them, with nothing
    // to release. Each call follows one that left another answer behind.
    var start: ?*const anyopaque = null;
    var context: ?*anyopaque = @ptrFromInt(0x1000);
    try testing.expectEqual(
        api.S_OK,
        stream.vtable.ReadFileFragment(stream, &start, 3, 4, &context),
    );
    try testing.expectEqual(@intFromPtr(bytes.ptr) + 3, @intFromPtr(start.?));
    try testing.expectEqualStrings("3456", @as([*]const u8, @ptrCast(start.?))[0..4]);
    try testing.expect(context == null);
    stream.vtable.ReleaseFileFragment(stream, context);

    // All of it, and nothing at its end.
    try testing.expectEqual(
        api.S_OK,
        stream.vtable.ReadFileFragment(stream, &start, 0, bytes.len, &context),
    );
    try testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(start.?));
    try testing.expectEqual(
        api.S_OK,
        stream.vtable.ReadFileFragment(stream, &start, bytes.len, 0, &context),
    );
    try testing.expectEqual(@intFromPtr(bytes.ptr) + bytes.len, @intFromPtr(start.?));

    // One byte past the end is refused wherever the fragment starts, and
    // so are the offsets and sizes whose sum wraps around to the inside.
    const max = std.math.maxInt(u64);
    for ([_][2]u64{
        .{ 0, bytes.len + 1 },
        .{ 7, 4 },
        .{ bytes.len, 1 },
        .{ bytes.len + 1, 0 },
        .{ max, 1 },
        .{ max - 1, 4 },
        .{ 1, max },
        .{ max, max },
    }) |case| {
        const offset, const len = case;
        start = @ptrFromInt(0x1000);
        context = @ptrFromInt(0x1000);
        try testing.expectEqual(
            api.E_FAIL,
            stream.vtable.ReadFileFragment(stream, &start, offset, len, &context),
        );
        try testing.expect(start == null);
        try testing.expect(context == null);
    }

    // No time of writing.
    var time: api.UINT64 = 99;
    try testing.expectEqual(api.E_NOTIMPL, stream.vtable.GetLastWriteTime(stream, &time));
    try testing.expectEqual(0, time);

    // It answers to its own interface and to IUnknown, as the one object
    // that it is, and not to the loader's.
    {
        const same = try api.queryInterface(stream, api.IDWriteFontFileStream);
        defer api.release(same);
        try testing.expectEqual(@intFromPtr(stream), @intFromPtr(same));
        const base = try api.queryInterface(stream, api.IUnknown);
        defer api.release(base);
        try testing.expectEqual(@intFromPtr(stream), @intFromPtr(base));
    }
    const unk = api.unknown(stream);
    var out: ?*anyopaque = @ptrFromInt(0x1000);
    try testing.expectEqual(
        api.E_NOINTERFACE,
        unk.vtable.QueryInterface(unk, &api.IID_IDWriteFontFileLoader, &out),
    );
    try testing.expect(out == null);

    // The one reference left is the one the loader gave, and the stream
    // goes with it.
    try testing.expectEqual(2, unk.vtable.AddRef(unk));
    try testing.expectEqual(1, unk.vtable.Release(unk));
    try testing.expectEqual(before + 1, Stream.live.load(.monotonic));
    try testing.expectEqual(0, unk.vtable.Release(unk));
    try testing.expectEqual(before, Stream.live.load(.monotonic));
}

test "directwrite font file loader: keys" {
    const testing = std.testing;
    const bytes = "0123456789";

    const loader = try create(testing.allocator);
    defer api.release(loader);
    const before = Stream.live.load(.monotonic);

    // A key of another size is not one of ours.
    const k = key(bytes);
    for ([_]api.UINT{ 0, @sizeOf(Key) - 1, @sizeOf(Key) + 1 }) |size| {
        var made: ?*api.IDWriteFontFileStream = @ptrFromInt(0x1000);
        try testing.expectEqual(
            api.E_INVALIDARG,
            loader.vtable.CreateStreamFromKey(loader, &k, size, &made),
        );
        try testing.expect(made == null);
    }
    try testing.expectEqual(before, Stream.live.load(.monotonic));

    // The key is read wherever DirectWrite keeps its copy, aligned or
    // not.
    {
        var copy: [@sizeOf(Key) + 1]u8 = undefined;
        @memcpy(copy[1..], std.mem.asBytes(&k));
        var made: ?*api.IDWriteFontFileStream = null;
        try testing.expectEqual(
            api.S_OK,
            loader.vtable.CreateStreamFromKey(loader, &copy[1], @sizeOf(Key), &made),
        );
        const stream = made.?;
        defer api.release(stream);

        var start: ?*const anyopaque = null;
        var context: ?*anyopaque = null;
        try testing.expectEqual(
            api.S_OK,
            stream.vtable.ReadFileFragment(stream, &start, 8, 2, &context),
        );
        try testing.expectEqualStrings("89", @as([*]const u8, @ptrCast(start.?))[0..2]);
    }

    // A font of no bytes has a stream of no size.
    {
        const empty = key("");
        var made: ?*api.IDWriteFontFileStream = null;
        try testing.expectEqual(
            api.S_OK,
            loader.vtable.CreateStreamFromKey(loader, &empty, @sizeOf(Key), &made),
        );
        const stream = made.?;
        defer api.release(stream);

        var size: api.UINT64 = 99;
        try testing.expectEqual(api.S_OK, stream.vtable.GetFileSize(stream, &size));
        try testing.expectEqual(0, size);
        var start: ?*const anyopaque = null;
        var context: ?*anyopaque = null;
        try testing.expectEqual(
            api.E_FAIL,
            stream.vtable.ReadFileFragment(stream, &start, 0, 1, &context),
        );
    }
    try testing.expectEqual(before, Stream.live.load(.monotonic));
}

test "directwrite font file loader: references and interfaces" {
    const testing = std.testing;

    const loader = try create(testing.allocator);
    const unk = api.unknown(loader);

    {
        const same = try api.queryInterface(loader, api.IDWriteFontFileLoader);
        defer api.release(same);
        try testing.expectEqual(@intFromPtr(loader), @intFromPtr(same));
        const base = try api.queryInterface(loader, api.IUnknown);
        defer api.release(base);
        try testing.expectEqual(@intFromPtr(loader), @intFromPtr(base));
    }

    // It is not the loader of local files, which a font of the system
    // has and which the path of a font is asked of.
    var out: ?*anyopaque = @ptrFromInt(0x1000);
    try testing.expectEqual(
        api.E_NOINTERFACE,
        unk.vtable.QueryInterface(unk, &api.IID_IDWriteLocalFontFileLoader, &out),
    );
    try testing.expect(out == null);

    // A stream holds nothing of the loader and lives on after it.
    const bytes = "0123456789";
    const before = Stream.live.load(.monotonic);
    const k = key(bytes);
    var made: ?*api.IDWriteFontFileStream = null;
    try testing.expectEqual(
        api.S_OK,
        loader.vtable.CreateStreamFromKey(loader, &k, @sizeOf(Key), &made),
    );
    const stream = made.?;

    try testing.expectEqual(2, unk.vtable.AddRef(unk));
    try testing.expectEqual(1, unk.vtable.Release(unk));
    try testing.expectEqual(0, unk.vtable.Release(unk));

    var size: api.UINT64 = 0;
    try testing.expectEqual(api.S_OK, stream.vtable.GetFileSize(stream, &size));
    try testing.expectEqual(bytes.len, size);
    api.release(stream);
    try testing.expectEqual(before, Stream.live.load(.monotonic));
}
