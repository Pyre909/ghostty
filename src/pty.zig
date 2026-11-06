const std = @import("std");
const builtin = @import("builtin");
const windows = @import("os/main.zig").windows;
const global = @import("global.zig");
const posix = std.posix;
const assert = @import("quirks.zig").inlineAssert;

const log = std.log.scoped(.pty);

/// Redeclare this winsize struct so we can just use a Zig struct. This
/// layout should be correct on all tested platforms. The defaults on this
/// are some reasonable screen size but you should probably not use them.
pub const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

pub const Pty = switch (builtin.target.os.tag) {
    .windows => WindowsPty,
    .ios => NullPty,
    else => PosixPty,
};

/// The modes of a pty. Not all of these modes are supported on
/// all platforms but all platforms share the same mode struct.
///
/// The default values of fields in this struct are set to the
/// most typical values for a pty. This makes it easier for cross-platform
/// code which doesn't support all of the modes to work correctly.
pub const Mode = packed struct {
    /// ICANON on POSIX
    canonical: bool = true,

    /// ECHO on POSIX
    echo: bool = true,
};

pub const ProcessInfo = enum {
    /// The PID of the process that controls the PTY.
    foreground_pid,
    /// Gets the name of the slave PTY. Returned name points to an internal buffer
    /// so it should not be modified or freed.
    tty_name,

    pub fn Type(comptime info: ProcessInfo) type {
        return switch (info) {
            .foreground_pid => u64,
            .tty_name => [:0]const u8,
        };
    }
};

// A pty implementation that does nothing.
//
// TODO: This should be removed. This is only temporary until we have
// a termio that doesn't use a pty. This isn't used in any user-facing
// artifacts, this is just a stopgap to get compilation to work on iOS.
const NullPty = struct {
    pub const Error = OpenError || GetModeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    master: Fd,
    slave: Fd,

    pub const OpenError = error{};

    pub fn open(size: winsize) OpenError!Pty {
        _ = size;
        return .{ .master = 0, .slave = 0 };
    }

    pub fn deinit(self: *Pty) void {
        _ = self;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        _ = self;
        return .{};
    }

    pub const SetSizeError = error{};

    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        _ = self;
        _ = size;
    }

    pub const ChildPreExecError = error{};

    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        _ = self;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *Pty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

