//! Graphics API wrapper for Direct3D 11.
//!
//! The Win32 runtime hosts this renderer and hands it one thing, the HWND.
//! The renderer owns the device, the immediate context and a DXGI flip-model
//! swap chain, all created in `init` on the main thread inside
//! `CoreSurface.init`, so a GPU that cannot do this fails surface creation
//! where the failure is visible (opengl/wgl.zig explains why a failure on
//! the render thread is worse than a blank window). Every later call runs on
//! the render thread under the generic renderer's draw mutex, which is what
//! the single-threaded immediate context requires.
//!
//! Frames render into an offscreen target texture and are copied to the
//! back buffer and presented synchronously from `Frame.complete`, as the WGL
//! backend does, so one swap chain slot is enough and nothing is exported.
//! The target cannot be the back buffer itself: on resize the generic
//! renderer creates the new target before it drops the old one.
//!
//! The backend is reachable only with `-Drenderer=d3d11` while it grows
//! toward parity with the WGL path; pipelines not ported yet are skipped by
//! the render pass.
pub const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(D3D11);
const shadertoy = @import("shadertoy.zig");

const api = @import("d3d11/api.zig");

pub const GraphicsAPI = D3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");

/// Custom shaders are not translated for this backend yet, so the target is
/// a placeholder; `shaders.Shaders.init` builds no post pipelines.
pub const custom_shader_target: shadertoy.Target = .glsl;
/// SV_Position is +Y = down, like Metal's fragment position.
pub const custom_shader_y_is_down = true;

/// One slot: presentation is synchronous inside `Frame.complete`, so at
/// most one frame is ever in flight (generic.zig allows a count of 1).
pub const swap_chain_count = 1;

/// Direct3D 11 textures are at most this wide or high.
const max_texture_dimension: u32 = 16384;

const log = std.log.scoped(.d3d11);

const win32 = struct {
    const RECT = extern struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    };

    extern "d3d11" fn D3D11CreateDevice(
        adapter: ?*api.IDXGIAdapter,
        driver_type: api.D3D_DRIVER_TYPE,
        software: ?api.HMODULE,
        flags: api.UINT,
        feature_levels: ?[*]const api.D3D_FEATURE_LEVEL,
        num_feature_levels: api.UINT,
        sdk_version: api.UINT,
        device: ?*?*api.ID3D11Device,
        feature_level: ?*api.D3D_FEATURE_LEVEL,
        context: ?*?*api.ID3D11DeviceContext,
    ) callconv(.winapi) api.HRESULT;

    extern "user32" fn GetClientRect(hwnd: api.HWND, rect: *RECT) callconv(.winapi) api.BOOL;

    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?api.HMODULE;
    extern "kernel32" fn GetProcAddress(module: api.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
};

/// The window this renderer presents to. Borrowed from the apprt, which
/// destroys it only after the renderer is gone.
hwnd: api.HWND,

device: *api.ID3D11Device,
context: *api.ID3D11DeviceContext,
swap_chain: *api.IDXGISwapChain1,

/// The feature level the device came up with.
feature_level: api.D3D_FEATURE_LEVEL,

/// D3DCompile from d3dcompiler_47.dll, which is loaded once per process
/// at init so that a missing compiler fails surface creation rather than
/// the first frame.
compile: api.D3DCompileFn,

/// Bound at s0 when a render pass begins, for the steps that sample a
/// texture without naming a sampler: the image steps.
default_sampler: Sampler,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The size the apprt last reported through the `.resize` message, in
/// pixels. `surfaceSize` answers with it and the swap chain follows it at
/// present time. Zero until the first resize, which the apprt sends right
/// after the surface exists, and zero while the window is minimized.
size: struct { width: u32 = 0, height: u32 = 0 } = .{},

