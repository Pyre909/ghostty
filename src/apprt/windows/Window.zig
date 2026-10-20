//! A terminal window: the top-level frame, and what belongs to the window
//! rather than to a terminal -- its size, caption, maximize state, the size
//! Windows suggests on a DPI change, its system modal loops. Its terminals
//! are `Surface`s, child windows the frame lays out from its split tree
//! (`tree`, `layout`). Until splits can be opened, a window holds one.
//!
//! Ownership, as for surfaces (`App.surfaceDestroyed`): membership in
//! `App.windows` is ownership of the allocation. The frame's WM_NCDESTROY,
//! which Windows sends after its child windows are destroyed, frees a
//! window that is in the list; one that is not yet (`create` failing) is
//! freed by `create` itself.
//!
//! The tree holds its terminals by pointer and owns none of them. It never
//! holds a freed one: a terminal that closes on its own leaves it before it
//! is destroyed (`removePane`), and the frame's WM_DESTROY, which comes
//! before its child windows are destroyed, empties it.

const Window = @This();

const std = @import("std");

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const terminal = @import("../../terminal/main.zig");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;
const Surface = @import("Surface.zig").Surface;
const SplitTree = @import("../../datastruct/main.zig").SplitTree;
const WM_GHOSTTY_DESTROY = @import("App.zig").WM_GHOSTTY_DESTROY;
const postTeardown = @import("App.zig").postTeardown;
const confirm = @import("dialog.zig").confirm;

const log = std.log.scoped(.win32);

/// The frame's window class, registered in `App.init`.
pub const class_name = "GhosttyWindowClass";

/// The terminals of a window. `Surface.ref` and `Surface.unref` do
/// nothing; see the ownership note above.
pub const Tree = SplitTree(Surface);

app: *App,

/// The frame. Written from WM_NCCREATE, the first message it receives, so
/// it is valid in every other handler.
hwnd: win32.HWND,

/// This window's terminals: never empty from `create` until the frame's
/// WM_DESTROY empties it.
tree: Tree,

/// The terminal with the keyboard focus, or the one to give it to when the
/// window is next activated: set by each terminal's WM_SETFOCUS, and moved
/// off a terminal that closes on its own by `removePane`. Null only while
/// the tree is empty.
focused: ?*Surface,

/// A close of the whole window is being asked about, or was agreed to and
/// its teardown posted (`requestClose`). Stops a second WM_CLOSE or
/// close_window from asking or posting twice. Cleared when the user
/// declines or the post fails; otherwise the teardown frees the window.
closing: bool,

/// WM_GHOSTTY_DESTROY arrived while teardown was not allowed; re-posted by
/// `App.repostDeferredDestroys`, as a terminal's is
/// (`Surface.destroy_deferred`).
destroy_deferred: bool,

/// Tracked so `.toggle_maximize` knows which way to toggle.
maximized: bool,

/// This window's share of `App.modal_loop_depth`; see `ModalLoops`.
modal_loops: ModalLoops,

/// Disabled by `App.beginPrompt` for a prompt in another window, for
/// `App.endPrompt` to enable again.
prompt_disabled: bool,

/// Create a window holding a new terminal, still hidden: `show` shows it
/// once the app owns both (`App.newWindow`). The frame is created at
/// CW_USEDEFAULT size so that the terminal, which fills it, starts with a
/// non-zero size (`CoreSurface.init` reads it).
pub fn create(app: *App, opts: Surface.Options) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .hwnd = undefined,
        .tree = .empty,
        .focused = null,
        .maximized = false,
        .modal_loops = .{},
        .prompt_disabled = false,
        .closing = false,
        .destroy_deferred = false,
    };

    const hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        L("Ghostty"),
        win32.WS_OVERLAPPEDWINDOW | win32.WS_CLIPCHILDREN,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        null,
        app.hinstance,
        self,
    ) orelse {
        log.err("CreateWindowExW failed for a window frame", .{});
        return App.Error.Win32WindowCreationFailed;
    };
    // Safe alongside the errdefer above: WM_NCDESTROY frees only a window
    // that is in App.windows, which this one is not yet.
    errdefer _ = win32.DestroyWindow(hwnd);

    const surface = try Surface.create(app, self, opts);
    // Nothing owns the terminal until it is in the tree.
    self.tree = Tree.init(alloc, surface) catch |err| {
        surface.discard();
        return err;
    };
    self.focused = surface;
    return self;
}

/// Size the still-hidden frame to `window-width`/`window-height` and show
/// it. The first WM_SETFOCUS and WM_PAINT (and the first WM_SIZE, unless
/// the size already sent one) reach the terminal from here; its core is
/// live by now.
pub fn show(self: *Window) void {
    if (self.focused) |surface| {
        if (surface.initial_size) |size| {
            applyInitialSize(self.hwnd, (surface.getContentScale() catch unreachable).x, size);
        }
    }
    _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNORMAL);
    _ = win32.UpdateWindow(self.hwnd);
}

