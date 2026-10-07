//! Graphics API wrapper for Direct3D 11.
//!
//! The Win32 runtime, or a host embedding libghostty through its Windows
//! platform, hands this renderer one thing, the HWND.
//! The renderer owns the device, the immediate context and a DXGI flip-model
//! swap chain, all created in `init` on the main thread inside
//! `CoreSurface.init`, so a GPU that cannot do this fails surface creation
//! where the failure is visible, rather than on the render thread, where it
//! would leave the window blank. Every later call runs under the generic
//! renderer's draw mutex, which is what the single-threaded immediate
//! context requires: usually on the render thread, but a frame can also be
//! drawn from the apprt's or host's thread through `Surface.draw`
//! (ghostty_surface_draw), which renderers must allow.
//!
//! Frames render into an offscreen target texture and are copied to the
//! back buffer and presented synchronously from `Frame.complete`, so one
//! swap chain slot is enough and nothing is exported.
//! The target cannot be the back buffer itself: on resize the generic
//! renderer creates the new target before it drops the old one.
//!
//! A lost device (a GPU reset, a driver update) is reported by Present and
//! latched. The generic renderer then releases what it created on the
//! device and `recoverDevice` creates a new one for the same window, after
//! which everything is rebuilt lazily, as after an unrealize.
//!
//! This is the Windows renderer: every pipeline the other backends draw is
//! here, custom shaders included.
pub const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(D3D11);
const shadertoy = @import("shadertoy.zig");

const api = @import("d3d11/api.zig");

pub const GraphicsAPI = D3D11;
pub const Device = @import("d3d11/Device.zig");
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");

/// Custom shaders arrive as HLSL from shadertoy.zig and compile like the
/// built-in ones; `shaders.Shaders.init` builds one post pipeline each.
pub const custom_shader_target: shadertoy.Target = .hlsl;
/// SV_Position is +Y = down, like Metal's fragment position.
pub const custom_shader_y_is_down = true;

/// One slot: presentation is synchronous inside `Frame.complete`, so at
/// most one frame is ever in flight (generic.zig allows a count of 1).
pub const swap_chain_count = 1;

/// Direct3D 11 textures are at most this wide or high.
const max_texture_dimension: u32 = 16384;

/// Frames to let pass between recovery attempts after one failed, so a
/// GPU that stays gone is not asked for a device on every wakeup.
const recovery_backoff_frames: u8 = 16;

/// Stale frames dropped in a row before `present` warns that the window's
/// size is not being reported. A drag drops a few at a time, each followed
/// by a matching frame; this many in a row means no resize is coming.
const stale_warn_after: u32 = 120;

const log = std.log.scoped(.d3d11);

const win32 = struct {
    const RECT = internal_os.windows.RECT;
    const GetClientRect = internal_os.windows.exp.user32.GetClientRect;

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
};

/// The window this renderer presents to. Borrowed from the apprt or the
/// embedding host, which destroys it only after the renderer is gone.
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

/// Present parameters: the sync interval and the flags. `window-vsync =
/// false` presents with interval 0, and with tearing allowed when DXGI
/// reports support, so the frame rate is not tied to the display.
sync_interval: api.UINT,
present_flags: api.UINT,

/// The debug layer's message queue, Debug builds only; its messages go to
/// the log after every present.
info_queue: ?*api.ID3D11InfoQueue = null,

/// Set once the device was lost. Later frames are refused without
/// touching the device until `recoverDevice` replaces it.
lost: bool = false,

/// Whether `window-vsync` is on, kept so that `recoverDevice` creates the
/// new swap chain with the same presentation choice.
vsync: bool,

/// Set while the GPU objects are released: after `deinit`, and after a
/// recovery attempt that could not create a replacement device. The
/// release is skipped then, and the next attempt goes straight to
/// creating.
released: bool = false,

/// Frames still to wait before the next recovery attempt.
recovery_backoff: u8 = 0,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The size the apprt last reported through the `.resize` message, in
/// pixels. `surfaceSize` answers with it and the swap chain follows it at
/// present time. Zero until the first resize, which the apprt sends right
/// after the surface exists. A minimize does not change it: the apprt
/// reports occlusion instead, and no frame is drawn while invisible.
size: struct { width: u32 = 0, height: u32 = 0 } = .{},

/// Frames presented, for the first-present log. Guarded by the generic
/// renderer's draw mutex, like everything `present` touches.
present_count: u64 = 0,

/// Stale frames dropped in a row (see `present`). Guarded by the draw
/// mutex.
stale: StaleFrames = .{},

