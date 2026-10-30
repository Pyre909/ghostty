const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    bash,
    cmd,
    elvish,
    fish,
    nushell,
    powershell,
    zsh,
};

/// The result of setting up a shell integration.
pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// The command to use to start the shell with the integration.
    /// In most cases this is identical to the command given but for
    /// bash in particular it may be different.
    ///
    /// The memory is allocated in the arena given to setup.
    command: config.Command,
};

/// Set up the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result. It is expected to be an arena to
/// simplify cleanup.
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
) !?ShellIntegration {
    const shell: Shell = force_shell orelse
        try detectShell(alloc_arena, command) orelse
        return null;

    const new_command: config.Command = switch (shell) {
        .bash => try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        // Only on Windows: elsewhere `PROMPT` is some other shell's (zsh
        // reads it as its prompt).
        .cmd => if (comptime builtin.target.os.tag == .windows) try setupCmd(
            alloc_arena,
            command,
            env,
        ) else null,

        .nushell => try setupNushell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .powershell => try setupPowerShell(
            alloc_arena,
            command,
            resource_dir,
        ),

        .zsh => try setupZsh(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .elvish, .fish => xdg: {
            if (!try setupXdgDataDirs(alloc_arena, resource_dir, env)) return null;
            break :xdg try command.clone(alloc_arena);
        },
    } orelse return null;

    return .{
        .shell = shell,
        .command = new_command,
    };
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).@"enum".field_names) |field| {
        const shell = @field(Shell, field);

        var res: TmpResourcesDir = try .init(shell);
        defer res.deinit();

        const result = try setup(
            alloc,
            res.path,
            .{ .shell = "sh" },
            &env,
            shell,
        );
        if (comptime shell == .cmd and builtin.target.os.tag != .windows) {
            // cmd is integrated only on Windows (the "cmd" test).
            try testing.expect(result == null);
        } else {
            try testing.expectEqual(shell, result.?.shell);
        }
    }
}

test "shell integration failure" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const result = try setup(
        alloc,
        "/nonexistent",
        .{ .shell = "sh" },
        &env,
        null,
    );

    try testing.expect(result == null);
    try testing.expectEqual(0, env.count());
}

fn detectShell(alloc: Allocator, command: config.Command) !?Shell {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    const arg0 = arg_iter.next() orelse return null;
    const exe = std.fs.path.basename(arg0);

    if (std.mem.eql(u8, "bash", exe)) {
        // Apple distributes their own patched version of Bash 3.2
        // on macOS that disables the ENV-based POSIX startup path.
        // This means we're unable to perform our automatic shell
        // integration sequence in this specific environment.
        //
        // If we're running "/bin/bash" on Darwin, we can assume
        // we're using Apple's Bash because /bin is non-writable
        // on modern macOS due to System Integrity Protection.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", arg0)) {
                return null;
            }
        }
        return .bash;
    }

    if (std.mem.eql(u8, "elvish", exe)) return .elvish;
    if (std.mem.eql(u8, "fish", exe)) return .fish;
    if (std.mem.eql(u8, "nu", exe)) return .nushell;
    if (std.mem.eql(u8, "zsh", exe)) return .zsh;

    // PowerShell 7 is `pwsh` and Windows PowerShell 5.1 is `powershell`.
    // Unlike the names above these ignore case, as Windows file names do
    // (`PowerShell.EXE`), and on Windows an `.exe` suffix. Elsewhere a
    // `pwsh.exe` is the Windows one run through WSL's interop, which sees
    // neither our environment nor our paths.
    const name = if (builtin.target.os.tag == .windows and
        std.ascii.endsWithIgnoreCase(exe, ".exe"))
        exe[0 .. exe.len - ".exe".len]
    else
        exe;
    if (std.ascii.eqlIgnoreCase(name, "pwsh") or
        std.ascii.eqlIgnoreCase(name, "powershell")) return .powershell;

    // cmd.exe, the default command on Windows (Exec), only there: elsewhere
    // a `cmd` is some other program, and a `cmd.exe` is the Windows one run
    // through WSL's interop, which sees none of our environment.
    if (builtin.target.os.tag == .windows and
        std.ascii.eqlIgnoreCase(name, "cmd")) return .cmd;

    return null;
}

