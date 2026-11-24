//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, butos/main.zig
//! also OS-specific features and conventions.

const std = @import("std");
const builtin = @import("builtin");

const dbus = @import("dbus.zig");
const desktop = @import("desktop.zig");
const file = @import("file.zig");
const flatpak = @import("flatpak.zig");
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");
const systemd = @import("systemd.zig");
const kernel_info = @import("kernel_info.zig");

// Namespaces
pub const cgroup = @import("cgroup.zig");
pub const edit = @import("edit.zig");
pub const hostname = @import("hostname.zig");
pub const i18n = @import("i18n.zig");
pub const mach = @import("mach.zig");
pub const path = @import("path.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
pub const macos = @import("macos.zig");
pub const shell = @import("shell.zig");
pub const stderr = @import("stderr.zig");
pub const uri = @import("uri.zig");

// Functions and types
pub const CFReleaseThread = @import("cf_release_thread.zig");
pub const TempDir = @import("TempDir.zig");
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const launchedByDbusActivation = dbus.launchedByDbusActivation;
pub const launchedBySystemd = systemd.launchedBySystemd;
pub const desktopEnvironment = desktop.desktopEnvironment;
pub const rlimit = file.rlimit;
pub const fixMaxFiles = file.fixMaxFiles;
pub const restoreMaxFiles = file.restoreMaxFiles;
pub const randomTmpPath = file.randomTmpPath;
pub const isFlatpak = flatpak.isFlatpak;
pub const FlatpakHostCommand = flatpak.FlatpakHostCommand;
pub const home = homedir.home;
pub const expandHome = homedir.expandHome;
pub const isHomeRelative = homedir.isHomeRelative;
pub const ensureLocale = locale.ensureLocale;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const OpenType = openpkg.Type;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
pub const ResourcesDir = resourcesdir.ResourcesDir;
pub const ShellEscapeWriter = shell.ShellEscapeWriter;
pub const getKernelInfo = kernel_info.getKernelInfo;
pub const getConfigEditCommand = edit.getConfigEditCommand;

/// How the threads we start are configured.
///
/// On Windows, Zig hands `stack_size` to NtCreateThreadEx as the stack's
/// initial commit and leaves the reserve to the executable's header, so
/// the default of 16 MiB charges every thread 16 MiB of commit that it
/// never touches (five threads a terminal). This asks for the smallest
/// commit Zig passes on; the stack still grows to the header's reserve
/// on demand. Elsewhere the size is a reservation that costs nothing
/// until used, so the default stays.
pub const thread_config: std.Thread.SpawnConfig = if (builtin.target.os.tag == .windows)
    .{ .stack_size = 64 * 1024 }
else
    .{};

test "win32: thread_config commits little stack" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    const S = struct {
        const MBI = windows.MEMORY_BASIC_INFORMATION;
        const VirtualQuery = windows.exp.kernel32.VirtualQuery;

        /// The reserve and the commit of the calling thread's stack.
        fn measure(reserve: *usize, commit: *usize) void {
            var local: u8 = 0;
            var info: MBI = undefined;
            if (VirtualQuery(&local, &info, @sizeOf(MBI)) == 0) return;
            const stack = info.AllocationBase;
            var addr = stack;
            while (VirtualQuery(@ptrFromInt(addr), &info, @sizeOf(MBI)) != 0 and
                info.AllocationBase == stack) : (addr += info.RegionSize)
            {
                reserve.* += info.RegionSize;
                if (info.State == windows.MEM_COMMIT) commit.* += info.RegionSize;
            }
        }
    };

    var reserve: usize = 0;
    var commit: usize = 0;
    const thread = try std.Thread.spawn(thread_config, S.measure, .{ &reserve, &commit });
    thread.join();

    // The commit includes the guard pages; the default commits all 16 MiB.
    try std.testing.expect(commit > 0);
    try std.testing.expect(commit <= 256 * 1024);
    try std.testing.expect(reserve >= 4 * commit);
}

test {
    _ = @import("com_abi.zig");
    _ = file;
    _ = stderr;
    _ = edit;
    _ = i18n;
    _ = mouse;
    _ = openpkg;
    _ = path;
    _ = uri;
    _ = shell;
    _ = hostname;

    if (comptime builtin.target.os.tag == .linux) {
        _ = kernel_info;
    } else if (comptime builtin.target.os.tag.isDarwin()) {
        _ = mach;
        _ = macos;
    }
}