/// The frame's window procedure.
pub fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    // As in Surface.wndProc: WM_NCCREATE carries the CREATESTRUCTW, and
    // messages before it find no pointer and fall through.
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |param| {
            const self: *Window = @ptrCast(@alignCast(param));
            self.hwnd = hwnd;
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self: *Window = ptr: {
        const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
    };
    return self.handleMessage(hwnd, msg, wparam, lparam);
}

fn handleMessage(
    self: *Window,
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    switch (msg) {
        // The title bar button, Alt+F4 when no binding consumed it, and the
        // window menu's Close.
        win32.WM_CLOSE => {
            self.requestClose();
            return 0;
        },

        WM_GHOSTTY_DESTROY => {
            // Frees `self` unless deferred; nothing may follow it.
            self.destroyPosted();
            return 0;
        },

        win32.WM_SIZE => {
            const minimized = wparam == win32.SIZE_MINIMIZED;
            // A child window is not resized when its frame is minimized
            // or restored at the same size, so it never sees either:
            // report the visibility from here. The core ignores repeats.
            var it = self.tree.iterator();
            while (it.next()) |entry| entry.view.occlusionChanged(!minimized);

            // A minimized frame reports a 0x0 client area. The terminals
            // keep their sizes, since the core clamps the grid to at least
            // 1x1 and would reflow every line to one column and back.
            if (minimized) return 0;

            // Each terminal gets its WM_SIZE synchronously, which resizes
            // its core.
            self.relayout();
            return 0;
        },

        win32.WM_DPICHANGED => {
            // The new scale first: the suggested rect below lays the
            // terminals out synchronously, and their cores must see the
            // scale before the sizes computed for them. A child window gets
            // no WM_DPICHANGED of its own. wParam carries the new DPI in
            // both words; they are always equal for a window.
            var it = self.tree.iterator();
            while (it.next()) |entry| entry.view.scaleChanged(win32.hiword(wparam));
            applySuggestedRect(hwnd, lparam);

            // The rect lays the terminals out through WM_SIZE only if it
            // changes the client size, but the divider width depends on the
            // DPI too. Terminals already in place get no second WM_SIZE.
            self.relayout();
            return 0;
        },

        // Keyboard focus belongs to a terminal: the frame gets it on
        // activation (DefWindowProcW's WM_ACTIVATE), and passes it on.
        win32.WM_SETFOCUS => {
            if (self.focused) |surface| _ = win32.SetFocus(surface.hwnd);
            return 0;
        },

        // The system modal loops. See App.wndProc's WM_GHOSTTY_WAKEUP.
        win32.WM_ENTERSIZEMOVE, win32.WM_ENTERMENULOOP => {
            self.modal_loops.enter(&self.app.modal_loop_depth);
            return 0;
        },
        win32.WM_EXITSIZEMOVE, win32.WM_EXITMENULOOP => {
            self.modal_loops.exit(&self.app.modal_loop_depth);
            return 0;
        },

        // Sent to the top-level window, not to the terminal with the focus.
        win32.WM_SYSCOMMAND => if (isBareKeyMenu(wparam, lparam)) return 0,

        // Erased by WM_PAINT below, all of it at once.
        win32.WM_ERASEBKGND => return 1,

        // What the terminals leave of the client area: the dividers
        // between them. WS_CLIPCHILDREN keeps the paint out of the
        // terminals, which their own swap chains draw.
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &paint) orelse return 0;
            defer _ = win32.EndPaint(hwnd, &paint);
            const color = dividerColor(&self.app.config);
            const brush = win32.CreateSolidBrush(win32.rgb(color.r, color.g, color.b)) orelse return 0;
            defer _ = win32.DeleteObject(brush);
            _ = win32.FillRect(hdc, &paint.rcPaint, brush);
            return 0;
        },

        win32.WM_DESTROY => {
            // Destroyed inside its own size/move or menu loop (e.g. the
            // shell exited mid-drag): the WM_EXIT* for that loop will not
            // come, so return this window's share of the depth now.
            // Otherwise every later wakeup would tick from whatever loop
            // dispatched it.
            self.modal_loops.release(&self.app.modal_loop_depth);

            // The child windows are destroyed next, and each frees its
            // terminal (App.surfaceDestroyed): the tree lets go of them
            // first. Nothing lays the window out after this.
            self.tree.deinit();
            self.tree = .empty;
            self.focused = null;
            return 0;
        },

        // After the child windows: frees `self`, so nothing may follow.
        win32.WM_NCDESTROY => {
            self.app.windowDestroyed(self);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => {},
    }

    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// WM_CLOSE and `close_window`: close the window and every terminal in it,
