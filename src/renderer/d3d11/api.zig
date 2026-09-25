//! Direct3D 11, DXGI and D3DCompiler declarations for the D3D11 renderer
//! backend.
//!
//! The COM interfaces are vtable structs in the order of the mingw headers
//! Zig ships (lib/libc/include/any-windows-any: d3d11.h, dxgi.h, dxgi1_2.h,
//! dxgi1_3.h, dxgi1_4.h, dxgi1_5.h, d3d11sdklayers.h, d3dcommon.h,
//! d3dcompiler.h), the same headers the C compiler would read. Only the
//! methods the backend calls are typed; every other slot is an untyped
//! pointer, so a vtable keeps its size and each typed slot keeps its index.
//! A derived interface embeds its parent's vtable as its first field, which
//! is how COM lays them out.
//!
//! The tests check every vtable's slot count and every struct's layout
//! against the header, so a dropped or shuffled slot fails on any host
//! instead of calling the wrong function in a Windows run. No extern
//! function lives here so that those tests link everywhere; D3D11.zig
//! declares D3D11CreateDevice and loads D3DCompile at runtime.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

/// The calling convention of every COM method and of D3DCompile: the
/// platform convention on Windows (stdcall on x86, the C convention on
/// x86_64 and aarch64). On other hosts only the layout tests analyze these
/// types, and the Windows convention is not compilable there, so the C
/// convention stands in; it never gets called.
const cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

pub const UINT = u32;
pub const INT = i32;
pub const ULONG = u32;
pub const UINT8 = u8;
pub const UINT64 = u64;
pub const SIZE_T = usize;
pub const FLOAT = f32;
/// WINBOOL in the headers: a C int.
pub const BOOL = i32;
pub const WCHAR = u16;
pub const LPCSTR = [*:0]const u8;
pub const HWND = windows.HWND;
pub const HMODULE = windows.HMODULE;
pub const HANDLE = windows.HANDLE;
pub const GUID = windows.GUID;
pub const REFIID = *const GUID;

/// A Windows LONG, 32 bits on every Windows target. Spelled as i32 rather
/// than c_long so the constants below mean the same thing when the tests
/// run on a host where c_long is 64 bits.
pub const HRESULT = i32;

pub const LUID = extern struct {
    LowPart: u32,
    HighPart: i32,
};

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub inline fn failed(hr: HRESULT) bool {
    return hr < 0;
}

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
pub const DXGI_ERROR_NOT_FOUND: HRESULT = @bitCast(@as(u32, 0x887A0002));
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
pub const DXGI_ERROR_SDK_COMPONENT_MISSING: HRESULT = @bitCast(@as(u32, 0x887A002D));
pub const DXGI_STATUS_OCCLUDED: HRESULT = @bitCast(@as(u32, 0x087A0001));

// Well-known IIDs. IUnknown's is the one GUID every COM header agrees on;
// the rest come from the DEFINE_GUID lines of the headers named above.
pub const IID_IUnknown: GUID = GUID.parse("{00000000-0000-0000-C000-000000000046}");
pub const IID_IDXGIObject: GUID = GUID.parse("{aec22fb8-76f3-4639-9be0-28eb43a67a2e}");
pub const IID_IDXGIDevice: GUID = GUID.parse("{54ec77fa-1377-44e6-8c32-88fd5f44c84c}");
pub const IID_IDXGIAdapter: GUID = GUID.parse("{2411e7e1-12ac-4ccf-bd14-9798e8534dc0}");
pub const IID_IDXGIFactory2: GUID = GUID.parse("{50c83a1c-e072-4c48-87b0-3630fa36a6d0}");
pub const IID_IDXGIFactory5: GUID = GUID.parse("{7632e1f5-ee65-4dca-87fd-84cd75f8838d}");
pub const IID_IDXGISwapChain1: GUID = GUID.parse("{790a45f7-0d42-4876-983a-0a55cfe6f4aa}");
pub const IID_IDXGISwapChain2: GUID = GUID.parse("{a8be2ac4-199f-4946-b331-79599fb98de7}");
pub const IID_ID3D11Device: GUID = GUID.parse("{db6f6ddb-ac77-4e88-8253-819df9bbf140}");
pub const IID_ID3D11DeviceContext: GUID = GUID.parse("{c0bfa96c-e089-44fb-8eaf-26f8796190da}");
pub const IID_ID3D11Resource: GUID = GUID.parse("{dc8e63f3-d12b-4952-b47b-5e45026a862d}");
pub const IID_ID3D11Texture2D: GUID = GUID.parse("{6f15aaf2-d208-4e89-9ab4-489535d34f9c}");
pub const IID_ID3D11InfoQueue: GUID = GUID.parse("{6543dbb6-1b48-42f5-ab82-e97ec74326f6}");

// ---------------------------------------------------------------------------
// Enums and flags
//
// C enums are ints in these headers, so every enum is c_int-backed. Only the
// members the backend uses are named; the enums stay non-exhaustive because
// the runtime can hand back any value the header defines.

pub const DXGI_FORMAT = enum(c_int) {
    UNKNOWN = 0x0,
    R32G32B32A32_FLOAT = 0x2,
    R32G32_FLOAT = 0x10,
    R32G32_UINT = 0x11,
    R8G8B8A8_UNORM = 0x1c,
    R8G8B8A8_UNORM_SRGB = 0x1d,
    R8G8B8A8_UINT = 0x1e,
    R16G16_UINT = 0x24,
    R16G16_SINT = 0x26,
    R32_FLOAT = 0x29,
    R32_UINT = 0x2a,
    R8G8_UINT = 0x32,
    R8_UNORM = 0x3d,
    R8_UINT = 0x3e,
    B8G8R8A8_UNORM = 0x57,
    B8G8R8A8_TYPELESS = 0x5a,
    B8G8R8A8_UNORM_SRGB = 0x5b,
    _,
};

pub const DXGI_SWAP_EFFECT = enum(c_int) {
    FLIP_SEQUENTIAL = 3,
    FLIP_DISCARD = 4,
    _,
};

