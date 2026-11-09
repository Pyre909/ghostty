const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary Ghostty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// The install step for ghostty.com, the console launcher installed
/// beside ghostty.exe on Windows (src/main_launcher.zig).
launcher_install_step: ?*std.Build.Step.InstallArtifact = null,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omitFramePointer(),
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // Add the shared dependencies. When building only lib-vt we skip
    // heavy deps so cross-compilation doesn't pull in GTK, etc.
    if (!cfg.emit_lib_vt) _ = try deps.add(exe);

    // Check for possible issues
    try checkNixShell(exe, cfg);

    // Add patchelf step if that option is specified.
    cfg.addPatchElf(exe, &install_step.step);

    // OS-specific
    var launcher_install_step: ?*std.Build.Step.InstallArtifact = null;
    switch (cfg.target.result.os.tag) {
        .windows => {
            exe.subsystem = .windows;
            exe.root_module.addWin32ResourceFile(.{
                .file = b.path("dist/windows/ghostty.rc"),
            });

            // A console program needs no app dependencies. It imports the
            // CLI action detection (cli/action.zig) and cli/ghostty.zig's
            // Action, whose other imports Zig never analyses: only the
            // action tags and detectSpecialCase are used.
            const launcher = b.addExecutable(.{
                .name = "ghostty-launcher",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main_launcher.zig"),
                    .target = cfg.target,
                    .optimize = cfg.optimize,
                    .strip = cfg.strip,
                }),
                .use_llvm = true,
            });
            launcher.subsystem = .console;
            launcher_install_step = b.addInstallArtifact(launcher, .{
                .dest_sub_path = "ghostty.com",
            });

            // Microsoft's ConPTY package: src/pty.zig uses its conpty.dll
            // when OpenConsole.exe is beside it, both beside ghostty.exe,
            // and kernel32's pseudoconsole otherwise. The package carries
            // no licence file, so its MIT notice (microsoft/terminal's
            // LICENSE) goes with them.
            //
            // Only a build that installs the app asks for the package
            // (build.zig installs the exe for an app runtime with
            // emit-exe), so lib-vt and libghostty builds never fetch it.
            // x86 gets none: the package's own layout gives a 32-bit
            // build all three architectures' OpenConsole.exe, since it may
            // run on 64-bit Windows, and that is not measured here.
            conpty: {
                if (cfg.app_runtime == .none or !cfg.emit_exe) break :conpty;
                const arch = switch (cfg.target.result.cpu.arch) {
                    .aarch64 => "arm64",
                    .x86_64 => "x64",
                    else => break :conpty,
                };
                const dep = b.lazyDependency("conpty", .{}) orelse break :conpty;
                for ([_]struct { []const u8, []const u8 }{
                    .{ b.fmt("runtimes/win-{s}/native/conpty.dll", .{arch}), "conpty.dll" },
                    .{ b.fmt("build/native/runtimes/{s}/OpenConsole.exe", .{arch}), "OpenConsole.exe" },
                }) |file| install_step.step.dependOn(&b.addInstallBinFile(
                    dep.path(file[0]),
                    file[1],
                ).step);
                install_step.step.dependOn(&b.addInstallBinFile(
                    b.path("dist/windows/conpty-LICENSE.txt"),
                    "conpty-LICENSE.txt",
                ).step);
            }
        },

        else => {},
    }

    return .{
        .exe = exe,
        .install_step = install_step,
        .launcher_install_step = launcher_install_step,
    };
}

/// Add the ghostty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
    if (self.launcher_install_step) |step| b.getInstallStep().dependOn(&step.step);
}

/// If we're in NixOS but not in the shell environment then we issue
/// a warning because the rpath may not be setup properly. This doesn't modify
/// our build in any way but addresses a common build-from-source issue
/// for a subset of users.
fn checkNixShell(exe: *std.Build.Step.Compile, cfg: *const Config) !void {
    // Non-Linux doesn't have rpath issues.
    if (cfg.target.result.os.tag != .linux) return;

    // When cross-compiling, we don't need to worry about matching our
    // Nix shell rpath since the resulting binary will be run on a
    // separate system.
    if (!cfg.target.query.isNativeCpu()) return;
    if (!cfg.target.query.isNativeOs()) return;

    // Verify we're in NixOS
    std.Io.Dir.accessAbsolute(exe.step.owner.graph.io, "/etc/NIXOS", .{}) catch return;

    // If we're in a nix shell, not a problem
    if (cfg.env.get("IN_NIX_SHELL") != null) return;

    std.log.warn(
        "\x1b[" ++ color_map.get("yellow").? ++
            "\x1b[" ++ color_map.get("d").? ++
            \\Detected building on and for NixOS outside of the Nix shell environment.
            \\
            \\The resulting ghostty binary will likely fail on launch because it is
            \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
            \\We highly recommend running only within the Nix build environment
            \\and the resulting binary will be portable across your system.
            \\
            \\To run in the Nix build environment, use the following command.
            \\Append any additional options like (`-Doptimize` flags). The resulting
            \\binary will be in zig-out as usual.
            \\
            \\  nix develop -c zig build
            \\
        ++
            "\x1b[0m",
        .{},
    );
}

/// ANSI escape codes for colored log output
const color_map = std.StaticStringMap([]const u8).initComptime(.{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
