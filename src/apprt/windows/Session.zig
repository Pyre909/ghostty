//! `window-save-state` in the running app: the open windows described as
//! a `State` (`snapshot`), and a state's windows opened again (`apply`).
//! The format, and what of a state is taken, is State.zig's.
//!
//! A snapshot reads only what this runtime keeps itself: the frames'
//! places, the tabs' trees, and each terminal's stored titles and
//! directory. It asks no core anything and takes no lock, so it can run
//! wherever the UI thread is, a session's end inside a handler included.

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const App = @import("App.zig").App;
pub const State = @import("State.zig");
const Surface = @import("Surface.zig").Surface;
const Tab = @import("Tab.zig");
const toast = @import("toast.zig");
const Window = @import("Window.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Whether a share's server is this machine, for the directories a
/// state holds (`State.check`).
pub fn isLocalHost(host: []const u8) bool {
    return internal_os.hostname.isLocal(host) catch |err| {
        log.warn("cannot tell whether a host is this machine err={}", .{err});
        return false;
    };
}

/// The open windows as a state, or null when none of them is kept. All
/// of it is allocated with `arena`, but for the titles and directories,
/// which are the terminals' own: it is good until a message is handled.
///
/// Left out: the quick terminal, which is not a window to bring back; a
/// window or a terminal that is closing, one parked for `undo` among
/// them, since the user has closed it; and a tab with a terminal that
/// was started with a command, as macOS leaves out such a window: the
/// state has no command in it, and a shell in that program's place is
/// not what was open.
pub fn snapshot(app: *const App, arena: Allocator, isLocal: State.IsLocal) Allocator.Error!?State {
    var windows: std.ArrayList(State.Window) = .empty;
    for (app.windows.items) |window| {
        if (window.quick or window.closing) continue;
        if (windows.items.len == State.max_windows) {
            log.warn("more windows are open than a saved state holds, the rest are not saved", .{});
            break;
        }
        const place = window.savedPlace() orelse continue;

        var tabs: std.ArrayList(State.Tab) = .empty;
        var selected: u32 = 0;
        for (window.tabs.items, 0..) |t, i| {
            if (tabs.items.len == State.max_tabs) {
                log.warn("a window has more tabs than a saved state holds, the rest are not saved", .{});
                break;
            }
            const saved = try snapshotTab(arena, t, isLocal) orelse continue;
            if (i == window.selected) selected = @intCast(tabs.items.len);
            try tabs.append(arena, saved);
        }
        if (tabs.items.len == 0) continue;
        try windows.append(arena, .{
            .rect = place.rect,
            .dpi = place.dpi,
            .maximized = place.maximized,
            .fullscreen = place.fullscreen,
            .title = State.titleOrNone(window.title_override),
            .selected = selected,
            .tabs = tabs.items,
        });
    }
    if (windows.items.len == 0) return null;
    return .{ .version = State.format_version, .windows = windows.items };
}

/// `t` as a state's tab, or null when it is not kept (`snapshot`).
fn snapshotTab(arena: Allocator, t: *const Tab, isLocal: State.IsLocal) Allocator.Error!?State.Tab {
    if (t.tree.nodes.len == 0) return null;
    var it = t.tree.iterator();
    while (it.next()) |entry| if (entry.view.ran_command and !entry.view.closing) return null;
    if (!kept(&t.tree, .root)) return null;

    var nodes: std.ArrayList(State.Node) = .empty;
    var focused: ?u32 = null;
    try emit(arena, &nodes, &focused, isLocal, t, .root);
    if (nodes.items.len > State.max_nodes) {
        log.warn("a tab has more terminals than a saved state holds, it is not saved", .{});
        return null;
    }
    return .{
        .title = State.titleOrNone(t.title_override),
        // The tab's focused terminal, or its first when that one is
        // closing: node 0 is a terminal only when it is the only node.
        .focused = focused orelse first: {
            for (nodes.items, 0..) |node, i| if (node == .leaf) break :first @intCast(i);
            unreachable;
        },
        .nodes = nodes.items,
    };
}

/// Whether anything under `handle` is kept: a terminal that is not
/// closing. The tree is this runtime's own, as deep as the user split
/// it, so walking it by recursion is bounded by what is on screen.
fn kept(tree: *const Window.Tree, handle: Window.Tree.Node.Handle) bool {
    return switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| !surface.closing,
        .split => |s| kept(tree, s.left) or kept(tree, s.right),
    };
}