pub const DXGI_SCALING = enum(c_int) {
    STRETCH = 0,
    NONE = 1,
    _,
};

pub const DXGI_ALPHA_MODE = enum(c_int) {
    IGNORE = 3,
    _,
};

pub const DXGI_MODE_SCANLINE_ORDER = enum(c_int) { UNSPECIFIED = 0, _ };
pub const DXGI_MODE_SCALING = enum(c_int) { UNSPECIFIED = 0, _ };

pub const DXGI_FEATURE = enum(c_int) {
    PRESENT_ALLOW_TEARING = 0,
    _,
};

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;
pub const DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: UINT = 0x40;
pub const DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING: UINT = 0x800;
pub const DXGI_PRESENT_ALLOW_TEARING: UINT = 0x200;
pub const DXGI_MWA_NO_WINDOW_CHANGES: UINT = 0x1;
pub const DXGI_MWA_NO_ALT_ENTER: UINT = 0x2;

pub const D3D_DRIVER_TYPE = enum(c_int) {
    HARDWARE = 1,
    WARP = 5,
    _,
};

pub const D3D_FEATURE_LEVEL = enum(c_int) {
    @"10_1" = 0xa100,
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
    _,
};

pub const D3D11_SDK_VERSION: UINT = 7;
pub const D3D11_CREATE_DEVICE_SINGLETHREADED: UINT = 0x1;
pub const D3D11_CREATE_DEVICE_DEBUG: UINT = 0x2;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: UINT = 0x20;

pub const D3D11_USAGE = enum(c_int) {
    DEFAULT = 0,
    IMMUTABLE = 1,
    DYNAMIC = 2,
    _,
};

pub const D3D11_BIND_VERTEX_BUFFER: UINT = 0x1;
pub const D3D11_BIND_CONSTANT_BUFFER: UINT = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: UINT = 0x8;
pub const D3D11_BIND_RENDER_TARGET: UINT = 0x20;
pub const D3D11_CPU_ACCESS_WRITE: UINT = 0x10000;
pub const D3D11_RESOURCE_MISC_BUFFER_STRUCTURED: UINT = 0x40;

pub const D3D11_MAP = enum(c_int) {
    WRITE_DISCARD = 4,
    WRITE_NO_OVERWRITE = 5,
    _,
};

pub const D3D11_PRIMITIVE_TOPOLOGY = enum(c_int) {
    TRIANGLELIST = 4,
    TRIANGLESTRIP = 5,
    _,
};

pub const D3D11_RTV_DIMENSION = enum(c_int) {
    TEXTURE2D = 4,
    _,
};

pub const D3D11_SRV_DIMENSION = enum(c_int) {
    BUFFER = 1,
    TEXTURE2D = 4,
    BUFFEREX = 11,
    _,
};

pub const D3D11_FILTER = enum(c_int) {
    MIN_MAG_MIP_POINT = 0x0,
    MIN_MAG_MIP_LINEAR = 0x15,
    _,
};

pub const D3D11_TEXTURE_ADDRESS_MODE = enum(c_int) {
    CLAMP = 3,
    _,
};

pub const D3D11_COMPARISON_FUNC = enum(c_int) {
    NEVER = 1,
    _,
};

pub const D3D11_BLEND = enum(c_int) {
    ZERO = 1,
    ONE = 2,
    SRC_ALPHA = 5,
    INV_SRC_ALPHA = 6,
    _,
};

pub const D3D11_BLEND_OP = enum(c_int) {
    ADD = 1,
    _,
};

pub const D3D11_COLOR_WRITE_ENABLE_ALL: UINT8 = 0xf;

pub const D3D11_FILL_MODE = enum(c_int) {
    SOLID = 3,
    _,
};

pub const D3D11_CULL_MODE = enum(c_int) {
    NONE = 1,
    _,
};

pub const D3D11_INPUT_CLASSIFICATION = enum(c_int) {
    PER_VERTEX_DATA = 0,
    PER_INSTANCE_DATA = 1,
    _,
};

pub const D3D11_APPEND_ALIGNED_ELEMENT: UINT = 0xffffffff;

pub const D3D11_FEATURE = enum(c_int) {
    D3D11_OPTIONS = 5,
    _,
};

pub const D3D11_FLOAT32_MAX: FLOAT = 3.402823466e+38;

pub const D3D11_MESSAGE_CATEGORY = enum(c_int) { _ };
pub const D3D11_MESSAGE_SEVERITY = enum(c_int) {
    CORRUPTION = 0,
    ERROR = 1,
    WARNING = 2,
    INFO = 3,
    MESSAGE = 4,
    _,
};
pub const D3D11_MESSAGE_ID = enum(c_int) { _ };

pub const D3DCOMPILE_DEBUG: UINT = 0x1;
pub const D3DCOMPILE_SKIP_OPTIMIZATION: UINT = 0x4;
pub const D3DCOMPILE_PACK_MATRIX_ROW_MAJOR: UINT = 0x8;
pub const D3DCOMPILE_ENABLE_STRICTNESS: UINT = 0x800;
pub const D3DCOMPILE_OPTIMIZATION_LEVEL3: UINT = 0x8000;

// ---------------------------------------------------------------------------
// Structs

pub const DXGI_RATIONAL = extern struct {
    Numerator: UINT,
    Denominator: UINT,
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT,
    Quality: UINT,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: UINT,
    Height: UINT,
    Format: DXGI_FORMAT,
    Stereo: BOOL,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: UINT,
    BufferCount: UINT,
    Scaling: DXGI_SCALING,
    SwapEffect: DXGI_SWAP_EFFECT,
    AlphaMode: DXGI_ALPHA_MODE,
    Flags: UINT,
};

pub const DXGI_SWAP_CHAIN_FULLSCREEN_DESC = extern struct {
    RefreshRate: DXGI_RATIONAL,
    ScanlineOrdering: DXGI_MODE_SCANLINE_ORDER,
    Scaling: DXGI_MODE_SCALING,
    Windowed: BOOL,
};

