//! A terminal's inspector window: the core's inspector (src/inspector)
//! drawn by Dear ImGui in a top-level window of its own (`imgui.View`),
//! titled and sized as GTK's. One per terminal at most, opened and closed
//! by the `inspector` action (`Surface.controlInspector`). While it is
//! open the core records what the inspector shows.

const Inspector = @This();

const std = @import("std");

const CoreInspector = @import("../../inspector/main.zig").Inspector;
const imgui = @import("imgui.zig");
const win32 = @import("win32.zig");
const L = win32.L;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");

surface: *Surface,
view: imgui.View,

/// GTK's title, and its default size, here at 96 DPI.
const title = "Ghostty: Terminal Inspector";
const width = 1000;
const height = 600;

/// Open the inspector of `surface`'s terminal, whose core must be live.
pub fn create(surface: *Surface) !*Inspector {
    const core = surface.liveCore() orelse return error.SurfaceNotLive;
    const app = surface.app;
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Inspector);
    errdefer alloc.destroy(self);
    self.surface = surface;

    try core.activateInspector();
    errdefer core.deactivateInspector();

    // Scaled for the terminal's monitor, where the window opens.
    const dpi: c_int = @intCast(Window.dpiOf(app, surface.hwnd));
    try self.view.init(
        app.hinstance,
        L(title),
        @divTrunc(width * dpi, 96),
        @divTrunc(height * dpi, 96),
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
    if (surface.liveCore()) |core| core.deactivateInspector();
    surface.app.core_app.alloc.destroy(self);
}

/// Not under a core frame or a prompt: `CoreInspector.render` takes the
/// terminal's renderer state mutex, which such a frame may hold.
fn ready(ptr: *anyopaque) bool {
    const self: *Inspector = @ptrCast(@alignCast(ptr));
    if (!self.surface.app.canReenterCore()) return false;
    const core = self.surface.liveCore() orelse return false;
    return core.inspector != null;
}

fn draw(ptr: *anyopaque) void {
    const self: *Inspector = @ptrCast(@alignCast(ptr));
    const core = self.surface.liveCore() orelse return;
    const inspector = core.inspector orelse return;
    inspector.render(core);
}

/// Closed as the `inspector` action closes it, except under a core frame
/// or a prompt (`ready`): the frame may be using the core's inspector,
/// which closing frees, so the window stays open until then.
fn close(ptr: *anyopaque) void {
    const self: *Inspector = @ptrCast(@alignCast(ptr));
    if (!self.surface.app.canReenterCore()) return;
    _ = self.surface.controlInspector(.hide);
}