/// Counts stale frames dropped in a row so that `present` can warn, once,
/// about a window whose size is not being reported.
const StaleFrames = struct {
    streak: u32 = 0,
    warned: bool = false,

    /// What `present` does with a frame.
    const Verdict = enum { present, drop, drop_warn };

    /// Decide what `present` does with a frame rendered at `target_w` by
    /// `target_h` for a client area of `client_w` by `client_h`, and count
    /// it. The client size is clamped as `surfaceSize` clamps, so that a
    /// client area larger than a texture can be still matches the target
    /// drawn for it.
    fn frame(
        self: *StaleFrames,
        client_w: i64,
        client_h: i64,
        target_w: i64,
        target_h: i64,
    ) Verdict {
        const cw: i64 = @min(client_w, max_texture_dimension);
        const ch: i64 = @min(client_h, max_texture_dimension);
        if (cw == target_w and ch == target_h) {
            self.presented();
            return .present;
        }
        return if (self.drop(cw, ch)) .drop_warn else .drop;
    }

    /// Count a frame dropped for a client area of `width` by `height`, and
    /// return true if this drop is the one to warn about. The host reports
    /// only nonzero sizes (see ghostty_platform_windows_s), so a client
    /// area collapsed to zero width or height is not a missing report: the
    /// host owes occlusion or a refresh there instead, not a size. Like a
    /// zero-size surface in the generic renderer's drawFrameLocked, it is
    /// not an error, and it ends the streak.
    fn drop(self: *StaleFrames, width: i64, height: i64) bool {
        if (width == 0 or height == 0) {
            self.streak = 0;
            return false;
        }

        self.streak +|= 1;
        if (self.streak != stale_warn_after or self.warned) return false;
        self.warned = true;
        return true;
    }

    /// A frame was presented, which ends the streak: a drag drops a few
    /// frames at a time, each run followed by a matching frame.
    fn presented(self: *StaleFrames) void {
        self.streak = 0;
    }
};

/// The device is the app's, which holds nothing for Direct3D 11, see
/// `Device`: the renderer creates its own device for its window.
pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !D3D11 {
    comptime switch (builtin.os.tag) {
        .windows => {},
        else => @compileError("unsupported platform for Direct3D 11"),
    };

    _ = alloc;
    _ = device;

    const hwnd: api.HWND = switch (apprt.runtime) {
        apprt.windows => opts.rt_surface.hwnd,
        apprt.embedded => switch (opts.rt_surface.platform) {
            .windows => |v| v.hwnd,
            // Platform.init refuses these tags on Windows.
            .macos, .ios => unreachable,
        },
        else => @compileError("unsupported apprt for Direct3D 11"),
    };

    const compile = try loadCompiler();

    var self: D3D11 = .{
        .hwnd = hwnd,
        .compile = compile,
        .vsync = opts.config.vsync,
        .blending = opts.config.blending,
        // Set by adopt.
        .device = undefined,
        .context = undefined,
        .swap_chain = undefined,
        .feature_level = undefined,
        .default_sampler = undefined,
        .sync_interval = undefined,
        .present_flags = undefined,
    };
    self.adopt(try createGpu(hwnd, opts.config.vsync));
    return self;
}

/// The objects that live and die with one device. `init` creates them,
/// and `recoverDevice` creates them again after the device was lost.
const Gpu = struct {
    device: *api.ID3D11Device,
    context: *api.ID3D11DeviceContext,
    swap_chain: *api.IDXGISwapChain1,
    feature_level: api.D3D_FEATURE_LEVEL,
    default_sampler: Sampler,
    sync_interval: api.UINT,
    present_flags: api.UINT,
    info_queue: ?*api.ID3D11InfoQueue,
};

fn adopt(self: *D3D11, gpu: Gpu) void {
    self.device = gpu.device;
    self.context = gpu.context;
    self.swap_chain = gpu.swap_chain;
    self.feature_level = gpu.feature_level;
    self.default_sampler = gpu.default_sampler;
    self.sync_interval = gpu.sync_interval;
    self.present_flags = gpu.present_flags;
    self.info_queue = gpu.info_queue;
    self.released = false;
}