pub const DXGI_ADAPTER_DESC = extern struct {
    Description: [128]WCHAR,
    VendorId: UINT,
    DeviceId: UINT,
    SubSysId: UINT,
    Revision: UINT,
    DedicatedVideoMemory: SIZE_T,
    DedicatedSystemMemory: SIZE_T,
    SharedSystemMemory: SIZE_T,
    AdapterLuid: LUID,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    MipLevels: UINT,
    ArraySize: UINT,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: D3D11_USAGE,
    BindFlags: UINT,
    CPUAccessFlags: UINT,
    MiscFlags: UINT,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: UINT,
    Usage: D3D11_USAGE,
    BindFlags: UINT,
    CPUAccessFlags: UINT,
    MiscFlags: UINT,
    StructureByteStride: UINT,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: ?*const anyopaque,
    SysMemPitch: UINT,
    SysMemSlicePitch: UINT,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: UINT,
    DepthPitch: UINT,
};

pub const D3D11_BUFFER_RTV = extern struct {
    FirstElement: UINT,
    NumElements: UINT,
};

pub const D3D11_TEX2D_RTV = extern struct {
    MipSlice: UINT,
};

pub const D3D11_RENDER_TARGET_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: D3D11_RTV_DIMENSION,
    u: extern union {
        Buffer: D3D11_BUFFER_RTV,
        Texture2D: D3D11_TEX2D_RTV,
        /// The widest members of the header's union (the array and 3D
        /// views) are three UINTs; this keeps the size without naming them.
        _widest: [3]UINT,
    },
};

/// The header spells this as two anonymous unions (FirstElement or
/// ElementOffset, NumElements or ElementWidth); each pair is one UINT.
pub const D3D11_BUFFER_SRV = extern struct {
    FirstElement: UINT,
    NumElements: UINT,
};

pub const D3D11_BUFFEREX_SRV = extern struct {
    FirstElement: UINT,
    NumElements: UINT,
    Flags: UINT,
};

pub const D3D11_TEX2D_SRV = extern struct {
    MostDetailedMip: UINT,
    MipLevels: UINT,
};

pub const D3D11_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: D3D11_SRV_DIMENSION,
    u: extern union {
        Buffer: D3D11_BUFFER_SRV,
        Texture2D: D3D11_TEX2D_SRV,
        BufferEx: D3D11_BUFFEREX_SRV,
        /// The widest members (the array and cube-array views) are four
        /// UINTs.
        _widest: [4]UINT,
    },
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: D3D11_FILTER,
    AddressU: D3D11_TEXTURE_ADDRESS_MODE,
    AddressV: D3D11_TEXTURE_ADDRESS_MODE,
    AddressW: D3D11_TEXTURE_ADDRESS_MODE,
    MipLODBias: FLOAT,
    MaxAnisotropy: UINT,
    ComparisonFunc: D3D11_COMPARISON_FUNC,
    BorderColor: [4]FLOAT,
    MinLOD: FLOAT,
    MaxLOD: FLOAT,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL,
    SrcBlend: D3D11_BLEND,
    DestBlend: D3D11_BLEND,
    BlendOp: D3D11_BLEND_OP,
    SrcBlendAlpha: D3D11_BLEND,
    DestBlendAlpha: D3D11_BLEND,
    BlendOpAlpha: D3D11_BLEND_OP,
    RenderTargetWriteMask: UINT8,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL,
    IndependentBlendEnable: BOOL,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC,
};

pub const D3D11_RASTERIZER_DESC = extern struct {
    FillMode: D3D11_FILL_MODE,
    CullMode: D3D11_CULL_MODE,
    FrontCounterClockwise: BOOL,
    DepthBias: INT,
    DepthBiasClamp: FLOAT,
    SlopeScaledDepthBias: FLOAT,
    DepthClipEnable: BOOL,
    ScissorEnable: BOOL,
    MultisampleEnable: BOOL,
    AntialiasedLineEnable: BOOL,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: LPCSTR,
    SemanticIndex: UINT,
    Format: DXGI_FORMAT,
    InputSlot: UINT,
    AlignedByteOffset: UINT,
    InputSlotClass: D3D11_INPUT_CLASSIFICATION,
    InstanceDataStepRate: UINT,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: FLOAT,
    TopLeftY: FLOAT,
    Width: FLOAT,
    Height: FLOAT,
    MinDepth: FLOAT,
    MaxDepth: FLOAT,
};

pub const D3D11_BOX = extern struct {
    left: UINT,
    top: UINT,
    front: UINT,
    right: UINT,
    bottom: UINT,
    back: UINT,
};

pub const D3D11_MESSAGE = extern struct {
    Category: D3D11_MESSAGE_CATEGORY,
    Severity: D3D11_MESSAGE_SEVERITY,
    ID: D3D11_MESSAGE_ID,
    pDescription: ?[*]const u8,
    DescriptionByteLength: SIZE_T,
};

pub const D3D_SHADER_MACRO = extern struct {
    Name: ?LPCSTR,
    Definition: ?LPCSTR,
};

// ---------------------------------------------------------------------------
// COM helpers

/// Any COM object pointer viewed through its IUnknown prefix.
pub inline fn unknown(obj: anytype) *IUnknown {
    return @ptrCast(obj);
}

/// Drops one reference. COM returns the remaining count, which nothing
/// here needs.
pub fn release(obj: anytype) void {
    const u = unknown(obj);
    _ = u.vtable.Release(u);
}

pub const QueryInterfaceError = error{QueryInterfaceFailed};

/// QueryInterface for `T`, which must carry its IID as `T.IID`. The
/// returned reference is owned by the caller.
pub fn queryInterface(obj: anytype, comptime T: type) QueryInterfaceError!*T {
    const u = unknown(obj);
    var out: ?*anyopaque = null;
    if (failed(u.vtable.QueryInterface(u, &T.IID, &out))) return error.QueryInterfaceFailed;
    return @ptrCast(@alignCast(out orelse return error.QueryInterfaceFailed));
}

