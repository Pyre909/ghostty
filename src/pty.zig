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

/// How a pty is opened, beyond its size.
pub const OpenOptions = struct {
    /// Whether the terminal measures a grapheme cluster as one character
    /// (grapheme-width-method = unicode) rather than each codepoint on its
    /// own (legacy). Only Windows uses it: there a console host keeps its
    /// own screen buffer and cursor, so it must measure text as we do.
    grapheme_cluster: bool = true,
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

    pub fn open(size: winsize, opts: OpenOptions) OpenError!Pty {
        _ = size;
        _ = opts;
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
    pub fn open(size: winsize, opts: OpenOptions) OpenError!Pty {
        _ = opts;

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

    /// The pseudoconsole functions a pty is made with, which also resize
    /// and close it: those of Microsoft's ConPTY package
    /// (Microsoft.Windows.Console.ConPTY) when its conpty.dll and
    /// OpenConsole.exe are beside the executable, else kernel32's.
    /// kernel32's resize did resize a pseudoconsole the package made, and
    /// its close did not fail on one, on the Windows 11 tried, but neither
    /// is documented, so a pty keeps the functions that made it.
    ///
    /// kernel32's start the system's conhost.exe, which drops the Kitty
    /// graphics protocol and the replies to OSC 10, 52 and 5522, and
    /// measures some clusters (emoji with skin tone modifiers, ZWJ
    /// sequences, decomposed accents) wider than we do, so a program's
    /// cursor drifts from ours after them. The package's OpenConsole.exe
    /// passes those sequences on, and open tells it to measure as we do.
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
            /// conpty.dll without OpenConsole.exe beside it. The DLL would
            /// then start one from a folder named for the machine's
            /// architecture, a layout we do not install and so refuse, or
            /// else the system's conhost.exe, and succeed either way, so
            /// this is the only place the gap can be seen.
            no_open_console,
            /// conpty.dll did not load.
            load_failed,
            /// conpty.dll lacks one of the three functions.
            no_export,
            /// The package's create failed, so kernel32's made the
            /// pseudoconsole: its DLL starts OpenConsole.exe itself, which
            /// a copy of it that is not a program, or a policy that allows
            /// only ghostty.exe, stops.
            create_failed,
        };

        /// The source whose host an open last logged above debug, as its
        /// tag, or none yet: every terminal opens a pty, and each would
        /// otherwise log the same host again.
        var logged = std.atomic.Value(u8).init(std.math.maxInt(u8));

        /// Whether to log the host of an open with `source` at debug
        /// rather than its own level: after the first, while the source
        /// stays the same.
        fn quiet(source: Source) bool {
            return logged.swap(@backingInt(source), .monotonic) == @backingInt(source);
        }

        /// Log the host an open uses, as `quiet` says.
        fn note(
            source: Source,
            comptime level: std.log.Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (quiet(source)) return log.debug(format, args);
            switch (level) {
                .info => log.info(format, args),
                .warn => log.warn(format, args),
                else => comptime unreachable,
            }
        }

        /// The functions for a pty opened now, from the executable's
        /// folder, not this module's: a program that embeds libghostty
        /// gets the package only with both files beside its own
        /// executable. Each open looks again: after the first,
        /// LoadLibraryExW finds conpty.dll loaded and raises its reference
        /// count, which nothing lowers, so the pseudoconsoles made with it
        /// can always be closed through it.
        fn init() ConPty {
            const alloc = global.alloc();
            const dir = std.process.executableDirPathAlloc(global.io(), alloc) catch |err| {
                note(.no_dll, .warn, "conpty: using the system's, the executable's folder is unknown err={}", .{err});
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
                note(.no_dll, .warn, "conpty: using the system's, a path in {s} could not be made err={}", .{ dir, err });
                return .{ .source = .no_dll };
            };
        }

        fn loadPaths(alloc: std.mem.Allocator, dir: []const u8) !ConPty {
            const io = global.io();
            const dll = try std.fs.path.join(alloc, &.{ dir, "conpty.dll" });
            defer alloc.free(dll);
            std.Io.Dir.accessAbsolute(io, dll, .{}) catch |err| {
                note(.no_dll, .info, "conpty: using the system's, no {s} err={}", .{ dll, err });
                return .{ .source = .no_dll };
            };

            const open_console = try std.fs.path.join(alloc, &.{ dir, "OpenConsole.exe" });
            defer alloc.free(open_console);
            std.Io.Dir.accessAbsolute(io, open_console, .{}) catch |err| {
                note(.no_open_console, .warn, "conpty: using the system's, {s} without {s} err={}", .{ dll, open_console, err });
                return .{ .source = .no_open_console };
            };

            const dll_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, dll);
            defer alloc.free(dll_w);
            // With no critical-error box for this load: for a conpty.dll
            // that is no image, such as one cut short, the loader would
            // otherwise show "Bad Image" and wait for it to be answered,
            // holding the terminal that is opening. Such a DLL is reported
            // below and the system's ConPTY used. This thread's mode only,
            // and back as it was after: the process's mode is the
            // program's, which may embed libghostty. Microsoft's
            // SetThreadErrorMode page explains this mode as preventing
            // "error mode dialogs from hanging the application".
            var mode: windows.DWORD = undefined;
            const no_box = windows.exp.kernel32.SetThreadErrorMode(
                windows.exp.kernel32.GetThreadErrorMode() | windows.SEM_FAILCRITICALERRORS,
                &mode,
            ) != windows.FALSE;
            defer if (no_box) {
                _ = windows.exp.kernel32.SetThreadErrorMode(mode, null);
            };
            const module = windows.exp.kernel32.LoadLibraryExW(
                dll_w,
                null,
                windows.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | windows.LOAD_LIBRARY_SEARCH_SYSTEM32,
            ) orelse {
                note(.load_failed, .warn, "conpty: using the system's, {s} did not load err={}", .{ dll, windows.GetLastError() });
                return .{ .source = .load_failed };
            };

            var conpty: ConPty = .{ .source = .package };
            inline for (.{
                .{ "create", "ConptyCreatePseudoConsole" },
                .{ "resize", "ConptyResizePseudoConsole" },
                .{ "close", "ConptyClosePseudoConsole" },
            }) |f| {
                const proc = windows.exp.kernel32.GetProcAddress(module, f[1]) orelse {
                    note(.no_export, .warn, "conpty: using the system's, {s} has no {s} err={}", .{ dll, f[1], windows.GetLastError() });
                    _ = windows.exp.kernel32.FreeLibrary(module);
                    return .{ .source = .no_export };
                };
                @field(conpty, f[0]) = @ptrCast(@alignCast(proc));
            }
            note(.package, .info, "conpty: using {s}", .{dll});
            return conpty;
        }
    };

    /// Ours: what the console's program writes, read here.
    out_pipe: windows.HANDLE,
    /// Ours: what is written here, the console's program reads.
    in_pipe: windows.HANDLE,
    console: Console,
    size: winsize,

    /// The console host on the other side of the pipes.
    pub const Console = union(enum) {
        /// A pseudoconsole we made, which keeps the host's ends of the
        /// pipes until it is closed.
        conpty: struct {
            pseudo_console: windows.HPCON,
            functions: ConPty,
            out_pipe_pty: windows.HANDLE,
            in_pipe_pty: windows.HANDLE,
        },
        /// A console Windows handed to us (`openHandoff`).
        handoff: Handoff,
        /// A console that `endConsole` closed: only our ends of the
        /// pipes are left.
        ended,
    };

    /// The handles of a console that Windows handed to the default
    /// terminal through ITerminalHandoff3::EstablishPtyHandoff, all owned
    /// by the pty once `openHandoff` succeeds. The host is the console
    /// server, an OpenConsole.exe. While `reference` is open the host
    /// outlives every program of the console; once it is released (the
    /// first `setSize` does, as Windows Terminal releases it after its
    /// first resize) the host ends with the console's last program, as a
    /// console window does. Closing `signal` ends the host at once, and
    /// with it every program of the console: the only way to end them,
    /// as the handle to the program that comes with a handoff has no
    /// PROCESS_TERMINATE access.
    pub const Handoff = struct {
        /// The write end of the host's signal pipe: resize and the like,
        /// as ConptyResizePseudoConsole sends them.
        signal: windows.HANDLE,
        /// A handle to the console's reference object; null once released.
        reference: ?windows.HANDLE,
        /// The console server process, which ends with the console.
        server: windows.HANDLE,
    };

    /// The signal pipe's resize message, a private protocol between
    /// ConPTY and its console host: a u16 code, then the width and height
    /// in characters (PtySignal::ResizeWindow and ResizeWindowData).
    /// Ref: https://github.com/microsoft/terminal/blob/d61c5f920adbc27ae2ee41bd02dd4d5f846818ed/src/host/PtySignalInputThread.hpp#L39-L51
    const signal_resize: u16 = 8;

    pub const OpenError = error{Unexpected};

    /// The two pipes of a pty, both ends.
    const Pipes = struct {
        out_pipe: windows.HANDLE,
        in_pipe: windows.HANDLE,
        out_pipe_pty: windows.HANDLE,
        in_pipe_pty: windows.HANDLE,

        fn close(self: Pipes) void {
            _ = windows.exp.kernel32.CloseHandle(self.in_pipe_pty);
            _ = windows.exp.kernel32.CloseHandle(self.in_pipe);
            _ = windows.exp.kernel32.CloseHandle(self.out_pipe_pty);
            _ = windows.exp.kernel32.CloseHandle(self.out_pipe);
        }
    };

    /// The most columns or rows a console can have: it measures in
    /// SHORTs, half the range of a winsize's fields.
    const max_console = std.math.maxInt(@FieldType(windows.COORD, "X"));

    /// The console's size for `size`: a size past a console's range is
    /// clamped to the largest it can have rather than cast (which is
    /// illegal behavior from 32768 up).
    fn consoleSize(size: winsize) windows.COORD {
        return .{
            .X = @min(size.ws_col, max_console),
            .Y = @min(size.ws_row, max_console),
        };
    }

    /// Open a new PTY with the given initial size.
    pub fn open(size: winsize, opts: OpenOptions) OpenError!Pty {
        const pipes = try openPipes();
        errdefer pipes.close();

        var conpty: ConPty = .init();
        var pseudo_console: windows.HPCON = undefined;
        const coord = consoleSize(size);
        // The package's host is told how the terminal measures text, so
        // that its cursor stays with ours: as graphemes under
        // grapheme-width-method = unicode, by each codepoint's wcwidth
        // under legacy. Each agreed with us on every cluster tried, where
        // the package's other settings did not. A program that switches
        // mode 2027 changes our measurement but not the host's, which is
        // fixed here. kernel32's get none: conhost.exe measured the same
        // with and without the graphemes flag, and the others are not
        // measured there.
        const flags: windows.DWORD = if (conpty.source != .package) 0 else if (opts.grapheme_cluster)
            windows.PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES
        else
            windows.PSEUDOCONSOLE_GLYPH_WIDTH_WCSWIDTH;
        var result = conpty.create(coord, pipes.in_pipe_pty, pipes.out_pipe_pty, flags, &pseudo_console);
        // Where the package's create fails, kernel32's may still work: the
        // files were there, but its OpenConsole.exe may not start.
        if (result != windows.S_OK and conpty.source == .package) {
            ConPty.note(.create_failed, .warn, "conpty: using the system's, the package's pseudoconsole failed err=0x{x}", .{@as(u32, @bitCast(result))});
            conpty = .{ .source = .create_failed };
            result = conpty.create(coord, pipes.in_pipe_pty, pipes.out_pipe_pty, 0, &pseudo_console);
        }
        if (result != windows.S_OK) {
            log.err("conpty: no pseudoconsole err=0x{x}", .{@as(u32, @bitCast(result))});
            return error.Unexpected;
        }

        return .{
            .out_pipe = pipes.out_pipe,
            .in_pipe = pipes.in_pipe,
            .console = .{ .conpty = .{
                .pseudo_console = pseudo_console,
                .functions = conpty,
                .out_pipe_pty = pipes.out_pipe_pty,
                .in_pipe_pty = pipes.in_pipe_pty,
            } },
            .size = size,
        };
    }

    /// A pty for a console handed to us, and the host's ends of its pipes
    /// to return from EstablishPtyHandoff: the caller owns those two (COM
    /// closes them once it has copied them to the host). The pty owns
    /// `handoff` once this succeeds; on a failure it is the caller's
    /// still. The host learns the size from the first `setSize`.
    pub fn openHandoff(handoff: Handoff) OpenError!struct {
        pty: Pty,
        /// The host reads its program's input from it.
        host_in: windows.HANDLE,
        /// The host writes its program's output to it.
        host_out: windows.HANDLE,
    } {
        const pipes = try openPipes();
        return .{
            .pty = .{
                .out_pipe = pipes.out_pipe,
                .in_pipe = pipes.in_pipe,
                .console = .{ .handoff = handoff },
                .size = .{ .ws_row = 0, .ws_col = 0, .ws_xpixel = 0, .ws_ypixel = 0 },
            },
            .host_in = pipes.in_pipe_pty,
            .host_out = pipes.out_pipe_pty,
        };
    }

    /// End the console now, as closing a console window does: its
    /// programs get CTRL_CLOSE_EVENT and end after their handlers (a
    /// handed-off console's end at once). Our ends of the pipes stay
    /// until `deinit`, so a reader still drains what the host writes on
    /// its way out, and ClosePseudoConsole cannot block on a full pipe.
    pub fn endConsole(self: *Pty) void {
        switch (self.console) {
            .conpty => |c| {
                _ = windows.exp.kernel32.CloseHandle(c.in_pipe_pty);
                _ = windows.exp.kernel32.CloseHandle(c.out_pipe_pty);
                c.functions.close(c.pseudo_console);
            },
            .handoff => |h| closeHandoff(h),
            .ended => return,
        }
        self.console = .ended;
    }

    /// The console server of a handed-off console, which ends with the
    /// console; null for any other pty, or once `endConsole` closed it.
    pub fn handoffServer(self: *const Pty) ?windows.HANDLE {
        return switch (self.console) {
            .handoff => |h| h.server,
            .conpty, .ended => null,
        };
    }

    /// Close a handed-off console: the signal pipe and the reference
    /// first, which ends the console and its programs.
    fn closeHandoff(handoff: Handoff) void {
        _ = windows.exp.kernel32.CloseHandle(handoff.signal);
        if (handoff.reference) |r| _ = windows.exp.kernel32.CloseHandle(r);
        _ = windows.exp.kernel32.CloseHandle(handoff.server);
    }

    fn openPipes() OpenError!Pipes {
        var pty: Pipes = undefined;

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
        return pty;
    }

    pub fn deinit(self: *Pty) void {
        switch (self.console) {
            .conpty => |c| {
                (Pipes{
                    .out_pipe = self.out_pipe,
                    .in_pipe = self.in_pipe,
                    .out_pipe_pty = c.out_pipe_pty,
                    .in_pipe_pty = c.in_pipe_pty,
                }).close();
                c.functions.close(c.pseudo_console);
            },
            .handoff, .ended => {
                self.endConsole();
                _ = windows.exp.kernel32.CloseHandle(self.in_pipe);
                _ = windows.exp.kernel32.CloseHandle(self.out_pipe);
            },
        }
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
        switch (self.console) {
            .conpty => |c| {
                const result = c.functions.resize(
                    c.pseudo_console,
                    consoleSize(size),
                );
                if (result != windows.S_OK) return error.ResizeFailed;
            },
            .handoff => |*h| {
                // The host's signal pipe is synchronous and it reads it on
                // its own thread, so a message this small never waits.
                const message = [3]u16{
                    signal_resize,
                    @min(size.ws_col, max_console),
                    @min(size.ws_row, max_console),
                };
                var put: windows.DWORD = 0;
                if (windows.exp.kernel32.WriteFile(h.signal, &message, @sizeOf(@TypeOf(message)), &put, null) == windows.FALSE or
                    put != @sizeOf(@TypeOf(message)))
                {
                    log.warn("handoff: resize not sent err={}", .{windows.GetLastError()});
                    return error.ResizeFailed;
                }
                // The host has our size: the console may now end with
                // its last program, as Windows Terminal lets it
                // (ConptyConnection::Start releases it after its first
                // resize).
                if (h.reference) |r| {
                    _ = windows.exp.kernel32.CloseHandle(r);
                    h.reference = null;
                }
            },
            // No console left to tell.
            .ended => {},
        }
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

    var pty = try Pty.open(ws, .{});
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

    // With OpenConsole.exe beside it, it is loaded, which fails, with no
    // error box. On Windows 11 the loader's box showed only when both the
    // process's and the thread's error modes allowed it, so both are set to
    // the system's default, 0, first, which a program can inherit from
    // what started it: a runner started with SEM_FAILCRITICALERRORS would
    // hide the box. Without the load's own mode the box waits for an
    // answer and the test never ends. The load leaves the thread's mode as
    // it found it. The process's mode is put back at once: every thread
    // has it.
    var mode: windows.DWORD = undefined;
    try testing.expect(windows.exp.kernel32.SetThreadErrorMode(0, &mode) != windows.FALSE);
    defer _ = windows.exp.kernel32.SetThreadErrorMode(mode, null);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "OpenConsole.exe", .data = "" });
    const process_mode = windows.exp.kernel32.SetErrorMode(0);
    const loaded = ConPty.load(alloc, dir);
    _ = windows.exp.kernel32.SetErrorMode(process_mode);
    try expectSystem(loaded, .load_failed);
    try testing.expectEqual(@as(windows.DWORD, 0), windows.exp.kernel32.GetThreadErrorMode());

    // A DLL without the ConPTY functions, which is freed: the loader no
    // longer has it, and its file can be deleted.
    var system_w: [windows.MAX_PATH]u16 = undefined;
    const system_len = windows.exp.kernel32.GetSystemDirectoryW(&system_w, system_w.len);
    try testing.expect(system_len > 0 and system_len < system_w.len);
    const system = try std.unicode.wtf16LeToWtf8Alloc(alloc, system_w[0..system_len]);
    defer alloc.free(system);
    const version = try std.fs.path.join(alloc, &.{ system, "version.dll" });
    defer alloc.free(version);
    try std.Io.Dir.cwd().copyFile(version, tmp.dir, "conpty.dll", testing.io, .{});
    const dll = try std.fs.path.join(alloc, &.{ dir, "conpty.dll" });
    defer alloc.free(dll);
    const dll_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, dll);
    defer alloc.free(dll_w);
    try expectSystem(ConPty.load(alloc, dir), .no_export);
    try testing.expect(windows.exp.kernel32.GetModuleHandleW(dll_w) == null);

    // Failing to allocate a path also falls back to kernel32's, and frees
    // the paths allocated before it.
    try testing.checkAllAllocationFailures(alloc, struct {
        fn f(a: std.mem.Allocator, d: []const u8) !void {
            try testing.expectEqual(ConPty.Source.no_export, (try ConPty.loadPaths(a, d)).source);
        }
    }.f, .{dir});
    var failing: testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    try expectSystem(ConPty.load(failing.allocator(), dir), .no_dll);
    try testing.expect(windows.exp.kernel32.GetModuleHandleW(dll_w) == null);
    try tmp.dir.deleteFile(testing.io, "conpty.dll");
}

