// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
//
// This currently isn't supported as a general purpose embedding API.
// This is currently used only to embed ghostty within a macOS app. However,
// it could be expanded to be general purpose in the future.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const posix = std.posix;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const main = @import("main_ghostty.zig");
const global = @import("global.zig");
const apprt = @import("apprt.zig");
const internal_os = @import("os/main.zig");
const windows = @import("os/windows.zig");

// Some comptime assertions that our C API depends on.
comptime {
    // We allow tests to reference this file because we unit test
    // some of the C API. At runtime though we should never get these
    // functions unless we are building libghostty.
    if (!builtin.is_test) {
        assert(apprt.runtime == apprt.embedded);
    }
}

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

comptime {
    // These structs need to be referenced so the `export` functions
    // are truly exported by the C API lib.

    // Our config API
    _ = @import("config.zig").CApi;

    // Any apprt-specific C API, mainly libghostty for apprt.embedded.
    if (@hasDecl(apprt.runtime, "CAPI")) _ = apprt.runtime.CAPI;

    // Our benchmark API. We probably want to gate this on a build
    // config in the future but for now we always just export it.
    _ = @import("benchmark/main.zig").CApi;

    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

/// ghostty_info_s
const Info = extern struct {
    mode: BuildMode,
    version: [*]const u8,
    version_len: usize,

    const BuildMode = enum(c_int) {
        debug,
        release_safe,
        release_fast,
        release_small,
    };
};

/// ghostty_string_s
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
    sentinel: bool,

    pub const empty: String = .{
        .ptr = null,
        .len = 0,
        .sentinel = false,
    };

    pub fn fromSlice(slice: anytype) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
            .sentinel = sentinel: {
                const info = @typeInfo(@TypeOf(slice));
                switch (info) {
                    .pointer => |p| {
                        if (p.size != .slice) @compileError("only slices supported");
                        if (p.child != u8) @compileError("only u8 slices supported");
                        const sentinel_ = p.sentinel();
                        if (sentinel_) |sentinel| if (sentinel != 0) @compileError("only 0 is supported for sentinels");
                        break :sentinel sentinel_ != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }

    pub fn deinit(self: *const String) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            global.alloc().free(ptr[0..self.len :0]);
        } else {
            global.alloc().free(ptr[0..self.len]);
        }
    }
};

// Global state initialization. ghostty_init takes a C argv and exists on
// every target but Windows; ghostty_init_wtf16 is its Windows counterpart,
// because std's arguments there are a WTF-16 command line that a C argv
// cannot carry. Exporting each only where it works makes the wrong one a
// link error rather than a runtime failure.
const NotWindows = struct {
    /// Initialize ghostty global state.
    export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
        return initC(argv[0..argc]);
    }
};

const Windows = struct {
    /// Initialize ghostty global state on Windows. `cmdline` is a WTF-16
    /// command line of `len` code units, parsed like the one std reads
    /// for an executable; pass GetCommandLineW() to give ghostty the
    /// host process's arguments. The buffer is not copied: ghostty reads
    /// it again later (for example in ghostty_config_load_cli_args), so
    /// it must stay valid and unchanged for the life of the process, as
    /// GetCommandLineW()'s does.
    export fn ghostty_init_wtf16(cmdline: [*]const u16, len: usize) c_int {
        // The MSVC arm of DllMain below (upstream's) runs no C++ global
        // constructors and sets up no onexit table, so simdutf, glslang and
        // spirv-cross would fault later; refuse rather than crash. A static
        // library linked into an MSVC program gets both from the program's
        // own CRT startup, so only the DLL is refused. Nothing can be logged
        // yet: logging needs the global state initC sets up. Revisit with
        // the Zig 0.17 port, which changes how the DLL entry point is chosen.
        if (comptime builtin.target.abi == .msvc and is_dll) return 1;

        const rc = initC(cmdline[0..len]);
        if (comptime is_dll) {
            if (rc == 0) pin();
        }
        return rc;
    }

    const is_dll = builtin.output_mode == .Lib and builtin.link_mode == .dynamic;

    /// Any address inside this module, for GetModuleHandleExW.
    const anchor: u16 = 0;

    /// Keep this DLL loaded until the process ends. A FreeLibrary would
    /// otherwise unmap it under ghostty's threads, among them detached ones
    /// that are never joined (the font discovery warmup, URL opening), and
    /// DLL_PROCESS_DETACH first runs the C++ static destructors that those
    /// threads may still use. Pinned, the DLL is detached only at process
    /// exit, after Windows has ended the other threads.
    fn pin() void {
        var module: ?windows.HMODULE = null;
        if (!windows.exp.kernel32.GetModuleHandleExW(
            windows.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                windows.GET_MODULE_HANDLE_EX_FLAG_PIN,
            @ptrCast(&anchor),
            &module,
        ).toBool()) {
            std.log.warn(
                "unable to pin the libghostty DLL, unloading it is unsafe err={}",
                .{windows.GetLastError()},
            );
        }
    }
};

// Reference the conditional exports based on target platform so they're
// included in the C API.
comptime {
    if (builtin.target.os.tag == .windows) {
        _ = Windows;
    } else {
        _ = NotWindows;
    }
}

fn initC(args: std.process.Args.Vector) c_int {
    assert(builtin.link_libc);

    global.init(.{
        .c = .{
            .args = args,
            .environ = if (std.process.Environ.Block == std.process.Environ.PosixBlock)
                // Asserting libc means that we can fast-path all POSIX blocks
                .{ .block = .{ .slice = std.c.environ[0..env_len: {
                    var len: usize = 0;
                    while (std.c.environ[len]) |_| : (len += 1) {}
                    break :env_len len;
                } :null] } }
            else
                // Anything that is not using PosixBlock is a global block for
                // purposes of initialization.
                .{ .block = .{ .use_global = true } },
        },
    }) catch |err| {
        std.log.err("failed to initialize ghostty error={}", .{err});
        return 1;
    };

    return 0;
}