/// An untyped vtable slot. The backend never calls it, but it has to be
/// there so the slots after it keep their index.
const Slot = *const anyopaque;

// ---------------------------------------------------------------------------
// Interfaces
//
// Parameter names follow the headers. Interfaces that the backend only ever
// receives as opaque pointers are declared opaque.

pub const IDXGIOutput = opaque {};
pub const ID3D11ClassLinkage = opaque {};
pub const ID3D11ClassInstance = opaque {};
pub const ID3D11DepthStencilView = opaque {};
pub const ID3DInclude = opaque {};

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IUnknown;

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, REFIID, *?*anyopaque) callconv(cc) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(cc) ULONG,
        Release: *const fn (*IUnknown) callconv(cc) ULONG,
    };
};

pub const IDXGIObject = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGIObject;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetPrivateData: Slot,
        GetParent: *const fn (*IDXGIObject, REFIID, *?*anyopaque) callconv(cc) HRESULT,
    };

    /// The parent object as `T`, owned by the caller.
    pub fn getParent(self: *IDXGIObject, comptime T: type) QueryInterfaceError!*T {
        var out: ?*anyopaque = null;
        if (failed(self.vtable.GetParent(self, &T.IID, &out))) return error.QueryInterfaceFailed;
        return @ptrCast(@alignCast(out orelse return error.QueryInterfaceFailed));
    }
};

pub const IDXGIDeviceSubObject = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        GetDevice: Slot,
    };
};

pub const IDXGIAdapter = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGIAdapter;

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        EnumOutputs: Slot,
        GetDesc: *const fn (*IDXGIAdapter, *DXGI_ADAPTER_DESC) callconv(cc) HRESULT,
        CheckInterfaceSupport: Slot,
    };

    pub fn getParent(self: *IDXGIAdapter, comptime T: type) QueryInterfaceError!*T {
        return @as(*IDXGIObject, @ptrCast(self)).getParent(T);
    }
};

pub const IDXGIDevice = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGIDevice;

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        GetAdapter: *const fn (*IDXGIDevice, *?*IDXGIAdapter) callconv(cc) HRESULT,
        CreateSurface: Slot,
        QueryResourceResidency: Slot,
        SetGPUThreadPriority: Slot,
        GetGPUThreadPriority: Slot,
    };
};

pub const IDXGIFactory = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        EnumAdapters: Slot,
        MakeWindowAssociation: *const fn (*IDXGIFactory, HWND, UINT) callconv(cc) HRESULT,
        GetWindowAssociation: Slot,
        CreateSwapChain: Slot,
        CreateSoftwareAdapter: Slot,
    };
};

pub const IDXGIFactory1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IDXGIFactory.VTable,
        EnumAdapters1: Slot,
        IsCurrent: Slot,
    };
};

pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGIFactory2;

    pub const VTable = extern struct {
        base: IDXGIFactory1.VTable,
        IsWindowedStereoEnabled: Slot,
        CreateSwapChainForHwnd: *const fn (
            *IDXGIFactory2,
            *IUnknown,
            HWND,
            *const DXGI_SWAP_CHAIN_DESC1,
            ?*const DXGI_SWAP_CHAIN_FULLSCREEN_DESC,
            ?*IDXGIOutput,
            *?*IDXGISwapChain1,
        ) callconv(cc) HRESULT,
        CreateSwapChainForCoreWindow: Slot,
        GetSharedResourceAdapterLuid: Slot,
        RegisterStereoStatusWindow: Slot,
        RegisterStereoStatusEvent: Slot,
        UnregisterStereoStatus: Slot,
        RegisterOcclusionStatusWindow: Slot,
        RegisterOcclusionStatusEvent: Slot,
        UnregisterOcclusionStatus: Slot,
        CreateSwapChainForComposition: Slot,
    };

    pub fn makeWindowAssociation(self: *IDXGIFactory2, hwnd: HWND, flags: UINT) HRESULT {
        return self.vtable.base.base.MakeWindowAssociation(@ptrCast(self), hwnd, flags);
    }
};

pub const IDXGIFactory3 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IDXGIFactory2.VTable,
        GetCreationFlags: Slot,
    };
};

pub const IDXGIFactory4 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IDXGIFactory3.VTable,
        EnumAdapterByLuid: Slot,
        EnumWarpAdapter: Slot,
    };
};

pub const IDXGIFactory5 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGIFactory5;

    pub const VTable = extern struct {
        base: IDXGIFactory4.VTable,
        CheckFeatureSupport: *const fn (*IDXGIFactory5, DXGI_FEATURE, *anyopaque, UINT) callconv(cc) HRESULT,
    };
};

pub const IDXGISwapChain = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IDXGIDeviceSubObject.VTable,
        Present: *const fn (*IDXGISwapChain, UINT, UINT) callconv(cc) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain, UINT, REFIID, *?*anyopaque) callconv(cc) HRESULT,
        SetFullscreenState: Slot,
        GetFullscreenState: Slot,
        GetDesc: Slot,
        ResizeBuffers: *const fn (*IDXGISwapChain, UINT, UINT, UINT, DXGI_FORMAT, UINT) callconv(cc) HRESULT,
        ResizeTarget: Slot,
        GetContainingOutput: Slot,
        GetFrameStatistics: Slot,
        GetLastPresentCount: Slot,
    };
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGISwapChain1;

    pub const VTable = extern struct {
        base: IDXGISwapChain.VTable,
        GetDesc1: *const fn (*IDXGISwapChain1, *DXGI_SWAP_CHAIN_DESC1) callconv(cc) HRESULT,
        GetFullscreenDesc: Slot,
        GetHwnd: Slot,
        GetCoreWindow: Slot,
        Present1: Slot,
        IsTemporaryMonoSupported: Slot,
        GetRestrictToOutput: Slot,
        SetBackgroundColor: Slot,
        GetBackgroundColor: Slot,
        SetRotation: Slot,
        GetRotation: Slot,
    };

    pub fn present(self: *IDXGISwapChain1, sync_interval: UINT, flags: UINT) HRESULT {
        return self.vtable.base.Present(@ptrCast(self), sync_interval, flags);
    }

    /// Back buffer `index` as `T`, owned by the caller.
    pub fn getBuffer(self: *IDXGISwapChain1, index: UINT, comptime T: type) QueryInterfaceError!*T {
        var out: ?*anyopaque = null;
        if (failed(self.vtable.base.GetBuffer(@ptrCast(self), index, &T.IID, &out))) return error.QueryInterfaceFailed;
        return @ptrCast(@alignCast(out orelse return error.QueryInterfaceFailed));
    }

    pub fn resizeBuffers(self: *IDXGISwapChain1, buffer_count: UINT, width: UINT, height: UINT, format: DXGI_FORMAT, flags: UINT) HRESULT {
        return self.vtable.base.ResizeBuffers(@ptrCast(self), buffer_count, width, height, format, flags);
    }

    pub fn getDesc1(self: *IDXGISwapChain1, desc: *DXGI_SWAP_CHAIN_DESC1) HRESULT {
        return self.vtable.GetDesc1(self, desc);
    }
};

