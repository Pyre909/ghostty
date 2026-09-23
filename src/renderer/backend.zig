const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;
const Runtime = @import("../apprt/runtime.zig").Runtime;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    webgl,
    d3d11,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
        runtime: Runtime,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.os.tag.isDarwin()) return .metal;

        // The Win32 runtime hands the renderer a window. The embedded
        // runtime, which the library builds with, has none to give a
        // swap chain, so on Windows it keeps the OpenGL backend.
        if (runtime == .windows) return .d3d11;

        return .opengl;
    }
};