/// asking once if any of them would be asked about on its own
/// (`CoreSurface.needsConfirmQuit`). The window is then torn down in one
/// step (`destroyPosted`), as GTK closes a window and as `App.terminate`
/// does, not one terminal at a time, which would lay the window out again
/// after each.
///
/// `close_window` runs inside a core frame, so this only posts, as
/// `Surface.close` does.
pub fn requestClose(self: *Window) void {
    if (self.app.terminating or self.closing) return;
    self.closing = true;

    // The tree does not change while the prompt is open: only `run` adds
    // terminals, and a teardown is deferred (`App.canReenterCore`).
    const ask = ask: {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            const core_surface = entry.view.liveCore() orelse continue;
            if (core_surface.needsConfirmQuit()) break :ask true;
        }
        break :ask false;
    };
    if (ask and !confirm(
        self.app,
        self.hwnd,
        L("A process is still running in this window. Close it anyway?"),
        .ok,
    )) {
        self.closing = false;
        return;
    }

    self.postDestroy();
}

/// Ask for the window to be torn down from a message loop.
pub fn postDestroy(self: *Window) void {
    postTeardown(self.hwnd, &self.closing);
}

/// WM_GHOSTTY_DESTROY on the frame: the window's teardown, run or deferred
/// as a terminal's is (`App.canTearDown`). **`self` is freed by
/// `destroy`**: only `app`, read beforehand, is used after it.
fn destroyPosted(self: *Window) void {
    const app = self.app;

    // terminate drives teardown itself; see App.terminate.
    if (app.terminating) return;

    if (!app.canTearDown()) {
        self.destroy_deferred = true;
        return;
    }

    _ = self.destroy();

    // As in Surface.destroyPosted.
    if (app.canTearDown()) app.repostDeferredDestroys();
}

/// Stop the core of every terminal in the window, then destroy the frame,
/// which destroys their windows. Returns whether the frame was destroyed;
/// **when it was, `self` and every terminal in it have been freed**
/// (WM_DESTROY -> App.surfaceDestroyed, WM_NCDESTROY ->
/// App.windowDestroyed).
///
/// Each stopCore pumps messages, and a handler they run may add terminals
/// to `App.surfaces` or remove them, which can move the list: it is
/// searched afresh after each, until no terminal of this window has a
/// live core left.
pub fn destroy(self: *Window) bool {
    search: while (true) {
        for (self.app.surfaces.items) |surface| {
            if (surface.window != self or surface.liveCore() == null) continue;
            surface.stopCore();
            continue :search;
        }
        break;
    }
    return win32.DestroyWindow(self.hwnd).toBool();
}

/// Take the terminal at `handle` in the tree out of this window ahead of
/// its teardown (`Surface.destroy`), when another terminal stays. The others
/// are laid out again over its place, and if it had the focus, the focus
/// moves to the terminal before it, else the one after it, as on GTK
/// (`closeConfirmationClose` in src/apprt/gtk/class/split_tree.zig). It is
/// hidden, so that nothing shows it while its core stops.
///
/// Fails only to allocate the new tree, and then changes nothing.
pub fn removePane(self: *Window, handle: Tree.Node.Handle) !void {
    const alloc = self.app.core_app.alloc;
    const surface = self.tree.nodes[handle.idx()].leaf;

    // From the tree as it is, which still has `handle`. `.previous` and
    // `.next` allocate nothing.
    const focus: ?*Surface = if (self.focused != surface) self.focused else focus: {
        const to = (self.tree.goto(alloc, handle, .previous) catch null) orelse
            (self.tree.goto(alloc, handle, .next) catch null) orelse
            break :focus null;
        break :focus self.tree.nodes[to.idx()].leaf;
    };

    const tree = try self.tree.remove(alloc, handle);
    errdefer comptime unreachable;
    self.tree.deinit();
    self.tree = tree;
    self.focused = focus;

    // The focus moves first, so that it is never left on a hidden window.
    // Only in the active window: setting the focus in another one would
    // activate it.
    if (focus) |f| {
        if (win32.GetActiveWindow() == self.hwnd) _ = win32.SetFocus(f.hwnd);
    }
    _ = win32.ShowWindow(surface.hwnd, win32.SW_HIDE);
    self.relayout();
}

/// Lay the terminals out over the client area (`layout`). Not while the
/// window is minimized and its client area is empty (see WM_SIZE).
pub fn relayout(self: *Window) void {
    if (self.tree.isEmpty() or win32.IsIconic(self.hwnd).toBool()) return;
    var client: win32.RECT = undefined;
    if (!win32.GetClientRect(self.hwnd, &client).toBool()) return;
    const divider = dividerWidth(dpiOf(self.app, self.hwnd));

    // One batch, so that the terminals move together.
    const count = std.math.lossyCast(c_int, self.tree.nodes.len);
    var placer: Placer = .{ .batch = win32.BeginDeferWindowPos(count) };
    layout(&self.tree, client, divider, &placer);
    if (placer.batch) |batch| {
        if (win32.EndDeferWindowPos(batch).toBool()) return;
    } else if (!placer.dropped) {
        // There was no batch, and each terminal is already in place.
        return;
    }

    // The batch failed, and none of its positions were applied: each
    // terminal is placed on its own instead.
    var direct: Placer = .{ .batch = null };
    layout(&self.tree, client, divider, &direct);
}