pub const IDXGISwapChain2 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_IDXGISwapChain2;

    pub const VTable = extern struct {
        base: IDXGISwapChain1.VTable,
        SetSourceSize: Slot,
        GetSourceSize: Slot,
        SetMaximumFrameLatency: *const fn (*IDXGISwapChain2, UINT) callconv(cc) HRESULT,
        GetMaximumFrameLatency: Slot,
        GetFrameLatencyWaitableObject: *const fn (*IDXGISwapChain2) callconv(cc) HANDLE,
        SetMatrixTransform: Slot,
        GetMatrixTransform: Slot,
    };
};

pub const ID3D11DeviceChild = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetDevice: Slot,
        GetPrivateData: Slot,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
    };
};

pub const ID3D11Resource = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ID3D11Resource;

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetType: Slot,
        SetEvictionPriority: Slot,
        GetEvictionPriority: Slot,
    };
};

pub const ID3D11Texture2D = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ID3D11Texture2D;

    pub const VTable = extern struct {
        base: ID3D11Resource.VTable,
        GetDesc: *const fn (*ID3D11Texture2D, *D3D11_TEXTURE2D_DESC) callconv(cc) void,
    };

    pub inline fn resource(self: *ID3D11Texture2D) *ID3D11Resource {
        return @ptrCast(self);
    }
};

pub const ID3D11Buffer = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11Resource.VTable,
        GetDesc: *const fn (*ID3D11Buffer, *D3D11_BUFFER_DESC) callconv(cc) void,
    };

    pub inline fn resource(self: *ID3D11Buffer) *ID3D11Resource {
        return @ptrCast(self);
    }
};

pub const ID3D11View = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetResource: Slot,
    };
};

pub const ID3D11RenderTargetView = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11View.VTable,
        GetDesc: Slot,
    };
};

pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11View.VTable,
        GetDesc: Slot,
    };
};

pub const ID3D11SamplerState = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetDesc: Slot,
    };
};

pub const ID3D11BlendState = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetDesc: Slot,
    };
};

pub const ID3D11RasterizerState = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        GetDesc: Slot,
    };
};

pub const ID3D11InputLayout = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

pub const ID3D11VertexShader = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