/// Posix PTY creation and management. This is just a thin layer on top
/// of Posix syscalls. The caller is responsible for detail-oriented handling
/// of the returned file handles.
const PosixPty = struct {
    pub const Error = OpenError || GetModeError || GetSizeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    const c = @import("pty-c");

    /// The file descriptors for the master and slave side of the pty.
    /// The slave side is never closed automatically by this struct
    /// so the caller is responsible for closing it if things
    /// go wrong.
    master: Fd,
    slave: Fd,

    /// Buffer for storage of slave tty name so that we don't have to recompute
    /// it every time we need it.
    tty_name_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined,
    /// The name of slave tty. If `null` it has not yet been computed or
    /// may not be available. Should not be accessed directly, but through
    /// `self.getProcessInfo(.tty_name)`
    tty_name: ?[:0]const u8 = null,

    pub const OpenError = error{OpenptyFailed};

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) OpenError!Pty {
        // Need to copy so that it becomes non-const.
        var sizeCopy = size;

        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
        if (c.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&sizeCopy),
        ) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }

        // Set CLOEXEC on the master fd, only the slave fd should be inherited
        // by the child process (shell/command).
        cloexec: {
            const flags = posix.system.fcntl(master_fd, posix.F.GETFD);
            if (flags == -1) {
                log.warn("error getting flags for master fd err=E{s}", .{@tagName(posix.errno(-1))});
                break :cloexec;
            }

            switch (posix.errno(posix.system.fcntl(
                master_fd,
                posix.F.SETFD,
                flags | posix.FD_CLOEXEC,
            ))) {
                .SUCCESS => {},
                else => |e| log.warn("error setting CLOEXEC on master fd err=E{}", .{e}),
            }
        }

        // Enable UTF-8 mode. I think this is on by default on Linux but it
        // is NOT on by default on macOS so we ensure that it is always set.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0)
            return error.OpenptyFailed;
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0)
            return error.OpenptyFailed;

        return .{
            .master = master_fd,
            .slave = slave_fd,
            .tty_name_buf = undefined,
            .tty_name = null,
        };
    }

    pub fn deinit(self: *Pty) void {
        _ = posix.system.close(self.master);
        self.* = undefined;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.master, &attrs) != 0)
            return error.GetModeFailed;

        return .{
            .canonical = (attrs.c_lflag & c.ICANON) != 0,
            .echo = (attrs.c_lflag & c.ECHO) != 0,
        };
    }

    pub const GetSizeError = error{IoctlFailed};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        var ws: winsize = undefined;
        if (c.ioctl(self.master, c.TIOCGWINSZ, @intFromPtr(&ws)) < 0)
            return error.IoctlFailed;

        return ws;
    }

    pub const SetSizeError = error{IoctlFailed};

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        if (c.ioctl(self.master, c.TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
    }

    pub const ChildPreExecError = error{ OperationNotSupported, ProcessGroupFailed, SetControllingTerminalFailed };

    /// This should be called prior to exec in the forked child process
    /// in order to setup the tty properly.
    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        // Reset our signals
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.ABRT, &sa, null);
        posix.sigaction(posix.SIG.ALRM, &sa, null);
        posix.sigaction(posix.SIG.BUS, &sa, null);
        posix.sigaction(posix.SIG.CHLD, &sa, null);
        posix.sigaction(posix.SIG.FPE, &sa, null);
        posix.sigaction(posix.SIG.HUP, &sa, null);
        posix.sigaction(posix.SIG.ILL, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.PIPE, &sa, null);
        posix.sigaction(posix.SIG.SEGV, &sa, null);
        posix.sigaction(posix.SIG.TRAP, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.QUIT, &sa, null);

        // Create a new process group
        if (c.setsid() < 0) return error.ProcessGroupFailed;

        // Set controlling terminal
        switch (posix.errno(c.ioctl(self.slave, c.TIOCSCTTY, @as(c_ulong, 0)))) {
            .SUCCESS => {},
            else => |err| {
                log.err("error setting controlling terminal errno={}", .{err});
                return error.SetControllingTerminalFailed;
            },
        }

        // Can close master/slave pair now
        _ = posix.system.close(self.slave);
        _ = posix.system.close(self.master);
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *PosixPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (info) {
            .foreground_pid => {
                switch (builtin.target.os.tag) {
                    .linux => {
                        const linux = std.os.linux;
                        var pgrp: i32 = undefined;
                        const rc = linux.tcgetpgrp(self.master, &pgrp);
                        switch (rc) {
                            0 => return @intCast(pgrp), // SUCCESS
                            else => return null, // Anything else
                        }
                    },
                    else => {
                        const rc = c.tcgetpgrp(self.master);
                        if (rc < 0) return null;
                        return @intCast(rc);
                    },
                }
            },
            .tty_name => {
                if (self.tty_name) |tty_name| return tty_name;

                switch (builtin.target.os.tag) {
                    .macos => {
                        // The macOS TIOCPTYGNAME ioctl does not allow us to
                        // specify the length of the buffer passed to it, but
                        // expects it to be at least 128 bytes long.
                        assert(self.tty_name_buf.len >= 128);
                        switch (posix.errno(c.ioctl(self.master, c.TIOCPTYGNAME, @intFromPtr(&self.tty_name_buf)))) {
                            .SUCCESS => {
                                const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                                self.tty_name = tty_name;
                                return tty_name;
                            },
                            else => |err| {
                                log.err("error getting name of slave PTY errno={t}", .{err});
                                return null;
                            },
                        }
                    },
                    .linux => {
                        if (c.ptsname_r(self.master, &self.tty_name_buf, self.tty_name_buf.len) != 0) return null;
                        const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                        self.tty_name = tty_name;
                        return tty_name;
                    },
                    else => return null,
                }
            },
        };
    }
};