/// Runs an action if it is specified. If there is no action this returns
/// false. If there is an action then this doesn't return.
pub export fn ghostty_cli_try_action() void {
    const action = global.action() orelse return;
    std.log.info("executing CLI action={}", .{action});
    posix.system.exit(action.run(global.alloc()) catch |err| {
        std.log.err("CLI action failed error={}", .{err});
        posix.system.exit(1);
    });

    posix.system.exit(0);
}

/// Return metadata about Ghostty, such as version, build mode, etc.
pub export fn ghostty_info() Info {
    return .{
        .mode = switch (builtin.mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseFast => .release_fast,
            .ReleaseSmall => .release_small,
        },
        .version = build_config.version_string.ptr,
        .version_len = build_config.version_string.len,
    };
}

/// Translate a string maintained by libghostty into the current
/// application language. This will return the same string (same pointer)
/// if no translation is found, so the pointer must be stable through
/// the function call.
///
/// This should only be used for singular strings maintained by Ghostty.
pub export fn ghostty_translate(msgid: [*:0]const u8) [*:0]const u8 {
    return internal_os.i18n._(msgid);
}

/// Free a string allocated by Ghostty.
pub export fn ghostty_string_free(str: String) void {
    str.deinit();
}

// On Windows, Zig's _DllMainCRTStartup is this DLL's entry point, and it
// runs neither C runtime's own DLL initialization. Declaring DllMain makes
// Zig's start.zig forward every DllMain reason to it, so we do that here.
//
// For MinGW we forward to mingw's _CRT_INIT, as mingw's DllMainCRTStartup
// would. It sets up the DLL's atexit table and then runs the C++ global
// constructors. Both matter. Without the constructors simdutf's
// implementation pointer stays null, and the first non-ASCII byte the
// terminal decodes dispatches through it. Without the table, glslang,
// spirv-cross, libc++ and imgui corrupt the heap the first time a
// function-local static registers its destructor with atexit (compiling
// a custom shader does). libghostty-vt's DLL needs only the constructors;
// see lib/windows_dll.zig.
//
// For MSVC we call the CRT bootstrap functions from libvcruntime and
// libucrt (already linked). That does not run the C++ constructors or set
// up the module's onexit table, which vcstartup's _CRT_INIT would; whether
// that links next to Zig's _DllMainCRTStartup needs an MSVC build to
// settle.
//
// This is a workaround. Closest upstream tracking: Codeberg ziglang/zig
// #30936 (reimplement crt0 code). Remove this DllMain when Zig runs the
// MSVC and MinGW DLL CRT init natively.
pub const DllMain = if (builtin.os.tag == .windows) struct {
    const BOOL = windows.BOOL;
    const HINSTANCE = windows.HINSTANCE;
    const DWORD = windows.DWORD;
    const LPVOID = windows.LPVOID;
    const TRUE = windows.TRUE;
    const FALSE = windows.FALSE;

    const DLL_PROCESS_ATTACH: DWORD = 1;
    const DLL_PROCESS_DETACH: DWORD = 0;

    const __vcrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__vcrt_initialize" });
    const __vcrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__vcrt_uninitialize" });
    const __acrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__acrt_initialize" });
    const __acrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__acrt_uninitialize" });
    const _CRT_INIT = @extern(*const fn (HINSTANCE, DWORD, LPVOID) callconv(.winapi) BOOL, .{ .name = "_CRT_INIT" });

    pub fn handler(hinst: HINSTANCE, fdwReason: DWORD, reserved: LPVOID) callconv(.winapi) BOOL {
        if (comptime builtin.target.abi != .msvc) return _CRT_INIT(hinst, fdwReason, reserved);
        switch (fdwReason) {
            DLL_PROCESS_ATTACH => {
                if (__vcrt_initialize() < 0) return FALSE;
                if (__acrt_initialize() < 0) return FALSE;
                return TRUE;
            },
            DLL_PROCESS_DETACH => {
                _ = __acrt_uninitialize(1);
                _ = __vcrt_uninitialize(1);
                return TRUE;
            },
            else => return TRUE,
        }
    }
}.handler else void;

test "ghostty_string_s empty string" {
    const testing = std.testing;
    const empty_string = String.empty;
    defer empty_string.deinit();

    try testing.expect(empty_string.len == 0);
    try testing.expect(empty_string.sentinel == false);
}

test "ghostty_string_s c string" {
    const testing = std.testing;

    const slice: [:0]const u8 = "hello";
    const allocated_slice = try testing.allocator.dupeZ(u8, slice);
    const c_null_string = String.fromSlice(allocated_slice);
    defer c_null_string.deinit();

    try testing.expect(allocated_slice[5] == 0);
    try testing.expect(@TypeOf(slice) == [:0]const u8);
    try testing.expect(@TypeOf(allocated_slice) == [:0]u8);
    try testing.expect(c_null_string.len == 5);
    try testing.expect(c_null_string.sentinel == true);
}

test "ghostty_string_s zig string" {
    const testing = std.testing;

    const slice: []const u8 = "hello";
    const allocated_slice = try testing.allocator.dupe(u8, slice);
    const zig_string = String.fromSlice(allocated_slice);
    defer zig_string.deinit();

    try testing.expect(@TypeOf(slice) == []const u8);
    try testing.expect(@TypeOf(allocated_slice) == []u8);
    try testing.expect(zig_string.len == 5);
    try testing.expect(zig_string.sentinel == false);
}
