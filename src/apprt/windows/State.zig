//! The open windows as `window-save-state` keeps them between runs: each
//! window's place, its tabs in order, each tab's splits, and for every
//! terminal the directory its shell last reported and the title the user
//! gave it. This file is the format only, with no window in it: what is
//! written (`encode`), and what is taken back (`decode`).
//!
//! A saved state is a file anything running as the user can write, so
//! reading one is reading untrusted input, and it is made unable to do
//! more than open shells:
//!
//! - There is no command in it. A restored terminal runs what the config
//!   says, in a directory the file names.
//! - Each directory must be one a shell could have reported
//!   (src/termio/windows_pwd.zig), and in the form that gives. A share on
//!   another server is refused as it is there: opening one connects to
//!   that server as the user.
//! - A tab's splits are a flat list of nodes, as the split tree's own
//!   (src/datastruct/split_tree.zig), in preorder: a split's left child
//!   is the node after it. No type here holds itself, so no file decides
//!   how deep the parser's stack goes, and one loop tells a tree from
//!   anything else (`checkTree`).
//! - Everything is counted and bounded (`max_windows` and the rest).
//!
//! Anything wrong refuses the whole state: a state half taken would
//! bring back windows nobody had. A field this version does not know is
//! passed over, so that a later one can add fields without a new version.
//!
//! `encode` refuses what `decode` would, so nothing is written that
//! could not be read back, and `decode(encode(s))` is `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows_pwd = @import("../../termio/windows_pwd.zig");

/// The format's version. Another one's file is not read.
pub const format_version = 1;

/// The most windows in one state, tabs in one window, and nodes in one
/// tab; 127 nodes are 64 terminals.
pub const max_windows = 16;
pub const max_tabs = 64;
pub const max_nodes = 127;

/// The longest title and directory, in bytes.
pub const max_title = 1024;
pub const max_pwd = 4096;

/// The largest coordinate of a window's rectangle either way, which is
/// what a virtual screen's can be.
pub const max_coordinate = 32767;

/// The scales a window can have been saved at: 50% to 1000% of 96.
pub const min_dpi = 48;
pub const max_dpi = 960;

version: u32,
windows: []const Window,

const State = @This();

pub const Window = struct {
    /// Where the window is when neither maximized nor fullscreen: left,
    /// top, right and bottom in screen coordinates, at `dpi`.
    rect: [4]i32,
    dpi: u32,
    maximized: bool,
    fullscreen: bool,

    /// The title the user gave the window, or null.
    title: ?[]const u8 = null,

    /// The index in `tabs` of the tab that shows.
    selected: u32,
    tabs: []const Tab,
};

pub const Tab = struct {
    /// The title the user gave the tab, or null.
    title: ?[]const u8 = null,

    /// The index in `nodes` of the terminal with the focus.
    focused: u32,

    /// The tab's split tree in preorder; the first node is its root.
    nodes: []const Node,
};

pub const Node = union(enum) {
    split: Split,
    leaf: Leaf,
};

pub const Split = struct {
    layout: Layout,

    /// The left or top child's share, 0 to 1 with both ends, as a split
    /// can be dragged to either.
    ratio: f16,

    /// Indexes in the tab's `nodes`. `left` is the node after this one.
    left: u32,
    right: u32,

    pub const Layout = enum { horizontal, vertical };
};

pub const Leaf = struct {
    /// The directory the terminal's shell last reported, or null.
    pwd: ?[]const u8 = null,

    /// The title the user gave the terminal, or null.
    title: ?[]const u8 = null,
};

/// Whether a share's server is this machine (`windows_pwd.IsLocal`).
pub const IsLocal = windows_pwd.IsLocal;

/// `v` as a state's title: itself, or none when a state would not take
/// it (`checkTitle`), as a program's title that is not text.
pub fn titleOrNone(v: ?[]const u8) ?[]const u8 {
    checkTitle(v) catch return null;
    return v;
}

/// `v` as a state's directory: itself, or none when a state would not
/// take it (`checkPwd`). `alloc` is used and given back within the call.
pub fn pwdOrNone(alloc: Allocator, v: ?[]const u8, isLocal: IsLocal) Allocator.Error!?[]const u8 {
    checkPwd(alloc, v, isLocal) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return v;
}

