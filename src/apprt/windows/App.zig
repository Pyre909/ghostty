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
const confirm = @import("dialog.zig").confirm;
const fatalNotice = @import("dialog.zig").fatalNotice;
const notice = @import("dialog.zig").notice;

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

    /// A message-only window. It is the target for `wakeup` and for the quit
    /// timer. Using a window rather than `PostThreadMessageW` is deliberate:
    /// thread messages are silently dropped by the nested modal loops that
    /// Win32 runs during window drags, menus and dialogs, so a wakeup could be
    /// lost exactly when the mailbox needs draining.
    msg_hwnd: win32.HWND,

    /// The windows this runtime owns. See `surfaceDestroyed` for the
    /// ownership invariant. Each one whose `CoreSurface` is initialized is
    /// also registered with `CoreApp.addSurface`, which is what drives the
    /// quit timer; this list and the core's can differ only while a surface
    /// is being created or torn down.
    surfaces: std.ArrayListUnmanaged(*Surface),

    /// Windows the core asked for (`.new_window`) that `run` has not
    /// created yet, oldest first, each with the core surface that asked,
    /// if any.
    ///
    /// The core asks from inside its own frames: a `new_window` binding
    /// performs the action from `CoreSurface.keyCallback`
    /// (`performBindingAction` -> `CoreApp.newWindow`). Creating the window
    /// there would register a surface with the core in the middle of that
    /// frame and send the new window's activation, and the old window's
    /// WM_KILLFOCUS, into a surface whose key callback is still on the
    /// stack. So the action only records the request, and `run` creates
    /// the window after its tick (`createRequestedWindows`).
    ///
    /// A parent is always live: a surface clears its own entries when its
    /// teardown starts (`forgetWindowParent`), before its address can be
    /// reused.
    window_requests: std.ArrayListUnmanaged(?*CoreSurface),

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
    /// this is non-zero, and `run` re-posts it: teardowns run one after
    /// another, never one inside another's wait.
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
            .msg_hwnd = msg_hwnd,
            .surfaces = .empty,
            .window_requests = .empty,
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
        // Every remaining surface is destroyed as destroyPosted does it
        // (Surface.destroy), so that CoreApp.deinit, which `main` runs after
        // this, finds an empty surface list and its
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
        // Each destroy removes and frees the surface (WM_DESTROY ->
        // surfaceDestroyed). A window that could not be destroyed gets no
        // WM_DESTROY, so it is released here the same way, or this loop
        // would not end.
        while (self.surfaces.getLastOrNull()) |surface| {
            if (!surface.destroy()) {
                log.err("failed to destroy a surface window err={}", .{
                    win32.GetLastError(),
                });
                self.surfaceDestroyed(surface);
            }
        }
        self.surfaces.deinit(self.core_app.alloc);

        // Windows asked for and never created: the process is quitting.
        self.window_requests.deinit(self.core_app.alloc);

        self.stopQuitTimer();

        _ = win32.DestroyWindow(self.msg_hwnd);
        unregisterClasses(self.hinstance);
        self.config.deinit();
    }

    /// The Win32 message loop.
    pub fn run(self: *App) !void {
        // Create the initial window, directly rather than through
        // `window_requests`: nothing would make the loop below come round
        // to a request before some message arrived. Failing here is
        // fatal, as no window would exist; failing to open a later one is
        // only reported (`createRequestedWindows`).
        if (self.config.@"initial-window") {
            _ = self.newWindow(null) catch |err| {
                log.err("failed to create the initial window err={}", .{err});
                fatalNotice(err);
                return err;
            };
        }

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
            switch (@intFromEnum(ret)) {
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

            // And the windows the core asked for (`window_requests`).
            self.createRequestedWindows();
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

    /// Enter a modal prompt (`dialog.confirm`, `dialog.notice`) owned by
    /// `owner`, or by no window.
    ///
    /// No surface can be used while a prompt is open: ticks stop
    /// (`canReenterCore`), so every window's output pauses, and input does
    /// not reach the core. MessageBoxW disables only its owner, though, so
    /// the outermost prompt disables every other surface window as well,
    /// and `endPrompt` enables them again. A window that was already
    /// disabled is left as it was.
    ///
    /// Surfaces are not created while a prompt is open (only `run` creates
    /// them) and their teardown is deferred, so `endPrompt` finds the
    /// windows disabled here.
    pub fn beginPrompt(self: *App, owner: ?win32.HWND) void {
        self.prompt_depth += 1;
        if (self.prompt_depth > 1) return;
        for (self.surfaces.items) |surface| {
            if (owner != null and surface.hwnd == owner.?) continue;
            if (win32.EnableWindow(surface.hwnd, .FALSE).toBool()) continue;
            surface.prompt_disabled = true;
        }
    }

    /// The window a prompt belongs to: `hwnd`, or for a caller that has
    /// none, the surface window the user was last in, else the first one.
    /// With no owner, the box would leave every window disabled
    /// (`beginPrompt`) and the activation would go to another application
    /// when it closes; MessageBoxW enables its owner again before it
    /// returns and hands the activation back to it.
    pub fn promptOwner(self: *const App, hwnd: ?win32.HWND) ?win32.HWND {
        if (hwnd) |h| return h;
        if (self.core_app.focusedSurface()) |s| return s.rt_surface.hwnd;
        if (self.surfaces.items.len > 0) return self.surfaces.items[0].hwnd;
        return null;
    }

    /// Leave the prompt entered by the matching `beginPrompt`.
    pub fn endPrompt(self: *App) void {
        self.prompt_depth -= 1;
        if (self.prompt_depth > 0) return;
        for (self.surfaces.items) |surface| {
            if (!surface.prompt_disabled) continue;
            surface.prompt_disabled = false;
            _ = win32.EnableWindow(surface.hwnd, .TRUE);
        }
    }

    /// Re-post WM_GHOSTTY_DESTROY for every surface whose teardown was
    /// deferred. Called where `canReenterCore` holds and no teardown runs:
    /// by `run`, and by `Surface.destroyPosted` once its teardown is done.
    pub fn repostDeferredDestroys(self: *App) void {
        for (self.surfaces.items) |surface| {
            if (!surface.destroy_deferred) continue;
            surface.destroy_deferred = false;
            surface.postDestroy();
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
            .present_terminal => presentTerminal(target),
            .toggle_maximize => toggleMaximize(target),
            .render => render(target),
            .mouse_visibility => mouseVisibility(target, value),
            .mouse_shape => mouseShape(target, value),
            .open_url => openUrl(target, value),
            .initial_size => initialSize(target, value),

            .ring_bell => ring_bell: {
                _ = win32.MessageBeep(win32.MB_ICONASTERISK);
                break :ring_bell true;
            },

            .new_window => self.requestWindow(target),

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

        if (self.core_app.needsConfirmQuit()) {
            const owner: ?win32.HWND = if (self.core_app.focusedSurface()) |s|
                s.rt_surface.hwnd
            else
                null;
            if (!confirm(
                self,
                owner,
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
            // it. Surface.close confirms if needed and posts the teardown, so
            // every close path -- the title bar button, Alt+F4 (a default
            // binding to this action, `Config.Keybinds.init`) and a
            // child exit -- converges on Surface.destroyPosted.
            //
            // `true` means the request was handled. The user may still decline
            // the confirmation; that is a completed close request, not an
            // unsupported action.
            .surface => |v| close: {
                v.rt_surface.close(v.needsConfirmQuit());
                break :close true;
            },
        };
    }

    fn presentTerminal(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.present(),
        };
    }

    /// Records the size `window-width`/`window-height` ask for. The core
    /// sends it from CoreSurface.init and again whenever the cell size
    /// changes (`Surface.recomputeInitialSize`); `Surface.create` applies it
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

    fn toggleMaximize(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| maximize: {
                const surface = v.rt_surface;
                surface.maximized = !surface.maximized;
                // ShowWindow's BOOL is the window's *previous* visibility, not
                // whether the call succeeded, so it deliberately is not
                // propagated: a window that was hidden returns zero from a
                // call that worked perfectly.
                _ = win32.ShowWindow(
                    surface.hwnd,
                    if (surface.maximized) win32.SW_MAXIMIZE else win32.SW_RESTORE,
                );
                break :maximize true;
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
    /// this frame has returned, and ShellExecuteW, which blocks until the
    /// handler has started and may dispatch messages while it waits, runs
    /// on its own thread, as the core's opener does (src/os/open.zig).
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

        const wide = std.unicode.utf8ToUtf16LeAllocZ(open_url_alloc, value.url) catch |err| {
            log.warn("open url: cannot convert the target err={}", .{err});
            return false;
        };
        const thread = std.Thread.spawn(.{}, openUrlThread, .{wide}) catch |err| {
            open_url_alloc.free(wide);
            log.warn("open url: cannot start the opener thread err={}", .{err});
            return false;
        };
        thread.detach();
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
                // `quit-after-last-window-closed` is `builtin.os.tag == .linux`
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

    /// `.new_window`: record the request for `run` (see `window_requests`).
    /// `true` once it is recorded: the window is then created, or its
    /// failure reported to the user, as soon as the core frame that asked
    /// has returned, unless the app quits first.
    fn requestWindow(self: *App, target: apprt.Target) bool {
        const parent: ?*CoreSurface = switch (target) {
            .app => null,
            .surface => |v| v,
        };
        self.window_requests.append(self.core_app.alloc, parent) catch |err| {
            log.warn("cannot record a new window request err={}", .{err});
            return false;
        };
        return true;
    }

    /// Forget `core_surface` as the parent of the windows it asked for: it
    /// is closing. Called by `Surface.stopCore` while the address is still
    /// that surface's, so that a surface created later at the same address
    /// cannot pass for the parent.
    pub fn forgetWindowParent(self: *App, core_surface: *CoreSurface) void {
        for (self.window_requests.items) |*parent| {
            const p = parent.* orelse continue;
            if (p == core_surface) parent.* = null;
        }
    }

    /// Create the windows in `window_requests`, oldest first. Called by
    /// `run`, where `canReenterCore` holds and no teardown is running.
    fn createRequestedWindows(self: *App) void {
        // A window opened now would only be torn down again by `terminate`.
        if (self.quit) return;

        // By index, reading the length again each time round: the notice for
        // a failure runs a message loop, and a request added meanwhile is
        // still created here.
        defer self.window_requests.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.window_requests.items.len) : (i += 1) {
            const parent = self.window_requests.items[i];
            _ = self.newWindow(parent) catch |err| {
                log.err("failed to create a window err={}", .{err});
                notice(
                    self,
                    if (parent) |p| p.rt_surface.hwnd else null,
                    L("Ghostty could not open a new window."),
                );
            };
        }
    }

    /// Create a terminal window: the initial one (`run`), or one the core
    /// asked for (`createRequestedWindows`) from `parent`, a live surface.
    fn newWindow(self: *App, parent: ?*CoreSurface) !*Surface {
        const alloc = self.core_app.alloc;
        try self.surfaces.ensureUnusedCapacity(alloc, 1);

        // Surface.create registers the surface with the core, and
        // CoreApp.addSurface cancels the startup quit timer
        // itself, so there is no quit-timer handling here.
        // Taken from the asking surface itself (see Surface.Options).
        const cwd: ?[]const u8 = cwd: {
            const p = parent orelse break :cwd null;
            if (!apprt.surface.shouldInheritWorkingDirectory(.window, &self.config)) break :cwd null;
            break :cwd p.pwd(alloc) catch null;
        };
        defer if (cwd) |v| alloc.free(v);

        const surface = try Surface.create(self, .{
            .font_size = font_size: {
                const p = parent orelse break :font_size null;
                if (!self.config.@"window-inherit-font-size") break :font_size null;
                break :font_size p.font_size.points;
            },
            .working_directory = cwd,
        });
        errdefer comptime unreachable;
        self.surfaces.appendAssumeCapacity(surface);

        return surface;
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
        const idx = idx: {
            for (self.surfaces.items, 0..) |s, i| {
                if (s == surface) break :idx i;
            }
            return;
        };

        // The HWND outlives its Surface by one message: WM_NCDESTROY is
        // still to come. Clear the back-pointer so wndProc's `v == 0` guard
        // catches it instead of forming a *Surface into freed memory.
        _ = win32.SetWindowLongPtrW(surface.hwnd, win32.GWLP_USERDATA, 0);

        _ = self.surfaces.swapRemove(idx);
        surface.deinit();
        self.core_app.alloc.destroy(surface);

        // The quit timer is not handled here: CoreApp.deleteSurface, which
        // Surface.stopCore calls before the window is destroyed, starts it
        // when the core's last surface goes (`CoreApp.deleteSurface`).
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

/// ID_ICON_GHOSTTY in dist/windows/ghostty.rc, which the exe links.
const icon_resource_id = 1;

fn registerClasses(hinstance: win32.HINSTANCE) !void {
    const arrow = win32.LoadCursorW(null, win32.IDC_ARROW);

    // The exe's own icon for the caption and Alt+Tab. LoadIconW returns a
    // shared icon, so nothing destroys it. With hIconSm null the system
    // picks the small size from the same resource (WNDCLASSEXW docs); if
    // the load fails both stay null and the system default is used.
    const icon = win32.LoadIconW(hinstance, @ptrFromInt(icon_resource_id));

    const surface_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        // No CS_HREDRAW or CS_VREDRAW: nothing here draws through GDI, and
        // WM_SIZE already queues the frame for the new size. They would
        // invalidate the whole window on every resize step, shrinks
        // included, and each resulting WM_PAINT wakes the renderer for
        // another frame of the same size.
        .style = 0,
        .lpfnWndProc = &Surface.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = icon,
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
}

/// The allocator of the link `openUrl` hands to its opener thread, which
/// frees it. ShellExecuteW blocks until the handler has started, which can
/// be a cold browser start or the shell's app picker, and the detached
/// thread can outlive App.terminate and global.deinit, which deinitializes
/// the debug allocator. So the link is allocated with an allocator of the
/// process rather than `core_app.alloc`, as no allocator of the app is
/// known to outlive the thread.
const open_url_alloc = std.heap.smp_allocator;

/// Opens `wide` with the shell, then frees it. COM is initialized for the
/// thread first, as ShellExecuteW documents: a shell extension it delegates
/// to may need a single-threaded apartment.
fn openUrlThread(wide: [:0]u16) void {
    defer open_url_alloc.free(wide);
    const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) win32.CoUninitialize();
    const rc = win32.ShellExecuteW(null, L("open"), wide.ptr, null, null, win32.SW_SHOWNORMAL);
    if (rc <= 32) log.warn("ShellExecuteW failed code={}", .{rc});
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

test "win32: a prompt disables the other windows until the outermost one ends" {
    // MessageBoxW disables only its owner; the rest is beginPrompt's.
    // Hidden top-level windows stand in for the surfaces' windows.
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

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var a: Surface = undefined;
        var b: Surface = undefined;
        var c: Surface = undefined;
    };
    s.a.hwnd = owner;
    s.b.hwnd = other;
    s.c.hwnd = off;
    for ([_]*Surface{ &s.a, &s.b, &s.c }) |surface| surface.prompt_disabled = false;

    var app: App = undefined;
    app.prompt_depth = 0;
    app.surfaces = .empty;
    defer app.surfaces.deinit(std.testing.allocator);
    try app.surfaces.appendSlice(std.testing.allocator, &.{ &s.a, &s.b, &s.c });

    // Disabled by something else, so not the prompt's to enable.
    _ = win32.EnableWindow(off, .FALSE);

    app.beginPrompt(owner);
    try std.testing.expect(win32.IsWindowEnabled(owner).toBool());
    try std.testing.expect(!win32.IsWindowEnabled(other).toBool());

    // A nested prompt, here owned by no window, changes nothing, and
    // neither does its end.
    app.beginPrompt(null);
    try std.testing.expect(win32.IsWindowEnabled(owner).toBool());
    app.endPrompt();
    try std.testing.expect(!win32.IsWindowEnabled(other).toBool());

    app.endPrompt();
    try std.testing.expectEqual(0, app.prompt_depth);
    try std.testing.expect(win32.IsWindowEnabled(other).toBool());
    try std.testing.expect(!win32.IsWindowEnabled(off).toBool());
}

test "win32: a prompt with no owner belongs to the last focused window" {
    // An ownerless MessageBoxW would leave every window disabled and hand
    // the activation to another application when it closes.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.surfaces = .empty;
    defer core_app.surfaces.deinit(alloc);
    core_app.focused_surface = null;

    var app: App = undefined;
    app.core_app = &core_app;
    app.surfaces = .empty;
    defer app.surfaces.deinit(alloc);

    // Static because the struct embeds a whole CoreSurface. The handles are
    // only compared, never used as windows.
    const s = struct {
        var a: Surface = undefined;
        var b: Surface = undefined;
    };
    s.a.hwnd = @ptrFromInt(0x10);
    s.b.hwnd = @ptrFromInt(0x20);
    s.a.core_surface.rt_surface = &s.a;
    s.b.core_surface.rt_surface = &s.b;

    try std.testing.expect(app.promptOwner(null) == null);

    try app.surfaces.appendSlice(alloc, &.{ &s.a, &s.b });
    try std.testing.expectEqual(s.a.hwnd, app.promptOwner(null).?);

    try core_app.surfaces.appendSlice(alloc, &.{ &s.a, &s.b });
    core_app.focused_surface = &s.b.core_surface;
    try std.testing.expectEqual(s.b.hwnd, app.promptOwner(null).?);

    // The caller's own window always wins.
    try std.testing.expectEqual(s.a.hwnd, app.promptOwner(s.a.hwnd).?);
}

test "win32: a new window is recorded where it is asked for, and created later" {
    // A `new_window` binding performs the action from inside the core's
    // key callback, so the action only records the request; `run` creates
    // the window after its tick. A surface that starts closing in between
    // clears itself from its requests (`forgetWindowParent`, called by
    // Surface.stopCore), so a surface created later at the same address is
    // not taken for the parent.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;

    var app: App = undefined;
    app.core_app = &core_app;
    app.window_requests = .empty;
    defer app.window_requests.deinit(alloc);
    app.surfaces = .empty;

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var open: Surface = undefined;
        var closed: Surface = undefined;
    };

    for ([_]apprt.Target{
        .{ .surface = &s.open.core_surface },
        .{ .surface = &s.closed.core_surface },
        .app,
    }) |target| {
        try std.testing.expect(try app.performAction(target, .new_window, {}));
    }
    try std.testing.expectEqual(0, app.surfaces.items.len);

    app.forgetWindowParent(&s.closed.core_surface);

    try std.testing.expectEqualSlices(
        ?*CoreSurface,
        &.{ &s.open.core_surface, null, null },
        app.window_requests.items,
    );
}
