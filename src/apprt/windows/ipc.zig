//! The format of IPC to a running instance: one request, from a client
//! run as `ghostty +new-window`, `+new-tab` or `+toggle-quick-terminal`
//! (src/cli/new_window.zig, new_tab.zig and toggle_quick_terminal.zig),
//! and the instance's one reply.
//!
//! Both are little-endian, and both start with a magic and the format's
//! `version`, which every version keeps in that place: a client and an
//! instance of different versions then tell the other is another version,
//! rather than misread each other.
//!
//! A request: the magic `GIPC`, the version (u16), the action (u16,
//! `Action`), the request's whole length in bytes (u32), the surface id
//! (u64), the number of arguments (u32), then each argument's length in
//! bytes (u32) and its bytes. A reply: the magic `GIPR`, the version
//! (u16), the status (u16, `Status`), the text's length in bytes (u32),
//! then the text.

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");

/// The format's version, in a request and in its reply. A message of
/// another version is refused (`error.VersionMismatch`), which the magic
/// and the version alone tell.
pub const version: u16 = 1;

const request_magic = "GIPC";
const reply_magic = "GIPR";

/// A request's fixed part: the magic, version, action, length, surface id
/// and number of arguments.
pub const request_header_len = 24;

/// A reply's fixed part: the magic, version, status and text length.
pub const reply_header_len = 12;

/// The longest request, in bytes; a longer one is refused unread. The
/// arguments are the client's command line, at most 32,767 UTF-16 code
/// units (CreateProcessW's `lpCommandLine`), and the working directory
/// the CLI adds to them, or makes a full path of (`runArgs` and
/// `checkArg` in src/cli/new_window.zig and new_tab.zig), at most as
/// many again (the long-path limit). A unit takes at most 3 bytes of
/// UTF-8, and an argument 4 bytes for its length and at least one unit
/// of the command line beside its own (a space, or the quotes of an
/// empty one), so any request a client can be given is under 214,000
/// bytes.
pub const max_request = 256 * 1024;

/// The longest text a reply carries, in bytes; a longer one is cut at a
/// character (`encodeReply`).
pub const max_reply_text = 1024;

/// The longest reply, in bytes.
pub const max_reply = reply_header_len + max_reply_text;

/// The actions, by the format's own codes rather than the core's enum
/// (`apprt.ipc.Action.Key`): each side maps one to the other by an
/// exhaustive switch, so an action the core adds fails to compile here
/// until it has a code, rather than be sent as another. No action is
/// zero, so a request of zeros is refused.
pub const Action = enum(u16) {
    new_window = 1,
    new_tab = 2,
    toggle_quick_terminal = 3,

    pub fn fromCore(key: apprt.ipc.Action.Key) Action {
        return switch (key) {
            .new_window => .new_window,
            .new_tab => .new_tab,
            .toggle_quick_terminal => .toggle_quick_terminal,
        };
    }

    pub fn core(self: Action) apprt.ipc.Action.Key {
        return switch (self) {
            .new_window => .new_window,
            .new_tab => .new_tab,
            .toggle_quick_terminal => .toggle_quick_terminal,
        };
    }
};

/// What the instance did with a request, with the reply's text saying why
/// where it did not do it. No status is zero, so a reply of zeros is
/// refused.
pub const Status = enum(u16) {
    /// Done.
    ok = 1,

    /// Taken, not yet done: the instance does it later.
    pending = 2,

    /// The instance does not do this action.
    unsupported = 3,

    /// The request was not one of this format (`DecodeError`).
    bad_request = 4,

    /// An argument the instance cannot use.
    bad_arguments = 5,

    /// The instance is quitting, and does nothing more.
    quitting = 6,

    /// The instance tried, and failed.
    failed = 7,
};

/// A request as the instance reads it (`decodeRequest`), owning its
/// arguments.
pub const Request = struct {
    action: Action,

    /// The terminal beside which a new tab opens, by the core's id
    /// (`id` in src/Surface.zig): zero for the focused one, and zero for
    /// the other actions.
    surface_id: u64,

    /// The arguments, valid UTF-8 with no NUL; null for none, never
    /// empty. Each is a slice of `storage`.
    arguments: ?[]const [:0]const u8,

    /// The arguments' bytes, each followed by a NUL.
    storage: []u8,

    pub fn deinit(self: *const Request, alloc: Allocator) void {
        if (self.arguments) |arguments| alloc.free(arguments);
        alloc.free(self.storage);
    }
};