test detectShell {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try detectShell(alloc, .{ .shell = "sh" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash" }));
    try testing.expectEqual(.elvish, try detectShell(alloc, .{ .shell = "elvish" }));
    try testing.expectEqual(.fish, try detectShell(alloc, .{ .shell = "fish" }));
    try testing.expectEqual(.nushell, try detectShell(alloc, .{ .shell = "nu" }));
    try testing.expectEqual(.zsh, try detectShell(alloc, .{ .shell = "zsh" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "pwsh" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "powershell" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "PowerShell" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "/usr/local/bin/pwsh -NoLogo" }));
    try testing.expect(try detectShell(alloc, .{ .shell = "pwshx" }) == null);
    try testing.expect(try detectShell(alloc, .{ .shell = "powershell_ise" }) == null);

    if (comptime builtin.target.os.tag == .windows) {
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "pwsh.exe" }));
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "PowerShell.EXE" }));
        try testing.expectEqual(.powershell, try detectShell(alloc, .{
            .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo",
        }));
        try testing.expectEqual(.powershell, try detectShell(alloc, .{ .direct = &.{
            "C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        } }));
        try testing.expect(try detectShell(alloc, .{ .shell = "powershell_ise.exe" }) == null);
        try testing.expect(try detectShell(alloc, .{ .shell = ".exe" }) == null);

        // The default command (Exec).
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "cmd.exe" }));
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "cmd" }));
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "CMD.EXE /k init.bat" }));
        try testing.expectEqual(.cmd, try detectShell(alloc, .{ .direct = &.{
            "C:\\WINDOWS\\system32\\cmd.exe",
        } }));
        try testing.expect(try detectShell(alloc, .{ .shell = "cmdx.exe" }) == null);
    } else {
        // The Windows PowerShell and cmd run through WSL's interop.
        try testing.expect(try detectShell(alloc, .{ .shell = "pwsh.exe" }) == null);
        try testing.expect(try detectShell(alloc, .{ .shell = "cmd.exe" }) == null);
        try testing.expect(try detectShell(alloc, .{ .shell = "cmd" }) == null);
    }

    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(try detectShell(alloc, .{ .shell = "/bin/bash" }) == null);
    }

    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash -c 'command'" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"/a b/bash\"" }));
}

/// Set up the shell integration features environment variable.
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
    cursor_blink: bool,
) !void {
    const field_names = @typeInfo(@TypeOf(features)).@"struct".field_names;
    const capacity: usize = capacity: {
        comptime var n: usize = field_names.len - 1; // commas
        inline for (field_names) |name| n += name.len;
        n += ":steady".len; // cursor value
        break :capacity n;
    };

    var buf: [capacity]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Sort the fields so that the output is deterministic. This is
    // done at comptime so it has no runtime cost
    const fields_sorted: [field_names.len][]const u8 = comptime fields: {
        var fields_sorted: [field_names.len][]const u8 = field_names.*;
        std.mem.sortUnstable(
            []const u8,
            &fields_sorted,
            {},
            (struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
                }
            }).lessThan,
        );
        break :fields fields_sorted;
    };

    inline for (fields_sorted) |name| {
        if (@field(features, name)) {
            if (writer.end > 0) try writer.writeByte(',');
            try writer.writeAll(name);

            if (std.mem.eql(u8, name, "cursor")) {
                try writer.writeAll(if (cursor_blink) ":blink" else ":steady");
            }
        }
    }

    if (writer.end > 0) {
        try env.put("GHOSTTY_SHELL_FEATURES", buf[0..writer.end]);
    }
}