/// Append what is kept under `handle`, which is something (`kept`), in
/// preorder. A split with only one side kept is that side, as the tree
/// is once the closing terminal has left it.
fn emit(
    arena: Allocator,
    nodes: *std.ArrayList(State.Node),
    focused: *?u32,
    isLocal: State.IsLocal,
    t: *const Tab,
    handle: Window.Tree.Node.Handle,
) Allocator.Error!void {
    switch (t.tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            if (t.focused == surface) focused.* = @intCast(nodes.items.len);
            try nodes.append(arena, .{ .leaf = .{
                .pwd = try State.pwdOrNone(arena, surface.pwd, isLocal),
                .title = State.titleOrNone(surface.title_override),
            } });
        },
        .split => |s| {
            const left = kept(&t.tree, s.left);
            const right = kept(&t.tree, s.right);
            if (!left) return emit(arena, nodes, focused, isLocal, t, s.right);
            if (!right) return emit(arena, nodes, focused, isLocal, t, s.left);
            const at = nodes.items.len;
            try nodes.append(arena, undefined);
            try emit(arena, nodes, focused, isLocal, t, s.left);
            const second = nodes.items.len;
            try emit(arena, nodes, focused, isLocal, t, s.right);
            nodes.items[at] = .{ .split = .{
                .layout = switch (s.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = std.math.clamp(s.ratio, 0, 1),
                .left = @intCast(at + 1),
                .right = @intCast(second),
            } };
        },
    }
}

/// Open the windows `state` describes, each as `State.check` took it;
/// how many opened. Each comes back with its tabs in their order, its
/// splits at their ratios, and its terminals as new shells in the
/// directories saved, at the place `Window.placeRestored` gives it.
///
/// What cannot be made is logged and left out, and the rest still
/// opens: a window whose first terminal cannot start, a tab likewise,
/// and a split there is no room for or that fails, whose one terminal
/// then stands for all that was under it.
pub fn apply(app: *App, state: State) usize {
    var opened: usize = 0;
    for (state.windows) |saved| {
        applyWindow(app, saved) catch |err| {
            log.warn("cannot open a saved window err={}", .{err});
            continue;
        };
        opened += 1;
    }
    return opened;
}

fn applyWindow(app: *App, saved: State.Window) !void {
    const alloc = app.core_app.alloc;
    try app.surfaces.ensureUnusedCapacity(alloc, 1);
    try app.windows.ensureUnusedCapacity(alloc, 1);

    const window = try Window.create(app, leafOptions(saved.tabs[0].nodes, 0, .window), .normal);
    errdefer comptime unreachable;
    app.windows.appendAssumeCapacity(window);
    const root = window.tab().focused.?;
    app.surfaces.appendAssumeCapacity(root);

    // Before any split, each of which is made only where it fits.
    const placing = window.placeRestored(.{
        .rect = saved.rect,
        .dpi = saved.dpi,
        .maximized = saved.maximized,
        .fullscreen = saved.fullscreen,
    });

    // The tab made for each saved one, for the one that shows to be
    // found among those that could be made.
    var made: [State.max_tabs]?*Tab = @splat(null);
    made[0] = window.tab();
    applyTab(app, window, root, saved.tabs[0]);
    for (saved.tabs[1..], made[1..saved.tabs.len]) |tab, *slot| {
        const pane = newTab(app, window, tab) catch |err| {
            log.warn("cannot open a saved tab err={}", .{err});
            continue;
        };
        slot.* = window.tabOf(pane).?;
        applyTab(app, window, pane, tab);
    }
    if (saved.title) |title| setTitle(alloc, window, null, title);

    const selected = if (made[saved.selected]) |t| window.tabIndex(t).? else 0;
    // The first tab's terminals were made hidden; whichever tab shows
    // is laid out here.
    if (selected == window.selected) window.relayout() else window.selectTab(selected);
    window.show(placing);
}

/// A tab at the end of `window` for `tab`, holding its first terminal.
fn newTab(app: *App, window: *Window, tab: State.Tab) !*Surface {
    try app.surfaces.ensureUnusedCapacity(app.core_app.alloc, 1);
    const index = try window.newTab(leafOptions(tab.nodes, 0, .tab), .end);
    errdefer comptime unreachable;
    const pane = window.tabs.items[index].focused.?;
    app.surfaces.appendAssumeCapacity(pane);
    return pane;
}