/// Windows PTY creation and management.
const WindowsPty = struct {
    pub const Error = OpenError || GetSizeError || SetSizeError;

    pub const Fd = windows.HANDLE;

    // Process-wide counter for pipe names
    var pipe_name_counter = std.atomic.Value(u32).init(1);

    /// The pseudoconsole functions a pty is made with, which must also
    /// resize and close it: those of Microsoft's ConPTY package
    /// (Microsoft.Windows.Console.ConPTY) when its conpty.dll and
    /// OpenConsole.exe are beside the executable, else kernel32's.
    ///
    /// kernel32's start the system's conhost.exe, which drops the Kitty
    /// graphics protocol and the replies to OSC 10, 52 and 5522, and
    /// measures some clusters (emoji with skin tone modifiers, ZWJ
    /// sequences, decomposed accents) wider than we do, so the shell's
    /// cursor drifts from ours after them. The package's OpenConsole.exe
    /// passes those sequences on and measures as we do.
    const ConPty = struct {
        create: *const @TypeOf(windows.exp.kernel32.CreatePseudoConsole) = &windows.exp.kernel32.CreatePseudoConsole,
        resize: *const @TypeOf(windows.exp.kernel32.ResizePseudoConsole) = &windows.exp.kernel32.ResizePseudoConsole,
        close: *const @TypeOf(windows.exp.kernel32.ClosePseudoConsole) = &windows.exp.kernel32.ClosePseudoConsole,
        source: Source,

        /// Where the functions came from: the package, or kernel32 and
        /// why.
        const Source = enum {
            /// The package's conpty.dll.
            package,
            /// No conpty.dll beside the executable, or the folder or a
            /// path in it could not be had.
            no_dll,
            /// conpty.dll without OpenConsole.exe. The DLL would start the
            /// system's conhost.exe instead and still succeed, so this is
            /// the only place the gap can be seen.
            no_open_console,
            /// conpty.dll did not load.
            load_failed,
            /// conpty.dll lacks one of the three functions.
            no_export,
        };

        /// The functions for a pty opened now, from the executable's
        /// folder. Each open looks again: after the first, LoadLibraryExW
        /// finds conpty.dll loaded and raises its reference count, which
        /// nothing lowers, so the pseudoconsoles made with it can always
        /// be closed through it.
        fn init() ConPty {
            const alloc = global.alloc();
            const dir = std.process.executableDirPathAlloc(global.io(), alloc) catch |err| {
                log.warn("conpty: using the system's, the executable's folder is unknown err={}", .{err});
                return .{ .source = .no_dll };
            };
            defer alloc.free(dir);
            return load(alloc, dir);
        }

        /// The package's functions if `dir`, an absolute path, holds
        /// conpty.dll and OpenConsole.exe, else kernel32's. A conpty.dll
        /// that loads but lacks a function is freed at once.
        fn load(alloc: std.mem.Allocator, dir: []const u8) ConPty {
            return loadPaths(alloc, dir) catch |err| {
                log.warn("conpty: using the system's, a path in {s} could not be made err={}", .{ dir, err });
                return .{ .source = .no_dll };
            };
        }

        fn loadPaths(alloc: std.mem.Allocator, dir: []const u8) !ConPty {
            const io = global.io();
            const dll = try std.fs.path.join(alloc, &.{ dir, "conpty.dll" });
            defer alloc.free(dll);
            std.Io.Dir.accessAbsolute(io, dll, .{}) catch |err| {
                log.info("conpty: using the system's, no {s} err={}", .{ dll, err });
                return .{ .source = .no_dll };
            };

            const open_console = try std.fs.path.join(alloc, &.{ dir, "OpenConsole.exe" });
            defer alloc.free(open_console);
            std.Io.Dir.accessAbsolute(io, open_console, .{}) catch |err| {
                log.warn("conpty: using the system's, {s} without {s} err={}", .{ dll, open_console, err });
                return .{ .source = .no_open_console };
            };

            const dll_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, dll);
            defer alloc.free(dll_w);
            const module = windows.exp.kernel32.LoadLibraryExW(
                dll_w,
                null,
                windows.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | windows.LOAD_LIBRARY_SEARCH_SYSTEM32,
            ) orelse {
                log.warn("conpty: using the system's, {s} did not load err={}", .{ dll, windows.GetLastError() });
                return .{ .source = .load_failed };
            };

            var conpty: ConPty = .{ .source = .package };
            inline for (.{
                .{ "create", "ConptyCreatePseudoConsole" },
                .{ "resize", "ConptyResizePseudoConsole" },
                .{ "close", "ConptyClosePseudoConsole" },
            }) |f| {
                const proc = windows.exp.kernel32.GetProcAddress(module, f[1]) orelse {
                    log.warn("conpty: using the system's, {s} has no {s} err={}", .{ dll, f[1], windows.GetLastError() });
                    _ = windows.exp.kernel32.FreeLibrary(module);
                    return .{ .source = .no_export };
                };
                @field(conpty, f[0]) = @ptrCast(@alignCast(proc));
            }
            log.info("conpty: using {s}", .{dll});
            return conpty;
        }
    };

    out_pipe: windows.HANDLE,
    in_pipe: windows.HANDLE,
    out_pipe_pty: windows.HANDLE,
    in_pipe_pty: windows.HANDLE,
    pseudo_console: windows.HPCON,
    conpty: ConPty,
    size: winsize,

    pub const OpenError = error{Unexpected};

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize) OpenError!Pty {
        var pty: Pty = undefined;

        var pipe_path_buf: [128]u8 = undefined;
        var pipe_path_buf_w: [128]u16 = undefined;
        const pipe_path = std.mem.printSentinel(
            &pipe_path_buf,
            "\\\\.\\pipe\\LOCAL\\ghostty-pty-{d}-{d}",
            .{
                windows.GetCurrentProcessId(),
                pipe_name_counter.fetchAdd(1, .monotonic),
            },
            0,
        ) catch unreachable;

        const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
            &pipe_path_buf_w,
            pipe_path,
        ) catch unreachable;
        pipe_path_buf_w[pipe_path_w_len] = 0;
        const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

        const security_attributes = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.FALSE,
            .lpSecurityDescriptor = null,
        };

        pty.in_pipe = windows.exp.kernel32.CreateNamedPipeW(
            pipe_path_w.ptr,
            windows.PIPE_ACCESS_OUTBOUND |
                windows.FILE_FLAG_FIRST_PIPE_INSTANCE |
                windows.FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            &security_attributes,
        );
        if (pty.in_pipe == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        errdefer _ = windows.exp.kernel32.CloseHandle(pty.in_pipe);

        var security_attributes_read = security_attributes;
        pty.in_pipe_pty = windows.exp.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (pty.in_pipe_pty == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        errdefer _ = windows.exp.kernel32.CloseHandle(pty.in_pipe_pty);

        // The in_pipe needs to be created as a named pipe, since anonymous
        // pipes created with CreatePipe do not support overlapped operations,
        // and the IOCP backend of libxev only uses overlapped operations on files.
        //
        // It would be ideal to use CreatePipe here, so that our pipe isn't
        // visible to any other processes.

        // if (windows.exp.kernel32.CreatePipe(&pty.in_pipe_pty, &pty.in_pipe, null, 0) == 0) {
        //     return windows.unexpectedError(windows.kernel32.GetLastError());
        // }
        // errdefer {
        //     _ = windows.CloseHandle(pty.in_pipe_pty);
        //     _ = windows.CloseHandle(pty.in_pipe);
        // }

        if (windows.exp.kernel32.CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0) == windows.FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        errdefer {
            _ = windows.exp.kernel32.CloseHandle(pty.out_pipe);
            _ = windows.exp.kernel32.CloseHandle(pty.out_pipe_pty);
        }

        const SetHandleInformation = struct {
            fn f(hObject: windows.HANDLE) !void {
                if (windows.exp.kernel32.SetHandleInformation(
                    hObject,
                    windows.HANDLE_FLAG_INHERIT,
                    0,
                ) == windows.FALSE) {
                    return windows.unexpectedError(windows.GetLastError());
                }
            }
        };

        try SetHandleInformation.f(pty.in_pipe);
        try SetHandleInformation.f(pty.in_pipe_pty);
        try SetHandleInformation.f(pty.out_pipe);
        try SetHandleInformation.f(pty.out_pipe_pty);

        pty.conpty = .init();
        const result = pty.conpty.create(
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
            pty.in_pipe_pty,
            pty.out_pipe_pty,
            0,
            &pty.pseudo_console,
        );
        if (result != windows.S_OK) return error.Unexpected;

        pty.size = size;
        return pty;
    }

    pub fn deinit(self: *Pty) void {
        _ = windows.exp.kernel32.CloseHandle(self.in_pipe_pty);
        _ = windows.exp.kernel32.CloseHandle(self.in_pipe);
        _ = windows.exp.kernel32.CloseHandle(self.out_pipe_pty);
        _ = windows.exp.kernel32.CloseHandle(self.out_pipe);
        self.conpty.close(self.pseudo_console);
        self.* = undefined;
    }

    pub const GetSizeError = error{};

    /// Return the size of the pty.
    pub fn getSize(self: Pty) GetSizeError!winsize {
        return self.size;
    }

    pub const SetSizeError = error{ResizeFailed};

    /// Set the size of the pty.
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        const result = self.conpty.resize(
            self.pseudo_console,
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
        );

        if (result != windows.S_OK) return error.ResizeFailed;
        self.size = size;
    }

    /// Get information about the process(es) attached to the PTY. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(_: *WindowsPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