test "setup features" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test: all features enabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true, .@"ssh-env" = true, .@"ssh-terminfo" = true, .path = true }, true);
        try testing.expectEqualStrings("cursor:blink,path,ssh-env,ssh-terminfo,sudo,title", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: all features disabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, std.mem.zeroes(config.ShellIntegrationFeatures), true);
        try testing.expect(env.get("GHOSTTY_SHELL_FEATURES") == null);
    }

    // Test: mixed features
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false, .@"ssh-env" = true, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("ssh-env,sudo", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: blinking cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("cursor:blink", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: steady cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, false);
        try testing.expectEqualStrings("cursor:steady", env.get("GHOSTTY_SHELL_FEATURES").?);
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    var stack_fallback_buf: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buf, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.allocator());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;
    try cmd.appendArg("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var buf: [32]u8 = undefined;
    var inject: std.Io.Writer = .fixed(&buf);
    try inject.writeAll("1");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration script.
    //
    // Unsupported options:
    //  -c          -c is always non-interactive
    //  --posix     POSIX mode (a la /bin/sh)
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.writeAll(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.writeAll(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Preserve an existing ENV value. We're about to overwrite it.
    if (env.get("ENV")) |v| {
        try env.put("GHOSTTY_BASH_ENV", v);
    }

    // Set our new ENV to point to our integration script.
    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.mem.print(
        &script_path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
        try env.put("ENV", script_path);
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        _ = env.swapRemove("GHOSTTY_BASH_ENV");
        return null;
    }

    try env.put("GHOSTTY_BASH_INJECT", buf[0..inject.end]);
    if (rcfile) |v| {
        try env.put("GHOSTTY_BASH_RCFILE", v);
    }

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (env.get("HISTFILE") == null) {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(global.io(), &environ_map, &home_buf)) |home| {
            var histfile_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const histfile = try std.mem.print(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeSentinel(u8, cmd.buffer.written(), 0) };
}

test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("bash --posix", command.?.shell);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expectEqual(0, env.count());
    }
}

test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: ENV" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("ENV", "env.sh");

    _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("env.sh", env.get("GHOSTTY_BASH_ENV").?);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // "-" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix - --arg file1 file2", command.?.shell);
    }

    // "--" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix -- --arg file1 file2", command.?.shell);
    }
}

test "bash: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupBash(alloc, .{ .shell = "bash" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// What cmd's prompt is wrapped in, in `PROMPT`'s own codes (`$E` is ESC,
/// `$P` the current drive and directory). Before it, the start of the
/// prompt (`redraw=0`: cmd does not redraw its prompt on a resize) and the
/// working directory as ConEmu's OSC 9;9. After it, 133;I: input that
/// ends at the end of its line, as nothing can mark where a command's
/// output starts.
const cmd_prompt_start = "$E]133;A;redraw=0$E\\$E]9;9;$P$E\\";
const cmd_prompt_end = "$E]133;I$E\\";

/// cmd's prompt when `PROMPT` is not set or empty.
const cmd_prompt_default = "$P$G";

/// Set up the cmd.exe automatic shell integration. cmd reads no startup
/// file we could add to (its `AutoRun` registry value is the user's) and
/// runs nothing before or after a command, but it expands `PROMPT` from
/// its environment for every prompt. The integration is that value: the
/// user's prompt, or cmd's default, between `cmd_prompt_start` and
/// `cmd_prompt_end`. That gives prompt marks and the working directory.
/// With no hook before a command and no `%ERRORLEVEL%` in `PROMPT` there
/// is no 133;C or 133;D, so no `command_finished`, and none of the
/// `shell-integration-features` apply. The command is unchanged.
fn setupCmd(
    alloc_arena: Allocator,
    command: config.Command,
    env: *EnvMap,
) !config.Command {
    try env.put("PROMPT", try cmdPrompt(alloc_arena, env.get("PROMPT")));
    return try command.clone(alloc_arena);
}

/// The `PROMPT` value that wraps `prompt`, the user's value if set. A value
/// already wrapped, which a cmd in Ghostty passes to a Ghostty it starts,
/// is kept as it is.
fn cmdPrompt(alloc: Allocator, prompt: ?[]const u8) ![]const u8 {
    const user = prompt orelse "";
    if (std.mem.startsWith(u8, user, cmd_prompt_start) and
        std.mem.endsWith(u8, user, cmd_prompt_end)) return user;

    return try std.mem.concat(alloc, u8, &.{
        cmd_prompt_start,
        if (user.len > 0) user else cmd_prompt_default,
        cmd_prompt_end,
    });
}