/// Debug-log counters. Only the render thread touches these.
present_count: u64 = 0,
dropped_stale_count: u64 = 0,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !D3D11 {
    comptime switch (builtin.os.tag) {
        .windows => {},
        else => @compileError("unsupported platform for Direct3D 11"),
    };

    _ = alloc;

    const hwnd: api.HWND = switch (apprt.runtime) {
        apprt.windows => opts.rt_surface.hwnd,
        else => @compileError("unsupported apprt for Direct3D 11"),
    };

    const compile = try loadCompiler();

    // BGRA support is required for the B8G8R8A8 swap chain format. The
    // debug layer needs the Graphics Tools optional feature; without it
    // device creation reports the SDK component missing, and the device is
    // created again without the layer.
    var flags: api.UINT = api.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if (comptime builtin.mode == .Debug) flags |= api.D3D11_CREATE_DEVICE_DEBUG;

    // Only 11_0: asking for 11_1 on an 11.0 runtime fails device creation
    // outright instead of falling back.
    const levels = [_]api.D3D_FEATURE_LEVEL{.@"11_0"};

    var device_ptr: ?*api.ID3D11Device = null;
    var context_ptr: ?*api.ID3D11DeviceContext = null;
    var level: api.D3D_FEATURE_LEVEL = undefined;
    var hr = win32.D3D11CreateDevice(
        null,
        .HARDWARE,
        null,
        flags,
        &levels,
        levels.len,
        api.D3D11_SDK_VERSION,
        &device_ptr,
        &level,
        &context_ptr,
    );
    if (hr == api.DXGI_ERROR_SDK_COMPONENT_MISSING and
        flags & api.D3D11_CREATE_DEVICE_DEBUG != 0)
    {
        log.info("D3D11 debug layer unavailable (Graphics Tools not installed); creating the device without it", .{});
        flags &= ~api.D3D11_CREATE_DEVICE_DEBUG;
        hr = win32.D3D11CreateDevice(
            null,
            .HARDWARE,
            null,
            flags,
            &levels,
            levels.len,
            api.D3D11_SDK_VERSION,
            &device_ptr,
            &level,
            &context_ptr,
        );
    }
    if (api.failed(hr)) {
        log.err("D3D11CreateDevice failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.D3D11DeviceFailed;
    }
    const device = device_ptr orelse return error.D3D11DeviceFailed;
    errdefer api.release(device);
    const context = context_ptr orelse return error.D3D11DeviceFailed;
    errdefer api.release(context);

    // The factory that made the adapter that made the device is the one
    // that may create swap chains for it: device -> adapter -> factory.
    const dxgi_device = api.queryInterface(device, api.IDXGIDevice) catch {
        log.err("D3D11 device has no IDXGIDevice interface", .{});
        return error.D3D11DeviceFailed;
    };
    defer api.release(dxgi_device);

    var adapter_ptr: ?*api.IDXGIAdapter = null;
    hr = dxgi_device.vtable.GetAdapter(dxgi_device, &adapter_ptr);
    const adapter = if (api.succeeded(hr)) adapter_ptr else null;
    const adapter_obj = adapter orelse {
        log.err("IDXGIDevice::GetAdapter failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.D3D11DeviceFailed;
    };
    defer api.release(adapter_obj);
    logAdapter(adapter_obj, level);

    const factory = adapter_obj.getParent(api.IDXGIFactory2) catch {
        log.err("adapter has no IDXGIFactory2 parent; DXGI 1.2 is required", .{});
        return error.D3D11DeviceFailed;
    };
    defer api.release(factory);

    // Width and height 0 size the chain to the client area. The format is
    // the same either way: the target texture carries the sRGB view when
    // blending is linear and its bytes are copied over as they are.
    const desc: api.DXGI_SWAP_CHAIN_DESC1 = .{
        .Width = 0,
        .Height = 0,
        .Format = .B8G8R8A8_UNORM,
        .Stereo = 0,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = api.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = .NONE,
        .SwapEffect = .FLIP_DISCARD,
        .AlphaMode = .IGNORE,
        .Flags = 0,
    };
    var swap_chain_ptr: ?*api.IDXGISwapChain1 = null;
    hr = factory.vtable.CreateSwapChainForHwnd(
        factory,
        api.unknown(device),
        hwnd,
        &desc,
        null,
        null,
        &swap_chain_ptr,
    );
    if (api.failed(hr)) {
        log.err("CreateSwapChainForHwnd failed hwnd={x} hr=0x{x}", .{
            @intFromPtr(hwnd),
            @as(u32, @bitCast(hr)),
        });
        return error.D3D11SwapChainFailed;
    }
    const swap_chain = swap_chain_ptr orelse return error.D3D11SwapChainFailed;
    errdefer api.release(swap_chain);

    // DXGI would otherwise watch the window for Alt+Enter and window
    // changes on the app's behalf; the apprt handles those itself.
    hr = factory.makeWindowAssociation(
        hwnd,
        api.DXGI_MWA_NO_ALT_ENTER | api.DXGI_MWA_NO_WINDOW_CHANGES,
    );
    if (api.failed(hr)) {
        log.warn("MakeWindowAssociation failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    // The linear, clamping state the other backends give their image
    // textures.
    const default_sampler = try Sampler.init(.{
        .device = device,
        .filter = .MIN_MAG_MIP_LINEAR,
        .address = .CLAMP,
    });
    errdefer default_sampler.deinit();

    log.info("D3D11 swap chain created hwnd={x} format=B8G8R8A8_UNORM buffers=2 flip_discard", .{
        @intFromPtr(hwnd),
    });

    return .{
        .hwnd = hwnd,
        .device = device,
        .context = context,
        .swap_chain = swap_chain,
        .feature_level = level,
        .compile = compile,
        .default_sampler = default_sampler,
        .blending = opts.config.blending,
    };
}

/// d3dcompiler_47.dll ships with Windows 8.1 and later; loading it by hand
/// rather than linking it keeps its absence an error this function can
/// report. The module is never freed: LoadLibrary counts references, and
/// every surface in the process shares it.
fn loadCompiler() error{D3DCompilerMissing}!api.D3DCompileFn {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll");
    const module = win32.LoadLibraryW(name) orelse {
        log.err("d3dcompiler_47.dll could not be loaded err={}", .{std.os.windows.GetLastError()});
        return error.D3DCompilerMissing;
    };
    const proc = win32.GetProcAddress(module, "D3DCompile") orelse {
        log.err("d3dcompiler_47.dll has no D3DCompile export", .{});
        return error.D3DCompilerMissing;
    };
    return @ptrCast(@alignCast(proc));
}

fn logAdapter(adapter: *api.IDXGIAdapter, level: api.D3D_FEATURE_LEVEL) void {
    var desc: api.DXGI_ADAPTER_DESC = undefined;
    if (api.failed(adapter.vtable.GetDesc(adapter, &desc))) {
        log.info("D3D11 device feature_level=0x{x} (adapter description unavailable)", .{@intFromEnum(level)});
        return;
    }
    const len = std.mem.indexOfScalar(u16, &desc.Description, 0) orelse desc.Description.len;
    var name_buf: [desc.Description.len * 3]u8 = undefined;
    const name: []const u8 = if (std.unicode.utf16LeToUtf8(&name_buf, desc.Description[0..len])) |n|
        name_buf[0..n]
    else |_|
        "(undecodable)";
    log.info("D3D11 adapter={s} vendor=0x{x} device=0x{x} feature_level=0x{x} dedicated_vram={d}MiB", .{
        name,
        desc.VendorId,
        desc.DeviceId,
        @intFromEnum(level),
        desc.DedicatedVideoMemory / (1024 * 1024),
    });
}

/// Main thread, after the render thread has been joined and has released
/// every GPU resource. The swap chain goes before the context and device;
/// nothing else references the back buffer at this point.
pub fn deinit(self: *D3D11) void {
    self.context.vtable.ClearState(self.context);
    self.context.vtable.Flush(self.context);
    self.default_sampler.deinit();
    api.release(self.swap_chain);
    api.release(self.context);
    api.release(self.device);
}

/// Nothing to bracket a frame with; kept for the contract.
pub fn drawFrameStart(self: *D3D11) void {
    _ = self;
}

pub fn drawFrameEnd(self: *D3D11) void {
    _ = self;
}

/// The `.resize` message is the only way the apprt's size reaches this
/// backend, so it is cached here and answered by `surfaceSize`. Reading the
/// client rectangle from the render thread would race the window state the
/// main thread is changing.
pub fn setViewport(self: *D3D11, width: u32, height: u32) void {
    self.size = .{ .width = width, .height = height };
}

pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    return .{
        .width = @min(self.size.width, max_texture_dimension),
        .height = @min(self.size.height, max_texture_dimension),
    };
}

pub fn initShaders(
    self: *const D3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.device,
        self.compile,
        custom_shaders,
        self.targetFormat(),
    );
}

/// An `_SRGB` render target view makes the GPU gamma encode after
/// blending, which is what linear alpha blending needs; the bytes it stores
/// are then presented as they are.
fn targetFormat(self: *const D3D11) api.DXGI_FORMAT {
    return if (self.blending.isLinear())
        .B8G8R8A8_UNORM_SRGB
    else
        .B8G8R8A8_UNORM;
}

pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device,
        .format = self.targetFormat(),
        .width = width,
        .height = height,
    });
}

