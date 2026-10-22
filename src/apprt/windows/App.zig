const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Config = configpkg.Config;

const win32 = @import("win32.zig");
const L = win32.L;
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const taskbar = @import("taskbar.zig");
const toast = @import("toast.zig");
const confirm = @import("dialog.zig").confirm;
const fatalNotice = @import("dialog.zig").fatalNotice;
const notice = @import("dialog.zig").notice;
const retry = @import("dialog.zig").retry;
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;
const writeClipboardText = @import("clipboard.zig").writeClipboardText;

const log = std.log.scoped(.win32);

/// Window class names. These are process-global, so they are registered once
/// in `App.init` and unregistered in `App.terminate`.
pub const surface_class_name = "GhosttySurfaceClass";
const app_class_name = "GhosttyAppClass";

/// Posted by `App.wakeup` from arbitrary threads to break `GetMessageW` out of
/// its block so `run` reaches the next `core_app.tick`.
pub const WM_GHOSTTY_WAKEUP: win32.UINT = win32.WM_APP + 1;

/// Posted to a surface window by `Surface.close`. Its handler tears the
/// surface down; see `Surface.destroyPosted`. Posting rather than destroying
/// in place is what keeps teardown out of core stack frames.
pub const WM_GHOSTTY_DESTROY: win32.UINT = win32.WM_APP + 2;

/// Posted to a surface window by `App.openUrl` for a refused OSC 8 link.
/// Its handler shows the notice; `App.openUrl` says why it is posted.
pub const WM_GHOSTTY_LINK_REFUSED: win32.UINT = win32.WM_APP + 3;

/// Posted to the message-only window by a toast's click handler
/// (`toast.Activated`) from a thread of Windows', with the id of the
/// terminal the toast is for (`notificationClicked`).
pub const WM_GHOSTTY_NOTIFICATION: win32.UINT = win32.WM_APP + 4;

/// Timer id for the quit-after-last-window timer on the app's message-only
/// window. Any non-zero value works; it only has to be unique per window.
const quit_timer_id: win32.UINT_PTR = 1;