test "cmd" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.cmd);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const maybe = try setup(alloc, res.path, .{ .shell = "cmd.exe /k init.bat" }, &env, .cmd);
    if (comptime builtin.target.os.tag != .windows) {
        // Elsewhere even a forced cmd does nothing.
        try testing.expect(maybe == null);
        try testing.expectEqual(0, env.count());
        return;
    }
    const result = maybe orelse return error.TestUnexpectedResult;
    try testing.expectEqual(.cmd, result.shell);
    try testing.expectEqualStrings("cmd.exe /k init.bat", result.command.shell);
    try testing.expectEqualStrings(
        "$E]133;A;redraw=0$E\\$E]9;9;$P$E\\$P$G$E]133;I$E\\",
        env.get("PROMPT") orelse "",
    );
    try testing.expectEqual(1, env.count());
}

test "cmd: the user's prompt" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PROMPT", "$T $P$_$G");

    _ = try setupCmd(alloc, .{ .shell = "cmd.exe" }, &env);
    try testing.expectEqualStrings(
        cmd_prompt_start ++ "$T $P$_$G" ++ cmd_prompt_end,
        env.get("PROMPT") orelse "",
    );
}

test "cmd: a wrapped prompt is kept" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PROMPT", "$N$G");

    // A Ghostty started from a cmd in Ghostty sets it up again.
    _ = try setupCmd(alloc, .{ .shell = "cmd.exe" }, &env);
    _ = try setupCmd(alloc, .{ .shell = "cmd.exe" }, &env);
    try testing.expectEqualStrings(
        cmd_prompt_start ++ "$N$G" ++ cmd_prompt_end,
        env.get("PROMPT") orelse "",
    );
}

test "cmd: a half-wrapped prompt is wrapped again" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Only a value with both ends is ours, such as the README's line
    // copied without its end.
    inline for (.{
        cmd_prompt_start ++ "$P$G",
        "$P$G" ++ cmd_prompt_end,
    }) |prompt| {
        try testing.expectEqualStrings(
            cmd_prompt_start ++ prompt ++ cmd_prompt_end,
            try cmdPrompt(alloc, prompt),
        );
    }
}

/// `prompt` expanded as cmd does for these tests' codes (`PROMPT /?`).
fn testCmdExpand(buf: []u8, prompt: []const u8, cwd: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < prompt.len) : (i += 1) {
        if (prompt[i] != '$') {
            try w.writeByte(prompt[i]);
            continue;
        }
        i += 1;
        if (i == prompt.len) return error.TestUnexpectedResult;
        switch (std.ascii.toUpper(prompt[i])) {
            'E' => try w.writeByte(0x1b),
            'P' => try w.writeAll(cwd),
            'G' => try w.writeByte('>'),
            '_' => try w.writeAll("\r\n"),
            '$' => try w.writeByte('$'),
            else => return error.TestUnexpectedResult,
        }
    }
    return w.buffered();
}