/// A reply as the client reads it (`decodeReply`). The text is a slice of
/// the bytes read, valid UTF-8; whatever prints it is to make its control
/// and bidi characters safe, since it can quote the client's own
/// arguments.
pub const Reply = struct {
    status: Status,
    text: []const u8,
};

pub const EncodeError = Allocator.Error || error{
    /// A list of arguments that is there but empty, which the core's
    /// actions call an error (`NewWindow.arguments` in
    /// src/apprt/ipc.zig); no list at all is sent as none.
    EmptyArguments,

    /// A surface id for an action other than new_tab.
    UnexpectedSurfaceId,

    /// An argument that is not valid UTF-8, or holds a NUL.
    InvalidArgument,

    /// Longer than `max_request`.
    TooLarge,
};

pub const DecodeError = Allocator.Error || error{
    /// Longer than `max_request` or, for a reply, its text longer than
    /// `max_reply_text`.
    TooLarge,

    /// Ends before the length it gives, or before a part it gives a
    /// length for.
    Truncated,

    /// Not this format's magic.
    BadMagic,

    /// Another version of the format.
    VersionMismatch,

    /// The request's length differs from the bytes read, or bytes follow
    /// its last argument or the reply's text.
    LengthMismatch,

    /// No action has this code.
    UnknownAction,

    /// A surface id with an action other than new_tab.
    UnexpectedSurfaceId,

    /// An argument that is not valid UTF-8, or holds a NUL.
    InvalidArgument,

    /// No status has this code.
    UnknownStatus,

    /// A reply's text that is not valid UTF-8.
    InvalidText,
};

/// The request for `action`, with `surface_id` (zero but for new_tab) and
/// `arguments` (null for none), as bytes the caller frees.
pub fn encodeRequest(
    alloc: Allocator,
    action: Action,
    surface_id: u64,
    arguments: ?[]const [:0]const u8,
) EncodeError![]u8 {
    if (surface_id != 0 and action != .new_tab) return error.UnexpectedSurfaceId;
    const args: []const [:0]const u8 = arguments orelse &.{};
    if (arguments != null and args.len == 0) return error.EmptyArguments;

    var len: usize = request_header_len;
    for (args) |arg| {
        if (!validArgument(arg)) return error.InvalidArgument;
        len += 4 + arg.len;
        if (len > max_request) return error.TooLarge;
    }

    const buf = try alloc.alloc(u8, len);
    var w: Writer = .{ .buf = buf };
    w.bytes(request_magic);
    w.int(u16, version);
    w.int(u16, @backingInt(action));
    w.int(u32, @intCast(len));
    w.int(u64, surface_id);
    w.int(u32, @intCast(args.len));
    for (args) |arg| {
        w.int(u32, @intCast(arg.len));
        w.bytes(arg);
    }
    std.debug.assert(w.pos == len);
    return buf;
}

/// The request in `bytes`, all of what the client sent, checked whole
/// before anything is allocated for it. The caller deinits it.
pub fn decodeRequest(alloc: Allocator, bytes: []const u8) DecodeError!Request {
    if (bytes.len > max_request) return error.TooLarge;
    var r: Reader = .{ .bytes = bytes };
    try r.magicAndVersion(request_magic);
    const code = try r.int(u16);
    const length = try r.int(u32);
    const surface_id = try r.int(u64);
    const count = try r.int(u32);

    if (length != bytes.len) return error.LengthMismatch;
    const action = std.enums.fromInt(Action, code) orelse return error.UnknownAction;
    if (surface_id != 0 and action != .new_tab) return error.UnexpectedSurfaceId;

    // Every argument is checked, and the space they take summed, before
    // anything is allocated: a count larger than the request can hold
    // fails as Truncated at its end, after at most one pass per 4 bytes,
    // rather than size an allocation.
    const start = r.pos;
    var storage_len: usize = 0;
    for (0..count) |_| {
        const arg = try r.take(try r.int(u32));
        if (!validArgument(arg)) return error.InvalidArgument;
        storage_len += arg.len + 1;
    }
    if (r.pos != bytes.len) return error.LengthMismatch;

    if (count == 0) return .{
        .action = action,
        .surface_id = surface_id,
        .arguments = null,
        .storage = &.{},
    };

    const storage = try alloc.alloc(u8, storage_len);
    errdefer alloc.free(storage);
    const arguments = try alloc.alloc([:0]const u8, count);

    r.pos = start;
    var at: usize = 0;
    for (arguments) |*argument| {
        const arg = r.take(r.int(u32) catch unreachable) catch unreachable;
        @memcpy(storage[at..][0..arg.len], arg);
        storage[at + arg.len] = 0;
        argument.* = storage[at .. at + arg.len :0];
        at += arg.len + 1;
    }

    return .{
        .action = action,
        .surface_id = surface_id,
        .arguments = arguments,
        .storage = storage,
    };
}