/// Make `root`'s tab, which holds only `root`, the tab `tab` describes.
/// Each terminal stands for a node of `tab`: `root` for the first, and
/// for a split, the terminal that stood for it then stands for its left
/// side and a new one beside it for its right, at the split's ratio.
fn applyTab(app: *App, window: *Window, root: *Surface, tab: State.Tab) void {
    const t = window.tabOf(root).?;
    var focused = root;
    // The nodes still to make, each with the terminal standing for it:
    // a split takes itself off and puts its two sides on, and a state's
    // tab has at most `max_nodes` nodes.
    var pending: [State.max_nodes]struct { u32, *Surface } = undefined;
    pending[0] = .{ 0, root };
    var depth: usize = 1;
    while (depth > 0) {
        depth -= 1;
        const index, const pane = pending[depth];
        const s = switch (tab.nodes[index]) {
            .leaf => |leaf| {
                settle(pane, leaf);
                if (index == tab.focused) focused = pane;
                continue;
            },
            .split => |s| s,
        };
        // The split takes the place in the tree its terminal has now
        // (`SplitTree.split`), which is where its ratio is then set.
        const handle = window.find(pane).?.handle;
        const beside = split(app, window, pane, s, tab.nodes) catch |err| {
            log.warn("cannot open a saved split, one terminal stands for it err={}", .{err});
            settle(pane, tab.nodes[firstLeaf(tab.nodes, index)].leaf);
            if (tab.focused >= index and tab.focused < subtreeEnd(tab.nodes, index)) focused = pane;
            continue;
        };
        t.tree.resizeInPlace(handle, s.ratio);
        pending[depth] = .{ s.right, beside };
        pending[depth + 1] = .{ s.left, pane };
        depth += 2;
    }
    t.focused = focused;
    if (tab.title) |title| setTitle(app.core_app.alloc, window, root, title);
    // A tab that does not show is told so, as one hidden is
    // (`Window.selectTab`); its terminals were made hidden.
    if (t != window.tab()) {
        var it = t.tree.iterator();
        while (it.next()) |entry| entry.view.occlusionChanged(false);
    }
}

/// A terminal beside `pane` for the right or lower side of `s`.
fn split(app: *App, window: *Window, pane: *Surface, s: State.Split, nodes: []const State.Node) !*Surface {
    try app.surfaces.ensureUnusedCapacity(app.core_app.alloc, 1);
    const beside = try window.split(pane, switch (s.layout) {
        .horizontal => .right,
        .vertical => .down,
    }, leafOptions(nodes, s.right, .split));
    errdefer comptime unreachable;
    app.surfaces.appendAssumeCapacity(beside);
    return beside;
}

/// What a restored terminal keeps of its saved one: the title the user
/// gave it, and its directory, which is where its shell starts. Kept so
/// that a state saved again before the shell reports one, or by a shell
/// that never does, still has it.
fn settle(pane: *Surface, leaf: State.Leaf) void {
    if (leaf.title) |title| {
        if (!pane.setTitleOverride(title)) log.warn("cannot give a restored terminal its title", .{});
    }
    if (leaf.pwd) |pwd| _ = pane.setPwd(pwd);
}

/// The window's title, or with `pane` its tab's.
fn setTitle(alloc: Allocator, window: *Window, pane: ?*const Surface, title: []const u8) void {
    const z = alloc.dupeSentinel(u8, title, 0) catch {
        log.warn("cannot give a restored window or tab its title", .{});
        return;
    };
    defer alloc.free(z);
    const ok = if (pane) |p| window.setTabTitle(p, z) else window.setWindowTitle(z);
    if (!ok) log.warn("cannot give a restored window or tab its title", .{});
}

/// The options to make the terminal standing for node `index` with: it
/// stays, in the end, the first terminal under that node, whose
/// directory it starts in.
fn leafOptions(
    nodes: []const State.Node,
    index: u32,
    context: @FieldType(Surface.Options, "context"),
) Surface.Options {
    return .{
        .working_directory = nodes[firstLeaf(nodes, index)].leaf.pwd,
        .context = context,
        .restored = true,
    };
}

/// The first terminal under node `index`: in preorder a split's left
/// side is the node after it.
fn firstLeaf(nodes: []const State.Node, index: u32) u32 {
    var at = index;
    while (nodes[at] == .split) at += 1;
    return at;
}