/// Moves each terminal where `layout` puts it: in a batch while there is
/// one, else at once.
const Placer = struct {
    batch: ?win32.HDWP,

    /// A DeferWindowPos failed. The batch is then abandoned, as its
    /// documentation says, so none of its positions are applied.
    dropped: bool = false,

    // Not SWP_NOCOPYBITS: it would repaint a terminal on every step of a
    // shrink, which the class styles avoid (`App.registerClasses`), and a
    // flip-model swap chain moves with its window.
    const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;

    pub fn pane(self: *Placer, surface: *Surface, rect: win32.RECT) void {
        if (self.dropped) return;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (self.batch) |batch| {
            self.batch = win32.DeferWindowPos(batch, surface.hwnd, null, rect.left, rect.top, w, h, flags);
            self.dropped = self.batch == null;
        } else {
            _ = win32.SetWindowPos(surface.hwnd, null, rect.left, rect.top, w, h, flags);
        }
    }

    /// Nothing to place: the frame paints the gaps between terminals
    /// itself (WM_PAINT).
    pub fn divider(self: *Placer, rect: win32.RECT) void {
        _ = self;
        _ = rect;
    }
};

/// Where each terminal of `tree` goes in `area`, and the dividers between
/// them, in whole pixels: `ctx.pane(view, rect)` for every leaf and
/// `ctx.divider(rect)` for every split. A split gives `divider` pixels to
/// the line between its sides, fewer if it is narrower than that, and
/// divides the rest by its ratio, to the nearest pixel, so that the panes
/// and dividers tile `area` exactly. `tree.spatial` describes the same
/// layout without dividers, but normalized to f16, which is up to two
/// pixels off at 3840 pixels across.
///
/// Generic over the tree so that tests can lay out a tree of their own.
pub fn layout(tree: anytype, area: win32.RECT, divider: i32, ctx: anytype) void {
    if (tree.isEmpty()) return;
    layoutNode(tree, .root, area, divider, ctx);
}

fn layoutNode(
    tree: anytype,
    handle: @TypeOf(tree.*).Node.Handle,
    area: win32.RECT,
    divider: i32,
    ctx: anytype,
) void {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| ctx.pane(view, area),
        .split => |s| {
            const across = s.layout == .horizontal;
            const total = @max(0, if (across) area.right - area.left else area.bottom - area.top);
            const line = std.math.clamp(divider, 0, total);
            const rest = total - line;
            const scaled = @round(@as(f32, @floatFromInt(rest)) * @as(f32, s.ratio));
            const first = std.math.clamp(std.math.lossyCast(i32, scaled), 0, rest);

            var a = area;
            var d = area;
            var b = area;
            if (across) {
                a.right = area.left + first;
                d.left = a.right;
                d.right = d.left + line;
                b.left = d.right;
            } else {
                a.bottom = area.top + first;
                d.top = a.bottom;
                d.bottom = d.top + line;
                b.top = d.bottom;
            }
            if (line > 0) ctx.divider(d);
            layoutNode(tree, s.left, a, divider, ctx);
            layoutNode(tree, s.right, b, divider, ctx);
        },
    }
}

/// The colour of the line between two terminals: `split-divider-color`, or
/// the one macOS derives from the background (`splitDividerColor` in
/// macos/Sources/Ghostty/Ghostty.Config.swift): darkened by 8% on a light
/// background and by 40% on a dark one. macOS darkens the HSB brightness,
/// which scales red, green and blue alike, and calls a background light
/// above a perceived luminance of 0.5.
pub fn dividerColor(config: *const configpkg.Config) terminal.color.RGB {
    if (config.@"split-divider-color") |color| return color.toTerminalRGB();
    const bg = config.background.toTerminalRGB();
    const keep: f64 = if (bg.perceivedLuminance() > 0.5) 0.92 else 0.6;
    const darken = struct {
        fn darken(c: u8, k: f64) u8 {
            return @intFromFloat(@round(@as(f64, @floatFromInt(c)) * k));
        }
    }.darken;
    return .{ .r = darken(bg.r, keep), .g = darken(bg.g, keep), .b = darken(bg.b, keep) };
}

/// The width of the line between two terminals: a pixel at 96 DPI, scaled
/// to the nearest whole pixel (halves up) and never less than one.
pub fn dividerWidth(dpi: u32) i32 {
    const base = win32.USER_DEFAULT_SCREEN_DPI;
    return @intCast(@max(1, (dpi +| base / 2) / base));
}

