//! What `ghostty +new-window` and `+new-tab` ask of the terminal they
//! open, from the arguments they send (`ipc.Request`): parsed as GTK
//! parses its own (src/apprt/gtk/class/Overrides.zig), and applied to the
//! terminal's configuration as GTK applies them (`applyCommandOverrides`
//! in src/apprt/gtk/class/surface.zig), but for the working directory
//! (`workingDirectory`). Other arguments are ignored, as there.
const Overrides = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const termio = @import("../../termio.zig");

const log = std.log.scoped(.win32);

/// From `-e`, which takes every argument after it as the command, run
/// directly, or else from `--command=`.
command: ?configpkg.Command = null,

/// From `--shell-integration=`.
shell_integration: ?configpkg.Config.ShellIntegration = null,

/// From `--working-directory=`, read as the option is, with `home` as the
/// user's home directory: a path, which the terminal takes as it takes an
/// inherited one (`Surface.inheritWorkingDirectory`), or `inherit`, this
/// process's own. GTK takes every value as a path, `home` too.
working_directory: ?configpkg.WorkingDirectory = null,

/// From `--title=`: the terminal's title in place of its program's, as
/// its title prompt sets one.
title: ?[:0]const u8 = null,

/// Not from arguments: a console Windows handed off (handoff.zig), shown
/// in place of starting the command. The slot is the asker's, and the
/// terminal empties it as it takes the console (`Surface.takeHandoff`).
handoff: ?*?termio.Exec.Handoff = null,

pub const ParseError = Allocator.Error || error{
    /// A `--command=` that does not parse, for which GTK does nothing.
    InvalidCommand,
};

/// Parse `arguments` into `arena`, which then owns the result. A
/// `--shell-integration=` or `--working-directory=` that does not parse
/// is logged and skipped, as GTK skips the first.
pub fn parse(arena: Allocator, arguments: []const [:0]const u8) ParseError!Overrides {
    var result: Overrides = .{};
    var parsed: struct { @"shell-integration": ?configpkg.Config.ShellIntegration = null } = .{};
    for (arguments, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-e")) {
            const rest = arguments[i + 1 ..];
            // Nothing after it leaves the command as it was.
            if (rest.len == 0) break;
            const direct = try arena.alloc([:0]const u8, rest.len);
            for (rest, direct) |from, *to| to.* = try arena.dupeSentinel(u8, from, 0);
            result.command = .{ .direct = direct };
            break;
        }
        if (std.mem.cutPrefix(u8, arg, "--command=")) |value| {
            var command: configpkg.Command = undefined;
            command.parseCLI(arena, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("refused an IPC command that does not parse err={}", .{err});
                    return error.InvalidCommand;
                },
            };
            result.command = command;
            continue;
        }
        if (std.mem.cutPrefix(u8, arg, "--shell-integration=")) |value| {
            cli.args.parseIntoField(
                @TypeOf(parsed),
                arena,
                &parsed,
                "shell-integration",
                std.mem.trim(u8, value, &std.ascii.whitespace),
            ) catch |err| {
                log.warn("ignored an IPC shell integration that does not parse err={}", .{err});
            };
            continue;
        }
        if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |value| {
            result.working_directory = parseWorkingDirectory(arena, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => wd: {
                    log.warn("ignored an IPC working directory that does not parse err={}", .{err});
                    break :wd result.working_directory;
                },
            };
            continue;
        }
        if (std.mem.cutPrefix(u8, arg, "--title=")) |value| {
            result.title = try arena.dupeSentinel(u8, std.mem.trim(u8, value, &std.ascii.whitespace), 0);
            continue;
        }
    }
    result.shell_integration = parsed.@"shell-integration";
    return result;
}

/// `value` read as the `working-directory` option reads it, `home`
/// resolved as Config.finalize resolves it: what the core would make of
/// the option at startup.
fn parseWorkingDirectory(arena: Allocator, value: []const u8) !configpkg.WorkingDirectory {
    var wd: configpkg.WorkingDirectory = undefined;
    try wd.parseCLI(arena, value);
    if (wd == .home) {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = try internal_os.home(global.io(), &environ_map, &buf) orelse
            return error.NoHomeDirectory;
        wd = .{ .path = try arena.dupe(u8, home) };
    }
    try wd.finalize(arena);
    return wd;
}