/// The index after the last node under `index`: in preorder a node's
/// subtree is the nodes after it until each split met has had its two
/// sides.
fn subtreeEnd(nodes: []const State.Node, index: u32) u32 {
    var at = index;
    var open: u32 = 1;
    while (open > 0) : (at += 1) {
        open -= 1;
        if (nodes[at] == .split) open += 2;
    }
    return at;
}

/// What a launch does with the states saved before it.
pub const Launch = enum {
    /// Opens their windows, in place of the initial window.
    restore,

    /// Leaves them for a later launch, and starts as if there were none.
    fresh,

    /// Deletes them, as `window-save-state = never` says a launch does.
    forget,
};

/// What this launch does, from the option, whether an `initial-command`
/// is set, and the process's arguments after its name. A launch that
/// names what its window is to run, where, or under what title opens
/// that window, and the saved ones wait: they would come back beside
/// it, or instead of it, to a user who asked for one terminal.
pub fn launch(
    mode: configpkg.Config.WindowSaveState,
    initial_command: bool,
    arguments: []const [:0]const u8,
) Launch {
    if (mode == .never) return .forget;
    if (initial_command) return .fresh;
    for (arguments) |arg| {
        // What follows it is the command's, whatever it looks like.
        if (std.mem.eql(u8, arg, "-e")) return .fresh;
        for ([_][]const u8{
            "--command=",
            "--initial-command=",
            "--working-directory=",
            "--title=",
        }) |prefix| {
            if (std.mem.startsWith(u8, arg, prefix)) return .fresh;
        }
    }
    return .restore;
}

/// Why the app is closing its windows.
pub const End = enum {
    /// The `quit` action.
    quit,

    /// Windows shuts down, restarts, or signs the user out.
    session,
};

/// Whether the windows open at `end` are saved, to come back at the next
/// launch. Never those of a window the user closed: closing the last one
/// leaves none open to save.
pub fn saves(mode: configpkg.Config.WindowSaveState, end: End) bool {
    _ = end;
    return switch (mode) {
        .always => true,
        .default, .never => false,
    };
}

