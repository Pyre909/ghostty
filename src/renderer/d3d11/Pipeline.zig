//! A render pipeline: the shader pair, the input layout and the fixed
//! state one draw step uses.
//!
//! Shaders compile at runtime with D3DCompile from the HLSL source the
//! backend embeds, as the OpenGL backend compiles its GLSL at runtime. A
//! pipeline given no source stays a placeholder: `ready` is false and render
//! steps skip it.
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");

const api = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *api.ID3D11Device,

    /// D3DCompile, resolved by the backend at init.
    compile: api.D3DCompileFn,

    /// The render target format the pipeline draws into.
    format: api.DXGI_FORMAT,

    /// For the logs.
    name: []const u8,

    /// HLSL source of the vertex and pixel shaders, entry point `main`.
    /// Either missing leaves the pipeline a placeholder.
    vertex_source: ?[:0]const u8 = null,
    fragment_source: ?[:0]const u8 = null,

    /// Vertex input elements, when the pipeline reads a vertex buffer.
    input_elements: []const api.D3D11_INPUT_ELEMENT_DESC = &.{},

    /// The stride of that vertex buffer.
    stride: u32 = 0,

    /// Whether to enable blending.
    blending_enabled: bool = true,
};

pub const Error = error{
    ShaderCompileFailed,
    D3D11Failed,
};

vs: ?*api.ID3D11VertexShader = null,
ps: ?*api.ID3D11PixelShader = null,
input_layout: ?*api.ID3D11InputLayout = null,
blend_state: ?*api.ID3D11BlendState = null,
rasterizer_state: ?*api.ID3D11RasterizerState = null,

/// The vertex buffer stride, 0 when the pipeline reads none.
stride: u32 = 0,

blending_enabled: bool,

/// True once the pipeline holds shaders and can be drawn with.
ready: bool = false,

pub fn init(opts: Options) Error!Self {
    const vertex_source = opts.vertex_source orelse return .{ .blending_enabled = opts.blending_enabled };
    const fragment_source = opts.fragment_source orelse return .{ .blending_enabled = opts.blending_enabled };

    const device = opts.device;

    const vs_blob = try compileShader(opts.compile, opts.name, vertex_source, "vs_5_0");
    defer api.release(vs_blob);
    const ps_blob = try compileShader(opts.compile, opts.name, fragment_source, "ps_5_0");
    defer api.release(ps_blob);

    const vs_bytes = vs_blob.bytes();
    const ps_bytes = ps_blob.bytes();

    var vs: ?*api.ID3D11VertexShader = null;
    var hr = device.vtable.CreateVertexShader(device, vs_bytes.ptr, vs_bytes.len, null, &vs);
    if (api.failed(hr)) {
        log.err("CreateVertexShader({s}) failed hr=0x{x}", .{ opts.name, @as(u32, @bitCast(hr)) });
        return error.D3D11Failed;
    }
    errdefer if (vs) |s| api.release(s);

    var ps: ?*api.ID3D11PixelShader = null;
    hr = device.vtable.CreatePixelShader(device, ps_bytes.ptr, ps_bytes.len, null, &ps);
    if (api.failed(hr)) {
        log.err("CreatePixelShader({s}) failed hr=0x{x}", .{ opts.name, @as(u32, @bitCast(hr)) });
        return error.D3D11Failed;
    }
    errdefer if (ps) |s| api.release(s);

    // The input layout is validated against the vertex shader's input
    // signature, which is why the bytecode is still needed here.
    var input_layout: ?*api.ID3D11InputLayout = null;
    if (opts.input_elements.len > 0) {
        hr = device.vtable.CreateInputLayout(
            device,
            opts.input_elements.ptr,
            @intCast(opts.input_elements.len),
            vs_bytes.ptr,
            vs_bytes.len,
            &input_layout,
        );
        if (api.failed(hr)) {
            log.err("CreateInputLayout({s}) failed hr=0x{x}", .{ opts.name, @as(u32, @bitCast(hr)) });
            return error.D3D11Failed;
        }
    }
    errdefer if (input_layout) |l| api.release(l);

    // Premultiplied alpha blending, as on the other backends. A null state
    // is the default, which is no blending.
    var blend_state: ?*api.ID3D11BlendState = null;
    if (opts.blending_enabled) {
        var desc: api.D3D11_BLEND_DESC = std.mem.zeroes(api.D3D11_BLEND_DESC);
        desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = .ONE,
            .DestBlend = .INV_SRC_ALPHA,
            .BlendOp = .ADD,
            .SrcBlendAlpha = .ONE,
            .DestBlendAlpha = .INV_SRC_ALPHA,
            .BlendOpAlpha = .ADD,
            .RenderTargetWriteMask = api.D3D11_COLOR_WRITE_ENABLE_ALL,
        };
        hr = device.vtable.CreateBlendState(device, &desc, &blend_state);
        if (api.failed(hr)) {
            log.err("CreateBlendState({s}) failed hr=0x{x}", .{ opts.name, @as(u32, @bitCast(hr)) });
            return error.D3D11Failed;
        }
    }
    errdefer if (blend_state) |s| api.release(s);

    // Both triangle windings draw: the full-screen triangle and the
    // instanced quads are not consistently wound.
    const raster_desc: api.D3D11_RASTERIZER_DESC = .{
        .FillMode = .SOLID,
        .CullMode = .NONE,
        .FrontCounterClockwise = 0,
        .DepthBias = 0,
        .DepthBiasClamp = 0,
        .SlopeScaledDepthBias = 0,
        .DepthClipEnable = 1,
        .ScissorEnable = 0,
        .MultisampleEnable = 0,
        .AntialiasedLineEnable = 0,
    };
    var rasterizer_state: ?*api.ID3D11RasterizerState = null;
    hr = device.vtable.CreateRasterizerState(device, &raster_desc, &rasterizer_state);
    if (api.failed(hr)) {
        log.err("CreateRasterizerState({s}) failed hr=0x{x}", .{ opts.name, @as(u32, @bitCast(hr)) });
        return error.D3D11Failed;
    }

    log.debug("pipeline {s} ready vs={d}B ps={d}B", .{ opts.name, vs_bytes.len, ps_bytes.len });

    return .{
        .vs = vs,
        .ps = ps,
        .input_layout = input_layout,
        .blend_state = blend_state,
        .rasterizer_state = rasterizer_state,
        .stride = opts.stride,
        .blending_enabled = opts.blending_enabled,
        .ready = true,
    };
}

