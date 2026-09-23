//! A sampler state.
const Self = @This();

const std = @import("std");

const api = @import("api.zig");

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    device: *api.ID3D11Device,
    filter: api.D3D11_FILTER,
    /// Applied to every axis.
    address: api.D3D11_TEXTURE_ADDRESS_MODE,
};

pub const Error = error{
    /// A Direct3D 11 call failed.
    D3D11Failed,
};

sampler: *api.ID3D11SamplerState,

pub fn init(opts: Options) Error!Self {
    const desc: api.D3D11_SAMPLER_DESC = .{
        .Filter = opts.filter,
        .AddressU = opts.address,
        .AddressV = opts.address,
        .AddressW = opts.address,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = .NEVER,
        .BorderColor = .{ 0, 0, 0, 0 },
        .MinLOD = 0,
        .MaxLOD = api.D3D11_FLOAT32_MAX,
    };

    var sampler_ptr: ?*api.ID3D11SamplerState = null;
    const hr = opts.device.vtable.CreateSamplerState(opts.device, &desc, &sampler_ptr);
    if (api.failed(hr)) {
        log.err("CreateSamplerState failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.D3D11Failed;
    }

    return .{ .sampler = sampler_ptr orelse return error.D3D11Failed };
}

pub fn deinit(self: Self) void {
    api.release(self.sampler);
}