test {
    const testing = std.testing;
    var ws: winsize = .{
        .ws_row = 50,
        .ws_col = 80,
        .ws_xpixel = 1,
        .ws_ypixel = 1,
    };

    var pty = try Pty.open(ws);
    defer pty.deinit();

    // Initialize size should match what we gave it
    try testing.expectEqual(ws, try pty.getSize());

    // Can set and read new sizes
    ws.ws_row *= 2;
    try pty.setSize(ws);
    try testing.expectEqual(ws, try pty.getSize());

    switch (builtin.target.os.tag) {
        .freebsd => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        .linux => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/pts/")),
        .macos => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        else => try testing.expect(pty.getProcessInfo(.tty_name) == null),
    }
}

test "WindowsPty: ConPTY package only with conpty.dll and OpenConsole.exe" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const ConPty = WindowsPty.ConPty;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir);

    const expectSystem = struct {
        fn f(conpty: ConPty, source: ConPty.Source) !void {
            try testing.expectEqual(source, conpty.source);
            try testing.expect(conpty.create == &windows.exp.kernel32.CreatePseudoConsole);
            try testing.expect(conpty.resize == &windows.exp.kernel32.ResizePseudoConsole);
            try testing.expect(conpty.close == &windows.exp.kernel32.ClosePseudoConsole);
        }
    }.f;

    // Neither file.
    try expectSystem(ConPty.load(alloc, dir), .no_dll);

    // OpenConsole.exe alone.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "OpenConsole.exe", .data = "" });
    try expectSystem(ConPty.load(alloc, dir), .no_dll);

    // A conpty.dll that is no DLL, alone: refused before it is loaded,
    // because the package's DLL without OpenConsole.exe would start the
    // system's conhost.exe and report success.
    try tmp.dir.deleteFile(testing.io, "OpenConsole.exe");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "conpty.dll", .data = "not a DLL" });
    try expectSystem(ConPty.load(alloc, dir), .no_open_console);

    // With OpenConsole.exe beside it, it is loaded, which fails.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "OpenConsole.exe", .data = "" });
    try expectSystem(ConPty.load(alloc, dir), .load_failed);

    // A DLL without the ConPTY functions.
    try std.Io.Dir.cwd().copyFile(
        "C:\\Windows\\System32\\version.dll",
        tmp.dir,
        "conpty.dll",
        testing.io,
        .{},
    );
    try expectSystem(ConPty.load(alloc, dir), .no_export);
}
