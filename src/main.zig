const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const crash = @import("crash/main.zig");

/// See build_config.ExeEntrypoint for why we do this.
const entrypoint = switch (build_config.exe_entrypoint) {
    .ghostty => @import("main_ghostty.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_ghostty_1 => @import("build/mdgen/main_ghostty_1.zig"),
    .mdgen_ghostty_5 => @import("build/mdgen/main_ghostty_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};

/// The main entrypoint for the program.
pub const main = entrypoint.main;

/// Standard options such as logger overrides.
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};

/// The Windows app writes a minidump before a panic or a fatal exception
/// ends it (crash/windows.zig). Everything else keeps Zig's handlers.
const crash_dumps = crash.windows.enabled;

/// Zig's panic handler, with a dump first on Windows.
///
/// Everywhere else this must be Zig's default, written out: std.lang.panic
/// is `root.panic` whenever the root declares one, and its own choice by
/// compiler backend only when the root declares none. A declaration cannot
/// be left out for some targets, so there is no default to defer to. The
/// switch below is that choice as Zig 0.17's lib/std/lang.zig makes it.
pub const panic = if (crash_dumps)
    std.debug.FullPanic(crash.windows.panic)
else switch (builtin.zig_backend) {
    .stage2_loongarch,
    .stage2_powerpc,
    .stage2_riscv64,
    => std.debug.simple_panic,
    else => std.debug.FullPanic(std.debug.defaultPanic),
};

/// std.debug's overrides. Only `handleSegfault`, on Windows, which Zig's
/// segfault handler calls once it has decided to end the process.
pub const debug = if (crash_dumps) struct {
    pub const handleSegfault = crash.windows.handleSegfault;
} else struct {};

comptime {
    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

test {
    // Zig 0.16.0 has made test logging more strict. Now, *anything* that gets
    // printed to stderr results in a "failed command" message, even if the
    // tests ultimately passed. To reduce confusion here (and honestly, test
    // log spam in general), we bump the default testing log level to error.
    std.testing.log_level = std.log.Level.err;
    _ = entrypoint;
    _ = @import("quirks_memset.zig");
}
