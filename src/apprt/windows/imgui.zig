//! Dear ImGui's DirectX 11 and Win32 backends, for the terminal inspector.
//!
//! The DirectX 11 backend compiles its two shaders at runtime with
//! D3DCompile. Linked as it is, that call would put d3dcompiler_47.dll in
//! the exe's import table, and that DLL is not a KnownDLL: a static import
//! of it is searched for in the application's directory first, so a copy
//! planted beside the exe would load at startup. pkg/dcimgui renames the
//! call to ghostty_imgui_D3DCompile, which this file defines over the
//! renderer's loader, the one that searches System32 only.
//!
//! `View` is a top-level window that ImGui draws in through both backends.

const std = @import("std");
const builtin = @import("builtin");
const cimgui = @import("dcimgui");

const global = @import("../../global.zig");
const D3D11 = @import("../../renderer.zig").D3D11;
const api = D3D11.api;
const App = @import("App.zig").App;
const win32 = @import("win32.zig");
const L = win32.L;

const log = std.log.scoped(.win32);

const LoadCompiler = @TypeOf(&D3D11.loadCompiler);

/// For tests: a loader in place of the renderer's
/// (`ghostty_imgui_D3DCompile`), to reach the shim's failure path.
var test_load_compiler: if (builtin.is_test) ?LoadCompiler else void =
    if (builtin.is_test) null else {};

/// D3DCompile for the DirectX 11 backend (see the file comment). It
/// returns E_FAIL, with both blobs null, when the compiler cannot be
/// loaded. The backend's CreateDeviceObjects then returns false, and its
/// NewFrame calls that again on every frame and asserts when it fails,
/// so a caller creates the device objects itself and draws nothing when
/// they fail.
export fn ghostty_imgui_D3DCompile(
    data: *const anyopaque,
    data_size: api.SIZE_T,
    filename: ?api.LPCSTR,
    defines: ?[*]const api.D3D_SHADER_MACRO,
    include: ?*api.ID3DInclude,
    entrypoint: ?api.LPCSTR,
    target: api.LPCSTR,
    sflags: api.UINT,
    eflags: api.UINT,
    shader: *?*api.ID3DBlob,
    error_messages: ?*?*api.ID3DBlob,
) callconv(.winapi) api.HRESULT {
    const load = if (builtin.is_test) test_load_compiler orelse &D3D11.loadCompiler else &D3D11.loadCompiler;
    const compile = load() catch {
        shader.* = null;
        if (error_messages) |messages| messages.* = null;
        return api.E_FAIL;
    };
    return compile(data, data_size, filename, defines, include, entrypoint, target, sflags, eflags, shader, error_messages);
}