/// Where the instances of one kind keep the states they save: a
/// directory of their own (`key`) under the user's state directory,
/// with a file for each process that saved one. A launch takes every
/// file there is (`claim`), so that the windows of each process that a
/// session's end closed come back, in whichever launch is first.
pub const Store = struct {
    dir: std.Io.Dir,

    /// The most files one launch takes; the rest wait for the next.
    pub const max_files = 64;

    /// A file this long or longer is not read.
    pub const max_bytes = 256 * 1024;

    /// The most windows, and terminals in them, one launch opens from
    /// the files it takes.
    pub const max_windows = 32;
    pub const max_terminals = 128;

    const state_suffix = ".json";
    const claimed_suffix = ".claimed";

    /// The longest name of a state file. Those this runtime writes are
    /// far shorter; a longer one is not its own.
    const max_name = 96;

    const max_class = 64;
    const elevated_suffix = ".elevated";

    pub const KeyBuf = [@max("class-".len + max_class, "hash-".len + 16, toast.app_id.len) + elevated_suffix.len]u8;

    /// The name of the directory for the instances of `class`: those
    /// that would serve each other's requests share their saved
    /// windows, and no others. An elevated instance has its own, since
    /// what it opens runs as administrator, and a file the user's other
    /// programs can write must not say what that is.
    ///
    /// A class is the name as it is only where that is a file name on
    /// every volume, and never one Windows reads as another: its
    /// prefix keeps it from a device's name (`CON`), and one ending in
    /// a dot, which Windows drops, is hashed like the rest.
    pub fn key(buf: *KeyBuf, class: ?[]const u8, elevated: bool) []const u8 {
        const tail = if (elevated) elevated_suffix else "";
        const c = class orelse
            return std.fmt.bufPrint(buf, "{s}{s}", .{ toast.app_id, tail }) catch unreachable;
        if (plainClass(c))
            return std.fmt.bufPrint(buf, "class-{s}{s}", .{ c, tail }) catch unreachable;
        return std.fmt.bufPrint(buf, "hash-{x:0>16}{s}", .{ std.hash.Wyhash.hash(0, c), tail }) catch unreachable;
    }

    fn plainClass(class: []const u8) bool {
        if (class.len == 0 or class.len > max_class) return false;
        if (class[class.len - 1] == '.') return false;
        for (class) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        };
        return true;
    }

    /// The store of this process's kind, its directory made if there
    /// was none.
    pub fn open(alloc: Allocator, class: ?[]const u8, elevated: bool) !Store {
        const io = global.io();
        var key_buf: KeyBuf = undefined;
        const parent = "ghostty/window-state/";
        var subdir_buf: [parent.len + @typeInfo(KeyBuf).array.len]u8 = undefined;
        const subdir = std.fmt.bufPrint(&subdir_buf, parent ++ "{s}", .{key(&key_buf, class, elevated)}) catch unreachable;
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        const path = try internal_os.xdg.state(io, alloc, &environ_map, .{ .subdir = subdir });
        defer alloc.free(path);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, path);
        return .{ .dir = try cwd.openDir(io, path, .{ .iterate = true }) };
    }

    pub fn close(self: Store) void {
        self.dir.close(global.io());
    }

    /// Write `state` as a file of this process's, whole or not at all: a
    /// launch never reads one half written. The name is this process's
    /// ID and the time, so that it is no other's, whatever became of a
    /// process that had the ID before.
    pub fn save(self: Store, arena: Allocator, state: State, isLocal: State.IsLocal) !void {
        const io = global.io();
        const text = try State.encode(arena, state, isLocal);
        var name_buf: [max_name]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}-{x}" ++ state_suffix, .{
            std.os.windows.GetCurrentProcessId(),
            @as(u96, @bitCast(std.Io.Timestamp.now(io, .real).toNanoseconds())),
        }) catch unreachable;
        var file = try self.dir.createFileAtomic(io, name, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, text);
        try file.replace(io);
    }

    /// Delete every state there is, taken or not.
    pub fn forget(self: Store) void {
        const io = global.io();
        var it = self.dir.iterate();
        while (it.next(io) catch |err| stop: {
            log.warn("cannot list the saved window states err={}", .{err});
            break :stop null;
        }) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, state_suffix) and
                !std.mem.endsWith(u8, entry.name, claimed_suffix)) continue;
            self.dir.deleteFile(io, entry.name) catch |err| {
                log.warn("cannot delete a saved window state err={}", .{err});
            };
        }
    }

    /// Take the states there are, and give their windows, each as
    /// `State.check` took it, in `arena`.
    ///
    /// A file is taken by renaming it to a name of this process's, which
    /// one process only can do: two launches at once never both open
    /// its windows. It is deleted as soon as it is read, before any of
    /// it is used, so that a state whose windows end the process is
    /// not met again by the next launch. One that cannot be read, is
    /// too long or is not a state is deleted the same, with a warning.
    pub fn claim(self: Store, arena: Allocator, isLocal: State.IsLocal) Allocator.Error![]const State.Window {
        const io = global.io();
        var names: std.ArrayList([]const u8) = .empty;
        var it = self.dir.iterate();
        while (it.next(io) catch |err| stop: {
            log.warn("cannot list the saved window states err={}", .{err});
            break :stop null;
        }) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len > max_name or !std.mem.endsWith(u8, entry.name, state_suffix)) continue;
            if (names.items.len == max_files) {
                log.warn("more window states are saved than one launch takes, the rest wait", .{});
                break;
            }
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        // The order they come back in is not the directory's to choose.
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var windows: std.ArrayList(State.Window) = .empty;
        var terminals: usize = 0;
        var dropped: usize = 0;
        const pid = std.os.windows.GetCurrentProcessId();
        for (names.items) |name| {
            var buf: [max_name + 32]u8 = undefined;
            const mine = std.fmt.bufPrint(&buf, "{s}.{d}" ++ claimed_suffix, .{ name, pid }) catch unreachable;
            self.dir.rename(name, self.dir, mine, io) catch |err| {
                // Another launch has it.
                if (err != error.FileNotFound) log.warn("cannot take a saved window state err={}", .{err});
                continue;
            };
            const read = self.dir.readFileAlloc(io, mine, arena, .limited(max_bytes));
            self.dir.deleteFile(io, mine) catch |err| {
                log.warn("cannot delete a saved window state err={}", .{err});
            };
            const text = read catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("ignored a saved window state that cannot be read err={}", .{err});
                    continue;
                },
            };
            const state = State.decode(arena, text, isLocal) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("ignored a saved window state that is not one err={}", .{err});
                    continue;
                },
            };
            for (state.windows) |window| {
                const count = terminalsOf(window);
                if (windows.items.len == max_windows or terminals + count > max_terminals) {
                    dropped += 1;
                    continue;
                }
                terminals += count;
                try windows.append(arena, window);
            }
        }
        if (dropped > 0) log.warn("more windows were saved than one launch opens, left out count={}", .{dropped});
        return windows.items;
    }

    fn terminalsOf(window: State.Window) usize {
        var count: usize = 0;
        for (window.tabs) |t| {
            for (t.nodes) |node| count += @intFromBool(node == .leaf);
        }
        return count;
    }
};

