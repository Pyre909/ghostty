//! `window-save-state` in the running app: the open windows described as
//! a `State` (`snapshot`). The format, and what of a state is taken, is
//! State.zig's.
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