pub const PresentError = error{
    /// The device was removed or reset; the frame is unhealthy.
    DeviceLost,
    /// Any other failure. The frame itself was fine.
    PresentFailed,
};

/// Copy a finished target to the back buffer and present it. Render
/// thread, from `Frame.complete`.
///
/// Frames rendered at a size the client area no longer has are dropped, as
/// Metal and WGL do: during a drag the client rectangle runs ahead of the
/// renderer's `.resize` message, and stretching the old frame would show a
/// smeared grid. The WM_SIZE that made the sizes differ already queued a
/// `.resize` and a wakeup, so a matching frame follows. GetClientRect only
/// reads window state, so it is safe from this thread while the main thread
/// sits in a modal size loop.
///
/// The swap chain follows the target's size here rather than in
/// `setViewport`, so every reference to a back buffer lives inside this
/// function and ResizeBuffers never finds one outstanding.
pub fn present(self: *D3D11, target: Target) PresentError!void {
    var rc: win32.RECT = undefined;
    if (win32.GetClientRect(self.hwnd, &rc) != 0) {
        const cw: i64 = rc.right - rc.left;
        const ch: i64 = rc.bottom - rc.top;
        if (cw != @as(i64, @intCast(target.width)) or
            ch != @as(i64, @intCast(target.height)))
        {
            self.dropped_stale_count += 1;
            log.debug(
                "present hwnd={x}: dropped stale {d}x{d} frame, client is {d}x{d} (dropped={d})",
                .{
                    @intFromPtr(self.hwnd),
                    target.width,
                    target.height,
                    cw,
                    ch,
                    self.dropped_stale_count,
                },
            );
            return;
        }
    }

    const w: api.UINT = @intCast(target.width);
    const h: api.UINT = @intCast(target.height);

    var desc: api.DXGI_SWAP_CHAIN_DESC1 = undefined;
    if (api.succeeded(self.swap_chain.getDesc1(&desc)) and
        (desc.Width != w or desc.Height != h))
    {
        // The pipeline state may still name the previous back buffer's
        // views; the pass that follows binds its own.
        self.context.vtable.ClearState(self.context);
        const hr = self.swap_chain.resizeBuffers(0, w, h, .UNKNOWN, desc.Flags);
        if (api.failed(hr)) {
            log.warn("ResizeBuffers to {d}x{d} failed hr=0x{x}", .{ w, h, @as(u32, @bitCast(hr)) });
            return self.presentError(hr);
        }
        log.debug("swap chain resized to {d}x{d}", .{ w, h });
    }

    const back = self.swap_chain.getBuffer(0, api.ID3D11Texture2D) catch {
        log.warn("swap chain back buffer unavailable", .{});
        return error.PresentFailed;
    };
    defer api.release(back);

    // A whole-resource copy between two B8G8R8A8 textures; the sRGB view
    // on the target changes nothing about the bytes.
    self.context.vtable.CopyResource(self.context, back.resource(), target.texture.resource());

    const hr = self.swap_chain.present(1, 0);
    self.present_count += 1;
    if (self.present_count == 1) {
        log.info("first present hwnd={x} {d}x{d}", .{ @intFromPtr(self.hwnd), w, h });
    }
    if (api.failed(hr)) {
        log.warn("Present failed hwnd={x} hr=0x{x}", .{ @intFromPtr(self.hwnd), @as(u32, @bitCast(hr)) });
        return self.presentError(hr);
    }
    log.debug("present #{d} hwnd={x} {d}x{d} dropped_stale={d}", .{
        self.present_count,
        @intFromPtr(self.hwnd),
        w,
        h,
        self.dropped_stale_count,
    });
}