/// The DPI of `hwnd`, falling back to the reference 96 when it cannot be
/// determined. Never returns 0: scaling by zero would silently produce a
/// zero-size grid rather than an error anybody could see.
pub fn dpiOf(app: *const App, hwnd: win32.HWND) u32 {
    // Resolved at runtime, not statically imported -- GetDpiForWindow does
    // not exist before Windows 10 1607 and a static import would stop the
    // binary loading there at all. See App.init.
    if (app.get_dpi_for_window) |f| {
        // Returns 0 for an invalid window.
        const v = f(hwnd);
        if (v != 0) return v;
    }

    // Pre-1607 fallback. This is the *correct* answer on those versions:
    // they have no per-monitor DPI, so the system-wide value is the only
    // one there is.
    if (win32.GetDC(null)) |screen| {
        defer _ = win32.ReleaseDC(null, screen);
        const v = win32.GetDeviceCaps(screen, win32.LOGPIXELSX);
        if (v > 0) return @intCast(v);
    }

    return win32.USER_DEFAULT_SCREEN_DPI;
}

/// Resize the window so its client area is `size` scaled by `scale`, the
/// window's content scale. The whole value is scaled, as macOS and GTK also
/// treat it, so the core's device-pixel padding comes out larger by the
/// scale factor: the grid is never smaller than requested, at most a little
/// larger, unless the window would not fit its monitor's work area. The
/// frame is measured from the window itself rather than with
/// AdjustWindowRectExForDpi, which does not exist before Windows 10 1607
/// (see the dynamic imports in App.init): the window already exists at its
/// final DPI, so its window rect minus its client rect is exactly the frame.
/// The sizes saturate, since `window-width` is only clamped from below.
pub fn applyInitialSize(hwnd: win32.HWND, scale: f32, size: apprt.action.InitialSize) void {
    const client_w = std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(size.width)) * scale));
    const client_h = std.math.lossyCast(i32, @ceil(@as(f32, @floatFromInt(size.height)) * scale));
    var window: win32.RECT = undefined;
    var client: win32.RECT = undefined;
    var monitor: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    const read = read: {
        if (!win32.GetWindowRect(hwnd, &window).toBool()) break :read false;
        if (!win32.GetClientRect(hwnd, &client).toBool()) break :read false;
        const m = win32.MonitorFromWindow(
            hwnd,
            win32.MONITOR_DEFAULTTONEAREST,
        ) orelse break :read false;
        break :read win32.GetMonitorInfoW(m, &monitor).toBool();
    };
    if (!read) {
        log.warn("unable to read the window frame or work area, initial size not applied", .{});
        return;
    }
    const frame_w = (window.right - window.left) - (client.right - client.left);
    const frame_h = (window.bottom - window.top) - (client.bottom - client.top);

    // CW_USEDEFAULT placed the default-sized window inside the work
    // area, but nothing keeps a larger one grown from the same corner
    // there: SetWindowPos does not move a window back on screen, and
    // the only size limit Windows applies is the maximum track size,
    // about the whole virtual screen.
    const rect = constrainToWorkArea(
        window.left,
        window.top,
        client_w +| frame_w,
        client_h +| frame_h,
        monitor.rcWork,
    );

    // SetWindowPos sends WM_SIZE synchronously; the core is live, so it
    // sees the new size before the first paint. That WM_SIZE also reports
    // the window visible (occlusionCallback) while it is still hidden,
    // which is harmless only because ShowWindow follows immediately.
    if (!win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    ).toBool()) log.warn("unable to apply initial window size err={}", .{win32.GetLastError()});
}

/// The rect for a `width` x `height` window at `x`, `y`, kept inside the
/// work area `work` as macOS keeps a window on screen
/// (`NSWindow.constrainToScreen`): it is moved up or left until it fits, and
/// made smaller only if it is larger than the work area.
fn constrainToWorkArea(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    work: win32.RECT,
) win32.RECT {
    const w = @min(width, work.right - work.left);
    const h = @min(height, work.bottom - work.top);
    const left = @max(work.left, @min(x, work.right - w));
    const top = @max(work.top, @min(y, work.bottom - h));
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// Bring the window to the front, restoring it first if it is
/// minimized, as GTK's `gtk.Window.present` does. SetForegroundWindow
/// alone only activates a window: a minimized one stays minimized.
pub fn present(hwnd: win32.HWND) bool {
    if (win32.IsIconic(hwnd).toBool()) {
        // The BOOL is the previous visibility, not success.
        _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
    }

    // SetForegroundWindow returning FALSE is the documented *normal*
    // outcome under Windows' foreground lock -- the calling process is
    // not foreground and has had no recent input -- so hard-coding true
    // here would lie in the common case rather than the rare one.
    return win32.SetForegroundWindow(hwnd).toBool();
}

/// `.toggle_maximize`: maximize the window, or restore it, and record which
/// in `maximized`.
pub fn toggleMaximize(hwnd: win32.HWND, maximized: *bool) void {
    maximized.* = !maximized.*;
    // ShowWindow's BOOL is the window's *previous* visibility, not
    // whether the call succeeded, so it deliberately is not
    // propagated: a window that was hidden returns zero from a
    // call that worked perfectly.
    _ = win32.ShowWindow(
        hwnd,
        if (maximized.*) win32.SW_MAXIMIZE else win32.SW_RESTORE,
    );
}

/// WM_DPICHANGED's second half: lParam carries the suggested new window
/// rect. Not honoring it leaves the window the wrong physical size on the
/// new monitor, so it is applied verbatim. SetWindowPos sends WM_SIZE
/// synchronously, so the surfaces must have the new scale before this.
pub fn applySuggestedRect(hwnd: win32.HWND, lparam: win32.LPARAM) void {
    const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    _ = win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
    );
}