pub const App = struct {
    core_app: *CoreApp,

    /// The configuration. Owned by this struct, freed in `terminate`.
    ///
    /// Every surface's config is derived from this one
    /// (`apprt.surface.newConfig` in `Surface.create`), and the app-scoped key
    /// path in `CoreApp.keyEvent` reads `rt_app.config.keybind`.
    config: Config,

    hinstance: win32.HINSTANCE,

    /// GetDpiForWindow, resolved at runtime because it does not exist before
    /// Windows 10 1607. Null means every window reports the system DPI.
    get_dpi_for_window: ?win32.GetDpiForWindowFn,

    /// IsWindowArranged, resolved at runtime because it exists only from
    /// Windows 10 1903 and has no import library. Null means no window is
    /// known to be snapped (`Window.isRestored`).
    is_window_arranged: ?win32.IsWindowArrangedFn,

    /// Explorer's TaskbarButtonCreated, registered at startup: sent to a
    /// frame once its taskbar button exists, and again after Explorer
    /// restarts (`Window.taskbar_button`). 0 if it could not be registered,
    /// which leaves the taskbar alone.
    taskbar_created: win32.UINT,

    /// The taskbar buttons' progress bars, made when the first button
    /// exists (`taskbarList`); null before, or while it cannot be made.
    taskbar_list: ?*taskbar.ITaskbarList3,

    /// The system's notifications, made for the first desktop notification
    /// (`notifierFor`); null before, or when they could not be made.
    toasts: ?*toast.Toasts,

    /// What desktop notifications are shown through: `toasts`, or a
    /// test's stand-in.
    notifier: ?toast.Notifier,

    /// Making `toasts` failed, logged once; it is not tried again.
    toasts_failed: bool,

    /// The tag of the last toast shown (`toast.Toast.tag`).
    toast_tag: u64,

    /// A toast's click that came where the focus could not move, for `run`
    /// to make (`notificationMessage`); the latest wins.
    pending_click: ?u64,

    /// `init` entered a single-threaded apartment on this thread, for
    /// `terminate` to leave.
    com_initialized: bool,

    /// Windows' light or dark mode for apps, read when the app starts and
    /// again when a frame hears that it changed (`systemSchemeChanged`).
    system_scheme: apprt.ColorScheme,

    /// The color scheme the core was last told (`syncColorScheme`), null
    /// until it is first told.
    reported_scheme: ?apprt.ColorScheme,

    /// A message-only window. It is the target for `wakeup` and for the quit
    /// timer. Using a window rather than `PostThreadMessageW` is deliberate:
    /// thread messages are silently dropped by the nested modal loops that
    /// Win32 runs during window drags, menus and dialogs, so a wakeup could be
    /// lost exactly when the mailbox needs draining.
    msg_hwnd: win32.HWND,

    /// The terminals this runtime owns. See `surfaceDestroyed` for the
    /// ownership invariant. Each one whose `CoreSurface` is initialized is
    /// also registered with `CoreApp.addSurface`, which is what drives the
    /// quit timer; this list and the core's can differ only while a surface
    /// is being created or torn down.
    surfaces: std.ArrayListUnmanaged(*Surface),

    /// The windows the terminals are in, with the same ownership rule
    /// (`windowDestroyed`).
    windows: std.ArrayListUnmanaged(*Window),

    /// Work the core asked for that `run` has not carried out yet, oldest
    /// first (`Request`): windows and splits, the changes to splits and
    /// the focus moves after them, and a full configuration reload.
    ///
    /// The core asks from inside its own frames: a binding performs the
    /// action from `CoreSurface.keyCallback` (`performBindingAction`).
    /// Creating a terminal there would register a surface with the core in
    /// the middle of that frame and send the new terminal's focus, and the
    /// old one's WM_KILLFOCUS, into a surface whose key callback is still
    /// on the stack; laying terminals out sends them WM_SIZE, which enters
    /// the core; and a reload frees the configuration the binding's actions
    /// live in. So the action only records the request, and `run` carries
    /// it out after its tick (`createRequested`).
    ///
    /// A surface named in a request is always live: a surface clears its
    /// own entries when its teardown starts (`forgetClosing`), before its
    /// address can be reused.
    requests: std.ArrayListUnmanaged(Request),

    /// Set when the loop should stop. Written only on the main thread.
    quit: bool,

    /// The quit-after-last-window timer, in the GTK `Application`'s form
    /// (its `quit_timer`). `run` quits once this is `expired` and no surface
    /// is left.
    ///
    /// Expiry is recorded rather than acted on where it happens. `main` in
    /// main_ghostty.zig calls `startQuitTimer` *before* it calls `run`, and
    /// `quit-after-last-window-closed-delay` is unset by default
    /// (`Config.@"quit-after-last-window-closed-delay"`), i.e. zero delay.
    /// Quitting synchronously at that point would set `quit` before the loop
    /// ever began and the process would exit with its window still on screen.
    quit_timer: enum {
        off,

        /// Armed on `msg_hwnd` as `quit_timer_id`. GTK's carries the glib
        /// source; a window timer is named by its fixed id, so this carries
        /// nothing.
        active,

        expired,
    },

    /// True while `core_app.tick` is on the stack. See `tick`.
    ticking: bool,

    /// Number of modal confirmation prompts (`confirm`) currently open.
    /// Changed only by `beginPrompt` and `endPrompt`.
    ///
    /// A prompt runs a nested message loop, often with a core frame beneath
    /// it (`CoreSurface.close` from `keyCallback`, a clipboard confirmation
    /// from `tick`). Neither ticking nor surface teardown may run inside that
    /// loop; see `canReenterCore`.
    prompt_depth: u32,

    /// Number of system modal loops (window size/move, window menu) the main
    /// thread is currently inside. `run` does not get control back until such
    /// a loop ends, so while this is non-zero the wakeup handler ticks
    /// instead; see `wndProc`.
    modal_loop_depth: u32,

    /// Number of surface teardowns (`Surface.stopCore`) on the stack.
    ///
    /// A teardown pumps messages while it waits for the surface's threads
    /// (`waitForThread`), so another window's WM_GHOSTTY_DESTROY can be
    /// dispatched inside it. `Surface.destroyPosted` defers that one while
    /// this is non-zero, and `repostDeferredDestroys` posts it again:
    /// teardowns run one after another, never one inside another's wait.
    teardown_depth: u32,

    /// Set for the whole of `terminate`. Teardown is driven from there
    /// synchronously, so posted closes and destroys are ignored meanwhile.
    terminating: bool,

    pub const Error = error{
        Win32ClassRegistrationFailed,
        Win32WindowCreationFailed,
        Win32MessageLoopFailed,
        /// A Win32 call that should not fail for a live window did.
        Win32CallFailed,
    };

    /// Always false: this runtime has no IPC channel to an already-running
    /// instance, so every CLI action that would need one honestly reports
    /// "not supported on this platform".
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    /// Work the core asked for that `run` has not carried out yet
    /// (`requests`).
    pub const Request = union(enum) {
        /// A new window, from the surface that asked, if any.
        window: ?*CoreSurface,

        /// A new split beside `parent`, in `direction`.
        split: struct {
            parent: *CoreSurface,
            direction: apprt.action.SplitDirection,
        },

        /// A `goto_split` asked for after a request still waiting here, so
        /// that it moves within the windows and splits made before it
        /// (`gotoSplit`).
        goto: struct {
            from: *CoreSurface,
            to: apprt.action.GotoSplit,
        },

        /// Move a divider, as `resize_split` names it, in the window of
        /// `from` (`resizeSplit`).
        resize: struct {
            from: *CoreSurface,
            value: apprt.action.ResizeSplit,
        },

        /// Give the splits of the window of this surface equal shares
        /// (`equalizeSplits`).
        equalize: *CoreSurface,

        /// Read the configuration from disk again and give it to the core
        /// (`reloadConfig`).
        reload,

        /// Make the window of this surface cover its monitor, or put it
        /// back (`requestFullscreen`).
        fullscreen: *CoreSurface,

        /// Maximize the window of this surface, or restore it
        /// (`requestMaximize`).
        maximize: *CoreSurface,

        /// Zoom the focused terminal of the window of this surface, or end
        /// the zoom (`toggleSplitZoom`).
        zoom: *CoreSurface,

        /// Hide or show the title bar of the window of this surface
        /// (`requestDecorations`).
        decorations: *CoreSurface,

        /// Give every window the decorations the configuration now asks
        /// for (`configChange`).
        redecorate,

        /// Give the window of this surface the size a new one is made with
        /// (`requestResetWindowSize`).
        reset_window_size: *CoreSurface,

        /// Resize the window of this surface for the size a program asked
        /// of it (`requestResizeWindow`).
        resize_window: struct {
            from: *CoreSurface,
            size: apprt.action.ResizeWindow,
        },

        /// Activate the window before or after the one of `from`
        /// (`gotoWindow`).
        goto_window: struct {
            from: *CoreSurface,
            to: apprt.action.GotoWindow,
        },

        /// One of the above whose surface began to close first: it has
        /// nowhere to go.
        dropped,
    };

    /// `main` in main_ghostty.zig declares `var app_runtime: apprt.App =
    /// undefined` on its stack, so this initializes in place and never returns
    /// a value. The App therefore has a stable address for the process
    /// lifetime, which is what lets `Surface.rtApp` hand out a pointer derived
    /// from it.
    pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
        _ = opts;

        const alloc = core_app.alloc;

        // The image base in the PEB is the exe's module handle, the value
        // GetModuleHandleW(NULL) returns. Win32 defines HMODULE as HINSTANCE
        // (minwindef.h); std types them as distinct opaques, so the module
        // handle is cast once, here, where it becomes the window classes'
        // instance.
        const hinstance: win32.HINSTANCE = @ptrCast(std.os.windows.peb().ImageBaseAddress);

        // Per-monitor DPI v2, so the DPI query reports the real value and
        // WM_DPICHANGED arrives with a usable suggested rect.
        //
        // Both DPI entry points are resolved through GetProcAddress rather
        // than statically imported; see the note on
        // win32.SetProcessDpiAwarenessContextFn for why a static import would
        // be a load-time process failure on older Windows rather than a
        // runtime fallback. GetModuleHandleW rather than LoadLibraryW because
        // user32 is already in this binary's import table.
        const user32 = win32.GetModuleHandleW(L("user32.dll"));
        if (user32) |m| {
            if (win32.GetProcAddress(m, "SetProcessDpiAwarenessContext")) |p| {
                const f: win32.SetProcessDpiAwarenessContextFn = @ptrCast(@alignCast(p));
                if (!f(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).toBool()) {
                    // FALSE alone does not mean per-monitor awareness is unavailable.
                    // ERROR_ACCESS_DENIED means the awareness was already set
                    // before this call -- in a normal build by the manifest
                    // embedded from dist/windows/ghostty.manifest, which
                    // declares PerMonitorV2. That is the expected path, so it
                    // is not reported; logEffectiveDpiAwareness states what is
                    // actually in effect either way.
                    const err = win32.GetLastError();
                    if (err != .ACCESS_DENIED) {
                        log.warn("SetProcessDpiAwarenessContext failed err={}", .{err});
                    }
                }
            } else {
                log.info("SetProcessDpiAwarenessContext missing (pre-1703 Windows)", .{});
            }
            logEffectiveDpiAwareness(m);
        }

        const get_dpi_for_window: ?win32.GetDpiForWindowFn = dpi: {
            const m = user32 orelse break :dpi null;
            const p = win32.GetProcAddress(m, "GetDpiForWindow") orelse {
                log.info("GetDpiForWindow missing (pre-1607 Windows), using system DPI", .{});
                break :dpi null;
            };
            break :dpi @ptrCast(@alignCast(p));
        };
        const is_window_arranged: ?win32.IsWindowArrangedFn = arranged: {
            const m = user32 orelse break :arranged null;
            const p = win32.GetProcAddress(m, "IsWindowArranged") orelse {
                log.info("IsWindowArranged missing (pre-1903 Windows), snapped windows are not told apart", .{});
                break :arranged null;
            };
            break :arranged @ptrCast(@alignCast(p));
        };

        // As the GTK runtime does: a configuration that fails to load is
        // recorded as a diagnostic and the defaults are used, which only
        // fail for OOM, so that Ghostty still starts.
        var config = Config.load(alloc) catch |err| err: {
            log.warn("error loading user configuration err={}", .{err});
            var def: Config = try .default(alloc);
            errdefer def.deinit();
            try def.addDiagnosticFmt(
                "error loading user configuration: {}",
                .{err},
            );

            break :err def;
        };
        errdefer config.deinit();

        registerClasses(hinstance) catch |err| {
            fatalNotice(err);
            return err;
        };
        errdefer unregisterClasses(hinstance);

        // The taskbar's object is of an apartment-threaded class, and this
        // thread has the message loop such an apartment needs.
        const com_hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
        if (com_hr < 0) log.warn("CoInitializeEx failed hr=0x{x}", .{@as(u32, @bitCast(com_hr))});
        errdefer if (com_hr >= 0) win32.CoUninitialize();
        const taskbar_created = win32.RegisterWindowMessageW(L("TaskbarButtonCreated"));
        if (taskbar_created == 0) log.warn("RegisterWindowMessageW failed err={}", .{win32.GetLastError()});

        const msg_hwnd = win32.CreateWindowExW(
            0,
            L(app_class_name),
            null,
            0,
            0,
            0,
            0,
            0,
            win32.HWND_MESSAGE,
            null,
            hinstance,
            null,
        ) orelse {
            log.err("failed to create the message-only window", .{});
            fatalNotice(Error.Win32WindowCreationFailed);
            return Error.Win32WindowCreationFailed;
        };
        errdefer _ = win32.DestroyWindow(msg_hwnd);

        self.* = .{
            .core_app = core_app,
            .config = config,
            .hinstance = hinstance,
            .get_dpi_for_window = get_dpi_for_window,
            .is_window_arranged = is_window_arranged,
            .taskbar_created = taskbar_created,
            .taskbar_list = null,
            .toasts = null,
            .notifier = null,
            .toasts_failed = false,
            .toast_tag = 0,
            .pending_click = null,
            .com_initialized = com_hr >= 0,
            .system_scheme = systemColorScheme(),
            .reported_scheme = null,
            .msg_hwnd = msg_hwnd,
            .surfaces = .empty,
            .windows = .empty,
            .requests = .empty,
            .quit = false,
            .quit_timer = .off,
            .ticking = false,
            .prompt_depth = 0,
            .modal_loop_depth = 0,
            .teardown_depth = 0,
            .terminating = false,
        };

        // The app pointer has to be reachable from the message-only window's
        // wndproc. Unlike surface windows (which receive it via CREATESTRUCTW
        // in WM_NCCREATE) the App does not exist yet at CreateWindowExW time,
        // so it is attached here. No message can be dispatched in between:
        // dispatching only happens in `run`.
        _ = win32.SetWindowLongPtrW(
            msg_hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(self)),
        );
    }

    pub fn terminate(self: *App) void {
        // Every remaining window is destroyed with its terminals, as a
        // window close does it (Window.destroy), so that CoreApp.deinit,
        // which `main` runs after this, finds an empty surface list and its
        // `font_grid_set.count() == 0` assert holds.
        //
        // `terminating` makes destroyPosted and close ignore anything still
        // queued: stopCore pumps messages, and a WM_GHOSTTY_DESTROY or
        // WM_CLOSE dispatched there must not start a second teardown (or a
        // confirmation prompt) for a surface this loop is about to handle.
        self.terminating = true;

        // Windows are destroyed before the classes they belong to are
        // unregistered; UnregisterClassW fails while a window of the class
        // still exists.
        //
        // Each window goes as a window close takes it (Window.destroy): its
        // terminals' cores stop, then the frame is destroyed, which frees
        // each terminal and the window (WM_DESTROY -> surfaceDestroyed,
        // WM_NCDESTROY -> windowDestroyed). A frame that could not be
        // destroyed gets none of those messages, so its terminals and the
        // window are released here the same way, or the loop would not end.
        while (self.windows.getLastOrNull()) |window| {
            if (!window.destroy()) {
                log.err("failed to destroy a window err={}", .{win32.GetLastError()});
                // Downwards, as surfaceDestroyed swaps the last one in.
                var i = self.surfaces.items.len;
                while (i > 0) {
                    i -= 1;
                    const surface = self.surfaces.items[i];
                    if (surface.window == window) self.surfaceDestroyed(surface);
                }
                self.windowDestroyed(window);
            }
        }
        self.windows.deinit(self.core_app.alloc);

        // Every terminal is a child window of a frame, so none is left.
        self.surfaces.deinit(self.core_app.alloc);

        // Windows asked for and never created: the process is quitting.
        self.requests.deinit(self.core_app.alloc);

        self.stopQuitTimer();

        _ = win32.DestroyWindow(self.msg_hwnd);
        unregisterClasses(self.hinstance);
        self.config.deinit();

        if (self.taskbar_list) |list| list.release();
        // Each terminal's toasts went with it (`surfaceDestroyed`). Not
        // every toast of the app ID: another Ghostty process shows its own
        // under it.
        if (self.toasts) |t| {
            t.deinit();
            self.core_app.alloc.destroy(t);
        }
        if (self.com_initialized) win32.CoUninitialize();
    }

    /// The taskbar buttons' progress bars, made the first time a button
    /// exists (`Window.taskbar_button`); null, logged, if they cannot be,
    /// and tried again for the next button.
    pub fn taskbarList(self: *App) ?*taskbar.ITaskbarList3 {
        if (self.taskbar_list) |list| return list;
        // Logged by `create`.
        self.taskbar_list = taskbar.create() catch return null;
        return self.taskbar_list;
    }

    /// The Win32 message loop.
    pub fn run(self: *App) !void {
        // The core learns the color scheme before the initial window, so
        // that its terminal starts with it.
        self.syncColorScheme();

        // Create the initial window directly, not through the core's
        // `.new_window` as GTK's `activate` does. If it cannot open, the
        // process has no window at all, and this path says why
        // (`fatalNotice`, e.g. no Direct3D 11) and exits with the error. A
        // queued window would only be reported as one that could not open
        // (`createRequested`), and the launch's quit timer would then
        // end the process with no reason given.
        if (self.config.@"initial-window") {
            _ = self.newWindow(null) catch |err| {
                log.err("failed to create the initial window err={}", .{err});
                fatalNotice(err);
                return err;
            };
        }
        self.showConfigErrors();

        var msg: win32.MSG = undefined;
        while (!self.quit) {
            // Act on an expired quit timer here rather than where it expired
            // (see `quit_timer`): only here is it known both that the loop
            // has started and that no window is on screen.
            if (self.quit_timer == .expired and self.surfaces.items.len == 0) {
                self.logQuitOverride();
                self.quit = true;
                break;
            }

            // Block until something arrives. `wakeup` posts
            // WM_GHOSTTY_WAKEUP to msg_hwnd, so a mailbox push on any thread
            // breaks this out promptly. A wakeup that lands while we are
            // inside tick() is not lost: it sits in the queue and makes the
            // next GetMessageW return immediately.
            const ret = win32.GetMessageW(&msg, null, 0, 0);
            switch (@backingInt(ret)) {
                // GetMessageW reports failure as -1, distinct from the 0 that
                // means WM_QUIT. Treating -1 as "quit" would mask a real bug.
                -1 => {
                    log.err("GetMessageW failed", .{});
                    return Error.Win32MessageLoopFailed;
                },
                0 => break,
                else => {
                    _ = win32.TranslateMessage(&msg);
                    _ = win32.DispatchMessageW(&msg);
                },
            }

            // Drain whatever else is pending so a burst (a resize drag, a
            // flood of wakeups) costs one tick rather than one per message.
            while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
                if (msg.message == win32.WM_QUIT) {
                    self.quit = true;
                    break;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            if (self.quit) break;

            // drainMailbox returns early after dispatching `.quit`, so the
            // queue is not necessarily empty here. The next loop iteration
            // ticks again; `.quit` will have set self.quit if it was seen.
            //
            // `run` is never itself inside a core frame, so `ticking` is
            // always false here and this tick always runs.
            try self.tick();

            // Teardowns that were refused while a core frame or a prompt was
            // on the stack are retried now that neither is.
            self.repostDeferredDestroys();

            // Likewise mouse events a prompt held back, and capture that was
            // lost without a message (Surface.syncMouse).
            self.syncDeferredMouse();

            // And IME work that could not run where it arose (Surface.syncIme).
            self.syncDeferredIme();

            // And the work the core asked for from inside its frames
            // (`requests`), and a focus move one asked for outside a key
            // callback.
            self.createRequested();
            self.applyPendingFocus();

            // And a toast's click a prompt or a teardown held back.
            self.applyPendingClick();

            // And a change of color scheme: of the system's mode, which a
            // prompt may have held back, or of the configuration, which a
            // reload in `requests` may just have made.
            self.syncColorScheme();
        }
    }

    /// Tick the core, unless a tick is already on the stack.
    ///
    /// Reentrancy is possible because a tick can open a modal prompt
    /// (a clipboard confirmation, `Surface.close`), and a prompt's nested
    /// message loop dispatches WM_GHOSTTY_WAKEUP and WM_GHOSTTY_DESTROY.
    /// `drainMailbox` is not written to be reentered, so a nested request is
    /// dropped; the outer tick, or the next one, drains whatever it wanted.
    fn tick(self: *App) !void {
        if (self.ticking) return;
        self.ticking = true;
        defer self.ticking = false;
        try self.core_app.tick(self);
    }

    /// Tick from inside a message handler, where there is no caller to
    /// return an error to. Does nothing unless `canReenterCore`.
    fn tickFromHandler(self: *App) void {
        if (!self.canReenterCore()) return;
        self.tick() catch |err| log.warn("core tick failed err={}", .{err});
    }

    /// Whether a message handler may tick the core or tear a surface down
    /// right now.
    ///
    /// Not while a tick is on the stack (see `tick`). Not while a
    /// confirmation prompt is open either: a prompt usually has a core frame
    /// beneath it, and the teardown a tick can start would free that frame's
    /// surface. The cost is a stall, not a deadlock: output pauses until the
    /// user answers, because nothing drains the app mailbox meanwhile. Surface
    /// teardown is deferred rather than refused (`Surface.destroyPosted`), so
    /// it cannot wait on threads that are blocked on that undrained mailbox.
    pub fn canReenterCore(self: *const App) bool {
        return !self.ticking and self.prompt_depth == 0;
    }

    /// Enter a modal prompt (`dialog.messageBox`, behind `dialog.confirm`,
    /// `dialog.retry` and `dialog.notice`) owned by `owner`, or by no
    /// window.
    ///
    /// No surface can be used while a prompt is open: ticks stop
    /// (`canReenterCore`), so every window's output pauses, and input does
    /// not reach the core. MessageBoxW disables only its owner, though, so
    /// the outermost prompt disables every other window as well, and
    /// `endPrompt` enables them again; a disabled window takes no input for
    /// its terminals either. A window that was already disabled is left as
    /// it was.
    ///
    /// Windows are not created while a prompt is open (only `run` creates
    /// them) and their teardown is deferred, so `endPrompt` finds the
    /// windows disabled here.
    pub fn beginPrompt(self: *App, owner: ?win32.HWND) void {
        self.prompt_depth += 1;
        if (self.prompt_depth > 1) return;
        for (self.windows.items) |window| {
            if (owner != null and window.hwnd == owner.?) continue;
            if (win32.EnableWindow(window.hwnd, .FALSE).toBool()) continue;
            window.prompt_disabled = true;
        }
    }

    /// The window a prompt belongs to: the top-level window of `hwnd`
    /// (a terminal's is its frame), or for a caller that has none, the
    /// window the user was last in, else the first one. With no owner, the
    /// box would leave every window disabled (`beginPrompt`) and the
    /// activation would go to another application when it closes;
    /// MessageBoxW enables its owner again before it returns and hands the
    /// activation back to it. It disables only that owner, so the owner
    /// must be the top-level window, not a terminal inside it.
    pub fn promptOwner(self: *const App, hwnd: ?win32.HWND) ?win32.HWND {
        if (hwnd) |h| return win32.GetAncestor(h, win32.GA_ROOT) orelse h;
        if (self.core_app.focusedSurface()) |s| return s.rt_surface.window.hwnd;
        if (self.windows.items.len > 0) return self.windows.items[0].hwnd;
        return null;
    }

    /// Leave the prompt entered by the matching `beginPrompt`.
    ///
    /// The outermost one wakes `run`. The prompt's message loop dispatched
    /// the wakeups posted while it was open, with no tick (`canReenterCore`),
    /// and a prompt `run` opened outside a tick (`showConfigErrors`) has no
    /// tick after it to drain what they announced, nor to make what its
    /// answer recorded in `requests`. Inside a tick this costs one more tick.
    pub fn endPrompt(self: *App) void {
        self.prompt_depth -= 1;
        if (self.prompt_depth > 0) return;
        for (self.windows.items) |window| {
            if (!window.prompt_disabled) continue;
            window.prompt_disabled = false;
            _ = win32.EnableWindow(window.hwnd, .TRUE);
        }
        self.wakeup();
    }

    /// Whether a posted teardown may run now (`Surface.destroyPosted`,
    /// `Window.destroyPosted`). Not with a core frame or a prompt beneath
    /// (`canReenterCore`): the teardown's wait pumps and ticks, and could
    /// wait on threads blocked behind the undrained mailbox. Nor inside
    /// another teardown's wait (`teardown_depth`): it would nest a second
    /// wait in the first, and with several closing at once each would nest
    /// inside the last.
    pub fn canTearDown(self: *const App) bool {
        return self.canReenterCore() and self.teardown_depth == 0;
    }

    /// Re-post WM_GHOSTTY_DESTROY for every terminal and every window whose
    /// teardown was deferred. Called where `canTearDown` holds: by `run`,
    /// and by `Surface.destroyPosted` and `Window.destroyPosted` once their
    /// own teardown is done.
    pub fn repostDeferredDestroys(self: *App) void {
        for (self.surfaces.items) |surface| {
            if (!surface.destroy_deferred) continue;
            surface.destroy_deferred = false;
            surface.postDestroy();
        }
        for (self.windows.items) |window| {
            if (!window.destroy_deferred) continue;
            window.destroy_deferred = false;
            window.postDestroy();
        }
    }

    /// Bring every live core surface up to date with the mouse
    /// (`Surface.syncMouse`). A prompt answered from the keyboard then does
    /// not leave a button pressed until the next mouse message, and a drag
    /// whose capture ended without a message ends here. Called by `run`,
    /// where `canReenterCore` holds. The list cannot change during the loop:
    /// no mouse callback creates or destroys a surface (`Surface.close` only
    /// posts).
    fn syncDeferredMouse(self: *App) void {
        for (self.surfaces.items) |surface| {
            const core_surface = surface.liveCore() orelse continue;
            _ = surface.syncMouse(core_surface, null);
        }
    }

    /// Finish the IME work of every live core surface (`Surface.syncIme`).
    /// Called by `run`, where `canReenterCore` holds. A result delivered
    /// here can close a surface, but `Surface.close` only posts, so the
    /// list does not change during the loop.
    fn syncDeferredIme(self: *App) void {
        for (self.surfaces.items) |surface| {
            const core_surface = surface.liveCore() orelse continue;
            surface.syncIme(core_surface);
        }
    }

    /// Tell the core the color scheme (`coreScheme`) if it changed: the
    /// app's conditional state, which new terminals start from, and each
    /// live terminal's, which pick the light or dark half of `theme` and
    /// answer a program's color scheme query. For each the core reloads the
    /// configuration softly (`reloadConfig`). Called by `run`, where
    /// `canReenterCore` holds: before the initial window, then after every
    /// tick and the requests after it, which picks up a change of the
    /// system's mode (`systemSchemeChanged`) or of `window-theme` and the
    /// background (`configChange`, as a recorded reload makes it). The
    /// list does not change during the loop: a reload creates and destroys
    /// no surface.
    fn syncColorScheme(self: *App) void {
        const scheme = coreScheme(&self.config, self.system_scheme);
        if (self.reported_scheme == scheme) return;
        self.reported_scheme = scheme;

        self.core_app.colorSchemeEvent(self, scheme) catch |err| {
            log.warn("cannot give the core the color scheme err={}", .{err});
        };
        for (self.surfaces.items) |surface| {
            const core_surface = surface.liveCore() orelse continue;
            core_surface.colorSchemeCallback(scheme) catch |err| {
                log.warn("cannot give a terminal the color scheme err={}", .{err});
            };
        }
    }

    /// A frame heard that Windows' settings changed (WM_SETTINGCHANGE,
    /// "ImmersiveColorSet"); every frame hears it, and `Window.create`
    /// asks too. If the light or dark mode for apps is not the one read
    /// last, every title bar follows at once, and the core hears of it from
    /// `run` (`syncColorScheme`), since a prompt may be open now. The
    /// message is sent, not posted, so GetMessageW in `run` handles it and
    /// keeps waiting: `run` is woken to come round.
    pub fn systemSchemeChanged(self: *App) void {
        const scheme = systemColorScheme();
        if (scheme == self.system_scheme) return;
        self.system_scheme = scheme;
        for (self.windows.items) |window| window.applyTheme();
        self.wakeup();
    }

    /// Wait until the thread `handle` has exited, while keeping the main
    /// thread responsive: messages are dispatched and the core ticked
    /// between wakeups.
    ///
    /// Pumping is required, not cosmetic. The render and IO threads push into
    /// the app mailbox with `.forever` (e.g. the renderer's `frameCompleted`),
    /// and only a tick on this thread drains it; a plain WaitForSingleObject
    /// here could wait on a thread that is waiting on us.
    ///
    /// A WM_QUIT pulled out of the queue while pumping is re-posted
    /// afterwards, so a quit requested meanwhile still ends `run`.
    pub fn waitForThread(self: *App, handle: win32.HANDLE) void {
        var quit_seen = false;
        defer if (quit_seen) win32.PostQuitMessage(0);

        // One-second slices only so that a stuck thread is reported once;
        // the wait itself is unbounded, as the join after it would be.
        var slices: u32 = 0;
        while (true) {
            // Tick before every wait, not only after new input. A wakeup
            // may already have been consumed without a tick (`wndProc`
            // outside a modal loop, or a prompt's message loop), and a
            // producer blocked in a `.forever` push posts no new one until
            // the mailbox is drained, so waiting for input alone could wait
            // forever. An empty mailbox makes this a single locked pop.
            self.tickFromHandler();

            switch (win32.MsgWaitForMultipleObjectsEx(
                1,
                @ptrCast(&handle),
                1000,
                win32.QS_ALLINPUT,
                // Return for input already in the queue too, not only for
                // input that arrives after the call. Without it a message
                // that was peeked but not removed would not wake us.
                win32.MWMO_INPUTAVAILABLE,
            )) {
                // The thread has exited.
                internal_os.windows.WAIT_OBJECT_0 => return,

                // Input. The tick at the top of the loop drains whatever
                // the dispatched messages left in the mailbox.
                internal_os.windows.WAIT_OBJECT_0 + 1 => {
                    var msg: win32.MSG = undefined;
                    while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
                        if (msg.message == win32.WM_QUIT) {
                            quit_seen = true;
                            continue;
                        }
                        _ = win32.TranslateMessage(&msg);
                        _ = win32.DispatchMessageW(&msg);
                    }
                },

                internal_os.windows.WAIT_TIMEOUT => {
                    slices += 1;
                    if (slices == 5) log.warn(
                        "surface thread has not exited after 5s; still waiting",
                        .{},
                    );
                },

                // WAIT_FAILED (a bad handle). There is nothing to wait on
                // reliably any more; the joins in CoreSurface.deinit that
                // follow will block or fail loudly on their own.
                else => |r| {
                    log.err(
                        "MsgWaitForMultipleObjectsEx failed r={x} err={}",
                        .{ r, win32.GetLastError() },
                    );
                    return;
                },
            }
        }
    }

    /// Called from the renderer and IO threads via `CoreApp.Mailbox.push`, so
    /// this must be thread-safe and must not block. PostMessageW is both.
    pub fn wakeup(self: *App) void {
        _ = win32.PostMessageW(self.msg_hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
    }

    /// `main` in main_ghostty.zig calls this before `run` because a freshly
    /// started app has no surfaces yet.
    pub fn startQuitTimer(self: *App) void {
        // The result is dropped because `main` has nothing to do
        // with it; a failure to arm is already logged by setQuitTimer.
        _ = self.setQuitTimer(.start);
    }

    /// Actions this runtime actually performs. Anything not named here
    /// returns `false`, which is the contract's word for "unsupported" -- see
    /// the `apprt.Action` docs (actions are OPTIONAL). Returning `true` for an
    /// action that did not happen would be a lie the core cannot detect.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        return switch (action) {
            .quit => self.requestQuit(),

            // Reports whether the timer actually reached the requested
            // state. A SetTimer that failed means the app will never quit on
            // its own, and `true` would hide that from the core.
            .quit_timer => self.setQuitTimer(value),

            .set_title => self.setTitle(target, value),
            .close_window => self.closeWindow(target),
            .close_tab => self.closeTab(target, value),
            .present_terminal => presentTerminal(target),
            .toggle_maximize => self.requestMaximize(target),
            .toggle_fullscreen => self.requestFullscreen(target),
            .toggle_window_decorations => self.requestDecorations(target),
            .resize_window => self.requestResizeWindow(target, value),
            .reset_window_size => self.requestResetWindowSize(target),
            .copy_title_to_clipboard => copyTitleToClipboard(target),
            .render => render(target),
            .mouse_visibility => mouseVisibility(target, value),
            .mouse_shape => mouseShape(target, value),
            .open_url => openUrl(target, value),
            .open_config => self.openConfig(value),
            .initial_size => initialSize(target, value),
            .reload_config => try self.reloadConfig(target, value),
            .config_change => try self.configChange(target, value),

            .ring_bell => ring_bell: {
                _ = win32.MessageBeep(win32.MB_ICONASTERISK);
                break :ring_bell true;
            },

            .new_window => self.requestWindow(target),
            .new_split => self.requestSplit(target, value),
            .goto_split => self.gotoSplit(target, value),
            .resize_split => self.resizeSplit(target, value),
            .equalize_splits => self.equalizeSplits(target),
            .toggle_split_zoom => self.toggleSplitZoom(target),
            .goto_window => self.gotoWindow(target, value),
            .float_window => floatWindow(target, value),
            .progress_report => progressReport(target, value),
            .desktop_notification => self.desktopNotification(target, value),

            // Everything else, including
            // `.cell_size` and `.size_limit` (sent during CoreSurface.init;
            // `false` is a valid answer to each), and
            // `.mouse_over_link` (a link-preview UI this runtime lacks; the
            // core tracks the link itself and ignores the result,
            // `Surface.mouseRefreshLinks`, `Surface.cursorPosCallback`).
            else => false,
        };
    }

    /// The `.quit` action (the `quit` binding, Ctrl+Shift+Q by default).
    /// As on GTK (`Application.quit`), the user is asked first when any
    /// surface would ask before closing (`CoreApp.needsConfirmQuit`): a
    /// running program, `confirm-close-surface = always`, or a read-only
    /// surface. Declining is still a handled request, so this returns `true`
    /// either way.
    fn requestQuit(self: *App) bool {
        if (self.quit) return true;

        // No owner of its own: promptOwner gives the prompt the window the
        // user was last in.
        if (self.core_app.needsConfirmQuit()) {
            if (!confirm(
                self,
                null,
                L("All terminal sessions will be terminated. Quit Ghostty?"),
                .ok,
            )) return true;
        }

        self.quit = true;
        win32.PostQuitMessage(0);
        return true;
    }

    fn setTitle(
        self: *App,
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        _ = self;
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.setTitle(value.title),
        };
    }

    fn closeWindow(self: *App, target: apprt.Target) bool {
        _ = self;
        return switch (target) {
            .app => false,
            // Never DestroyWindow here: this runs inside a core frame (a
            // keybinding, src/Surface.zig keyCallback -> performBindingAction),
            // and destroying synchronously would free the CoreSurface under
            // it. Window.requestClose confirms if needed and posts the
            // window's teardown, which the title bar button and Alt+F4 (a
            // default binding to this action, `Config.Keybinds.init`) share.
            // A terminal closing alone (close_surface, a child exit) posts
            // its own (Surface.close).
            //
            // `true` means the request was handled. The user may still decline
            // the confirmation; that is a completed close request, not an
            // unsupported action.
            .surface => |v| close: {
                v.rt_surface.window.requestClose();
                break :close true;
            },
        };
    }

    /// `.close_tab`: without tabs a window is its own one tab, so `.this`
    /// closes the window as `close_window` does. That is what the default
    /// Ctrl+Shift+W does on this platform (`Config.Keybinds.init`, where it
    /// replaced `close_surface`), as it closes a tab of one window on GTK.
    /// `.other` and `.right` name other tabs, which there are not: `false`,
    /// unsupported, as for every tab action until tabs exist.
    fn closeTab(self: *App, target: apprt.Target, mode: apprt.action.CloseTabMode) bool {
        return switch (mode) {
            .this => self.closeWindow(target),
            .other, .right => false,
        };
    }

    fn presentTerminal(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| Window.present(v.rt_surface.window.hwnd),
        };
    }

    /// Records the size `window-width`/`window-height` ask for. The core
    /// sends it from CoreSurface.init and again whenever the cell size
    /// changes (`Surface.recomputeInitialSize`); `Window.show` applies it
    /// once, before the window is first shown. Later values are stored but
    /// never resize a live window, as on GTK (`setDefaultSize` in the
    /// window's surface init) and macOS (`initialSize` on a new window).
    fn initialSize(target: apprt.Target, value: apprt.action.InitialSize) bool {
        return switch (target) {
            .app => false,
            .surface => |v| stored: {
                v.rt_surface.initial_size = value;
                break :stored true;
            },
        };
    }

    /// Nothing to do: the render thread presents its own frames
    /// (src/renderer/d3d11/Frame.zig), and the backend does not even send
    /// this action. An InvalidateRect here would only start a WM_PAINT ->
    /// refreshCallback -> frame cycle for a frame already on screen.
    fn render(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => true,
        };
    }

    /// `.mouse_visibility`, per window: the core hides the pointer while
    /// typing and shows it on the next mouse event (`Surface.hideMouse`).
    /// Applied in the window's WM_SETCURSOR rather than with ShowCursor,
    /// whose counter covers the whole thread: it would also hide the pointer
    /// over the title bar and borders, where the core never sees a move that
    /// could show it again, and outlive a window destroyed while hidden.
    fn mouseVisibility(target: apprt.Target, value: apprt.action.MouseVisibility) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.setMouseVisibility(value),
        };
    }

    /// `.mouse_shape`: the pointer shape over the terminal, per window.
    fn mouseShape(target: apprt.Target, shape: terminal.MouseShape) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.setMouseShape(shape),
        };
    }

    /// Open a link with its registered handler, the shell's `open` verb.
    ///
    /// An OSC 8 target and a link found in the terminal's text (`.unknown`)
    /// are program output, and the shell would pass any scheme on: `file:`
    /// runs executables and a custom scheme starts whatever registered it.
    /// Only a well-formed http, https or mailto link is opened from one
    /// (`linkRefused`); anything else is refused with a notice. The refusal
    /// reports `true`: `false` would send the same link to the core's generic
    /// opener (`Surface.openUrl`), which refuses these kinds on Windows as
    /// well (src/os/open.zig) but reports that as an error. The other kinds
    /// are paths the core resolved itself, and open unchanged.
    ///
    /// Nothing here may dispatch messages: the core calls this while
    /// holding its renderer lock (`Surface.mouseButtonCallback`), and the next
    /// mouse move dispatched on this thread would take that lock again in
    /// cursorPosCallback. The notice is therefore posted and shown once
    /// this frame has returned, and the link is opened on a thread of its
    /// own (`openLink`).
    fn openUrl(target: apprt.Target, value: apprt.action.OpenUrl) bool {
        const hwnd = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.hwnd,
        };

        if (linkRefused(value.kind, value.url)) {
            log.warn("refused a {t} link: not a well-formed http, https or mailto target", .{value.kind});
            _ = win32.PostMessageW(hwnd, WM_GHOSTTY_LINK_REFUSED, 0, 0);
            return true;
        }

        return openLink(value.kind, value.url);
    }

    /// `.open_config` (Ctrl+, by default): open the configuration file,
    /// created empty if there is none (`configpkg.edit.openPath`), with
    /// the program Windows has for it, or else the one it has for text
    /// files, as macOS opens it with the default text editor when no
    /// program claims `.ghostty` (`openUrlThread`). Only `os_open`:
    /// `new_window`, which runs $EDITOR in a new window, is GTK's alone, as
    /// the action's documentation says.
    fn openConfig(self: *App, value: apprt.action.OpenConfig) bool {
        switch (value) {
            .os_open => {},
            .new_window => return false,
        }
        const alloc = self.core_app.alloc;
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("cannot find the configuration file to open err={}", .{err});
            return false;
        };
        defer alloc.free(path);
        return openLink(.text, path);
    }

    /// `.reload_config`. A full reload reads the configuration from disk
    /// again; a soft one hands over the loaded configuration again, which
    /// the core asks for when a conditional state such as the color scheme
    /// changes. Either goes to the target, and for the app the core answers
    /// with `.config_change` (`configChange`).
    ///
    /// The app's full reload comes from the `reload_config` binding,
    /// Ctrl+Shift+, by default, inside the core's key callback. Giving the
    /// core a new configuration there frees the one the terminal's bindings
    /// live in, and a chained binding still reads the actions after this
    /// one from it (`CoreSurface.maybeHandleBinding`). So the reload is
    /// recorded in `requests` and `run` makes it once the callback has
    /// returned (`reloadQueued`), in order with the windows and splits a
    /// chain asks for. GTK and macOS reload at once. A soft reload and a
    /// terminal's own follow a change of color scheme, which a runtime
    /// reports outside any binding, and are made at once.
    fn reloadConfig(
        self: *App,
        target: apprt.Target,
        opts: apprt.action.ReloadConfig,
    ) !bool {
        if (!opts.soft and target == .app) {
            try self.requests.append(self.core_app.alloc, .reload);
            return true;
        }
        try self.reloadNow(target, opts.soft);
        return true;
    }

    /// Give `target` the configuration: the loaded one again when `soft`,
    /// otherwise one read from disk. A configuration that fails to load is
    /// an error, and the loaded one stays.
    fn reloadNow(self: *App, target: apprt.Target, soft: bool) !void {
        var loaded: ?Config = if (soft) null else try Config.load(self.core_app.alloc);
        defer if (loaded) |*c| c.deinit();
        const config: *const Config = if (loaded) |*c| c else &self.config;

        switch (target) {
            .app => try self.core_app.updateConfig(self, config),
            .surface => |core| try core.updateConfig(config),
        }
    }

    /// The full reload `reloadConfig` recorded, and the errors in what it
    /// read (`showConfigErrors`).
    fn reloadQueued(self: *App) void {
        self.reloadNow(.app, false) catch |err| {
            log.warn("failed to reload the configuration err={}", .{err});
            return;
        };
        self.showConfigErrors();
    }

    /// GTK's configuration errors dialog: the configuration's diagnostics,
    /// if it has any, and a reload if the user asks for one (Retry), which
    /// `run` makes (`requests`) and which shows what errors remain. Called
    /// where a prompt may open: by `run` after the initial window, and
    /// after a full reload, so that a reload for a change of color scheme,
    /// which reads no file, does not show the same errors again. No owner
    /// of its own: `promptOwner` gives the prompt the window the user was
    /// last in.
    fn showConfigErrors(self: *App) void {
        if (self.config._diagnostics.empty()) return;
        const alloc = self.core_app.alloc;
        const text = configErrorsText(alloc, &self.config) catch |err| {
            log.warn("cannot show the configuration errors err={}", .{err});
            return;
        };
        defer alloc.free(text);
        if (!retry(self, null, text)) return;
        self.requests.append(alloc, .reload) catch |err| {
            log.warn("cannot record reloading the configuration err={}", .{err});
        };
    }

    /// `.config_change`. For the app, the configuration becomes this
    /// runtime's, with the conditional state the core applied to it, as GTK
    /// and macOS keep theirs: new terminals derive theirs from it, the
    /// dividers take their color from it, and every other reader of
    /// `config` reads it when it needs it. The value only lives for the
    /// call, so it is copied, and every window repaints its dividers. In a
    /// soft reload the value comes from `config` itself, and is `config`
    /// when the core could not apply the conditional state, so it is copied
    /// before `config` is freed. `CoreApp.updateConfig` does not touch the
    /// configuration it was given once the action returns.
    ///
    /// Nothing in this runtime depends on a terminal's own configuration:
    /// `false` for a surface.
    fn configChange(
        self: *App,
        target: apprt.Target,
        value: apprt.action.ConfigChange,
    ) !bool {
        switch (target) {
            .app => {},
            .surface => return false,
        }

        const config = try value.config.clone(self.core_app.alloc);
        self.config.deinit();
        self.config = config;
        for (self.windows.items) |window| {
            _ = win32.InvalidateRect(window.hwnd, null, .FALSE);
            window.applyTheme();
        }
        // `window-decoration` may have changed, here or in a theme a soft
        // reload switched to; the frames change for it from `run`, since a
        // soft reload comes inside a core frame. `run` is woken for it: the
        // reload that `run`'s own syncColorScheme makes comes after its
        // createRequested.
        self.requests.append(self.core_app.alloc, .redecorate) catch |err| {
            log.warn("cannot record redecorating the windows err={}", .{err});
            return true;
        };
        self.wakeup();
        return true;
    }

    /// Arm or cancel the quit-after-last-window timer. Returns whether the
    /// requested state was actually reached; `.quit_timer` reports it to the
    /// core verbatim.
    fn setQuitTimer(self: *App, mode: apprt.action.QuitTimer) bool {
        // Cancel any previous timer first: `.start` can arrive again before
        // `.stop` (the core re-sends it as surfaces come and go).
        self.stopQuitTimer();

        switch (mode) {
            .stop => return true,

            .start => {
                // The apprt owns the quit-after-last-window policy, and this
                // foundation deliberately overrides the configuration.
                //
                // `quit-after-last-window-closed` is `builtin.target.os.tag == .linux`
                // (`Config.@"quit-after-last-window-closed"`), i.e. false on
                // Windows. But once its last window has closed, this runtime
                // has nothing left to open another from: `.new_window` is
                // asked for from a window, and there is no tray icon, no
                // global hotkey and no IPC to a running instance
                // (`performIpc`). Honoring `false` would leave an invisible
                // process with a message-only window that receives nothing
                // and a GetMessageW that blocks forever, endable only from
                // Task Manager.
                //
                // Delete this override -- not the config read -- as soon as
                // a window can be opened with none open.
                //
                // The override is reported by logQuitOverride where the quit is
                // carried out, not here: `.start` also arrives at launch, from
                // startQuitTimer, for a quit that newWindow cancels, so
                // logging here would report quits that never happen.

                const delay_ms: u64 = if (self.config.@"quit-after-last-window-closed-delay") |v|
                    v.asMilliseconds()
                else
                    0;

                // A zero delay must not quit synchronously: startQuitTimer
                // runs before run() does. Record the expiry and let run()
                // decide; see the `quit_timer` field.
                if (delay_ms == 0) {
                    self.quit_timer = .expired;
                    return true;
                }

                if (win32.SetTimer(
                    self.msg_hwnd,
                    quit_timer_id,
                    std.math.cast(win32.UINT, delay_ms) orelse std.math.maxInt(win32.UINT),
                    null,
                ) == 0) {
                    log.warn("failed to arm the quit timer", .{});
                    return false;
                }

                self.quit_timer = .active;
                return true;
            },
        }
    }

    fn stopQuitTimer(self: *App) void {
        switch (self.quit_timer) {
            .off => {},
            .expired => self.quit_timer = .off,
            .active => {
                _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
                self.quit_timer = .off;
            },
        }
    }

    /// The quit timer's WM_TIMER on `msg_hwnd`.
    ///
    /// KillTimer does not remove a WM_TIMER that is already queued, so one
    /// can still arrive after `stopQuitTimer` (a `.stop` from
    /// `CoreApp.addSurface`). Only a timer that is still armed expires;
    /// expiring any other would quit with a window on screen.
    fn quitTimerFired(self: *App) void {
        if (self.quit_timer != .active) return;

        // Window timers repeat until killed.
        _ = win32.KillTimer(self.msg_hwnd, quit_timer_id);
        self.quit_timer = .expired;
    }

    /// Report that the process is quitting because of the override in
    /// setQuitTimer rather than because the configuration asked for it.
    /// Called only from `run`, where that quit is carried out.
    fn logQuitOverride(self: *const App) void {
        if (self.config.@"quit-after-last-window-closed") return;
        log.info(
            "quitting despite quit-after-last-window-closed=false: " ++
                "this runtime cannot open a window once none is left",
            .{},
        );
    }

    /// `.new_window`: record the request for `run` (see `requests`).
    /// `true` once it is recorded: the window is then created, or its
    /// failure reported to the user, as soon as the core frame that asked
    /// has returned, unless the app quits first.
    fn requestWindow(self: *App, target: apprt.Target) bool {
        const parent: ?*CoreSurface = switch (target) {
            .app => null,
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .window = parent }) catch |err| {
            log.warn("cannot record a new window request err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.new_split`: record the request for `run`, as `requestWindow` does,
    /// for the same reason: a `new_split` binding performs it inside the
    /// core's key callback.
    fn requestSplit(
        self: *App,
        target: apprt.Target,
        direction: apprt.action.SplitDirection,
    ) bool {
        const parent = switch (target) {
            .app => {
                log.warn("new split to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .split = .{
            .parent = parent,
            .direction = direction,
        } }) catch |err| {
            log.warn("cannot record a new split request err={}", .{err});
            return false;
        };
        return true;
    }

    /// Forget `core_surface`, which is closing, wherever something still
    /// waits on it: windows it asked for lose it as their parent, splits,
    /// changes to splits and focus moves it asked for are dropped, and so is
    /// a focus move to it.
    /// Called by `Surface.detachCore`, the first step of every teardown,
    /// while the address is still that surface's, so that a surface created
    /// later at the same address cannot pass for it.
    pub fn forgetClosing(self: *App, core_surface: *CoreSurface) void {
        for (self.requests.items) |*request| switch (request.*) {
            .window => |*parent| {
                if (parent.* == core_surface) parent.* = null;
            },
            .split => |split| {
                if (split.parent == core_surface) request.* = .dropped;
            },
            .goto => |goto| {
                if (goto.from == core_surface) request.* = .dropped;
            },
            .resize => |resize| {
                if (resize.from == core_surface) request.* = .dropped;
            },
            .equalize, .fullscreen, .maximize, .zoom, .decorations, .reset_window_size => |from| {
                if (from == core_surface) request.* = .dropped;
            },
            .goto_window => |goto| {
                if (goto.from == core_surface) request.* = .dropped;
            },
            .resize_window => |resize| {
                if (resize.from == core_surface) request.* = .dropped;
            },
            .reload, .redecorate, .dropped => {},
        };
        for (self.windows.items) |window| {
            const surface = window.pending_focus orelse continue;
            if (&surface.core_surface == core_surface) window.pending_focus = null;
        }
    }

    /// `.goto_split`: whether there is a terminal to go to from the one the
    /// action is performed on (`Window.goto`). `false` lets the key through
    /// to the terminal, as the default bindings are performable. The focus
    /// moves once the core's key callback has returned
    /// (`Window.pending_focus`).
    ///
    /// After a window or split still waiting in `requests`, as when a binding
    /// chains `goto_split` after `new_split`, the move waits behind it and is
    /// made by `createRequested`, so that it goes within the split made
    /// first. The action then reports it performed without knowing yet.
    fn gotoSplit(self: *App, target: apprt.Target, to: apprt.action.GotoSplit) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        if (self.requests.items.len > 0) {
            self.requests.append(self.core_app.alloc, .{ .goto = .{
                .from = from,
                .to = to,
            } }) catch |err| {
                log.warn("cannot record a split to go to err={}", .{err});
                return false;
            };
            return true;
        }

        const window = from.rt_surface.window;
        const surface = window.goto(from.rt_surface, to) orelse return false;

        // One being torn down, as its window closes around it, takes no
        // focus: the key reaches the terminal instead.
        if (surface.liveCore() == null) return false;
        window.pending_focus = surface;
        return true;
    }

    /// `.resize_split`: recorded for `run` (`requests`), which lays the
    /// terminals out again once the core's key callback has returned: a
    /// terminal moved inside it would re-enter the core with WM_SIZE
    /// (`CoreSurface.sizeCallback`). GTK and macOS lay out later too. As on
    /// GTK, `false` for no amount or a window with a single terminal, so
    /// that the key reaches the terminal, unless a split for that window is
    /// still to come from `requests`.
    fn resizeSplit(self: *App, target: apprt.Target, value: apprt.action.ResizeSplit) bool {
        const from = switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        if (value.amount == 0) return false;
        const window = from.rt_surface.window;
        if (!window.tree.isSplit() and !self.splitQueuedIn(window)) return false;
        self.requests.append(self.core_app.alloc, .{ .resize = .{
            .from = from,
            .value = value,
        } }) catch |err| {
            log.warn("cannot record a split resize err={}", .{err});
            return false;
        };
        return true;
    }

    /// Whether `requests` holds a split that will land in `window`.
    fn splitQueuedIn(self: *const App, window: *const Window) bool {
        for (self.requests.items) |request| switch (request) {
            .split => |split| if (split.parent.rt_surface.window == window) return true,
            else => {},
        };
        return false;
    }

    /// `.equalize_splits`: recorded for `run`, as `resizeSplit` is. Always
    /// `true` for a surface, as on GTK, whose action is always enabled.
    fn equalizeSplits(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => {
                log.warn("equalize_splits to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .equalize = from }) catch |err| {
            log.warn("cannot record equalizing the splits err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.toggle_maximize`: recorded for `run`, as `toggle_fullscreen` is:
    /// maximizing lays the terminals out again, and a chain of the two
    /// keeps its order. Not made on a window that covers its monitor then.
    fn requestMaximize(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .maximize = from }) catch |err| {
            log.warn("cannot record toggling maximized err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.toggle_fullscreen`: recorded for `run`, as `resizeSplit` is, since
    /// covering the monitor lays the terminals out again
    /// (`Window.toggleFullscreen`). Windows has one kind of fullscreen; the
    /// macOS-only kinds the value can name (`macos-non-native-fullscreen`)
    /// are taken as it.
    fn requestFullscreen(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .fullscreen = from }) catch |err| {
            log.warn("cannot record toggling fullscreen err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.toggle_window_decorations`: recorded for `run`, as
    /// `toggle_fullscreen` is, since a frame without its caption lays the
    /// terminals out again (`Window.toggleDecorations`).
    fn requestDecorations(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .decorations = from }) catch |err| {
            log.warn("cannot record toggling the window decorations err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.copy_title_to_clipboard`: the terminal's title, written as a copy
    /// is (`Surface.setClipboard`), as GTK copies it; `false` with none, or
    /// an empty one, on which the binding's documentation says it has no
    /// effect. Made at once, as a copy is: nothing is laid out and no focus
    /// moves.
    fn copyTitleToClipboard(target: apprt.Target) bool {
        const surface = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface,
        };
        const title = surface.getTitle() orelse return false;
        if (title.len == 0) return false;
        surface.setClipboard(.standard, &.{.{
            .mime = "text/plain",
            .data = title,
        }}, false) catch |err| {
            log.warn("cannot copy the title to the clipboard err={}", .{err});
            return false;
        };
        return true;
    }

    /// The system's notifications, made the first time one is shown, with
    /// Ghostty's app ID registered for them (`toast.register`); null,
    /// logged once, if they cannot be.
    pub fn notifierFor(self: *App) ?toast.Notifier {
        if (self.notifier) |notifier| return notifier;
        if (self.toasts_failed) return null;
        const t = self.makeToasts() catch |err| {
            log.warn("desktop notifications are unavailable err={}", .{err});
            self.toasts_failed = true;
            return null;
        };
        self.toasts = t;
        self.notifier = t.notifierOf();
        return self.notifier;
    }

    fn makeToasts(self: *App) !*toast.Toasts {
        var buf: [1024]u8 = undefined;
        const icon = if (global.resourcesDir().app()) |resources| toast.iconPath(&buf, resources) else null;
        try toast.register(toast.app_id, toast.app_name, icon);

        const alloc = self.core_app.alloc;
        const t = try alloc.create(toast.Toasts);
        errdefer alloc.destroy(t);
        t.* = try toast.Toasts.init(alloc, toast.app_id, self.msg_hwnd, WM_GHOSTTY_NOTIFICATION);
        return t;
    }

    /// The tag of a new toast, unique to the process (`toast.Toast.tag`).
    pub fn nextToastTag(self: *App) u64 {
        self.toast_tag += 1;
        return self.toast_tag;
    }

    /// `.desktop_notification`: a toast (`Surface.notify`). The app's own,
    /// which the core does not send, goes back to no terminal.
    fn desktopNotification(self: *App, target: apprt.Target, value: apprt.action.DesktopNotification) bool {
        return switch (target) {
            .app => app: {
                const notifier = self.notifierFor() orelse break :app false;
                break :app notifier.show(.{
                    .title = value.title,
                    .body = value.body,
                    .group = 0,
                    .tag = self.nextToastTag(),
                });
            },
            .surface => |v| v.rt_surface.notify(value.title, value.body),
        };
    }

    /// WM_GHOSTTY_NOTIFICATION, a toast's click, made at once where the
    /// focus may move, or else kept for `run` (`pending_click`): a prompt's
    /// or a teardown's message loop dispatches it too, with a core frame or
    /// a teardown beneath. Dropped while quitting.
    fn notificationMessage(self: *App, group: u64) void {
        if (self.terminating) return;
        if (!self.canReenterCore() or self.teardown_depth > 0) {
            self.pending_click = group;
            return;
        }
        self.notificationClicked(group);
    }

    /// The click `notificationMessage` kept, if any. Called by `run`.
    fn applyPendingClick(self: *App) void {
        const group = self.pending_click orelse return;
        self.pending_click = null;
        self.notificationClicked(group);
    }

    /// A toast was clicked (`toast.Activated`): its terminal, if it is still
    /// there and neither it nor its window is closing, is brought forward
    /// with the focus, as GTK's present-surface and macOS bring it, ending
    /// a zoom that hides it (`Window.focusFromGoto`). The terminals may be
    /// laid out again, so never inside a core frame (`notificationMessage`).
    fn notificationClicked(self: *App, group: u64) void {
        log.debug("toast clicked group={d}", .{group});
        if (group == 0) return;
        for (self.surfaces.items) |surface| {
            if (surface.notifications.id != group) continue;
            if (surface.closing or surface.window.closing) return;
            surface.window.focusFromGoto(surface);
            _ = Window.present(surface.window.hwnd);
            return;
        }
    }

    /// `.progress_report`: on the taskbar button of the terminal's window
    /// (`Surface.reportProgress`). Made at once: nothing is laid out and no
    /// focus moves.
    fn progressReport(target: apprt.Target, value: terminal.osc.Command.ProgressReport) bool {
        switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.reportProgress(value),
        }
        return true;
    }

    /// `.reset_window_size`: recorded for `run`, as `toggle_fullscreen` is,
    /// since the terminals are laid out again, and made then
    /// (`Window.resetSize`). `false` when the window has no size to go
    /// back to, or covers its monitor (`Window.defaultSize`), as macOS
    /// does nothing then.
    fn requestResetWindowSize(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        if (from.rt_surface.window.defaultSize() == null) return false;
        self.requests.append(self.core_app.alloc, .{ .reset_window_size = from }) catch |err| {
            log.warn("cannot record resetting the window size err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.resize_window`, which a program asks for (CSI 8 t) when
    /// `vt-window-resize-allowed` lets it: recorded for `run`, as
    /// `toggle_fullscreen` is, since the terminals are laid out again, and
    /// made then if it still may be (`Window.resizeToTerminal`). `false`
    /// when it may not be now: as on GTK and macOS, only the one terminal
    /// of a window at a size of its own is resized.
    fn requestResizeWindow(
        self: *App,
        target: apprt.Target,
        value: apprt.action.ResizeWindow,
    ) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        if (!from.rt_surface.window.terminalResizable(from.rt_surface)) {
            log.debug("resize_window not made: not the one terminal of a window at a size of its own", .{});
            return false;
        }
        self.requests.append(self.core_app.alloc, .{ .resize_window = .{
            .from = from,
            .size = value,
        } }) catch |err| {
            log.warn("cannot record resizing the window err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.goto_window`: activate the window beside the one asking, wrapping
    /// around, as GTK goes through its windows from the active one
    /// (`Application.gotoWindow`, `windowBeside`); `false` with one window,
    /// so that the key reaches the terminal. Recorded for `run`, as
    /// `goto_split`'s move is held back: the activation moves the focus,
    /// which would send the asking terminal's core its loss inside its key
    /// callback.
    fn gotoWindow(self: *App, target: apprt.Target, to: apprt.action.GotoWindow) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        if (self.windows.items.len < 2) return false;
        self.requests.append(self.core_app.alloc, .{ .goto_window = .{
            .from = from,
            .to = to,
        } }) catch |err| {
            log.warn("cannot record the window to go to err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.float_window`, from `toggle_window_float_on_top`: made at once,
    /// since it changes no terminal's size (`Window.setFloating`).
    fn floatWindow(target: apprt.Target, value: apprt.action.FloatWindow) bool {
        const window = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.window,
        };
        return window.setFloating(switch (value) {
            .on => true,
            .off => false,
            .toggle => !window.isFloating(),
        });
    }

    /// The window `goto_window` goes to from `from`, wrapping around, or
    /// null when it is the only one: for `.next` the one opened before it,
    /// and for `.previous` the one opened after it, in GTK's order, since
    /// GTK walks `gtk.Window.listToplevels`, which lists the newest window
    /// first. `windows` is in opening order (`windowDestroyed`).
    fn windowBeside(self: *const App, from: *Window, to: apprt.action.GotoWindow) ?*Window {
        const windows = self.windows.items;
        if (windows.len < 2) return null;
        const i = std.mem.indexOfScalar(*Window, windows, from) orelse return null;
        return windows[
            switch (to) {
                .next => (i + windows.len - 1) % windows.len,
                .previous => (i + 1) % windows.len,
            }
        ];
    }

    /// `.toggle_split_zoom`: recorded for `run`, as `resizeSplit` is, since
    /// a zoom lays the terminals out again (`Window.toggleZoom`). As on
    /// GTK it is not performed for a single terminal, unless a split for
    /// its window is still to come, so that the key reaches the terminal.
    fn toggleSplitZoom(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        const window = from.rt_surface.window;
        if (!window.tree.isSplit() and !self.splitQueuedIn(window)) return false;
        self.requests.append(self.core_app.alloc, .{ .zoom = from }) catch |err| {
            log.warn("cannot record zooming the split err={}", .{err});
            return false;
        };
        return true;
    }

    /// Give each window the focus move a `goto_split` chose in it, if any
    /// (`Window.pending_focus`). Called by a terminal's key handler once the
    /// core's key callback has returned (`Surface.handleMessage`), and by
    /// `run` for an action performed from anywhere else.
    pub fn applyPendingFocus(self: *App) void {
        // By index, reading the length each time round: giving the focus
        // runs window procedures.
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            const window = self.windows.items[i];
            const surface = window.pending_focus orelse continue;
            window.pending_focus = null;
            // Still live: a teardown would have cleared it (`forgetClosing`).
            window.focusFromGoto(surface);
        }
    }

    /// Carry out `requests`, oldest first. Called by `run`, where
    /// `canReenterCore` holds and no teardown is running.
    fn createRequested(self: *App) void {
        // A window opened now would only be torn down again by `terminate`.
        if (self.quit) return;

        // By index, reading the length again each time round: the notice for
        // a failure runs a message loop, and a request added meanwhile is
        // still created here.
        defer self.requests.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.requests.items.len) : (i += 1) {
            switch (self.requests.items[i]) {
                .window => |parent| _ = self.newWindow(parent) catch |err| {
                    log.err("failed to create a window err={}", .{err});
                    notice(
                        self,
                        if (parent) |p| p.rt_surface.hwnd else null,
                        L("Ghostty could not open a new window."),
                    );
                },
                .split => |split| self.newSplit(split.parent, split.direction) catch |err| switch (err) {
                    // As when a key has nothing to do: the window is as it was.
                    error.SplitTooSmall => log.info("no room for a split: a terminal would be smaller than a cell", .{}),
                    else => {
                        log.err("failed to create a split err={}", .{err});
                        notice(
                            self,
                            split.parent.rt_surface.hwnd,
                            L("Ghostty could not open a new split."),
                        );
                    },
                },
                .goto => |goto| gotoQueued(goto.from, goto.to),
                // From the focused terminal, as gotoQueued starts, which is
                // GTK's active surface.
                .resize => |resize| {
                    const window = resize.from.rt_surface.window;
                    window.resizeSplit(window.focused orelse resize.from.rt_surface, resize.value);
                },
                .equalize => |from| from.rt_surface.window.equalize(),
                .reload => self.reloadQueued(),
                .fullscreen => |from| from.rt_surface.window.toggleFullscreen(),
                .decorations => |from| from.rt_surface.window.toggleDecorations(),
                .reset_window_size => |from| from.rt_surface.window.resetSize(),
                .resize_window => |resize| resize.from.rt_surface.window.resizeToTerminal(
                    resize.from.rt_surface,
                    resize.size,
                ),
                .redecorate => for (self.windows.items) |window| window.applyDecorations(),
                // A window covering its monitor is left as it is: maximized,
                // it would have the work area instead.
                .maximize => |from| {
                    const window = from.rt_surface.window;
                    if (window.fullscreen == null) window.toggleMaximize();
                },
                .goto_window => |goto| {
                    const window = self.windowBeside(goto.from.rt_surface.window, goto.to) orelse continue;
                    _ = Window.present(window.hwnd);
                },
                // From the focused terminal, as `resize` starts.
                .zoom => |from| {
                    const window = from.rt_surface.window;
                    window.toggleZoom(window.focused orelse from.rt_surface);
                },
                .dropped => {},
            }
        }
    }

    /// A focus move `gotoSplit` queued behind a window or split, made now
    /// that those exist. It starts from the window's focused terminal, as
    /// GTK's does after a split (`newSplit` in
    /// src/apprt/gtk/class/split_tree.zig makes the new terminal its last
    /// focused one): after `new_split` that is the new terminal.
    fn gotoQueued(from: *CoreSurface, to: apprt.action.GotoSplit) void {
        const window = from.rt_surface.window;
        const start = window.focused orelse from.rt_surface;
        const surface = window.goto(start, to) orelse return;
        if (surface.liveCore() == null) return;
        // No core frame is on the stack here, unlike in gotoSplit.
        window.focusFromGoto(surface);
    }

    /// What a new terminal takes from `parent`, the surface that asked for
    /// it, as `context`: its font size with `window-inherit-font-size`, for
    /// a split too, as macOS has it (`newSurfaceOptions` in
    /// src/apprt/embedded.zig), and its working directory if `context`
    /// inherits it. The caller frees `working_directory` with the core
    /// allocator once the terminal is created.
    fn inheritedOptions(
        self: *App,
        parent: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
    ) Surface.Options {
        const p = parent orelse return .{ .context = context };
        return .{
            .font_size = if (self.config.@"window-inherit-font-size") p.font_size.points else null,
            // Taken from the asking surface itself (see Surface.Options).
            .working_directory = if (apprt.surface.shouldInheritWorkingDirectory(context, &self.config))
                p.pwd(self.core_app.alloc) catch null
            else
                null,
            .context = context,
        };
    }

    /// Create a terminal window: the initial one (`run`), or one the core
    /// asked for (`createRequested`) from `parent`, a live surface.
    fn newWindow(self: *App, parent: ?*CoreSurface) !*Window {
        const alloc = self.core_app.alloc;
        try self.surfaces.ensureUnusedCapacity(alloc, 1);
        try self.windows.ensureUnusedCapacity(alloc, 1);

        const opts = self.inheritedOptions(parent, .window);
        defer if (opts.working_directory) |v| alloc.free(v);

        // Surface.create registers the surface with the core, and
        // CoreApp.addSurface cancels the startup quit timer
        // itself, so there is no quit-timer handling here.
        const window = try Window.create(self, opts);
        errdefer comptime unreachable;
        self.windows.appendAssumeCapacity(window);
        self.surfaces.appendAssumeCapacity(window.focused.?);

        // Shown once both are owned, so that its first messages find them.
        window.show();
        return window;
    }

    /// Open a split beside `parent`, a live surface, in `direction`: a new
    /// terminal in the parent's window, which takes the focus.
    fn newSplit(
        self: *App,
        parent: *CoreSurface,
        direction: apprt.action.SplitDirection,
    ) !void {
        const alloc = self.core_app.alloc;
        try self.surfaces.ensureUnusedCapacity(alloc, 1);

        const opts = self.inheritedOptions(parent, .split);
        defer if (opts.working_directory) |v| alloc.free(v);

        const window = parent.rt_surface.window;
        const surface = try window.split(parent.rt_surface, direction, opts);
        errdefer comptime unreachable;
        self.surfaces.appendAssumeCapacity(surface);

        // Shown once it is owned, as a new window is.
        window.showPane(surface);
    }

    /// Called from the surface's WM_DESTROY handler, and by `terminate` for
    /// a window that could not be destroyed.
    ///
    /// Ownership invariant: **membership in `self.surfaces` is ownership of
    /// the heap allocation.** A window whose Surface is not in the list is
    /// still owned by whoever is constructing or tearing it down, so this
    /// returns without freeing. That is what makes `Surface.create`'s errdefer
    /// chain safe -- DestroyWindow reenters here before the surface is
    /// registered, and a free here would be a double free.
    pub fn surfaceDestroyed(self: *App, surface: *Surface) void {
        const idx = std.mem.indexOfScalar(*Surface, self.surfaces.items, surface) orelse return;

        // The HWND outlives its Surface by one message: WM_NCDESTROY is
        // still to come. Clear the back-pointer so wndProc's `v == 0` guard
        // catches it instead of forming a *Surface into freed memory.
        _ = win32.SetWindowLongPtrW(surface.hwnd, win32.GWLP_USERDATA, 0);

        _ = self.surfaces.swapRemove(idx);
        // As on macOS and GTK, a terminal's toasts go with it.
        surface.clearNotifications();
        // Already moved off a terminal that closed on its own
        // (`Window.removePane`), and gone once the frame is destroyed
        // (its WM_DESTROY); this only keeps it from ever dangling.
        if (surface.window.focused == surface) surface.window.focused = null;
        surface.deinit();
        self.core_app.alloc.destroy(surface);

        // The quit timer is not handled here: CoreApp.deleteSurface, which
        // Surface.stopCore calls before the window is destroyed, starts it
        // when the core's last surface goes (`CoreApp.deleteSurface`).
    }

    /// Called from the frame's WM_NCDESTROY, after its terminals'
    /// WM_DESTROY, and by `terminate` for a window that could not be
    /// destroyed. The ownership invariant of `surfaceDestroyed` holds for
    /// `self.windows` too: `Window.create` destroys a frame it has not
    /// handed over yet, and frees it itself.
    pub fn windowDestroyed(self: *App, window: *Window) void {
        const idx = std.mem.indexOfScalar(*Window, self.windows.items, window) orelse return;

        // As in surfaceDestroyed; after WM_NCDESTROY no message comes, but a
        // window `terminate` gives up on still exists.
        _ = win32.SetWindowLongPtrW(window.hwnd, win32.GWLP_USERDATA, 0);

        // In order: `windowBeside` goes by opening order.
        _ = self.windows.orderedRemove(idx);
        // Empty already unless `terminate` gave up on the frame, which then
        // had no WM_DESTROY.
        window.tree.deinit();
        self.core_app.alloc.destroy(window);
    }

    /// The message-only window's procedure.
    fn wndProc(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        const self: *App = ptr: {
            const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
            if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
        };

        switch (msg) {
            // Normally there is nothing to do but return: the message
            // existing is the point, and `run` ticks the core after every
            // dispatched message.
            //
            // Inside a system modal loop (a size/move drag, the window menu)
            // `run` does not get control back until the loop ends, so the
            // mailbox would go undrained for the whole drag -- output stops,
            // and the render and IO threads can block on `.forever` pushes.
            // Those loops are entered from DefWindowProcW, never from inside
            // a core frame, so ticking here is safe; canReenterCore still
            // guards against the one exception, a prompt beneath the loop.
            WM_GHOSTTY_WAKEUP => {
                if (self.modal_loop_depth > 0) self.tickFromHandler();
                return 0;
            },

            WM_GHOSTTY_NOTIFICATION => {
                self.notificationMessage(toast.messageGroup(wparam, lparam));
                return 0;
            },

            // `run` quits once the timer has expired, the next time round
            // its loop.
            win32.WM_TIMER => if (wparam == quit_timer_id) {
                self.quitTimerFired();
                return 0;
            },

            else => {},
        }

        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
};

/// Log the DPI awareness actually in effect for this thread.
///
/// SetProcessDpiAwarenessContext's return value cannot distinguish a manifest
/// that already selected PerMonitorV2 from a genuine failure, so the effective
/// context is queried instead of inferred. Both functions exist only from
/// Windows 10 1607 and are resolved by name for the same reason as the other
/// DPI entry points; see win32.SetProcessDpiAwarenessContextFn.
fn logEffectiveDpiAwareness(user32: win32.HMODULE) void {
    const get_p = win32.GetProcAddress(user32, "GetThreadDpiAwarenessContext") orelse return;
    const eq_p = win32.GetProcAddress(user32, "AreDpiAwarenessContextsEqual") orelse return;
    const get_ctx: win32.GetThreadDpiAwarenessContextFn = @ptrCast(@alignCast(get_p));
    const ctx_eq: win32.AreDpiAwarenessContextsEqualFn = @ptrCast(@alignCast(eq_p));

    // Documented never to return NULL; the optional return type and this
    // branch are defensive, since the declaration is ours rather than the SDK's.
    const current = get_ctx() orelse {
        log.warn("could not query the effective DPI awareness", .{});
        return;
    };
    if (ctx_eq(current, win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).toBool()) {
        log.debug("DPI awareness is per-monitor v2", .{});
    } else {
        log.warn(
            "DPI awareness is not per-monitor v2; the system will scale this " ++
                "window's contents on high-DPI displays",
            .{},
        );
    }
}

/// Post WM_GHOSTTY_DESTROY to `hwnd`, a terminal's window or a frame, for
/// a close that has just set `closing`. Posting only fails when the queue
/// is full (10,000 messages); the close is then undone, so that the user
/// can ask again.
pub fn postTeardown(hwnd: win32.HWND, closing: *bool) void {
    if (win32.PostMessageW(hwnd, WM_GHOSTTY_DESTROY, 0, 0).toBool()) return;
    log.err("failed to post a teardown err={}", .{win32.GetLastError()});
    closing.* = false;
}

/// ID_ICON_GHOSTTY in dist/windows/ghostty.rc, which the exe links.
const icon_resource_id = 1;

fn registerClasses(hinstance: win32.HINSTANCE) !void {
    const arrow = win32.LoadCursorW(null, win32.IDC_ARROW);

    // The exe's own icon for the frame's caption and Alt+Tab. LoadIconW returns a
    // shared icon, so nothing destroys it. With hIconSm null the system
    // picks the small size from the same resource (WNDCLASSEXW docs); if
    // the load fails both stay null and the system default is used.
    const icon = win32.LoadIconW(hinstance, @ptrFromInt(icon_resource_id));

    // No CS_HREDRAW or CS_VREDRAW for either class. They would invalidate
    // the whole window on every resize step, shrinks included. A terminal
    // draws nothing through GDI, and WM_SIZE already queues its frame for
    // the new size, so each resulting WM_PAINT would only wake its renderer
    // for another frame of the same size. The frame paints just its
    // dividers, and Windows already invalidates what a resize or a
    // terminal's move uncovers of it.
    const window_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &Window.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = icon,
        .hCursor = arrow,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(Window.class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&window_class) == 0) {
        log.err("failed to register the window class err={}", .{win32.GetLastError()});
        return App.Error.Win32ClassRegistrationFailed;
    }
    errdefer _ = win32.UnregisterClassW(L(Window.class_name), hinstance);

    const surface_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &Surface.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = arrow,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(surface_class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&surface_class) == 0) {
        log.err("failed to register the surface window class err={}", .{win32.GetLastError()});
        return App.Error.Win32ClassRegistrationFailed;
    }
    errdefer _ = win32.UnregisterClassW(L(surface_class_name), hinstance);

    const app_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &App.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(app_class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&app_class) == 0) {
        log.err("failed to register the app window class err={}", .{win32.GetLastError()});
        return App.Error.Win32ClassRegistrationFailed;
    }
}

fn unregisterClasses(hinstance: win32.HINSTANCE) void {
    _ = win32.UnregisterClassW(L(app_class_name), hinstance);
    _ = win32.UnregisterClassW(L(surface_class_name), hinstance);
    _ = win32.UnregisterClassW(L(Window.class_name), hinstance);
}

/// The text of `showConfigErrors`: GTK's dialog's, then each diagnostic on
/// a line of its own, at most `config_errors_shown` of them, then what the
/// buttons do. A diagnostic can quote the file, so invalid UTF-8 becomes
/// U+FFFD (`wideFromUtf8`), and so does a NUL, which MessageBoxW would
/// take for the end of the text: a UTF-16 file, read as UTF-8, has one
/// beside each ASCII character.
fn configErrorsText(alloc: Allocator, config: *const Config) ![:0]u16 {
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    const w = &text.writer;
    try w.writeAll("One or more configuration errors were found. Please review the " ++
        "errors below, and either reload your configuration or ignore these errors.\n\n");
    const items = config._diagnostics.items();
    for (items[0..@min(items.len, config_errors_shown)]) |*diag| {
        try diag.format(w);
        try w.writeByte('\n');
    }
    if (items.len > config_errors_shown) {
        try w.print("...and {d} more\n", .{items.len - config_errors_shown});
    }
    try w.writeAll("\nRetry reloads the configuration; Cancel ignores these errors.");
    const wide = try wideFromUtf8(alloc, text.written());
    std.mem.replaceScalar(u16, wide, 0, std.unicode.replacement_character);
    return wide;
}

/// How many diagnostics `configErrorsText` lists: a message box does not
/// scroll.
const config_errors_shown = 20;

/// Windows' light or dark mode for apps: the AppsUseLightTheme value that
/// "Choose your default app mode" in Settings writes. Light when it cannot
/// be read, Windows' own default.
fn systemColorScheme() apprt.ColorScheme {
    var value: win32.DWORD = 1;
    var size: win32.DWORD = @sizeOf(win32.DWORD);
    const rc = win32.RegGetValueW(
        win32.HKEY_CURRENT_USER,
        L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        L("AppsUseLightTheme"),
        win32.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    if (rc != internal_os.windows.ERROR_SUCCESS) {
        // Not there on every edition, and read for every new window.
        log.debug("cannot read AppsUseLightTheme err={d}, assuming light", .{rc});
        return .light;
    }
    return if (value == 0) .dark else .light;
}

/// The color scheme the core is told, which picks the light or dark half of
/// `theme` and answers a program's color scheme query: the one the title
/// bars show (`Window.frameDark`). Under `auto` without a light and a dark
/// theme the core thus hears that a dark background is dark, whatever the
/// system's mode, as macOS tells its core the appearance `auto` gives its
/// windows; with them, and under `system`, it hears the system's mode.
/// macOS gives `ghostty` the system's appearance; here it is `auto`.
fn coreScheme(config: *const Config, system: apprt.ColorScheme) apprt.ColorScheme {
    return if (Window.frameDark(config, system)) .dark else .light;
}

/// The allocator of the link `openLink` hands to its opener thread, which
/// frees it. The detached thread can outlive App.terminate and
/// global.deinit, which deinitializes the debug allocator, so the link is
/// allocated with an allocator of the process rather than
/// `core_app.alloc`, as no allocator of the app is known to outlive the
/// thread.
const open_url_alloc = std.heap.smp_allocator;

/// Open `url` with the shell's `open` verb on a thread of its own
/// (`openUrlThread`): ShellExecuteExW blocks until the handler has
/// started, which can be a cold browser start or the shell's app picker,
/// and may dispatch messages while it waits, so it never runs on the UI
/// thread, as the core's opener does not either (src/os/open.zig).
fn openLink(kind: apprt.action.OpenUrl.Kind, url: []const u8) bool {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(open_url_alloc, url) catch |err| {
        log.warn("cannot convert the {t} link to open err={}", .{ kind, err });
        return false;
    };
    const thread = std.Thread.spawn(.{}, openUrlThread, .{ wide, kind == .text }) catch |err| {
        open_url_alloc.free(wide);
        log.warn("cannot start the opener thread for a {t} link err={}", .{ kind, err });
        return false;
    };
    thread.detach();
    return true;
}

/// Opens `wide` with the shell, then frees it. COM is initialized for the
/// thread first, as ShellExecuteExW documents: a shell extension it
/// delegates to may need a single-threaded apartment. The thread has no
/// message loop and ends when the call returns, so the call finishes the
/// launch, a DDE conversation included, before it returns
/// (SEE_MASK_NOASYNC), as SHELLEXECUTEINFOW's remarks require of such a
/// thread; it exists only to wait.
///
/// A `text` file, a path the core resolved itself, whose kind no program
/// is registered for opens with the program for text files. The shell's
/// `open` would hand it to its Unknown type, OpenWith, and report success
/// with nothing shown, so this is decided beforehand (`hasProgram`).
fn openUrlThread(wide: [:0]u16, text: bool) void {
    defer open_url_alloc.free(wide);
    const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) win32.CoUninitialize();

    var info: win32.SHELLEXECUTEINFOW = .{
        .cbSize = @sizeOf(win32.SHELLEXECUTEINFOW),
        .fMask = win32.SEE_MASK_NOASYNC,
        .lpVerb = L("open"),
        .lpFile = wide.ptr,
        .nShow = win32.SW_SHOWNORMAL,
    };
    var progid: ProgId = undefined;
    if (text and !hasProgram(textPathExtension(wide))) {
        if (textProgId(&progid)) |class| {
            info.fMask |= win32.SEE_MASK_CLASSNAME | win32.SEE_MASK_FLAG_NO_UI;
            info.lpClass = class;
        }
    }
    if (!win32.ShellExecuteExW(&info).toBool()) {
        log.warn("ShellExecuteExW failed err={}", .{win32.GetLastError()});
    }
}

/// The extension of the file a `.text` link names, with its dot, or the
/// empty string for one with none, such as the legacy `config`. Its
/// separators are made backslashes first, in place: a path the core put
/// together can mix them (the configuration's is joined with '/'), and
/// ShellExecuteExW finds no file by such a path, while PathFindExtensionW
/// takes only a backslash for a separator, and would take a dot in a
/// directory's name for the extension. It takes a path of at most
/// MAX_PATH characters, so a longer one has none here.
fn textPathExtension(path: [:0]u16) [*:0]const u16 {
    std.mem.replaceScalar(u16, path, '/', '\\');
    if (path.len >= win32.MAX_PATH) return path[path.len..].ptr;
    return win32.PathFindExtensionW(path.ptr);
}

/// A ProgID, for `textProgId`. One is at most 39 characters
/// (https://learn.microsoft.com/en-us/windows/win32/com/-progid--key); the
/// rest is room for one registered against that rule, and a longer one
/// fails rather than is cut short (ASSOCF_NOTRUNCATE).
const ProgId = [256:0]u16;

/// The ProgID that opens text files for this user, in `buf`, or null,
/// logged. ASSOCSTR_PROGID follows the user's default, the choice made in
/// Settings; `.txt`'s own class key does not, and on Windows 11 names the
/// legacy Notepad (txtfilelegacy), which ShellExecuteExW cannot open with
/// where only the Store Notepad is installed.
/// https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/ne-shlwapi-assocstr
fn textProgId(buf: *ProgId) ?[*:0]const u16 {
    var size: win32.DWORD = buf.len + 1;
    const hr = win32.AssocQueryStringW(
        win32.ASSOCF_INIT_IGNOREUNKNOWN | win32.ASSOCF_NOTRUNCATE,
        win32.ASSOCSTR_PROGID,
        L(".txt"),
        null,
        buf,
        &size,
    );
    if (hr < 0) {
        log.warn("no program for text files hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return null;
    }
    return buf;
}

/// Whether a program is registered to open files with `extension`, the
/// shell's Unknown type left out; none is for no extension.
fn hasProgram(extension: [*:0]const u16) bool {
    if (extension[0] == 0) return false;
    var size: win32.DWORD = 0;
    const hr = win32.AssocQueryStringW(
        win32.ASSOCF_INIT_IGNOREUNKNOWN,
        win32.ASSOCSTR_COMMAND,
        extension,
        L("open"),
        null,
        &size,
    );
    return hr >= 0;
}

/// Whether `openUrl` refuses a link: OSC 8 targets and links found in the
/// terminal's text come from program output and must pass
/// `untrustedLinkAllowed`, as the macOS app treats them (upstream
/// f9e8ef02d); paths the core resolved itself (`.text`, `.html`) are trusted.
fn linkRefused(kind: apprt.action.OpenUrl.Kind, url: []const u8) bool {
    return switch (kind) {
        .unknown, .osc8 => !untrustedLinkAllowed(url),
        .text, .html => false,
    };
}

/// Whether an OSC 8 target may be opened: an http or https link with a
/// host, or a mailto link with an address, containing nothing that could
/// display differently from what the handler receives. This is the allow
/// branch of the macOS policy (macos/Sources/Helpers/UntrustedURL.swift),
/// which likewise leaves the parse to the platform's URL parser (here
/// std.Uri); what that policy confirms or inspects (`file:`, custom
/// schemes) is refused here outright.
fn untrustedLinkAllowed(url: []const u8) bool {
    // Control, bidirectional and zero-width code points can hide part of
    // the target or add a display line; invalid UTF-8 cannot be shown.
    var it = (std.unicode.Utf8View.init(url) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        const unsafe = switch (cp) {
            0x00...0x1F, 0x7F...0x9F => true, // C0 and C1 controls
            0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069 => true, // bidi, zero width
            0x2028, 0x2029, 0x2060, 0xFEFF => true, // line separators, word joiner, BOM
            else => false,
        };
        if (unsafe) return false;
    }

    const uri = std.Uri.parse(url) catch return false;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        // "https:relative" and "https:///path" parse with no host, and
        // consumers resolve them against different bases. std.Uri ends
        // the user info at the first '@' where browsers take the last, so
        // "https://a@b@/" leaves the host "b@" here and an empty one there.
        const host = (uri.host orelse return false).percent_encoded;
        return host.len > 0 and std.mem.indexOfScalar(u8, host, '@') == null;
    }

    // The address is the path; a bare "mailto:" opens an empty message.
    if (std.ascii.eqlIgnoreCase(uri.scheme, "mailto")) return !uri.path.isEmpty();

    return false;
}

test "win32: waiting for a thread drains a full mailbox without input" {
    // Only what this tick touches: the mailbox, and the surface list that
    // `.close` is checked against (empty, so every message is a no-op).
    var core_app: CoreApp = undefined;
    core_app.mailbox = .{};
    core_app.surfaces = .empty;

    var app: App = undefined;
    app.core_app = &core_app;
    app.ticking = false;
    app.prompt_depth = 0;

    // Never dereferenced; static so it costs no stack.
    const gone = struct {
        var surface: CoreSurface = undefined;
    };

    // A full mailbox whose wakeups were already consumed by a loop that did
    // not tick, as a prompt's loop does: nothing is left in the queue.
    while (core_app.mailbox.push(
        global.io(),
        .{ .close = &gone.surface },
        .instant,
    ) != 0) {}

    // A producer such as the IO thread's reader, blocked on the full
    // mailbox and posting no wakeup until its push succeeds. A timeout
    // rather than `.forever` makes a wait that never drains fail the test
    // instead of hanging it.
    const Producer = struct {
        fn run(mailbox: *CoreApp.Mailbox.Queue, pushed: *bool) void {
            pushed.* = mailbox.push(
                global.io(),
                .{ .close = &gone.surface },
                .{ .ns = 3 * std.time.ns_per_s },
            ) != 0;
        }
    };
    var pushed = false;
    const thread = try std.Thread.spawn(.{}, Producer.run, .{ &core_app.mailbox, &pushed });
    app.waitForThread(thread.getHandle());
    thread.join();
    try std.testing.expect(pushed);
}

test "win32: untrusted links are limited to well-formed http, https and mailto" {
    const allowed = [_][]const u8{
        "https://example.com/path?q=1#f",
        "HTTP://user:pw@example.com:8080/",
        "http://[::1]:8080/",
        "mailto:someone@example.com?subject=hi",
        "MAILTO:a@b",
    };
    for (allowed) |url| try std.testing.expect(untrustedLinkAllowed(url));

    const refused = [_][]const u8{
        "",
        "example.com",
        "https:relative",
        "https://",
        "https:///path",
        "https://user@/path",
        "https://:8080/",
        "https://a@b@/",
        "https://a@@/",
        "http://[/",
        "http://[::1/",
        "http://example.com:abc/",
        "mailto:",
        "mailto:?subject=hi",
        "file:///C:/Windows/System32/calc.exe",
        "ms-settings:display",
        "ftp://example.com/",
        "https://example.com/\r\n",
        "https://example.com/\xff",
    };
    for (refused) |url| try std.testing.expect(!untrustedLinkAllowed(url));

    // One code point from each arm of the screen, placed as the macOS
    // policy's test places them (UntrustedURLTests.swift).
    const unsafe = [_]u21{
        0x0000, 0x001F, 0x007F, 0x0085, 0x009F, // C0 and C1 controls
        0x061C, 0x200B, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069, // bidi, zero width
        0x2028, 0x2029, 0x2060, 0xFEFF, // line separators, word joiner, BOM
    };
    inline for (unsafe) |cp| {
        const url = "https://example.com/before" ++ std.unicode.utf8EncodeComptime(cp) ++ "after";
        try std.testing.expect(!untrustedLinkAllowed(url));
    }
}

test "win32: links from program output are checked, resolved paths are not" {
    const testing = std.testing;
    const payload = "file:///C:/Windows/System32/calc.exe";

    // A link the URL regex found in the terminal's text is program output,
    // like an OSC 8 target: neither may launch a local file.
    try testing.expect(linkRefused(.unknown, payload));
    try testing.expect(linkRefused(.osc8, payload));
    try testing.expect(!linkRefused(.unknown, "https://example.com/"));
    try testing.expect(!linkRefused(.osc8, "https://example.com/"));

    // A path the core resolved itself, such as the config file it opens.
    try testing.expect(!linkRefused(.text, "C:\\Users\\me\\config.ghostty"));
    try testing.expect(!linkRefused(.html, "file:///C:/ghostty/help.html"));
}

test "win32: only an armed quit timer expires" {
    // KillTimer leaves a WM_TIMER that is already queued in place, so the
    // quit timer's can arrive after `.stop` has cancelled it. Expiring the
    // timer then would make `run` quit with a window on screen. A
    // message-only window stands in for the app's; the handler only needs
    // the App behind it.
    const hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(hwnd);

    var app: App = undefined;
    app.msg_hwnd = hwnd;
    _ = win32.SetWindowLongPtrW(
        hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(&app)),
    );

    const State = @TypeOf(app.quit_timer);
    const Case = struct { from: State, want: State };
    const cases = [_]Case{
        .{ .from = .active, .want = .expired },
        // Stopped after the message was queued.
        .{ .from = .off, .want = .off },
    };
    for (cases) |c| {
        app.quit_timer = c.from;
        _ = App.wndProc(hwnd, win32.WM_TIMER, quit_timer_id, 0);
        try std.testing.expectEqual(c.want, app.quit_timer);
    }
}

test "win32: a prompt disables the other windows until the outermost one ends and wakes run" {
    // MessageBoxW disables only its owner; the rest is beginPrompt's.
    // Hidden top-level windows stand in for the frames.
    const testWindow = struct {
        fn create() !win32.HWND {
            return win32.CreateWindowExW(
                0,
                L("STATIC"),
                null,
                0,
                0,
                0,
                0,
                0,
                null,
                null,
                null,
                null,
            ) orelse error.TestUnexpectedResult;
        }
    }.create;
    const owner = try testWindow();
    defer _ = win32.DestroyWindow(owner);
    const other = try testWindow();
    defer _ = win32.DestroyWindow(other);
    const off = try testWindow();
    defer _ = win32.DestroyWindow(off);

    var a: Window = undefined;
    var b: Window = undefined;
    var c: Window = undefined;
    a.hwnd = owner;
    b.hwnd = other;
    c.hwnd = off;
    for ([_]*Window{ &a, &b, &c }) |window| window.prompt_disabled = false;

    var app: App = undefined;
    app.prompt_depth = 0;
    app.windows = .empty;
    defer app.windows.deinit(std.testing.allocator);
    try app.windows.appendSlice(std.testing.allocator, &.{ &a, &b, &c });

    // Disabled by something else, so not the prompt's to enable.
    _ = win32.EnableWindow(off, .FALSE);

    // A message-only window stands in for the app's, to see the wakeup.
    app.msg_hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(app.msg_hwnd);
    const woken = struct {
        fn f(hwnd: win32.HWND) bool {
            var msg: win32.MSG = undefined;
            return win32.PeekMessageW(&msg, hwnd, WM_GHOSTTY_WAKEUP, WM_GHOSTTY_WAKEUP, win32.PM_REMOVE).toBool();
        }
    }.f;

    app.beginPrompt(owner);
    try std.testing.expect(win32.IsWindowEnabled(owner).toBool());
    try std.testing.expect(!win32.IsWindowEnabled(other).toBool());

    // A nested prompt, here owned by no window, changes nothing, and
    // neither does its end.
    app.beginPrompt(null);
    try std.testing.expect(win32.IsWindowEnabled(owner).toBool());
    app.endPrompt();
    try std.testing.expect(!win32.IsWindowEnabled(other).toBool());
    try std.testing.expect(!woken(app.msg_hwnd));

    // The outermost one's end wakes `run`, whose tick the prompt's own
    // message loop could not make.
    app.endPrompt();
    try std.testing.expectEqual(0, app.prompt_depth);
    try std.testing.expect(win32.IsWindowEnabled(other).toBool());
    try std.testing.expect(!win32.IsWindowEnabled(off).toBool());
    try std.testing.expect(woken(app.msg_hwnd));
}

test "win32: a prompt belongs to a top-level window" {
    // MessageBoxW disables only its owner, so a prompt a terminal asks for
    // belongs to the terminal's frame. An ownerless one would leave every
    // window disabled and hand the activation to another application when
    // it closes, so a caller with no window gets the last focused one.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.surfaces = .empty;
    defer core_app.surfaces.deinit(alloc);
    core_app.focused_surface = null;

    var app: App = undefined;
    app.core_app = &core_app;
    app.windows = .empty;
    defer app.windows.deinit(alloc);

    // Static because the struct embeds a whole CoreSurface. These handles
    // are only compared, never used as windows.
    const s = struct {
        var a: Surface = undefined;
        var b: Surface = undefined;
        var wa: Window = undefined;
        var wb: Window = undefined;
    };
    s.wa.hwnd = @ptrFromInt(0x10);
    s.wb.hwnd = @ptrFromInt(0x20);
    s.a.window = &s.wa;
    s.b.window = &s.wb;
    s.a.core_surface.rt_surface = &s.a;
    s.b.core_surface.rt_surface = &s.b;

    try std.testing.expect(app.promptOwner(null) == null);

    try app.windows.appendSlice(alloc, &.{ &s.wa, &s.wb });
    try std.testing.expectEqual(s.wa.hwnd, app.promptOwner(null).?);

    try core_app.surfaces.appendSlice(alloc, &.{ &s.a, &s.b });
    core_app.focused_surface = &s.b.core_surface;
    try std.testing.expectEqual(s.wb.hwnd, app.promptOwner(null).?);

    // The caller's own window always wins, and for a terminal that is its
    // frame. A hidden top-level window and a child of it stand in for them.
    const frame = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.DestroyWindow(frame);
    const pane = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        win32.WS_CHILD,
        0,
        0,
        0,
        0,
        frame,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(frame, app.promptOwner(pane).?);
    try std.testing.expectEqual(frame, app.promptOwner(frame).?);
}

/// For tests: an app with only what the frame and terminal window
/// procedures read when nothing has a core surface, the default
/// configuration, and a message-only window standing in for the app's, to
/// see a wakeup. `core_app.alloc` must be set; the caller registers the
/// classes (`registerClasses`) and frees it all (`testCleanup`).
pub fn testApp(app: *App, core_app: *CoreApp) !void {
    app.core_app = core_app;
    app.hinstance = @ptrCast(std.os.windows.peb().ImageBaseAddress);
    app.get_dpi_for_window = null;
    app.is_window_arranged = null;
    app.taskbar_created = 0;
    app.taskbar_list = null;
    app.toasts = null;
    app.notifier = null;
    app.toasts_failed = false;
    app.toast_tag = 0;
    app.pending_click = null;
    app.com_initialized = false;
    app.system_scheme = .light;
    app.reported_scheme = null;
    app.modal_loop_depth = 0;
    app.terminating = false;
    app.ticking = false;
    app.prompt_depth = 0;
    app.teardown_depth = 0;
    app.surfaces = .empty;
    app.windows = .empty;
    app.requests = .empty;
    app.quit = false;
    app.config = try .default(core_app.alloc);
    errdefer app.config.deinit();
    app.msg_hwnd = win32.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        win32.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.TestUnexpectedResult;
}

/// For tests: a hidden frame made as `newWindow` makes one
/// (`Window.createFrame`), owned by `app`, with no terminal yet.
fn testFrame(app: *App) !*Window {
    const alloc = app.core_app.alloc;
    try app.windows.ensureUnusedCapacity(alloc, 1);
    const window = try alloc.create(Window);
    window.* = .{
        .app = app,
        .hwnd = undefined,
        .tree = .empty,
        .focused = null,
        .pending_focus = null,
        .dark_frame = false,
        .fullscreen = null,
        .decoration = null,
        .modal_loops = .{},
        .taskbar_button = false,
        .prompt_disabled = false,
        .closing = false,
        .destroy_deferred = false,
    };
    _ = window.createFrame(0, 0, 200, 100) catch {
        alloc.destroy(window);
        return error.TestUnexpectedResult;
    };
    app.windows.appendAssumeCapacity(window);
    return window;
}

/// For tests: a hidden terminal window of the real class in `window`,
/// owned by `app`, with no core surface: a teardown only destroys and
/// frees it. The caller puts it in the window's tree. A test that
/// activates its frame hands it the focus and takes it back at teardown,
/// so it has what WM_SETFOCUS and WM_KILLFOCUS read.
fn testPane(app: *App, window: *Window) !*Surface {
    const alloc = app.core_app.alloc;
    try app.surfaces.ensureUnusedCapacity(alloc, 1);
    const surface = try alloc.create(Surface);
    surface.app = app;
    surface.window = window;
    surface.core_state = .none;
    // Only the way back from the core surface: actions name it.
    surface.core_surface.rt_surface = surface;
    surface.title = null;
    surface.initial_size = null;
    surface.ime = .{};
    surface.closing = false;
    surface.destroy_deferred = false;
    surface.focused = false;
    surface.mouse = .init();
    surface.progress = .{};
    surface.progress_expires = 0;
    surface.notifications = .{ .id = @intFromPtr(surface) };
    surface.preedit = .none;
    _ = win32.CreateWindowExW(
        0,
        L(surface_class_name),
        null,
        win32.WS_CHILD,
        0,
        0,
        200,
        100,
        window.hwnd,
        null,
        app.hinstance,
        surface,
    ) orelse {
        alloc.destroy(surface);
        return error.TestUnexpectedResult;
    };
    app.surfaces.appendAssumeCapacity(surface);
    return surface;
}

/// For tests: destroy whatever `testFrame` and `testPane` left, which
/// frees it all, then release what `testApp` made.
pub fn testCleanup(app: *App) void {
    const alloc = app.core_app.alloc;
    while (app.windows.getLastOrNull()) |window| {
        if (!win32.DestroyWindow(window.hwnd).toBool()) break;
    }
    app.surfaces.deinit(alloc);
    app.windows.deinit(alloc);
    app.requests.deinit(alloc);
    app.config.deinit();
    _ = win32.DestroyWindow(app.msg_hwnd);
}

fn clientRect(hwnd: win32.HWND) !win32.RECT {
    var rect: win32.RECT = undefined;
    if (!win32.GetClientRect(hwnd, &rect).toBool()) return error.TestUnexpectedResult;
    return rect;
}

/// For tests: whether a window is shown itself, whatever its parent is
/// (IsWindowVisible is false for every child of a hidden frame).
fn shown(hwnd: win32.HWND) bool {
    const visible: isize = win32.WS_VISIBLE;
    return win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE) & visible != 0;
}

/// For tests: whether a frame has its caption.
fn captioned(hwnd: win32.HWND) bool {
    const caption: isize = win32.WS_CAPTION;
    return win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE) & caption == caption;
}

fn windowRect(hwnd: win32.HWND) !win32.RECT {
    var rect: win32.RECT = undefined;
    if (!win32.GetWindowRect(hwnd, &rect).toBool()) return error.TestUnexpectedResult;
    return rect;
}

/// For tests: the rects of the monitor `hwnd` is mostly on.
fn monitorOf(hwnd: win32.HWND) !win32.MONITORINFO {
    const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse
        return error.TestUnexpectedResult;
    var info: win32.MONITORINFO = std.mem.zeroes(win32.MONITORINFO);
    info.cbSize = @sizeOf(win32.MONITORINFO);
    if (!win32.GetMonitorInfoW(monitor, &info).toBool()) return error.TestUnexpectedResult;
    return info;
}

test "win32: a window's terminal fills it, and both are freed once" {
    // The real classes and window procedures; both windows stay hidden and
    // are never activated.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const surface = try testPane(&app, window);
    window.tree = try .init(alloc, surface);
    window.focused = surface;

    // The frame's WM_SIZE, sent even to a hidden window, lays the terminal
    // out over the frame's new client area.
    try std.testing.expect(win32.SetWindowPos(
        window.hwnd,
        null,
        0,
        0,
        400,
        300,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOMOVE,
    ).toBool());
    const frame_client = try clientRect(window.hwnd);
    try std.testing.expect(frame_client.right > 200);
    try std.testing.expectEqual(frame_client, try clientRect(surface.hwnd));

    // DestroyWindow on the frame sends WM_DESTROY to the frame, then to the
    // terminal's window, and the frame's WM_NCDESTROY only after its child
    // windows are gone: the frame lets go of the terminal, the terminal
    // frees itself, then the window frees itself. A leak or a second free
    // of either fails the test through the testing allocator.
    try std.testing.expect(win32.DestroyWindow(window.hwnd).toBool());
    try std.testing.expectEqual(0, app.surfaces.items.len);
    try std.testing.expectEqual(0, app.windows.items.len);
}

/// For tests: where `pane` is inside its frame's client area.
fn paneRect(window: *const Window, pane: *const Surface) !win32.RECT {
    var rect: win32.RECT = undefined;
    if (!win32.GetWindowRect(pane.hwnd, &rect).toBool()) return error.TestUnexpectedResult;
    if (!window.toClient(&rect)) return error.TestUnexpectedResult;
    return rect;
}

/// For tests: the window's caption, read into `buf`.
fn testCaption(window: *const Window, buf: []u16) []const u16 {
    const n = win32.GetWindowTextW(window.hwnd, buf.ptr, @intCast(buf.len));
    return buf[0..@intCast(n)];
}

/// For tests: `got` within a pixel of `want`, the most that rounding a
/// split's f16 ratio moves a divider.
fn expectNear(want: i32, got: i32) !void {
    if (@abs(want - got) > 1) {
        std.debug.print("expected {d} give or take 1, found {d}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

/// For tests: `panes` side by side, in this order, as splitting each one
/// off the last to the right puts them.
fn testRow(alloc: std.mem.Allocator, panes: []const *Surface) !Window.Tree {
    return testLine(alloc, panes, .right);
}

/// For tests: `panes` in a line, in this order, as splitting each one off
/// the last in `where` puts them.
fn testLine(
    alloc: std.mem.Allocator,
    panes: []const *Surface,
    where: Window.Tree.Split.Direction,
) !Window.Tree {
    var tree: Window.Tree = try .init(alloc, panes[0]);
    errdefer tree.deinit();
    for (panes[0 .. panes.len - 1], panes[1..]) |last, pane| {
        var single: Window.Tree = try .init(alloc, pane);
        defer single.deinit();
        const next = try tree.split(alloc, tree.locate(last).?, where, 0.5, &single);
        tree.deinit();
        tree = next;
    }
    return tree;
}

/// For tests: `panes` fill the window's client area side by side, in this
/// order, a divider apart.
fn expectRow(window: *const Window, panes: []const *Surface) !void {
    const client = try clientRect(window.hwnd);
    const divider = Window.dividerWidth(Window.dpiOf(window.app, window.hwnd));
    var left: i32 = 0;
    for (panes) |pane| {
        const rect = try paneRect(window, pane);
        try std.testing.expectEqual(left, rect.left);
        try std.testing.expectEqual(@as(i32, 0), rect.top);
        try std.testing.expectEqual(client.bottom, rect.bottom);
        left = rect.right + divider;
    }
    try std.testing.expectEqual(client.right, (try paneRect(window, panes[panes.len - 1])).right);
}

test "win32: a window lays its terminals out side by side" {
    // Where `Window.layout` says, moved and sized: both terminals start at
    // the frame's origin, so only a move puts the second beside the first.
    // The real classes and window procedures, with no core surfaces; the
    // windows stay hidden.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const left = try testPane(&app, window);
    const right = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ left, right });
    window.focused = left;

    window.relayout();
    try expectRow(window, &.{ left, right });

    // Half each, give or take the odd pixel.
    const left_rect = try paneRect(window, left);
    const right_rect = try paneRect(window, right);
    const left_width = left_rect.right - left_rect.left;
    const right_width = right_rect.right - right_rect.left;
    try std.testing.expect(@abs(left_width - right_width) <= 1);
}

test "win32: a closing terminal hands its place, and the focus if it had it" {
    // a | b | c | d. Closing a terminal without the focus leaves the focus
    // where it is; closing the one with it hands it to the one before it,
    // as on GTK, and the window is titled after that one. Either way the
    // others take its place, and the last one takes the window with it. The real classes and window procedures,
    // with no core surfaces; the windows stay hidden and are never
    // activated, so the focus is only remembered.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    var panes: [4]*Surface = undefined;
    for (&panes) |*pane| pane.* = try testPane(&app, window);
    const a, const b, const c, const d = panes;
    window.tree = try testRow(alloc, &panes);
    window.relayout();
    try expectRow(window, &panes);

    // Each titled, so that the caption shows which one has the focus.
    for (panes, [_][:0]const u8{ "a", "b", "c", "d" }) |pane, title| {
        try std.testing.expect(pane.setTitle(title));
    }
    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [8]u16 = undefined;

    // The terminal that gets WM_SETFOCUS is the window's. Sent straight to
    // its window procedure: SetFocus would activate the window.
    const focus = struct {
        fn focus(pane: *Surface) void {
            _ = Surface.wndProc(pane.hwnd, win32.WM_SETFOCUS, 0, 0);
        }
    }.focus;
    focus(d);
    try std.testing.expect(window.focused == d);

    try std.testing.expect(a.destroy());
    try std.testing.expect(window.focused == d);
    try expectRow(window, &.{ b, c, d });

    focus(c);
    try std.testing.expect(c.destroy());
    try std.testing.expect(window.focused == b);
    try std.testing.expectEqualSlices(u16, utf16("b"), testCaption(window, &buf));
    try expectRow(window, &.{ b, d });

    // The first terminal has none before it: the one after it.
    try std.testing.expect(b.destroy());
    try std.testing.expect(window.focused == d);
    try std.testing.expectEqualSlices(u16, utf16("d"), testCaption(window, &buf));
    try expectRow(window, &.{d});

    try std.testing.expect(d.destroy());
    try std.testing.expectEqual(0, app.surfaces.items.len);
    try std.testing.expectEqual(0, app.windows.items.len);
}

test "win32: goto_split finds the terminal it names" {
    // Three in a row and three in a column, so that going the wrong way
    // finds another terminal: with two, a search by direction wraps around
    // to the same one either way. The real classes and window procedures,
    // with no core surfaces; the windows stay hidden.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    // a | b | c
    const row = try testFrame(&app);
    const a = try testPane(&app, row);
    const b = try testPane(&app, row);
    const c = try testPane(&app, row);
    row.tree = try testRow(alloc, &.{ a, b, c });
    try std.testing.expect(row.goto(b, .left) == a);
    try std.testing.expect(row.goto(b, .right) == c);

    // In order, wrapping around.
    try std.testing.expect(row.goto(a, .next) == b);
    try std.testing.expect(row.goto(c, .next) == a);
    try std.testing.expect(row.goto(a, .previous) == c);
    try std.testing.expect(row.goto(b, .previous) == a);

    // x over y over z
    const column = try testFrame(&app);
    const x = try testPane(&app, column);
    const y = try testPane(&app, column);
    const z = try testPane(&app, column);
    column.tree = try testLine(alloc, &.{ x, y, z }, .down);
    try std.testing.expect(column.goto(y, .up) == x);
    try std.testing.expect(column.goto(y, .down) == z);

    // A window with one terminal has nowhere to go.
    const alone = try testFrame(&app);
    const only = try testPane(&app, alone);
    alone.tree = try .init(alloc, only);
    try std.testing.expect(alone.goto(only, .next) == null);
}

test "win32: goto_split answers at once and moves the focus after the key" {
    // The action says whether there is a split to go to, so that a key
    // with nowhere to go reaches the terminal, but the focus moves only
    // once the core's key callback has returned (`applyPendingFocus`). A
    // target that starts closing first is forgotten, and one already
    // closing is refused.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const alone = try testFrame(&app);
    const only = try testPane(&app, alone);
    alone.tree = try .init(alloc, only);
    try std.testing.expect(!try app.performAction(.{ .surface = &only.core_surface }, .goto_split, .next));
    try std.testing.expect(alone.pending_focus == null);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.focused = a;

    // Already closing: refused.
    b.core_state = .stopping;
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.pending_focus == null);

    // Live; no core call is made on it. Back to `.none` before the
    // teardown at the end, which would stop a live core.
    b.core_state = .live;
    defer b.core_state = .none;

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.focused == a);
    app.forgetClosing(&b.core_surface);
    app.applyPendingFocus();
    try std.testing.expect(window.focused == a);

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.focused == a);
    app.applyPendingFocus();
    try std.testing.expect(window.focused == b);
}

test "win32: goto_split moves the focus in every window it is performed in" {
    // An `all:` binding performs the action on every surface, so each
    // window keeps its own move until the key callback has returned
    // (`Window.pending_focus`): one slot for the app would keep only the
    // last window's.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const first = try testFrame(&app);
    const a = try testPane(&app, first);
    const b = try testPane(&app, first);
    first.tree = try testRow(alloc, &.{ a, b });
    first.focused = a;

    const second = try testFrame(&app);
    const c = try testPane(&app, second);
    const d = try testPane(&app, second);
    second.tree = try testRow(alloc, &.{ c, d });
    second.focused = c;

    // Live; no core call is made on them. Back to `.none` before the
    // teardown at the end, which would stop a live core.
    b.core_state = .live;
    defer b.core_state = .none;
    d.core_state = .live;
    defer d.core_state = .none;

    for ([_]*Surface{ a, c }) |from| {
        try std.testing.expect(try app.performAction(.{ .surface = &from.core_surface }, .goto_split, .right));
    }
    app.applyPendingFocus();
    try std.testing.expect(first.focused == b);
    try std.testing.expect(second.focused == d);
}

test "win32: a goto_split after a waiting split waits behind it" {
    // A binding that chains goto_split after new_split: the split is only
    // recorded (`requestSplit`), so the move is recorded behind it, to be
    // made once the split exists (`gotoQueued`), not worked out from the
    // window as it was before. A surface that starts closing first takes
    // both with it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.focused = a;
    b.core_state = .live;
    defer b.core_state = .none;

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .new_split, .down));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.pending_focus == null);
    try std.testing.expect(window.focused == a);

    const want = [_]App.Request{
        .{ .split = .{ .parent = &a.core_surface, .direction = .down } },
        .{ .goto = .{ .from = &a.core_surface, .to = .right } },
    };
    try std.testing.expectEqual(want.len, app.requests.items.len);
    for (want, app.requests.items) |w, got| {
        try std.testing.expect(std.meta.eql(w, got));
    }

    app.forgetClosing(&a.core_surface);
    for (app.requests.items) |request| try std.testing.expect(request == .dropped);
}