pub fn deinit(self: *const Self) void {
    if (self.rasterizer_state) |s| api.release(s);
    if (self.blend_state) |s| api.release(s);
    if (self.input_layout) |l| api.release(l);
    if (self.ps) |s| api.release(s);
    if (self.vs) |s| api.release(s);
}

/// Compile one shader stage. Debug builds keep the shader debuggable;
/// release builds optimize fully. The compiler's messages go to the log in
/// both cases, as errors when it failed and at debug level otherwise.
fn compileShader(
    compile: api.D3DCompileFn,
    name: []const u8,
    source: [:0]const u8,
    target: [*:0]const u8,
) Error!*api.ID3DBlob {
    const flags: api.UINT = api.D3DCOMPILE_ENABLE_STRICTNESS |
        if (comptime builtin.mode == .Debug)
            api.D3DCOMPILE_DEBUG | api.D3DCOMPILE_SKIP_OPTIMIZATION
        else
            api.D3DCOMPILE_OPTIMIZATION_LEVEL3;

    var shader: ?*api.ID3DBlob = null;
    var messages: ?*api.ID3DBlob = null;
    const hr = compile(
        source.ptr,
        source.len,
        null,
        null,
        null,
        "main",
        target,
        flags,
        0,
        &shader,
        &messages,
    );
    defer if (messages) |m| api.release(m);

    if (api.failed(hr)) {
        if (shader) |s| api.release(s);
        log.err("D3DCompile {s} ({s}) failed hr=0x{x}: {s}", .{
            name,
            std.mem.span(target),
            @as(u32, @bitCast(hr)),
            if (messages) |m| trimMessages(m.bytes()) else "(no compiler output)",
        });
        return error.ShaderCompileFailed;
    }
    if (messages) |m| {
        const text = trimMessages(m.bytes());
        if (text.len > 0) log.debug("D3DCompile {s} ({s}): {s}", .{ name, std.mem.span(target), text });
    }

    return shader orelse error.ShaderCompileFailed;
}

/// The compiler's text is NUL-terminated and ends with a newline.
fn trimMessages(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    return std.mem.trimEnd(u8, text[0..end], "\r\n ");
}