pub const ID3D11PixelShader = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ID3D11Device;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        CreateBuffer: *const fn (*ID3D11Device, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(cc) HRESULT,
        CreateTexture1D: Slot,
        CreateTexture2D: *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(cc) HRESULT,
        CreateTexture3D: Slot,
        CreateShaderResourceView: *const fn (*ID3D11Device, *ID3D11Resource, ?*const D3D11_SHADER_RESOURCE_VIEW_DESC, *?*ID3D11ShaderResourceView) callconv(cc) HRESULT,
        CreateUnorderedAccessView: Slot,
        CreateRenderTargetView: *const fn (*ID3D11Device, *ID3D11Resource, ?*const D3D11_RENDER_TARGET_VIEW_DESC, *?*ID3D11RenderTargetView) callconv(cc) HRESULT,
        CreateDepthStencilView: Slot,
        CreateInputLayout: *const fn (*ID3D11Device, [*]const D3D11_INPUT_ELEMENT_DESC, UINT, *const anyopaque, SIZE_T, *?*ID3D11InputLayout) callconv(cc) HRESULT,
        CreateVertexShader: *const fn (*ID3D11Device, *const anyopaque, SIZE_T, ?*ID3D11ClassLinkage, *?*ID3D11VertexShader) callconv(cc) HRESULT,
        CreateGeometryShader: Slot,
        CreateGeometryShaderWithStreamOutput: Slot,
        CreatePixelShader: *const fn (*ID3D11Device, *const anyopaque, SIZE_T, ?*ID3D11ClassLinkage, *?*ID3D11PixelShader) callconv(cc) HRESULT,
        CreateHullShader: Slot,
        CreateDomainShader: Slot,
        CreateComputeShader: Slot,
        CreateClassLinkage: Slot,
        CreateBlendState: *const fn (*ID3D11Device, *const D3D11_BLEND_DESC, *?*ID3D11BlendState) callconv(cc) HRESULT,
        CreateDepthStencilState: Slot,
        CreateRasterizerState: *const fn (*ID3D11Device, *const D3D11_RASTERIZER_DESC, *?*ID3D11RasterizerState) callconv(cc) HRESULT,
        CreateSamplerState: *const fn (*ID3D11Device, *const D3D11_SAMPLER_DESC, *?*ID3D11SamplerState) callconv(cc) HRESULT,
        CreateQuery: Slot,
        CreatePredicate: Slot,
        CreateCounter: Slot,
        CreateDeferredContext: Slot,
        OpenSharedResource: Slot,
        CheckFormatSupport: Slot,
        CheckMultisampleQualityLevels: Slot,
        CheckCounterInfo: Slot,
        CheckCounter: Slot,
        CheckFeatureSupport: *const fn (*ID3D11Device, D3D11_FEATURE, *anyopaque, UINT) callconv(cc) HRESULT,
        GetPrivateData: Slot,
        SetPrivateData: Slot,
        SetPrivateDataInterface: Slot,
        GetFeatureLevel: *const fn (*ID3D11Device) callconv(cc) D3D_FEATURE_LEVEL,
        GetCreationFlags: Slot,
        GetDeviceRemovedReason: *const fn (*ID3D11Device) callconv(cc) HRESULT,
        GetImmediateContext: *const fn (*ID3D11Device, *?*ID3D11DeviceContext) callconv(cc) void,
        SetExceptionMode: Slot,
        GetExceptionMode: Slot,
    };
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ID3D11DeviceContext;

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
        VSSetConstantBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(cc) void,
        PSSetShaderResources: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11ShaderResourceView) callconv(cc) void,
        PSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, ?[*]const *ID3D11ClassInstance, UINT) callconv(cc) void,
        PSSetSamplers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11SamplerState) callconv(cc) void,
        VSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, ?[*]const *ID3D11ClassInstance, UINT) callconv(cc) void,
        DrawIndexed: Slot,
        Draw: Slot,
        Map: *const fn (*ID3D11DeviceContext, *ID3D11Resource, UINT, D3D11_MAP, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(cc) HRESULT,
        Unmap: *const fn (*ID3D11DeviceContext, *ID3D11Resource, UINT) callconv(cc) void,
        PSSetConstantBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(cc) void,
        IASetInputLayout: *const fn (*ID3D11DeviceContext, ?*ID3D11InputLayout) callconv(cc) void,
        IASetVertexBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11Buffer, [*]const UINT, [*]const UINT) callconv(cc) void,
        IASetIndexBuffer: Slot,
        DrawIndexedInstanced: Slot,
        DrawInstanced: *const fn (*ID3D11DeviceContext, UINT, UINT, UINT, UINT) callconv(cc) void,
        GSSetConstantBuffers: Slot,
        GSSetShader: Slot,
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, D3D11_PRIMITIVE_TOPOLOGY) callconv(cc) void,
        VSSetShaderResources: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11ShaderResourceView) callconv(cc) void,
        VSSetSamplers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11SamplerState) callconv(cc) void,
        Begin: Slot,
        End: Slot,
        GetData: Slot,
        SetPredication: Slot,
        GSSetShaderResources: Slot,
        GSSetSamplers: Slot,
        OMSetRenderTargets: *const fn (*ID3D11DeviceContext, UINT, ?[*]const ?*ID3D11RenderTargetView, ?*ID3D11DepthStencilView) callconv(cc) void,
        OMSetRenderTargetsAndUnorderedAccessViews: Slot,
        OMSetBlendState: *const fn (*ID3D11DeviceContext, ?*ID3D11BlendState, ?*const [4]FLOAT, UINT) callconv(cc) void,
        OMSetDepthStencilState: Slot,
        SOSetTargets: Slot,
        DrawAuto: Slot,
        DrawIndexedInstancedIndirect: Slot,
        DrawInstancedIndirect: Slot,
        Dispatch: Slot,
        DispatchIndirect: Slot,
        RSSetState: *const fn (*ID3D11DeviceContext, ?*ID3D11RasterizerState) callconv(cc) void,
        RSSetViewports: *const fn (*ID3D11DeviceContext, UINT, [*]const D3D11_VIEWPORT) callconv(cc) void,
        RSSetScissorRects: Slot,
        CopySubresourceRegion: *const fn (*ID3D11DeviceContext, *ID3D11Resource, UINT, UINT, UINT, UINT, *ID3D11Resource, UINT, ?*const D3D11_BOX) callconv(cc) void,
        CopyResource: *const fn (*ID3D11DeviceContext, *ID3D11Resource, *ID3D11Resource) callconv(cc) void,
        UpdateSubresource: *const fn (*ID3D11DeviceContext, *ID3D11Resource, UINT, ?*const D3D11_BOX, *const anyopaque, UINT, UINT) callconv(cc) void,
        CopyStructureCount: Slot,
        ClearRenderTargetView: *const fn (*ID3D11DeviceContext, *ID3D11RenderTargetView, *const [4]FLOAT) callconv(cc) void,
        ClearUnorderedAccessViewUint: Slot,
        ClearUnorderedAccessViewFloat: Slot,
        ClearDepthStencilView: Slot,
        GenerateMips: Slot,
        SetResourceMinLOD: Slot,
        GetResourceMinLOD: Slot,
        ResolveSubresource: Slot,
        ExecuteCommandList: Slot,
        HSSetShaderResources: Slot,
        HSSetShader: Slot,
        HSSetSamplers: Slot,
        HSSetConstantBuffers: Slot,
        DSSetShaderResources: Slot,
        DSSetShader: Slot,
        DSSetSamplers: Slot,
        DSSetConstantBuffers: Slot,
        CSSetShaderResources: Slot,
        CSSetUnorderedAccessViews: Slot,
        CSSetShader: Slot,
        CSSetSamplers: Slot,
        CSSetConstantBuffers: Slot,
        VSGetConstantBuffers: Slot,
        PSGetShaderResources: Slot,
        PSGetShader: Slot,
        PSGetSamplers: Slot,
        VSGetShader: Slot,
        PSGetConstantBuffers: Slot,
        IAGetInputLayout: Slot,
        IAGetVertexBuffers: Slot,
        IAGetIndexBuffer: Slot,
        GSGetConstantBuffers: Slot,
        GSGetShader: Slot,
        IAGetPrimitiveTopology: Slot,
        VSGetShaderResources: Slot,
        VSGetSamplers: Slot,
        GetPredication: Slot,
        GSGetShaderResources: Slot,
        GSGetSamplers: Slot,
        OMGetRenderTargets: Slot,
        OMGetRenderTargetsAndUnorderedAccessViews: Slot,
        OMGetBlendState: Slot,
        OMGetDepthStencilState: Slot,
        SOGetTargets: Slot,
        RSGetState: Slot,
        RSGetViewports: Slot,
        RSGetScissorRects: Slot,
        HSGetShaderResources: Slot,
        HSGetShader: Slot,
        HSGetSamplers: Slot,
        HSGetConstantBuffers: Slot,
        DSGetShaderResources: Slot,
        DSGetShader: Slot,
        DSGetSamplers: Slot,
        DSGetConstantBuffers: Slot,
        CSGetShaderResources: Slot,
        CSGetUnorderedAccessViews: Slot,
        CSGetShader: Slot,
        CSGetSamplers: Slot,
        CSGetConstantBuffers: Slot,
        ClearState: *const fn (*ID3D11DeviceContext) callconv(cc) void,
        Flush: *const fn (*ID3D11DeviceContext) callconv(cc) void,
        GetType: Slot,
        GetContextFlags: Slot,
        FinishCommandList: Slot,
    };
};