/// The reply of `status` with `text`, cut to `max_reply_text` bytes at a
/// character so that valid UTF-8 stays valid, written into `buf`: its
/// bytes.
pub fn encodeReply(buf: *[max_reply]u8, status: Status, text: []const u8) []const u8 {
    const cut = cutText(text, max_reply_text);
    var w: Writer = .{ .buf = buf };
    w.bytes(reply_magic);
    w.int(u16, version);
    w.int(u16, @backingInt(status));
    w.int(u32, @intCast(cut.len));
    w.bytes(cut);
    return buf[0..w.pos];
}

/// The length of the text that follows a reply's fixed part, from that
/// part: the client reads the pipe as bytes, the fixed part first and
/// then this many.
pub fn replyTextLength(header: *const [reply_header_len]u8) DecodeError!usize {
    return (try replyHeader(header)).len;
}

/// The reply in `bytes`, all of it: the fixed part, then the text.
pub fn decodeReply(bytes: []const u8) DecodeError!Reply {
    if (bytes.len < reply_header_len) {
        // A shorter reply can still tell another version.
        var r: Reader = .{ .bytes = bytes };
        try r.magicAndVersion(reply_magic);
        return error.Truncated;
    }
    const header = try replyHeader(bytes[0..reply_header_len]);
    const text = bytes[reply_header_len..];
    if (text.len < header.len) return error.Truncated;
    if (text.len > header.len) return error.LengthMismatch;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    return .{ .status = header.status, .text = text };
}

fn replyHeader(header: *const [reply_header_len]u8) DecodeError!struct {
    status: Status,
    len: usize,
} {
    var r: Reader = .{ .bytes = header };
    try r.magicAndVersion(reply_magic);
    const status = std.enums.fromInt(Status, try r.int(u16)) orelse
        return error.UnknownStatus;
    const len = try r.int(u32);
    if (len > max_reply_text) return error.TooLarge;
    return .{ .status = status, .len = len };
}

/// Whether `arg` can be sent: valid UTF-8, since the instance makes
/// configuration values of it, and with no NUL, which would end it early
/// as a `[:0]const u8`.
fn validArgument(arg: []const u8) bool {
    return std.mem.indexOfScalar(u8, arg, 0) == null and
        std.unicode.utf8ValidateSlice(arg);
}

/// `text`, cut to at most `max` bytes at the start of a character.
fn cutText(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    // Back from a continuation byte (10xxxxxx) to its character's start.
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) error{Truncated}![]const u8 {
        if (self.bytes.len - self.pos < n) return error.Truncated;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn int(self: *Reader, comptime T: type) error{Truncated}!T {
        const b = try self.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    /// The magic, then the version: first, so that a message of another
    /// version is told by them alone, however the rest of it is laid out.
    fn magicAndVersion(self: *Reader, magic: *const [4]u8) DecodeError!void {
        if (!std.mem.eql(u8, try self.take(4), magic)) return error.BadMagic;
        if (try self.int(u16) != version) return error.VersionMismatch;
    }
};

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn bytes(self: *Writer, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }

    fn int(self: *Writer, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.buf[self.pos..][0..@sizeOf(T)], value, .little);
        self.pos += @sizeOf(T);
    }
};

