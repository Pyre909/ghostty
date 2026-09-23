//! A render pipeline: the shader pair, input layout and fixed state one
//! draw step uses.
//!
//! The skeleton compiles no shaders, so a pipeline is only its fixed-state
//! description and `ready` stays false; render steps skip it.
const Self = @This();

const std = @import("std");

const api = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *api.ID3D11Device,

    /// The render target format the pipeline draws into.
    format: api.DXGI_FORMAT,

    /// How the vertex buffer advances.
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        per_vertex,
        per_instance,
    };
};

blending_enabled: bool,

/// True once the pipeline holds shaders and can be drawn with.
ready: bool = false,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    _ = VertexAttributes;
    return .{ .blending_enabled = opts.blending_enabled };
}

pub fn deinit(self: *const Self) void {
    _ = self;
}