test "WindowsPty: a size past a console's range is clamped" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    const fits: winsize = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    const wide: winsize = .{ .ws_row = 24, .ws_col = 40000, .ws_xpixel = 0, .ws_ypixel = 0 };
    const tall: winsize = .{ .ws_row = 40000, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    try testing.expectEqual(windows.COORD{ .X = 80, .Y = 24 }, WindowsPty.consoleSize(fits));
    try testing.expectEqual(windows.COORD{ .X = 32767, .Y = 24 }, WindowsPty.consoleSize(wide));
    try testing.expectEqual(windows.COORD{ .X = 80, .Y = 32767 }, WindowsPty.consoleSize(tall));

    // A console takes the clamped size, when it is made and when it is
    // resized (measured: 32767 columns, without error). Unclamped, the
    // cast of 40000 columns to a SHORT is checked illegal behavior.
    var pty = try Pty.open(wide, .{});
    defer pty.deinit();
    try pty.setSize(fits);
    try pty.setSize(wide);
    // The pty reports the size it was given, not the console's.
    try testing.expectEqual(wide, try pty.getSize());
}

test "WindowsPty: the console host is logged once while it stays the same" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const ConPty = WindowsPty.ConPty;

    ConPty.logged.store(std.math.maxInt(u8), .monotonic);
    try testing.expect(!ConPty.quiet(.package));
    try testing.expect(ConPty.quiet(.package));
    try testing.expect(ConPty.quiet(.package));

    // A change is logged, and so is the change back.
    try testing.expect(!ConPty.quiet(.no_dll));
    try testing.expect(ConPty.quiet(.no_dll));
    try testing.expect(!ConPty.quiet(.package));
}