/// Whether a WM_SYSCOMMAND is a bare Alt or F10 released without being
/// consumed: it arrives as SC_KEYMENU with lParam 0 and would put the
/// window into menu mode, swallowing the next keystroke. The window has no
/// menu bar, so that mode is never wanted. Alt+Space arrives with lParam
/// ' ' and still opens the window menu.
pub fn isBareKeyMenu(wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    return wparam & 0xFFF0 == win32.SC_KEYMENU and lparam == 0;
}

/// A window's share of `App.modal_loop_depth`: the system modal loops
/// (size/move, menu) it has entered and not yet reported leaving. A window
/// destroyed inside its own loop never receives the matching WM_EXIT*, so
/// its share is returned with `release` instead.
pub const ModalLoops = struct {
    count: u32 = 0,

    /// WM_ENTERSIZEMOVE, WM_ENTERMENULOOP.
    pub fn enter(self: *ModalLoops, app_depth: *u32) void {
        self.count += 1;
        app_depth.* += 1;
    }

    /// WM_EXITSIZEMOVE, WM_EXITMENULOOP. Only undoes what this window added,
    /// so a stray exit can never take another window's loop out of the
    /// count.
    pub fn exit(self: *ModalLoops, app_depth: *u32) void {
        if (self.count == 0) return;
        self.count -= 1;
        app_depth.* -|= 1;
    }

    /// WM_DESTROY: give back whatever this window still holds.
    pub fn release(self: *ModalLoops, app_depth: *u32) void {
        app_depth.* -|= self.count;
        self.count = 0;
    }

    /// Whether this window is inside one of its loops.
    pub fn inLoop(self: ModalLoops) bool {
        return self.count != 0;
    }
};

test "win32: an initial size is kept inside the monitor work area" {
    const testing = std.testing;
    const RECT = win32.RECT;

    // 1920x1080 with a 40 px taskbar at the bottom.
    const work: RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };

    // Fits where it is: unchanged.
    try testing.expectEqual(
        RECT{ .left = 100, .top = 50, .right = 900, .bottom = 650 },
        constrainToWorkArea(100, 50, 800, 600, work),
    );

    // Fits the work area but not below and right of its origin: moved up
    // and left, at the size asked for.
    try testing.expectEqual(
        RECT{ .left = 1120, .top = 40, .right = 1920, .bottom = 1040 },
        constrainToWorkArea(1300, 80, 800, 1000, work),
    );

    // Larger than the work area, including the saturated size of an
    // enormous `window-width`: the whole work area.
    try testing.expectEqual(work, constrainToWorkArea(100, 50, 2500, 1200, work));
    try testing.expectEqual(work, constrainToWorkArea(
        100,
        50,
        std.math.maxInt(i32),
        std.math.maxInt(i32),
        work,
    ));

    // A monitor left of and above the primary, with the taskbar on its
    // left edge: the work area does not start at zero.
    try testing.expectEqual(
        RECT{ .left = -1232, .top = 524, .right = -632, .bottom = 824 },
        constrainToWorkArea(-1260, 700, 600, 300, .{
            .left = -1232,
            .top = -200,
            .right = 0,
            .bottom = 824,
        }),
    );
}

/// For the layout tests: a view with a name and no reference count.
const TestPane = struct {
    name: u8,

    pub fn ref(self: *TestPane) *TestPane {
        return self;
    }

    pub fn unref(self: *TestPane) void {
        _ = self;
    }
};

const TestTree = SplitTree(TestPane);