test "win32: a queued goto_split starts from the window's focused terminal" {
    // What `createRequested` does with a move queued behind a split: by
    // then the split's new terminal has the focus, and the move starts
    // there, as GTK's does, not from the terminal the binding was
    // performed on.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    // a | b | c, with the focus on b as a split beside a would leave it.
    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b, c });
    window.focused = b;
    b.core_state = .live;
    defer b.core_state = .none;
    c.core_state = .live;
    defer c.core_state = .none;

    try app.requests.append(alloc, .{ .goto = .{ .from = &a.core_surface, .to = .right } });
    app.createRequested();
    try std.testing.expect(window.focused == c);
    try std.testing.expectEqual(0, app.requests.items.len);
}

test "win32: resize_split moves the nearest divider across it" {
    // In (a | b) over c, left and right move the line between a and b, and
    // up and down the one above c (`SplitTree.resize` takes the nearest
    // split that runs across the move). An amount is in device-independent
    // pixels of the whole window: 96 DPI here, so pixels, give or take one
    // for rounding.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    window.tree = tree: {
        var row = try testRow(alloc, &.{ a, b });
        defer row.deinit();
        var below: Window.Tree = try .init(alloc, c);
        defer below.deinit();
        break :tree try row.split(alloc, .root, .down, 0.5, &below);
    };
    window.relayout();
    const before_a = try paneRect(window, a);
    const before_c = try paneRect(window, c);

    window.resizeSplit(a, .{ .amount = 20, .direction = .right });
    const wider = try paneRect(window, a);
    try expectNear(before_a.right + 20, wider.right);
    try std.testing.expectEqual(before_a.bottom, wider.bottom);

    window.resizeSplit(b, .{ .amount = 10, .direction = .up });
    const shorter = try paneRect(window, a);
    try expectNear(before_a.bottom - 10, shorter.bottom);
    try expectNear(before_c.top - 10, (try paneRect(window, c)).top);
    try std.testing.expectEqual(wider.right, shorter.right);
}