/// The resize message waiting on a handoff's signal pipe. Peeks before
/// it reads, so that a message that was not sent fails the test rather
/// than hanging it.
fn testSignalMessage(read: windows.HANDLE) ![3]u16 {
    const k32 = windows.exp.kernel32;
    var message: [3]u16 = undefined;
    var avail: windows.DWORD = 0;
    try std.testing.expect(k32.PeekNamedPipe(read, null, 0, null, &avail, null) != windows.FALSE);
    try std.testing.expect(avail >= @sizeOf(@TypeOf(message)));
    var got: windows.DWORD = 0;
    try std.testing.expect(k32.ReadFile(read, &message, @sizeOf(@TypeOf(message)), &got, null) != windows.FALSE);
    try std.testing.expectEqual(@sizeOf(@TypeOf(message)), got);
    return message;
}

/// Every write end of the pipe is closed and nothing is left in it. A
/// peek, not a read, so that an open end fails the test rather than
/// hanging it.
fn testPipeClosed(read: windows.HANDLE) !void {
    const k32 = windows.exp.kernel32;
    try std.testing.expect(k32.PeekNamedPipe(read, null, 0, null, null, null) == windows.FALSE);
    try std.testing.expectEqual(std.os.windows.Win32Error.BROKEN_PIPE, windows.GetLastError());
}

