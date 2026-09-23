//! A 2D texture with the views its binding needs: a shader resource view
//! to sample it, a render target view to draw into it.
//!
//! A plain copyable value: the generic renderer swaps custom-shader
//! textures with `std.mem.swap` and stores them in image unions.
const Self = @This();

const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

const api = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *api.ID3D11Device,
    context: *api.ID3D11DeviceContext,
    format: api.DXGI_FORMAT,
    bind: Bind = .{},

    pub const Bind = struct {
        shader_resource: bool = true,
        render_target: bool = false,
    };
};

pub const Error = error{
    /// A Direct3D 11 call failed.
    D3D11Failed,
};

texture: *api.ID3D11Texture2D,
srv: ?*api.ID3D11ShaderResourceView,
rtv: ?*api.ID3D11RenderTargetView,

/// Needed to replace regions after creation.
context: *api.ID3D11DeviceContext,

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

/// Bytes per pixel for this texture.
bpp: usize,

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const bpp = bppOf(opts.format);

    var bind_flags: api.UINT = 0;
    if (opts.bind.shader_resource) bind_flags |= api.D3D11_BIND_SHADER_RESOURCE;
    if (opts.bind.render_target) bind_flags |= api.D3D11_BIND_RENDER_TARGET;

    const desc: api.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(width),
        .Height = @intCast(height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = bind_flags,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
    };

    const init_data: ?api.D3D11_SUBRESOURCE_DATA = if (data) |d| init: {
        assert(d.len == width * height * bpp);
        break :init .{
            .pSysMem = d.ptr,
            .SysMemPitch = @intCast(width * bpp),
            .SysMemSlicePitch = 0,
        };
    } else null;

    var texture_ptr: ?*api.ID3D11Texture2D = null;
    var hr = opts.device.vtable.CreateTexture2D(
        opts.device,
        &desc,
        if (init_data) |*d| d else null,
        &texture_ptr,
    );
    if (api.failed(hr)) {
        log.err("CreateTexture2D {d}x{d} format={d} failed hr=0x{x}", .{
            width,
            height,
            @intFromEnum(opts.format),
            @as(u32, @bitCast(hr)),
        });
        return error.D3D11Failed;
    }
    const texture = texture_ptr orelse return error.D3D11Failed;
    errdefer api.release(texture);

    var srv: ?*api.ID3D11ShaderResourceView = null;
    if (opts.bind.shader_resource) {
        hr = opts.device.vtable.CreateShaderResourceView(opts.device, texture.resource(), null, &srv);
        if (api.failed(hr)) {
            log.err("CreateShaderResourceView failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.D3D11Failed;
        }
    }
    errdefer if (srv) |v| api.release(v);

    var rtv: ?*api.ID3D11RenderTargetView = null;
    if (opts.bind.render_target) {
        hr = opts.device.vtable.CreateRenderTargetView(opts.device, texture.resource(), null, &rtv);
        if (api.failed(hr)) {
            log.err("CreateRenderTargetView failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.D3D11Failed;
        }
    }

    return .{
        .texture = texture,
        .srv = srv,
        .rtv = rtv,
        .context = opts.context,
        .width = width,
        .height = height,
        .bpp = bpp,
    };
}

pub fn deinit(self: Self) void {
    if (self.rtv) |v| api.release(v);
    if (self.srv) |v| api.release(v);
    api.release(self.texture);
}

/// Replace a region of the texture with the provided data.
///
/// Does NOT check the dimensions of the data to ensure correctness.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) error{}!void {
    const box: api.D3D11_BOX = .{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
        .back = 1,
    };
    self.context.vtable.UpdateSubresource(
        self.context,
        self.texture.resource(),
        0,
        &box,
        data.ptr,
        @intCast(self.bpp * width),
        0,
    );
}

/// Bytes per pixel of the formats this backend creates textures in.
fn bppOf(format: api.DXGI_FORMAT) usize {
    return switch (format) {
        .R8_UNORM, .R8_UINT => 1,
        .R8G8B8A8_UNORM,
        .R8G8B8A8_UNORM_SRGB,
        .B8G8R8A8_UNORM,
        .B8G8R8A8_UNORM_SRGB,
        .B8G8R8A8_TYPELESS,
        => 4,
        else => @panic("pixel format size unknown for a Direct3D 11 texture"),
    };
}