test "win32: resize_split never leaves a terminal less than a cell" {
    // SplitTree.resize clamps a ratio to 0 or 1, which would leave b no
    // room at all, so that move is refused (`Window.adopt`); a terminal
    // with no core needs a pixel, one with a core a cell of its font. The
    // largest amount also tests that the move is kept within the [-1, 1]
    // that SplitTree.resize asserts.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.relayout();
    const before = try paneRect(window, b);

    window.resizeSplit(a, .{ .amount = std.math.maxInt(u16), .direction = .right });
    try std.testing.expectEqual(before, try paneRect(window, b));

    // A move that leaves room is still made.
    window.resizeSplit(a, .{ .amount = 10, .direction = .right });
    try std.testing.expect((try paneRect(window, b)).left > before.left);
}

test "win32: equalize_splits gives each terminal an equal share" {
    // a | (b | c), as new splits leave it, gives a half. Equalizing weighs
    // each side of a split by its terminals (`SplitTree.equalize`).
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b, c });
    window.relayout();
    const width = struct {
        fn width(w: *const Window, pane: *const Surface) !i32 {
            const r = try paneRect(w, pane);
            return r.right - r.left;
        }
    }.width;
    try std.testing.expect(try width(window, a) > try width(window, b) + 1);

    window.equalize();
    try expectNear(try width(window, a), try width(window, b));
    try expectNear(try width(window, b), try width(window, c));
    try expectRow(window, &.{ a, b, c });
}

