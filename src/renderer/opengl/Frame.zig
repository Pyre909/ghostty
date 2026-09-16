//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const global = @import("../../global.zig");
const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we never block, instead
/// pushing the newly presented and exported frame to the frame queue.
///
/// On WGL (`OpenGL.wgl_enabled`) there is no queue: the frame is put on the
/// window right here, as metal/Frame.zig does, and `sync` is ignored too.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    // If there are any GL errors, consider the frame unhealthy.
    const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

    if (comptime OpenGL.wgl_enabled) {
        // Direct present: blit + SwapBuffers on this (the render) thread.
        // No pushFrame (ExportedFrame is void) and no `.redraw` push, since
        // the apprt has nothing to pull. No glFinish either: SwapBuffers
        // already flushes, and a dropped or unhealthy frame's commands are
        // flushed by the next swap.
        if (health == .healthy) {
            self.renderer.api.present(self.target.*) catch |err| {
                log.warn("failed to present render target: err={}", .{err});
            };
        } else {
            // The health check above popped one error flag. GL keeps one
            // flag per error kind, so any left over would make the next
            // frame unhealthy too, and here an unhealthy frame is not
            // presented at all. Drop them so one bad frame costs one frame.
            @import("wgl.zig").drainErrors();
        }
    } else {
        // If the frame is healthy, export it and push to the present queue.
        // The apprt pulls from this queue in its snapshot handler.
        if (health == .healthy) frame: {
            const frame = self.renderer.api.present(self.target.*) catch |err| {
                log.warn("failed to present render target: err={}", .{err});
                break :frame;
            };

            self.renderer.pushFrame(frame);

            // Notify the surface that it should redraw
            _ = self.renderer.surface_mailbox.push(.redraw, .{ .forever = {} });
        }
        gl.finish();
    }

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