/// A top-level window that Dear ImGui draws in, with an ImGui context, a
/// device and a flip-model swap chain of its own. Its owner builds the UI
/// (`Owner.draw`). Frames come from WM_PAINT and from a timer at 30 per
/// second, the most GTK's inspector redraws. All of it runs on the UI
/// thread. The window takes no input yet: the Win32 backend's message
/// handler is not called, and ImGui leaves the pointer's shape alone.
pub const View = struct {
    hwnd: win32.HWND,
    ctx: *cimgui.c.ImGuiContext,
    owner: Owner,

    /// Null after the device was lost or could not be made, until a frame
    /// makes another (`gpuForFrame`).
    gpu: ?Gpu,

    /// When a frame may next try to make a device, after one failed.
    recovery: D3D11.Recovery,

    /// Frames presented, for the log's first one and for the tests.
    presents: u64,

    pub const Owner = struct {
        ptr: *anyopaque,

        /// Whether a frame may draw now; when not, the window keeps
        /// showing the last one. Asked first, before anything else.
        ready: *const fn (*anyopaque) bool,

        /// Build the UI, with the view's context current, between
        /// ImGui_NewFrame and ImGui_Render. Twice per frame, as GTK and
        /// macOS do: some of ImGui's state takes a second frame to settle.
        draw: *const fn (*anyopaque) void,

        /// The window's close button, Alt+F4 or the window menu's Close
        /// (WM_CLOSE). The window stays until the owner calls `deinit`,
        /// which it may do from here.
        close: *const fn (*anyopaque) void,
    };

    const Gpu = struct {
        device: *api.ID3D11Device,
        context: *api.ID3D11DeviceContext,
        swap_chain: *api.IDXGISwapChain1,

        /// The back buffer's view, made for the chain's current size.
        target: ?*api.ID3D11RenderTargetView,

        /// The backend made its shaders and states. Without a compiler it
        /// cannot, and its NewFrame would assert, so frames then show the
        /// background only.
        drawable: bool,
    };

    pub const class_name = "GhosttyImGuiClass";

    /// The window's frame timer (WM_TIMER).
    const timer_id: win32.UINT_PTR = 1;
    const frame_ms: win32.UINT = 1000 / 30;

    /// The window property the Win32 backend keeps the context in.
    const context_prop = "IMGUI_CONTEXT";

    /// Register the window class. `icon` is the caption's and Alt+Tab's;
    /// null leaves the system's.
    pub fn registerClass(hinstance: win32.HINSTANCE, cursor: ?win32.HCURSOR, icon: ?win32.HICON) App.Error!void {
        const class: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            // A resize repaints the whole window at the new size at once
            // (WM_PAINT), rather than at the timer's next frame.
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
            .lpfnWndProc = &wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = icon,
            .hCursor = cursor,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = L(class_name),
            .hIconSm = null,
        };
        if (win32.RegisterClassExW(&class) == 0) {
            log.err("failed to register the ImGui window class err={}", .{win32.GetLastError()});
            return App.Error.Win32ClassRegistrationFailed;
        }
    }

    pub fn unregisterClass(hinstance: win32.HINSTANCE) void {
        _ = win32.UnregisterClassW(L(class_name), hinstance);
    }

    /// Make the window, hidden, `width` by `height` pixels with its frame,
    /// with its context and its GPU objects, and leave the context current
    /// for the owner's setup (fonts, flags); `show` then shows it. A device
    /// that cannot be made is not an error: the window opens and its frames
    /// try again (`recovery`). `self` must not move, as the window
    /// procedure finds it through GWLP_USERDATA.
    pub fn init(
        self: *View,
        hinstance: win32.HINSTANCE,
        title: [*:0]const u16,
        width: c_int,
        height: c_int,
        owner: Owner,
    ) !void {
        const hwnd = win32.CreateWindowExW(
            0,
            L(class_name),
            title,
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            width,
            height,
            null,
            null,
            hinstance,
            null,
        ) orelse {
            log.err("CreateWindowExW failed for an ImGui window err={}", .{win32.GetLastError()});
            return App.Error.Win32WindowCreationFailed;
        };
        errdefer _ = win32.DestroyWindow(hwnd);

        const ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.ImGuiContextFailed;
        errdefer cimgui.c.ImGui_DestroyContext(ctx);
        cimgui.c.ImGui_SetCurrentContext(ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.IniFilename = null;
        io.LogFilename = null;
        // Its first frame would set the pointer's shape wherever the
        // pointer is, over a terminal too, and nothing here answers
        // WM_SETCURSOR for it.
        io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_NoMouseCursorChange;

        self.* = .{
            .hwnd = hwnd,
            .ctx = ctx,
            .owner = owner,
            .gpu = null,
            .recovery = .{},
            .presents = 0,
        };
        _ = self.gpuForFrame();
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    }

    /// Show the window and start its frames.
    pub fn show(self: *View) void {
        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNORMAL);
        if (win32.SetTimer(self.hwnd, timer_id, frame_ms, null) == 0)
            log.warn("SetTimer failed for an ImGui window err={}; it draws only when repainted", .{win32.GetLastError()});
    }

    /// Destroy the window and everything made for it. Its procedure
    /// forgets the view first, so nothing the destruction sends reaches it.
    pub fn deinit(self: *View) void {
        _ = win32.SetWindowLongPtrW(self.hwnd, win32.GWLP_USERDATA, 0);
        _ = win32.KillTimer(self.hwnd, timer_id);
        cimgui.c.ImGui_SetCurrentContext(self.ctx);
        self.releaseGpu();
        cimgui.c.ImGui_DestroyContext(self.ctx);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// The Win32 backend's Shutdown, with the context current. It sets the
    /// window's context property to null rather than removing it, and a
    /// window must have its properties removed before it is destroyed
    /// (the RemovePropA docs).
    fn shutdownWin32(hwnd: win32.HWND) void {
        cimgui.ImGui_ImplWin32_Shutdown();
        _ = win32.RemovePropA(hwnd, context_prop);
    }

    /// Draw and present one frame, unless the window is minimized, the
    /// owner is not ready or there is no device.
    fn frame(self: *View) void {
        if (win32.IsIconic(self.hwnd).toBool()) return;
        if (!self.owner.ready(self.owner.ptr)) return;
        var rc: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &rc).toBool()) return;
        if (rc.right <= rc.left or rc.bottom <= rc.top) return;

        cimgui.c.ImGui_SetCurrentContext(self.ctx);
        const gpu = self.gpuForFrame() orelse return;
        const target = self.sizedTarget(gpu, @intCast(rc.right - rc.left), @intCast(rc.bottom - rc.top)) orelse return;

        if (gpu.drawable) for (0..2) |_| {
            cimgui.ImGui_ImplDX11_NewFrame();
            cimgui.ImGui_ImplWin32_NewFrame();
            cimgui.c.ImGui_NewFrame();
            self.owner.draw(self.owner.ptr);
            cimgui.c.ImGui_Render();
        };

        const context = gpu.context;
        context.vtable.OMSetRenderTargets(context, 1, &[_]?*api.ID3D11RenderTargetView{target}, null);
        const bg = cimgui.c.ImGui_GetStyle().*.Colors[cimgui.c.ImGuiCol_WindowBg];
        context.vtable.ClearRenderTargetView(context, target, &.{ bg.x, bg.y, bg.z, 1 });
        if (gpu.drawable) cimgui.ImGui_ImplDX11_RenderDrawData(cimgui.c.ImGui_GetDrawData());

        // Interval 0: the UI thread never waits for a vblank. A flip
        // chain still queues the frame, and at 30 per second the queue
        // never fills.
        const hr = gpu.swap_chain.present(0, 0);
        if (api.failed(hr)) return self.failed("Present", hr);
        self.presents += 1;
        if (self.presents == 1) log.info("ImGui window first present hwnd={x} drawable={}", .{ @intFromPtr(self.hwnd), gpu.drawable });
    }

    /// The GPU objects, made now if there are none and the last failure
    /// was long enough ago (`recovery`). The context must be current: the
    /// DirectX 11 backend is initialized in it.
    fn gpuForFrame(self: *View) ?*Gpu {
        if (self.gpu) |*gpu| return gpu;
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        if (self.recovery.delayMs(now) > 0) return null;
        self.gpu = makeGpu(self.hwnd) catch |err| {
            self.recovery.failed(now);
            log.err("ImGui window D3D11 setup failed err={}; retrying in {d}ms", .{ err, D3D11.recovery_retry_ms });
            return null;
        };
        self.recovery.succeeded();
        return &self.gpu.?;
    }

    /// A device, a swap chain for `hwnd` sized to its client area, and both
    /// backends initialized for them, in the current context.
    fn makeGpu(hwnd: win32.HWND) !Gpu {
        const made = try D3D11.createDevice(api.D3D11_CREATE_DEVICE_BGRA_SUPPORT);
        errdefer api.release(made.device);
        errdefer api.release(made.context);

        // The factory that made the device's adapter makes its chains.
        const dxgi_device = try api.queryInterface(made.device, api.IDXGIDevice);
        defer api.release(dxgi_device);
        var adapter_ptr: ?*api.IDXGIAdapter = null;
        var hr = dxgi_device.vtable.GetAdapter(dxgi_device, &adapter_ptr);
        if (api.failed(hr)) return error.D3D11DeviceFailed;
        const adapter = adapter_ptr orelse return error.D3D11DeviceFailed;
        defer api.release(adapter);
        const factory = try adapter.getParent(api.IDXGIFactory2);
        defer api.release(factory);

        // The renderer's HWND chain, less its tearing: width and height
        // 0 size it to the client area.
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
        hr = factory.vtable.CreateSwapChainForHwnd(factory, api.unknown(made.device), hwnd, &desc, null, null, &swap_chain_ptr);
        if (api.failed(hr)) {
            log.err("CreateSwapChainForHwnd failed for an ImGui window hwnd={x} hr=0x{x}", .{ @intFromPtr(hwnd), @as(u32, @bitCast(hr)) });
            return error.D3D11SwapChainFailed;
        }
        const swap_chain = swap_chain_ptr orelse return error.D3D11SwapChainFailed;
        errdefer api.release(swap_chain);

        // Alt+Enter would take the chain full-screen.
        hr = factory.makeWindowAssociation(hwnd, api.DXGI_MWA_NO_ALT_ENTER | api.DXGI_MWA_NO_WINDOW_CHANGES);
        if (api.failed(hr)) log.warn("MakeWindowAssociation failed for an ImGui window hr=0x{x}", .{@as(u32, @bitCast(hr))});

        // The backends start and end together (`releaseGpu`): the DirectX
        // 11 backend's Shutdown destroys every viewport's platform data,
        // the Win32 backend's for the main viewport among them, which
        // that backend reads in every frame after.
        if (!cimgui.ImGui_ImplWin32_Init(hwnd)) return error.ImGuiWin32Failed;
        errdefer shutdownWin32(hwnd);
        if (!cimgui.ImGui_ImplDX11_Init(made.device, made.context)) return error.ImGuiD3D11Failed;
        // A warning: a compiler that cannot load (the usual cause) logs
        // its own error.
        const drawable = cimgui.ImGui_ImplDX11_CreateDeviceObjects();
        if (!drawable) log.warn("ImGui's DirectX 11 objects could not be made; the window shows its background only", .{});
        return .{
            .device = made.device,
            .context = made.context,
            .swap_chain = swap_chain,
            .target = null,
            .drawable = drawable,
        };
    }

    /// The back buffer's render target view, with the chain resized to
    /// `width` by `height` first if it is not that size. Null on failure.
    fn sizedTarget(self: *View, gpu: *Gpu, width: api.UINT, height: api.UINT) ?*api.ID3D11RenderTargetView {
        var desc: api.DXGI_SWAP_CHAIN_DESC1 = undefined;
        const sized = api.succeeded(gpu.swap_chain.getDesc1(&desc)) and
            desc.Width == width and desc.Height == height;
        if (sized) if (gpu.target) |target| return target;

        if (gpu.target) |target| api.release(target);
        gpu.target = null;
        if (!sized) {
            // ResizeBuffers fails while any view of a buffer is still
            // bound, and the last frame's still is.
            gpu.context.vtable.ClearState(gpu.context);
            const hr = gpu.swap_chain.resizeBuffers(0, width, height, .UNKNOWN, 0);
            if (api.failed(hr)) {
                self.failed("ResizeBuffers", hr);
                return null;
            }
        }

        const back = gpu.swap_chain.getBuffer(0, api.ID3D11Texture2D) catch {
            log.warn("ImGui window back buffer unavailable", .{});
            return null;
        };
        defer api.release(back);
        var target: ?*api.ID3D11RenderTargetView = null;
        const hr = gpu.device.vtable.CreateRenderTargetView(gpu.device, back.resource(), null, &target);
        if (api.failed(hr)) {
            self.failed("CreateRenderTargetView", hr);
            return null;
        }
        gpu.target = target;
        return target;
    }

    /// Whether `hr` means the device is gone, and with it everything made
    /// on it.
    fn isDeviceLoss(hr: api.HRESULT) bool {
        return hr == api.DXGI_ERROR_DEVICE_REMOVED or hr == api.DXGI_ERROR_DEVICE_RESET;
    }

    /// Log a failed call of `what`. A lost device is released, and the
    /// next frame makes another.
    fn failed(self: *View, what: []const u8, hr: api.HRESULT) void {
        if (!isDeviceLoss(hr)) {
            log.warn("{s} failed for an ImGui window hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
            return;
        }
        self.loseDevice(what, hr);
    }

    fn loseDevice(self: *View, what: []const u8, hr: api.HRESULT) void {
        const gpu = self.gpu orelse return;
        const reason = gpu.device.vtable.GetDeviceRemovedReason(gpu.device);
        log.err("ImGui window D3D11 device lost in {s} hr=0x{x} reason=0x{x}; making another", .{
            what,
            @as(u32, @bitCast(hr)),
            @as(u32, @bitCast(reason)),
        });
        self.releaseGpu();
    }

    /// Release the GPU objects and end both backends (see `makeGpu`); the
    /// context must be current.
    fn releaseGpu(self: *View) void {
        const gpu = self.gpu orelse return;
        self.gpu = null;
        cimgui.ImGui_ImplDX11_Shutdown();
        shutdownWin32(self.hwnd);
        if (gpu.target) |target| api.release(target);
        // Unbound and flushed, released objects are destroyed now rather
        // than at a flush that never comes (as the renderer's releaseGpu).
        gpu.context.vtable.ClearState(gpu.context);
        gpu.context.vtable.Flush(gpu.context);
        api.release(gpu.swap_chain);
        api.release(gpu.context);
        api.release(gpu.device);
    }

    fn wndProc(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        App.handler_depth += 1;
        defer App.handler_depth -= 1;
        const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (ptr == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        const self: *View = @ptrFromInt(@as(usize, @bitCast(ptr)));
        switch (msg) {
            // Every pixel is the swap chain's.
            win32.WM_ERASEBKGND => return 1,

            win32.WM_PAINT => {
                var ps: win32.PAINTSTRUCT = undefined;
                _ = win32.BeginPaint(hwnd, &ps);
                _ = win32.EndPaint(hwnd, &ps);
                self.frame();
                return 0;
            },

            win32.WM_TIMER => if (wparam == timer_id) {
                self.frame();
                return 0;
            },

            // The owner may free the view here.
            win32.WM_CLOSE => {
                self.owner.close(self.owner.ptr);
                return 0;
            },

            else => {},
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
};

/// A WARP device, which every supported Windows has, GPU driver or not.
const TestDevice = struct {
    device: *api.ID3D11Device,
    context: *api.ID3D11DeviceContext,

    fn init() !TestDevice {
        const levels = [_]api.D3D_FEATURE_LEVEL{.@"11_0"};
        var device: ?*api.ID3D11Device = null;
        var context: ?*api.ID3D11DeviceContext = null;
        if (api.failed(D3D11.D3D11CreateDevice(null, .WARP, null, 0, &levels, levels.len, api.D3D11_SDK_VERSION, &device, null, &context)))
            return error.TestDeviceFailed;
        return .{ .device = device orelse return error.TestDeviceFailed, .context = context orelse return error.TestDeviceFailed };
    }

    fn deinit(self: TestDevice) void {
        api.release(self.context);
        api.release(self.device);
    }
};

/// An ImGui context with no ini or log file, current until `deinit`.
const TestContext = struct {
    ctx: *cimgui.c.ImGuiContext,

    fn init(width: f32, height: f32) !TestContext {
        const ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.ImGuiContextFailed;
        cimgui.c.ImGui_SetCurrentContext(ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.IniFilename = null;
        io.LogFilename = null;
        io.DisplaySize = .{ .x = width, .y = height };
        return .{ .ctx = ctx };
    }

    fn deinit(self: TestContext) void {
        cimgui.c.ImGui_DestroyContext(self.ctx);
    }
};

/// A 64x48 RGBA texture, for a render target or a CPU-readable copy of one.
fn testTexture(device: *api.ID3D11Device, usage: api.D3D11_USAGE, bind: api.UINT, cpu: api.UINT) !*api.ID3D11Texture2D {
    const desc: api.D3D11_TEXTURE2D_DESC = .{
        .Width = 64,
        .Height = 48,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .R8G8B8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = usage,
        .BindFlags = bind,
        .CPUAccessFlags = cpu,
        .MiscFlags = 0,
    };
    var texture: ?*api.ID3D11Texture2D = null;
    if (api.failed(device.vtable.CreateTexture2D(device, &desc, null, &texture))) return error.TextureFailed;
    return texture orelse error.TextureFailed;
}

test "win32: ImGui's DirectX 11 backend compiles through ghostty_imgui_D3DCompile and draws" {
    const testing = std.testing;

    const d3d = try TestDevice.init();
    defer d3d.deinit();
    const device = d3d.device;
    const context = d3d.context;

    const ig = try TestContext.init(64, 48);
    defer ig.deinit();
    try testing.expect(cimgui.ImGui_ImplDX11_Init(device, context));
    defer cimgui.ImGui_ImplDX11_Shutdown();
    // Both shaders compile here, through ghostty_imgui_D3DCompile.
    try testing.expect(cimgui.ImGui_ImplDX11_CreateDeviceObjects());

    const target = try testTexture(device, .DEFAULT, api.D3D11_BIND_RENDER_TARGET, 0);
    defer api.release(target);
    var rtv: ?*api.ID3D11RenderTargetView = null;
    try testing.expect(api.succeeded(device.vtable.CreateRenderTargetView(device, target.resource(), null, &rtv)));
    defer api.release(rtv.?);
    context.vtable.OMSetRenderTargets(context, 1, &[_]?*api.ID3D11RenderTargetView{rtv}, null);
    context.vtable.ClearRenderTargetView(context, rtv.?, &.{ 0, 0, 0, 1 });

    // One opaque red rectangle, (16,16) to (48,32), over a black frame.
    cimgui.ImGui_ImplDX11_NewFrame();
    cimgui.c.ImGui_NewFrame();
    cimgui.c.ImDrawList_AddRectFilled(
        cimgui.c.ImGui_GetForegroundDrawList(),
        .{ .x = 16, .y = 16 },
        .{ .x = 48, .y = 32 },
        0xff0000ff, // IM_COL32(255, 0, 0, 255)
    );
    cimgui.c.ImGui_Render();
    cimgui.ImGui_ImplDX11_RenderDrawData(cimgui.c.ImGui_GetDrawData());

    const copy = try testTexture(device, .STAGING, 0, api.D3D11_CPU_ACCESS_READ);
    defer api.release(copy);
    context.vtable.CopyResource(context, copy.resource(), target.resource());
    var mapped: api.D3D11_MAPPED_SUBRESOURCE = undefined;
    try testing.expect(api.succeeded(context.vtable.Map(context, copy.resource(), 0, .READ, 0, &mapped)));
    defer context.vtable.Unmap(context, copy.resource(), 0);
    const bytes: [*]const u8 = @ptrCast(mapped.pData.?);
    const pixel = struct {
        fn at(b: [*]const u8, pitch: usize, x: usize, y: usize) [4]u8 {
            return b[y * pitch + x * 4 ..][0..4].*;
        }
    }.at;
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(bytes, mapped.RowPitch, 32, 24));
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(bytes, mapped.RowPitch, 4, 4));
}

test "win32: ImGui_TextColored formats its arguments, in its colour" {
    const testing = std.testing;

    // The DirectX 11 backend makes the glyphs' texture as text needs it.
    const d3d = try TestDevice.init();
    defer d3d.deinit();
    const ig = try TestContext.init(400, 300);
    defer ig.deinit();
    try testing.expect(cimgui.ImGui_ImplDX11_Init(d3d.device, d3d.context));
    defer cimgui.ImGui_ImplDX11_Shutdown();

    cimgui.ImGui_ImplDX11_NewFrame();
    cimgui.c.ImGui_NewFrame();
    cimgui.c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, cimgui.c.ImGuiCond_Always);
    _ = cimgui.c.ImGui_Begin("test", null, 0);
    // The inspector's colour for an active screen. Passed as Zig passes a
    // variadic function's ImVec4 on Windows ARM64, its third component
    // was the address the C wrapper read its format from.
    const col: cimgui.c.ImVec4 = .{ .x = 0.4, .y = 1.0, .z = 0.4, .w = 1.0 };
    const list = cimgui.c.ImGui_GetWindowDrawList();
    const before: usize = @intCast(list.*.VtxBuffer.Size);
    cimgui.c.ImGui_TextColored(col, "%s %d", @as([*:0]const u8, "ab"), @as(c_int, 12));
    const size = cimgui.c.ImGui_GetItemRectSize();
    const after: usize = @intCast(list.*.VtxBuffer.Size);
    const want = cimgui.c.ImGui_CalcTextSize("ab 12");
    cimgui.c.ImGui_End();
    cimgui.c.ImGui_Render();

    try testing.expectEqual(want.x, size.x);
    try testing.expectEqual(want.y, size.y);
    // Every vertex of the text is in the colour.
    try testing.expect(after > before);
    const rgba = cimgui.c.ImGui_ColorConvertFloat4ToU32(col);
    for (list.*.VtxBuffer.Data[before..after]) |vertex| try testing.expectEqual(rgba, vertex.col);
}

test "win32: ImGui's Win32 backend never loads XInput" {
    const testing = std.testing;
    // The backend's gamepad support, which the build leaves out, loads the
    // first of these it finds; Windows 10 and 11 ship xinput1_4.dll.
    const xinput = [_][*:0]const u16{
        L("xinput1_4.dll"),
        L("xinput1_3.dll"),
        L("xinput9_1_0.dll"),
        L("xinput1_2.dll"),
        L("xinput1_1.dll"),
    };
    // None is loaded yet, so one loaded below is the backend's doing.
    for (xinput) |name| try testing.expect(win32.GetModuleHandleW(name) == null);

    const hwnd = win32.CreateWindowExW(0, L("STATIC"), L(""), win32.WS_POPUP, 0, 0, 64, 48, null, null, null, null) orelse
        return error.TestWindowFailed;
    defer _ = win32.DestroyWindow(hwnd);
    const ig = try TestContext.init(0, 0);
    defer ig.deinit();
    try testing.expect(cimgui.ImGui_ImplWin32_Init(hwnd));
    defer cimgui.ImGui_ImplWin32_Shutdown();
    cimgui.ImGui_ImplWin32_NewFrame();

    for (xinput) |name| try testing.expect(win32.GetModuleHandleW(name) == null);
}

test "win32: ImGui's DirectX 11 backend fails cleanly without a compiler" {
    const testing = std.testing;
    test_load_compiler = &noCompiler;
    defer test_load_compiler = null;

    const d3d = try TestDevice.init();
    defer d3d.deinit();
    const ig = try TestContext.init(64, 48);
    defer ig.deinit();
    try testing.expect(cimgui.ImGui_ImplDX11_Init(d3d.device, d3d.context));
    // Shutdown and the context's destruction follow the failure.
    defer cimgui.ImGui_ImplDX11_Shutdown();
    try testing.expect(!cimgui.ImGui_ImplDX11_CreateDeviceObjects());
}

test "win32: the ImGui compiler shim fails with no blobs when the compiler cannot load" {
    const testing = std.testing;
    test_load_compiler = &noCompiler;
    defer test_load_compiler = null;

    // Addresses no blob has, which the shim must overwrite.
    var shader: ?*api.ID3DBlob = @ptrFromInt(0x1000);
    var messages: ?*api.ID3DBlob = @ptrFromInt(0x1000);
    const source = "float4 main() : SV_Target { return 0; }";
    try testing.expectEqual(api.E_FAIL, ghostty_imgui_D3DCompile(source.ptr, source.len, null, null, null, "main", "ps_4_0", 0, 0, &shader, &messages));
    try testing.expect(shader == null);
    try testing.expect(messages == null);
    // The error blob is optional.
    shader = @ptrFromInt(0x1000);
    try testing.expectEqual(api.E_FAIL, ghostty_imgui_D3DCompile(source.ptr, source.len, null, null, null, null, "fx_5_0", 0, 0, &shader, null));
    try testing.expect(shader == null);
}

fn noCompiler() error{D3DCompilerMissing}!api.D3DCompileFn {
    return error.D3DCompilerMissing;
}

/// For tests: a view's owner that counts what the view asks of it, and
/// draws one rectangle per frame.
const TestOwner = struct {
    ready: bool = true,
    draws: u32 = 0,
    closes: u32 = 0,

    fn owner(self: *TestOwner) View.Owner {
        return .{ .ptr = self, .ready = isReady, .draw = draw, .close = close };
    }

    fn isReady(ptr: *anyopaque) bool {
        const self: *TestOwner = @ptrCast(@alignCast(ptr));
        return self.ready;
    }

    fn draw(ptr: *anyopaque) void {
        const self: *TestOwner = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        cimgui.c.ImDrawList_AddRectFilled(
            cimgui.c.ImGui_GetForegroundDrawList(),
            .{ .x = 8, .y = 8 },
            .{ .x = 40, .y = 24 },
            0xff0000ff,
        );
    }

    fn close(ptr: *anyopaque) void {
        const self: *TestOwner = @ptrCast(@alignCast(ptr));
        self.closes += 1;
    }
};

/// For tests: the exe's instance, with the view's class registered until
/// `deinit`.
const TestClass = struct {
    hinstance: win32.HINSTANCE,

    fn init() !TestClass {
        const hinstance: win32.HINSTANCE = @ptrCast(std.os.windows.peb().ImageBaseAddress);
        try View.registerClass(hinstance, null, null);
        return .{ .hinstance = hinstance };
    }

    fn deinit(self: TestClass) void {
        View.unregisterClass(self.hinstance);
    }
};

/// For tests: the frame a timer tick draws. The view is never shown, so
/// that no test window takes the focus; a hidden window draws as a shown
/// one does.
fn testTick(view: *View) void {
    _ = win32.SendMessageW(view.hwnd, win32.WM_TIMER, View.timer_id, 0);
}

test "win32: an ImGui view draws its owner twice per frame and presents" {
    const testing = std.testing;
    const class = try TestClass.init();
    defer class.deinit();
    var owner: TestOwner = .{};
    var view: View = undefined;
    try view.init(class.hinstance, L("test"), 320, 200, owner.owner());
    defer view.deinit();
    try testing.expect(view.gpu.?.drawable);

    testTick(&view);
    try testing.expectEqual(2, owner.draws);
    try testing.expectEqual(1, view.presents);
    // The rectangle reached the draw data, and the chain is the client
    // area's size.
    try testing.expect(cimgui.c.ImGui_GetDrawData().*.TotalVtxCount > 0);
    var rc: win32.RECT = undefined;
    try testing.expect(win32.GetClientRect(view.hwnd, &rc).toBool());
    var desc: api.DXGI_SWAP_CHAIN_DESC1 = undefined;
    try testing.expect(api.succeeded(view.gpu.?.swap_chain.getDesc1(&desc)));
    try testing.expectEqual(@as(api.UINT, @intCast(rc.right - rc.left)), desc.Width);
    try testing.expectEqual(@as(api.UINT, @intCast(rc.bottom - rc.top)), desc.Height);

    // A repaint draws a frame too.
    _ = win32.SendMessageW(view.hwnd, win32.WM_PAINT, 0, 0);
    try testing.expectEqual(4, owner.draws);
    try testing.expectEqual(2, view.presents);

    // Another timer's tick draws nothing, nor does one while the owner is
    // not ready.
    _ = win32.SendMessageW(view.hwnd, win32.WM_TIMER, View.timer_id + 1, 0);
    owner.ready = false;
    testTick(&view);
    try testing.expectEqual(4, owner.draws);
    try testing.expectEqual(2, view.presents);

    // A resize: the next frame resizes the chain.
    owner.ready = true;
    try testing.expect(win32.SetWindowPos(view.hwnd, null, 0, 0, 400, 300, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE).toBool());
    testTick(&view);
    try testing.expect(win32.GetClientRect(view.hwnd, &rc).toBool());
    try testing.expect(api.succeeded(view.gpu.?.swap_chain.getDesc1(&desc)));
    try testing.expectEqual(@as(api.UINT, @intCast(rc.right - rc.left)), desc.Width);
    try testing.expectEqual(@as(api.UINT, @intCast(rc.bottom - rc.top)), desc.Height);
}

test "win32: closing an ImGui view's window asks its owner" {
    const testing = std.testing;
    const class = try TestClass.init();
    defer class.deinit();
    var owner: TestOwner = .{};
    var view: View = undefined;
    try view.init(class.hinstance, L("test"), 320, 200, owner.owner());
    defer view.deinit();

    _ = win32.SendMessageW(view.hwnd, win32.WM_CLOSE, 0, 0);
    try testing.expectEqual(1, owner.closes);
    // The window stays until the owner ends the view.
    try testing.expect(win32.IsWindow(view.hwnd).toBool());
}

test "win32: an ImGui view makes another device after it lost one" {
    const testing = std.testing;
    const class = try TestClass.init();
    defer class.deinit();
    var owner: TestOwner = .{};
    var view: View = undefined;
    try view.init(class.hinstance, L("test"), 320, 200, owner.owner());
    defer view.deinit();
    testTick(&view);
    try testing.expectEqual(1, view.presents);

    // Only a removed or reset device is lost; any other failure keeps it.
    try testing.expect(View.isDeviceLoss(api.DXGI_ERROR_DEVICE_REMOVED));
    try testing.expect(View.isDeviceLoss(api.DXGI_ERROR_DEVICE_RESET));
    try testing.expect(!View.isDeviceLoss(api.E_FAIL));
    view.failed("Present", api.E_FAIL);
    try testing.expect(view.gpu != null);

    // Released as a lost one is (`loseDevice`, whose error log would fail
    // the test). The next frame makes another, with both backends
    // initialized again and the font texture made again, and draws; the
    // Win32 backend's frame reads the main viewport's data, which the
    // DirectX 11 backend's Shutdown destroyed. Twice, as the backends'
    // Shutdown and Init must allow.
    for (0..2) |i| {
        view.releaseGpu();
        try testing.expect(view.gpu == null);
        testTick(&view);
        try testing.expect(view.gpu != null);
        try testing.expectEqual(2 * (i + 2), owner.draws);
        try testing.expectEqual(i + 2, view.presents);
    }
}

test "win32: an ImGui view without a compiler shows its background only" {
    const testing = std.testing;
    test_load_compiler = &noCompiler;
    defer test_load_compiler = null;
    const class = try TestClass.init();
    defer class.deinit();
    var owner: TestOwner = .{};
    var view: View = undefined;
    try view.init(class.hinstance, L("test"), 320, 200, owner.owner());
    defer view.deinit();
    try testing.expect(!view.gpu.?.drawable);

    // No ImGui frame, which would assert in the backend's NewFrame; the
    // background is presented.
    testTick(&view);
    try testing.expectEqual(0, owner.draws);
    try testing.expectEqual(1, view.presents);
}

test "win32: ImGui views draw side by side and leave no USER objects" {
    const testing = std.testing;
    const class = try TestClass.init();
    defer class.deinit();
    const before = win32.GetGuiResources(win32.current_process, win32.GR_USEROBJECTS);

    var first_owner: TestOwner = .{};
    var first: View = undefined;
    try first.init(class.hinstance, L("first"), 320, 200, first_owner.owner());
    var second_owner: TestOwner = .{};
    var second: View = undefined;
    try second.init(class.hinstance, L("second"), 320, 200, second_owner.owner());
    testTick(&first);
    testTick(&second);
    testTick(&first);
    try testing.expectEqual(4, first_owner.draws);
    try testing.expectEqual(2, second_owner.draws);

    // The first one's end leaves no context current; the second makes its
    // own current for its frame.
    const hwnd = first.hwnd;
    first.deinit();
    try testing.expect(!win32.IsWindow(hwnd).toBool());
    testTick(&second);
    try testing.expectEqual(4, second_owner.draws);
    try testing.expectEqual(2, second.presents);
    second.deinit();

    try testing.expectEqual(before, win32.GetGuiResources(win32.current_process, win32.GR_USEROBJECTS));
}