test "cmd: the prompt's marks, as cmd writes them" {
    const testing = std.testing;
    const Terminal = @import("../terminal/main.zig").Terminal;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const prompt = try cmdPrompt(arena.allocator(), null);

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();

    // The bytes cmd writes through ConPTY: the prompt at a drive's root
    // (its path ends in a backslash right before ST), the typed command
    // echoed, the Enter's CR LF, output, and the blank line and prompt
    // that follow a command.
    var buf: [256]u8 = undefined;
    s.nextSlice(try testCmdExpand(&buf, prompt, "C:\\"));
    try testing.expect(t.cursorIsAtPrompt());
    try testing.expectEqual(.false, t.flags.shell_redraws_prompt);
    try testing.expectEqualStrings("C:\\", t.getPwd() orelse "");
    try testing.expectEqualStrings("C:\\>", try t.plainString(arena.allocator()));

    // Typed input, which 133;I ends at the end of its line.
    s.nextSlice("ping -t localhost");
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
    try testing.expect(t.screens.active.cursor.semantic_content_clear_eol);

    s.nextSlice("\r\n\r\nPinging localhost [::1] with 32 bytes");
    try testing.expect(!t.cursorIsAtPrompt());

    s.nextSlice("\r\n\r\n");
    s.nextSlice(try testCmdExpand(&buf, prompt, "C:\\Windows"));
    try testing.expect(t.cursorIsAtPrompt());
    try testing.expectEqual(.prompt, t.screens.active.cursor.page_row.semantic_prompt);
    try testing.expectEqualStrings("C:\\Windows", t.getPwd() orelse "");
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// The shell-integration path is prepended to `XDG_DATA_DIRS`.
/// It is also saved in the `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
/// so that the shell can refer to it and safely remove this directory
/// from `XDG_DATA_DIRS` when integration is complete.
fn setupXdgDataDirs(
    alloc: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_path = try std.mem.print(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return false;
    };
    integ_dir.close(global.io());

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integ_path);

    // We attempt to avoid allocating by using the stack up to 4K.
    // Max stack size is considerably larger on mac
    // 4K is a reasonable size for this for most cases. However, env
    // vars can be significantly larger so if we have to we fall
    // back to a heap allocated value.
    var stack_alloc_state_buf: [4096]u8 = undefined;
    var stack_alloc_state: std.heap.BufferFirstAllocator = .init(&stack_alloc_state_buf, alloc);
    const stack_alloc = stack_alloc_state.allocator();

    // If no XDG_DATA_DIRS set use the default value as specified.
    // This ensures that the default directories aren't lost by setting
    // our desired integration dir directly. See #2711.
    // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_path,
        ),
    );

    return true;
}

/// Prepend a value to an environment variable such as PATH.
/// The returned value is always allocated so it must be freed.
fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    // If there is no prior value, we return it as-is
    if (current.len == 0) return try alloc.dupe(u8, value);

    return try alloc.print("{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}

test "xdg: empty XDG_DATA_DIRS" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration:/usr/local/share:/usr/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: existing XDG_DATA_DIRS" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("XDG_DATA_DIRS", "/opt/share");

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration:/opt/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(!try setupXdgDataDirs(alloc, resources_dir, &env));
    try testing.expectEqual(0, env.count());
}

/// Set up automatic Nushell shell integration. This works by adding our
/// shell resource directory to the `XDG_DATA_DIRS` environment variable,
/// which Nushell will use to load `nushell/vendor/autoload/ghostty.nu`.
///
/// We then add `--execute 'use ghostty ...'` to the nu command line to
/// automatically enable our shelll features.
fn setupNushell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Add our XDG_DATA_DIRS entry (for nushell/vendor/autoload/). This
    // makes our 'ghostty' module automatically available, even if any
    // of the later checks abort the rest of our automatic integration.
    if (!try setupXdgDataDirs(alloc, resource_dir, env)) return null;

    var stack_fallback_buf: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buf, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.allocator());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;

    // Tell nu to immediately "use" all of the exported functions in our
    // 'ghostty' module.
    //
    // We can consider making this more specific based on the set of
    // enabled shell features (e.g. `use ghostty sudo`). At the moment,
    // shell features are all runtime-guarded in the nushell script.
    try cmd.appendArg("--execute 'use ghostty *'");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration module.
    //
    // Unsupported options:
    //  -c / --command      -c is always non-interactive
    //  --lsp               --lsp starts the language server
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--lsp")) {
            return null;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeSentinel(u8, cmd.buffer.written(), 0) };
}

test "nushell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupNushell(alloc, .{ .shell = "nu" }, res.path, &env);
    try testing.expectEqualStrings("nu --execute 'use ghostty *'", command.?.shell);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectStringStartsWith(
        env.get("XDG_DATA_DIRS").?,
        try std.mem.print(&path_buf, "{s}/shell-integration", .{res.path}),
    );
}

test "nushell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "nu --command exit",
        "nu --lsp",
        "nu -c script.sh",
        "nu -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupNushell(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expect(env.get("XDG_DATA_DIRS") != null);
        try testing.expect(env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR") != null);
    }
}