/// `request` read back, checked against what was encoded.
fn testRoundTrip(
    action: Action,
    surface_id: u64,
    arguments: ?[]const [:0]const u8,
) !void {
    const alloc = std.testing.allocator;
    const bytes = try encodeRequest(alloc, action, surface_id, arguments);
    defer alloc.free(bytes);
    const request = try decodeRequest(alloc, bytes);
    defer request.deinit(alloc);
    try std.testing.expectEqual(action, request.action);
    try std.testing.expectEqual(surface_id, request.surface_id);
    if (arguments) |want| {
        const got = request.arguments orelse return error.TestExpectedArguments;
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    } else try std.testing.expect(request.arguments == null);
}

/// A request's bytes written field by field, for requests `encodeRequest`
/// would not write. `length` null is the bytes' own length.
fn testRaw(
    buf: []u8,
    magic: *const [4]u8,
    ver: u16,
    code: u16,
    length: ?u32,
    surface_id: u64,
    count: u32,
    args: []const []const u8,
) []u8 {
    var w: Writer = .{ .buf = buf };
    w.bytes(magic);
    w.int(u16, ver);
    w.int(u16, code);
    w.int(u32, 0);
    w.int(u64, surface_id);
    w.int(u32, count);
    for (args) |arg| {
        w.int(u32, @intCast(arg.len));
        w.bytes(arg);
    }
    std.mem.writeInt(u32, buf[8..12], length orelse @intCast(w.pos), .little);
    return buf[0..w.pos];
}

test "win32: an IPC request reads back as it was written, for every action" {
    try testRoundTrip(.new_window, 0, null);
    try testRoundTrip(.new_window, 0, &.{
        "--working-directory=C:\\Users\\Ghost",
        "--title=\u{e9}t\u{e9} \u{1f47b}",
        "-e",
        "cmd",
        "/k",
        "", // an empty argument is still one
    });
    try testRoundTrip(.new_tab, 0, &.{"--working-directory=C:\\"});
    try testRoundTrip(.new_tab, 0xdead_beef_0000_0001, null);
    try testRoundTrip(.toggle_quick_terminal, 0, null);
}

test "win32: the longest IPC request is read, and one a byte longer is refused unread" {
    const alloc = std.testing.allocator;

    // One argument filling the request to `max_request`.
    const fill = try alloc.allocSentinel(u8, max_request - request_header_len - 4, 0);
    defer alloc.free(fill);
    @memset(fill, 'x');
    try testRoundTrip(.new_window, 0, &.{fill});

    // A byte more: the client does not write it.
    const over = try alloc.allocSentinel(u8, fill.len + 1, 0);
    defer alloc.free(over);
    @memset(over, 'x');
    try std.testing.expectError(error.TooLarge, encodeRequest(alloc, .new_window, 0, &.{over}));

    // And the instance does not read it, however well formed.
    const bytes = try alloc.alloc(u8, max_request + 1);
    defer alloc.free(bytes);
    const raw = testRaw(bytes, request_magic, version, 1, null, 0, 1, &.{over});
    try std.testing.expectEqual(max_request + 1, raw.len);
    try std.testing.expectError(error.TooLarge, decodeRequest(alloc, raw));
}

test "win32: the longest IPC request a client can be given is read" {
    // The request `max_request` reckons with, built from the limits it
    // names rather than from it: a command line of 32,767 UTF-16 units
    // (CreateProcessW) as one-unit arguments, each with the space after
    // it and each unit a character of 3 bytes in UTF-8, and then the
    // working directory the CLI adds, 32,767 such units long.
    const alloc = std.testing.allocator;
    const units = 32_767;
    const char = "\u{20ac}";
    const option = "--working-directory=";

    const arguments = try alloc.alloc([:0]const u8, units / 2 + 1);
    defer alloc.free(arguments);
    @memset(arguments[0 .. units / 2], char);
    const directory = try alloc.allocSentinel(u8, option.len + units * char.len, 0);
    defer alloc.free(directory);
    @memcpy(directory[0..option.len], option);
    var at: usize = option.len;
    while (at < directory.len) : (at += char.len) @memcpy(directory[at..][0..char.len], char);
    arguments[units / 2] = directory;

    const bytes = try encodeRequest(alloc, .new_window, 0, arguments);
    defer alloc.free(bytes);
    // 16,383 arguments of 4 + 3 bytes, the directory's 4 + 20 + 98,301,
    // and the fixed part.
    try std.testing.expectEqual(213_030, bytes.len);
    const request = try decodeRequest(alloc, bytes);
    defer request.deinit(alloc);
    const got = request.arguments orelse return error.TestExpectedArguments;
    try std.testing.expectEqual(arguments.len, got.len);
    try std.testing.expectEqualStrings(char, got[0]);
    try std.testing.expectEqualStrings(directory, got[got.len - 1]);
}