/// Why a state is refused. `Syntax` is text that is not this format at
/// all; the others each name the rule a well-formed state broke.
pub const Invalid = error{
    Syntax,
    Version,
    Windows,
    Rect,
    Dpi,
    Tabs,
    Selected,
    Tree,
    Focused,
    Ratio,
    Title,
    Pwd,
};

/// `state` as text, allocated with `alloc`; refused if `decode` would
/// refuse it.
pub fn encode(
    alloc: Allocator,
    state: State,
    isLocal: windows_pwd.IsLocal,
) (Allocator.Error || Invalid)![]u8 {
    try check(alloc, state, isLocal);
    return std.json.Stringify.valueAlloc(alloc, state, .{});
}

/// The state `text` holds. Everything of it is allocated with `arena`,
/// and nothing points into `text`.
pub fn decode(
    arena: Allocator,
    text: []const u8,
    isLocal: windows_pwd.IsLocal,
) (Allocator.Error || Invalid)!State {
    const state = std.json.parseFromSliceLeaky(State, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Syntax,
    };
    try check(arena, state, isLocal);
    return state;
}

/// Whether `state` is one this version takes. `alloc` is used and given
/// back within the call.
pub fn check(
    alloc: Allocator,
    state: State,
    isLocal: windows_pwd.IsLocal,
) (Allocator.Error || Invalid)!void {
    if (state.version != format_version) return error.Version;
    if (state.windows.len == 0 or state.windows.len > max_windows) return error.Windows;
    for (state.windows) |window| {
        const l, const t, const r, const b = window.rect;
        for (window.rect) |v| if (v < -max_coordinate or v > max_coordinate) return error.Rect;
        if (r <= l or b <= t) return error.Rect;
        if (window.dpi < min_dpi or window.dpi > max_dpi) return error.Dpi;
        try checkTitle(window.title);
        if (window.tabs.len == 0 or window.tabs.len > max_tabs) return error.Tabs;
        if (window.selected >= window.tabs.len) return error.Selected;
        for (window.tabs) |tab| {
            try checkTitle(tab.title);
            try checkTree(tab.nodes);
            if (tab.focused >= tab.nodes.len or tab.nodes[tab.focused] != .leaf)
                return error.Focused;
            for (tab.nodes) |node| switch (node) {
                .split => |s| if (!(s.ratio >= 0 and s.ratio <= 1)) return error.Ratio,
                .leaf => |leaf| {
                    try checkTitle(leaf.title);
                    try checkPwd(alloc, leaf.pwd, isLocal);
                },
            };
        }
    }
}

/// Whether `nodes` is one tree in preorder: walked from the root, left
/// child first, the nodes come up in the order they are listed, each
/// once. That one test refuses a child out of range, a child before its
/// parent (so any cycle), a node two splits share, and a node no split
/// names, since each of them puts some index out of turn or leaves the
/// walk short.
fn checkTree(nodes: []const Node) Invalid!void {
    if (nodes.len == 0 or nodes.len > max_nodes) return error.Tree;

    // The walk's pending right children, one put on per split walked.
    // The nodes walked are the first `seen` of the list, and the last
    // of the list cannot be a split that passes (its left child would
    // be out of range), so fewer splits are walked than there are nodes.
    var pending: [max_nodes]u32 = undefined;
    var depth: usize = 0;
    var at: u32 = 0;
    var seen: u32 = 0;
    while (true) {
        if (at != seen) return error.Tree;
        seen += 1;
        switch (nodes[at]) {
            .split => |s| {
                // In range, which the comparison at the top of the loop
                // then holds each to: `left` now, `right` when taken.
                if (s.left >= nodes.len or s.right >= nodes.len) return error.Tree;
                std.debug.assert(depth < pending.len);
                pending[depth] = s.right;
                depth += 1;
                at = s.left;
            },
            .leaf => {
                if (depth == 0) break;
                depth -= 1;
                at = pending[depth];
            },
        }
    }
    if (seen != nodes.len) return error.Tree;
}

/// A title is text a caption can show: valid UTF-8 with no NUL, which
/// would end it early, and not empty, which is no title (null).
fn checkTitle(title: ?[]const u8) Invalid!void {
    const v = title orelse return;
    if (v.len == 0 or v.len > max_title) return error.Title;
    if (std.mem.indexOfScalar(u8, v, 0) != null) return error.Title;
    if (!std.unicode.utf8ValidateSlice(v)) return error.Title;
}