fn presentError(self: *D3D11, hr: api.HRESULT) PresentError {
    if (hr == api.DXGI_ERROR_DEVICE_REMOVED or hr == api.DXGI_ERROR_DEVICE_RESET) {
        const reason = self.device.vtable.GetDeviceRemovedReason(self.device);
        log.err("D3D11 device lost hr=0x{x} reason=0x{x}", .{
            @as(u32, @bitCast(hr)),
            @as(u32, @bitCast(reason)),
        });
        return error.DeviceLost;
    }
    return error.PresentFailed;
}

fn bufferOptions(self: D3D11, kind: bufferpkg.Kind) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .kind = kind,
    };
}

/// Uniforms are a constant buffer.
pub fn uniformBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions(.constant);
}

/// Cell text is the instance buffer of the text pipeline.
pub fn fgBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

/// Cell backgrounds are read as a structured buffer by every cell pipeline.
pub fn bgBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions(.structured);
}

pub fn bgImageBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

pub fn imageBufferOptions(self: D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

pub const instanceBufferOptions = fgBufferOptions;

/// Options for the custom-shader textures, which are both render targets
/// and sampled inputs.
pub fn textureOptions(self: D3D11) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .format = self.targetFormat(),
        .bind = .{ .shader_resource = true, .render_target = true },
    };
}