pub const ID3D11InfoQueue = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ID3D11InfoQueue;

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetMessageCountLimit: Slot,
        ClearStoredMessages: *const fn (*ID3D11InfoQueue) callconv(cc) void,
        GetMessage: *const fn (*ID3D11InfoQueue, UINT64, ?*D3D11_MESSAGE, *SIZE_T) callconv(cc) HRESULT,
        GetNumMessagesAllowedByStorageFilter: Slot,
        GetNumMessagesDeniedByStorageFilter: Slot,
        GetNumStoredMessages: *const fn (*ID3D11InfoQueue) callconv(cc) UINT64,
        GetNumStoredMessagesAllowedByRetrievalFilter: Slot,
        GetNumMessagesDiscardedByMessageCountLimit: Slot,
        GetMessageCountLimit: Slot,
        AddStorageFilterEntries: Slot,
        GetStorageFilter: Slot,
        ClearStorageFilter: Slot,
        PushEmptyStorageFilter: Slot,
        PushCopyOfStorageFilter: Slot,
        PushStorageFilter: Slot,
        PopStorageFilter: Slot,
        GetStorageFilterStackSize: Slot,
        AddRetrievalFilterEntries: Slot,
        GetRetrievalFilter: Slot,
        ClearRetrievalFilter: Slot,
        PushEmptyRetrievalFilter: Slot,
        PushCopyOfRetrievalFilter: Slot,
        PushRetrievalFilter: Slot,
        PopRetrievalFilter: Slot,
        GetRetrievalFilterStackSize: Slot,
        AddMessage: Slot,
        AddApplicationMessage: Slot,
        SetBreakOnCategory: Slot,
        SetBreakOnSeverity: Slot,
        SetBreakOnID: Slot,
        GetBreakOnCategory: Slot,
        GetBreakOnSeverity: Slot,
        GetBreakOnID: Slot,
        SetMuteDebugOutput: *const fn (*ID3D11InfoQueue, BOOL) callconv(cc) void,
        GetMuteDebugOutput: Slot,
    };
};

/// ID3DBlob is an alias for ID3D10Blob in the headers.
pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(cc) *anyopaque,
        GetBufferSize: *const fn (*ID3DBlob) callconv(cc) SIZE_T,
    };

    /// The blob's bytes, valid for as long as the blob is alive.
    pub fn bytes(self: *ID3DBlob) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self.vtable.GetBufferPointer(self));
        return ptr[0..self.vtable.GetBufferSize(self)];
    }
};

/// D3DCompile from d3dcompiler_47.dll, which the backend resolves at
/// runtime with GetProcAddress so that a missing DLL is an init error
/// rather than a process-start failure.
pub const D3DCompileFn = *const fn (
    data: *const anyopaque,
    data_size: SIZE_T,
    filename: ?LPCSTR,
    defines: ?[*]const D3D_SHADER_MACRO,
    include: ?*ID3DInclude,
    entrypoint: LPCSTR,
    target: LPCSTR,
    sflags: UINT,
    eflags: UINT,
    shader: *?*ID3DBlob,
    error_messages: ?*?*ID3DBlob,
) callconv(cc) HRESULT;

// ---------------------------------------------------------------------------
// Layout tests
//
// Slot counts are the number of methods in each interface's C vtable in the
// headers named at the top, IUnknown's three included; struct sizes are the
// header's on a 64-bit target.

test "d3d11 api: vtable slot counts" {
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @sizeOf(IUnknown.VTable));
    try testing.expectEqual(7 * p, @sizeOf(IDXGIObject.VTable));
    try testing.expectEqual(8 * p, @sizeOf(IDXGIDeviceSubObject.VTable));
    try testing.expectEqual(10 * p, @sizeOf(IDXGIAdapter.VTable));
    try testing.expectEqual(12 * p, @sizeOf(IDXGIDevice.VTable));
    try testing.expectEqual(12 * p, @sizeOf(IDXGIFactory.VTable));
    try testing.expectEqual(14 * p, @sizeOf(IDXGIFactory1.VTable));
    try testing.expectEqual(25 * p, @sizeOf(IDXGIFactory2.VTable));
    try testing.expectEqual(26 * p, @sizeOf(IDXGIFactory3.VTable));
    try testing.expectEqual(28 * p, @sizeOf(IDXGIFactory4.VTable));
    try testing.expectEqual(29 * p, @sizeOf(IDXGIFactory5.VTable));
    try testing.expectEqual(18 * p, @sizeOf(IDXGISwapChain.VTable));
    try testing.expectEqual(29 * p, @sizeOf(IDXGISwapChain1.VTable));
    try testing.expectEqual(36 * p, @sizeOf(IDXGISwapChain2.VTable));
    try testing.expectEqual(7 * p, @sizeOf(ID3D11DeviceChild.VTable));
    try testing.expectEqual(10 * p, @sizeOf(ID3D11Resource.VTable));
    try testing.expectEqual(11 * p, @sizeOf(ID3D11Texture2D.VTable));
    try testing.expectEqual(11 * p, @sizeOf(ID3D11Buffer.VTable));
    try testing.expectEqual(8 * p, @sizeOf(ID3D11View.VTable));
    try testing.expectEqual(9 * p, @sizeOf(ID3D11RenderTargetView.VTable));
    try testing.expectEqual(9 * p, @sizeOf(ID3D11ShaderResourceView.VTable));
    try testing.expectEqual(8 * p, @sizeOf(ID3D11SamplerState.VTable));
    try testing.expectEqual(8 * p, @sizeOf(ID3D11BlendState.VTable));
    try testing.expectEqual(8 * p, @sizeOf(ID3D11RasterizerState.VTable));
    try testing.expectEqual(7 * p, @sizeOf(ID3D11InputLayout.VTable));
    try testing.expectEqual(7 * p, @sizeOf(ID3D11VertexShader.VTable));
    try testing.expectEqual(7 * p, @sizeOf(ID3D11PixelShader.VTable));
    try testing.expectEqual(43 * p, @sizeOf(ID3D11Device.VTable));
    try testing.expectEqual(115 * p, @sizeOf(ID3D11DeviceContext.VTable));
    try testing.expectEqual(38 * p, @sizeOf(ID3D11InfoQueue.VTable));
    try testing.expectEqual(5 * p, @sizeOf(ID3DBlob.VTable));
}

