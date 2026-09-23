//! A frame: the render passes drawn into one target, presented when the
//! frame completes.
const Self = @This();

const std = @import("std");

const api = @import("api.zig");
const Renderer = @import("../generic.zig").Renderer(D3D11);
const D3D11 = @import("../D3D11.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    context: *api.ID3D11DeviceContext,
};

context: *api.ID3D11DeviceContext,
renderer: *Renderer,
target: *Target,

pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    return .{
        .context = opts.context,
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
    return RenderPass.begin(.{
        .context = self.context,
        .attachments = attachments,
    });
}

/// Complete this frame and present the target.
///
/// Presentation is synchronous on this thread either way, so `sync` is
/// ignored, as the WGL backend ignores it. The frame is unhealthy only
/// when the device was lost; a present that failed for any other reason,
/// or a frame dropped for a stale size, leaves the renderer healthy.
pub fn complete(self: *Self, sync: bool) void {
    _ = sync;

    const health: Health = if (self.renderer.api.present(self.target.*)) .healthy else |err| switch (err) {
        error.DeviceLost => .unhealthy,
        error.PresentFailed => .healthy,
    };

    self.renderer.frameCompleted(health);
}