test "win32: resize_split and equalize_splits wait for run" {
    // Laying the terminals out moves windows, whose WM_SIZE would re-enter
    // the core inside its key callback, so both are recorded and made by
    // createRequested. resize_split is not performed with no amount, or for
    // a single terminal unless a split may still come, so that the key
    // reaches the terminal. A surface that starts closing takes its own
    // with it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const alone = try testFrame(&app);
    const only = try testPane(&app, alone);
    alone.tree = try .init(alloc, only);
    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.focused = a;
    window.relayout();

    const right: apprt.action.ResizeSplit = .{ .amount = 20, .direction = .right };
    try std.testing.expect(!try app.performAction(.{ .surface = &only.core_surface }, .resize_split, right));
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .resize_split, .{ .amount = 0, .direction = .right }));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Requests that cannot give `only` a split leave its key alone.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .new_window, {}));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .new_split, .down));
    try std.testing.expect(!try app.performAction(.{ .surface = &only.core_surface }, .resize_split, right));
    try std.testing.expectEqual(2, app.requests.items.len);
    app.requests.clearRetainingCapacity();

    const before = try paneRect(window, a);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .resize_split, right));
    try std.testing.expect(try app.performAction(.{ .surface = &only.core_surface }, .equalize_splits, {}));
    try std.testing.expectEqual(before, try paneRect(window, a));
    const want = [_]App.Request{
        .{ .resize = .{ .from = &a.core_surface, .value = right } },
        .{ .equalize = &only.core_surface },
    };
    try std.testing.expectEqual(want.len, app.requests.items.len);
    for (want, app.requests.items) |w, got| {
        try std.testing.expect(std.meta.eql(w, got));
    }
    app.createRequested();
    try std.testing.expectEqual(0, app.requests.items.len);
    try expectNear(before.right + 20, (try paneRect(window, a)).right);

    // A single terminal's resize waits behind a split still to come.
    try std.testing.expect(try app.performAction(.{ .surface = &only.core_surface }, .new_split, .right));
    try std.testing.expect(try app.performAction(.{ .surface = &only.core_surface }, .resize_split, right));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .equalize_splits, {}));
    try std.testing.expectEqual(3, app.requests.items.len);
    app.forgetClosing(&only.core_surface);
    app.forgetClosing(&a.core_surface);
    for (app.requests.items) |request| try std.testing.expect(request == .dropped);
}