test "nushell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupNushell(alloc, .{ .shell = "nu" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// The command PowerShell runs to load our integration script. It reads
/// the script as text and runs it in the global scope rather than
/// dot-sourcing the file or passing it to `-File`, because the execution
/// policy governs script files: Windows' default policy (Restricted)
/// refuses both, and RemoteSigned refuses a downloaded copy (one with a
/// Mark-of-the-Web), but neither stops this. The try/catch leaves a
/// working shell, with one line on stderr, if the script fails. It has
/// no double quotes, so a Windows command line needs no escapes for it.
const powershell_loader = "try { . ([scriptblock]::Create([IO.File]::ReadAllText(" ++
    "[IO.Path]::Combine($env:GHOSTTY_RESOURCES_DIR, 'shell-integration', " ++
    "'powershell', 'ghostty.ps1')))) } catch { [Console]::Error.WriteLine(" ++
    "'ghostty: shell integration failed: ' + $_) }";

/// `powershell_loader` quoted for the POSIX shell that runs a `.shell`
/// command (`/bin/sh -c`, or bash's `exec` on macOS): in single quotes,
/// with each of its own single quotes closed, escaped and reopened.
const powershell_loader_posix = quoted: {
    @setEvalBranchQuota(10_000);
    var out: []const u8 = "'";
    for (powershell_loader) |c| {
        if (c == '\'') out = out ++ "'\\''" else out = out ++ [1]u8{c};
    }
    break :quoted out ++ "'";
};

/// A PowerShell parameter that may come before our `-NoExit -Command`:
/// one that neither runs a command or a file nor makes the session
/// non-interactive. PowerShell takes any prefix of a parameter's name at
/// least `min` letters long (`-nop` is `-NoProfile`), and a `-`, `--` or
/// `/` in front of it (`MatchSwitch` and `GetSwitchKey` in PowerShell's
/// CommandLineParameterParser.cs).
const PowerShellParameter = struct {
    name: []const u8,
    min: usize,

    /// Whether the parameter takes the next argument as its value.
    value: bool = false,
};

/// The parameters we keep. Every other argument stops the integration,
/// rather than only the ones that run something (`-Command`, `-File`,
/// `-EncodedCommand`, ...): PowerShell takes a first argument that isn't
/// a parameter as a file (`pwsh script.ps1`, or a command for Windows
/// PowerShell), and a parameter by any long enough prefix, so a list of
/// what to refuse would have to follow every name PowerShell knows. No
/// prefix of these matches a parameter that PowerShell checks before
/// them.
const powershell_parameters = [_]PowerShellParameter{
    .{ .name = "nologo", .min = 3 },
    .{ .name = "noprofile", .min = 3 },
    .{ .name = "noprofileloadtime", .min = 17 },
    .{ .name = "login", .min = 1 },
    .{ .name = "interactive", .min = 1 },
    .{ .name = "sta", .min = 3 },
    .{ .name = "mta", .min = 3 },
    .{ .name = "executionpolicy", .min = 2, .value = true },
    .{ .name = "ep", .min = 2, .value = true },
    .{ .name = "windowstyle", .min = 1, .value = true },
    .{ .name = "workingdirectory", .min = 2, .value = true },
    .{ .name = "wd", .min = 2, .value = true },
};

/// The parameter an argument names, if it is one of
/// `powershell_parameters`. We take only a `-` or `--` in front of it.
fn powershellParameter(arg: []const u8) ?PowerShellParameter {
    const key = if (std.mem.startsWith(u8, arg, "--"))
        arg[2..]
    else if (std.mem.startsWith(u8, arg, "-"))
        arg[1..]
    else
        return null;

    for (powershell_parameters) |param| {
        if (key.len >= param.min and
            std.ascii.startsWithIgnoreCase(param.name, key)) return param;
    }

    return null;
}

