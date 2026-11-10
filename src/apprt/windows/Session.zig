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
const internal_os = @import("../../os/main.zig");
const App = @import("App.zig").App;
pub const State = @import("State.zig");
const Surface = @import("Surface.zig").Surface;
const Tab = @import("Tab.zig");
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

/// Open the windows `state` describes, which is one `State.check` took;
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
