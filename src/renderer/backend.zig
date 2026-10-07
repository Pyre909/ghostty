const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    d3d11,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        _ = wasm_target;
        if (target.os.tag.isDarwin()) return .metal;

        // OpenGL on Windows would need EGL; every Windows runtime gives
        // the renderer a window for a Direct3D 11 swap chain instead.
        if (target.os.tag == .windows) return .d3d11;

        return .opengl;
    }
};