test "win32: a malformed IPC request is refused" {
    const alloc = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const Case = struct { DecodeError, []const u8 };
    const cases = [_]Case{
        .{ error.BadMagic, testRaw(buf[0..64], "GIPR", version, 1, null, 0, 0, &.{}) },
        .{ error.VersionMismatch, testRaw(buf[64..128], request_magic, 2, 1, null, 0, 0, &.{}) },
        .{ error.LengthMismatch, testRaw(buf[128..192], request_magic, version, 1, 23, 0, 0, &.{}) },
        .{ error.UnknownAction, testRaw(buf[192..256], request_magic, version, 0, null, 0, 0, &.{}) },
    };
    for (cases) |case| try std.testing.expectError(case[0], decodeRequest(alloc, case[1]));

    // One at a time from here, each in the whole buffer.
    try std.testing.expectError(error.UnknownAction, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, 4, null, 0, 0, &.{}),
    ));
    try std.testing.expectError(error.UnexpectedSurfaceId, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, @backingInt(Action.new_window), null, 7, 0, &.{}),
    ));
    try std.testing.expectError(error.UnexpectedSurfaceId, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, @backingInt(Action.toggle_quick_terminal), null, 7, 0, &.{}),
    ));
    try std.testing.expectError(error.InvalidArgument, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, 1, null, 0, 1, &.{"a\x00b"}),
    ));
    try std.testing.expectError(error.InvalidArgument, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, 1, null, 0, 1, &.{"\xff"}),
    ));
    // An unpaired surrogate as Windows' WTF-8 writes it is not UTF-8.
    try std.testing.expectError(error.InvalidArgument, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, 1, null, 0, 1, &.{"\xed\xa0\x80"}),
    ));
    // An argument whose length runs past the end.
    {
        const raw = testRaw(&buf, request_magic, version, 1, null, 0, 1, &.{"abc"});
        std.mem.writeInt(u32, raw[24..28], 4, .little);
        try std.testing.expectError(error.Truncated, decodeRequest(alloc, raw));
    }
    // Two arguments said, one there.
    try std.testing.expectError(error.Truncated, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, 1, null, 0, 2, &.{"abc"}),
    ));
    // One argument said, two there.
    try std.testing.expectError(error.LengthMismatch, decodeRequest(
        alloc,
        testRaw(&buf, request_magic, version, 1, null, 0, 1, &.{ "abc", "d" }),
    ));
    // The fixed part cut anywhere.
    const whole = testRaw(&buf, request_magic, version, 1, null, 0, 0, &.{});
    for (0..whole.len) |n| {
        const err = decodeRequest(alloc, whole[0..n]);
        try std.testing.expectError(error.Truncated, err);
    }
}

test "win32: an IPC request the instance could not read is not written" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.EmptyArguments, encodeRequest(alloc, .new_window, 0, &.{}));
    try std.testing.expectError(error.EmptyArguments, encodeRequest(alloc, .new_tab, 0, &.{}));
    try std.testing.expectError(error.UnexpectedSurfaceId, encodeRequest(alloc, .new_window, 1, null));
    try std.testing.expectError(error.UnexpectedSurfaceId, encodeRequest(alloc, .toggle_quick_terminal, 1, null));
    try std.testing.expectError(error.InvalidArgument, encodeRequest(alloc, .new_window, 0, &.{"a\x00b"}));
    try std.testing.expectError(error.InvalidArgument, encodeRequest(alloc, .new_window, 0, &.{ "ok", "\xed\xa0\x80" }));
}

test "win32: an IPC request saying more arguments than it holds is refused before anything is allocated" {
    var buf: [64]u8 = undefined;
    const raw = testRaw(&buf, request_magic, version, 1, null, 0, std.math.maxInt(u32), &.{"abc"});
    // An allocator that fails at once: the refusal is not OutOfMemory.
    try std.testing.expectError(error.Truncated, decodeRequest(std.testing.failing_allocator, raw));
}

fn testDecodeFreed(alloc: Allocator, bytes: []const u8) !void {
    const request = try decodeRequest(alloc, bytes);
    request.deinit(alloc);
}