test "win32: queued split changes reach the window from its focused terminal" {
    // What createRequested does with a .resize and an .equalize: a resize
    // starts from the window's focused terminal, as gotoQueued does (GTK's
    // active surface), not from the one that asked; an equalize reaches the
    // asking surface's window. In a | (b over c) only a path from b or c
    // crosses a line that runs across, so a resize down from a would move
    // nothing.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    window.tree = tree: {
        var row = try testRow(alloc, &.{ a, b });
        defer row.deinit();
        var below: Window.Tree = try .init(alloc, c);
        defer below.deinit();
        break :tree try row.split(alloc, row.locate(b).?, .down, 0.5, &below);
    };
    window.focused = b;
    window.relayout();
    const before = try paneRect(window, b);
    try app.requests.append(alloc, .{ .resize = .{
        .from = &a.core_surface,
        .value = .{ .amount = 10, .direction = .down },
    } });
    app.createRequested();
    try expectNear(before.bottom + 10, (try paneRect(window, b)).bottom);

    // a | b | c as new splits leave it: a has half until equalized.
    const row = try testFrame(&app);
    const x = try testPane(&app, row);
    const y = try testPane(&app, row);
    const z = try testPane(&app, row);
    row.tree = try testRow(alloc, &.{ x, y, z });
    row.relayout();
    try app.requests.append(alloc, .{ .equalize = &x.core_surface });
    app.createRequested();
    try expectRow(row, &.{ x, y, z });
    const wx = (try paneRect(row, x)).right - (try paneRect(row, x)).left;
    const wz = (try paneRect(row, z)).right - (try paneRect(row, z)).left;
    try expectNear(wx, wz);
}

test "win32: a window is titled after its focused terminal" {
    // A title set on another terminal waits until it gets the focus.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const left = try testPane(&app, window);
    const right = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ left, right });

    const caption = testCaption;
    var buf: [64]u16 = undefined;

    _ = Surface.wndProc(left.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(left.setTitle("left"));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("left"), caption(window, &buf));

    try std.testing.expect(right.setTitle("right"));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("left"), caption(window, &buf));

    _ = Surface.wndProc(right.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("right"), caption(window, &buf));
}

test "win32: a click on an inactive window picks the terminal it focuses" {
    // The click only activates the window, and the activation focuses the
    // terminal clicked rather than the one that had the focus before.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const left = try testPane(&app, window);
    const right = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ left, right });
    window.focused = left;

    // A left button press on the client area; the hidden frame is not the
    // active window.
    const lparam: win32.LPARAM = (@as(win32.LPARAM, win32.WM_LBUTTONDOWN) << 16) | win32.HTCLIENT;
    try std.testing.expectEqual(
        win32.MA_ACTIVATEANDEAT,
        Surface.wndProc(right.hwnd, win32.WM_MOUSEACTIVATE, @intFromPtr(window.hwnd), lparam),
    );
    try std.testing.expect(window.focused == right);
}

test "win32: close_tab closes the window, its one tab" {
    // Without tabs a window is its own one tab, so close_tab:this, the
    // default Ctrl+Shift+W, closes it as close_window does: one teardown
    // is posted to the frame, and it frees the window and its terminals.
    // The other modes name tabs there are not: unsupported, so the action
    // reports not performed (a `performable:` binding then passes its key
    // to the terminal), and nothing is posted.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.focused = a;

    var msg: win32.MSG = undefined;
    for ([_]apprt.action.CloseTabMode{ .other, .right }) |mode| {
        try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .close_tab, mode));
    }
    try std.testing.expect(!win32.PeekMessageW(
        &msg,
        window.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_NOREMOVE,
    ).toBool());

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .close_tab, .this));
    try std.testing.expect(window.closing);
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        window.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_REMOVE,
    ).toBool());
    _ = win32.DispatchMessageW(&msg);
    try std.testing.expectEqual(0, app.windows.items.len);
    try std.testing.expectEqual(0, app.surfaces.items.len);
}

test "win32: closing a window takes every terminal in it at once" {
    // One request posts one teardown to the frame, and leaves the window
    // on screen: it runs inside a core call for close_window, where hiding
    // the window could activate another. The teardown destroys the frame
    // and frees it and its terminals; a second request while it is
    // pending posts nothing. Dispatched inside another teardown's wait, the
    // teardown waits and is posted again. The terminals have no core
    // surfaces, so there is nothing to ask about and no core to stop: this
    // covers the posting and the freeing, not the stopping, which needs a
    // running core (the VM scenarios close windows with live shells).
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.focused = a;

    // Shown without being activated, so that a change is seen.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    try std.testing.expect(win32.IsWindowVisible(window.hwnd).toBool());

    window.requestClose();
    window.requestClose();
    try std.testing.expect(win32.IsWindowVisible(window.hwnd).toBool());
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        window.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_REMOVE,
    ).toBool());
    var second: win32.MSG = undefined;
    try std.testing.expect(!win32.PeekMessageW(
        &second,
        window.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_NOREMOVE,
    ).toBool());

    // Inside another teardown's wait: deferred, the window untouched.
    app.teardown_depth = 1;
    _ = win32.DispatchMessageW(&msg);
    try std.testing.expect(window.destroy_deferred);
    try std.testing.expectEqual(2, app.surfaces.items.len);

    // Posted again once no teardown runs, and then it runs.
    app.teardown_depth = 0;
    app.repostDeferredDestroys();
    try std.testing.expect(!window.destroy_deferred);
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        window.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_REMOVE,
    ).toBool());
    _ = win32.DispatchMessageW(&msg);
    try std.testing.expectEqual(0, app.surfaces.items.len);
    try std.testing.expectEqual(0, app.windows.items.len);
}

test "win32: a terminal with no core closes through a posted teardown" {
    // Not destroyed on the spot: a WM_CLOSE can be dispatched inside
    // another teardown's wait, which must not change the terminals under
    // it (`Window.destroy`).
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;

    // Both still there: had the close destroyed the terminal, it would
    // have taken the window and freed both.
    _ = Surface.wndProc(pane.hwnd, win32.WM_CLOSE, 0, 0);
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(1, app.surfaces.items.len);
    try std.testing.expect(pane.closing);
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        pane.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_REMOVE,
    ).toBool());

    // The teardown it posted takes the window with its only terminal.
    _ = win32.DispatchMessageW(&msg);
    try std.testing.expectEqual(0, app.surfaces.items.len);
    try std.testing.expectEqual(0, app.windows.items.len);
}

test "win32: new windows and splits are recorded where they are asked for" {
    // A `new_window` or `new_split` binding performs the action from inside
    // the core's key callback, so the action only records the request;
    // `run` creates it after its tick. A surface that starts closing in
    // between clears itself from its requests (`forgetClosing`, called
    // by Surface.stopCore): a window it asked for has no parent, and a split
    // beside it is dropped, so a surface created later at the same address
    // is not taken for the parent.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;

    var app: App = undefined;
    try testApp(&app, &core_app);
    defer testCleanup(&app);

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var open: Surface = undefined;
        var closed: Surface = undefined;
    };
    const open = &s.open.core_surface;
    const closed = &s.closed.core_surface;

    for ([_]apprt.Target{ .{ .surface = open }, .{ .surface = closed }, .app }) |target| {
        try std.testing.expect(try app.performAction(target, .new_window, {}));
    }
    try std.testing.expect(try app.performAction(.{ .surface = open }, .new_split, .right));
    try std.testing.expect(try app.performAction(.{ .surface = closed }, .new_split, .down));
    // A split needs a surface to go beside.
    try std.testing.expect(!try app.performAction(.app, .new_split, .left));
    try std.testing.expectEqual(0, app.surfaces.items.len);

    app.forgetClosing(closed);

    const want = [_]App.Request{
        .{ .window = open },
        .{ .window = null },
        .{ .window = null },
        .{ .split = .{ .parent = open, .direction = .right } },
        .dropped,
    };
    try std.testing.expectEqual(want.len, app.requests.items.len);
    for (want, app.requests.items) |w, got| {
        try std.testing.expect(std.meta.eql(w, got));
    }
}

test "win32: config_change makes a copy of the app's configuration" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    defer testCleanup(&app);

    // The value only lives for the action. The title is in its arena, so
    // a configuration that kept pointing into it would read freed memory.
    {
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.title = try changed.arenaAlloc().dupeSentinel(u8, "reloaded", 0);
        changed.@"split-divider-color" = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
    }
    try std.testing.expectEqualStrings("reloaded", app.config.title.?);

    // The dividers are painted from it.
    try std.testing.expectEqual(
        terminal.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 },
        Window.dividerColor(&app.config),
    );
}

test "win32: a soft reload_config hands the app's configuration back through the core" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    try core_app.init(alloc);
    defer core_app.deinit();
    var app: App = undefined;
    try testApp(&app, &core_app);
    defer testCleanup(&app);
    app.config.title = try app.config.arenaAlloc().dupeSentinel(u8, "kept", 0);
    const before = app.config.title.?.ptr;

    // The core applies the app's conditional state and answers with
    // config_change, which replaces the configuration the reload started
    // from with a copy of the result: the same settings in new memory. The
    // testing allocator fails a free of the old one that is missing or
    // comes twice.
    try std.testing.expect(try app.performAction(.app, .reload_config, .{ .soft = true }));
    try std.testing.expectEqualStrings("kept", app.config.title.?);
    try std.testing.expect(app.config.title.?.ptr != before);
}

test "win32: a full reload_config waits for run" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    try core_app.init(alloc);
    defer core_app.deinit();
    var app: App = undefined;
    try testApp(&app, &core_app);
    defer testCleanup(&app);
    app.config.title = try app.config.arenaAlloc().dupeSentinel(u8, "kept", 0);
    const before = app.config.title.?.ptr;

    // From a binding, inside the core's key callback: recorded, and the
    // configuration the binding may still be reading stays. `run` makes it
    // (`reloadQueued`), which reads the configuration from disk, so it is
    // not made here: the VM scenario does that.
    try std.testing.expect(try app.performAction(.app, .reload_config, .{}));
    try std.testing.expect(app.config.title != null);
    try std.testing.expectEqual(before, app.config.title.?.ptr);
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .reload);
}

test "win32: the core is told the color scheme the title bars show" {
    const alloc = std.testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();

    for ([_]apprt.ColorScheme{ .light, .dark }) |system| {
        config.@"window-theme" = .system;
        try std.testing.expectEqual(system, coreScheme(&config, system));
        config.@"window-theme" = .light;
        try std.testing.expectEqual(.light, coreScheme(&config, system));
        config.@"window-theme" = .dark;
        try std.testing.expectEqual(.dark, coreScheme(&config, system));
    }

    // auto and ghostty: the background's, against the system's mode, and
    // with a light and a dark theme the system's, against the background.
    for ([_]configpkg.Config.WindowTheme{ .auto, .ghostty }) |theme| {
        config.@"window-theme" = theme;
        config._conditional_set = .{};
        config.background = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
        try std.testing.expectEqual(.dark, coreScheme(&config, .light));
        config.background = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
        try std.testing.expectEqual(.light, coreScheme(&config, .dark));
        config._conditional_set.insert(.theme);
        try std.testing.expectEqual(.dark, coreScheme(&config, .dark));
    }
}