test "d3d11 api: typed slot indices" {
    // A typed slot that drifted by one would still pass the size test, so
    // the slots the backend calls most are pinned by index as well.
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(3 * p, @offsetOf(ID3D11Device.VTable, "CreateBuffer"));
    try testing.expectEqual(5 * p, @offsetOf(ID3D11Device.VTable, "CreateTexture2D"));
    try testing.expectEqual(9 * p, @offsetOf(ID3D11Device.VTable, "CreateRenderTargetView"));
    try testing.expectEqual(40 * p, @offsetOf(ID3D11Device.VTable, "GetImmediateContext"));
    try testing.expectEqual(7 * p, @offsetOf(ID3D11DeviceContext.VTable, "VSSetConstantBuffers"));
    try testing.expectEqual(14 * p, @offsetOf(ID3D11DeviceContext.VTable, "Map"));
    try testing.expectEqual(21 * p, @offsetOf(ID3D11DeviceContext.VTable, "DrawInstanced"));
    try testing.expectEqual(33 * p, @offsetOf(ID3D11DeviceContext.VTable, "OMSetRenderTargets"));
    try testing.expectEqual(47 * p, @offsetOf(ID3D11DeviceContext.VTable, "CopyResource"));
    try testing.expectEqual(50 * p, @offsetOf(ID3D11DeviceContext.VTable, "ClearRenderTargetView"));
    try testing.expectEqual(110 * p, @offsetOf(ID3D11DeviceContext.VTable, "ClearState"));
    try testing.expectEqual(8 * p, @offsetOf(IDXGISwapChain.VTable, "Present"));
    try testing.expectEqual(13 * p, @offsetOf(IDXGISwapChain.VTable, "ResizeBuffers"));
    try testing.expectEqual(18 * p, @offsetOf(IDXGISwapChain1.VTable, "GetDesc1"));
    try testing.expectEqual(15 * p, @offsetOf(IDXGIFactory2.VTable, "CreateSwapChainForHwnd"));
}

test "d3d11 api: struct layouts" {
    const testing = std.testing;
    try testing.expectEqual(48, @sizeOf(DXGI_SWAP_CHAIN_DESC1));
    try testing.expectEqual(20, @sizeOf(DXGI_SWAP_CHAIN_FULLSCREEN_DESC));
    try testing.expectEqual(304, @sizeOf(DXGI_ADAPTER_DESC));
    try testing.expectEqual(44, @sizeOf(D3D11_TEXTURE2D_DESC));
    try testing.expectEqual(24, @sizeOf(D3D11_BUFFER_DESC));
    try testing.expectEqual(16, @sizeOf(D3D11_SUBRESOURCE_DATA));
    try testing.expectEqual(16, @sizeOf(D3D11_MAPPED_SUBRESOURCE));
    try testing.expectEqual(8, @offsetOf(D3D11_MAPPED_SUBRESOURCE, "RowPitch"));
    try testing.expectEqual(20, @sizeOf(D3D11_RENDER_TARGET_VIEW_DESC));
    try testing.expectEqual(24, @sizeOf(D3D11_SHADER_RESOURCE_VIEW_DESC));
    try testing.expectEqual(52, @sizeOf(D3D11_SAMPLER_DESC));
    try testing.expectEqual(32, @sizeOf(D3D11_RENDER_TARGET_BLEND_DESC));
    try testing.expectEqual(264, @sizeOf(D3D11_BLEND_DESC));
    try testing.expectEqual(40, @sizeOf(D3D11_RASTERIZER_DESC));
    try testing.expectEqual(32, @sizeOf(D3D11_INPUT_ELEMENT_DESC));
    try testing.expectEqual(24, @sizeOf(D3D11_VIEWPORT));
    try testing.expectEqual(24, @sizeOf(D3D11_BOX));
    try testing.expectEqual(32, @sizeOf(D3D11_MESSAGE));
    try testing.expectEqual(16, @offsetOf(D3D11_MESSAGE, "pDescription"));
}

test "d3d11 api: iids and hresults" {
    const testing = std.testing;
    try testing.expectEqual(0xdb6f6ddb, IID_ID3D11Device.Data1);
    try testing.expectEqual(0xac77, IID_ID3D11Device.Data2);
    try testing.expectEqual(0x40, IID_ID3D11Device.Data4[7]);
    try testing.expectEqual(0x46, IID_IUnknown.Data4[7]);
    try testing.expect(failed(DXGI_ERROR_DEVICE_REMOVED));
    try testing.expect(failed(E_FAIL));
    try testing.expect(succeeded(S_OK));
    try testing.expect(succeeded(S_FALSE));
    try testing.expect(succeeded(DXGI_STATUS_OCCLUDED));
}
