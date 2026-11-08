//! Dear ImGui's DirectX 11 and Win32 backends, for the terminal inspector.
//!
//! The DirectX 11 backend compiles its two shaders at runtime with
//! D3DCompile. Linked as it is, that call would put d3dcompiler_47.dll in
//! the exe's import table, and that DLL is not a KnownDLL: a static import
//! of it is searched for in the application's directory first, so a copy
//! planted beside the exe would load at startup. pkg/dcimgui renames the
//! call to ghostty_imgui_D3DCompile, which this file defines over the
//! renderer's loader, the one that searches System32 only.

const std = @import("std");
const builtin = @import("builtin");
const cimgui = @import("dcimgui");

const D3D11 = @import("../../renderer.zig").D3D11;
const api = D3D11.api;
const win32 = @import("win32.zig");

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

test "win32: ImGui's Win32 backend never loads XInput" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
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