/// Set up the PowerShell automatic shell integration. PowerShell has no
/// startup hook we can point at our script (like bash's ENV or zsh's
/// ZDOTDIR), so we append `-NoExit -Command` with `powershell_loader`.
/// It runs after the user's profile, so our script can wrap the prompt
/// that the profile defines.
///
/// This works for PowerShell 7 (`pwsh`) on every platform and for Windows
/// PowerShell 5.1 (`powershell`).
fn setupPowerShell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
) !?config.Command {
    var args: std.ArrayList([:0]const u8) = .empty;

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    const exe = iter.next() orelse return null;
    try args.append(alloc, try alloc.dupeSentinel(u8, exe, 0));

    // Walk through the rest of the given arguments. If we see one that
    // isn't a parameter we know to keep, we bail out and skip loading our
    // shell integration. Users can still manually load the shell
    // integration script.
    while (iter.next()) |arg| {
        const param = powershellParameter(arg) orelse return null;
        try args.append(alloc, try alloc.dupeSentinel(u8, arg, 0));
        if (param.value) {
            const value = iter.next() orelse return null;
            // Windows writes an empty argument as nothing at all, which
            // would make the next argument the value.
            if (value.len == 0) return null;
            try args.append(alloc, try alloc.dupeSentinel(u8, value, 0));
        }
    }

    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.mem.print(
        &script_path_buf,
        "{s}/shell-integration/powershell/ghostty.ps1",
        .{resource_dir},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        return null;
    }

    // PowerShell takes everything after `-Command` as the command, so it
    // must come last.
    switch (command) {
        .direct => {},
        .shell => |v| if (comptime builtin.target.os.tag != .windows) {
            // We append to the command as it was written, rather than
            // joining the arguments we parsed, so that the shell that runs
            // it (`/bin/sh -c`, or bash's `exec` on macOS) sees the same
            // quoting and expansions as without us.
            return .{ .shell = try alloc.printSentinel(
                "{s} -NoExit -Command {s}",
                .{ v, powershell_loader_posix },
                0,
            ) };
        },
    }

    // A direct command, or a shell command on Windows, where execCommand
    // splits it on whitespace without honoring quotes, which would split
    // the loader.
    try args.appendSlice(alloc, &.{ "-NoExit", "-Command", powershell_loader });
    return .{ .direct = try args.toOwnedSlice(alloc) };
}

test "powershell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    // A direct command keeps its arguments, and our own come last.
    {
        const command = try setupPowerShell(alloc, .{ .direct = &.{
            "pwsh",
            "-NoLogo",
        } }, res.path);
        try expectArgs(&.{
            "pwsh",
            "-NoLogo",
            "-NoExit",
            "-Command",
            powershell_loader,
        }, command.?.direct);
    }

    if (comptime builtin.target.os.tag == .windows) {
        const command = try setupPowerShell(alloc, .{
            .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo",
        }, res.path);
        try expectArgs(&.{
            "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
            "-NoLogo",
            "-NoExit",
            "-Command",
            powershell_loader,
        }, command.?.direct);
    } else {
        const command = try setupPowerShell(alloc, .{
            .shell = "\"/a b/pwsh\" -NoLogo",
        }, res.path);
        try testing.expectEqualStrings(
            "\"/a b/pwsh\" -NoLogo -NoExit -Command " ++ powershell_loader_posix,
            command.?.shell,
        );

        // The shell that runs the command must see our arguments as we
        // meant them, the loader as one.
        const run = try std.process.run(alloc, testing.io, .{ .argv = &.{
            "/bin/sh",
            "-c",
            try alloc.print("printf '%s\\n' {s}", .{command.?.shell}),
        } });
        try testing.expect(run.term == .exited and run.term.exited == 0);
        try testing.expectEqualStrings(
            "/a b/pwsh\n-NoLogo\n-NoExit\n-Command\n" ++ powershell_loader ++ "\n",
            run.stdout,
        );
    }
}

test "powershell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "pwsh -Command exit",
        "pwsh -c exit",
        "pwsh -com exit",
        "pwsh -CommandWithArgs exit",
        "pwsh -cwa exit",
        "pwsh -File script.ps1",
        "pwsh -f script.ps1",
        "pwsh script.ps1",
        "pwsh -EncodedCommand ZQB4AGkAdAA=",
        "pwsh -e ZQB4AGkAdAA=",
        "pwsh -ec ZQB4AGkAdAA=",
        "pwsh -NonInteractive",
        "pwsh -noni",
        "pwsh -NoExit",
        "pwsh -NoE",
        "pwsh -Version",
        "pwsh -v",
        "pwsh -Help",
        "pwsh -h",
        "pwsh -?",
        "pwsh -ConfigurationName x",
        "pwsh -SettingsFile x",
        "pwsh -OutputFormat Text",
        "pwsh -InputFormat Text",
        "pwsh -inp Text",
        "pwsh -no",
        "pwsh -st",
        "pwsh -",
        "pwsh --",
        "pwsh ---NoLogo",
        "pwsh /NoLogo",
        "pwsh -ExecutionPolicy:Bypass",
        "pwsh -ExecutionPolicy",
        "pwsh -NoLogo -wd",
        "pwsh -wd \"\"",
        "pwsh -NoLogo -Command exit",
    };

    for (cmdlines) |cmdline| {
        const command = try setupPowerShell(alloc, .{ .shell = cmdline }, res.path);
        if (command != null) {
            std.log.err("not refused: {s}", .{cmdline});
            return error.TestUnexpectedResult;
        }
    }
}