/// What `layout` reports, kept for the layout tests.
const TestLayout = struct {
    panes: [8]Pane = undefined,
    pane_count: usize = 0,
    dividers: [8]win32.RECT = undefined,
    divider_count: usize = 0,

    const Pane = struct { view: *TestPane, rect: win32.RECT };

    pub fn pane(self: *TestLayout, view: *TestPane, rect: win32.RECT) void {
        self.panes[self.pane_count] = .{ .view = view, .rect = rect };
        self.pane_count += 1;
    }

    pub fn divider(self: *TestLayout, rect: win32.RECT) void {
        self.dividers[self.divider_count] = rect;
        self.divider_count += 1;
    }

    fn rectOf(self: *const TestLayout, view: *const TestPane) win32.RECT {
        for (self.panes[0..self.pane_count]) |p| {
            if (p.view == view) return p.rect;
        }
        unreachable;
    }

    /// The panes and dividers cover `area` exactly once: every rect lies
    /// inside it, no two overlap, and together they are as large as it.
    fn expectTiles(self: *const TestLayout, area: win32.RECT) !void {
        var rects: [16]win32.RECT = undefined;
        var n: usize = 0;
        for (self.panes[0..self.pane_count]) |p| {
            rects[n] = p.rect;
            n += 1;
        }
        for (self.dividers[0..self.divider_count]) |d| {
            rects[n] = d;
            n += 1;
        }
        var covered: i64 = 0;
        for (rects[0..n], 0..) |a, i| {
            try std.testing.expect(a.left >= area.left and a.right <= area.right);
            try std.testing.expect(a.top >= area.top and a.bottom <= area.bottom);
            try std.testing.expect(a.left <= a.right and a.top <= a.bottom);
            covered += @as(i64, a.right - a.left) * (a.bottom - a.top);
            for (rects[i + 1 .. n]) |b| {
                const overlap = a.left < b.right and b.left < a.right and
                    a.top < b.bottom and b.top < a.bottom;
                try std.testing.expect(!overlap);
            }
        }
        try std.testing.expectEqual(
            @as(i64, area.right - area.left) * (area.bottom - area.top),
            covered,
        );
    }
};

/// `tree` with `pane` split off `at` in `direction`.
fn testSplit(
    tree: *const TestTree,
    at: TestTree.Node.Handle,
    direction: TestTree.Split.Direction,
    ratio: f16,
    pane: *TestPane,
) !TestTree {
    const alloc = std.testing.allocator;
    var single: TestTree = try .init(alloc, pane);
    defer single.deinit();
    return tree.split(alloc, at, direction, ratio, &single);
}

test "win32: dividers take their colour from the config or the background" {
    const alloc = std.testing.allocator;
    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    // The default dark background, 0x282C34: 40% darker.
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0x18, .g = 0x1A, .b = 0x1F },
        dividerColor(&config),
    );

    // A light one: 8% darker.
    config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0xEB, .g = 0xEB, .b = 0xEB },
        dividerColor(&config),
    );

    // Set: used as it is.
    config.@"split-divider-color" = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 },
        dividerColor(&config),
    );
}

test "win32: a divider is a pixel at 96 DPI, scaled to the nearest pixel" {
    // DPI, width: 125% rounds down, 150% and 250% round up.
    for ([_][2]u32{
        .{ 0, 1 },   .{ 96, 1 },  .{ 120, 1 }, .{ 144, 2 },
        .{ 168, 2 }, .{ 192, 2 }, .{ 240, 3 }, .{ 288, 3 },
    }) |c| {
        try std.testing.expectEqual(@as(i32, @intCast(c[1])), dividerWidth(c[0]));
    }
}

test "win32: split terminals and their dividers tile the window" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var c: TestPane = .{ .name = 'c' };

    // a | b, then b over c.
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var ab = try testSplit(&only_a, .root, .right, 0.5, &b);
    defer ab.deinit();
    var tree = try testSplit(&ab, ab.locate(&b).?, .down, 0.3, &c);
    defer tree.deinit();

    // Odd sizes, so that neither split divides evenly.
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 1001, .bottom = 601 };
    var got: TestLayout = .{};
    layout(&tree, area, 2, &got);
    try std.testing.expectEqual(3, got.pane_count);
    try std.testing.expectEqual(2, got.divider_count);
    try got.expectTiles(area);

    // 999 pixels left for the panes; half of it rounds up.
    try std.testing.expectEqual(500, got.rectOf(&a).right);
    try std.testing.expectEqual(502, got.rectOf(&b).left);
    // 599 left between b and c; 0.3 of it is 179.7.
    try std.testing.expectEqual(180, got.rectOf(&b).bottom);
    try std.testing.expectEqual(182, got.rectOf(&c).top);

    // Within a window that does not start at the origin, too.
    const moved: win32.RECT = .{ .left = 7, .top = 3, .right = 108, .bottom = 54 };
    var got_moved: TestLayout = .{};
    layout(&tree, moved, 1, &got_moved);
    try got_moved.expectTiles(moved);
}

test "win32: a split at either end gives one side all of it" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var tree = try testSplit(&only_a, .root, .down, 0.5, &b);
    defer tree.deinit();
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 80, .bottom = 50 };

    for ([_]f16{ 0, 1 }) |ratio| {
        tree.resizeInPlace(.root, ratio);
        var got: TestLayout = .{};
        layout(&tree, area, 1, &got);
        try got.expectTiles(area);
        const a_height = got.rectOf(&a).bottom - got.rectOf(&a).top;
        const b_height = got.rectOf(&b).bottom - got.rectOf(&b).top;
        try std.testing.expectEqual(@as(i32, if (ratio == 0) 0 else 49), a_height);
        try std.testing.expectEqual(@as(i32, if (ratio == 0) 49 else 0), b_height);
    }
}