test "win32: the core is told the color scheme when it changes" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    try core_app.init(alloc);
    defer core_app.deinit();
    var app: App = undefined;
    try testApp(&app, &core_app);
    defer testCleanup(&app);
    app.config.title = try app.config.arenaAlloc().dupeSentinel(u8, "kept", 0);

    // The system's dark mode reaches the core, which reloads the app's
    // configuration softly for it: config_change replaces this runtime's
    // with a copy. The frames change for its `window-decoration` from
    // `run`, which is woken for it: `run` tells the core after making
    // what was recorded.
    app.config.@"window-theme" = .system;
    app.system_scheme = .dark;
    const before = app.config.title.?.ptr;
    app.syncColorScheme();
    try std.testing.expectEqual(.dark, core_app.config_conditional_state.theme);
    try std.testing.expect(app.config.title.?.ptr != before);
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .redecorate);
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        app.msg_hwnd,
        WM_GHOSTTY_WAKEUP,
        WM_GHOSTTY_WAKEUP,
        win32.PM_REMOVE,
    ).toBool());

    // Told once. The core ignores a repeat by itself, so it is made to have
    // lost the scheme: told again, it would take it back and reload.
    core_app.config_conditional_state.theme = .light;
    const told = app.config.title.?.ptr;
    app.syncColorScheme();
    try std.testing.expectEqual(.light, core_app.config_conditional_state.theme);
    try std.testing.expectEqual(told, app.config.title.?.ptr);
    core_app.config_conditional_state.theme = .dark;

    // window-theme = light overrides the system's mode.
    app.config.@"window-theme" = .light;
    app.syncColorScheme();
    try std.testing.expectEqual(.light, core_app.config_conditional_state.theme);
}

test "win32: a change of the system's app mode reaches every title bar" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    app.config.@"window-theme" = .system;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    const window = try testFrame(&app);

    // The mode read last is the other one, as if Windows had just switched,
    // and the frame shows it. The system's mode itself is never changed.
    const now = systemColorScheme();
    app.system_scheme = if (now == .dark) .light else .dark;
    window.applyTheme();
    try std.testing.expectEqual(now != .dark, window.dark_frame);

    // Windows announces the change to every top-level window, with the
    // name in a buffer of its own.
    var name = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet").*;
    _ = win32.SendMessageW(window.hwnd, win32.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(&name)));
    try std.testing.expectEqual(now, app.system_scheme);
    try std.testing.expectEqual(now == .dark, window.dark_frame);

    // The message was sent, so `run` is woken to tell the core.
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        app.msg_hwnd,
        WM_GHOSTTY_WAKEUP,
        WM_GHOSTTY_WAKEUP,
        win32.PM_REMOVE,
    ).toBool());
}

test "win32: a new configuration re-themes every title bar" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    const window = try testFrame(&app);

    // Each way, so that it fails whatever the frame showed before.
    for ([_]configpkg.Config.WindowTheme{ .dark, .light, .dark }) |theme| {
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.@"window-theme" = theme;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        try std.testing.expectEqual(theme == .dark, window.dark_frame);
    }
}

test "win32: toggle_fullscreen waits for run, covers the monitor and comes back" {
    // Covering the monitor lays the terminals out again, whose WM_SIZE
    // would re-enter the core inside its key callback, so the toggle is
    // recorded and made by createRequested. A surface that starts closing
    // takes its own with it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const placed = try windowRect(window.hwnd);
    const info = try monitorOf(window.hwnd);

    // Recorded, not made.
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    try std.testing.expectEqual(placed, try windowRect(window.hwnd));
    try std.testing.expectEqual(1, app.requests.items.len);

    // Made: the frame covers the monitor with no caption, and the terminal
    // fills it.
    app.createRequested();
    try std.testing.expectEqual(info.rcMonitor, try windowRect(window.hwnd));
    try std.testing.expect(!captioned(window.hwnd));
    try std.testing.expectEqual(try clientRect(window.hwnd), try clientRect(pane.hwnd));

    // Not maximized while it covers the monitor.
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_maximize, {}));
    app.createRequested();
    try std.testing.expectEqual(info.rcMonitor, try windowRect(window.hwnd));
    try std.testing.expect(!win32.IsZoomed(window.hwnd).toBool());

    // Nor by Win+Up's maximize, which would give it the work area.
    _ = win32.SendMessageW(window.hwnd, win32.WM_SYSCOMMAND, win32.SC_MAXIMIZE, 0);
    try std.testing.expectEqual(info.rcMonitor, try windowRect(window.hwnd));
    try std.testing.expect(!win32.IsZoomed(window.hwnd).toBool());

    // A change of scale keeps it covering the monitor, not the scaled rect
    // Windows suggests.
    var suggested = info.rcMonitor;
    suggested.right += 600;
    suggested.bottom += 300;
    _ = win32.SendMessageW(window.hwnd, win32.WM_DPICHANGED, 144 << 16 | 144, @bitCast(@intFromPtr(&suggested)));
    try std.testing.expectEqual(info.rcMonitor, try windowRect(window.hwnd));

    // And back, with its frame, where it was: at its rect, not its
    // placement's, which a window snapped to a side of the screen keeps
    // from before the snap.
    window.fullscreen.?.placement.rcNormalPosition.left += 40;
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.createRequested();
    try std.testing.expectEqual(placed, try windowRect(window.hwnd));
    try std.testing.expect(captioned(window.hwnd));
    try std.testing.expectEqual(null, window.fullscreen);

    // Unless no monitor shows that rect any more, as when its monitor is
    // unplugged: then by its placement, which comes back on a monitor.
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.createRequested();
    window.fullscreen.?.rect = .{ .left = -40000, .top = -40000, .right = -39000, .bottom = -39500 };
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.createRequested();
    try std.testing.expectEqual(placed, try windowRect(window.hwnd));

    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.forgetClosing(&pane.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
}

test "win32: a maximized window comes back from fullscreen maximized" {
    // From maximized, a window that covers its monitor keeps WS_MAXIMIZE:
    // Win+Down's restore leaves fullscreen rather than restoring it with no
    // frame, Win+Up's maximize does nothing, and a chained
    // toggle_fullscreen then toggle_maximize keep their order.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;
    _ = win32.ShowWindow(window.hwnd, win32.SW_MAXIMIZE);

    // Maximized as the caption button does it, not by toggle_maximize,
    // which goes by the window: it restores it, then maximizes it again.
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_maximize, {}));
    app.createRequested();
    try std.testing.expect(!win32.IsZoomed(window.hwnd).toBool());
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_maximize, {}));
    app.createRequested();
    try std.testing.expect(win32.IsZoomed(window.hwnd).toBool());
    const maximized = try windowRect(window.hwnd);

    for ([_]win32.WPARAM{ win32.SC_MAXIMIZE, win32.SC_RESTORE }) |command| {
        try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
        app.createRequested();
        try std.testing.expect(window.fullscreen != null);
        const covering = try windowRect(window.hwnd);

        _ = win32.SendMessageW(window.hwnd, win32.WM_SYSCOMMAND, win32.SC_MAXIMIZE, 0);
        try std.testing.expectEqual(covering, try windowRect(window.hwnd));
        _ = win32.SendMessageW(window.hwnd, win32.WM_SYSCOMMAND, command, 0);
        if (command == win32.SC_MAXIMIZE) {
            // Still covering; leave by the toggle.
            try std.testing.expectEqual(covering, try windowRect(window.hwnd));
            try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
            app.createRequested();
        }
        try std.testing.expectEqual(null, window.fullscreen);
        try std.testing.expect(win32.IsZoomed(window.hwnd).toBool());
        try std.testing.expectEqual(maximized, try windowRect(window.hwnd));
        try std.testing.expect(captioned(window.hwnd));
    }

    // Minimized while it covers the monitor, then restored, as from the
    // taskbar: it comes back covering it, still fullscreen, though it was
    // maximized.
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.createRequested();
    const covering = try windowRect(window.hwnd);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMINNOACTIVE);
    try std.testing.expect(win32.IsIconic(window.hwnd).toBool());
    _ = win32.SendMessageW(window.hwnd, win32.WM_SYSCOMMAND, win32.SC_RESTORE, 0);
    try std.testing.expect(!win32.IsIconic(window.hwnd).toBool());
    try std.testing.expect(window.fullscreen != null);
    try std.testing.expectEqual(covering, try windowRect(window.hwnd));
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.createRequested();
    try std.testing.expectEqual(maximized, try windowRect(window.hwnd));

    // Covering the monitor, then a chain of toggle_fullscreen and
    // toggle_maximize: out of fullscreen first, then restored from
    // maximized, in that order.
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    app.createRequested();
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_fullscreen, .native));
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .toggle_maximize, {}));
    app.createRequested();
    try std.testing.expectEqual(null, window.fullscreen);
    try std.testing.expect(!win32.IsZoomed(window.hwnd).toBool());
}

test "win32: toggle_split_zoom waits for run and zooms the focused terminal" {
    // A zoom lays the terminals out again, whose WM_SIZE would re-enter the
    // core inside its key callback, so it is recorded and made by
    // createRequested; a single terminal's key reaches the terminal. A
    // goto_split ends the zoom, or moves it with split-preserve-zoom =
    // navigation, so that the focus never goes to a hidden terminal.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const alone = try testFrame(&app);
    const only = try testPane(&app, alone);
    alone.tree = try .init(alloc, only);
    try std.testing.expect(!try app.performAction(.{ .surface = &only.core_surface }, .toggle_split_zoom, {}));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Unless a split for its window is still to come, as in a chain.
    try std.testing.expect(try app.performAction(.{ .surface = &only.core_surface }, .new_split, .right));
    try std.testing.expect(try app.performAction(.{ .surface = &only.core_surface }, .toggle_split_zoom, {}));
    try std.testing.expectEqual(2, app.requests.items.len);
    app.requests.clearRetainingCapacity();

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ a, b });
    window.focused = a;
    window.relayout();
    const split_a = try paneRect(window, a);

    // Recorded, then made from the focused terminal: it fills the frame
    // and the other is hidden.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_split_zoom, {}));
    try std.testing.expectEqual(split_a, try paneRect(window, a));
    app.createRequested();
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    try std.testing.expect(!shown(b.hwnd));

    // A split from it divides its place in the tiling, not the window it
    // covers: the split ends the zoom.
    try std.testing.expectEqual(split_a, window.tiledPlace(a).?);

    // And back.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .toggle_split_zoom, {}));
    app.createRequested();
    try std.testing.expectEqual(split_a, try paneRect(window, a));
    try std.testing.expect(shown(b.hwnd));

    // A goto_split from the zoomed terminal ends the zoom. The target is
    // live only for the action, which refuses one that is not; no core
    // call is made on it.
    for ([_]bool{ false, true }) |navigation| {
        app.config.@"split-preserve-zoom".navigation = navigation;
        window.focused = a;
        try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .toggle_split_zoom, {}));
        app.createRequested();
        b.core_state = .live;
        const goes = try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right);
        b.core_state = .none;
        try std.testing.expect(goes);
        app.applyPendingFocus();
        try std.testing.expect(window.focused == b);
        try std.testing.expect(shown(b.hwnd));
        if (navigation) {
            // The zoom moved to it.
            try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, b));
            try std.testing.expect(!shown(a.hwnd));
            window.toggleZoom(b);
        } else {
            try std.testing.expectEqual(split_a, try paneRect(window, a));
        }
    }

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .toggle_split_zoom, {}));
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
}

test "win32: open_config's new_window is not handled" {
    // `new_window`, $EDITOR in a new window, is GTK's alone, as it was
    // before open_config was handled; `os_open` starts a program, so only
    // the VM scenario runs it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    defer testCleanup(&app);
    try std.testing.expect(!try app.performAction(.app, .open_config, .new_window));
}

test "win32: a text file of no registered kind opens as a text file" {
    const ext = std.unicode.utf8ToUtf16LeStringLiteral;
    // The configuration's path is joined with '/': its separators are made
    // backslashes before its extension is looked for.
    var path = ext("C:\\Users\\me/.config/ghostty/config.ghostty").*;
    try std.testing.expectEqualSlices(u16, ext(".ghostty"), std.mem.span(textPathExtension(&path)));
    try std.testing.expectEqualSlices(u16, ext("C:\\Users\\me\\.config\\ghostty\\config.ghostty"), &path);
    // The legacy file has none; a dot in a directory's name is not one.
    var legacy = ext("C:\\Users\\me.x/ghostty/config").*;
    try std.testing.expectEqualSlices(u16, ext(""), std.mem.span(textPathExtension(&legacy)));
    // Nor does a path PathFindExtensionW does not take.
    var long: [win32.MAX_PATH + 4:0]u16 = @splat('a');
    @memcpy(long[long.len - 4 ..], ext(".txt"));
    try std.testing.expectEqualSlices(u16, ext(""), std.mem.span(textPathExtension(&long)));

    // A program for a kind every Windows registers; none for a kind nobody
    // registered, nor for no kind; the shell's Unknown type does not count.
    try std.testing.expect(hasProgram(ext(".exe")));
    try std.testing.expect(!hasProgram(ext(".ghostty-test-no-such-kind")));
    try std.testing.expect(!hasProgram(ext("")));
}

test "win32: the configuration errors list at most twenty diagnostics" {
    const alloc = std.testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    for (0..21) |i| try config.addDiagnosticFmt("bad line {d}", .{i});
    try config.addDiagnosticFmt("bad \xff byte", .{});

    const wide = try configErrorsText(alloc, &config);
    defer alloc.free(wide);
    const text = try std.unicode.utf16LeToUtf8Alloc(alloc, wide);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "One or more configuration errors were found."));
    try std.testing.expect(std.mem.indexOf(u8, text, "bad line 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bad line 19\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bad line 20") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "...and 2 more\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Cancel ignores these errors."));

    // A byte that is not UTF-8, or a NUL, as a diagnostic quoting the file
    // can hold, does not stop the list where MessageBoxW reads it: up to
    // the first NUL.
    var one: Config = try .default(alloc);
    defer one.deinit();
    try one.addDiagnosticFmt("bad \xff byte", .{});
    try one.addDiagnosticFmt("bad \x00 byte", .{});
    try one.addDiagnosticFmt("next", .{});
    const wide_one = try configErrorsText(alloc, &one);
    defer alloc.free(wide_one);
    const text_one = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(wide_one.ptr));
    defer alloc.free(text_one);
    try std.testing.expect(std.mem.indexOf(u8, text_one, "bad \u{FFFD} byte\nbad \u{FFFD} byte\nnext\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text_one, "Cancel ignores these errors."));
}

test "win32: maximize starts a window maximized, and under fullscreen too" {
    // GTK applies maximize before fullscreen: a window that starts covering
    // its monitor comes back maximized. No terminal is focused, so no
    // initial size applies.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    app.config.maximize = true;

    const window = try testFrame(&app);
    window.show();
    try std.testing.expect(shown(window.hwnd));
    try std.testing.expect(win32.IsZoomed(window.hwnd).toBool());

    app.config.fullscreen = .true;
    const covering = try testFrame(&app);
    covering.show();
    try std.testing.expect(shown(covering.hwnd));
    try std.testing.expect(covering.fullscreen != null);
    covering.toggleFullscreen();
    try std.testing.expect(win32.IsZoomed(covering.hwnd).toBool());
    try std.testing.expectEqual(try windowRect(window.hwnd), try windowRect(covering.hwnd));
}

test "win32: goto_window waits for run and goes round the windows" {
    // Activating a window moves the focus, which would reach the asking
    // terminal's core inside its key callback, so the move is recorded and
    // made by createRequested; with one window the key reaches the
    // terminal. Activation needs the foreground, which a test process does
    // not hold, but `Window.present` restores a minimized window first, so
    // the window gone to is the one no longer minimized.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    var windows: [3]*Window = undefined;
    var panes: [3]*Surface = undefined;
    for (&windows, &panes, 0..) |*w, *p, i| {
        w.* = try testFrame(&app);
        p.* = try testPane(&app, w.*);
        w.*.tree = try .init(alloc, p.*);
        if (i == 0) {
            // Alone, there is nowhere to go.
            try std.testing.expect(!try app.performAction(.{ .surface = &p.*.core_surface }, .goto_window, .next));
            try std.testing.expectEqual(0, app.requests.items.len);
        }
    }

    // In GTK's order, newest first: next is the window opened before,
    // previous the one opened after, round the ends.
    try std.testing.expectEqual(windows[2], app.windowBeside(windows[0], .next).?);
    try std.testing.expectEqual(windows[1], app.windowBeside(windows[0], .previous).?);
    try std.testing.expectEqual(windows[1], app.windowBeside(windows[2], .next).?);
    try std.testing.expectEqual(windows[0], app.windowBeside(windows[2], .previous).?);

    const Case = struct { to: apprt.action.GotoWindow, want: usize, other: usize };
    for ([_]Case{
        .{ .to = .next, .want = 2, .other = 1 },
        .{ .to = .previous, .want = 1, .other = 2 },
    }) |c| {
        for (windows[1..]) |w| _ = win32.ShowWindow(w.hwnd, win32.SW_SHOWMINNOACTIVE);
        try std.testing.expect(try app.performAction(.{ .surface = &panes[0].core_surface }, .goto_window, c.to));
        try std.testing.expectEqual(1, app.requests.items.len);
        try std.testing.expect(win32.IsIconic(windows[c.want].hwnd).toBool());
        app.createRequested();
        try std.testing.expectEqual(0, app.requests.items.len);
        try std.testing.expect(!win32.IsIconic(windows[c.want].hwnd).toBool());
        try std.testing.expect(win32.IsIconic(windows[c.other].hwnd).toBool());
    }

    // A closing terminal drops its own.
    try std.testing.expect(try app.performAction(.{ .surface = &panes[0].core_surface }, .goto_window, .next));
    app.forgetClosing(&panes[0].core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.requests.clearRetainingCapacity();

    // A window closing between others leaves the rest in opening order.
    const last = try testFrame(&app);
    try std.testing.expect(win32.DestroyWindow(windows[1].hwnd).toBool());
    try std.testing.expectEqual(last, app.windowBeside(windows[0], .next).?);
    try std.testing.expectEqual(windows[2], app.windowBeside(windows[0], .previous).?);
}

test "win32: resize_window waits for run and resizes the window of a lone terminal" {
    // A program asks for it (CSI 8 t), and the core asks from inside a
    // tick; the terminals are laid out again, so it is recorded and made
    // by createRequested. As on GTK and macOS only the one terminal of a
    // window at a size of its own is resized, and a zero dimension is
    // kept.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const target: apprt.Target = .{ .surface = &pane.core_surface };
    const scale = try pane.getContentScale();

    // Recorded, not made; then the width, and the height kept.
    const before = try clientRect(window.hwnd);
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 300, .height = 0 }));
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expectEqual(before, try clientRect(window.hwnd));
    app.createRequested();
    const wide = try clientRect(window.hwnd);
    try std.testing.expectEqual(Window.scaledSize(300, scale.x), wide.right);
    try std.testing.expectEqual(before.bottom, wide.bottom);
    try std.testing.expectEqual(wide, try clientRect(pane.hwnd));

    // The height, and the width kept.
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 0, .height = 200 }));
    app.createRequested();
    const tall = try clientRect(window.hwnd);
    try std.testing.expectEqual(wide.right, tall.right);
    try std.testing.expectEqual(Window.scaledSize(200, scale.y), tall.bottom);

    // Not for a maximized window, nor one covering its monitor.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMAXIMIZED);
    try std.testing.expect(!try app.performAction(target, .resize_window, .{ .width = 300, .height = 200 }));
    _ = win32.ShowWindow(window.hwnd, win32.SW_RESTORE);
    window.toggleFullscreen();
    try std.testing.expect(!try app.performAction(target, .resize_window, .{ .width = 300, .height = 200 }));
    window.toggleFullscreen();
    try std.testing.expectEqual(0, app.requests.items.len);

    // Nor for a snapped one, which Windows tells apart from Windows 10
    // 1903 (IsWindowArranged); one that is not is resized.
    const arranged = struct {
        fn yes(_: win32.HWND) callconv(.winapi) win32.BOOL {
            return .TRUE;
        }
        fn no(_: win32.HWND) callconv(.winapi) win32.BOOL {
            return .FALSE;
        }
    };
    app.is_window_arranged = arranged.yes;
    try std.testing.expect(!try app.performAction(target, .resize_window, .{ .width = 300, .height = 200 }));
    try std.testing.expectEqual(0, app.requests.items.len);
    app.is_window_arranged = arranged.no;
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 300, .height = 200 }));
    app.requests.clearRetainingCapacity();
    app.is_window_arranged = null;

    // A closing terminal drops its own, and a window that is no longer
    // at a size of its own when run comes is left as it is.
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 400, .height = 0 }));
    app.forgetClosing(&pane.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.requests.clearRetainingCapacity();
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 400, .height = 0 }));
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMAXIMIZED);
    const maximized = try windowRect(window.hwnd);
    app.createRequested();
    try std.testing.expectEqual(maximized, try windowRect(window.hwnd));
    _ = win32.ShowWindow(window.hwnd, win32.SW_RESTORE);

    // Not in a split.
    const other = try testPane(&app, window);
    window.tree.deinit();
    window.tree = try testRow(alloc, &.{ pane, other });
    try std.testing.expect(!try app.performAction(target, .resize_window, .{ .width = 300, .height = 200 }));
}

test "win32: reset_window_size waits for run and gives the window a new one's size" {
    // As on macOS: maximized with `maximize`, or else the size
    // `window-width` and `window-height` ask for; nothing with neither, or
    // for a window covering its monitor. The terminals are laid out again,
    // so it is recorded and made by createRequested.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const target: apprt.Target = .{ .surface = &pane.core_surface };
    const scale = try pane.getContentScale();

    // No size to go back to.
    try std.testing.expect(!try app.performAction(target, .reset_window_size, {}));

    // The size `window-width` and `window-height` ask for: recorded, not
    // made; then the client area takes it.
    pane.initial_size = .{ .width = 320, .height = 180 };
    const before = try clientRect(window.hwnd);
    try std.testing.expect(try app.performAction(target, .reset_window_size, {}));
    try std.testing.expectEqual(before, try clientRect(window.hwnd));
    app.createRequested();
    const sized = try clientRect(window.hwnd);
    try std.testing.expectEqual(Window.scaledSize(320, scale.x), sized.right);
    try std.testing.expectEqual(Window.scaledSize(180, scale.x), sized.bottom);

    // A maximized window is restored and given it, though it was
    // resized after, which is what it would be restored to.
    const resized = win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;
    _ = win32.SetWindowPos(window.hwnd, null, 0, 0, 500, 400, resized);
    try std.testing.expect(!std.meta.eql(sized, try clientRect(window.hwnd)));
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMAXIMIZED);
    try std.testing.expect(try app.performAction(target, .reset_window_size, {}));
    app.createRequested();
    try std.testing.expect(!win32.IsZoomed(window.hwnd).toBool());
    try std.testing.expectEqual(sized, try clientRect(window.hwnd));

    // And so is a snapped one (IsWindowArranged).
    _ = win32.SetWindowPos(window.hwnd, null, 0, 0, 500, 400, resized);
    app.is_window_arranged = struct {
        fn f(_: win32.HWND) callconv(.winapi) win32.BOOL {
            return .TRUE;
        }
    }.f;
    try std.testing.expect(try app.performAction(target, .reset_window_size, {}));
    app.createRequested();
    try std.testing.expectEqual(sized, try clientRect(window.hwnd));
    app.is_window_arranged = null;

    // Not for a window covering its monitor.
    window.toggleFullscreen();
    try std.testing.expect(!try app.performAction(target, .reset_window_size, {}));
    window.toggleFullscreen();

    // With `maximize`, maximized.
    app.config.maximize = true;
    try std.testing.expect(try app.performAction(target, .reset_window_size, {}));
    app.createRequested();
    try std.testing.expect(win32.IsZoomed(window.hwnd).toBool());

    // A closing terminal drops its own.
    try std.testing.expect(try app.performAction(target, .reset_window_size, {}));
    app.forgetClosing(&pane.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
}

