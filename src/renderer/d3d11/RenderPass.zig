//! A render pass: one color attachment, cleared when asked, and the draw
//! steps into it.
//!
//! Device context state persists across steps within a pass on purpose: the
//! image step passes no uniforms and reads the ones the background step
//! bound, exactly as on Metal and OpenGL.
//!
//! Register conventions, shared with every HLSL shader: the vertex buffer
//! is input-assembler slot 0; the uniforms are constant buffer b1; textures
//! are t0, t1, ... with their samplers at s0, s1, ...; storage buffers
//! (`buffers[1..]` of a step) are t8, t9, .... Buffers, textures and
//! samplers are bound to both the vertex and the pixel stage, as Metal binds
//! them to both stages.
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

/// The first t register of the storage buffers.
pub const storage_register_base: api.UINT = 8;

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

    fn topology(self: Primitive) api.D3D11_PRIMITIVE_TOPOLOGY {
        return switch (self) {
            .triangle => .TRIANGLELIST,
            .triangle_strip => .TRIANGLESTRIP,
        };
    }
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

/// Add a step to this render pass. A pipeline without shaders is skipped.
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    if (self.rtv == null) return;
    if (!s.pipeline.ready) return;

    const ctx = self.context;
    const vt = ctx.vtable;

    vt.IASetInputLayout(ctx, s.pipeline.input_layout);
    vt.VSSetShader(ctx, s.pipeline.vs, null, 0);
    vt.PSSetShader(ctx, s.pipeline.ps, null, 0);

    if (s.buffers.len > 0) {
        // Index 0 is the vertex buffer, as on the other backends.
        if (s.buffers[0]) |h| {
            const buffers = [_]?*api.ID3D11Buffer{h.buffer};
            const strides = [_]api.UINT{s.pipeline.stride};
            const offsets = [_]api.UINT{0};
            vt.IASetVertexBuffers(ctx, 0, 1, &buffers, &strides, &offsets);
        }

        // The rest are storage buffers, read through their views.
        for (s.buffers[1..], 0..) |b, i| if (b) |h| {
            const views = [_]?*api.ID3D11ShaderResourceView{h.srv};
            const slot: api.UINT = storage_register_base + @as(api.UINT, @intCast(i));
            vt.VSSetShaderResources(ctx, slot, 1, &views);
            vt.PSSetShaderResources(ctx, slot, 1, &views);
        };
    }

    if (s.uniforms) |h| {
        const buffers = [_]?*api.ID3D11Buffer{h.buffer};
        vt.VSSetConstantBuffers(ctx, 1, 1, &buffers);
        vt.PSSetConstantBuffers(ctx, 1, 1, &buffers);
    }

    for (s.textures, 0..) |t, i| if (t) |tex| {
        const views = [_]?*api.ID3D11ShaderResourceView{tex.srv};
        const slot: api.UINT = @intCast(i);
        vt.VSSetShaderResources(ctx, slot, 1, &views);
        vt.PSSetShaderResources(ctx, slot, 1, &views);
    };

    for (s.samplers, 0..) |smp, i| if (smp) |sampler| {
        const samplers = [_]?*api.ID3D11SamplerState{sampler.sampler};
        const slot: api.UINT = @intCast(i);
        vt.VSSetSamplers(ctx, slot, 1, &samplers);
        vt.PSSetSamplers(ctx, slot, 1, &samplers);
    };

    vt.OMSetBlendState(ctx, s.pipeline.blend_state, null, 0xffffffff);
    vt.RSSetState(ctx, s.pipeline.rasterizer_state);
    vt.IASetPrimitiveTopology(ctx, s.draw.type.topology());

    vt.DrawInstanced(
        ctx,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    _ = self;
}
