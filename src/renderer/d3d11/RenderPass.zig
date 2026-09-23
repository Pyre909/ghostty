//! A render pass: one color attachment, cleared when asked, and the draw
//! steps into it.
//!
//! Device context state persists across steps within a pass on purpose: the
//! image step passes no uniforms and reads the ones the background step
//! bound, exactly as on Metal and OpenGL.
const Self = @This();

const std = @import("std");

const api = @import("api.zig");
const Buffer = @import("buffer.zig").Buffer;
const Handle = @import("buffer.zig").Handle;
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    context: *api.ID3D11DeviceContext,

    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// The primitive topologies the generic renderer draws with.
pub const Primitive = enum {
    triangle,
    triangle_strip,
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?Handle = null,
    buffers: []const ?Handle = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

context: *api.ID3D11DeviceContext,

/// The attachment's view, or null when it has none, in which case every
/// step is skipped.
rtv: ?*api.ID3D11RenderTargetView,

/// Begin a render pass: bind the attachment, set the viewport to it and
/// clear it if a clear color was given.
pub fn begin(opts: Options) Self {
    const at = opts.attachments[0];

    const rtv: ?*api.ID3D11RenderTargetView, const width: usize, const height: usize = switch (at.target) {
        .target => |t| .{ t.rtv, t.width, t.height },
        .texture => |t| .{ t.rtv, t.width, t.height },
    };

    const self: Self = .{ .context = opts.context, .rtv = rtv };
    const view = rtv orelse {
        log.warn("render pass attachment has no render target view; skipping the pass", .{});
        return self;
    };

    if (at.clear_color) |c| {
        opts.context.vtable.ClearRenderTargetView(opts.context, view, &c);
    }

    const views = [_]?*api.ID3D11RenderTargetView{view};
    opts.context.vtable.OMSetRenderTargets(opts.context, 1, &views, null);

    const viewport: api.D3D11_VIEWPORT = .{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(width),
        .Height = @floatFromInt(height),
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    opts.context.vtable.RSSetViewports(opts.context, 1, @ptrCast(&viewport));

    return self;
}

/// Add a step to this render pass. Nothing is drawn until the pipelines
/// carry shaders; the pass then consists of its clear alone.
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    if (self.rtv == null) return;
    if (!s.pipeline.ready) return;
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    _ = self;
}
