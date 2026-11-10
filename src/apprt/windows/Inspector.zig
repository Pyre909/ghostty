//! A terminal's inspector window: the core's inspector (src/inspector)
//! drawn by Dear ImGui in a top-level window of its own (`imgui.View`),
//! titled and sized as GTK's. One per terminal at most, opened and closed
//! by the `inspector` action (`Surface.controlInspector`). While it is
//! open the core records what the inspector shows.

const Inspector = @This();

const std = @import("std");
const builtin = @import("builtin");

const CoreInspector = @import("../../inspector/main.zig").Inspector;
const CoreSurface = @import("../../Surface.zig");
const imgui = @import("imgui.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const TitleDialog = @import("TitleDialog.zig");
const Window = @import("Window.zig");
const Question = @import("dialog.zig").Question;

const log = std.log.scoped(.win32);

surface: *Surface,
view: imgui.View,

/// The outermost prompt disabled the window (`App.beginPrompt`), and
/// `App.endPrompt` enables it again.
prompt_disabled: bool,

/// The title bar is dark (`applyTheme`).
dark_frame: bool,

/// GTK's title, and its default size, here the client area's at 96 DPI.
const title = "Ghostty: Terminal Inspector";
const width = 1000;
const height = 600;

/// For tests: what stands in for the terminal's core, which a test's
/// terminal does not have: one marked live has an unmade core.
pub var test_core: if (builtin.is_test) ?*TestCore else void =
    if (builtin.is_test) null else {};

/// For tests: whether the core's inspector is active, and what was asked
/// of the core.
pub const TestCore = struct {
    active: bool = false,
    activations: u32 = 0,
    deactivations: u32 = 0,
    renders: u32 = 0,

    /// Activation fails, as the core's can when out of memory.
    refuse: bool = false,
};

/// Open the inspector of `surface`'s terminal, whose core must be live.
pub fn create(surface: *Surface) !*Inspector {
    const core = surface.liveCore() orelse return error.SurfaceNotLive;
    const app = surface.app;
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Inspector);
    errdefer alloc.destroy(self);
    self.surface = surface;
    self.prompt_disabled = false;
    self.dark_frame = false;

    try activate(core);
    errdefer deactivate(core);

    // Made where the terminal's frame is, so on its monitor and at its
    // DPI, then sized and centred there.
    const frame = surface.window.hwnd;
    var over: win32.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = height };
    _ = win32.GetWindowRect(frame, &over);
    var translated: Question = .{};
    try self.view.init(
        app.hinstance,
        translated.one(title),
        over,
        &app.modal_loop_depth,
        .{ .ptr = self, .ready = ready, .draw = draw, .close = close },
    );
    place(self.view.hwnd, frame, Window.dpiOf(app, self.view.hwnd));
    // Read again, as placed: a move to another DPI would have scaled the
    // view already (WM_DPICHANGED), and this must not undo it.
    self.view.setDpi(Window.dpiOf(app, self.view.hwnd));
    self.applyTheme();
    // The view's context is current, for the inspector's fonts and flags.
    CoreInspector.setup();
    self.view.show();
    return self;
}

