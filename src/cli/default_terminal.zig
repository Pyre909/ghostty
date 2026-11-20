const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");

pub const Options = struct {
    /// Make Ghostty the default terminal.
    enable: bool = false,

    /// Put back the default terminal Ghostty replaced.
    disable: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `+default-terminal` command makes Ghostty the terminal Windows
/// opens consoles in: a console program started from Explorer, the Run
/// dialog or a shortcut then gets a Ghostty window in place of the console
/// host's. Without a flag, it says whether Ghostty is the default.
///
/// Windows hands a console to a third-party terminal only through Windows
/// Terminal's console server, so Windows Terminal 1.22 or later must be
/// installed. Consoles started as administrator keep the console host.
/// The default Ghostty replaces is saved, and `--disable` puts it back,
/// unless another default terminal was chosen since, which it keeps.
///
/// Only supported by the Windows app.
///
/// Flags:
///
///   * `--enable`: Make Ghostty the default terminal.
///
///   * `--disable`: Put back the default terminal Ghostty replaced.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // The Windows app's runtime serves the class the command names: any
    // other build, libghostty's on Windows too, would point the user's
    // consoles at an executable that never serves them.
    if (comptime build_config.app_runtime != .windows) {
        try stderr.writeAll("+default-terminal is only supported by the Windows app.\n");
        return 1;
    } else {
        if (opts.enable and opts.disable) {
            try stderr.writeAll("Give --enable or --disable, not both.\n");
            return 2;
        }
        const default_terminal = @import("../apprt/windows/default_terminal.zig");
        return default_terminal.command(
            alloc,
            if (opts.enable) .enable else if (opts.disable) .disable else .status,
            stdout,
            stderr,
        );
    }
}