test "WindowsPty: a handed-off console resizes and ends through its handles" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const k32 = windows.exp.kernel32;

    // Stand-ins for the host: a pipe each for the signal, the reference
    // and the server, whose read ends show what the pty sent and when it
    // closed its ends.
    var ends: [3][2]windows.HANDLE = undefined;
    for (&ends) |*e| try testing.expect(k32.CreatePipe(&e[0], &e[1], null, 0) != windows.FALSE);
    defer for (ends) |e| {
        _ = k32.CloseHandle(e[0]);
    };

    const opened = try WindowsPty.openHandoff(.{
        .signal = ends[0][1],
        .reference = ends[1][1],
        .server = ends[2][1],
    });
    var pty = opened.pty;
    defer _ = k32.CloseHandle(opened.host_in);

    // A resize is the host's resize message on the signal pipe.
    const size: winsize = .{ .ws_row = 31, .ws_col = 101, .ws_xpixel = 0, .ws_ypixel = 0 };
    try pty.setSize(size);
    try testing.expectEqual(size, try pty.getSize());
    try testing.expectEqual([3]u16{ 8, 101, 31 }, try testSignalMessage(ends[0][0]));
    // A size past a console's range is sent as the largest it has.
    try pty.setSize(.{ .ws_row = 40000, .ws_col = 32768, .ws_xpixel = 0, .ws_ypixel = 0 });
    try testing.expectEqual([3]u16{ 8, 32767, 32767 }, try testSignalMessage(ends[0][0]));
    // With our size sent, the reference is released, as Windows
    // Terminal releases it: the console may end with its last program.
    try testPipeClosed(ends[1][0]);
    try testing.expectEqual(ends[2][1], pty.handoffServer().?);
    var buf: [32]u8 = undefined;
    var got: windows.DWORD = 0;

    // What the host writes, the pty reads.
    const text = "handed off";
    try testing.expect(k32.WriteFile(opened.host_out, text, text.len, &got, null) != windows.FALSE);
    _ = k32.CloseHandle(opened.host_out);
    try testing.expect(k32.ReadFile(pty.out_pipe, &buf, buf.len, &got, null) != windows.FALSE);
    try testing.expectEqualStrings(text, buf[0..got]);

    // Closing the pty closes every handle of the console, which is what
    // ends the host and its program.
    pty.deinit();
    for (ends) |e| try testPipeClosed(e[0]);
}
