const std = @import("std");

/// Runtime is the runtime to use for Ghostty. All runtimes do not provide
/// equivalent feature sets.
pub const Runtime = enum {
    /// Will not produce an executable at all when `zig build` is called.
    /// This is only useful if you're only interested in the lib only (macOS,
    /// and Windows hosts that embed libghostty).
    none,

    /// GTK4. Rich windowed application. This uses a full GObject-based
    /// approach to building the application.
    gtk,

    /// Win32. Native Windows application built directly on the Win32 API
    /// (user32/gdi32), rendering with Direct3D 11. See src/apprt/windows.zig.
    /// This is not the Windows default: build it with -Dapp-runtime=windows.
    windows,

    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            // The Linux and FreeBSD default is GTK because it is a full
            // featured application.
            .linux, .freebsd => .gtk,
            // Otherwise, we do NONE so we don't create an exe and we create
            // libghostty. On macOS, Xcode is used to build the app that links
            // to libghostty.
            else => .none,
        };
    }
};

test {
    _ = Runtime;
}

test "default runtime per target os" {
    const testing = std.testing;
    const builtin = @import("builtin");

    const Case = struct { std.Target.Os.Tag, Runtime };
    const cases = [_]Case{
        .{ .linux, .gtk },
        .{ .freebsd, .gtk },
        .{ .macos, .none },
        // A plain `zig build` for Windows produces libghostty, as on
        // macOS, so hosts that embed it get the DLL. The Win32 runtime
        // is opt-in.
        .{ .windows, .none },
    };

    for (cases) |c| {
        var target = builtin.target;
        target.os = std.Target.Os.Tag.defaultVersionRange(
            c[0],
            target.cpu.arch,
            target.abi,
        );
        try testing.expectEqual(c[1], Runtime.default(target));
    }
}
