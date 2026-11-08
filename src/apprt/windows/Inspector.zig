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
const L = win32.L;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");

surface: *Surface,
view: imgui.View,

/// The outermost prompt disabled the window (`App.beginPrompt`), and
/// `App.endPrompt` enables it again.
prompt_disabled: bool,

/// GTK's title, and its default size, here at 96 DPI.
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

    try activate(core);
    errdefer deactivate(core);

    // Scaled for the terminal's monitor, where the window opens.
    const dpi: c_int = @intCast(Window.dpiOf(app, surface.hwnd));
    try self.view.init(
        app.hinstance,
        L(title),
        @divTrunc(width * dpi, 96),
        @divTrunc(height * dpi, 96),
        &app.modal_loop_depth,
        .{ .ptr = self, .ready = ready, .draw = draw, .close = close },
    );
    // The view's context is current, for the inspector's fonts and flags.
    CoreInspector.setup();
    self.view.show();
    return self;
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