/// Matches Shadertoy's sampling.
pub fn samplerOptions(self: D3D11) Sampler.Options {
    return .{
        .device = self.device,
        .filter = .MIN_MAG_MIP_LINEAR,
        .address = .CLAMP,
    };
}

pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    /// DXGI has no sRGB single-channel format, so gray ignores `srgb`.
    fn toDxgi(self: ImageTextureFormat, srgb: bool) api.DXGI_FORMAT {
        return switch (self) {
            .gray => .R8_UNORM,
            .rgba => if (srgb) .R8G8B8A8_UNORM_SRGB else .R8G8B8A8_UNORM,
            .bgra => if (srgb) .B8G8R8A8_UNORM_SRGB else .B8G8R8A8_UNORM,
        };
    }
};

pub fn imageTextureOptions(
    self: D3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .format = format.toDxgi(srgb),
        .bind = .{ .shader_resource = true },
    };
}

pub fn initAtlasTexture(
    self: *const D3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: api.DXGI_FORMAT = switch (atlas.format) {
        .grayscale => .R8_UNORM,
        .bgra => .B8G8R8A8_UNORM_SRGB,
        else => @panic("unsupported atlas format for Direct3D 11 texture"),
    };

    return try Texture.init(
        .{
            .device = self.device,
            .context = self.context,
            .format = format,
            .bind = .{ .shader_resource = true },
        },
        atlas.size,
        atlas.size,
        null,
    );
}

pub fn beginFrame(
    self: *const D3D11,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    return try Frame.begin(.{
        .context = self.context,
        .default_sampler = self.default_sampler.sampler,
    }, renderer, target);
}