/// A directory is one a shell's report gives, in the very form it gives:
/// anything else was not saved by this program.
fn checkPwd(
    alloc: Allocator,
    pwd: ?[]const u8,
    isLocal: windows_pwd.IsLocal,
) (Allocator.Error || Invalid)!void {
    const v = pwd orelse return;
    if (v.len > max_pwd) return error.Pwd;
    switch (try windows_pwd.parse(alloc, v, isLocal)) {
        .refused => return error.Pwd,
        .path => |path| {
            defer alloc.free(path);
            if (!std.mem.eql(u8, path, v)) return error.Pwd;
        },
    }
}

const testing = std.testing;

/// This machine in the tests: `ME` and nothing else.
fn testIsLocal(host: []const u8) bool {
    return std.mem.eql(u8, host, "ME");
}

/// For tests: a random state within every bound, of at most `most`
/// windows, tabs in each and terminals in each tab, allocated with
/// `arena`. With `even`, each split's ratio gives every terminal under
/// it the same share, so that all of them fit a window of some size;
/// otherwise it is any ratio, either end included.
pub fn testRandom(
    arena: Allocator,
    random: std.Random,
    most: struct { windows: usize = 4, tabs: usize = 5, leaves: usize = 12, even: bool = false },
) !State {
    const titles = [_]?[]const u8{ null, null, "build", "a \"quoted\" one", "\\back\\slash", "naïve ✓ 日本", "tab\there" };
    const pwds = [_]?[]const u8{ null, "C:\\", "C:\\src\\ghostty", "D:\\with space\\ünï", "\\\\ME\\share\\dir", "\\\\wsl.localhost\\Ubuntu\\home\\me" };
    const pick = struct {
        fn of(r: std.Random, from: []const ?[]const u8) ?[]const u8 {
            return from[r.uintLessThan(usize, from.len)];
        }
    }.of;

    const windows = try arena.alloc(Window, random.intRangeAtMost(usize, 1, most.windows));
    for (windows) |*window| {
        const tabs = try arena.alloc(Tab, random.intRangeAtMost(usize, 1, most.tabs));
        for (tabs) |*tab| {
            // Grown as a walk in preorder: each node is a split while
            // leaves remain to hand out below it.
            const leaves = random.intRangeAtMost(usize, 1, most.leaves);
            const nodes = try arena.alloc(Node, 2 * leaves - 1);
            var next: u32 = 0;
            // (node to fill, leaves it holds)
            var stack: std.ArrayList(struct { u32, usize }) = .empty;
            try stack.append(arena, .{ 0, leaves });
            next = 1;
            var focus: std.ArrayList(u32) = .empty;
            // Preorder needs each subtree's nodes together, so a split's
            // right child is numbered only after its whole left side;
            // sizes are known up front, which gives its index at once.
            while (stack.pop()) |item| {
                const index, const count = item;
                if (count == 1) {
                    nodes[index] = .{ .leaf = .{ .pwd = pick(random, &pwds), .title = pick(random, &titles) } };
                    try focus.append(arena, index);
                    continue;
                }
                const left_count = random.intRangeAtMost(usize, 1, count - 1);
                const left = index + 1;
                const right: u32 = @intCast(left + 2 * left_count - 1);
                nodes[index] = .{ .split = .{
                    .layout = random.enumValue(Split.Layout),
                    .ratio = if (most.even)
                        @floatCast(@as(f64, @floatFromInt(left_count)) / @as(f64, @floatFromInt(count)))
                    else switch (random.uintLessThan(u8, 8)) {
                        0 => 0,
                        1 => 1,
                        else => @floatCast(random.float(f32)),
                    },
                    .left = left,
                    .right = right,
                } };
                try stack.append(arena, .{ right, count - left_count });
                try stack.append(arena, .{ left, left_count });
            }
            tab.* = .{
                .title = pick(random, &titles),
                .focused = focus.items[random.uintLessThan(usize, focus.items.len)],
                .nodes = nodes,
            };
        }
        const l = random.intRangeAtMost(i32, -4000, 4000);
        const t = random.intRangeAtMost(i32, -4000, 4000);
        window.* = .{
            .rect = .{ l, t, l + random.intRangeAtMost(i32, 1, 5000), t + random.intRangeAtMost(i32, 1, 5000) },
            .dpi = random.intRangeAtMost(u32, min_dpi, max_dpi),
            .maximized = random.boolean(),
            .fullscreen = random.boolean(),
            .title = pick(random, &titles),
            .selected = @intCast(random.uintLessThan(usize, tabs.len)),
            .tabs = tabs,
        };
    }
    return .{ .version = format_version, .windows = windows };
}

