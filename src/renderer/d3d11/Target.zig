//! A render target: an offscreen texture with a render target view.
//!
//! It is copied to the swap chain's back buffer when presented. It cannot
//! be the back buffer itself, because the generic renderer creates the new
//! target before it drops the old one on resize.
const Self = @This();

const std = @import("std");

const api = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *api.ID3D11Device,
    format: api.DXGI_FORMAT,
    width: usize,
    height: usize,
};

texture: *api.ID3D11Texture2D,
rtv: *api.ID3D11RenderTargetView,
format: api.DXGI_FORMAT,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const desc: api.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(opts.width),
        .Height = @intCast(opts.height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = api.D3D11_BIND_RENDER_TARGET,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
    };

    var texture_ptr: ?*api.ID3D11Texture2D = null;
    var hr = opts.device.vtable.CreateTexture2D(opts.device, &desc, null, &texture_ptr);
    if (api.failed(hr)) {
        log.err("CreateTexture2D for a {d}x{d} target failed hr=0x{x}", .{
            opts.width,
            opts.height,
            @as(u32, @bitCast(hr)),
        });
        return error.D3D11Failed;
    }
    const texture = texture_ptr orelse return error.D3D11Failed;
    errdefer api.release(texture);

    var rtv_ptr: ?*api.ID3D11RenderTargetView = null;
    hr = opts.device.vtable.CreateRenderTargetView(opts.device, texture.resource(), null, &rtv_ptr);
    if (api.failed(hr)) {
        log.err("CreateRenderTargetView failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.D3D11Failed;
    }
    const rtv = rtv_ptr orelse return error.D3D11Failed;

    return .{
        .texture = texture,
        .rtv = rtv,
        .format = opts.format,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    api.release(self.rtv);
    api.release(self.texture);
}