test "win32: a launch that names what to open leaves the saved windows for another" {
    const testing = std.testing;
    const Case = struct { arguments: []const [:0]const u8, launch: Launch };
    for ([_]Case{
        .{ .arguments = &.{}, .launch = .restore },
        .{ .arguments = &.{"--class=com.example.one"}, .launch = .restore },
        .{ .arguments = &.{ "--font-size=14", "--window-save-state=always" }, .launch = .restore },
        // Not the options, only names that begin as they do.
        .{ .arguments = &.{ "--title-report=true", "--working-directory", "--e" }, .launch = .restore },
        .{ .arguments = &.{ "-e", "top" }, .launch = .fresh },
        .{ .arguments = &.{ "--class=com.example.one", "-e", "top" }, .launch = .fresh },
        .{ .arguments = &.{"--command=top"}, .launch = .fresh },
        .{ .arguments = &.{"--initial-command=top"}, .launch = .fresh },
        .{ .arguments = &.{"--working-directory=C:\\src"}, .launch = .fresh },
        .{ .arguments = &.{"--title=build"}, .launch = .fresh },
    }) |case| {
        errdefer std.debug.print("arguments={any}\n", .{case.arguments});
        try testing.expectEqual(case.launch, launch(.default, false, case.arguments));
        try testing.expectEqual(case.launch, launch(.always, false, case.arguments));
        // The option alone says whether they are deleted.
        try testing.expectEqual(Launch.forget, launch(.never, false, case.arguments));
        try testing.expectEqual(Launch.forget, launch(.never, true, case.arguments));
        try testing.expectEqual(Launch.fresh, launch(.default, true, case.arguments));
        try testing.expectEqual(Launch.fresh, launch(.always, true, case.arguments));
    }
}

test "win32: the windows are saved at the ends the option names" {
    const testing = std.testing;
    try testing.expect(saves(.always, .quit));
    try testing.expect(saves(.always, .session));
    try testing.expect(!saves(.never, .quit));
    try testing.expect(!saves(.never, .session));
    try testing.expect(!saves(.default, .quit));
}

test "win32: only the instances that share a class share their saved windows" {
    const testing = std.testing;
    const long: [65]u8 = @splat('a');
    const classes = [_]?[]const u8{
        null,
        "com.example.one",
        "com.example.two",
        // One Windows would read as the first, with its dot dropped.
        "com.example.one.",
        "..",
        "CON",
        "a b",
        "a/b",
        "a\\..\\b",
        "",
        long[0..64],
        &long,
    };
    var bufs: [classes.len * 2]Store.KeyBuf = undefined;
    var keys: [classes.len * 2][]const u8 = undefined;
    for (classes, 0..) |class, i| {
        keys[2 * i] = Store.key(&bufs[2 * i], class, false);
        keys[2 * i + 1] = Store.key(&bufs[2 * i + 1], class, true);
    }
    for (keys, 0..) |key, i| {
        errdefer std.debug.print("key={s}\n", .{key});
        // A name of one directory, and not one Windows changes.
        try testing.expect(key.len > 0 and key.len <= @typeInfo(Store.KeyBuf).array.len);
        for (key) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-');
        try testing.expect(key[key.len - 1] != '.');
        try testing.expect(!std.ascii.eqlIgnoreCase(key, "con") and !std.ascii.startsWithIgnoreCase(key, "con."));
        for (keys[i + 1 ..]) |other| try testing.expect(!std.ascii.eqlIgnoreCase(key, other));
    }
    var buf: Store.KeyBuf = undefined;
    try testing.expectEqualStrings("class-com.example.one", Store.key(&buf, "com.example.one", false));
    try testing.expectEqualStrings("class-com.example.one.elevated", Store.key(&buf, "com.example.one", true));
    try testing.expectEqualStrings(toast.app_id, Store.key(&buf, null, false));
}