test "win32: a window state read back is the one written" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prng: std.Random.DefaultPrng = .init(0x57a7_e001);
    const random = prng.random();
    for (0..300) |_| {
        const state = try testRandom(arena, random, .{});
        const text = try encode(testing.allocator, state, &testIsLocal);
        defer testing.allocator.free(text);
        const back = try decode(arena, text, &testIsLocal);
        // Nothing read back points into the text it came from.
        @memset(text, ' ');
        try testing.expectEqualDeep(state, back);
    }
}

/// One window with one tab of two terminals side by side: the smallest
/// state with every kind of thing in it.
const golden =
    \\{"version":1,"windows":[{"rect":[100,50,1300,850],"dpi":144,"maximized":false,"fullscreen":false,"title":null,"selected":0,"tabs":[{"title":"work","focused":2,"nodes":[{"split":{"layout":"horizontal","ratio":0.5,"left":1,"right":2}},{"leaf":{"pwd":"C:\\src","title":null}},{"leaf":{"pwd":null,"title":"build"}}]}]}]}
;

fn testGolden() State {
    return .{ .version = format_version, .windows = &.{.{
        .rect = .{ 100, 50, 1300, 850 },
        .dpi = 144,
        .maximized = false,
        .fullscreen = false,
        .selected = 0,
        .tabs = &.{.{
            .title = "work",
            .focused = 2,
            .nodes = &.{
                .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = 1, .right = 2 } },
                .{ .leaf = .{ .pwd = "C:\\src" } },
                .{ .leaf = .{ .title = "build" } },
            },
        }},
    }} };
}

test "win32: version 1 of the window state is this text" {
    // The text is what files on disk hold: a change here is a change of
    // format, which wants a new version, not a new expectation.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try encode(arena, testGolden(), &testIsLocal);
    try testing.expectEqualStrings(golden, text);
    try testing.expectEqualDeep(testGolden(), try decode(arena, golden, &testIsLocal));

    // A field a later version adds is passed over, wherever it is.
    const later =
        \\{"version":1,"added":{"deep":[1,{"x":null}]},"windows":[{"rect":[0,0,10,10],"dpi":96,"maximized":true,"fullscreen":false,"selected":0,"color":"red","tabs":[{"focused":0,"nodes":[{"leaf":{"font":12}}]}]}]}
    ;
    const state = try decode(arena, later, &testIsLocal);
    try testing.expect(state.windows[0].maximized);
    try testing.expect(state.windows[0].tabs[0].nodes[0].leaf.pwd == null);
}

test "win32: a window state cut short anywhere is refused, not half taken" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..golden.len) |len| {
        try testing.expectError(error.Syntax, decode(arena, golden[0..len], &testIsLocal));
    }
    // And with something after it.
    try testing.expectError(error.Syntax, decode(arena, golden ++ "{}", &testIsLocal));
}

/// A directory of `parts` names of 200 bytes each, as JSON text holds it.
fn testLongPwd(comptime parts: usize) []const u8 {
    var path: []const u8 = "C:";
    for (0..parts) |_| path = path ++ "\\\\" ++ &@as([200]u8, @splat('a'));
    return path;
}

/// `golden` with its first `old` replaced by `new`, decoded.
fn testEdited(arena: Allocator, old: []const u8, new: []const u8) !State {
    const at = std.mem.indexOf(u8, golden, old) orelse return error.TestUnexpectedResult;
    const text = try std.mem.concat(arena, u8, &.{ golden[0..at], new, golden[at + old.len ..] });
    return decode(arena, text, &testIsLocal);
}