test "win32: a divider wider than its split takes all of it" {
    const alloc = std.testing.allocator;
    var a: TestPane = .{ .name = 'a' };
    var b: TestPane = .{ .name = 'b' };
    var only_a: TestTree = try .init(alloc, &a);
    defer only_a.deinit();
    var tree = try testSplit(&only_a, .root, .right, 0.5, &b);
    defer tree.deinit();

    // A window dragged down to almost nothing at a high DPI.
    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 3, .bottom = 40 };
    var got: TestLayout = .{};
    layout(&tree, area, 10, &got);
    try got.expectTiles(area);
    try std.testing.expectEqual(0, got.rectOf(&a).right - got.rectOf(&a).left);
    try std.testing.expectEqual(0, got.rectOf(&b).right - got.rectOf(&b).left);
}

test "win32: the pixel layout agrees with the split tree's own" {
    // tree.spatial() places the same panes in a 1x1 square, without
    // dividers. Scaled up, each pane must be within its dividers and a
    // pixel of rounding per split above it.
    const alloc = std.testing.allocator;
    var panes: [4]TestPane = .{ .{ .name = 'a' }, .{ .name = 'b' }, .{ .name = 'c' }, .{ .name = 'd' } };
    var t0: TestTree = try .init(alloc, &panes[0]);
    defer t0.deinit();
    var t1 = try testSplit(&t0, .root, .right, 0.6, &panes[1]);
    defer t1.deinit();
    var t2 = try testSplit(&t1, t1.locate(&panes[0]).?, .down, 0.25, &panes[2]);
    defer t2.deinit();
    var tree = try testSplit(&t2, t2.locate(&panes[1]).?, .left, 0.7, &panes[3]);
    defer tree.deinit();

    var sp = try tree.spatial(alloc);
    defer sp.deinit(alloc);

    const area: win32.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const divider = 2;
    var got: TestLayout = .{};
    layout(&tree, area, divider, &got);
    try got.expectTiles(area);

    // Two splits above every pane here.
    const tolerance: f32 = 2 * (divider + 1);
    const w: f32 = @floatFromInt(area.right);
    const h: f32 = @floatFromInt(area.bottom);
    for (got.panes[0..got.pane_count]) |p| {
        const slot = sp.slots[tree.locate(p.view).?.idx()];
        const want = [4]f32{
            @as(f32, slot.x) * w,
            @as(f32, slot.y) * h,
            (@as(f32, slot.x) + @as(f32, slot.width)) * w,
            (@as(f32, slot.y) + @as(f32, slot.height)) * h,
        };
        const have = [4]i32{ p.rect.left, p.rect.top, p.rect.right, p.rect.bottom };
        for (want, have) |x, y| {
            try std.testing.expect(@abs(x - @as(f32, @floatFromInt(y))) <= tolerance);
        }
    }
}

test "win32: modal loops are counted per window and returned on destroy" {
    // The app ticks the core from its window procedure while any window is
    // in a size/move or menu loop (WM_GHOSTTY_WAKEUP), so the count must
    // not leak past a loop's end or a window's. One message-only window
    // stands in for both frames: these handlers never use it.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    var app: App = undefined;
    app.modal_loop_depth = 0;

    var a: Window = undefined;
    var b: Window = undefined;
    for ([_]*Window{ &a, &b }) |window| {
        window.app = &app;
        window.hwnd = hwnd;
        window.tree = .empty;
        window.focused = null;
        window.modal_loops = .{};
    }

    _ = a.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    _ = a.handleMessage(hwnd, win32.WM_ENTERMENULOOP, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    // An exit with no loop of its own takes nothing from another window.
    _ = b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(2, app.modal_loop_depth);

    _ = b.handleMessage(hwnd, win32.WM_ENTERSIZEMOVE, 0, 0);
    try std.testing.expectEqual(3, app.modal_loop_depth);

    // Destroyed inside both of its loops, so their exits never come.
    _ = a.handleMessage(hwnd, win32.WM_DESTROY, 0, 0);
    try std.testing.expectEqual(1, app.modal_loop_depth);

    _ = b.handleMessage(hwnd, win32.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
    _ = b.handleMessage(hwnd, win32.WM_EXITMENULOOP, 0, 0);
    try std.testing.expectEqual(0, app.modal_loop_depth);
}

test "win32: presenting a minimized window restores it" {
    // A top-level window created minimized and hidden stands in for a
    // terminal window: `present` only uses the handle.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        win32.WS_OVERLAPPEDWINDOW | win32.WS_MINIMIZE,
        0,
        0,
        200,
        100,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);
    try std.testing.expect(win32.IsIconic(hwnd).toBool());

    _ = present(hwnd);
    try std.testing.expect(!win32.IsIconic(hwnd).toBool());
}
