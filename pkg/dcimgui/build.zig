const std = @import("std");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const freetype = b.option(bool, "freetype", "Use Freetype") orelse false;
    const backend_opengl3 = b.option(bool, "backend-opengl3", "OpenGL3 backend") orelse false;
    const backend_metal = b.option(bool, "backend-metal", "Metal backend") orelse false;
    const backend_osx = b.option(bool, "backend-osx", "OSX backend") orelse false;
    const backend_dx11 = b.option(bool, "backend-dx11", "DirectX 11 backend (the program defines ghostty_imgui_D3DCompile)") orelse false;
    const backend_win32 = b.option(bool, "backend-win32", "Win32 backend") orelse false;

    // Build options
    const options = b.addOptions();
    options.addOption(bool, "freetype", freetype);
    options.addOption(bool, "backend_opengl3", backend_opengl3);
    options.addOption(bool, "backend_metal", backend_metal);
    options.addOption(bool, "backend_osx", backend_osx);
    options.addOption(bool, "backend_dx11", backend_dx11);
    options.addOption(bool, "backend_win32", backend_win32);

    // Main static lib
    const lib = b.addLibrary(.{
        .name = "dcimgui",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // On MSVC, we must not use linkLibCpp because Zig unconditionally
            // passes -nostdinc++ and then adds its bundled libc++/libc++abi
            // include paths, which conflict with MSVC's own C++ runtime
            // headers. The MSVC SDK include directories (added via linkLibC)
            // contain both C and C++ headers, so linkLibCpp is not needed.
            .link_libcpp = target.result.abi != .msvc,
        }),
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Zig module
    const mod = b.addModule("dcimgui", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    mod.linkLibrary(lib);

    // We need to add proper Apple SDKs to find stdlib headers
    if (target.result.os.tag.isDarwin()) {
        if (!target.query.isNative()) {
            try @import("apple_sdk").addPaths(b, lib);
        }
    }

    // Split -D flags off from the rest of the flags, so that we can use them
    // in C translation.
    var define_flags: std.ArrayList([]const u8) = .empty;
    defer define_flags.deinit(b.allocator);
    try define_flags.appendSlice(b.allocator, &.{
        "-DIMGUI_HAS_DOCK=1",
        "-DIMGUI_USE_WCHAR32=1",
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
    });
    if (freetype) try define_flags.appendSlice(b.allocator, &.{
        "-DIMGUI_ENABLE_FREETYPE=1",
    });
    if (backend_opengl3) try define_flags.appendSlice(b.allocator, &.{
        "-DZIGPKG_IMGUI_ENABLE_OPENGL3=1",
    });
    if (target.result.os.tag == .windows) {
        try define_flags.appendSlice(b.allocator, &.{
            "-DIMGUI_IMPL_API=extern\t\"C\"\t__declspec(dllexport)",
        });
    } else {
        try define_flags.appendSlice(b.allocator, &.{
            "-DIMGUI_IMPL_API=extern\t\"C\"",
        });
    }

    var all_flags: std.ArrayList([]const u8) = .empty;
    try all_flags.appendSlice(b.allocator, define_flags.items);
    if (target.result.abi == .msvc) {
        try all_flags.appendSlice(b.allocator, &.{
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
        });
    }
    if (target.result.os.tag == .freebsd or target.result.abi == .musl) {
        try all_flags.append(b.allocator, "-fPIC");
    }

    // Add the core Dear Imgui source files
    if (b.lazyDependency("imgui", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path(""));
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{
                "imgui_demo.cpp",
                "imgui_draw.cpp",
                "imgui_tables.cpp",
                "imgui_widgets.cpp",
                "imgui.cpp",
            },
            .flags = all_flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path(""),
            "",
            .{ .include_extensions = &.{".h"} },
        );

        if (freetype) {
            lib.root_module.addCSourceFile(.{
                .file = upstream.path("misc/freetype/imgui_freetype.cpp"),
                .flags = all_flags.items,
            });

            if (b.systemIntegrationOption("freetype", .{})) {
                // The static library only gets the headers. Given -lfreetype
                // directly, Zig puts libfreetype.so into the archive and the
                // final link fails on it, so the shared library is linked
                // through the module instead.
                addPkgConfigIncludePaths(b, lib.root_module, "freetype2");
                mod.linkSystemLibrary("freetype2", dynamic_link_opts);
            } else {
                const freetype_dep = b.dependency("freetype", .{
                    .target = target,
                    .optimize = optimize,
                    .@"enable-libpng" = true,
                });
                lib.root_module.linkLibrary(freetype_dep.artifact("freetype"));
            }
        }

        if (backend_metal) {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_metal.mm"},
                .flags = all_flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_metal.h"} },
            );
        }
        if (backend_osx) {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_osx.mm"},
                .flags = all_flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_osx.h"} },
            );
        }
        if (backend_dx11) {
            // The backend calls D3DCompile, which would put
            // d3dcompiler_47.dll in the import table of whatever links it.
            // That DLL is not a KnownDLL, so a static import is searched
            // for in the application's directory first. The call is
            // renamed instead, and the program linking this backend
            // defines ghostty_imgui_D3DCompile (the D3DCompile signature),
            // loading the compiler however it trusts. d3dcompiler.h
            // declares the function in extern "C", so the renamed one has
            // C linkage too. Under the MSVC ABI, which is not yet built,
            // the backend's `#pragma comment(lib, "d3dcompiler")` still
            // names the import library; nothing references it after the
            // rename, so the linker should take no import from it.
            var flags: std.ArrayList([]const u8) = .empty;
            try flags.appendSlice(b.allocator, all_flags.items);
            try flags.append(b.allocator, "-DD3DCompile=ghostty_imgui_D3DCompile");
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_dx11.cpp"},
                .flags = flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_dx11.h"} },
            );
        }
        if (backend_win32) {
            // No gamepad: the backend would otherwise load XInput by bare
            // name (xinput1_4.dll and older), which a terminal has no use
            // for.
            var flags: std.ArrayList([]const u8) = .empty;
            try flags.appendSlice(b.allocator, all_flags.items);
            try flags.append(b.allocator, "-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD");
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_win32.cpp"},
                .flags = flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_win32.h"} },
            );
        }
        if (backend_opengl3) {
            lib.root_module.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_opengl3.cpp"},
                .flags = all_flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_opengl3.h"} },
            );
        }
    }

    // Add the C bindings
    if (b.lazyDependency("bindings", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path(""));
        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{
                "dcimgui.cpp",
                "dcimgui_internal.cpp",
            },
            .flags = all_flags.items,
        });
        lib.root_module.addCSourceFiles(.{
            .root = b.path(""),
            .files = &.{"ext.cpp"},
            .flags = all_flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path(""),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    // C translation
    try translate_c.addImportToModule(b, "dcimgui_c", mod, .{
        .source = .{ .includes = .{
            .files = &.{.{ .path = "dcimgui.h" }},
        } },
        .target = target,
        .optimize = optimize,
        .link_libs = &.{lib},
        .default_init = true,
        .extra_args = define_flags.items,
    });

    // The test uses the public module so that it sees the same imports,
    // the translated C header among them, as anything depending on it.
    const test_exe = b.addTest(.{
        .name = "test",
        .root_module = mod,
    });
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);
}

/// Add the include paths that pkg-config reports for a package, without
/// linking anything.
fn addPkgConfigIncludePaths(
    b: *std.Build,
    module: *std.Build.Module,
    name: []const u8,
) void {
    const pkg_config = b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";
    const cflags = b.run(&.{ pkg_config, "--cflags-only-I", name });
    var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            module.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
        }
    }
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