test "win32: a window state that breaks a rule is refused whole" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const leaf = "{\"leaf\":{\"pwd\":\"C:\\\\src\",\"title\":null}}";
    const split = "{\"split\":{\"layout\":\"horizontal\",\"ratio\":0.5,\"left\":1,\"right\":2}}";
    const cases = [_]struct { Invalid, []const u8, []const u8 }{
        .{ error.Version, "\"version\":1", "\"version\":2" },
        .{ error.Version, "\"version\":1", "\"version\":0" },
        .{ error.Syntax, "\"version\":1", "\"version\":-1" },
        .{ error.Syntax, "\"version\":1,", "" },
        .{ error.Syntax, "\"version\":1", "\"version\":1,\"version\":1" },

        // The rectangle: empty, inside out, or off any screen.
        .{ error.Rect, "[100,50,1300,850]", "[100,50,100,850]" },
        .{ error.Rect, "[100,50,1300,850]", "[100,50,1300,50]" },
        .{ error.Rect, "[100,50,1300,850]", "[1300,50,100,850]" },
        .{ error.Rect, "[100,50,1300,850]", "[100,50,32768,850]" },
        .{ error.Rect, "[100,50,1300,850]", "[-32768,50,1300,850]" },
        .{ error.Syntax, "[100,50,1300,850]", "[100,50,1300]" },
        .{ error.Syntax, "[100,50,1300,850]", "[100,50,1300,4294967296]" },
        .{ error.Dpi, "\"dpi\":144", "\"dpi\":47" },
        .{ error.Dpi, "\"dpi\":144", "\"dpi\":961" },

        .{ error.Selected, "\"selected\":0", "\"selected\":1" },
        .{ error.Focused, "\"focused\":2", "\"focused\":3" },
        // The focus is a terminal's, and the root here is a split.
        .{ error.Focused, "\"focused\":2", "\"focused\":0" },

        // Not one tree in preorder: a split that is its own child, a
        // child before its parent, children swapped, one node under two
        // splits, a node under none, a child that is not there.
        .{ error.Tree, "\"left\":1", "\"left\":0" },
        .{ error.Tree, "\"right\":2", "\"right\":0" },
        .{ error.Tree, "\"left\":1,\"right\":2", "\"left\":2,\"right\":1" },
        .{ error.Tree, "\"right\":2", "\"right\":1" },
        .{ error.Tree, leaf, leaf ++ "," ++ leaf },
        .{ error.Tree, "\"right\":2", "\"right\":3" },
        .{ error.Tree, split ++ ",", "" },
        .{ error.Tree, split ++ "," ++ leaf ++ ",", split ++ "," ++ split ++ "," },
        .{ error.Syntax, "\"horizontal\"", "\"diagonal\"" },
        .{ error.Syntax, "{\"leaf\":{\"pwd\":null,\"title\":\"build\"}}", "{\"command\":{\"run\":\"calc\"}}" },

        .{ error.Ratio, "\"ratio\":0.5", "\"ratio\":1.5" },
        .{ error.Ratio, "\"ratio\":0.5", "\"ratio\":-0.25" },
        .{ error.Ratio, "\"ratio\":0.5", "\"ratio\":1e9" },
        .{ error.Syntax, "\"ratio\":0.5", "\"ratio\":NaN" },

        .{ error.Title, "\"work\"", "\"\"" },
        .{ error.Title, "\"work\"", "\"a\\u0000b\"" },
        .{ error.Title, "\"build\"", "\"" ++ &@as([max_title + 1]u8, @splat('x')) ++ "\"" },
        .{ error.Title, "\"title\":null,\"selected\"", "\"title\":\"\",\"selected\"" },

        // Directories no shell's report gives: another machine's share,
        // a device, relative ones, a URL (a report's other form, which
        // is not the form kept), and one with a name no directory has.
        .{ error.Pwd, "C:\\\\src", "\\\\\\\\other\\\\share" },
        .{ error.Pwd, "C:\\\\src", "\\\\\\\\.\\\\pipe\\\\x" },
        .{ error.Pwd, "C:\\\\src", "\\\\\\\\?\\\\GLOBALROOT\\\\Device" },
        .{ error.Pwd, "C:\\\\src", "C:src" },
        .{ error.Pwd, "C:\\\\src", "\\\\src" },
        .{ error.Pwd, "C:\\\\src", "src" },
        .{ error.Pwd, "C:\\\\src", "/home/me" },
        .{ error.Pwd, "C:\\\\src", "file://ME/C:/src" },
        .{ error.Pwd, "C:\\\\src", "\\\"C:\\\\src\\\"" },
        .{ error.Pwd, "C:\\\\src", "C:\\\\a<b" },
        .{ error.Pwd, "C:\\\\src", "" },
        .{ error.Pwd, "C:\\\\src", comptime testLongPwd(21) },
    };
    for (cases) |case| {
        const expected, const old, const new = case;
        testing.expectError(expected, testEdited(arena, old, new)) catch |err| {
            std.debug.print("case: {s} -> {s}\n", .{ old, new });
            return err;
        };
    }

    // This machine's share is a directory a report gives.
    _ = try testEdited(arena, "C:\\\\src", "\\\\\\\\ME\\\\share");
    // As is one just short of the longest (20 names are 4022 bytes).
    _ = try testEdited(arena, "C:\\\\src", comptime testLongPwd(20));
    // Either end of a split is a ratio.
    _ = try testEdited(arena, "\"ratio\":0.5", "\"ratio\":0");
    _ = try testEdited(arena, "\"ratio\":0.5", "\"ratio\":1");
}