/// Size the window `hwnd` so that its client area is `width` by `height`
/// at `dpi`, its own, centred over the terminal's frame and kept inside
/// the work area of the frame's monitor (`TitleDialog.centred`). Its frame
/// is measured from the window itself, as `Window.resizeClient` measures
/// a terminal's: AdjustWindowRectExForDpi does not exist before Windows 10
/// 1607. Left where it was made when the windows cannot be read.
fn place(hwnd: win32.HWND, frame: win32.HWND, dpi: u32) void {
    var window: win32.RECT = undefined;
    var client: win32.RECT = undefined;
    var over: win32.RECT = undefined;
    if (!win32.GetWindowRect(hwnd, &window).toBool() or
        !win32.GetClientRect(hwnd, &client).toBool() or
        !win32.GetWindowRect(frame, &over).toBool())
    {
        log.warn("cannot read the inspector window's frame err={}", .{win32.GetLastError()});
        return;
    }
    const monitor = Window.monitorInfo(win32.MonitorFromWindow(frame, win32.MONITOR_DEFAULTTONEAREST)) orelse return;
    const scaled: c_int = @intCast(dpi);
    const w = @divTrunc(width * scaled, 96) + (window.right - window.left) - (client.right - client.left);
    const h = @divTrunc(height * scaled, 96) + (window.bottom - window.top) - (client.bottom - client.top);
    const at = TitleDialog.centred(over, w, h, monitor.rcWork);
    if (!win32.SetWindowPos(hwnd, null, at.left, at.top, at.right - at.left, at.bottom - at.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE).toBool())
        log.warn("cannot place the inspector window err={}", .{win32.GetLastError()});
}

/// Give the window the title bar the frames have (`Window.frameDark`), as
/// GTK's inspector window follows the app's color scheme. A failed call
/// leaves `dark_frame` as it was, so the next one tries again.
pub fn applyTheme(self: *Inspector) void {
    const app = self.surface.app;
    const dark = Window.frameDark(&app.config, app.system_scheme, app.window_theme_override);
    if (dark == self.dark_frame) return;
    const value: win32.BOOL = if (dark) .TRUE else .FALSE;
    const hr = win32.DwmSetWindowAttribute(
        self.view.hwnd,
        win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &value,
        @sizeOf(win32.BOOL),
    );
    if (hr < 0) {
        log.warn("cannot set the inspector's title bar mode dark={} hr=0x{x}", .{ dark, @as(u32, @bitCast(hr)) });
        return;
    }
    self.dark_frame = dark;
}

/// Close the window, and end the core's recording if the core is live.
pub fn destroy(self: *Inspector) void {
    const surface = self.surface;
    self.view.deinit();
    if (surface.liveCore()) |core| deactivate(core);
    surface.app.core_app.alloc.destroy(self);
}

/// Not under a core frame or a prompt: `CoreInspector.render` takes the
/// terminal's renderer state mutex, which such a frame may hold.
fn ready(ptr: *anyopaque) bool {
    const self: *Inspector = @ptrCast(@alignCast(ptr));
    if (!self.surface.app.canReenterCore()) return false;
    const core = self.surface.liveCore() orelse return false;
    return isActive(core);
}

fn draw(ptr: *anyopaque) void {
    const self: *Inspector = @ptrCast(@alignCast(ptr));
    const core = self.surface.liveCore() orelse return;
    render(core);
}

/// Closed as the `inspector` action closes it, except under a core frame,
/// which may be using the core's inspector that closing frees (`ready`):
/// the window then stays open. A prompt disables the window
/// (`App.beginPrompt`), so it is not closed from under one either.
fn close(ptr: *anyopaque) void {
    const self: *Inspector = @ptrCast(@alignCast(ptr));
    if (!self.surface.app.canReenterCore()) return;
    _ = self.surface.controlInspector(.hide);
}

// The core's inspector calls, which tests make on `test_core` instead.

fn activate(core: *CoreSurface) !void {
    if (builtin.is_test) if (test_core) |t| {
        if (t.refuse) return error.OutOfMemory;
        t.active = true;
        t.activations += 1;
        return;
    };
    try core.activateInspector();
}

fn deactivate(core: *CoreSurface) void {
    if (builtin.is_test) if (test_core) |t| {
        if (t.active) t.deactivations += 1;
        t.active = false;
        return;
    };
    core.deactivateInspector();
}

fn isActive(core: *CoreSurface) bool {
    if (builtin.is_test) if (test_core) |t| return t.active;
    return core.inspector != null;
}

fn render(core: *CoreSurface) void {
    if (builtin.is_test) if (test_core) |t| {
        t.renders += 1;
        return;
    };
    const inspector = core.inspector orelse return;
    inspector.render(core);
}