test "win32: copy_title_to_clipboard copies the terminal's title, if it has one" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;
    const target: apprt.Target = .{ .surface = &pane.core_surface };

    // Put back whatever text the clipboard held, as the clipboard's own
    // test does.
    const readClipboardText = @import("clipboard.zig").readClipboardText;
    const saved = try readClipboardText(alloc, pane.hwnd);
    defer if (saved) |text| {
        writeClipboardText(pane.hwnd, text) catch {};
        alloc.free(text);
    };
    try writeClipboardText(pane.hwnd, "before");

    // None yet, then an empty one: no effect.
    try std.testing.expect(!try app.performAction(target, .copy_title_to_clipboard, {}));
    _ = pane.setTitle("");
    try std.testing.expect(!try app.performAction(target, .copy_title_to_clipboard, {}));
    {
        const text = (try readClipboardText(alloc, pane.hwnd)) orelse return error.TestUnexpectedResult;
        defer alloc.free(text);
        try std.testing.expectEqualStrings("before", text);
    }

    _ = pane.setTitle("vim café");
    try std.testing.expect(try app.performAction(target, .copy_title_to_clipboard, {}));
    const text = (try readClipboardText(alloc, pane.hwnd)) orelse return error.TestUnexpectedResult;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("vim café", text);
}

test "win32: toggle_window_decorations waits for run and takes the caption off or puts it back" {
    // The client area changes with the caption and the terminals are laid
    // out again, so the toggle is recorded and made by createRequested. As
    // on GTK a window keeps a setting of its own: the first toggle takes
    // the other one, the next goes back to `window-decoration`.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    window.focused = pane;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const target: apprt.Target = .{ .surface = &pane.core_surface };
    const placed = try windowRect(window.hwnd);

    // Recorded, not made; then the caption comes off, the window keeps its
    // rect, and the terminal fills the larger client area.
    try std.testing.expect(try app.performAction(target, .toggle_window_decorations, {}));
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(captioned(window.hwnd));
    const framed = try clientRect(window.hwnd);
    app.createRequested();
    try std.testing.expect(!captioned(window.hwnd));
    try std.testing.expectEqual(placed, try windowRect(window.hwnd));
    try std.testing.expect((try clientRect(window.hwnd)).bottom > framed.bottom);
    try std.testing.expectEqual(try clientRect(window.hwnd), try clientRect(pane.hwnd));

    // Leaving fullscreen keeps it so; and a toggle while it covers the
    // monitor changes nothing there, but shows when it leaves.
    window.toggleFullscreen();
    window.toggleFullscreen();
    try std.testing.expect(!captioned(window.hwnd));
    window.toggleFullscreen();
    window.toggleDecorations();
    try std.testing.expect(!captioned(window.hwnd));
    window.toggleFullscreen();
    try std.testing.expect(captioned(window.hwnd));
    try std.testing.expectEqual(null, window.decoration);

    // With `none` from a new configuration, which `run` applies, the
    // caption comes off; then a toggle puts it back.
    var none: Config = try .default(alloc);
    defer none.deinit();
    none.@"window-decoration" = .none;
    try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &none }));
    try std.testing.expect(captioned(window.hwnd));
    app.createRequested();
    try std.testing.expect(!captioned(window.hwnd));
    try std.testing.expect(try app.performAction(target, .toggle_window_decorations, {}));
    app.createRequested();
    try std.testing.expect(captioned(window.hwnd));

    // A closing terminal drops its own.
    try std.testing.expect(try app.performAction(target, .toggle_window_decorations, {}));
    app.forgetClosing(&pane.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
}

test "win32: a window without decorations is made without its caption" {
    // CreateWindowExW gives a frame its caption whatever style it asks for,
    // and the terminal is created at the frame's client area, so the caption
    // comes off before anything measures it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    app.config.@"window-decoration" = .none;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    try std.testing.expect(!captioned(window.hwnd));
    const thick: isize = win32.WS_THICKFRAME;
    try std.testing.expectEqual(thick, win32.GetWindowLongPtrW(window.hwnd, win32.GWL_STYLE) & thick);

    // The client area is the window less its sizing border, the same all
    // round, with no caption's height on top.
    const outer = try windowRect(window.hwnd);
    const client = try clientRect(window.hwnd);
    const border = @divExact((outer.right - outer.left) - client.right, 2);
    try std.testing.expectEqual((outer.bottom - outer.top) - 2 * border, client.bottom);
}

test "win32: a window without decorations maximizes to the work area" {
    // Windows maximizes a frame with no caption over its whole monitor,
    // the taskbar's place included. A framed window of the same class,
    // maximized by Windows, is the reference.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const reference = try testFrame(&app);
    _ = win32.ShowWindow(reference.hwnd, win32.SW_SHOWMAXIMIZED);
    const framed = try windowRect(reference.hwnd);
    const window = try testFrame(&app);
    window.toggleDecorations();
    try std.testing.expect(!captioned(window.hwnd));

    const info = try monitorOf(window.hwnd);
    const work = info.rcWork;
    const clientOnScreen = struct {
        fn f(hwnd: win32.HWND) !win32.RECT {
            const client = try clientRect(hwnd);
            var origin: win32.POINT = .{ .x = 0, .y = 0 };
            if (!win32.ScreenToClient(hwnd, &origin).toBool()) return error.TestUnexpectedResult;
            return .{
                .left = -origin.x,
                .top = -origin.y,
                .right = client.right - origin.x,
                .bottom = client.bottom - origin.y,
            };
        }
    }.f;

    // Maximized, its client area is the work area; and so restored from
    // minimized, as from the taskbar, and back from fullscreen.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMAXIMIZED);
    try std.testing.expectEqual(work, try clientOnScreen(window.hwnd));
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMINNOACTIVE);
    _ = win32.SendMessageW(window.hwnd, win32.WM_SYSCOMMAND, win32.SC_RESTORE, 0);
    try std.testing.expect(win32.IsZoomed(window.hwnd).toBool());
    try std.testing.expectEqual(work, try clientOnScreen(window.hwnd));
    window.toggleFullscreen();
    window.toggleFullscreen();
    try std.testing.expect(win32.IsZoomed(window.hwnd).toBool());
    try std.testing.expectEqual(work, try clientOnScreen(window.hwnd));

    // Given its caption while maximized, it takes the reference's rect;
    // without it again, the work area again.
    window.toggleDecorations();
    try std.testing.expect(captioned(window.hwnd));
    try std.testing.expectEqual(framed, try windowRect(window.hwnd));
    window.toggleDecorations();
    try std.testing.expectEqual(work, try clientOnScreen(window.hwnd));

    // Toggled while it covers the monitor, each way: the same, once it
    // leaves.
    window.toggleFullscreen();
    window.toggleDecorations();
    window.toggleFullscreen();
    try std.testing.expect(captioned(window.hwnd));
    try std.testing.expectEqual(framed, try windowRect(window.hwnd));
    window.toggleFullscreen();
    window.toggleDecorations();
    window.toggleFullscreen();
    try std.testing.expect(!captioned(window.hwnd));
    try std.testing.expectEqual(work, try clientOnScreen(window.hwnd));

    // With no taskbar, or one that hides itself, the work area is the
    // whole monitor, which such a frame's client area covers maximized
    // whether it is kept to the work area or not.
    if (std.meta.eql(work, info.rcMonitor)) return error.SkipZigTest;
}

/// For tests: a stand-in for the taskbar's object, which keeps what a
/// button would show.
const TestTaskbar = struct {
    list: taskbar.ITaskbarList3 = .{ .vtable = &vtable },
    hwnd: ?win32.HWND = null,
    state: taskbar.State = .none,
    /// Out of 100, while the state shows one.
    value: ?u64 = null,
    calls: usize = 0,
    /// Every state set, in order.
    states: [32]taskbar.State = undefined,
    states_len: usize = 0,

    const vtable = vtable: {
        var v: taskbar.ITaskbarList3.VTable = undefined;
        const info = @typeInfo(taskbar.ITaskbarList3.VTable).@"struct";
        for (info.field_names, info.field_types) |name, T| {
            if (T == *const anyopaque) @field(v, name) = @ptrCast(&unused);
        }
        v.Release = release;
        v.HrInit = hrInit;
        v.SetProgressValue = setProgressValue;
        v.SetProgressState = setProgressState;
        break :vtable v;
    };

    fn unused() callconv(.winapi) void {
        unreachable;
    }

    fn release(_: *taskbar.ITaskbarList3) callconv(.winapi) std.os.windows.ULONG {
        return 1;
    }

    fn hrInit(_: *taskbar.ITaskbarList3) callconv(.winapi) win32.HRESULT {
        return 0;
    }

    fn setProgressState(list: *taskbar.ITaskbarList3, hwnd: win32.HWND, state: taskbar.State) callconv(.winapi) win32.HRESULT {
        const self: *TestTaskbar = @fieldParentPtr("list", list);
        self.calls += 1;
        self.hwnd = hwnd;
        self.state = state;
        if (!state.filled()) self.value = null;
        self.states[self.states_len] = state;
        self.states_len += 1;
        return 0;
    }

    fn setProgressValue(list: *taskbar.ITaskbarList3, hwnd: win32.HWND, done: u64, total: u64) callconv(.winapi) win32.HRESULT {
        const self: *TestTaskbar = @fieldParentPtr("list", list);
        self.calls += 1;
        self.hwnd = hwnd;
        self.value = done * 100 / total;
        return 0;
    }
};

test "win32: progress_report shows the focused terminal's progress on the taskbar button" {
    // Only once Explorer says the button exists, as ITaskbarList3 asks, and
    // only the focused terminal's, as Windows Terminal shows its focused
    // pane's.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    // A number of this test's own: Explorer's real one could reach a
    // frame another test shows.
    var fake: TestTaskbar = .{};
    app.taskbar_list = &fake.list;
    app.taskbar_created = win32.WM_APP + 0x100;

    const window = try testFrame(&app);
    const left = try testPane(&app, window);
    const right = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ left, right });
    window.focused = left;
    const report = struct {
        fn f(a: *App, pane: *Surface, value: terminal.osc.Command.ProgressReport) !void {
            try std.testing.expect(try a.performAction(.{ .surface = &pane.core_surface }, .progress_report, value));
        }
    }.f;

    // Kept before the button exists, and shown once it does.
    try report(&app, left, .{ .state = .set, .progress = 40 });
    try std.testing.expectEqual(0, fake.calls);
    _ = win32.SendMessageW(window.hwnd, app.taskbar_created, 0, 0);
    try std.testing.expectEqual(@as(?win32.HWND, window.hwnd), fake.hwnd);
    try std.testing.expectEqual(.normal, fake.state);
    try std.testing.expectEqual(40, fake.value.?);

    // Another terminal's is shown once it has the focus: an error it
    // reported with no value, shown full; then the first one's again.
    const calls = fake.calls;
    try report(&app, right, .{ .state = .@"error" });
    try std.testing.expectEqual(calls, fake.calls);
    _ = Surface.wndProc(right.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expectEqual(.@"error", fake.state);
    try std.testing.expectEqual(100, fake.value.?);
    _ = Surface.wndProc(left.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expectEqual(.normal, fake.state);
    try std.testing.expectEqual(40, fake.value.?);

    // Not for the app.
    try std.testing.expect(!try app.performAction(.app, .progress_report, .{ .state = .set, .progress = 1 }));

    // A report lapses once it is 15 seconds old, not at a WM_TIMER that
    // was queued before it.
    const timer = @import("Surface.zig").progress_timer_id;
    _ = Surface.wndProc(left.hwnd, win32.WM_TIMER, timer, 0);
    try std.testing.expectEqual(.normal, fake.state);
    left.progress_expires = 0;
    _ = Surface.wndProc(left.hwnd, win32.WM_TIMER, timer, 0);
    try std.testing.expectEqual(.none, fake.state);
    try std.testing.expectEqual(taskbar.Progress{}, left.progress);

    // From an error or a pause to the indeterminate state, none comes
    // first, as Windows Terminal sets it, or the button keeps the old bar;
    // also when the focus moves from a paused terminal to such a one.
    try report(&app, left, .{ .state = .@"error", .progress = 50 });
    fake.states_len = 0;
    try report(&app, left, .{ .state = .indeterminate });
    try std.testing.expectEqualSlices(taskbar.State, &.{ .none, .indeterminate }, fake.states[0..fake.states_len]);
    try report(&app, right, .{ .state = .pause, .progress = 30 });
    _ = Surface.wndProc(right.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expectEqual(.paused, fake.state);
    fake.states_len = 0;
    _ = Surface.wndProc(left.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expectEqualSlices(taskbar.State, &.{ .none, .indeterminate }, fake.states[0..fake.states_len]);

    // Each window shows its own focused terminal's, which need not have
    // the keyboard focus: that is in the first window.
    const other = try testFrame(&app);
    const pane = try testPane(&app, other);
    other.tree = try .init(alloc, pane);
    other.focused = pane;
    _ = win32.SendMessageW(other.hwnd, app.taskbar_created, 0, 0);
    try report(&app, pane, .{ .state = .set, .progress = 70 });
    try std.testing.expect(!pane.focused);
    try std.testing.expectEqual(@as(?win32.HWND, other.hwnd), fake.hwnd);
    try std.testing.expectEqual(.normal, fake.state);
    try std.testing.expectEqual(70, fake.value.?);

    // Explorer restarted, and says the first window's button exists again:
    // it shows its progress again.
    fake.hwnd = null;
    fake.state = .none;
    _ = win32.SendMessageW(window.hwnd, app.taskbar_created, 0, 0);
    try std.testing.expectEqual(@as(?win32.HWND, window.hwnd), fake.hwnd);
    try std.testing.expectEqual(.indeterminate, fake.state);

    // With progress-style = false a report removes what was shown.
    try report(&app, left, .{ .state = .pause, .progress = 30 });
    try std.testing.expectEqual(.paused, fake.state);
    try std.testing.expectEqual(30, fake.value.?);
    app.config.@"progress-style" = false;
    try report(&app, left, .{ .state = .set, .progress = 50 });
    try std.testing.expectEqual(.none, fake.state);
}

test "win32: desktop_notification shows a toast for its terminal, which a click goes back to" {
    // As on macOS and GTK: a toast is in its terminal's group, which goes
    // when the terminal gains the focus or closes, and one shown while it
    // has the focus goes after three seconds (DesktopNotifications); a
    // click brings its terminal forward with the focus.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    var fake: toast.TestNotifier = .{};
    app.notifier = fake.notifier();

    const window = try testFrame(&app);
    const left = try testPane(&app, window);
    const right = try testPane(&app, window);
    window.tree = try testRow(alloc, &.{ left, right });
    _ = Surface.wndProc(left.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(left.setTitle("vim"));
    const notify = struct {
        fn f(a: *App, pane: *Surface, title: [:0]const u8) !void {
            try std.testing.expect(try a.performAction(
                .{ .surface = &pane.core_surface },
                .desktop_notification,
                .{ .title = title, .body = "done" },
            ));
        }
    }.f;

    // For a terminal without the focus: in its group, with no title of
    // its own to show under it, kept.
    try notify(&app, right, "build");
    try std.testing.expectEqual(1, fake.shown_len);
    try std.testing.expectEqual(right.notifications.id, fake.shown[0].group);
    try std.testing.expectEqual(null, fake.shown[0].attribution);
    try std.testing.expectEqual(0, right.notifications.expiring.items.len);

    // For the focused one: its title under it, and removed once three
    // seconds have passed, not at a WM_TIMER that comes before.
    try notify(&app, left, "test");
    try std.testing.expectEqual(left.notifications.id, fake.shown[1].group);
    try std.testing.expectEqualStrings("vim", fake.shown[1].attribution orelse "");
    try std.testing.expect(fake.shown[1].tag != fake.shown[0].tag);
    const timer = @import("desktop_notifications.zig").timer_id;
    _ = Surface.wndProc(left.hwnd, win32.WM_TIMER, timer, 0);
    try std.testing.expectEqual(0, fake.removed_len);
    try std.testing.expectEqual(1, left.notifications.expiring.items.len);
    left.notifications.expiring.items[0].at = 0;
    _ = Surface.wndProc(left.hwnd, win32.WM_TIMER, timer, 0);
    try std.testing.expectEqual(1, fake.removed_len);
    try std.testing.expectEqual([2]u64{ left.notifications.id, fake.shown[1].tag }, fake.removed[0]);

    // Gaining the focus removes a terminal's, once.
    _ = Surface.wndProc(right.hwnd, win32.WM_SETFOCUS, 0, 0);
    _ = Surface.wndProc(right.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expectEqual(1, fake.removed_groups_len);
    try std.testing.expectEqual(right.notifications.id, fake.removed_groups[0]);

    // A click on the first one's, as Windows reports it: the handler posts
    // it to the app's window, whose procedure gives that terminal the focus
    // and brings its frame to the front, shown as a real one is. One for a
    // terminal that is gone changes nothing.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    _ = win32.SetWindowLongPtrW(app.msg_hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(&app)));
    const handler = try toast.Activated.create(app.msg_hwnd, WM_GHOSTTY_NOTIFICATION, left.notifications.id);
    _ = handler.vtable.Invoke(handler, null, null);
    _ = handler.vtable.Release(handler);
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        app.msg_hwnd,
        WM_GHOSTTY_NOTIFICATION,
        WM_GHOSTTY_NOTIFICATION,
        win32.PM_REMOVE,
    ).toBool());
    _ = App.wndProc(app.msg_hwnd, msg.message, msg.wParam, msg.lParam);
    try std.testing.expectEqual(left, window.focused.?);
    const click = struct {
        fn f(a: *App, group: u64) void {
            const m = toast.groupMessage(group);
            _ = App.wndProc(a.msg_hwnd, WM_GHOSTTY_NOTIFICATION, m[0], m[1]);
        }
    }.f;
    click(&app, 12345);
    try std.testing.expectEqual(left, window.focused.?);

    // Not for a terminal that is closing, nor one in a window closing,
    // nor while the app quits.
    right.closing = true;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.focused.?);
    right.closing = false;
    window.closing = true;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.focused.?);
    window.closing = false;
    app.terminating = true;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.focused.?);
    app.terminating = false;

    // Under a prompt, where the focus may not move, `run` makes it later.
    app.prompt_depth = 1;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.focused.?);
    app.prompt_depth = 0;
    app.applyPendingClick();
    try std.testing.expectEqual(right, window.focused.?);

    // A zoom that hides the terminal ends first.
    window.tree.zoom(window.tree.locate(right).?);
    window.relayout();
    click(&app, left.notifications.id);
    try std.testing.expectEqual(left, window.focused.?);
    try std.testing.expectEqual(null, window.tree.zoomed);

    // Closing removes a terminal's.
    try notify(&app, left, "again");
    const removed = fake.removed_groups_len;
    const left_id = left.notifications.id;
    try std.testing.expect(left.destroy());
    try std.testing.expectEqual(removed + 1, fake.removed_groups_len);
    try std.testing.expectEqual(left_id, fake.removed_groups[removed]);

    // The app's own: no terminal's group.
    try std.testing.expect(try app.performAction(.app, .desktop_notification, .{ .title = "", .body = "app" }));
    try std.testing.expectEqual(0, fake.shown[fake.shown_len - 1].group);
}

test "win32: float_window keeps a window on top, or puts it back" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const pane = try testPane(&app, window);
    window.tree = try .init(alloc, pane);
    const target: apprt.Target = .{ .surface = &pane.core_surface };

    // It is made at once, inside the core's key callback, so neither the
    // window, shown as one that floats is, nor its terminal may hear of a
    // size or a focus change: only its place in the z-order changes.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const Seen = struct {
        var count: usize = 0;
        fn proc(code: c_int, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
            if (code >= 0) {
                const sent: *const win32.CWPSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                switch (sent.message) {
                    win32.WM_SIZE, win32.WM_ACTIVATE, win32.WM_SETFOCUS, win32.WM_KILLFOCUS => count += 1,
                    else => {},
                }
            }
            return win32.CallNextHookEx(null, code, wparam, lparam);
        }
    };
    const hook = win32.SetWindowsHookExW(
        win32.WH_CALLWNDPROC,
        Seen.proc,
        null,
        std.os.windows.GetCurrentThreadId(),
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.UnhookWindowsHookEx(hook);

    try std.testing.expect(!window.isFloating());
    for ([_]struct { apprt.action.FloatWindow, bool }{
        .{ .toggle, true },
        .{ .toggle, false },
        .{ .on, true },
        .{ .on, true },
        .{ .off, false },
        .{ .off, false },
    }) |c| {
        try std.testing.expect(try app.performAction(target, .float_window, c[0]));
        try std.testing.expectEqual(c[1], window.isFloating());
    }
    try std.testing.expectEqual(0, Seen.count);
    // The hook does see a change of size.
    _ = win32.SetWindowPos(window.hwnd, null, 0, 0, 300, 150, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    try std.testing.expect(Seen.count > 0);

    // Covering the monitor and coming back keeps it floating.
    try std.testing.expect(try app.performAction(target, .float_window, .on));
    window.focused = pane;
    window.toggleFullscreen();
    try std.testing.expect(window.isFloating());
    window.toggleFullscreen();
    try std.testing.expect(window.isFloating());
}