test "win32: a window state has as many windows, tabs and terminals as it may" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one = testGolden().windows[0];

    // Windows: none, the most, one more.
    try testing.expectError(error.Windows, check(arena, .{ .version = format_version, .windows = &.{} }, &testIsLocal));
    const windows = try arena.alloc(Window, max_windows + 1);
    @memset(windows, one);
    try check(arena, .{ .version = format_version, .windows = windows[0..max_windows] }, &testIsLocal);
    try testing.expectError(error.Windows, check(arena, .{ .version = format_version, .windows = windows }, &testIsLocal));

    // Tabs likewise.
    const tabs = try arena.alloc(Tab, max_tabs + 1);
    @memset(tabs, one.tabs[0]);
    var window = one;
    window.tabs = &.{};
    try testing.expectError(error.Tabs, check(arena, .{ .version = format_version, .windows = &.{window} }, &testIsLocal));
    window.tabs = tabs[0..max_tabs];
    try check(arena, .{ .version = format_version, .windows = &.{window} }, &testIsLocal);
    window.tabs = tabs;
    try testing.expectError(error.Tabs, check(arena, .{ .version = format_version, .windows = &.{window} }, &testIsLocal));

    // Nodes: a chain of splits each with a terminal on its left, as deep
    // as a tree gets, at the most and at two more (a tree's count is
    // odd).
    for ([_]usize{ max_nodes, max_nodes + 2 }) |count| {
        const nodes = try arena.alloc(Node, count);
        var i: u32 = 0;
        while (i + 1 < count) : (i += 2) {
            nodes[i] = .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = i + 1, .right = i + 2 } };
            nodes[i + 1] = .{ .leaf = .{} };
        }
        nodes[count - 1] = .{ .leaf = .{} };
        window.tabs = &.{.{ .focused = 1, .nodes = nodes }};
        const result = check(arena, .{ .version = format_version, .windows = &.{window} }, &testIsLocal);
        if (count <= max_nodes) try result else try testing.expectError(error.Tree, result);
    }

    // The other way up, the walk holds a pending right child per level.
    const nodes = try arena.alloc(Node, max_nodes);
    const splits = max_nodes / 2;
    for (0..splits) |s| nodes[s] = .{ .split = .{
        .layout = .vertical,
        .ratio = 0.5,
        .left = @intCast(s + 1),
        .right = @intCast(max_nodes - 1 - s),
    } };
    for (splits..max_nodes) |l| nodes[l] = .{ .leaf = .{} };
    window.tabs = &.{.{ .focused = max_nodes - 1, .nodes = nodes }};
    try check(arena, .{ .version = format_version, .windows = &.{window} }, &testIsLocal);
}

test "win32: a window state that would not be read is not written" {
    // A title is stored as the program gave it, which need not be text.
    var state = testGolden();
    var window = state.windows[0];
    window.title = "\xff\xfe";
    state.windows = &.{window};
    try testing.expectError(error.Title, encode(testing.allocator, state, &testIsLocal));

    var tab = testGolden().windows[0].tabs[0];
    var nodes = tab.nodes[0..3].*;
    nodes[0].split.ratio = std.math.nan(f16);
    tab.nodes = &nodes;
    window = testGolden().windows[0];
    window.tabs = &.{tab};
    state.windows = &.{window};
    try testing.expectError(error.Ratio, encode(testing.allocator, state, &testIsLocal));

    // Nor is a directory that is not text: JSON has no way to hold it.
    nodes = testGolden().windows[0].tabs[0].nodes[0..3].*;
    nodes[1].leaf.pwd = "C:\\\xff";
    tab.nodes = &nodes;
    window.tabs = &.{tab};
    state.windows = &.{window};
    try testing.expectError(error.Pwd, encode(testing.allocator, state, &testIsLocal));
}