/// Give `config`, a new terminal's, the command and shell integration
/// asked for, and an `inherit` working directory, as GTK's
/// `applyCommandOverrides` does the first two: a command asked for
/// detects its shell's integration again, unless integration is off or
/// another was asked for. A working directory that is a path the caller
/// takes from `workingDirectory`, to be checked.
pub fn apply(self: *const Overrides, config: *configpkg.Config) Allocator.Error!void {
    if (self.command) |value| {
        config.command = try value.clone(config.arenaAlloc());
        if (self.shell_integration) |integration| {
            config.@"shell-integration" = integration;
        } else if (config.@"shell-integration" != .none) {
            config.@"shell-integration" = .detect;
        }
    } else if (self.shell_integration) |value| {
        config.@"shell-integration" = value;
    }
    if (self.working_directory) |wd| if (wd == .inherit) {
        config.@"working-directory" = .inherit;
    };
    // Input is for the configured command, which a console handed off
    // does not run: its program was started by another.
    if (self.handoff != null) config.input = .{};
}

/// The path a new terminal starts in, for one that would inherit
/// `inherited`: the path asked for, or none for `inherit` (`apply`), or
/// `inherited` when nothing was asked. The CLI always asks, for the
/// directory it runs in unless `--working-directory` names another
/// (src/cli/new_tab.zig), so a tab opens where the command ran. GTK lets
/// the inherited one win, the parent's pwd set after the overrides
/// (src/apprt/gtk/class/surface.zig): there a tab opens where the terminal
/// beside it is.
pub fn workingDirectory(self: *const Overrides, inherited: ?[]const u8) ?[]const u8 {
    const wd = self.working_directory orelse return inherited;
    return wd.value();
}

/// Whether the terminal shows something other than the configured shell:
/// a command, or a console handed off, whose program a saved state could
/// not start again (`Surface.ran_command`).
pub fn replacesShell(self: *const Overrides) bool {
    return self.command != null or self.handoff != null;
}

test "win32: IPC arguments are read as GTK reads them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const o = try parse(alloc, &.{
        "--title= a ",
        "--shell-integration= none ",
        "--working-directory=C:\\Windows",
        "--unknown=1",
        "--class=x",
        "-e",
        "cmd.exe",
        "/k",
        "--title=b",
    });
    try std.testing.expectEqualStrings("a", o.title.?);
    try std.testing.expectEqual(.none, o.shell_integration.?);
    try std.testing.expectEqualStrings("C:\\Windows", o.workingDirectory(null).?);
    const direct = o.command.?.direct;
    try std.testing.expectEqual(3, direct.len);
    for ([_][]const u8{ "cmd.exe", "/k", "--title=b" }, direct) |want, got| try std.testing.expectEqualStrings(want, got);

    // `-e` wins over `--command=`, whichever comes first, and with nothing
    // after it leaves `--command=`'s.
    const shell = try parse(alloc, &.{"--command=pwsh.exe -NoLogo"});
    try std.testing.expectEqualStrings("pwsh.exe -NoLogo", shell.command.?.shell);
    const both = try parse(alloc, &.{ "-e", "a.exe", "--command=b.exe" });
    try std.testing.expectEqual(2, both.command.?.direct.len);
    const bare = try parse(alloc, &.{ "--command=b.exe", "-e" });
    try std.testing.expectEqualStrings("b.exe", bare.command.?.shell);

    // The last of each counts; none at all is no override.
    const last = try parse(alloc, &.{ "--title=a", "--title=b", "--shell-integration=cmd", "--shell-integration=none" });
    try std.testing.expectEqualStrings("b", last.title.?);
    try std.testing.expectEqual(.none, last.shell_integration.?);
    const none = try parse(alloc, &.{});
    try std.testing.expectEqual(null, none.command);
    try std.testing.expectEqual(null, none.shell_integration);
    try std.testing.expectEqual(null, none.working_directory);
    try std.testing.expectEqual(null, none.title);
}

test "win32: IPC arguments that do not parse are refused or skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectError(error.InvalidCommand, parse(alloc, &.{"--command= "}));
    try std.testing.expectError(error.InvalidCommand, parse(alloc, &.{ "--title=a", "--command=" }));
    // Skipped, keeping what came before.
    const o = try parse(alloc, &.{
        "--shell-integration=cmd",
        "--shell-integration=nonsense",
        "--working-directory=C:\\Windows",
        "--working-directory= ",
    });
    try std.testing.expectEqual(.cmd, o.shell_integration.?);
    try std.testing.expectEqualStrings("C:\\Windows", o.workingDirectory(null).?);
}