/// Create the device, its immediate context and a swap chain for the
/// window, plus the sampler and debug queue that go with them.
fn createGpu(hwnd: api.HWND, vsync: bool) !Gpu {
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
    // A driver that stops short of feature level 11_0, or no adapter at
    // all: WARP, the software rasterizer every supported Windows ships,
    // does 11_0. Slow, but a terminal is drawn rather than no window, and
    // the adapter line below then names the Microsoft Basic Render Driver.
    if (api.failed(hr)) {
        log.warn("D3D11CreateDevice on the hardware adapter failed hr=0x{x}; trying WARP", .{@as(u32, @bitCast(hr))});
        hr = win32.D3D11CreateDevice(
            null,
            .WARP,
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

    // The debug layer queues its messages; drainDebugMessages logs them.
    const info_queue: ?*api.ID3D11InfoQueue = if (flags & api.D3D11_CREATE_DEVICE_DEBUG != 0)
        api.queryInterface(device, api.ID3D11InfoQueue) catch null
    else
        null;
    errdefer if (info_queue) |q| api.release(q);

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

    // `window-vsync = false` presents without waiting for a vblank. In
    // windowed flip model only tearing unlocks the rate, and DXGI must
    // be asked whether it can tear; without it interval 0 still presents
    // as soon as the queue has room.
    const sync_interval: api.UINT = if (vsync) 1 else 0;
    var swap_chain_flags: api.UINT = 0;
    var present_flags: api.UINT = 0;
    if (!vsync) tearing: {
        const factory5 = api.queryInterface(factory, api.IDXGIFactory5) catch break :tearing;
        defer api.release(factory5);
        var allow: api.BOOL = 0;
        const check = factory5.vtable.CheckFeatureSupport(
            factory5,
            .PRESENT_ALLOW_TEARING,
            @ptrCast(&allow),
            @sizeOf(api.BOOL),
        );
        if (api.failed(check) or allow == 0) break :tearing;
        swap_chain_flags |= api.DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;
        present_flags |= api.DXGI_PRESENT_ALLOW_TEARING;
    }

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
        .Flags = swap_chain_flags,
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
    // changes on the app's behalf; the apprt or the host handles those.
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

    log.info("D3D11 swap chain created hwnd={x} format=B8G8R8A8_UNORM buffers=2 flip_discard sync_interval={d} tearing={}", .{
        @intFromPtr(hwnd),
        sync_interval,
        present_flags & api.DXGI_PRESENT_ALLOW_TEARING != 0,
    });

    return .{
        .device = device,
        .context = context,
        .swap_chain = swap_chain,
        .feature_level = level,
        .default_sampler = default_sampler,
        .sync_interval = sync_interval,
        .present_flags = present_flags,
        .info_queue = info_queue,
    };
}

/// d3dcompiler_47.dll is loaded by hand rather than linked so that its
/// absence is an error this function can report. It is searched for in
/// System32 only, with its dependencies: it is not a KnownDLL, so a bare
/// name would search the application directory first, and in an embedding
/// host that is the host's directory. A module of that name the process
/// already loaded is used as it is, wherever it came from; a WinUI 3 host
/// loads one before the first surface (see ghostty_platform_windows_s in
/// ghostty.h). The module is never freed: LoadLibrary counts references,
/// and every surface in the process shares it.
fn loadCompiler() error{D3DCompilerMissing}!api.D3DCompileFn {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll");
    const module = internal_os.windows.exp.kernel32.LoadLibraryExW(
        name,
        null,
        internal_os.windows.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse {
        log.err("d3dcompiler_47.dll could not be loaded err={}", .{std.os.windows.GetLastError()});
        return error.D3DCompilerMissing;
    };
    const proc = internal_os.windows.exp.kernel32.GetProcAddress(module, "D3DCompile") orelse {
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
/// every GPU resource.
pub fn deinit(self: *D3D11) void {
    self.releaseGpu();
}

/// Release the device and everything created with it. The swap chain goes
/// before the context and device; nothing else references the back buffer
/// at this point. Nothing to do when a failed recovery already released
/// them.
fn releaseGpu(self: *D3D11) void {
    if (self.released) return;
    self.released = true;
    self.context.vtable.ClearState(self.context);
    self.context.vtable.Flush(self.context);
    self.default_sampler.deinit();
    api.release(self.swap_chain);
    api.release(self.context);
    if (self.info_queue) |q| api.release(q);
    api.release(self.device);
}

/// Whether the device was lost since the last frame. The generic renderer
/// asks at the start of every frame and, when so, releases everything it
/// created on the device before calling `recoverDevice`.
pub fn deviceLost(self: *const D3D11) bool {
    return self.lost;
}

/// Replace a lost device: release it with everything created on it, and
/// create them again for the same window. Under the draw mutex, on the
/// thread drawing the frame, after the generic renderer released its own
/// resources. On failure the device stays lost, the caller draws nothing,
/// and a later frame tries again once the backoff has passed.
pub fn recoverDevice(self: *D3D11) !void {
    assert(self.lost);
    self.releaseGpu();
    if (self.recovery_backoff > 0) {
        self.recovery_backoff -= 1;
        return error.DeviceLost;
    }
    const gpu = createGpu(self.hwnd, self.vsync) catch |err| {
        self.recovery_backoff = recovery_backoff_frames;
        log.err("D3D11 device recovery failed err={}; retrying later", .{err});
        return err;
    };
    self.adopt(gpu);
    self.lost = false;
    log.info("D3D11 device recovered hwnd={x}", .{@intFromPtr(self.hwnd)});
}

/// Nothing to bracket a frame with; kept for the contract.
pub fn drawFrameStart(self: *D3D11) void {
    _ = self;
}

pub fn drawFrameEnd(self: *D3D11) void {
    _ = self;
}

/// The `.resize` message is the only way the apprt's size reaches this
/// backend, so it is cached here and answered by `surfaceSize`. Sizing
/// frames from the client rectangle instead would let a frame disagree with
/// the grid the core laid out for the last `.resize`; `present` reads it only
/// to drop frames that no longer match.
pub fn setViewport(self: *D3D11, width: u32, height: u32) void {
    self.size = .{ .width = width, .height = height };
}

/// The cached `.resize` size, except that a client area collapsed to zero
/// width or height answers 0x0 so the generic renderer skips the frame
/// before any work, as Metal does by reading its layer's bounds. Zero-size
/// reports never arrive as a `.resize` (they would reflow the grid), so the
/// collapse is read live; like `present`, this runs under the draw mutex on
/// whichever thread draws, and GetClientRect only reads window state.
pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    var rc: win32.RECT = undefined;
    if (win32.GetClientRect(self.hwnd, &rc).toBool() and
        (rc.right <= rc.left or rc.bottom <= rc.top))
    {
        return .{ .width = 0, .height = 0 };
    }
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

/// Copy a finished target to the back buffer and present it, from
/// `Frame.complete` under the draw mutex: usually on the render thread,
/// but on the apprt's or host's thread when it draws through
/// `Surface.draw`.
///
/// Frames rendered at a size the client area no longer has are dropped, as
/// Metal does: during a drag the client rectangle runs ahead of the
/// renderer's `.resize` message, and stretching the old frame would show a
/// smeared grid. Under the Win32 runtime the WM_SIZE that made the sizes
/// differ already queued a `.resize` and a wakeup, so a matching frame
/// follows. Under the embedded runtime nothing in ghostty sees WM_SIZE: the
/// host must report the new size with ghostty_surface_set_size, and if it
/// never does every frame is dropped, so a long run of drops is logged once
/// as a warning. A client area of zero width or height needs no report, so
/// its drops do not count toward that run. `StaleFrames.frame` makes these
/// calls. GetClientRect only reads window state, so it is safe from
/// whichever thread draws, including while the window's thread sits in a
/// modal size loop.
///
/// The swap chain follows the target's size here rather than in
/// `setViewport`, so every reference to a back buffer lives inside this
/// function and ResizeBuffers never finds one outstanding.
pub fn present(self: *D3D11, target: Target) PresentError!void {
    if (self.lost) return error.DeviceLost;

    // Targets are at most max_texture_dimension on a side. A client area
    // that cannot be read is taken to match the target.
    const tw: i64 = @intCast(target.width);
    const th: i64 = @intCast(target.height);
    var rc: win32.RECT = undefined;
    const cw: i64, const ch: i64 = if (win32.GetClientRect(self.hwnd, &rc).toBool())
        .{ rc.right - rc.left, rc.bottom - rc.top }
    else
        .{ tw, th };
    switch (self.stale.frame(cw, ch, tw, th)) {
        .present => {},
        .drop => return,
        .drop_warn => {
            log.warn(
                "present hwnd={x}: {d} frames in a row rendered at {d}x{d} for a {d}x{d} client area were dropped; an embedding host must report the client size with ghostty_surface_set_size",
                .{ @intFromPtr(self.hwnd), stale_warn_after, target.width, target.height, cw, ch },
            );
            return;
        },
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

    const hr = self.swap_chain.present(self.sync_interval, self.present_flags);
    self.drainDebugMessages();
    self.present_count += 1;
    if (self.present_count == 1) {
        log.info("first present hwnd={x} {d}x{d}", .{ @intFromPtr(self.hwnd), w, h });
    }
    if (api.failed(hr)) {
        log.warn("Present failed hwnd={x} hr=0x{x}", .{ @intFromPtr(self.hwnd), @as(u32, @bitCast(hr)) });
        return self.presentError(hr);
    }
}

fn presentError(self: *D3D11, hr: api.HRESULT) PresentError {
    if (hr == api.DXGI_ERROR_DEVICE_REMOVED or hr == api.DXGI_ERROR_DEVICE_RESET) {
        const reason = self.device.vtable.GetDeviceRemovedReason(self.device);
        log.err("D3D11 device lost hr=0x{x} reason=0x{x}", .{
            @as(u32, @bitCast(hr)),
            @as(u32, @bitCast(reason)),
        });
        self.lost = true;
        return error.DeviceLost;
    }
    return error.PresentFailed;
}

/// Log what the debug layer queued since the last drain. Debug builds
/// only: `info_queue` is null otherwise. Corruption and errors log as
/// errors, warnings as warnings, the rest at debug level.
fn drainDebugMessages(self: *D3D11) void {
    const queue = self.info_queue orelse return;
    const count = queue.vtable.GetNumStoredMessages(queue);
    if (count == 0) return;
    defer queue.vtable.ClearStoredMessages(queue);

    // A message is the struct followed by its text in one allocation.
    var buf: [4096]u8 align(@alignOf(api.D3D11_MESSAGE)) = undefined;
    var i: api.UINT64 = 0;
    while (i < count) : (i += 1) {
        var len: api.SIZE_T = 0;
        if (api.failed(queue.vtable.GetMessage(queue, i, null, &len))) continue;
        if (len > buf.len) {
            log.warn("debug layer message #{d} is {d} bytes, too long to log", .{ i, len });
            continue;
        }
        if (api.failed(queue.vtable.GetMessage(queue, i, @ptrCast(&buf), &len))) continue;
        const msg: *const api.D3D11_MESSAGE = @ptrCast(&buf);
        const text: []const u8 = if (msg.pDescription) |d| std.mem.sliceTo(d, 0) else "";
        switch (msg.Severity) {
            .CORRUPTION, .ERROR => log.err("debug layer: {s}", .{text}),
            .WARNING => log.warn("debug layer: {s}", .{text}),
            else => log.debug("debug layer: {s}", .{text}),
        }
    }
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

test "d3d11: zero-size client area does not count as stale" {
    const testing = std.testing;

    // A collapsed client area, which the host need not report, never warns.
    var stale: StaleFrames = .{};
    for (0..stale_warn_after * 2) |_| {
        try testing.expectEqual(.drop, stale.frame(800, 0, 640, 480));
        try testing.expectEqual(.drop, stale.frame(0, 600, 640, 480));
    }

    // Nor does it add to a run of real stale frames: it ends the run.
    for (0..stale_warn_after - 1) |_| {
        try testing.expectEqual(.drop, stale.frame(800, 600, 640, 480));
    }
    try testing.expectEqual(.drop, stale.frame(0, 600, 640, 480));
    for (0..stale_warn_after - 1) |_| {
        try testing.expectEqual(.drop, stale.frame(800, 600, 640, 480));
    }

    // A full run warns, once.
    try testing.expectEqual(.drop_warn, stale.frame(800, 600, 640, 480));
    for (0..stale_warn_after * 2) |_| {
        try testing.expectEqual(.drop, stale.frame(800, 600, 640, 480));
    }
}

test "d3d11: stale frames warn only when dropped in a row" {
    const testing = std.testing;

    // A drag drops a few frames at a time, each run ended by a frame that
    // matches the client area, so however many it drops in all it never
    // warns.
    var stale: StaleFrames = .{};
    for (0..stale_warn_after * 2) |_| {
        for (0..stale_warn_after - 1) |_| {
            try testing.expectEqual(.drop, stale.frame(800, 600, 640, 480));
        }
        try testing.expectEqual(.present, stale.frame(800, 600, 800, 600));
    }

    // One unbroken run does.
    for (0..stale_warn_after - 1) |_| {
        try testing.expectEqual(.drop, stale.frame(800, 600, 640, 480));
    }
    try testing.expectEqual(.drop_warn, stale.frame(800, 600, 640, 480));
}

test "d3d11: a client area larger than a texture matches the clamped target" {
    const testing = std.testing;

    // surfaceSize clamps the target to the largest texture, so a frame
    // drawn at that size is current, however often it comes.
    var stale: StaleFrames = .{};
    for (0..stale_warn_after * 2) |_| {
        try testing.expectEqual(.present, stale.frame(20000, 600, max_texture_dimension, 600));
        try testing.expectEqual(.present, stale.frame(800, 20000, 800, max_texture_dimension));
    }
}