test "win32: reading an IPC request frees what it took when memory runs out" {
    const alloc = std.testing.allocator;
    const bytes = try encodeRequest(alloc, .new_tab, 1, &.{ "--title=a", "-e", "cmd" });
    defer alloc.free(bytes);
    try std.testing.checkAllAllocationFailures(alloc, testDecodeFreed, .{bytes});
}

test "win32: an IPC reply reads back as it was written, its text cut at a character" {
    var buf: [max_reply]u8 = undefined;
    const why = "unknown shell integration 'x'";
    for (std.enums.values(Status)) |status| {
        const bytes = encodeReply(&buf, status, why);
        try std.testing.expectEqual(why.len, try replyTextLength(bytes[0..reply_header_len]));
        const reply = try decodeReply(bytes);
        try std.testing.expectEqual(status, reply.status);
        try std.testing.expectEqualStrings(why, reply.text);
    }

    // An empty text.
    try std.testing.expectEqualStrings("", (try decodeReply(encodeReply(&buf, .ok, ""))).text);

    // A text that fills the reply exactly is whole.
    const full: [max_reply_text]u8 = @splat('a');
    try std.testing.expectEqualStrings(&full, (try decodeReply(encodeReply(&buf, .failed, &full))).text);

    // Longer, it is cut before the character the limit falls in.
    var long: [max_reply_text + 3]u8 = @splat('a');
    @memcpy(long[max_reply_text - 1 ..], "\u{e9}\u{e9}");
    const cut = (try decodeReply(encodeReply(&buf, .failed, &long))).text;
    try std.testing.expectEqualStrings(full[0 .. max_reply_text - 1], cut);
}

test "win32: a malformed IPC reply is refused" {
    var buf: [max_reply]u8 = undefined;
    const good = encodeReply(&buf, .failed, "why");

    var bad: [max_reply + 1]u8 = undefined;
    const Case = struct { DecodeError, usize, []const u8 };
    const cases = [_]Case{
        .{ error.BadMagic, 0, "GIPC" },
        .{ error.VersionMismatch, 4, &.{ 2, 0 } },
        .{ error.UnknownStatus, 6, &.{ 0, 0 } },
        .{ error.UnknownStatus, 6, &.{ 8, 0 } },
        .{ error.Truncated, 8, &.{ 4, 0, 0, 0 } },
        .{ error.LengthMismatch, 8, &.{ 2, 0, 0, 0 } },
        .{ error.InvalidText, reply_header_len, "\xffhy" },
    };
    for (cases) |case| {
        @memcpy(bad[0..good.len], good);
        @memcpy(bad[case[1]..][0..case[2].len], case[2]);
        try std.testing.expectError(case[0], decodeReply(bad[0..good.len]));
    }

    // A text length past the limit is refused from the fixed part alone,
    // before the client reads the text.
    @memcpy(bad[0..reply_header_len], good[0..reply_header_len]);
    std.mem.writeInt(u32, bad[8..12], max_reply_text + 1, .little);
    try std.testing.expectError(error.TooLarge, replyTextLength(bad[0..reply_header_len]));

    // The fixed part cut anywhere; another version still tells.
    for (0..reply_header_len) |n| {
        try std.testing.expectError(error.Truncated, decodeReply(good[0..n]));
    }
    @memcpy(bad[0..6], good[0..6]);
    bad[4] = 2;
    try std.testing.expectError(error.VersionMismatch, decodeReply(bad[0..6]));
}

test "win32: a request of another IPC version is told by its magic and version alone" {
    // However short the rest, and whatever it holds.
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], request_magic);
    std.mem.writeInt(u16, buf[4..6], version + 1, .little);
    try std.testing.expectError(error.VersionMismatch, decodeRequest(std.testing.allocator, buf[0..6]));
}

test "win32: every IPC action of the core has a code of its own in the format" {
    var seen: std.EnumSet(Action) = .empty;
    for (std.enums.values(apprt.ipc.Action.Key)) |key| {
        const action = Action.fromCore(key);
        try std.testing.expect(!seen.contains(action));
        seen.insert(action);
        try std.testing.expectEqual(key, action.core());
    }
    try std.testing.expectEqual(std.enums.values(Action).len, seen.count());
}