test "win32: an IPC working directory means what the option means" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const inherit = try parse(alloc, &.{"--working-directory=inherit"});
    try std.testing.expectEqual(.inherit, inherit.working_directory.?);
    try std.testing.expectEqual(null, inherit.workingDirectory("C:\\Users"));
    // Nothing asked keeps what the terminal would inherit.
    try std.testing.expectEqualStrings("C:\\Users", (try parse(alloc, &.{})).workingDirectory("C:\\Users").?);
    try std.testing.expectEqualStrings("C:\\Windows", (try parse(alloc, &.{"--working-directory=C:\\Windows"})).workingDirectory("C:\\Users").?);

    // `home` is the home directory, as Config.finalize finds it.
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const want = (try internal_os.home(global.io(), &environ_map, &buf)).?;
    const home = try parse(alloc, &.{"--working-directory= home "});
    try std.testing.expectEqualStrings(want, home.workingDirectory(null).?);
    // A quoted value, as the option reads one.
    const quoted = try parse(alloc, &.{"--working-directory=\"C:\\Program Files\""});
    try std.testing.expectEqualStrings("C:\\Program Files", quoted.workingDirectory(null).?);
}

test "win32: IPC overrides give a new terminal's configuration its command and shell integration, as GTK's do" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var config = try configpkg.Config.default(std.testing.allocator);
    defer config.deinit();

    // Nothing asked changes nothing.
    config.@"shell-integration" = .cmd;
    try (Overrides{}).apply(&config);
    try std.testing.expectEqual(.cmd, config.@"shell-integration");
    try std.testing.expectEqual(null, config.command);

    // A command detects its shell's integration, unless it is off.
    try (try parse(alloc, &.{ "-e", "pwsh.exe" })).apply(&config);
    try std.testing.expectEqualStrings("pwsh.exe", config.command.?.direct[0]);
    try std.testing.expectEqual(.detect, config.@"shell-integration");
    config.@"shell-integration" = .none;
    try (try parse(alloc, &.{"--command=cmd.exe"})).apply(&config);
    try std.testing.expectEqual(.none, config.@"shell-integration");
    // One asked for wins, with a command or without.
    try (try parse(alloc, &.{ "--command=cmd.exe", "--shell-integration=cmd" })).apply(&config);
    try std.testing.expectEqual(.cmd, config.@"shell-integration");
    try (try parse(alloc, &.{"--shell-integration=powershell"})).apply(&config);
    try std.testing.expectEqual(.powershell, config.@"shell-integration");

    // `inherit` is set here; a path is not, as the caller checks it.
    config.@"working-directory" = .home;
    try (try parse(alloc, &.{"--working-directory=C:\\Windows"})).apply(&config);
    try std.testing.expectEqual(.home, config.@"working-directory".?);
    try (try parse(alloc, &.{"--working-directory=inherit"})).apply(&config);
    try std.testing.expectEqual(.inherit, config.@"working-directory".?);
}

test "win32: a console handed off gets no configured input" {
    var config = try configpkg.Config.default(std.testing.allocator);
    defer config.deinit();
    try config.input.parseCLI(config.arenaAlloc(), "raw:echo hi\\r");
    // A terminal of the configured command keeps it.
    try (Overrides{}).apply(&config);
    try std.testing.expectEqual(1, config.input.list.items.len);
    var slot: ?termio.Exec.Handoff = null;
    try (Overrides{ .handoff = &slot }).apply(&config);
    try std.testing.expectEqual(0, config.input.list.items.len);
}

test "win32: a command or a console handed off replaces the shell" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expect(!(try parse(alloc, &.{"--title=a"})).replacesShell());
    try std.testing.expect((try parse(alloc, &.{ "-e", "a.exe" })).replacesShell());
    try std.testing.expect((try parse(alloc, &.{"--command=b.exe"})).replacesShell());
    // The slot counts, whether or not the terminal has taken it yet.
    var slot: ?termio.Exec.Handoff = null;
    try std.testing.expect((Overrides{ .handoff = &slot }).replacesShell());
}