test "powershell: empty value" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    // Windows writes an empty argument as nothing at all, so PowerShell
    // would take the `-NoExit` after it as the value.
    const args = [_][:0]const u8{ "pwsh", "-wd", "" };
    try testing.expect(try setupPowerShell(alloc, .{ .direct = &args }, res.path) == null);
}

test "powershell: supported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.powershell);
    defer res.deinit();

    // Every parameter we keep, by its shortest name or another prefix, and
    // with `-` or `--`.
    const args = [_][:0]const u8{
        "pwsh",
        "-nol",
        "--NoProfile",
        "-NoProfileLoadTime",
        "-l",
        "-Interactive",
        "-STA",
        "-mta",
        "-ex",
        "Bypass",
        "-EP",
        "RemoteSigned",
        "-w",
        "Normal",
        "-wo",
        "/a b",
        "--wd",
        "/tmp",
    };
    const command = try setupPowerShell(alloc, .{ .direct = &args }, res.path);
    try expectArgs(&(args ++ .{ "-NoExit", "-Command", powershell_loader }), command.?.direct);
}

test "powershell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The shell-integration/powershell directory, without the script.
    var res: TmpResourcesDir = try .init(.elvish);
    defer res.deinit();
    try res.tmp_dir.dir.createDirPath(testing.io, "shell-integration/powershell");

    try testing.expect(try setupPowerShell(alloc, .{ .shell = "pwsh" }, res.path) == null);
}

/// Expect a command's arguments to be the given ones.
fn expectArgs(expected: []const []const u8, actual: []const [:0]const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
fn setupZsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Preserve an existing ZDOTDIR value. We're about to overwrite it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR to point to our shell resource directory.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const integ_path = try std.mem.print(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return null;
    };
    integ_dir.close(global.io());
    try env.put("ZDOTDIR", integ_path);

    return try command.clone(alloc);
}

test "zsh" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expect(env.get("GHOSTTY_ZSH_ZDOTDIR") == null);
}

test "zsh: ZDOTDIR" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("ZDOTDIR", "$HOME/.config/zsh");

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expectEqualStrings("$HOME/.config/zsh", env.get("GHOSTTY_ZSH_ZDOTDIR").?);
}

test "zsh: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupZsh(alloc, .{ .shell = "zsh" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Test helper that creates a temporary resources directory with shell integration paths.
const TmpResourcesDir = struct {
    tmp_dir: std.testing.TmpDir,
    path: [:0]const u8,
    shell_path: []const u8,

    fn init(shell: Shell) !TmpResourcesDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const relative_shell_path = try std.mem.print(
            &path_buf,
            "shell-integration/{s}",
            .{@tagName(shell)},
        );
        try tmp_dir.dir.createDirPath(std.testing.io, relative_shell_path);

        const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);

        const shell_path = try std.testing.allocator.print(
            "{s}/{s}",
            .{ path, relative_shell_path },
        );
        errdefer std.testing.allocator.free(shell_path);

        switch (shell) {
            .bash => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/bash/ghostty.bash",
                .data = "",
            }),
            .powershell => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/powershell/ghostty.ps1",
                .data = "",
            }),
            else => {},
        }

        return .{
            .tmp_dir = tmp_dir,
            .path = path,
            .shell_path = shell_path,
        };
    }

    fn deinit(self: *TmpResourcesDir) void {
        std.testing.allocator.free(self.shell_path);
        std.testing.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};
