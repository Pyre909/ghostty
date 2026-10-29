const std = @import("std");
const builtin = @import("builtin");
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
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const taskbar = @import("taskbar.zig");
const TabBar = @import("TabBar.zig");
const SearchBar = @import("SearchBar.zig");
const LinkPreview = @import("LinkPreview.zig");
const Overlays = @import("Overlays.zig");
const Dividers = @import("Dividers.zig");
const KeyState = @import("KeyState.zig");
const ReadOnly = @import("ReadOnly.zig");
const ChildExited = @import("ChildExited.zig");
const TitleDialog = @import("TitleDialog.zig");
const CommandPalette = @import("CommandPalette.zig");
const ContextMenu = @import("ContextMenu.zig");
const ScrollBar = @import("ScrollBar.zig");
const overlay_keys = @import("overlay_keys.zig");
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

    /// GetDpiForWindow and GetSystemMetricsForDpi, for a terminal's scroll
    /// bar width at its window's real DPI (`ScrollBar.width`), resolved at
    /// runtime with the others (Windows 10 1607). A pointer of its own, not
    /// `get_dpi_for_window`, which tests stand in for. Null before 1607,
    /// where the width is the system DPI's.
    bar_metric: ?ScrollBar.Metric,

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

    /// The terminal whose search bar `start_search` opened or `end_search`
    /// closed last, to get the keyboard focus, or its search field, once
    /// the core frame that asked has returned (`SearchBar.start`,
    /// `applyPendingFocus`): moving the focus inside it would send
    /// WM_KILLFOCUS into a surface whose key callback is on the stack, as
    /// for `Tab.pending_focus`. One for the app: the last one asked for
    /// wins. Live when set; cleared when it begins to close
    /// (`forgetClosing`) or is freed (`surfaceDestroyed`).
    search_focus: ?*Surface,

    /// The terminal whose search bar `end_search` closed while the bar
    /// held the keyboard focus, left shown until `applyPendingFocus` has
    /// moved the focus out of it (`SearchBar.finish`). One for the app, as
    /// only one window has the focus. Live when set, as `search_focus`.
    search_hide: ?*Surface,

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

    /// Number of system modal loops (window size/move, window menu, a
    /// terminal's scroll bar) the main thread is currently inside. `run`
    /// does not get control back until such a loop ends, so while this is
    /// non-zero the wakeup handler ticks instead; see `wndProc`.
    modal_loop_depth: u32,

    /// Number of surface teardowns (`Surface.stopCore`) on the stack.
    ///
    /// A teardown pumps messages while it waits for the surface's threads
    /// (`waitForThread`), so another window's WM_GHOSTTY_DESTROY can be
    /// dispatched inside it. `Surface.destroyPosted` defers that one while
    /// this is non-zero, and `repostDeferredDestroys` posts it again:
    /// teardowns run one after another, never one inside another's wait.
    teardown_depth: u32,

    /// Number of modal loops a terminal's own message handler is running
    /// (`beginTerminalLoop`): its context menu's, from its WM_RBUTTONUP
    /// (`ContextMenu.show`), and its scroll bar's, from DefWindowProcW
    /// (`ScrollBar.loop`). Such a loop dispatches every message posted
    /// meanwhile, WM_GHOSTTY_DESTROY among them, and returns to that
    /// handler when it ends; nothing holds the terminal alive
    /// (`Surface.ref` counts nothing). While this is non-zero no teardown
    /// runs (`canTearDown`), and the ones deferred meanwhile are posted
    /// again when the last loop ends, unless something else still defers
    /// them (`endTerminalLoop`).
    ///
    /// For the app, not per terminal, as `prompt_depth` and
    /// `teardown_depth` are: the terminal is freed by its own teardown or
    /// by its window's, which stops every terminal of the window and
    /// destroys the frame that owns the menu (`Window.destroy`), and a
    /// count per terminal would have to be read by both. The cost is that
    /// every teardown waits until the loop ends, which for a menu is when
    /// the user chooses or dismisses it, and for the scroll bar when the
    /// button comes up.
    terminal_loops: u32,

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
        /// for (`configChange`), and every terminal the scroll bar it asks
        /// for (`ScrollBar.restyle`), and lay each window out again, since
        /// `window-show-tab-bar` may have changed.
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

        /// `.new_tab` for a terminal: a tab in its window (`newTab`).
        tab: *CoreSurface,

        /// `.goto_tab`: the tab to show in `from`'s window, worked out
        /// again when it is made, since tabs may have come or gone
        /// (`Window.gotoTabIndex`).
        goto_tab: struct {
            from: *CoreSurface,
            to: apprt.action.GotoTab,
            /// The index in `requests` of the move of `from`'s tab to a
            /// new window this waits behind, if it does (`dropBehind`).
            behind: ?usize = null,
        },

        /// `.move_tab` behind a tab still to open in `from`'s window, or
        /// behind a move of its tab to a new window (`moveTab`).
        move_tab: struct {
            from: *CoreSurface,
            amount: isize,
            /// As for `goto_tab`.
            behind: ?usize = null,
        },

        /// `.move_tab_to_new_window`: the tab of `from`, moved into a
        /// window of its own (`moveTabToNewWindow`); or a tab dragged out
        /// of the bar, the one `from` is the focused terminal of, with
        /// where it was dropped (`Window.dropTabOut`).
        move_tab_to_new_window: struct {
            from: *CoreSurface,
            drop: ?Window.Drop = null,
        },

        /// `.close_window` behind a move of `from`'s tab to a new window,
        /// which it then closes (`closeWindow`); dropped if the tab does
        /// not move (`dropBehind`).
        close_window: struct {
            from: *CoreSurface,
            /// The index in `requests` of that move.
            behind: usize,
        },

        /// `.close_tab` behind a move of `from`'s tab to a new window,
        /// among the tabs there (`closeTab`); dropped as `close_window` is.
        close_tab: struct {
            from: *CoreSurface,
            mode: apprt.action.CloseTabMode,
            behind: usize,
        },

        /// A binding a key in `from`'s search field, or in the command
        /// palette open for it, found while the core could not be
        /// re-entered, by the trigger it was found under, to be looked up
        /// again and performed (`overlay_keys.replay`).
        overlay_key: struct {
            from: *CoreSurface,
            trigger: input.Binding.Trigger,
            field: overlay_keys.Field = .search,
        },

        /// `.toggle_command_palette`: open the command palette over the
        /// window of `from`, or close it (`CommandPalette.toggle`).
        palette: *CoreSurface,

        /// An entry chosen in the command palette open for `from` while
        /// the core could not be re-entered, the palette already closed:
        /// its action performed on `from`, or its terminal focused
        /// (`CommandPalette.replay`). The request owns `pending`, freed
        /// when it is carried out or dropped (`freeRequest`).
        palette_run: struct {
            from: *CoreSurface,
            pending: *CommandPalette.Pending,
        },

        /// Enter, Escape or a button of `from`'s search bar while the core
        /// could not be re-entered (`SearchBar.replay`).
        search_key: struct {
            from: *CoreSurface,
            key: SearchBar.FieldKey,
        },

        /// `.prompt_title`: ask for the title of `from`, or of its tab, in
        /// a dialog over its window (`TitleDialog.open`).
        title_prompt: struct {
            from: *CoreSurface,
            target: TitleDialog.Target,
        },

        /// A click on the Close button of the child-exited banner of this
        /// surface while the core could not be re-entered: it closes as its
        /// own WM_CLOSE closes it (`Surface.requestClose`, `ChildExited`).
        close_surface: *CoreSurface,

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
        const bar_metric = ScrollBar.Metric.resolve(user32);
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
            .bar_metric = bar_metric,
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
            .search_focus = null,
            .search_hide = null,
            .quit = false,
            .quit_timer = .off,
            .ticking = false,
            .prompt_depth = 0,
            .modal_loop_depth = 0,
            .teardown_depth = 0,
            .terminal_loops = 0,
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
        self.freeRequests();

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

    /// Free `requests`, never carried out, and what they own.
    fn freeRequests(self: *App) void {
        for (self.requests.items) |*request| self.freeRequest(request);
        self.requests.deinit(self.core_app.alloc);
    }

    /// Free what `request` owns, and make it `.dropped`.
    fn freeRequest(self: *App, request: *Request) void {
        switch (request.*) {
            .palette_run => |chosen| chosen.pending.destroy(self.core_app.alloc),
            else => {},
        }
        request.* = .dropped;
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
                else => self.dispatch(&msg),
            }

            // Drain whatever else is pending so a burst (a resize drag, a
            // flood of wakeups) costs one tick rather than one per message.
            while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
                if (msg.message == win32.WM_QUIT) {
                    self.quit = true;
                    break;
                }
                self.dispatch(&msg);
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

            // And a focus move the core asked for outside a key callback,
            // and the work it asked for from inside its frames
            // (`requests`), in that order: a move is left pending only
            // while nothing is in `requests` (`gotoSplit`), so it came
            // first, and a tab shown by a request would drop it.
            self.applyPendingFocus();
            self.createRequested();

            // And a toast's click a prompt or a teardown held back.
            self.applyPendingClick();

            // And a change of color scheme: of the system's mode, which a
            // prompt may have held back, or of the configuration, which a
            // reload in `requests` may just have made.
            self.syncColorScheme();
        }
    }

    /// Dispatch a message `run` or `waitForThread` took from the queue,
    /// first offering it to an open title prompt (`dialogMessage`).
    fn dispatch(self: *App, msg: *win32.MSG) void {
        if (self.dialogMessage(msg)) return;
        _ = win32.TranslateMessage(msg);
        _ = win32.DispatchMessageW(msg);
    }

    /// Hand `msg` to IsDialogMessageW for an open title prompt, as a
    /// modeless dialog's message loop does, so that Tab moves between its
    /// controls, Enter presses OK and Escape Cancel; whether it took the
    /// message, which is then handled. Only while one is open, and only for
    /// a message to that dialog or one of its controls; a message for a
    /// terminal never reaches it. The OK and Cancel it sends run from
    /// `run`, or a teardown's wait (`waitForThread`), outside any core
    /// frame (`TitleDialog.commit`). A key-down that closed the prompt
    /// leaves its key-up to a terminal that never saw it pressed
    /// (`TitleDialog.closedByKey`).
    fn dialogMessage(self: *App, msg: *win32.MSG) bool {
        for (self.windows.items) |window| {
            const dialog = window.title_prompt.hwnd orelse continue;
            if (!win32.IsDialogMessageW(dialog, msg).toBool()) continue;
            if (window.title_prompt.hwnd == null) TitleDialog.closedByKey(window, msg);
            return true;
        }
        return false;
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
        if (builtin.is_test) if (test_tick) |seen| return seen(self);
        try self.core_app.tick(self);
    }

    /// For tests: told of each `tick`, in place of the core's, which a
    /// test's app does not have (`testApp`).
    pub var test_tick: if (builtin.is_test) ?*const fn (*App) void else void =
        if (builtin.is_test) null else {};

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
    /// Windows are not created while a prompt is open, as both places that
    /// create them wait for `canReenterCore`: `run` (`createRequested`),
    /// and a tab dropped out of a bar, from whichever loop dispatched the
    /// release (`Window.dropTabOut`); and their teardown is deferred, so
    /// `endPrompt` finds the windows disabled here. Nor are title prompts
    /// opened (`createRequested`), and an open one is disabled too, so
    /// that it takes no input either.
    ///
    /// A frame is enabled only when nothing holds it: this prompt (every
    /// frame but its owner), MessageBoxW (its owner), or the frame's title
    /// prompt (see TitleDialog.zig). A frame a title prompt holds is
    /// already disabled, so it is not marked here: the title prompt lets
    /// go of it when it closes, or leaves it to `endPrompt` if this
    /// prompt is still open then (`TitleDialog.close`). A title prompt
    /// that owns this prompt (`promptOwner`) is left to MessageBoxW, which
    /// disables its owner and enables it again with the activation as it
    /// returns; disabled here, it would be an owner MessageBoxW found
    /// disabled, and left so.
    pub fn beginPrompt(self: *App, owner: ?win32.HWND) void {
        self.prompt_depth += 1;
        if (self.prompt_depth > 1) return;
        for (self.windows.items) |window| {
            if (window.title_prompt.hwnd) |dialog| if (owner != dialog) {
                if (!win32.EnableWindow(dialog, .FALSE).toBool()) window.title_prompt.prompt_disabled = true;
            };
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
    ///
    /// A frame with a title prompt open is disabled by it, so the prompt
    /// is the owner instead: the activation then comes back to it, and the
    /// keyboard with it, rather than to a frame that cannot take it
    /// (`TitleDialog`).
    pub fn promptOwner(self: *const App, hwnd: ?win32.HWND) ?win32.HWND {
        const frame: win32.HWND = if (hwnd) |h|
            win32.GetAncestor(h, win32.GA_ROOT) orelse h
        else if (self.core_app.focusedSurface()) |s|
            s.rt_surface.window.hwnd
        else if (self.windows.items.len > 0)
            self.windows.items[0].hwnd
        else
            return null;
        for (self.windows.items) |window| {
            if (window.hwnd == frame) return window.title_prompt.hwnd orelse frame;
        }
        return frame;
    }

    /// Leave the prompt entered by the matching `beginPrompt`.
    ///
    /// The outermost one wakes `run`. The prompt's message loop dispatched
    /// the wakeups posted while it was open, with no tick (`canReenterCore`),
    /// and a prompt `run` opened outside a tick (`showConfigErrors`) has no
    /// tick after it to drain what they announced, nor to make what its
    /// answer recorded in `requests`. Inside a tick this costs one more tick.
    ///
    /// The outermost one enables the windows `beginPrompt` disabled, and
    /// the frames of title prompts that closed meanwhile; a frame whose
    /// title prompt is still open stays disabled, even if it owned the
    /// prompt and MessageBoxW enabled it on the way out, and the title
    /// prompt takes input again: enabled here if `beginPrompt` disabled
    /// it, or by MessageBoxW if it owned the prompt.
    pub fn endPrompt(self: *App) void {
        self.prompt_depth -= 1;
        if (self.prompt_depth > 0) return;
        for (self.windows.items) |window| {
            if (window.title_prompt.hwnd) |dialog| {
                window.prompt_disabled = false;
                _ = win32.EnableWindow(window.hwnd, .FALSE);
                if (window.title_prompt.prompt_disabled) {
                    window.title_prompt.prompt_disabled = false;
                    _ = win32.EnableWindow(dialog, .TRUE);
                }
                continue;
            }
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
    /// inside the last. Nor inside a modal loop a terminal's handler runs
    /// (`terminal_loops`): it would free that terminal, or its window,
    /// under the handler.
    pub fn canTearDown(self: *const App) bool {
        return self.canReenterCore() and self.teardown_depth == 0 and self.terminal_loops == 0;
    }

    /// Enter a modal loop that a terminal's message handler runs and that
    /// returns to it: no teardown runs until the matching
    /// `endTerminalLoop` (`terminal_loops`). Ticking is left alone: a loop
    /// the frame hears of, as the menu's WM_ENTERMENULOOP, is counted in
    /// `modal_loop_depth` there; one it does not, as DefWindowProcW's for
    /// a click on a scroll bar, must count itself there as well
    /// (`ScrollBar.loop`).
    pub fn beginTerminalLoop(self: *App) void {
        self.terminal_loops += 1;
    }

    /// Leave the loop entered by the matching `beginTerminalLoop`. When the
    /// last one has ended, the teardowns deferred meanwhile are posted again
    /// (`repostDeferredDestroys`), if one may run now (`canTearDown`); else
    /// whatever defers them posts them again later. Only posted, so that
    /// none runs inside this call.
    pub fn endTerminalLoop(self: *App) void {
        self.terminal_loops -= 1;
        if (self.terminal_loops == 0 and self.canTearDown()) self.repostDeferredDestroys();
    }

    /// Re-post WM_GHOSTTY_DESTROY for every terminal and every window whose
    /// teardown was deferred. Called where `canTearDown` holds: by `run`,
    /// by `Surface.destroyPosted` and `Window.destroyPosted` once their own
    /// teardown is done, and by `endTerminalLoop`.
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
                        // Through an open title prompt first, as `run`
                        // does, so that its Tab, Enter and Escape work
                        // while a stuck thread is waited for.
                        self.dispatch(&msg);
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
            .new_tab => self.requestTab(target),
            .goto_tab => self.gotoTab(target, value),
            .move_tab => self.moveTab(target, value),
            .move_tab_to_new_window => self.requestMoveTabToNewWindow(target),
            .set_tab_title => setTabTitle(target, value),
            .new_split => self.requestSplit(target, value),
            .goto_split => self.gotoSplit(target, value),
            .resize_split => self.resizeSplit(target, value),
            .equalize_splits => self.equalizeSplits(target),
            .toggle_split_zoom => self.toggleSplitZoom(target),
            .goto_window => self.gotoWindow(target, value),
            .float_window => floatWindow(target, value),
            .progress_report => progressReport(target, value),
            .desktop_notification => self.desktopNotification(target, value),
            .start_search => startSearch(target, value),
            .end_search => endSearch(target),
            .search_total => searchCount(target, .total, value.total),
            .search_selected => searchCount(target, .selected, value.selected),
            .prompt_title => self.requestTitlePrompt(target, value),
            .toggle_command_palette => self.requestPalette(target),
            .mouse_over_link => linkPreview(target, value),
            .key_sequence => keySequence(target, value),
            .key_table => keyTable(target, value),
            .readonly => readOnly(target, value),
            .show_child_exited => childExited(target, value),
            .scrollbar => scrollBar(target, value),

            // Everything else, including
            // `.cell_size` and `.size_limit` (sent during CoreSurface.init;
            // `false` is a valid answer to each).
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

    /// `.mouse_over_link`, from the core's cursor and key callbacks: the
    /// terminal's link preview shows the URL over its bottom-left corner,
    /// or hides for an empty one, as GTK's label does
    /// (`LinkPreview.show`). `false` for the app, and for a terminal whose
    /// preview could not be made or take the URL.
    fn linkPreview(target: apprt.Target, value: apprt.action.MouseOverLink) bool {
        return switch (target) {
            .app => false,
            .surface => |v| LinkPreview.show(v.rt_surface, value.url),
        };
    }

    /// `.key_sequence`, from the core's key callback, and its `.end` from
    /// a configuration change too: the terminal's key-state indicator adds
    /// the key to the pending sequence or clears it, as GTK's overlay does
    /// (`KeyState.sequence`). `false` for the app, and for a terminal whose
    /// indicator could not take the key or be made.
    fn keySequence(target: apprt.Target, value: apprt.action.KeySequence) bool {
        return switch (target) {
            .app => false,
            .surface => |v| KeyState.sequence(v.rt_surface, value),
        };
    }

    /// `.key_table`, from the core's key callback and a configuration
    /// change: the terminal's key-state indicator pushes or pops a key
    /// table, as GTK's overlay does (`KeyState.table`). `false` for the
    /// app, and for a terminal whose indicator could not take the table or
    /// be made.
    fn keyTable(target: apprt.Target, value: apprt.action.KeyTable) bool {
        return switch (target) {
            .app => false,
            .surface => |v| KeyState.table(v.rt_surface, value),
        };
    }

    /// `.readonly`, from the `toggle_readonly` binding, after the core has
    /// flipped its flag: the terminal's read-only badge shows over its
    /// top-right corner, or hides, as GTK's does (`ReadOnly.set`). `false`
    /// for the app, and for a terminal whose badge could not be made.
    fn readOnly(target: apprt.Target, value: apprt.action.Readonly) bool {
        return switch (target) {
            .app => false,
            .surface => |v| ReadOnly.set(v.rt_surface, value),
        };
    }

    /// `.show_child_exited`, from the core's tick once the terminal's
    /// command has exited: its banner shows across its bottom, titled by
    /// the exit code, with a button that closes it, as GTK's does
    /// (`ChildExited.show`); true stands in for the core's own text.
    /// `false` for the app, and for a terminal whose banner could not be
    /// made, which the core then writes its text into.
    fn childExited(target: apprt.Target, value: apprt.surface.Message.ChildExited) bool {
        return switch (target) {
            .app => false,
            .surface => |v| ChildExited.show(v.rt_surface, value),
        };
    }

    /// `.scrollbar`, from the core's tick when its rows change: the
    /// terminal's scroll bar shows them (`ScrollBar.update`). `false` for
    /// the app, and for a terminal with no bar (`scrollbar = never`).
    fn scrollBar(target: apprt.Target, value: terminal.Scrollbar) bool {
        return switch (target) {
            .app => false,
            .surface => |v| ScrollBar.update(v.rt_surface, value),
        };
    }

    /// `.start_search`, from the `start_search` binding with no text and
    /// from `search_selection` with the selection: the terminal's search
    /// bar opens, with the text if there is any, its field to get the
    /// focus with everything in it selected, as on GTK
    /// (`SearchBar.start`). `false`, so that the key reaches the terminal,
    /// for the app or when the bar cannot be made.
    fn startSearch(target: apprt.Target, value: apprt.action.StartSearch) bool {
        return switch (target) {
            .app => false,
            .surface => |v| SearchBar.start(v.rt_surface, value.needle),
        };
    }

    /// `.end_search`, which the core sends whether or not a search ran:
    /// the terminal's bar hides, and gives the terminal the focus back if
    /// its field had it (`SearchBar.finish`).
    fn endSearch(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| end: {
                SearchBar.finish(v.rt_surface);
                break :end true;
            },
        };
    }

    /// `.search_total` and `.search_selected`, from the core's search
    /// thread through its mailbox: the count the terminal's search bar
    /// shows, `selected/total` as on GTK (`SearchBar.countLabel`).
    fn searchCount(target: apprt.Target, comptime which: enum { total, selected }, value: ?usize) bool {
        return switch (target) {
            .app => false,
            .surface => |v| count: {
                switch (which) {
                    .total => SearchBar.setTotal(v.rt_surface, value),
                    .selected => SearchBar.setSelected(v.rt_surface, value),
                }
                break :count true;
            },
        };
    }

    /// `.prompt_title`, from `prompt_surface_title` and `prompt_tab_title`:
    /// a dialog over the terminal's window asks for its title or its tab's
    /// (`TitleDialog`), opened by `run`: a binding performs this inside the
    /// core's key callback, and the dialog takes the keyboard focus from
    /// the terminal. `false` for the app, and for `.window`
    /// (`prompt_window_title`): a window here has no title of its own to
    /// ask for, as its caption is always its shown tab's
    /// (`Window.tabTitle`), and the binding is documented as implemented
    /// on Linux only (src/input/Binding.zig), where GTK gives the window a
    /// title override. macOS takes it as the terminal's prompt instead
    /// (its `Ghostty.Action` maps any other target to the surface); here
    /// it does nothing, as on the platforms the binding documents as
    /// unsupported, rather than open a prompt the user did not ask for.
    fn requestTitlePrompt(self: *App, target: apprt.Target, value: apprt.action.PromptTitle) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        const which: TitleDialog.Target = switch (value) {
            .surface => .surface,
            .tab => .tab,
            .window => return false,
        };
        self.requests.append(self.core_app.alloc, .{ .title_prompt = .{
            .from = from,
            .target = which,
        } }) catch |err| {
            log.warn("cannot record a title prompt err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.toggle_command_palette`: the command palette opens over the
    /// terminal's window, or closes if it is open there, as GTK toggles its
    /// window's palette (`CommandPalette.toggle`). Carried out by `run`: a
    /// binding performs this inside the core's key callback, and the
    /// palette takes the keyboard focus from the terminal, or gives it
    /// back. `false` for the app.
    fn requestPalette(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .palette = from }) catch |err| {
            log.warn("cannot record a command palette to toggle err={}", .{err});
            return false;
        };
        return true;
    }

    fn closeWindow(self: *App, target: apprt.Target) bool {
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
            //
            // Behind a move of the terminal's tab to a new window, as when
            // a binding chains it after move_tab_to_new_window, recorded
            // for `run`, so that it closes the new window (`moveQueuedFor`),
            // or nothing if the tab does not move (`dropBehind`).
            .surface => |v| close: {
                if (self.moveQueuedFor(v.rt_surface)) |behind| {
                    self.requests.append(self.core_app.alloc, .{ .close_window = .{
                        .from = v,
                        .behind = behind,
                    } }) catch |err| {
                        log.warn("cannot record a window to close err={}", .{err});
                        break :close false;
                    };
                    break :close true;
                }
                v.rt_surface.window.requestClose();
                break :close true;
            },
        };
    }

    /// `.close_tab`: the terminal's tab, every other tab, or the tabs after
    /// it (`Window.requestCloseTabs`). The window's only tab is the window,
    /// which `.this` closes as `close_window` does: the default Ctrl+Shift+W
    /// on this platform (`Config.Keybinds.init`, where it replaced
    /// `close_surface`). `false` when the mode names no tab. Behind a move
    /// of the terminal's tab to a new window, recorded for `run`, so that
    /// it closes tabs there (`moveQueuedFor`), or none if the tab does not
    /// move (`dropBehind`); the action then reports it performed without
    /// knowing yet, as `gotoSplit` does.
    fn closeTab(self: *App, target: apprt.Target, mode: apprt.action.CloseTabMode) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        const surface = from.rt_surface;
        if (self.moveQueuedFor(surface)) |behind| {
            self.requests.append(self.core_app.alloc, .{ .close_tab = .{
                .from = from,
                .mode = mode,
                .behind = behind,
            } }) catch |err| {
                log.warn("cannot record a tab to close err={}", .{err});
                return false;
            };
            return true;
        }
        const window = surface.window;
        const at = window.find(surface) orelse return false;
        return window.closeTabs(at.index, mode);
    }

    /// `.new_tab`: for a terminal, a tab in its window, recorded for `run`
    /// as `requestWindow` records a window, since a binding performs it
    /// inside the core's key callback; for the app, nothing, as on GTK.
    fn requestTab(self: *App, target: apprt.Target) bool {
        const parent = switch (target) {
            // As GTK: a tab needs a window to go in.
            .app => {
                log.warn("new tab to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        self.requests.append(self.core_app.alloc, .{ .tab = parent }) catch |err| {
            log.warn("cannot record a new tab request err={}", .{err});
            return false;
        };
        return true;
    }

    /// Open a tab in `parent`'s window holding a new terminal, which
    /// inherits from `parent` as `tab-inherit-working-directory` asks, and
    /// show it.
    fn newTab(self: *App, parent: *CoreSurface) !void {
        const alloc = self.core_app.alloc;
        try self.surfaces.ensureUnusedCapacity(alloc, 1);

        const opts = self.inheritedOptions(parent, .tab);
        defer if (opts.working_directory) |v| alloc.free(v);

        const window = parent.rt_surface.window;
        const index = try window.newTab(opts);
        errdefer comptime unreachable;
        self.surfaces.appendAssumeCapacity(window.tabs.items[index].focused.?);

        // Shown once it is owned, as a new window is.
        window.selectTab(index);
    }

    /// `.goto_tab`: whether there is a tab to go to in the terminal's window
    /// (`Window.gotoTabIndex`), or one still to open there (`tabQueuedIn`),
    /// or the terminal's tab still to move to a new window
    /// (`moveQueuedFor`), among whose tabs it then goes; `false` lets the
    /// key through to the terminal, as the default bindings are
    /// performable. The tab is shown by `run`: a binding performs this
    /// inside the core's key callback, and showing it lays terminals out
    /// and moves the focus.
    fn gotoTab(self: *App, target: apprt.Target, to: apprt.action.GotoTab) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        const window = from.rt_surface.window;
        const behind = self.moveQueuedFor(from.rt_surface);
        if (window.gotoTabIndex(to) == null and
            !self.tabQueuedIn(window) and
            behind == null) return false;
        self.requests.append(self.core_app.alloc, .{ .goto_tab = .{
            .from = from,
            .to = to,
            .behind = behind,
        } }) catch |err| {
            log.warn("cannot record a tab to go to err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.move_tab`: made at once, since only the order of the tabs changes;
    /// but behind a tab still to open in the window, as when a binding
    /// chains it after `new_tab`, or behind a move of the terminal's tab
    /// to a new window (`moveQueuedFor`), recorded for `run`, so that it
    /// moves among the tabs GTK would have by then. The action then reports
    /// it performed without knowing yet, as `gotoSplit` does.
    fn moveTab(self: *App, target: apprt.Target, value: apprt.action.MoveTab) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        const window = from.rt_surface.window;
        const behind = self.moveQueuedFor(from.rt_surface);
        if (!self.tabQueuedIn(window) and behind == null) {
            return window.moveTab(from.rt_surface, value.amount);
        }
        self.requests.append(self.core_app.alloc, .{ .move_tab = .{
            .from = from,
            .amount = value.amount,
            .behind = behind,
        } }) catch |err| {
            log.warn("cannot record a tab to move err={}", .{err});
            return false;
        };
        return true;
    }

    /// `.move_tab_to_new_window`: whether the terminal's window has another
    /// tab to keep, or one still to open there (`tabQueuedIn`, as when a
    /// binding chains it after `new_tab`); else, and for the app, `false`,
    /// as on GTK, so that the key reaches the terminal. The move is made by
    /// `run` (`moveTabToNewWindow`): a binding performs this inside the
    /// core's key callback, and the move creates a window, lays terminals
    /// out and moves the focus.
    fn requestMoveTabToNewWindow(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => return false,
            .surface => |v| v,
        };
        const window = from.rt_surface.window;
        if (window.tabs.items.len <= 1 and !self.tabQueuedIn(window)) return false;
        self.requests.append(self.core_app.alloc, .{ .move_tab_to_new_window = .{ .from = from } }) catch |err| {
            log.warn("cannot record a tab to move to a new window err={}", .{err});
            return false;
        };
        return true;
    }

    /// Whether `requests` holds a tab that will open in `window`.
    fn tabQueuedIn(self: *const App, window: *const Window) bool {
        for (self.requests.items) |request| switch (request) {
            .tab => |parent| if (parent.rt_surface.window == window) return true,
            else => {},
        };
        return false;
    }

    /// Whether `requests` holds a move of the tab of `surface` to a new
    /// window. GTK moves it at once (`moveTabToNewWindow` in
    /// src/apprt/gtk/class/window.zig), so that what a terminal of the tab
    /// does next to its window or tabs, such as a binding chained after
    /// it, acts on the new window: here that waits behind the move, as
    /// behind a tab still to open (`tabQueuedIn`). The index in `requests`
    /// of the last such move, which the action waits behind, or null.
    fn moveQueuedFor(self: *const App, surface: *const Surface) ?usize {
        const t = surface.window.tabOf(surface) orelse return null;
        var last: ?usize = null;
        for (self.requests.items, 0..) |request, i| switch (request) {
            .move_tab_to_new_window => |move| {
                const moving = move.from.rt_surface;
                if (moving.window.tabOf(moving) == t) last = i;
            },
            else => {},
        };
        return last;
    }

    /// The move of a tab to a new window at `index` in `requests` did not
    /// happen: it failed, or was not made because the tab's window had no
    /// other tab left or was closing, or its terminal began to close
    /// (`forgetClosing`). What waits behind it (`moveQueuedFor`) is dropped,
    /// logged: it was meant for the new window, and would act on the old
    /// one, where close_window, say, would close the window the move was
    /// to leave with its other tabs. GTK makes the move at once, so that
    /// what follows it never finds it undone.
    fn dropBehind(self: *App, index: usize) void {
        for (self.requests.items[index + 1 ..]) |*request| {
            const behind: ?usize = switch (request.*) {
                .close_window => |close| close.behind,
                .close_tab => |close| close.behind,
                .goto_tab => |goto| goto.behind,
                .move_tab => |move| move.behind,
                else => null,
            };
            if (behind != index) continue;
            log.info("a {s} waiting for a tab's move to a new window is dropped: the tab did not move", .{@tagName(request.*)});
            request.* = .dropped;
        }
    }

    /// `.set_tab_title`: made at once, as `set_title` is.
    fn setTabTitle(target: apprt.Target, value: apprt.action.SetTitle) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.window.setTabTitle(v.rt_surface, value.title),
        };
    }

    fn presentTerminal(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.window.present(),
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
    /// call, so it is copied, and every window repaints its dividers, and
    /// every terminal its overlays, which may be drawn on the
    /// configuration's background (`Overlays.terminalBackground`). In a
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
        for (self.surfaces.items) |surface| surface.overlays.invalidate();
        // `window-decoration` and `scrollbar` may have changed, here or in
        // a theme a soft reload switched to; the frames and the terminals
        // change for them from `run`, since a soft reload comes inside a
        // core frame. `run` is woken for it: the reload that `run`'s own
        // syncColorScheme makes comes after its createRequested.
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
    /// a focus move to it; with a move of its tab to a new window, so is
    /// what waits behind that move (`dropBehind`); and a title prompt it
    /// opened closes (`TitleDialog.forget`).
    /// Called by `Surface.detachCore`, the first step of every teardown,
    /// while the address is still that surface's, so that a surface created
    /// later at the same address cannot pass for it.
    pub fn forgetClosing(self: *App, core_surface: *CoreSurface) void {
        for (self.requests.items, 0..) |*request, i| switch (request.*) {
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
            .equalize, .fullscreen, .maximize, .zoom, .decorations, .reset_window_size, .close_surface => |from| {
                if (from == core_surface) request.* = .dropped;
            },
            .goto_window => |goto| {
                if (goto.from == core_surface) request.* = .dropped;
            },
            .tab => |parent| {
                if (parent == core_surface) request.* = .dropped;
            },
            .goto_tab => |goto| {
                if (goto.from == core_surface) request.* = .dropped;
            },
            .move_tab => |move| {
                if (move.from == core_surface) request.* = .dropped;
            },
            // With what waits behind it, from other terminals of the tab.
            .move_tab_to_new_window => |move| if (move.from == core_surface) {
                request.* = .dropped;
                self.dropBehind(i);
            },
            .close_window => |close| {
                if (close.from == core_surface) request.* = .dropped;
            },
            .close_tab => |close| {
                if (close.from == core_surface) request.* = .dropped;
            },
            .resize_window => |resize| {
                if (resize.from == core_surface) request.* = .dropped;
            },
            .overlay_key => |key| {
                if (key.from == core_surface) request.* = .dropped;
            },
            .palette => |from| {
                if (from == core_surface) request.* = .dropped;
            },
            // And an entry chosen to focus it.
            .palette_run => |chosen| {
                if (chosen.from == core_surface or chosen.pending.jumpsTo(core_surface.rt_surface)) self.freeRequest(request);
            },
            .search_key => |key| {
                if (key.from == core_surface) request.* = .dropped;
            },
            .title_prompt => |prompt| {
                if (prompt.from == core_surface) request.* = .dropped;
            },
            .reload, .redecorate, .dropped => {},
        };
        for (self.windows.items) |window| for (window.tabs.items) |t| {
            const surface = t.pending_focus orelse continue;
            if (&surface.core_surface == core_surface) t.pending_focus = null;
        };
        if (self.search_focus) |surface| {
            if (&surface.core_surface == core_surface) self.search_focus = null;
        }
        // Its bar is destroyed with it (`Surface.destroy`).
        if (self.search_hide) |surface| {
            if (&surface.core_surface == core_surface) self.search_hide = null;
        }
        // The command palette open for it closes, and one with a jump to it
        // lists it no more.
        CommandPalette.forget(self, core_surface.rt_surface);
        // And the title prompt it asked for closes, last: its frame, enabled
        // again, may take the activation and give a terminal the focus.
        TitleDialog.forget(self, core_surface.rt_surface);
    }

    /// `.goto_split`: whether there is a terminal to go to from the one the
    /// action is performed on (`Window.goto`). `false` lets the key through
    /// to the terminal, as the default bindings are performable. The focus
    /// moves once the core's key callback has returned
    /// (`Tab.pending_focus`).
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
        const t = window.tabOf(surface).?;
        if (t == window.tab()) {
            t.pending_focus = surface;
        } else {
            window.focusHidden(t, surface);
        }
        return true;
    }

    /// `.resize_split`: recorded for `run` (`requests`), which lays the
    /// terminals out again once the core's key callback has returned: a
    /// terminal moved inside it would re-enter the core with WM_SIZE
    /// (`CoreSurface.sizeCallback`). GTK and macOS lay out later too. As on
    /// GTK, `false` for no amount or a tab with a single terminal, so that
    /// the key reaches the terminal, unless a split in that tab is still to
    /// come from `requests`.
    fn resizeSplit(self: *App, target: apprt.Target, value: apprt.action.ResizeSplit) bool {
        const from = switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        if (value.amount == 0) return false;
        const t = from.rt_surface.window.tabOf(from.rt_surface) orelse return false;
        if (!t.tree.isSplit() and !self.splitQueuedIn(t)) return false;
        self.requests.append(self.core_app.alloc, .{ .resize = .{
            .from = from,
            .value = value,
        } }) catch |err| {
            log.warn("cannot record a split resize err={}", .{err});
            return false;
        };
        return true;
    }

    /// Whether `requests` holds a split that will land in `t`.
    fn splitQueuedIn(self: *const App, t: *const Tab) bool {
        for (self.requests.items) |request| switch (request) {
            .split => |split| {
                const parent = split.parent.rt_surface;
                if (parent.window.tabOf(parent) == t) return true;
            },
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

    /// `.copy_title_to_clipboard`: the terminal's title as it shows, the
    /// user's from its title prompt if it has one (`Surface.effectiveTitle`),
    /// written as a copy is (`Surface.setClipboard`), as GTK copies it;
    /// `false` with none, or an empty one, on which the binding's
    /// documentation says it has no effect. Made at once, as a copy is:
    /// nothing is laid out and no focus moves.
    fn copyTitleToClipboard(target: apprt.Target) bool {
        const surface = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface,
        };
        const title = surface.effectiveTitle() orelse return false;
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
            _ = surface.window.present();
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
    /// GTK it is not performed for a single terminal, unless a split in its
    /// tab is still to come, so that the key reaches the terminal.
    fn toggleSplitZoom(self: *App, target: apprt.Target) bool {
        const from = switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },
            .surface => |v| v,
        };
        const t = from.rt_surface.window.tabOf(from.rt_surface) orelse return false;
        if (!t.tree.isSplit() and !self.splitQueuedIn(t)) return false;
        self.requests.append(self.core_app.alloc, .{ .zoom = from }) catch |err| {
            log.warn("cannot record zooming the split err={}", .{err});
            return false;
        };
        return true;
    }

    /// Give each window the focus move a `goto_split` chose in it, if any
    /// (`Tab.pending_focus`). Called by a terminal's key handler once the
    /// core's key callback has returned (`Surface.handleMessage`), and by
    /// `run` for an action performed from anywhere else.
    pub fn applyPendingFocus(self: *App) void {
        // By index, reading the length each time round: giving the focus
        // runs window procedures.
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            const window = self.windows.items[i];
            const surface = window.tab().pending_focus orelse continue;
            window.tab().pending_focus = null;
            // Still live: a teardown would have cleared it (`forgetClosing`).
            window.focusFromGoto(surface);
        }
        // And the one a search bar asked for (`search_focus`).
        if (self.search_focus) |surface| {
            self.search_focus = null;
            surface.window.giveSearchFocus(surface);
        }
        // Then the bar `end_search` left shown while it held the focus:
        // hidden now that the focus has left it, or given to its terminal
        // here if it has not (`SearchBar.place`); placed again instead if
        // a `start_search` opened it meanwhile.
        if (self.search_hide) |surface| {
            self.search_hide = null;
            SearchBar.place(surface);
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
                    const from = resize.from.rt_surface;
                    const t = from.window.tabOf(from) orelse continue;
                    from.window.resizeSplit(t.focused orelse from, resize.value);
                },
                .equalize => |from| from.rt_surface.window.equalize(from.rt_surface),
                .reload => self.reloadQueued(),
                .fullscreen => |from| from.rt_surface.window.toggleFullscreen(),
                .decorations => |from| from.rt_surface.window.toggleDecorations(),
                .reset_window_size => |from| from.rt_surface.window.resetSize(),
                .resize_window => |resize| resize.from.rt_surface.window.resizeToTerminal(
                    resize.from.rt_surface,
                    resize.size,
                ),
                // And `window-show-tab-bar` may have changed.
                .redecorate => for (self.windows.items) |window| {
                    window.applyDecorations();
                    window.applyScrollBars();
                    window.relayout();
                },
                // A window covering its monitor is left as it is: maximized,
                // it would have the work area instead.
                .maximize => |from| {
                    const window = from.rt_surface.window;
                    if (window.fullscreen == null) window.toggleMaximize();
                },
                .goto_window => |goto| {
                    const window = self.windowBeside(goto.from.rt_surface.window, goto.to) orelse continue;
                    _ = window.present();
                },
                .tab => |parent| self.newTab(parent) catch |err| {
                    log.err("failed to create a tab err={}", .{err});
                    notice(self, parent.rt_surface.hwnd, L("Ghostty could not open a new tab."));
                },
                .goto_tab => |goto| {
                    const window = goto.from.rt_surface.window;
                    if (window.gotoTabIndex(goto.to)) |index| window.selectTab(index);
                },
                .move_tab => |move| _ = move.from.rt_surface.window.moveTab(move.from.rt_surface, move.amount),
                .move_tab_to_new_window => |move| if (!self.reportMove(
                    move.from.rt_surface.hwnd,
                    self.moveTabToNewWindow(move.from, move.drop),
                )) self.dropBehind(i),
                .close_window => |close| close.from.rt_surface.window.requestClose(),
                .close_tab => |close| {
                    const window = close.from.rt_surface.window;
                    const at = window.find(close.from.rt_surface) orelse continue;
                    _ = window.closeTabs(at.index, close.mode);
                },
                // From the focused terminal, as `resize` starts.
                .zoom => |core_from| {
                    const from = core_from.rt_surface;
                    const t = from.window.tabOf(from) orelse continue;
                    from.window.toggleZoom(t.focused orelse from);
                },
                .overlay_key => |key| overlay_keys.replay(key.from, key.trigger, key.field),
                .palette => |from| CommandPalette.toggle(from.rt_surface),
                // Freed here; `pending` is not used after.
                .palette_run => |chosen| {
                    self.requests.items[i] = .dropped;
                    CommandPalette.replay(chosen.from.rt_surface, chosen.pending);
                },
                .search_key => |key| SearchBar.replay(key.from, key.key),
                .title_prompt => |prompt| _ = TitleDialog.open(prompt.from.rt_surface, prompt.target),
                .close_surface => |from| from.rt_surface.requestClose(),
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
        const t = window.tabOf(from.rt_surface) orelse return;
        const start = t.focused orelse from.rt_surface;
        const surface = window.goto(start, to) orelse return;
        if (surface.liveCore() == null) return;
        // No core frame is on the stack here, unlike in gotoSplit; but a
        // move in a tab not shown leaves it hidden, as there.
        if (t == window.tab()) {
            window.focusFromGoto(surface);
        } else {
            window.focusHidden(t, surface);
        }
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
        self.surfaces.appendAssumeCapacity(window.tab().focused.?);

        // Shown once both are owned, so that its first messages find them.
        window.show();
        return window;
    }

    /// Move the tab of `from`, a live surface, into a new window, made and
    /// shown as `newWindow` makes and shows one, which titles itself after
    /// the tab and gives its focused terminal the focus (`Window.show`);
    /// as on GTK. Nothing, logged, if by now `from` or its window is
    /// closing or the window has no other tab: tabs may have closed since
    /// the action was recorded.
    ///
    /// On an error nothing has changed: whatever can fail is done before
    /// the old window lets go of the tab (`Window.moveTabTo`), and the new
    /// window is then discarded. Should that step fail and not be undone,
    /// the move is finished instead, with any terminal that still cannot
    /// go kept in the old window (`Window.Moved`), for the caller to say
    /// so: either way each terminal is in the frame of the one window
    /// holding it, which the app owns, so that closing it frees them. Null
    /// when nothing was moved and nothing failed.
    ///
    /// A tab dragged out of the bar comes with where it was dropped, for
    /// the new frame's place (`Window.placeForDrop`).
    fn moveTabToNewWindow(self: *App, from: *CoreSurface, drop: ?Window.Drop) !?Window.Moved {
        const surface = from.rt_surface;
        const old = surface.window;
        const at = old.find(surface) orelse return null;
        if (surface.closing) {
            log.info("the tab is not moved to a new window: its terminal is closing", .{});
            return null;
        }
        return self.moveTabAt(old, at.index, drop);
    }

    /// `moveTabToNewWindow` for the tab at `index` in `old`. Called where
    /// `canReenterCore` holds: by `run` (`createRequested`), where no
    /// teardown is running, and for a drop (`moveTabOut`), which may come
    /// inside one.
    fn moveTabAt(self: *App, old: *Window, index: usize, drop: ?Window.Drop) !?Window.Moved {
        const alloc = self.core_app.alloc;
        if (old.closing or old.tabs.items.len <= 1) {
            log.info("the tab is not moved to a new window: its window is closing, or it is the only tab", .{});
            return null;
        }

        try self.windows.ensureUnusedCapacity(alloc, 1);
        const window = try Window.createBare(self);
        errdefer window.discard();
        // Before the tab comes, so that its terminals take the scale of the
        // monitor the frame is on (`Window.adoptTab`).
        if (drop) |d| window.placeForDrop(d);
        const moved = try old.moveTabTo(index, window);
        errdefer comptime unreachable;
        self.windows.appendAssumeCapacity(window);
        // A title prompt over `old` for a terminal of the tab closes. A
        // command palette open there now runs on the terminal of the tab
        // shown in its place (`CommandPalette.focusMoved`).
        TitleDialog.followMove(old);

        // Shown once it is owned, as a new window is.
        window.show();
        return moved;
    }

    /// A tab dragged out of `old`'s bar, the one at `index`, dropped
    /// outside the window (`Window.dropTabOut`), whenever the core may be
    /// re-entered: from `run`'s loop, from a system modal loop, or from
    /// the pump inside a terminal's teardown (`waitForThread`), which a
    /// release can reach as well. Moved to a new window at once, as `run`
    /// moves one for `move_tab_to_new_window`, and its failure told the
    /// same way. A terminal being torn down has left its tab already
    /// (`Surface.destroy`), and a window being torn down refuses the drop
    /// (`Window.closing`). Nothing while the tab's focused terminal is
    /// closing, as for the action.
    pub fn moveTabOut(self: *App, old: *Window, index: usize, drop: Window.Drop) void {
        const focused = old.tabs.items[index].focused orelse return;
        if (focused.closing) {
            log.info("the tab is not moved to a new window: its terminal is closing", .{});
            return;
        }
        _ = self.reportMove(focused.hwnd, self.moveTabAt(old, index, drop));
    }

    /// Tell the user, in a notice owned by the window of `owner`, the moved
    /// tab's terminal, if moving a tab to a new window failed (`result`),
    /// or failed partway and was finished instead (`Window.Moved`); whether
    /// the tab moved.
    fn reportMove(self: *App, owner: win32.HWND, result: anyerror!?Window.Moved) bool {
        const maybe = result catch |err| {
            log.err("failed to move a tab to a new window err={}", .{err});
            notice(self, owner, L("Ghostty could not move the tab to a new window."));
            return false;
        };
        const moved = maybe orelse return false;
        switch (moved) {
            .whole => {},
            .after_failure => {
                log.err("a tab was moved to a new window after its move failed and could not be undone", .{});
                notice(
                    self,
                    owner,
                    L("Moving the tab to a new window failed partway and could not be undone, so the tab was moved anyway."),
                );
            },
            .split => {
                log.err("a tab was moved to a new window after its move failed, but a terminal stayed behind", .{});
                notice(
                    self,
                    owner,
                    L("Moving the tab to a new window failed partway: the tab was moved, but a terminal that could not move stays in the window it was in, in a tab of its own."),
                );
            },
        }
        return true;
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

        // Shown once it is owned, as a new window is. In a tab not shown, it
        // waits hidden, as that tab's terminals do (`Window.hideTab`), to
        // have the focus when the tab is, as GTK's new split is its tab's
        // focused terminal.
        const t = window.tabOf(surface).?;
        if (t == window.tab()) {
            window.showPane(surface);
        } else {
            t.focused = surface;
            surface.occlusionChanged(false);
        }
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
        // (its WM_DESTROY); this only keeps it from ever dangling, in
        // whichever tab.
        for (surface.window.tabs.items) |t| {
            if (t.focused == surface) t.focused = null;
        }
        // A terminal with no core never passed through `forgetClosing`.
        if (self.search_focus == surface) self.search_focus = null;
        if (self.search_hide == surface) self.search_hide = null;
        CommandPalette.forget(self, surface);
        TitleDialog.forget(self, surface);
        surface.deinit();
        self.core_app.alloc.destroy(surface);

        // The quit timer is not handled here: CoreApp.deleteSurface, which
        // Surface.stopCore calls before the window is destroyed, starts it
        // when the core's last surface goes (`CoreApp.deleteSurface`).
    }

    /// Called from the frame's WM_NCDESTROY, after its terminals'
    /// WM_DESTROY, and by `terminate` for a window that could not be
    /// destroyed. The ownership invariant of `surfaceDestroyed` holds for
    /// `self.windows` too: a frame not handed over yet is destroyed, and
    /// its window freed, by `Window.discard` (from `Window.create` and
    /// `moveTabToNewWindow`).
    pub fn windowDestroyed(self: *App, window: *Window) void {
        const idx = std.mem.indexOfScalar(*Window, self.windows.items, window) orelse return;

        // As in surfaceDestroyed; after WM_NCDESTROY no message comes, but a
        // window `terminate` gives up on still exists.
        _ = win32.SetWindowLongPtrW(window.hwnd, win32.GWLP_USERDATA, 0);
        // The bar is a child of the frame, which it outlives with the same
        // back-pointer; and its WM_DESTROY, which frees its font, never
        // comes. Not DestroyWindow: it would fail as the frame's did, and on
        // the normal path the bar is gone already (`hwnd` null).
        if (window.bar.hwnd) |bar| _ = win32.SetWindowLongPtrW(bar, win32.GWLP_USERDATA, 0);
        window.bar.freeFont();

        // In order: `windowBeside` goes by opening order.
        _ = self.windows.orderedRemove(idx);
        // Its tabs' trees are empty already unless `terminate` gave up on
        // the frame, which then had no WM_DESTROY.
        window.deinitTabs(self.core_app.alloc);
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

    // No CS_HREDRAW or CS_VREDRAW for the frame and terminal classes.
    // They would invalidate the whole window on every resize step, shrinks
    // included. A terminal draws nothing through GDI, and WM_SIZE already
    // queues its frame for the new size, so each resulting WM_PAINT would
    // only wake its renderer for another frame of the same size. The frame
    // paints just its dividers, and Windows already invalidates what a
    // resize or a terminal's move uncovers of it.
    //
    // CS_DBLCLKS on the frame: a double click on a divider equalizes the
    // splits (`Dividers.doubleClick`). With it every button's second quick
    // press over the frame's own client area, the dividers and their
    // bands, comes as a *BUTTONDBLCLK. The frame handles no other button,
    // and DefWindowProcW does with their double-click messages what it did
    // with their presses: nothing. The caption's double click is
    // WM_NCLBUTTONDBLCLK, with or without it.
    const window_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_DBLCLKS,
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

    // CS_DBLCLKS: a double click on its empty part opens a tab; with it
    // every button's second quick press is a *BUTTONDBLCLK, which the bar
    // takes as a press anywhere else (`TabBar.wndProc`). The bar
    // draws itself through GDI, and is invalidated explicitly whenever it
    // is placed or its tabs change (`Window.placeBar`, `TabBar.Bar`).
    const bar_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_DBLCLKS,
        .lpfnWndProc = &TabBar.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = arrow,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(TabBar.class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&bar_class) == 0) {
        log.err("failed to register the tab bar class err={}", .{win32.GetLastError()});
        return App.Error.Win32ClassRegistrationFailed;
    }
    errdefer _ = win32.UnregisterClassW(L(TabBar.class_name), hinstance);

    // No CS_DBLCLKS: a quick second click on a button is a click like any
    // other. The bar draws itself through GDI and is invalidated whenever
    // it is placed or its count changes (`SearchBar.place`).
    const search_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &SearchBar.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = arrow,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(SearchBar.class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&search_class) == 0) {
        log.err("failed to register the search bar class err={}", .{win32.GetLastError()});
        return App.Error.Win32ClassRegistrationFailed;
    }
    errdefer _ = win32.UnregisterClassW(L(SearchBar.class_name), hinstance);

    const palette_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &CommandPalette.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = arrow,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(CommandPalette.class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&palette_class) == 0) {
        log.err("failed to register the command palette class err={}", .{win32.GetLastError()});
        return App.Error.Win32ClassRegistrationFailed;
    }
    errdefer _ = win32.UnregisterClassW(L(CommandPalette.class_name), hinstance);

    // The overlays' classes (`Overlays.registerClasses`).
    try Overlays.registerClasses(hinstance, arrow);
    errdefer Overlays.unregisterClasses(hinstance);

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
    _ = win32.UnregisterClassW(L(TabBar.class_name), hinstance);
    _ = win32.UnregisterClassW(L(SearchBar.class_name), hinstance);
    _ = win32.UnregisterClassW(L(CommandPalette.class_name), hinstance);
    Overlays.unregisterClasses(hinstance);
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

/// Whether `cp` in a link's target can hide part of it or add a display
/// line: control, bidirectional and zero-width code points. The macOS
/// app's set (`isUnsafeCharacter` in
/// macos/Sources/Helpers/UntrustedURL.swift), which refuses such a link
/// (`untrustedLinkAllowed`) and shows each one escaped in its preview
/// (`LinkPreview`). All of them are in the BMP and none is a surrogate.
pub fn unsafeCodepoint(cp: u21) bool {
    return switch (cp) {
        0x00...0x1F, 0x7F...0x9F => true, // C0 and C1 controls
        0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069 => true, // bidi, zero width
        0x2028, 0x2029, 0x2060, 0xFEFF => true, // line separators, word joiner, BOM
        else => false,
    };
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
    // Invalid UTF-8 cannot be shown.
    var it = (std.unicode.Utf8View.init(url) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        if (unsafeCodepoint(cp)) return false;
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
    // No title prompt to offer a pumped message to (`dispatch`).
    app.windows = .empty;

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
    for ([_]*Window{ &a, &b, &c }) |window| {
        window.prompt_disabled = false;
        window.title_prompt = .{};
    }

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
    // The real ones, as `init` resolves them: no test stands in for them.
    app.bar_metric = ScrollBar.Metric.resolve(win32.GetModuleHandleW(L("user32.dll")));
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
    app.terminal_loops = 0;
    app.surfaces = .empty;
    app.windows = .empty;
    app.requests = .empty;
    app.search_focus = null;
    app.search_hide = null;
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
    errdefer alloc.destroy(window);
    window.* = .{
        .app = app,
        .hwnd = undefined,
        .tabs = .empty,
        .selected = 0,
        .bar = .{},
        .dark_frame = false,
        .fullscreen = null,
        .decoration = null,
        .modal_loops = .{},
        .taskbar_button = false,
        .prompt_disabled = false,
        .title_prompt = .{},
        .palette = .{},
        .divider_drag = null,
        .divider_wheel = false,
        .closing = false,
        .destroy_deferred = false,
    };
    _ = try window.appendTab(alloc);
    errdefer window.deinitTabs(alloc);
    _ = try window.createFrame(0, 0, 200, 100);
    window.bar.create(window);
    app.windows.appendAssumeCapacity(window);
    return window;
}

/// For tests: a hidden terminal window of the real class in `window`,
/// owned by `app`, with no core surface, and the scroll bar the
/// configuration asks for (`ScrollBar.style`): a teardown only destroys
/// and frees it. The caller puts it in the window's tree. A test that
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
    surface.title_override = null;
    surface.initial_size = null;
    surface.ime = .{};
    surface.closing = false;
    surface.destroy_deferred = false;
    surface.focused = false;
    surface.mouse = .init();
    surface.progress = .{};
    surface.progress_expires = 0;
    surface.notifications = .{ .id = @intFromPtr(surface) };
    surface.search_bar = .{};
    surface.overlays = .{};
    surface.scroll_bar = .{};
    surface.preedit = .none;
    _ = win32.CreateWindowExW(
        0,
        L(surface_class_name),
        null,
        win32.WS_CHILD | ScrollBar.style(&app.config),
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
    // As `Surface.create` makes it.
    ScrollBar.made(surface);
    Overlays.create(surface);
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
    app.freeRequests();
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
    window.tab().tree = try .init(alloc, surface);
    window.tab().focused = surface;

    // The frame's WM_SIZE, sent even to a hidden window, lays the terminal
    // out over the frame's new client area; its own is what its scroll bar
    // leaves of it.
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
    try std.testing.expectEqual(frame_client, try paneRect(window, surface));
    var inner = frame_client;
    inner.right -= ScrollBar.width(surface);
    try std.testing.expectEqual(inner, try clientRect(surface.hwnd));

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

/// For tests: where `pane`'s client area, its window less its scroll bar,
/// is inside its frame's client area, worked out here, not as the
/// overlays work it out (`Overlays.paneRect`).
fn paneClient(window: *const Window, pane: *const Surface) !win32.RECT {
    var rect = try paneRect(window, pane);
    const client = try clientRect(pane.hwnd);
    rect.right = rect.left + client.right;
    rect.bottom = rect.top + client.bottom;
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
    window.tab().tree = try testRow(alloc, &.{ left, right });
    window.tab().focused = left;

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
    window.tab().tree = try testRow(alloc, &panes);
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
    try std.testing.expect(window.tab().focused == d);

    try std.testing.expect(a.destroy());
    try std.testing.expect(window.tab().focused == d);
    try expectRow(window, &.{ b, c, d });

    focus(c);
    try std.testing.expect(c.destroy());
    try std.testing.expect(window.tab().focused == b);
    try std.testing.expectEqualSlices(u16, utf16("b"), testCaption(window, &buf));
    try expectRow(window, &.{ b, d });

    // The first terminal has none before it: the one after it.
    try std.testing.expect(b.destroy());
    try std.testing.expect(window.tab().focused == d);
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
    row.tab().tree = try testRow(alloc, &.{ a, b, c });
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
    column.tab().tree = try testLine(alloc, &.{ x, y, z }, .down);
    try std.testing.expect(column.goto(y, .up) == x);
    try std.testing.expect(column.goto(y, .down) == z);

    // A window with one terminal has nowhere to go.
    const alone = try testFrame(&app);
    const only = try testPane(&app, alone);
    alone.tab().tree = try .init(alloc, only);
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
    alone.tab().tree = try .init(alloc, only);
    try std.testing.expect(!try app.performAction(.{ .surface = &only.core_surface }, .goto_split, .next));
    try std.testing.expect(alone.tab().pending_focus == null);

    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;

    // Already closing: refused.
    b.core_state = .stopping;
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.tab().pending_focus == null);

    // Live; no core call is made on it. Back to `.none` before the
    // teardown at the end, which would stop a live core.
    b.core_state = .live;
    defer b.core_state = .none;

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.tab().focused == a);
    app.forgetClosing(&b.core_surface);
    app.applyPendingFocus();
    try std.testing.expect(window.tab().focused == a);

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.tab().focused == a);
    app.applyPendingFocus();
    try std.testing.expect(window.tab().focused == b);
}

test "win32: goto_split moves the focus in every window it is performed in" {
    // An `all:` binding performs the action on every surface, so each
    // window keeps its own move until the key callback has returned
    // (`Tab.pending_focus`): one slot for the app would keep only the
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
    first.tab().tree = try testRow(alloc, &.{ a, b });
    first.tab().focused = a;

    const second = try testFrame(&app);
    const c = try testPane(&app, second);
    const d = try testPane(&app, second);
    second.tab().tree = try testRow(alloc, &.{ c, d });
    second.tab().focused = c;

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
    try std.testing.expect(first.tab().focused == b);
    try std.testing.expect(second.tab().focused == d);
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
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    b.core_state = .live;
    defer b.core_state = .none;

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .new_split, .down));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right));
    try std.testing.expect(window.tab().pending_focus == null);
    try std.testing.expect(window.tab().focused == a);

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
    window.tab().tree = try testRow(alloc, &.{ a, b, c });
    window.tab().focused = b;
    b.core_state = .live;
    defer b.core_state = .none;
    c.core_state = .live;
    defer c.core_state = .none;

    try app.requests.append(alloc, .{ .goto = .{ .from = &a.core_surface, .to = .right } });
    app.createRequested();
    try std.testing.expect(window.tab().focused == c);
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
    window.tab().tree = tree: {
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
    window.tab().tree = try testRow(alloc, &.{ a, b });
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
    window.tab().tree = try testRow(alloc, &.{ a, b, c });
    window.relayout();
    const width = struct {
        fn width(w: *const Window, pane: *const Surface) !i32 {
            const r = try paneRect(w, pane);
            return r.right - r.left;
        }
    }.width;
    try std.testing.expect(try width(window, a) > try width(window, b) + 1);

    window.equalize(b);
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
    alone.tab().tree = try .init(alloc, only);
    const window = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
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
    window.tab().tree = tree: {
        var row = try testRow(alloc, &.{ a, b });
        defer row.deinit();
        var below: Window.Tree = try .init(alloc, c);
        defer below.deinit();
        break :tree try row.split(alloc, row.locate(b).?, .down, 0.5, &below);
    };
    window.tab().focused = b;
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
    row.tab().tree = try testRow(alloc, &.{ x, y, z });
    row.relayout();
    try app.requests.append(alloc, .{ .equalize = &x.core_surface });
    app.createRequested();
    try expectRow(row, &.{ x, y, z });
    const wx = (try paneRect(row, x)).right - (try paneRect(row, x)).left;
    const wz = (try paneRect(row, z)).right - (try paneRect(row, z)).left;
    try expectNear(wx, wz);
}

/// For tests: a GetDpiForWindow that answers `dpi` for every window, in
/// place of the system DPI the tests would otherwise see.
const TestDpi = struct {
    var dpi: win32.UINT = 96;

    fn of(hwnd: win32.HWND) callconv(.winapi) win32.UINT {
        _ = hwnd;
        return dpi;
    }
};

/// For tests: `pane`'s answer to WM_NCHITTEST at `x`, `y` in its frame's
/// client area, asked with the point on the screen as Windows asks it.
fn testHitTest(window: *const Window, pane: *const Surface, x: i32, y: i32) !win32.LRESULT {
    var pt: win32.POINT = .{ .x = x, .y = y };
    if (!win32.ClientToScreen(window.hwnd, &pt).toBool()) return error.TestUnexpectedResult;
    return win32.SendMessageW(pane.hwnd, win32.WM_NCHITTEST, 0, testPoint(pt.x, pt.y));
}

/// For tests: (a | b) over c in `window`, laid out.
fn testSplits(window: *Window, a: *Surface, b: *Surface, c: *Surface) !void {
    const alloc = window.app.core_app.alloc;
    window.tab().tree = tree: {
        var row = try testRow(alloc, &.{ a, b });
        defer row.deinit();
        var below: Window.Tree = try .init(alloc, c);
        defer below.deinit();
        break :tree try row.split(alloc, .root, .down, 0.5, &below);
    };
    window.tab().focused = a;
    window.relayout();
}

test "win32: beside a divider a terminal lets the pointer through to the frame" {
    // In (a | b) over c at 96 DPI: within 3 pixels of either line, each
    // terminal answers WM_NCHITTEST with HTTRANSPARENT, so that Windows
    // gives the pointer to the frame under it (`Dividers.hitTest`); a
    // pixel further, and along the window's outer edges, it answers as
    // before.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    // Without scroll bars, which keep their pixels beside a line ("beside
    // a divider a terminal's scroll bar keeps its pixels").
    app.config.scrollbar = .never;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    const ra = try paneRect(window, a);
    const rb = try paneRect(window, b);
    const rc = try paneRect(window, c);
    // A line of a pixel between a and b, and one between them and c.
    try std.testing.expectEqual(ra.right + 1, rb.left);
    try std.testing.expectEqual(ra.bottom + 1, rc.top);
    try std.testing.expectEqual(rb.bottom + 1, rc.top);

    const through = win32.HTTRANSPARENT;
    const client: win32.LRESULT = win32.HTCLIENT;
    const y = @divTrunc(ra.top + ra.bottom, 2);
    const xa = @divTrunc(ra.left + ra.right, 2);
    const xb = @divTrunc(rb.left + rb.right, 2);
    for ([_]struct { *Surface, i32, i32, win32.LRESULT }{
        // Left and right of the line between a and b.
        .{ a, ra.right - 1, y, through },
        .{ a, ra.right - 3, y, through },
        .{ a, ra.right - 4, y, client },
        .{ b, rb.left, y, through },
        .{ b, rb.left + 2, y, through },
        .{ b, rb.left + 3, y, client },
        // Above and below the line over c, all along it.
        .{ a, xa, ra.bottom - 1, through },
        .{ a, xa, ra.bottom - 3, through },
        .{ a, xa, ra.bottom - 4, client },
        .{ b, xb, rb.bottom - 3, through },
        .{ c, xa, rc.top, through },
        .{ c, xb, rc.top + 2, through },
        .{ c, rc.left, rc.top + 2, through },
        .{ c, xa, rc.top + 3, client },
        // Along the window's outer edges.
        .{ a, ra.left, y, client },
        .{ a, ra.left + 2, y, client },
        .{ a, xa, ra.top, client },
        .{ b, rb.right - 1, y, client },
        .{ b, rb.right - 3, y, client },
        .{ b, xb, rb.top + 2, client },
        .{ c, rc.left, rc.bottom - 1, client },
        .{ c, xa, rc.bottom - 3, client },
        .{ c, rc.right - 1, rc.bottom - 10, client },
    }) |case| {
        try std.testing.expectEqual(case[3], try testHitTest(window, case[0], case[1], case[2]));
    }
}

test "win32: a zoomed tab, and a tab not shown, have no band" {
    // The frame draws no divider for either (`Window.layout`): a zoomed
    // terminal covers the line, and a tab not shown has none of its lines
    // in the window. Each comes back with its tab's layout.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    // Without scroll bars, which keep their pixels beside a line ("beside
    // a divider a terminal's scroll bar keeps its pixels").
    app.config.scrollbar = .never;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    const line = (try paneRect(window, a)).right;
    const y = @divTrunc((try paneRect(window, a)).bottom, 2);
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, a, line - 1, y));

    window.toggleZoom(a);
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    for ([_]i32{ line - 3, line - 1, line, line + 1, line + 3 }) |x| {
        try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, a, x, y));
    }
    window.toggleZoom(a);
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, a, line - 1, y));

    // c in a tab of its own, shown over the whole layout area.
    const c = try testTab(&app, window);
    window.selectTab(window.tabIndex(window.tabOf(c).?).?);
    try std.testing.expect(shown(c.hwnd) and !shown(a.hwnd));
    const rc = try paneRect(window, c);
    const yc = @divTrunc(rc.top + rc.bottom, 2);
    for ([_]i32{ line - 3, line - 1, line, line + 1, line + 3 }) |x| {
        try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, c, x, yc));
    }
    window.selectTab(window.tabIndex(window.tabOf(a).?).?);
    const back = (try paneRect(window, a)).right;
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, a, back - 1, yc));
}

test "win32: the band follows a new split and a DPI change" {
    // Laid out again for each hit test (`Dividers.at`): a new split's line
    // has its band at once, and at 144 DPI the line is 2 pixels and the
    // band 5 on each side, 4.5 rounded up.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    // Without scroll bars, which keep their pixels beside a line ("beside
    // a divider a terminal's scroll bar keeps its pixels").
    app.config.scrollbar = .never;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    const whole = try paneRect(window, a);
    const mid = @divTrunc(whole.left + whole.right, 2);
    const y = @divTrunc(whole.top + whole.bottom, 2);
    var x = mid - 6;
    while (x <= mid + 6) : (x += 1) {
        try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, a, x, y));
    }

    // a | b, as a split leaves it once shown (`Window.showPane`).
    const b = try testPane(&app, window);
    const row = try testRow(alloc, &.{ a, b });
    window.tab().tree.deinit();
    window.tab().tree = row;
    window.relayout();
    const ra = try paneRect(window, a);
    const rb = try paneRect(window, b);
    try std.testing.expectEqual(ra.right + 1, rb.left);
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, a, ra.right - 3, y));
    try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, a, ra.right - 4, y));
    try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, a, ra.right - 5, y));
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, b, rb.left + 2, y));
    try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, b, rb.left + 4, y));

    // The frame moved to a monitor at 144 DPI, its size kept.
    TestDpi.dpi = 144;
    var suggested = try windowRect(window.hwnd);
    _ = win32.SendMessageW(window.hwnd, win32.WM_DPICHANGED, 144 << 16 | 144, @bitCast(@intFromPtr(&suggested)));
    const wa = try paneRect(window, a);
    const wb = try paneRect(window, b);
    try std.testing.expectEqual(wa.right + 2, wb.left);
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, a, wa.right - 5, y));
    try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, a, wa.right - 6, y));
    try std.testing.expectEqual(win32.HTTRANSPARENT, try testHitTest(window, b, wb.left + 4, y));
    try std.testing.expectEqual(win32.HTCLIENT, try testHitTest(window, b, wb.left + 5, y));
}

test "win32: the frame shows the resize pointer on a divider and beside it" {
    // Over the frame itself (its own WM_SETCURSOR, wParam the frame), on a
    // line or in its band: left and right across the line between a and b,
    // up and down across the one over c (`Dividers.setCursor`). Elsewhere,
    // for the pointer over a terminal, and under a prompt (HTERROR: the
    // frame is disabled), DefWindowProcW's pointer, as before. A seam
    // stands in for GetCursorPos.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;
    defer Dividers.test_cursor_pos = null;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    const ra = try paneRect(window, a);
    const rb = try paneRect(window, b);
    const rc = try paneRect(window, c);
    const y = @divTrunc(ra.top + ra.bottom, 2);
    const xa = @divTrunc(ra.left + ra.right, 2);

    const ibeam = win32.LoadCursorW(null, win32.IDC_IBEAM).?;
    const we = win32.LoadCursorW(null, win32.IDC_SIZEWE).?;
    const ns = win32.LoadCursorW(null, win32.IDC_SIZENS).?;
    const frame = window.hwnd;
    const hterror: u16 = @bitCast(@as(i16, -2));
    // Null: neither resize pointer, whichever DefWindowProcW sets.
    for ([_]struct { win32.HWND, u16, i32, i32, ?win32.HCURSOR }{
        .{ frame, win32.HTCLIENT, ra.right - 3, y, we },
        .{ frame, win32.HTCLIENT, ra.right, y, we },
        .{ frame, win32.HTCLIENT, rb.left + 2, y, we },
        .{ frame, win32.HTCLIENT, xa, ra.bottom - 3, ns },
        .{ frame, win32.HTCLIENT, xa, ra.bottom, ns },
        .{ frame, win32.HTCLIENT, rc.right - 1, rc.top + 2, ns },
        .{ frame, win32.HTCLIENT, ra.right - 4, y, null },
        .{ frame, win32.HTCLIENT, xa, rc.top + 3, null },
        .{ a.hwnd, win32.HTCLIENT, ra.right - 1, y, null },
        .{ frame, hterror, ra.right - 1, y, null },
    }) |case| {
        _ = win32.SetCursor(ibeam);
        var pt: win32.POINT = .{ .x = case[2], .y = case[3] };
        try std.testing.expect(win32.ClientToScreen(frame, &pt).toBool());
        Dividers.test_cursor_pos = pt;
        const lparam: win32.LPARAM = (@as(win32.LPARAM, win32.WM_MOUSEMOVE) << 16) | case[1];
        _ = win32.SendMessageW(frame, win32.WM_SETCURSOR, @intFromPtr(case[0]), lparam);
        const now = win32.GetCursor();
        if (case[4]) |want| {
            try std.testing.expect(now == want);
        } else {
            try std.testing.expect(now != we and now != ns);
        }
    }
}

/// For tests: the frame's mouse message `msg` at the point `x`, `y` of
/// its client area, with the left button down but for a release, as
/// Windows sends it in a band or to the frame holding the capture.
fn testFrameMouse(window: *Window, msg: win32.UINT, x: i32, y: i32) void {
    const down: win32.WPARAM = if (msg == win32.WM_LBUTTONUP) 0 else win32.MK_LBUTTON;
    _ = win32.SendMessageW(window.hwnd, msg, down, testPoint(x, y));
}

/// For tests: a press at `x`, `y` in a band of `window`, which starts a
/// divider's drag and takes the capture.
fn testPressDivider(window: *Window, x: i32, y: i32) !void {
    testFrameMouse(window, win32.WM_LBUTTONDOWN, x, y);
    try std.testing.expect(window.divider_drag != null);
    try std.testing.expect(win32.GetCapture() == window.hwnd);
}

/// For tests: that `window` has no divider's drag, nor the capture, and
/// that a move to `x`, `y` with the button down leaves `pane` where it is.
fn testDragEnded(window: *Window, pane: *const Surface, x: i32, y: i32) !void {
    try std.testing.expect(window.divider_drag == null);
    try std.testing.expect(win32.GetCapture() != window.hwnd);
    const before = try paneRect(window, pane);
    testFrameMouse(window, win32.WM_MOUSEMOVE, x, y);
    try std.testing.expectEqual(before, try paneRect(window, pane));
}

test "win32: a divider dragged with the pointer moves the terminals beside it" {
    // (a | b) over c at 96 DPI. A press in a band takes the capture, and
    // each move puts the line as far from where it was as the pointer has
    // gone from the press, writing the split's ratio and laying the
    // terminals out at once (`Dividers.Drag`); the release's own point
    // counts, and lets the capture go. The line between a and b moves a
    // and b only; the one over c, across the other way, moves all three.
    // A press outside a band starts nothing. A resize or a DPI change
    // during a drag leaves it on.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    defer _ = win32.ReleaseCapture();
    const ra = try paneRect(window, a);
    const rb = try paneRect(window, b);
    const rc = try paneRect(window, c);
    const y = @divTrunc(ra.top + ra.bottom, 2);
    const tree = &window.tab().tree;
    const row = tree.nodes[Window.Tree.Node.Handle.root.idx()].split.left;

    // Pressed 2 pixels left of the line, in a's pixels of the band; moved
    // 40 right, then 30 left of the press, a little lower.
    const x = ra.right - 2;
    try testPressDivider(window, x, y);
    testFrameMouse(window, win32.WM_MOUSEMOVE, x + 40, y);
    try std.testing.expectEqual(ra.right + 40, (try paneRect(window, a)).right);
    try std.testing.expectEqual(win32.RECT{
        .left = rb.left + 40,
        .top = rb.top,
        .right = rb.right,
        .bottom = rb.bottom,
    }, try paneRect(window, b));
    try std.testing.expectEqual(rc, try paneRect(window, c));
    testFrameMouse(window, win32.WM_MOUSEMOVE, x - 30, y + 7);
    try std.testing.expectEqual(ra.right - 30, (try paneRect(window, a)).right);
    try std.testing.expectEqual(rb.left - 30, (try paneRect(window, b)).left);
    try std.testing.expectEqual(ra.bottom, (try paneRect(window, a)).bottom);

    // Released 50 right of the press: the line there, its ratio written,
    // the capture let go; a move after it moves nothing.
    testFrameMouse(window, win32.WM_LBUTTONUP, x + 50, y);
    try std.testing.expect(window.divider_drag == null);
    try std.testing.expect(win32.GetCapture() == null);
    const moved = try paneRect(window, a);
    try std.testing.expectEqual(ra.right + 50, moved.right);
    try std.testing.expectEqual(rb.left + 50, (try paneRect(window, b)).left);
    const rest = rb.right - ra.left - 1;
    try std.testing.expectEqual(moved.right - moved.left, Window.firstExtent(rest, tree.nodes[row.idx()].split.ratio));
    testFrameMouse(window, win32.WM_MOUSEMOVE, x + 90, y);
    try std.testing.expectEqual(moved, try paneRect(window, a));

    // The line over c, pressed on it and moved 30 up: a and b end higher,
    // c starts higher, and the line between a and b stays.
    const xa = @divTrunc(moved.left + moved.right, 2);
    try testPressDivider(window, xa, ra.bottom);
    testFrameMouse(window, win32.WM_MOUSEMOVE, xa + 9, ra.bottom - 30);
    testFrameMouse(window, win32.WM_LBUTTONUP, xa + 9, ra.bottom - 30);
    try std.testing.expectEqual(win32.RECT{
        .left = moved.left,
        .top = moved.top,
        .right = moved.right,
        .bottom = ra.bottom - 30,
    }, try paneRect(window, a));
    try std.testing.expectEqual(rb.bottom - 30, (try paneRect(window, b)).bottom);
    try std.testing.expectEqual(win32.RECT{
        .left = rc.left,
        .top = rc.top - 30,
        .right = rc.right,
        .bottom = rc.bottom,
    }, try paneRect(window, c));
    try std.testing.expect(win32.GetCapture() == null);

    // A press 4 pixels left of the line between a and b, past its band.
    const now = try paneRect(window, a);
    testFrameMouse(window, win32.WM_LBUTTONDOWN, now.right - 4, y);
    try std.testing.expect(window.divider_drag == null);
    try std.testing.expect(win32.GetCapture() == null);
    testFrameMouse(window, win32.WM_MOUSEMOVE, now.right + 40, y);
    try std.testing.expectEqual(now, try paneRect(window, a));

    // A resize and a DPI change during a drag leave it on, and the line
    // still goes where the pointer puts it, 2 pixels wide at 144 DPI.
    try testPressDivider(window, now.right, y);
    testResize(window, 500, 300);
    testFrameMouse(window, win32.WM_MOUSEMOVE, now.right + 20, y);
    try std.testing.expectEqual(now.right + 20, (try paneRect(window, a)).right);
    TestDpi.dpi = 144;
    defer TestDpi.dpi = 96;
    var suggested = try windowRect(window.hwnd);
    _ = win32.SendMessageW(window.hwnd, win32.WM_DPICHANGED, 144 << 16 | 144, @bitCast(@intFromPtr(&suggested)));
    try std.testing.expect(window.divider_drag != null);
    testFrameMouse(window, win32.WM_MOUSEMOVE, now.right + 30, y);
    try std.testing.expectEqual(now.right + 30, (try paneRect(window, a)).right);
    try std.testing.expectEqual(now.right + 32, (try paneRect(window, b)).left);
    testFrameMouse(window, win32.WM_LBUTTONUP, now.right + 30, y);
    try std.testing.expect(win32.GetCapture() == null);
}

test "win32: a dragged divider stops at a pixel for each terminal beyond it" {
    // Without a core a terminal's least is a pixel, as `adopt` keeps it
    // (`Window.cellExtent`). In a | b | c the line after a stops a pixel
    // from the window's left edge, and, dragged right, where b, c and the
    // line between them take three. In (d | e) over f the line over f
    // stops a pixel below the top, d and e side by side needing a pixel
    // each down, and a pixel above the bottom. In g | h | i, with the line
    // between h and i dragged to its right stop first, which leaves i a
    // pixel at a ratio near 1, the line after g, dragged right, stops where
    // h and i keep a pixel each at that ratio: a pixel further, i would
    // have none.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    // Without scroll bars, which keep their pixels beside a line ("beside
    // a divider a terminal's scroll bar keeps its pixels").
    app.config.scrollbar = .never;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const row = try testFrame(&app);
    testResize(row, 400, 300);
    const a = try testPane(&app, row);
    const b = try testPane(&app, row);
    const c = try testPane(&app, row);
    row.tab().tree = try testRow(alloc, &.{ a, b, c });
    row.tab().focused = a;
    row.relayout();
    _ = win32.ShowWindow(row.hwnd, win32.SW_SHOWNOACTIVATE);
    defer _ = win32.ReleaseCapture();
    const client = row.layoutArea() orelse return error.TestUnexpectedResult;
    const ra = try paneRect(row, a);
    const y = @divTrunc(ra.top + ra.bottom, 2);

    try testPressDivider(row, ra.right, y);
    testFrameMouse(row, win32.WM_MOUSEMOVE, -1000, y);
    try std.testing.expectEqual(win32.RECT{
        .left = client.left,
        .top = ra.top,
        .right = client.left + 1,
        .bottom = ra.bottom,
    }, try paneRect(row, a));
    testFrameMouse(row, win32.WM_MOUSEMOVE, 5000, y);
    const rb = try paneRect(row, b);
    const rc = try paneRect(row, c);
    try std.testing.expectEqual(1, rb.right - rb.left);
    try std.testing.expectEqual(1, rc.right - rc.left);
    try std.testing.expectEqual(client.right, rc.right);
    try std.testing.expectEqual(rb.right + 1, rc.left);
    try std.testing.expectEqual((try paneRect(row, a)).right + 1, rb.left);
    testFrameMouse(row, win32.WM_LBUTTONUP, 5000, y);

    const column = try testFrame(&app);
    testResize(column, 400, 300);
    const d = try testPane(&app, column);
    const e = try testPane(&app, column);
    const f = try testPane(&app, column);
    try testSplits(column, d, e, f);
    _ = win32.ShowWindow(column.hwnd, win32.SW_SHOWNOACTIVATE);
    const area = column.layoutArea() orelse return error.TestUnexpectedResult;
    const rd = try paneRect(column, d);
    const x = @divTrunc(rd.left + rd.right, 2);
    try testPressDivider(column, x, rd.bottom);
    testFrameMouse(column, win32.WM_MOUSEMOVE, x, -1000);
    try std.testing.expectEqual(area.top + 1, (try paneRect(column, d)).bottom);
    try std.testing.expectEqual(area.top + 1, (try paneRect(column, e)).bottom);
    try std.testing.expectEqual(area.top + 2, (try paneRect(column, f)).top);
    testFrameMouse(column, win32.WM_MOUSEMOVE, x, 5000);
    try std.testing.expectEqual(area.bottom - 1, (try paneRect(column, f)).top);
    try std.testing.expectEqual(area.bottom, (try paneRect(column, f)).bottom);
    testFrameMouse(column, win32.WM_LBUTTONUP, x, 5000);
    try std.testing.expect(win32.GetCapture() == null);

    const nested = try testFrame(&app);
    testResize(nested, 400, 300);
    const g = try testPane(&app, nested);
    const h = try testPane(&app, nested);
    const i = try testPane(&app, nested);
    nested.tab().tree = try testRow(alloc, &.{ g, h, i });
    nested.tab().focused = g;
    nested.relayout();
    _ = win32.ShowWindow(nested.hwnd, win32.SW_SHOWNOACTIVATE);
    const yn = @divTrunc((try paneRect(nested, g)).top + (try paneRect(nested, g)).bottom, 2);
    const right = nested.tab().tree.nodes[Window.Tree.Node.Handle.root.idx()].split.right;

    // The line between h and i to its right stop: i a pixel wide.
    try testPressDivider(nested, (try paneRect(nested, h)).right, yn);
    testFrameMouse(nested, win32.WM_LBUTTONUP, 5000, yn);
    try std.testing.expectEqual(1, (try paneRect(nested, i)).right - (try paneRect(nested, i)).left);
    const ratio = nested.tab().tree.nodes[right.idx()].split.ratio;
    try std.testing.expect(ratio > 0.9);

    // The line after g to its right stop, then its left one.
    try testPressDivider(nested, (try paneRect(nested, g)).right, yn);
    testFrameMouse(nested, win32.WM_MOUSEMOVE, 5000, yn);
    const ri = try paneRect(nested, i);
    const rh = try paneRect(nested, h);
    try std.testing.expect(rh.right - rh.left >= 1);
    try std.testing.expectEqual(1, ri.right - ri.left);
    try std.testing.expectEqual(rh.right + 1, ri.left);
    try std.testing.expectEqual((try paneRect(nested, g)).right + 1, rh.left);
    // A pixel further, h and i would share a pixel less at that ratio,
    // which leaves i none.
    const less = ri.right - rh.left - 2;
    try std.testing.expectEqual(less, Window.firstExtent(less, ratio));
    testFrameMouse(nested, win32.WM_MOUSEMOVE, -1000, yn);
    try std.testing.expectEqual(1, (try paneRect(nested, g)).right - (try paneRect(nested, g)).left);
    try std.testing.expect((try paneRect(nested, i)).right - (try paneRect(nested, i)).left >= 1);
    testFrameMouse(nested, win32.WM_LBUTTONUP, -1000, yn);
    try std.testing.expect(win32.GetCapture() == null);
}

test "win32: a divider drag ends with a lost capture or a change of its tab" {
    // Each lets go of the capture if the frame still has it, and the
    // moves after it move nothing: another window taking the capture, a
    // prompt disabling the frame (WM_CANCELMODE), a move without the
    // button, a zoom, the tab's splits equalized or resized, a terminal
    // closing, a new split, the tab hidden, and the tab moved to another
    // window (`Dividers.tabChanged`). While the
    // core may not be re-entered a move lays nothing out, and the drag
    // goes on after. A tab added and not shown leaves the drag alone, and
    // so does a change of its tree.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    defer _ = win32.ReleaseCapture();
    const line = (try paneRect(window, a)).right;
    const y = @divTrunc((try paneRect(window, a)).top + (try paneRect(window, a)).bottom, 2);

    // Another window takes the capture.
    try testPressDivider(window, line, y);
    testFrameMouse(window, win32.WM_MOUSEMOVE, line + 10, y);
    try std.testing.expectEqual(line + 10, (try paneRect(window, a)).right);
    _ = win32.SetCapture(a.hwnd);
    try testDragEnded(window, a, line + 40, y);
    _ = win32.ReleaseCapture();

    // A prompt opens: every frame is disabled, which cancels the capture.
    try testPressDivider(window, line + 10, y);
    app.beginPrompt(null);
    try testDragEnded(window, a, line + 40, y);
    app.endPrompt();
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());

    // A move without the button down, after a release unseen.
    try testPressDivider(window, line + 10, y);
    _ = win32.SendMessageW(window.hwnd, win32.WM_MOUSEMOVE, 0, testPoint(line + 20, y));
    try testDragEnded(window, a, line + 40, y);

    // While the core may not be re-entered, as under a prompt the frame
    // did not see, the line waits; then it follows.
    try testPressDivider(window, line + 10, y);
    app.prompt_depth = 1;
    testFrameMouse(window, win32.WM_MOUSEMOVE, line + 30, y);
    try std.testing.expectEqual(line + 10, (try paneRect(window, a)).right);
    app.prompt_depth = 0;
    testFrameMouse(window, win32.WM_MOUSEMOVE, line + 30, y);
    try std.testing.expectEqual(line + 30, (try paneRect(window, a)).right);
    testFrameMouse(window, win32.WM_MOUSEMOVE, line, y);

    // A zoom; in the zoomed tab a press starts nothing.
    window.toggleZoom(a);
    try testDragEnded(window, a, line + 40, y);
    testFrameMouse(window, win32.WM_LBUTTONDOWN, line, y);
    try std.testing.expect(window.divider_drag == null);
    try std.testing.expect(win32.GetCapture() == null);
    window.toggleZoom(a);
    try std.testing.expectEqual(line, (try paneRect(window, a)).right);

    // With the line moved off centre, the tab's splits equalized, then
    // resized (`Window.adopt`), then equalized again.
    try testPressDivider(window, line, y);
    testFrameMouse(window, win32.WM_LBUTTONUP, line + 30, y);
    try testPressDivider(window, line + 30, y);
    window.equalize(a);
    try testDragEnded(window, a, line + 40, y);
    try std.testing.expectEqual(line, (try paneRect(window, a)).right);
    try testPressDivider(window, line, y);
    window.resizeSplit(a, .{ .amount = 20, .direction = .right });
    try testDragEnded(window, a, line + 40, y);
    try std.testing.expect((try paneRect(window, a)).right > line);
    window.equalize(a);
    try std.testing.expectEqual(line, (try paneRect(window, a)).right);

    // c closes.
    try testPressDivider(window, line, y);
    try std.testing.expect(c.destroy());
    try testDragEnded(window, a, line + 40, y);

    // d split off below a by `Window.split`, its terminal made without a
    // core (`Window.test_create_pane`), and shown, as `App.newSplit` shows
    // it. The split reads a's cell, which a core would have.
    const Panes = struct {
        fn create(w: *Window) anyerror!*Surface {
            return testPane(w.app, w);
        }
    };
    Window.test_create_pane = &Panes.create;
    defer Window.test_create_pane = null;
    a.core_surface.size.cell = .{ .width = 1, .height = 1 };
    try testPressDivider(window, line, y);
    const d = try window.split(a, .down, .{});
    window.showPane(d);
    try std.testing.expect(window.tab().tree.locate(d) != null);
    try testDragEnded(window, a, line + 40, y);

    // A tab added and not shown leaves the drag, and so does a change of
    // that tab's tree; the tab hidden ends it.
    try testPressDivider(window, line, y);
    const e = try testTab(&app, window);
    window.equalize(e);
    try std.testing.expect(window.divider_drag != null);
    testFrameMouse(window, win32.WM_MOUSEMOVE, line + 5, y);
    const ya = @divTrunc((try paneRect(window, a)).top + (try paneRect(window, a)).bottom, 2);
    try std.testing.expectEqual(line + 5, (try paneRect(window, a)).right);
    window.selectTab(1);
    try testDragEnded(window, e, line + 40, ya);
    window.selectTab(0);

    // The tab moved to a window of its own.
    try testPressDivider(window, line + 5, ya);
    const to = try testFrame(&app);
    try std.testing.expect(try window.moveTabTo(0, to) == .whole);
    try std.testing.expect(window.tab().focused == e);
    try testDragEnded(window, e, line + 40, ya);
    try std.testing.expect(to.divider_drag == null);
}

test "win32: a double click on a divider equalizes the tab's splits" {
    // The frame's class has CS_DBLCLKS, so that the second press of a
    // double click in a band comes as WM_LBUTTONDBLCLK: each split of the
    // shown tab then gets its share (`Window.equalizeTab`). Not outside a
    // band, not for another button's double click, not in a zoomed tab,
    // nor while the core may not be re-entered.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    try std.testing.expect(win32.GetClassLongW(window.hwnd, win32.GCL_STYLE) & win32.CS_DBLCLKS != 0);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    defer _ = win32.ReleaseCapture();
    const equal_a = try paneRect(window, a);
    const equal_c = try paneRect(window, c);
    const y = @divTrunc(equal_a.top + equal_a.bottom, 2);
    const x = @divTrunc(equal_a.left + equal_a.right, 2);

    // Both lines dragged off the middle.
    const Lines = struct {
        fn offCentre(w: *Window, pa: *const Surface, at_y: i32, at_x: i32) !void {
            const ra = try paneRect(w, pa);
            try testPressDivider(w, ra.right, at_y);
            testFrameMouse(w, win32.WM_LBUTTONUP, ra.right + 60, at_y);
            try testPressDivider(w, at_x, ra.bottom);
            testFrameMouse(w, win32.WM_LBUTTONUP, at_x, ra.bottom - 40);
        }
    };
    try Lines.offCentre(window, a, y, x);
    const off = try paneRect(window, a);
    try std.testing.expectEqual(equal_a.right + 60, off.right);
    try std.testing.expectEqual(equal_a.bottom - 40, off.bottom);

    // Outside a band, other buttons in it, and under a prompt: nothing.
    testFrameMouse(window, win32.WM_LBUTTONDBLCLK, off.right - 4, y);
    for ([_]win32.UINT{ win32.WM_MBUTTONDBLCLK, win32.WM_RBUTTONDBLCLK, win32.WM_XBUTTONDBLCLK }) |msg| {
        _ = win32.SendMessageW(window.hwnd, msg, 0, testPoint(off.right, y));
    }
    app.prompt_depth = 1;
    testFrameMouse(window, win32.WM_LBUTTONDBLCLK, off.right, y);
    app.prompt_depth = 0;
    try std.testing.expectEqual(off, try paneRect(window, a));
    try std.testing.expect(window.divider_drag == null);
    try std.testing.expect(win32.GetCapture() == null);

    // In the band of the line between a and b: both lines in the middle
    // again, a and b as wide, and a, b and c as high, as before the drags.
    testFrameMouse(window, win32.WM_LBUTTONDBLCLK, off.right + 2, y);
    try std.testing.expectEqual(equal_a, try paneRect(window, a));
    try std.testing.expectEqual(equal_c, try paneRect(window, c));
    try std.testing.expect(window.divider_drag == null);
    try std.testing.expect(win32.GetCapture() == null);

    // Off again; the line over c's band, below it, does as much.
    try Lines.offCentre(window, a, y, x);
    testFrameMouse(window, win32.WM_LBUTTONDBLCLK, x, (try paneRect(window, c)).top + 2);
    try std.testing.expectEqual(equal_a, try paneRect(window, a));

    // Zoomed: no band, so nothing; unzoomed, the lines where they were.
    try Lines.offCentre(window, a, y, x);
    const before = try paneRect(window, a);
    window.toggleZoom(a);
    testFrameMouse(window, win32.WM_LBUTTONDBLCLK, before.right, y);
    window.toggleZoom(a);
    try std.testing.expectEqual(before, try paneRect(window, a));
}

/// For tests: the wheel messages the terminals' windows get, recorded by a
/// subclass of each window `watch` is given, which passes every message on
/// to the terminal's own procedure, but for a wheel that comes while one is
/// being handled: a terminal with no core passes its wheel up to the
/// frame, so a frame that sent it back would loop until the stack
/// overflowed. That one is recorded and goes no further, and the loop
/// shows as a second wheel.
const TestWheels = struct {
    const Got = struct { hwnd: win32.HWND, msg: win32.UINT };

    /// The terminals' class procedure, the one each subclassed window had.
    var proc: ?win32.WNDPROC = null;
    var got: [8]Got = undefined;
    var len: usize = 0;
    var depth: usize = 0;

    fn watch(surface: *const Surface) void {
        const old = win32.SetWindowLongPtrW(surface.hwnd, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&wndProc)));
        if (proc == null) proc = @ptrFromInt(@as(usize, @bitCast(old)));
    }

    fn wndProc(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        const is_wheel = msg == win32.WM_MOUSEWHEEL or msg == win32.WM_MOUSEHWHEEL;
        if (is_wheel) {
            if (len < got.len) {
                got[len] = .{ .hwnd = hwnd, .msg = msg };
                len += 1;
            }
            if (depth > 0) return 0;
            depth += 1;
        }
        defer if (is_wheel) {
            depth -= 1;
        };
        return win32.CallWindowProcW(proc.?, hwnd, msg, wparam, lparam);
    }

    /// That the watched terminals got `msg`, each of `to` once and in that
    /// order, since the last call, and nothing else; then forget them.
    fn expect(msg: win32.UINT, to: []const *const Surface) !void {
        defer len = 0;
        try std.testing.expectEqual(to.len, len);
        for (to, got[0..len]) |surface, g| {
            try std.testing.expect(surface.hwnd == g.hwnd);
            try std.testing.expectEqual(msg, g.msg);
        }
    }
};

/// For tests: the wheel message `msg`, a notch away from the user, sent to
/// `to` at the point `x`, `y` of `window`'s client area, with the point on
/// the screen as Windows sends it.
fn testWheelAt(to: win32.HWND, window: *const Window, msg: win32.UINT, x: i32, y: i32) !void {
    var pt: win32.POINT = .{ .x = x, .y = y };
    if (!win32.ClientToScreen(window.hwnd, &pt).toBool()) return error.TestUnexpectedResult;
    _ = win32.SendMessageW(to, msg, testWheel(120), testPoint(pt.x, pt.y));
}

test "win32: a wheel in a divider's band goes on to the terminal there" {
    // (a | b) over c at 96 DPI. In a band the terminal under the pointer
    // lets it through to the frame, which gets the wheel: the frame passes
    // both wheels on to the terminal whose rect holds the point, once,
    // though a terminal with no core passes its wheel back up to the frame
    // (DefWindowProcW). On a line, which no terminal holds, no terminal
    // gets it; nor outside the bands, where a terminal's own wheel comes
    // up to the frame and is not sent back; nor in a zoomed tab or from a
    // tab not shown.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    for ([_]*Surface{ a, b, c }) |pane| TestWheels.watch(pane);
    TestWheels.len = 0;
    const ra = try paneRect(window, a);
    const rc = try paneRect(window, c);
    const line = ra.right;
    const y = @divTrunc(ra.top + ra.bottom, 2);
    const x = @divTrunc(ra.left + ra.right, 2);
    const frame = window.hwnd;

    for ([_]win32.UINT{ win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL }) |msg| {
        // In a's pixels of the band of the line between a and b, then in
        // b's; above and below the line over c.
        try testWheelAt(frame, window, msg, line - 2, y);
        try TestWheels.expect(msg, &.{a});
        try testWheelAt(frame, window, msg, line + 3, y);
        try TestWheels.expect(msg, &.{b});
        try testWheelAt(frame, window, msg, x, ra.bottom - 1);
        try TestWheels.expect(msg, &.{a});
        try testWheelAt(frame, window, msg, x, rc.top + 2);
        try TestWheels.expect(msg, &.{c});

        // On either line.
        try testWheelAt(frame, window, msg, line, y);
        try TestWheels.expect(msg, &.{});
        try testWheelAt(frame, window, msg, x, ra.bottom);
        try TestWheels.expect(msg, &.{});

        // Outside the bands: sent to the frame, and sent to a, as Windows
        // sends it there.
        try testWheelAt(frame, window, msg, line - 10, y);
        try TestWheels.expect(msg, &.{});
        try testWheelAt(a.hwnd, window, msg, line - 10, y);
        try TestWheels.expect(msg, &.{a});
    }

    // Zoomed to a: no band.
    window.toggleZoom(a);
    try testWheelAt(frame, window, win32.WM_MOUSEWHEEL, line - 2, y);
    try TestWheels.expect(win32.WM_MOUSEWHEEL, &.{});
    window.toggleZoom(a);

    // Another tab shown alone: the hidden tab's bands are gone with it.
    const e = try testTab(&app, window);
    window.selectTab(1);
    TestWheels.watch(e);
    try testWheelAt(frame, window, win32.WM_MOUSEWHEEL, line - 2, y);
    try TestWheels.expect(win32.WM_MOUSEWHEEL, &.{});
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
    window.tab().tree = try testRow(alloc, &.{ left, right });

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
    window.tab().tree = try testRow(alloc, &.{ left, right });
    window.tab().focused = left;

    // A left button press on the client area; the hidden frame is not the
    // active window.
    const lparam: win32.LPARAM = (@as(win32.LPARAM, win32.WM_LBUTTONDOWN) << 16) | win32.HTCLIENT;
    try std.testing.expectEqual(
        win32.MA_ACTIVATEANDEAT,
        Surface.wndProc(right.hwnd, win32.WM_MOUSEACTIVATE, @intFromPtr(window.hwnd), lparam),
    );
    try std.testing.expect(window.tab().focused == right);
}

/// For tests: a tab of its own in `window` for a new terminal, as
/// `Window.newTab` makes one, not shown.
fn testTab(app: *App, window: *Window) !*Surface {
    const pane = try testPane(app, window);
    _ = try window.insertTab(pane);
    return pane;
}

test "win32: new_tab and goto_tab wait for run, and a tab shows alone" {
    // A binding performs both inside the core's key callback, and showing a
    // tab lays terminals out and moves the focus, so both are recorded and
    // made by createRequested. A new tab goes after the shown one, or at
    // the end; goto_tab goes as GTK's does.
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
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    try std.testing.expect(a.setTitle("a"));

    // Recorded. Behind it, with one tab, a goto_tab or move_tab is
    // recorded too, to be made among the tabs there will be; here as if
    // run had made it, by a tab added as newTab adds one.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .new_tab, {}));
    try std.testing.expect(app.requests.items[0] == .tab);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab, .{ .amount = -1 }));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_tab, .previous));
    try std.testing.expectEqual(3, app.requests.items.len);
    const n = try testTab(&app, window);
    window.selectTab(window.tabIndex(window.tabOf(n).?).?);
    app.requests.items[0] = .dropped;
    app.createRequested();
    // a, n; a moved back by one wraps round to n, a; and n's previous is a.
    try std.testing.expectEqual(window.tabOf(n).?, window.tabs.items[0]);
    try std.testing.expectEqual(window.tabOf(a).?, window.tab());
    try std.testing.expect(n.destroy());
    try std.testing.expectEqual(1, window.tabs.items.len);

    // After the shown tab; at the end with `window-new-tab-position = end`.
    const b = try testTab(&app, window);
    const c = try testTab(&app, window);
    try std.testing.expectEqual(2, window.tabIndex(window.tabOf(b).?).?);
    try std.testing.expectEqual(1, window.tabIndex(window.tabOf(c).?).?);
    app.config.@"window-new-tab-position" = .end;
    const d = try testTab(&app, window);
    try std.testing.expectEqual(3, window.tabIndex(window.tabOf(d).?).?);
    try std.testing.expect(b.setTitle("b"));

    // A program does not resize a window of several tabs for its terminal,
    // alone in its tab as it is: the others would change too.
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .resize_window, .{ .width = 300, .height = 200 }));

    // One tab shows: its terminal laid out, the others hidden, and the
    // window titled after it.
    try std.testing.expect(shown(a.hwnd));
    try std.testing.expect(!shown(b.hwnd));
    var buf: [64]u16 = undefined;
    const goto = struct {
        fn f(app_: *App, from: *Surface, to: apprt.action.GotoTab) !bool {
            const performed = try app_.performAction(.{ .surface = &from.core_surface }, .goto_tab, to);
            if (performed) {
                try std.testing.expectEqual(from.window.tab(), from.window.tabOf(from).?);
                app_.createRequested();
            }
            return performed;
        }
    }.f;
    try std.testing.expect(try goto(&app, a, .last));
    try std.testing.expectEqual(d, window.tab().focused.?);
    try std.testing.expect(try goto(&app, d, .next));
    try std.testing.expectEqual(a, window.tab().focused.?);
    try std.testing.expect(try goto(&app, a, .previous));
    try std.testing.expectEqual(d, window.tab().focused.?);
    try std.testing.expect(try goto(&app, d, @fromBackingInt(@intCast(3))));
    try std.testing.expectEqual(b, window.tab().focused.?);
    try std.testing.expect(shown(b.hwnd));
    try std.testing.expect(!shown(a.hwnd));
    try std.testing.expect(!shown(d.hwnd));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("b"), testCaption(window, &buf));

    // An index past the last goes to the last; the shown tab, or 0, is
    // not performed, so the key reaches the terminal.
    try std.testing.expect(try goto(&app, b, @fromBackingInt(@intCast(99))));
    try std.testing.expectEqual(d, window.tab().focused.?);
    try std.testing.expect(!try goto(&app, d, .last));
    try std.testing.expect(!try goto(&app, d, @fromBackingInt(@intCast(0))));
    try std.testing.expect(!try goto(&app, d, @fromBackingInt(@intCast(4))));

    // A closing terminal drops its own.
    try std.testing.expect(try app.performAction(.{ .surface = &d.core_surface }, .goto_tab, .next));
    try std.testing.expect(try app.performAction(.{ .surface = &d.core_surface }, .new_tab, {}));
    try std.testing.expect(try app.performAction(.{ .surface = &d.core_surface }, .move_tab, .{ .amount = 1 }));
    try std.testing.expect(app.requests.items[2] == .move_tab);
    app.forgetClosing(&d.core_surface);
    for (app.requests.items) |request| try std.testing.expect(request == .dropped);
}

test "win32: move_tab, set_tab_title and a tab's last terminal" {
    // move_tab and set_tab_title are made at once: only the order and the
    // titles change. A tab whose last terminal closes goes with it, the one
    // after it shown in its place, or the one before; a terminal closing
    // in a hidden tab leaves the shown one as it is.
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
    const a2 = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, a2 });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    try std.testing.expect(a.setTitle("a"));

    // One tab: nothing to move.
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .move_tab, .{ .amount = 1 }));

    const b = try testTab(&app, window);
    const c = try testTab(&app, window);
    const ta = window.tabOf(a).?;
    const tb = window.tabOf(b).?;
    const tc = window.tabOf(c).?;
    // a, c, b; moved by one it is c, a, b, and wraps round to c, b, a.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab, .{ .amount = 1 }));
    try std.testing.expectEqualSlices(*Window.Tab, &.{ tc, ta, tb }, window.tabs.items);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab, .{ .amount = -2 }));
    try std.testing.expectEqualSlices(*Window.Tab, &.{ tc, tb, ta }, window.tabs.items);
    // The shown tab is still a's.
    try std.testing.expectEqual(ta, window.tab());

    // A title of its own, shown in place of the terminal's, and gone when
    // it is empty; one for a hidden tab changes no caption.
    var buf: [64]u16 = undefined;
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .set_tab_title, .{ .title = "build" }));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("build"), testCaption(window, &buf));
    try std.testing.expect(a.setTitle("vim"));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("build"), testCaption(window, &buf));
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .set_tab_title, .{ .title = "logs" }));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("build"), testCaption(window, &buf));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .set_tab_title, .{ .title = "" }));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("vim"), testCaption(window, &buf));

    // A terminal closing in a hidden tab leaves the shown one as it is.
    window.selectTab(window.tabIndex(tc).?);
    try std.testing.expect(a2.destroy());
    try std.testing.expectEqual(tc, window.tab());
    try std.testing.expectEqual(c, window.tab().focused.?);
    try std.testing.expectEqual(a, ta.focused.?);
    try std.testing.expect(!shown(a.hwnd));

    // The shown tab's last terminal: the one after it shows, here a's;
    // then the last tab's: the one before it, c's. Each shown is captioned
    // with its own title.
    window.selectTab(window.tabIndex(tb).?);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("logs"), testCaption(window, &buf));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .set_tab_title, .{ .title = "edit" }));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("logs"), testCaption(window, &buf));
    // As `b.destroy()` takes its tab out before its core stops: hidden
    // then, the next tab shown first. Freed with the frame.
    window.removeTab(tb);
    try std.testing.expect(!shown(b.hwnd));
    try std.testing.expectEqualSlices(*Window.Tab, &.{ tc, ta }, window.tabs.items);
    try std.testing.expectEqual(ta, window.tab());
    try std.testing.expect(shown(a.hwnd));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("edit"), testCaption(window, &buf));
    try std.testing.expect(a.destroy());
    try std.testing.expectEqualSlices(*Window.Tab, &.{tc}, window.tabs.items);
    try std.testing.expectEqual(c, window.tab().focused.?);
    try std.testing.expect(shown(c.hwnd));
}

test "win32: a terminal in a hidden tab acts in its own tab" {
    // An `all:` binding performs an action on every terminal, those in
    // hidden tabs too (`CoreApp.performAllAction`), and a request made
    // before a goto_tab is made after it. Each acts in the terminal's own
    // tab, which stays hidden, as GTK's do; a toast's click shows it.
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
    const a2 = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, a2 });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    try std.testing.expect(a.setTitle("a"));
    const ta = window.tab();

    const b = try testTab(&app, window);
    const b2 = try testPane(&app, window);
    const b3 = try testPane(&app, window);
    const tb = window.tabOf(b).?;
    tb.tree.deinit();
    tb.tree = try testRow(alloc, &.{ b, b2, b3 });

    // A lone terminal in a hidden tab has no split to zoom or resize,
    // whatever the shown tab has.
    const c = try testTab(&app, window);
    try std.testing.expect(!try app.performAction(.{ .surface = &c.core_surface }, .toggle_split_zoom, {}));
    try std.testing.expect(!try app.performAction(.{ .surface = &c.core_surface }, .resize_split, .{ .amount = 10, .direction = .right }));

    // A focus move in the shown tab waits for the key callback to return;
    // one left when the tab is hidden is dropped, and a closing terminal
    // drops its own in any tab. A target is live only while it is chosen:
    // a hidden one would be told its occlusion.
    a2.core_state = .live;
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .next));
    a2.core_state = .none;
    try std.testing.expectEqual(a2, ta.pending_focus.?);
    window.selectTab(window.tabIndex(tb).?);
    try std.testing.expect(ta.pending_focus == null);
    ta.pending_focus = a2;
    app.forgetClosing(&a2.core_surface);
    try std.testing.expect(ta.pending_focus == null);
    window.selectTab(window.tabIndex(ta).?);
    // Its place under the tab bar, which three tabs show.
    const a_rect = try paneRect(window, a);
    try std.testing.expect(a_rect.top > 0);

    // A terminal of the hidden tab given the focus is that tab's, and
    // retitles nothing.
    var buf: [64]u16 = undefined;
    window.setFocused(b2);
    try std.testing.expectEqual(b2, tb.focused.?);
    try std.testing.expectEqual(a, ta.focused.?);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("a"), testCaption(window, &buf));

    // Equalized, zoomed and moved in its own tab, which stays hidden; the
    // shown tab is as it was. A move queued behind a request starts from
    // the tab's focused terminal; one made at once from a hidden terminal
    // ends its tab's zoom, as one in the shown tab would.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .equalize_splits, {}));
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_split_zoom, {}));
    app.createRequested();
    try std.testing.expectEqual(tb.tree.locate(b2), tb.tree.zoomed);
    try std.testing.expectEqual(null, ta.tree.zoomed);
    try std.testing.expectEqual(ta, window.tab());
    try std.testing.expect(!shown(b2.hwnd));

    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_split_zoom, {}));
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .goto_split, .next));
    b3.core_state = .live;
    app.createRequested();
    b3.core_state = .none;
    try std.testing.expectEqual(null, tb.tree.zoomed);
    try std.testing.expectEqual(b3, tb.focused.?);
    try std.testing.expectEqual(ta, window.tab());
    try std.testing.expect(!shown(b3.hwnd));

    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_split_zoom, {}));
    app.createRequested();
    try std.testing.expectEqual(tb.tree.locate(b3), tb.tree.zoomed);
    b.core_state = .live;
    try std.testing.expect(try app.performAction(.{ .surface = &b3.core_surface }, .goto_split, .next));
    b.core_state = .none;
    try std.testing.expectEqual(b, tb.focused.?);
    try std.testing.expect(tb.pending_focus == null);
    try std.testing.expectEqual(null, tb.tree.zoomed);
    try std.testing.expectEqual(ta, window.tab());
    try std.testing.expectEqual(a_rect, try paneRect(window, a));

    // A split from a hidden terminal goes in its own tab, in the place
    // its terminal has there, as the tab shows it below.
    const b_place = window.tiledPlace(b).?;

    // A toast's click shows the tab with its terminal focused.
    window.focusFromGoto(b);
    try std.testing.expectEqual(tb, window.tab());
    try std.testing.expectEqual(b, tb.focused.?);
    try std.testing.expectEqual(a, ta.focused.?);
    try std.testing.expect(shown(b.hwnd));
    try std.testing.expect(!shown(a.hwnd));
    try std.testing.expectEqual(b_place, try paneRect(window, b));
    // Equalized while hidden.
    const width = struct {
        fn width(w: *const Window, pane: *const Surface) !i32 {
            const r = try paneRect(w, pane);
            return r.right - r.left;
        }
    }.width;
    try expectNear(try width(window, b), try width(window, b2));
    try expectNear(try width(window, b2), try width(window, b3));

    // Minimized, a new terminal takes the place the shown tab's keep, not
    // the frame's empty client area.
    window.selectTab(window.tabIndex(ta).?);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMINNOACTIVE);
    try std.testing.expect(win32.IsIconic(window.hwnd).toBool());
    try std.testing.expectEqual(a_rect, window.tiledPlace(a).?);
}

test "win32: move_tab_to_new_window waits for run, and only with another tab" {
    // As on GTK: not performed for the app, nor for a window's only tab,
    // so that a key reaches the terminal; else recorded, since a binding
    // performs it inside the core's key callback, and made by
    // createRequested, which looks the tab up again: dropped when its
    // terminal begins to close, and nothing while the terminal or its
    // window is closing, or once the window has no other tab.
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
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    try std.testing.expect(!try app.performAction(.app, .move_tab_to_new_window, {}));
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Behind a tab still to open there, as one binding chains them, it is
    // recorded, to be made among the tabs there will be.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .new_tab, {}));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    try std.testing.expectEqual(2, app.requests.items.len);
    try std.testing.expect(app.requests.items[1] == .move_tab_to_new_window);
    app.requests.clearRetainingCapacity();

    const b = try testTab(&app, window);
    window.selectTab(window.tabIndex(window.tabOf(b).?).?);

    // Recorded, not made: the terminal is still in its window.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .move_tab_to_new_window, {}));
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .move_tab_to_new_window);
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expect(b.window == window);

    // Dropped once the terminal begins to close.
    app.forgetClosing(&b.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(2, window.tabs.items.len);

    // Nothing while the window is closing, nor while the terminal is.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .move_tab_to_new_window, {}));
    window.closing = true;
    app.createRequested();
    window.closing = false;
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(2, window.tabs.items.len);
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .move_tab_to_new_window, {}));
    b.closing = true;
    app.createRequested();
    b.closing = false;
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(2, window.tabs.items.len);

    // Nor once the window has no other tab: here b's closed first.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    try std.testing.expect(b.destroy());
    app.createRequested();
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(1, window.tabs.items.len);
    try std.testing.expect(a.window == window);
    try std.testing.expect(win32.GetAncestor(a.hwnd, win32.GA_PARENT) == window.hwnd);
}

test "win32: move_tab_to_new_window moves a tab whole into a new window" {
    // The tab, with its split, zoom, focused terminal and title of its
    // own, becomes the only tab of a new window, which is shown and
    // captioned after it; its terminals are that frame's children and
    // point back at it. The old window shows the tab after it, or else
    // the one before, as when a tab closes, and its bar goes with one tab
    // left. A toast's click then reaches a moved terminal in its new
    // window.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    try std.testing.expect(a.setTitle("a"));

    // a; x and y side by side, zoomed on x, titled "logs"; c.
    const c = try testTab(&app, window);
    const x = try testTab(&app, window);
    const y = try testPane(&app, window);
    const t = window.tabOf(x).?;
    t.tree.deinit();
    t.tree = try testRow(alloc, &.{ x, y });
    t.tree.zoom(t.tree.locate(x).?);
    try std.testing.expect(c.setTitle("c"));
    try std.testing.expect(x.setTitle("x"));
    try std.testing.expect(try app.performAction(.{ .surface = &x.core_surface }, .set_tab_title, .{ .title = "logs" }));
    window.selectTab(1);
    try std.testing.expect(window.tab() == t);
    try std.testing.expect(!shown(y.hwnd));

    // A focus move left pending on the tab; a middle button down on the
    // bar's third tab, c's, which the move cancels as the indexes shift.
    t.pending_focus = y;
    const bar = window.bar.hwnd.?;
    const on_c = testMid(testBarLayout(window).tabRect(2));
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, on_c);
    try std.testing.expectEqual(2, window.bar.middle.?);
    // y, which the zoom hides, is never resized, so the IME form it keeps
    // tells whether it was given a new scale (`Surface.scaleChanged`).
    y.ime.form = .{ .pt = .{ .x = 1, .y = 1 }, .rc = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 } };

    try std.testing.expect(try app.performAction(.{ .surface = &x.core_surface }, .move_tab_to_new_window, {}));
    try std.testing.expectEqual(1, app.windows.items.len);
    app.createRequested();
    try std.testing.expectEqual(0, app.requests.items.len);
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = app.windows.items[1];

    var buf: [64]u16 = undefined;
    try std.testing.expectEqual(1, moved.tabs.items.len);
    try std.testing.expect(moved.tab() == t);
    try std.testing.expect(t.focused == x);
    try std.testing.expect(t.pending_focus == null);
    try std.testing.expectEqualStrings("logs", t.title_override.?);
    try std.testing.expectEqual(t.tree.locate(x), t.tree.zoomed);
    for ([_]*Surface{ x, y }) |pane| {
        try std.testing.expect(pane.window == moved);
        try std.testing.expect(win32.GetAncestor(pane.hwnd, win32.GA_PARENT) == moved.hwnd);
    }
    try std.testing.expect(shown(moved.hwnd));
    try std.testing.expect(shown(x.hwnd));
    try std.testing.expect(!shown(y.hwnd));
    try std.testing.expect(!shown(moved.bar.hwnd.?));
    try std.testing.expectEqual(try clientRect(moved.hwnd), try paneRect(moved, x));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("logs"), testCaption(moved, &buf));
    // Both frames have the same DPI: no new scale.
    try std.testing.expect(y.ime.form != null);

    // The old window shows c, the tab after, captioned after it; the
    // bar's press is cancelled, so its release closes nothing.
    try std.testing.expectEqual(2, window.tabs.items.len);
    try std.testing.expect(window.tabOf(x) == null);
    try std.testing.expect(window.tab() == window.tabOf(c).?);
    try std.testing.expect(shown(c.hwnd));
    try std.testing.expect(!shown(a.hwnd));
    try std.testing.expect(shown(bar));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("c"), testCaption(window, &buf));
    try std.testing.expect(window.bar.middle == null);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, on_c);
    try std.testing.expect(!a.closing and !c.closing);

    // A toast's click on y finds it in the new window: the zoom there
    // ends, and y has the focus.
    app.notificationClicked(y.notifications.id);
    try std.testing.expect(t.tree.zoomed == null);
    try std.testing.expect(t.focused == y);
    try std.testing.expect(shown(y.hwnd));

    // A hidden tab's, as an `all:` binding reaches it: a's. The window
    // keeps c shown, and with one tab left its bar goes.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(3, app.windows.items.len);
    const moved_a = app.windows.items[2];
    try std.testing.expect(a.window == moved_a);
    try std.testing.expect(shown(a.hwnd));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("a"), testCaption(moved_a, &buf));
    try std.testing.expectEqual(1, window.tabs.items.len);
    try std.testing.expect(window.tab().focused == c);
    try std.testing.expect(!shown(bar));
    try std.testing.expectEqual(0, (try paneRect(window, c)).top);

    // Every window has one tab now.
    for ([_]*Surface{ a, c, x }) |pane| {
        try std.testing.expect(!try app.performAction(.{ .surface = &pane.core_surface }, .move_tab_to_new_window, {}));
    }
    try std.testing.expectEqual(0, app.requests.items.len);
}

test "win32: a tab that cannot move to a new window stays as it was" {
    // Whatever can fail is done before the old window lets go of the tab
    // (`Window.moveTabTo`): an allocation failing at any point leaves the
    // tab, its terminals and the window as they were, and no new window
    // behind, which the testing allocator would report as a leak.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const b = try testTab(&app, window);
    const b2 = try testPane(&app, window);
    const tb = window.tabOf(b).?;
    tb.tree.deinit();
    tb.tree = try testRow(alloc, &.{ b, b2 });
    window.selectTab(1);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = fail_index });
        core_app.alloc = failing.allocator();
        const result = app.moveTabToNewWindow(&b.core_surface, null);
        core_app.alloc = alloc;
        const finished = result catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(1, app.windows.items.len);
            try std.testing.expectEqual(2, window.tabs.items.len);
            try std.testing.expect(window.tab() == tb);
            try std.testing.expect(tb.focused == b);
            for ([_]*Surface{ b, b2 }) |pane| {
                try std.testing.expect(pane.window == window);
                try std.testing.expect(win32.GetAncestor(pane.hwnd, win32.GA_PARENT) == window.hwnd);
                try std.testing.expect(shown(pane.hwnd));
            }
            continue;
        };
        try std.testing.expect(finished.? == .whole);
        break;
    }
    // Some allocation failed before the one run that succeeded.
    try std.testing.expect(fail_index > 0);
    try std.testing.expectEqual(2, app.windows.items.len);
    try std.testing.expect(b.window == app.windows.items[1]);
    try std.testing.expect(b2.window == app.windows.items[1]);
}

test "win32: a tab whose terminal cannot change frames stays where it was" {
    // SetParent fails for a window handle that is no longer valid: the
    // terminal moved before it goes back to the old frame, the new window
    // is discarded (a leak of it fails the test through the testing
    // allocator), and the tab is shown where it was.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const b = try testTab(&app, window);
    // Out of the app's list, so that its window's WM_DESTROY frees
    // nothing; its handle is then dead.
    const z = try testPane(&app, window);
    _ = app.surfaces.pop();
    defer alloc.destroy(z);
    try std.testing.expect(win32.DestroyWindow(z.hwnd).toBool());
    // And its link preview's, which a teardown destroys with it
    // (`Surface.destroy`): freed below, z never lets go of it.
    try std.testing.expect(win32.DestroyWindow(z.overlays.link_preview.hwnd.?).toBool());
    const tb = window.tabOf(b).?;
    tb.tree.deinit();
    // z on the left: a split keeps the node it adds before the one split
    // (`SplitTree.split`), so b is moved first, and must go back.
    tb.tree = try testRow(alloc, &.{ z, b });
    var order = tb.tree.iterator();
    try std.testing.expect(order.next().?.view == b);
    window.selectTab(1);

    try std.testing.expectError(App.Error.Win32CallFailed, app.moveTabToNewWindow(&b.core_surface, null));
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(2, window.tabs.items.len);
    try std.testing.expect(window.tab() == tb);
    try std.testing.expect(tb.focused == b);
    try std.testing.expect(b.window == window);
    try std.testing.expect(win32.GetAncestor(b.hwnd, win32.GA_PARENT) == window.hwnd);
    try std.testing.expect(shown(b.hwnd));

    // z leaves the tree before it is freed.
    tb.tree.deinit();
    tb.tree = try .init(alloc, b);
}

test "win32: a tab that can neither move nor go back is moved after all" {
    // SetParent fails for b2 moving to the new frame, and then for b, which
    // moved, going back: the move is finished instead, b2 moved again, so
    // that each terminal is in the frame of the one window holding it,
    // which the app owns and shows. Closing that window then frees both
    // (a leak fails the test through the testing allocator), and the old
    // window, which keeps a, stays.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const b = try testTab(&app, window);
    const b2 = try testPane(&app, window);
    const tb = window.tabOf(b).?;
    tb.tree.deinit();
    // b2 on the left: b is moved first (`SplitTree.split`), and must be
    // the one that cannot go back.
    tb.tree = try testRow(alloc, &.{ b2, b });
    var order = tb.tree.iterator();
    try std.testing.expect(order.next().?.view == b);
    window.selectTab(1);

    const Fail = struct {
        var home: win32.HWND = undefined;
        var forward: ?win32.HWND = null;
        var back: win32.HWND = undefined;
        var forward_failures: usize = 0;
        var back_failures: usize = 0;
        fn setParent(child: win32.HWND, parent: ?win32.HWND) callconv(.winapi) ?win32.HWND {
            if (parent == home and child == back) {
                back_failures += 1;
                return null;
            }
            // Once only: moved again, it goes.
            if (parent != home and child == forward) {
                forward = null;
                forward_failures += 1;
                return null;
            }
            return win32.SetParent(child, parent);
        }
    };
    Fail.home = window.hwnd;
    Fail.forward = b2.hwnd;
    Fail.back = b.hwnd;
    Window.test_set_parent = &Fail.setParent;
    defer Window.test_set_parent = &win32.SetParent;

    // True: the caller says the move was finished after a failure.
    try std.testing.expect((try app.moveTabToNewWindow(&b.core_surface, null)).? == .after_failure);
    try std.testing.expectEqual(1, Fail.forward_failures);
    try std.testing.expectEqual(1, Fail.back_failures);
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = app.windows.items[1];
    try std.testing.expect(moved != window);
    try std.testing.expect(moved.tab() == tb);
    for ([_]*Surface{ b, b2 }) |pane| {
        try std.testing.expect(pane.window == moved);
        try std.testing.expect(win32.GetAncestor(pane.hwnd, win32.GA_PARENT) == moved.hwnd);
    }
    try std.testing.expect(shown(moved.hwnd));
    try std.testing.expectEqual(1, window.tabs.items.len);
    try std.testing.expect(window.tab().focused == a);
    try std.testing.expect(win32.GetAncestor(a.hwnd, win32.GA_PARENT) == window.hwnd);

    // Closing the new window frees its terminals; the old one stays.
    moved.requestClose();
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool()) {
        _ = win32.DispatchMessageW(&msg);
    }
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expect(app.windows.items[0] == window);
    try std.testing.expectEqual(1, app.surfaces.items.len);
    try std.testing.expect(app.surfaces.items[0] == a);
}

test "win32: a terminal that can change frames neither way stays in its old window" {
    // SetParent always fails for b2 and b3 moving to the new frame, and
    // for b, which moved, going back: the move is finished, b alone in the
    // new window, and b2 and b3, still in the old frame, stay with the old
    // window, each in a tab of its own where the tab was, one shown as the
    // tab was. Each terminal then belongs to the window whose frame holds
    // it, so that closing either window first frees its own terminals,
    // once, and the other's after (a double free or a leak fails the test
    // through the testing allocator, or the app's lists).
    const alloc = std.testing.allocator;
    for ([_]bool{ true, false }) |old_first| {
        var core_app: CoreApp = undefined;
        core_app.alloc = alloc;
        var app: App = undefined;
        try testApp(&app, &core_app);
        try registerClasses(app.hinstance);
        defer unregisterClasses(app.hinstance);
        defer testCleanup(&app);

        const window = try testFrame(&app);
        testResize(window, 800, 300);
        const a = try testPane(&app, window);
        window.tab().tree = try .init(alloc, a);
        window.tab().focused = a;
        _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
        window.relayout();
        const ta = window.tab();
        const b = try testTab(&app, window);
        const b2 = try testPane(&app, window);
        const b3 = try testPane(&app, window);
        const tb = window.tabOf(b).?;
        tb.tree.deinit();
        tb.tree = try testRow(alloc, &.{ b2, b, b3 });
        // Focused on one that stays: the tab's focus goes to b, as when
        // it closes (`Window.removePane`).
        tb.focused = b2;
        window.selectTab(1);
        try std.testing.expect(shown(b2.hwnd) and shown(b3.hwnd));

        const Fail = struct {
            var home: win32.HWND = undefined;
            var stuck: [2]win32.HWND = undefined;
            var back: win32.HWND = undefined;
            var forward_failures: usize = 0;
            var back_failures: usize = 0;
            fn setParent(child: win32.HWND, parent: ?win32.HWND) callconv(.winapi) ?win32.HWND {
                if (parent == home and child == back) {
                    back_failures += 1;
                    return null;
                }
                if (parent != home and (child == stuck[0] or child == stuck[1])) {
                    forward_failures += 1;
                    return null;
                }
                return win32.SetParent(child, parent);
            }
        };
        Fail.home = window.hwnd;
        Fail.stuck = .{ b2.hwnd, b3.hwnd };
        Fail.back = b.hwnd;
        Fail.forward_failures = 0;
        Fail.back_failures = 0;
        Window.test_set_parent = &Fail.setParent;
        defer Window.test_set_parent = &win32.SetParent;

        try std.testing.expect((try app.moveTabToNewWindow(&b.core_surface, null)).? == .split);
        // b2 and b3 twice each: at first, and when the move is finished.
        try std.testing.expectEqual(4, Fail.forward_failures);
        try std.testing.expectEqual(1, Fail.back_failures);

        // The new window: b alone, focused, in its frame.
        try std.testing.expectEqual(2, app.windows.items.len);
        const moved = app.windows.items[1];
        try std.testing.expect(moved != window);
        try std.testing.expectEqual(1, moved.tabs.items.len);
        try std.testing.expect(moved.tab() == tb);
        try std.testing.expect(tb.tree.locate(b) != null);
        try std.testing.expect(tb.tree.locate(b2) == null);
        try std.testing.expect(tb.tree.locate(b3) == null);
        try std.testing.expect(tb.focused == b);
        try std.testing.expect(b.window == moved);
        try std.testing.expect(win32.GetAncestor(b.hwnd, win32.GA_PARENT) == moved.hwnd);
        try std.testing.expect(shown(moved.hwnd));

        // The old one: a, then b2 and b3 each in a tab, the first shown
        // in the tab's place, the other hidden.
        try std.testing.expectEqual(3, window.tabs.items.len);
        try std.testing.expect(window.tabs.items[0] == ta);
        try std.testing.expectEqual(1, window.selected);
        const t2 = window.tabOf(b2).?;
        const t3 = window.tabOf(b3).?;
        try std.testing.expect(t2 != t3 and t2 != ta and t3 != ta);
        for ([_]struct { *Surface, *Window.Tab }{ .{ b2, t2 }, .{ b3, t3 } }) |kept| {
            try std.testing.expect(kept[0].window == window);
            try std.testing.expect(win32.GetAncestor(kept[0].hwnd, win32.GA_PARENT) == window.hwnd);
            try std.testing.expect(kept[1].focused == kept[0]);
            try std.testing.expect(kept[1].tree.locate(kept[0]).? == .root);
            try std.testing.expectEqual(kept[1] == window.tab(), shown(kept[0].hwnd));
        }
        try std.testing.expect(window.tab() == t2 or window.tab() == t3);
        try std.testing.expect(win32.GetAncestor(a.hwnd, win32.GA_PARENT) == window.hwnd);

        // Closing each window in turn frees its own terminals, once.
        const order: [2]*Window = if (old_first) .{ window, moved } else .{ moved, window };
        const second = order[1];
        order[0].requestClose();
        var msg: win32.MSG = undefined;
        while (win32.PeekMessageW(&msg, null, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool()) {
            _ = win32.DispatchMessageW(&msg);
        }
        try std.testing.expectEqual(1, app.windows.items.len);
        try std.testing.expect(app.windows.items[0] == second);
        if (old_first) {
            try std.testing.expectEqual(1, app.surfaces.items.len);
            try std.testing.expect(app.surfaces.items[0] == b);
            try std.testing.expect(moved.tab().tree.locate(b) != null);
        } else {
            try std.testing.expectEqual(3, app.surfaces.items.len);
            for ([_]*Surface{ a, b2, b3 }) |pane| {
                try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, pane) != null);
                try std.testing.expect(window.find(pane) != null);
            }
        }
        second.requestClose();
        while (win32.PeekMessageW(&msg, null, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool()) {
            _ = win32.DispatchMessageW(&msg);
        }
        try std.testing.expectEqual(0, app.windows.items.len);
        try std.testing.expectEqual(0, app.surfaces.items.len);
    }
}

test "win32: tab and window actions behind a queued move act on the new window" {
    // GTK moves a tab to a new window at once, so that what a terminal of
    // the tab does next, as a binding chained after the move, acts on the
    // new window. Here the move waits for run, and close_window,
    // close_tab, move_tab and goto_tab from that tab wait behind it: the
    // old window keeps its other tabs, and close_window closes the new
    // one. Each is dropped once its terminal begins to close.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    app.config.@"window-new-tab-position" = .end;
    // a; x and y side by side; c. x's tab shown.
    const x = try testTab(&app, window);
    const y = try testPane(&app, window);
    const t = window.tabOf(x).?;
    t.tree.deinit();
    t.tree = try testRow(alloc, &.{ x, y });
    const c = try testTab(&app, window);
    window.selectTab(1);
    const ta = window.tabOf(a).?;
    const tc = window.tabOf(c).?;

    const queue = struct {
        // The move from x, then each action from y, in its tab.
        fn f(app_: *App, x_: *Surface, y_: *Surface) !void {
            const from: apprt.Target = .{ .surface = &y_.core_surface };
            try std.testing.expect(try app_.performAction(.{ .surface = &x_.core_surface }, .move_tab_to_new_window, {}));
            try std.testing.expect(try app_.performAction(from, .close_tab, .other));
            try std.testing.expect(try app_.performAction(from, .move_tab, .{ .amount = 1 }));
            // The tab shown already: in the old window, nothing to go to.
            try std.testing.expect(try app_.performAction(from, .goto_tab, @fromBackingInt(2)));
            try std.testing.expect(try app_.performAction(from, .close_window, {}));
        }
    }.f;

    // Recorded, with nothing done yet: no tab closing, none moved, the
    // window not closing.
    try queue(&app, x, y);
    try std.testing.expectEqual(5, app.requests.items.len);
    try std.testing.expect(app.requests.items[1] == .close_tab);
    try std.testing.expect(app.requests.items[2] == .move_tab);
    try std.testing.expect(app.requests.items[3] == .goto_tab);
    try std.testing.expect(app.requests.items[4] == .close_window);
    try std.testing.expect(!a.closing and !c.closing and !window.closing);
    try std.testing.expect(window.tabs.items[0] == ta);
    try std.testing.expect(window.tabs.items[1] == t);
    try std.testing.expect(window.tabs.items[2] == tc);

    // From another tab, which stays, move_tab is made at once, as before.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab, .{ .amount = 1 }));
    try std.testing.expect(window.tabs.items[1] == ta);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab, .{ .amount = -1 }));
    try std.testing.expect(window.tabs.items[0] == ta);
    try std.testing.expectEqual(5, app.requests.items.len);

    // Made in order: the tab moves, then in the new window, its only tab,
    // close_tab, move_tab and goto_tab have nothing to do, and
    // close_window closes it. The old window, which shows c, stays.
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = app.windows.items[1];
    try std.testing.expect(x.window == moved and y.window == moved);
    try std.testing.expect(moved.closing and !window.closing);
    try std.testing.expect(!a.closing and !c.closing);
    try std.testing.expectEqual(2, window.tabs.items.len);
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool()) {
        _ = win32.DispatchMessageW(&msg);
    }
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expect(app.windows.items[0] == window);
    try std.testing.expectEqual(2, app.surfaces.items.len);
    try std.testing.expect(window.tab() == tc);

    // Again from c, alone in its tab, shown: each waits behind the move,
    // and is dropped with it once c begins to close.
    try queue(&app, c, c);
    try std.testing.expectEqual(5, app.requests.items.len);
    try std.testing.expect(!a.closing and !window.closing);
    try std.testing.expect(window.tabs.items[0] == ta);
    app.forgetClosing(&c.core_surface);
    for (app.requests.items) |request| try std.testing.expect(request == .dropped);
    app.createRequested();
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(2, window.tabs.items.len);
    try std.testing.expect(!a.closing and !c.closing and !window.closing);
}

test "win32: tab and window actions behind a move that does not happen are dropped" {
    // close_window, close_tab, move_tab and goto_tab from a terminal of a
    // tab whose move to a new window is queued wait for it, meant for the
    // new window (`moveQueuedFor`). When the move does not happen they are
    // dropped, not made in the old window, where close_window would close
    // it with the tabs the move was to leave there: when its terminal
    // begins to close first, and when its window has no other tab left by
    // then.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    app.config.@"window-new-tab-position" = .end;
    // a; x and y side by side; c. x's tab shown.
    const x = try testTab(&app, window);
    const y = try testPane(&app, window);
    const t = window.tabOf(x).?;
    t.tree.deinit();
    t.tree = try testRow(alloc, &.{ x, y });
    const c = try testTab(&app, window);
    window.selectTab(1);
    const ta = window.tabOf(a).?;
    const tc = window.tabOf(c).?;

    const Check = struct {
        // The move from x, then each action from y, in its tab. Made in
        // the old window, each would change it: a and c would close, the
        // tab move, another tab show, and the window close.
        fn queue(app_: *App, x_: *Surface, y_: *Surface) !void {
            const from: apprt.Target = .{ .surface = &y_.core_surface };
            try std.testing.expect(try app_.performAction(.{ .surface = &x_.core_surface }, .move_tab_to_new_window, {}));
            try std.testing.expect(try app_.performAction(from, .close_tab, .other));
            try std.testing.expect(try app_.performAction(from, .move_tab, .{ .amount = 1 }));
            try std.testing.expect(try app_.performAction(from, .goto_tab, .next));
            try std.testing.expect(try app_.performAction(from, .close_window, {}));
            try std.testing.expectEqual(5, app_.requests.items.len);
        }

        // The window as it was: these tabs in this order, `shown` shown,
        // nothing closing.
        fn same(window_: *Window, tabs: []const *Window.Tab, shown_: *Window.Tab) !void {
            try std.testing.expect(!window_.closing);
            try std.testing.expectEqual(tabs.len, window_.tabs.items.len);
            for (tabs, window_.tabs.items) |want, have| try std.testing.expect(want == have);
            try std.testing.expect(window_.tab() == shown_);
            for (window_.tabs.items) |tab_| {
                var it = tab_.tree.iterator();
                while (it.next()) |entry| try std.testing.expect(!entry.view.closing);
            }
        }
    };

    // A move that fails takes the same way as one not made (`reportMove`
    // returns false), but logs an error, which fails a test run.

    // x begins to close before the move: the move is dropped, and so is
    // what y queued behind it.
    try Check.queue(&app, x, y);
    app.forgetClosing(&x.core_surface);
    for (app.requests.items) |request| try std.testing.expect(request == .dropped);
    app.createRequested();
    try std.testing.expectEqual(1, app.windows.items.len);
    try Check.same(window, &.{ ta, t, tc }, t);

    // a and c close before the move: with no other tab, the tab stays.
    try Check.queue(&app, x, y);
    try std.testing.expect(a.destroy());
    try std.testing.expect(c.destroy());
    app.createRequested();
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expect(x.window == window);
    try Check.same(window, &.{t}, t);
}

test "win32: a moved tab takes its new frame's scale, place and title unshown" {
    // `Window.moveTabTo` onto a frame nobody has shown yet, as
    // `createBare` makes one: its terminals are laid out in it, given its
    // scale where it differs from the old frame's, as the frame's
    // WM_DPICHANGED gives it, and the frame is captioned after the tab
    // without being activated.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    // A hidden tab of p and q, zoomed on p, so that q is never resized.
    const p = try testTab(&app, window);
    const q = try testPane(&app, window);
    const t = window.tabOf(p).?;
    t.tree.deinit();
    t.tree = try testRow(alloc, &.{ p, q });
    t.tree.zoom(t.tree.locate(p).?);
    try std.testing.expect(p.setTitle("p"));
    q.ime.form = .{ .pt = .{ .x = 1, .y = 1 }, .rc = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 } };

    // The old frame at 96 DPI, every other at 144.
    const Dpi = struct {
        var old: ?win32.HWND = null;
        fn of(hwnd: win32.HWND) callconv(.winapi) win32.UINT {
            return if (win32.GetAncestor(hwnd, win32.GA_ROOT) == old) 96 else 144;
        }
    };
    Dpi.old = window.hwnd;
    app.get_dpi_for_window = &Dpi.of;

    // The DPI each terminal is given, which a terminal with no core keeps
    // nowhere.
    const Scales = struct {
        var dpi_p: ?u16 = null;
        var dpi_q: ?u16 = null;
        var other: usize = 0;
        var of_p: *Surface = undefined;
        var of_q: *Surface = undefined;
        fn seen(surface: *Surface, dpi: u16) void {
            if (surface == of_p) {
                dpi_p = dpi;
            } else if (surface == of_q) {
                dpi_q = dpi;
            } else {
                other += 1;
            }
        }
    };
    Scales.of_p = p;
    Scales.of_q = q;
    Surface.test_scale_changed = &Scales.seen;
    defer Surface.test_scale_changed = null;

    const to = try testFrame(&app);
    try std.testing.expect(try window.moveTabTo(1, to) == .whole);
    try std.testing.expectEqual(144, Scales.dpi_p.?);
    try std.testing.expectEqual(144, Scales.dpi_q.?);
    try std.testing.expectEqual(0, Scales.other);
    try std.testing.expect(q.ime.form == null);
    try std.testing.expect(to.tab() == t);
    try std.testing.expect(p.window == to and q.window == to);
    try std.testing.expectEqual(try clientRect(to.hwnd), try paneRect(to, p));
    try std.testing.expect(!shown(to.hwnd));
    var buf: [64]u16 = undefined;
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("p"), testCaption(to, &buf));
    try std.testing.expect(window.tab().focused == a);
    try std.testing.expectEqual(1, window.tabs.items.len);
}

test "win32: close_tab closes this tab, the others or those after it" {
    // Each terminal of the tabs it names gets a teardown posted, and a tab
    // goes with its last (`Surface.destroy`); the window stays.
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
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    app.config.@"window-new-tab-position" = .end;
    const b = try testTab(&app, window);
    const b2 = try testPane(&app, window);
    {
        const tb = window.tabOf(b).?;
        var row = try testRow(alloc, &.{ b, b2 });
        errdefer row.deinit();
        tb.tree.deinit();
        tb.tree = row;
    }
    const c = try testTab(&app, window);
    const d = try testTab(&app, window);
    window.selectTab(1);

    // Each terminal of each tab named, and no other.
    const drain = struct {
        fn f() void {
            var msg: win32.MSG = undefined;
            while (win32.PeekMessageW(&msg, null, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool()) {
                _ = win32.DispatchMessageW(&msg);
            }
        }
    }.f;
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .close_tab, .right));
    try std.testing.expect(c.closing and d.closing);
    try std.testing.expect(!a.closing and !b.closing and !b2.closing);
    drain();
    try std.testing.expectEqual(2, window.tabs.items.len);

    // The tabs after the last: none.
    try std.testing.expect(!try app.performAction(.{ .surface = &b.core_surface }, .close_tab, .right));

    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .close_tab, .other));
    try std.testing.expect(a.closing and !b.closing);
    drain();
    try std.testing.expectEqual(1, window.tabs.items.len);
    try std.testing.expectEqual(b, window.tab().focused.?);

    // `.this` with two tabs closes the tab, both its terminals.
    const e = try testTab(&app, window);
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .close_tab, .this));
    try std.testing.expect(b.closing and b2.closing and !e.closing);
    drain();
    try std.testing.expectEqual(1, window.tabs.items.len);
    try std.testing.expectEqual(e, window.tab().focused.?);
    try std.testing.expect(!window.closing);
}

test "win32: the tab bar shows over the terminals, and its clicks show and close tabs" {
    // As window-show-tab-bar = auto: hidden with one tab and along the top
    // with two, the terminals under it; never as it says, from a reloaded
    // configuration too; and not while the window covers its monitor. A
    // click on a tab shows it at once, `run`'s loop having dispatched it;
    // its close glyph, and a middle click, close it when pressed and
    // released on the same tab; the wheel scrolls tabs that do not fit,
    // by fractions of a notch too, and the highlight follows.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    try std.testing.expect(!shown(bar));
    try std.testing.expectEqual(0, (try paneRect(window, a)).top);

    const b = try testTab(&app, window);
    window.selectTab(1);
    const height = TabBar.Metrics.init(Window.dpiOf(&app, window.hwnd)).height;
    try std.testing.expect(shown(bar));
    try std.testing.expectEqual(height, (try paneRect(window, b)).top);

    app.config.@"window-show-tab-bar" = .never;
    window.relayout();
    try std.testing.expect(!shown(bar));
    try std.testing.expectEqual(0, (try paneRect(window, b)).top);
    app.config.@"window-show-tab-bar" = .auto;
    window.relayout();
    window.toggleFullscreen();
    try std.testing.expect(!shown(bar));
    window.toggleFullscreen();
    try std.testing.expect(shown(bar));

    // A reloaded configuration lays every window out again (`redecorate`):
    // the frame keeps its styles, so no WM_SIZE does it.
    {
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.@"window-show-tab-bar" = .never;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        app.createRequested();
        try std.testing.expect(!shown(bar));
        try std.testing.expectEqual(0, (try paneRect(window, b)).top);
        changed.@"window-show-tab-bar" = .auto;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        app.createRequested();
        try std.testing.expect(shown(bar));
        try std.testing.expectEqual(height, (try paneRect(window, b)).top);
    }

    const c = try testTab(&app, window);
    const layout = testBarLayout(window);
    try std.testing.expectEqual(0, layout.scroll);

    // A click on the first tab shows it at once, and records nothing.
    const first = layout.tabRect(0);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, testPoint(first.left + 4, 4));
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(first.left + 4, 4));
    try std.testing.expectEqual(0, window.selected);
    try std.testing.expectEqual(0, app.requests.items.len);

    // The second tab's close glyph, pressed and released on it: closed.
    const close = layout.closeRect(1);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, testMid(close));
    try std.testing.expect(!b.closing);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testMid(close));
    try std.testing.expect(b.closing);
    try std.testing.expect(!a.closing);

    // Pressed on a tab, which shows it, and released on its close glyph:
    // not closed.
    const third = layout.tabRect(2);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, testPoint(third.left + 4, 4));
    try std.testing.expectEqual(2, window.selected);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testMid(layout.closeRect(2)));
    try std.testing.expect(!c.closing);

    // A middle click closes a tab only if it went down on that tab: not a
    // release alone, nor one from another tab; its close glyph counts.
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, testPoint(first.left + 4, 4));
    try std.testing.expect(!a.closing);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, testPoint(third.left + 4, 4));
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, testPoint(first.left + 4, 4));
    try std.testing.expect(!a.closing);
    try std.testing.expect(!c.closing);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, testPoint(first.left + 4, 4));
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, testMid(layout.closeRect(0)));
    try std.testing.expect(a.closing);

    // Their teardowns leave the third, alone, and the bar goes.
    testTeardowns();
    try std.testing.expectEqual(1, window.tabs.items.len);
    try std.testing.expect(window.tab().focused == c);
    try std.testing.expect(!shown(bar));

    // So does a hidden tab's last terminal, leaving one tab.
    const d = try testTab(&app, window);
    window.relayout();
    try std.testing.expect(shown(bar));
    try std.testing.expect(d.destroy());
    try std.testing.expect(!shown(bar));
    try std.testing.expectEqual(0, (try paneRect(window, c)).top);

    // Tabs too many for the bar scroll with the wheel: a notch a tab, a
    // high-resolution wheel's fraction of one in proportion; and the
    // highlight goes to the tab now under the pointer.
    for (0..19) |_| _ = try testTab(&app, window);
    window.relayout();
    const over = testBarLayout(window);
    try std.testing.expectEqual(0, over.scroll);
    try std.testing.expect(over.max_scroll > 2 * over.tab);
    _ = win32.SendMessageW(bar, win32.WM_MOUSEMOVE, 0, testPoint(10, 4));
    try std.testing.expect(std.meta.eql(window.bar.hover, TabBar.Hit{ .tab = 0 }));
    _ = win32.SendMessageW(bar, win32.WM_MOUSEWHEEL, testWheel(-30), 0);
    const part = @divTrunc(30 * over.tab, win32.WHEEL_DELTA);
    try std.testing.expectEqual(part, window.bar.scroll);
    _ = win32.SendMessageW(bar, win32.WM_MOUSEWHEEL, testWheel(-120), 0);
    try std.testing.expectEqual(part + over.tab, window.bar.scroll);
    try std.testing.expect(std.meta.eql(window.bar.hover, TabBar.Hit{ .tab = 1 }));
}

test "win32: the tab bar's buttons take every click, and only their own" {
    // A quick second click, which Windows sends as a double click, is a
    // click on a close glyph or the "+"; on the bar's empty part it opens
    // a tab. A press counts only with its release on the same thing: not
    // once the capture is taken away, nor once the tabs change under it.
    // The "+" goes through the core's new_tab binding.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    // Each goes after the shown tab, so they end a, b, c, d, e, f.
    const f = try testTab(&app, window);
    const e = try testTab(&app, window);
    const d = try testTab(&app, window);
    const c = try testTab(&app, window);
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    try std.testing.expect(window.tabs.items[1].focused == b);

    // The shown terminal opens the new tabs. Live, so that the binding
    // runs; no other core call is made on it. Back to `.none` before
    // anything lays it out (its WM_SIZE would reach a core), and before
    // the teardown at the end, which would stop a live core.
    a.core_state = .live;
    defer a.core_state = .none;
    a.core_surface.rt_app = &app;

    // The "+", clicked twice quickly: two new tabs.
    const plus = testMid(testBarLayout(window).plusRect());
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, plus);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, plus);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDBLCLK, 0, plus);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, plus);
    try std.testing.expectEqual(2, app.requests.items.len);
    for (app.requests.items) |request| try std.testing.expect(request == .tab);
    app.requests.clearRetainingCapacity();

    // The empty part: its double click opens one.
    const empty = testPoint(testBarLayout(window).plusRect().right + 20, 4);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, empty);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, empty);
    try std.testing.expectEqual(0, app.requests.items.len);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDBLCLK, 0, empty);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, empty);
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .tab);
    app.requests.clearRetainingCapacity();
    a.core_state = .none;

    // Pressed on b's close glyph, then the capture taken away: the button
    // came up elsewhere, so a release there later closes nothing.
    const close_b = testMid(testBarLayout(window).closeRect(1));
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, close_b);
    _ = win32.SendMessageW(bar, win32.WM_CAPTURECHANGED, 0, 0);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, close_b);
    try std.testing.expect(!b.closing);

    // b's close glyph, clicked; once b is gone c takes its place, and a
    // quick second click there closes c.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, close_b);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, close_b);
    try std.testing.expect(b.closing);
    testTeardowns();
    try std.testing.expect(window.tabs.items[1].focused == c);
    const close_c = testMid(testBarLayout(window).closeRect(1));
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDBLCLK, 0, close_c);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, close_c);
    try std.testing.expect(c.closing);
    testTeardowns();

    // a, d, e, f: pressed on e's close glyph; d goes meanwhile, and f's
    // glyph has e's index now: the release on it closes nothing.
    try std.testing.expect(window.tabs.items[2].focused == e);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, testMid(testBarLayout(window).closeRect(2)));
    try std.testing.expect(d.destroy());
    try std.testing.expect(window.tabs.items[2].focused == f);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testMid(testBarLayout(window).closeRect(2)));
    try std.testing.expect(!e.closing);
    try std.testing.expect(!f.closing);

    // a, e, f: the pointer on f; once e goes the "+" is there, and the
    // highlight goes with it.
    const on_f = testBarLayout(window).tabRect(2);
    _ = win32.SendMessageW(bar, win32.WM_MOUSEMOVE, 0, testPoint(on_f.left + 4, 4));
    try std.testing.expect(std.meta.eql(window.bar.hover, TabBar.Hit{ .tab = 2 }));
    try std.testing.expect(e.destroy());
    try std.testing.expect(std.meta.eql(window.bar.hover, testBarLayout(window).hit(on_f.left + 4, 4)));
    try std.testing.expect(window.bar.hover == .plus);
}

test "win32: a double click on the tab bar is two clicks, but on its empty part" {
    // With CS_DBLCLKS a quick second click of either button comes as a
    // double click: a middle one closes the tab now under the pointer, as
    // a left one on a close glyph does. A double click opens a tab only
    // with both of its presses on the bar's empty part, not when the first
    // closed the last tab and left empty space under the second.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    // Each goes after the shown tab, so they end a, b, c, d, e.
    const e = try testTab(&app, window);
    _ = try testTab(&app, window);
    const c = try testTab(&app, window);
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    try std.testing.expect(window.tabs.items[1].focused == b);

    // b's label, middle-clicked twice quickly: b closes, c takes its
    // place, and the second click closes c. The tabs widen as one goes, so
    // the point is on the second tab with four tabs as with five.
    const five = testBarLayout(window);
    const four: TabBar.Layout = .init(five.m, 4, five.width, 0);
    const second = four.tabRect(1).left + 4;
    try std.testing.expect(std.meta.eql(five.hit(second, 4), TabBar.Hit{ .tab = 1 }));
    const on_b = testPoint(second, 4);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, on_b);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, on_b);
    try std.testing.expect(b.closing);
    testTeardowns();
    try std.testing.expect(window.tabs.items[1].focused == c);
    try std.testing.expect(std.meta.eql(testBarLayout(window).hit(second, 4), TabBar.Hit{ .tab = 1 }));
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDBLCLK, 0, on_b);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, on_b);
    try std.testing.expect(c.closing);
    try std.testing.expect(!a.closing);
    testTeardowns();

    // a, d, e, as wide as tabs go, so the "+" follows e: once e's close
    // glyph closes it, the "+" moves left and the glyph's place is empty.
    try std.testing.expect(window.tabs.items[2].focused == e);
    const layout = testBarLayout(window);
    try std.testing.expectEqual(layout.m.tab_max, layout.tab);
    const glyph = layout.closeRect(2);
    const x = @divTrunc(glyph.left + glyph.right, 2);
    const y = @divTrunc(glyph.top + glyph.bottom, 2);
    const at = testPoint(x, y);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, at);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, at);
    try std.testing.expect(e.closing);
    testTeardowns();
    try std.testing.expectEqual(2, window.tabs.items.len);
    try std.testing.expect(testBarLayout(window).hit(x, y) == .none);

    // The shown terminal would open the tab: live, so that the binding
    // runs (see the test above).
    a.core_state = .live;
    defer a.core_state = .none;
    a.core_surface.rt_app = &app;

    // The second press of that double click, on the empty place: nothing.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDBLCLK, 0, at);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, at);
    try std.testing.expectEqual(0, app.requests.items.len);

    // Both presses there: a new tab.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, at);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, at);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDBLCLK, 0, at);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, at);
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .tab);
    app.requests.clearRetainingCapacity();
}

test "win32: the tab bar holds the mouse capture while a button is down on it" {
    // Taken by a press on a tab, its close glyph or the "+", so that the
    // bar sees the button come up wherever it does, and let go once no
    // button is down on it, the left and middle ones held together too. A
    // capture another window takes cancels the press.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    const c = try testTab(&app, window);
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    defer _ = win32.ReleaseCapture();
    try std.testing.expect(win32.GetCapture() == null);

    const layout = testBarLayout(window);
    const close_b = testMid(layout.closeRect(1));
    const plus = testMid(layout.plusRect());
    const empty = testPoint(layout.plusRect().right + 20, 4);
    const on_a = testPoint(layout.tabRect(0).left + 4, 4);
    const on_b = testPoint(layout.tabRect(1).left + 4, 4);
    const on_c = testPoint(layout.tabRect(2).left + 4, 4);

    // b's close glyph and the "+": held, then let go off them.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, close_b);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, empty);
    try std.testing.expect(win32.GetCapture() == null);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, plus);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, empty);
    try std.testing.expect(win32.GetCapture() == null);
    try std.testing.expect(!b.closing);

    // Nothing to press on: no capture.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, empty);
    try std.testing.expect(win32.GetCapture() == null);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, empty);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, plus);
    try std.testing.expect(win32.GetCapture() == null);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, plus);

    // Left on the shown tab, then the middle button down on b and up on c:
    // the left one is still down, so the capture stays until it comes up.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, on_a);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, on_b);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, on_c);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, on_a);
    try std.testing.expect(win32.GetCapture() == null);

    // The other way round.
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, on_b);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, on_a);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, on_a);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, on_c);
    try std.testing.expect(win32.GetCapture() == null);
    try std.testing.expect(!b.closing);
    try std.testing.expect(!c.closing);

    // b's close glyph held, and the frame takes the capture: Windows tells
    // the bar (WM_CAPTURECHANGED), the press is cancelled, and its release
    // on the glyph closes nothing, nor lets go of the frame's capture.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, close_b);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SetCapture(window.hwnd);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, close_b);
    try std.testing.expect(!b.closing);
    try std.testing.expect(win32.GetCapture() == window.hwnd);
    _ = win32.ReleaseCapture();

    // The middle button likewise.
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONDOWN, 0, on_b);
    try std.testing.expect(win32.GetCapture() == bar);
    _ = win32.SetCapture(window.hwnd);
    _ = win32.SendMessageW(bar, win32.WM_MBUTTONUP, 0, on_b);
    try std.testing.expect(!b.closing);
    _ = win32.ReleaseCapture();
}

test "win32: a click on a tab waits for run under a prompt, from a live terminal" {
    // Under a prompt, which may have a core frame beneath it, the tab is
    // shown from `run`, as goto_tab is; the request names the shown tab's
    // focused terminal, which must be live (`App.requests`). A window
    // being torn down takes no click.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = try testTab(&app, window);
    window.relayout();
    const bar = window.bar.hwnd.?;
    const second = testBarLayout(window).tabRect(1);
    const click = struct {
        fn f(hwnd: win32.HWND, at: win32.LPARAM) void {
            _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONDOWN, 0, at);
            _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONUP, 0, at);
        }
    }.f;

    app.prompt_depth = 1;
    defer app.prompt_depth = 0;
    a.core_state = .live;
    defer a.core_state = .none;
    click(bar, testPoint(second.left + 4, 4));
    try std.testing.expectEqual(0, window.selected);
    try std.testing.expectEqual(1, app.requests.items.len);
    switch (app.requests.items[0]) {
        .goto_tab => |goto| try std.testing.expect(goto.from == &a.core_surface),
        else => return error.TestUnexpectedResult,
    }
    app.requests.clearRetainingCapacity();

    // Stopping, its requests already dropped: none is recorded.
    a.core_state = .stopping;
    click(bar, testPoint(second.left + 4, 4));
    try std.testing.expectEqual(0, app.requests.items.len);
    a.core_state = .none;

    app.prompt_depth = 0;
    window.closing = true;
    click(bar, testPoint(second.left + 4, 4));
    window.closing = false;
    try std.testing.expectEqual(0, window.selected);
    try std.testing.expectEqual(0, app.requests.items.len);
}

/// For tests: the bar's WM_MOUSEMOVE to `x`, `y` with the left button down.
fn testDragTo(bar: win32.HWND, x: i32, y: i32) void {
    _ = win32.SendMessageW(bar, win32.WM_MOUSEMOVE, win32.MK_LBUTTON, testPoint(x, y));
}

/// For tests: that `window`'s tabs are, in order, those showing `panes`.
fn testTabOrder(window: *const Window, panes: []const *Surface) !void {
    try std.testing.expectEqual(panes.len, window.tabs.items.len);
    for (panes, window.tabs.items) |pane, t| try std.testing.expect(t.focused == pane);
}

test "win32: a tab dragged in the bar moves among the others" {
    // A press on a tab's label shows it, and stays a click until the
    // pointer goes past the system's drag threshold with the button down;
    // then the tab follows the pointer, the others making room once it
    // has passed half of one, and stays where the button comes up, still
    // shown. Only the order changes: nothing is recorded, no window made.
    // A close glyph is never dragged.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    // Each goes after the shown tab, so they end a, b, c.
    const c = try testTab(&app, window);
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    defer _ = win32.ReleaseCapture();
    try testTabOrder(window, &.{ a, b, c });
    const layout = testBarLayout(window);
    try std.testing.expectEqual(layout.m.tab_max, layout.tab);
    const tab = layout.tab;
    // How far a tab goes before a neighbour makes room: half of one,
    // rounded up (`TabBar.Layout.dropIndex`).
    const swap = tab - @divTrunc(tab, 2);

    // b, pressed 40 px in, then moved as far as the threshold each way: a
    // click, which shows b and moves nothing.
    const x = tab + 40;
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(x, 10));
    try std.testing.expectEqual(1, window.selected);
    const threshold = window.bar.drag.?.threshold;
    try std.testing.expect(threshold.x > 0 and threshold.y > 0);
    testDragTo(bar, x + threshold.x, 10 + threshold.y);
    testDragTo(bar, x - threshold.x, 10);
    try std.testing.expect(!window.bar.drag.?.active);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(x - threshold.x, 10));
    try std.testing.expect(window.bar.drag == null);
    try std.testing.expect(win32.GetCapture() == null);
    try testTabOrder(window, &.{ a, b, c });
    try std.testing.expectEqual(1, window.selected);

    // A move without the button down, as after a release unseen, ends the
    // press: the moves after it drag nothing.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(x, 10));
    _ = win32.SendMessageW(bar, win32.WM_MOUSEMOVE, 0, testPoint(x + 5, 10));
    try std.testing.expect(window.bar.drag == null);
    testDragTo(bar, x + 2 * tab, 10);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(x + 2 * tab, 10));
    try testTabOrder(window, &.{ a, b, c });

    // b's close glyph, held and moved two tabs on: no drag.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(layout.closeRect(1)));
    testDragTo(bar, 2 * tab + 40, 10);
    try std.testing.expect(window.bar.drag == null);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(2 * tab + 40, 10));
    try testTabOrder(window, &.{ a, b, c });
    try std.testing.expect(!b.closing);

    // a, dragged right: past the threshold it is a drag, which moves
    // nothing yet; once it has passed half of b, b makes room, and then c.
    // Released there: b, c, a, with a shown.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(40, 10));
    try std.testing.expect(window.tab().focused == a);
    testDragTo(bar, 40 + threshold.x + 1, 10);
    try std.testing.expect(window.bar.drag.?.active);
    try testTabOrder(window, &.{ a, b, c });
    testDragTo(bar, 40 + swap - 1, 10);
    try testTabOrder(window, &.{ a, b, c });
    testDragTo(bar, 40 + swap, 10);
    try testTabOrder(window, &.{ b, a, c });
    try std.testing.expect(window.tab().focused == a);
    testDragTo(bar, 40 + tab + swap - 1, 14);
    try testTabOrder(window, &.{ b, a, c });
    testDragTo(bar, 40 + tab + swap, 14);
    try testTabOrder(window, &.{ b, c, a });
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(40 + tab + swap, 14));
    try testTabOrder(window, &.{ b, c, a });
    try std.testing.expectEqual(2, window.selected);
    try std.testing.expect(window.tab().focused == a);
    try std.testing.expect(shown(a.hwnd) and !shown(b.hwnd) and !shown(c.hwnd));
    try std.testing.expect(window.bar.drag == null);
    try std.testing.expect(win32.GetCapture() == null);
    try std.testing.expectEqual(0, app.requests.items.len);
    try std.testing.expectEqual(1, app.windows.items.len);

    // c, dragged left, and released past the last move, where its place
    // is first: the release counts.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    try std.testing.expect(window.tab().focused == c);
    testDragTo(bar, tab + 40 - threshold.x - 1, 10);
    try std.testing.expect(window.bar.drag.?.active);
    try testTabOrder(window, &.{ b, c, a });
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(30, 10));
    try testTabOrder(window, &.{ c, b, a });
    try std.testing.expectEqual(0, window.selected);
    try std.testing.expect(shown(c.hwnd) and !shown(a.hwnd));
    try std.testing.expectEqual(1, app.windows.items.len);
}

test "win32: a tab drag ends with a lost capture or a change of the tabs" {
    // A capture taken away puts the dragged tab back where it began, and
    // the release then does nothing; a tab closing meanwhile ends the drag
    // where it is, so that the pointer moves nothing after, nor drops the
    // tab out. Held near an end of tabs too many for the bar, the drag's
    // timer scrolls them, the dragged tab finding its place among them.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    // a, b, c, d.
    const d = try testTab(&app, window);
    const c = try testTab(&app, window);
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    defer _ = win32.ReleaseCapture();
    const tab = testBarLayout(window).tab;
    const swap = tab - @divTrunc(tab, 2);

    // a, dragged past b and c; the frame takes the capture: back first.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(40, 10));
    testDragTo(bar, 40 + tab + swap, 10);
    try testTabOrder(window, &.{ b, c, a, d });
    _ = win32.SetCapture(window.hwnd);
    try testTabOrder(window, &.{ a, b, c, d });
    try std.testing.expect(window.bar.drag == null);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(40 + tab + swap, 10));
    try testTabOrder(window, &.{ a, b, c, d });
    _ = win32.ReleaseCapture();

    // Under a prompt, whose caller may count on the order of the tabs
    // (`Window.requestCloseTabs`), the pointer moves nothing, and the
    // capture the prompt takes ends the drag where it is.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(40, 10));
    testDragTo(bar, 40 + tab + swap, 10);
    try testTabOrder(window, &.{ b, c, a, d });
    app.prompt_depth = 1;
    testDragTo(bar, 40, 10);
    try testTabOrder(window, &.{ b, c, a, d });
    _ = win32.SetCapture(window.hwnd);
    app.prompt_depth = 0;
    try testTabOrder(window, &.{ b, c, a, d });
    try std.testing.expect(window.bar.drag == null);
    _ = win32.ReleaseCapture();
    window.reorderTab(2, 0);
    try testTabOrder(window, &.{ a, b, c, d });

    // b, dragged first; d closes: the drag ends there, b first. The
    // pointer then moves nothing, and its release below the window drops
    // nothing out of it.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    testDragTo(bar, 40, 10);
    try testTabOrder(window, &.{ b, a, c, d });
    try std.testing.expect(d.destroy());
    try testTabOrder(window, &.{ b, a, c });
    try std.testing.expect(window.bar.drag == null);
    testDragTo(bar, 2 * tab + 40, 10);
    try testTabOrder(window, &.{ b, a, c });
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(2 * tab + 40, 600));
    try testTabOrder(window, &.{ b, a, c });
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expect(window.tab().focused == b);

    // Twenty tabs, b first and shown. A timer tick with no drag scrolls
    // nothing.
    for (0..17) |_| _ = try testTab(&app, window);
    window.relayout();
    const over = testBarLayout(window);
    try std.testing.expectEqual(0, over.scroll);
    try std.testing.expect(over.max_scroll > 0);
    _ = win32.SendMessageW(bar, win32.WM_TIMER, TabBar.drag_timer, 0);
    try std.testing.expectEqual(0, window.bar.scroll);

    // b, dragged to the right end and held there: each tick scrolls by
    // the step, until the end, where b is last.
    const end = over.width - over.m.plus - 1;
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(10, 10));
    testDragTo(bar, end, 10);
    try std.testing.expect(window.bar.drag.?.active);
    const step = over.autoScrollStep(end, 10);
    try std.testing.expect(step > 0);
    _ = win32.SendMessageW(bar, win32.WM_TIMER, TabBar.drag_timer, 0);
    try std.testing.expectEqual(step, window.bar.scroll);
    for (0..1000) |_| _ = win32.SendMessageW(bar, win32.WM_TIMER, TabBar.drag_timer, 0);
    try std.testing.expectEqual(over.max_scroll, window.bar.scroll);
    try std.testing.expect(window.tabs.items[19].focused == b);
    try std.testing.expectEqual(19, window.selected);
    // The highlight is what the tabs scrolled under the pointer, as for
    // the wheel, not what was there at the last move: the last tab.
    const hover = testBarLayout(window).hit(end, 10);
    try std.testing.expect(std.meta.eql(window.bar.hover, hover));
    try std.testing.expect(switch (hover) {
        .tab, .close => |index| index == 19,
        else => false,
    });

    // And back to the left end: first again.
    testDragTo(bar, 0, 10);
    for (0..1000) |_| _ = win32.SendMessageW(bar, win32.WM_TIMER, TabBar.drag_timer, 0);
    try std.testing.expectEqual(0, window.bar.scroll);
    try std.testing.expect(window.tabs.items[0].focused == b);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(0, 10));
    try std.testing.expect(window.tabs.items[0].focused == b);
    try std.testing.expectEqual(0, window.selected);
}

test "win32: a tab dropped outside its window moves to a new one" {
    // Released outside the frame, a dragged tab moves to a new window as
    // move_tab_to_new_window moves one, the new frame placed so that the
    // point where its label was grabbed is under the pointer, as far as
    // the work area allows. Under a prompt the move is recorded, naming
    // the tab's focused terminal, and made by `run`; a press there stays
    // a click, which drops nothing. A window's only tab stays.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    // a, b, c.
    const c = try testTab(&app, window);
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    defer _ = win32.ReleaseCapture();
    const tab = testBarLayout(window).tab;
    const below = 600;

    // b, pressed 40 px in and 10 down, dragged straight down out of the
    // window and released there.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    testDragTo(bar, tab + 40, 200);
    try std.testing.expect(window.bar.drag.?.active);
    testDragTo(bar, tab + 40, below);
    var at: win32.POINT = .{ .x = tab + 40, .y = below };
    try std.testing.expect(win32.ClientToScreen(bar, &at).toBool());
    var old_rect: win32.RECT = undefined;
    try std.testing.expect(win32.GetWindowRect(window.hwnd, &old_rect).toBool());
    try std.testing.expect(at.y >= old_rect.bottom);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(tab + 40, below));
    try std.testing.expectEqual(0, app.requests.items.len);
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = app.windows.items[1];
    try std.testing.expect(b.window == moved);
    try std.testing.expect(win32.GetAncestor(b.hwnd, win32.GA_PARENT) == moved.hwnd);
    try std.testing.expectEqual(1, moved.tabs.items.len);
    try std.testing.expect(shown(moved.hwnd) and shown(b.hwnd));
    try testTabOrder(window, &.{ a, c });
    try std.testing.expect(window.tab().focused == c);
    try std.testing.expect(win32.GetCapture() == null);

    // Placed for the drop: placing it again would not move it.
    var placed: win32.RECT = undefined;
    try std.testing.expect(win32.GetWindowRect(moved.hwnd, &placed).toBool());
    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    try std.testing.expect(win32.ClientToScreen(moved.hwnd, &origin).toBool());
    var info: win32.MONITORINFO = undefined;
    info.cbSize = @sizeOf(win32.MONITORINFO);
    const monitor = win32.MonitorFromPoint(at, win32.MONITOR_DEFAULTTONEAREST) orelse return error.TestUnexpectedResult;
    try std.testing.expect(win32.GetMonitorInfoW(monitor, &info).toBool());
    const drop: Window.Drop = .{ .at = at, .grab = .{ .x = 40, .y = 10 } };
    try std.testing.expectEqual(placed, Window.dropRect(placed, origin, drop, info.rcWork));

    // c, whose terminal is closing, dropped out: it stays, as for the
    // action.
    c.closing = true;
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    testDragTo(bar, tab + 40, below);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(tab + 40, below));
    c.closing = false;
    try std.testing.expectEqual(2, app.windows.items.len);
    try testTabOrder(window, &.{ a, c });

    // Under a prompt: c, dragged out as the prompt opens, is recorded,
    // and moved by run; but not while its terminal has no live core, as
    // when it is stopping (`App.requests`), and nothing is moved then.
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    try std.testing.expect(window.tab().focused == c);
    testDragTo(bar, tab + 40, below);
    app.prompt_depth = 1;
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(tab + 40, below));
    app.prompt_depth = 0;
    try std.testing.expectEqual(0, app.requests.items.len);
    try std.testing.expectEqual(2, app.windows.items.len);
    try testTabOrder(window, &.{ a, c });
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    testDragTo(bar, tab + 40, below);
    try std.testing.expect(window.bar.drag.?.active);
    app.prompt_depth = 1;
    c.core_state = .live;
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(tab + 40, below));
    app.prompt_depth = 0;
    c.core_state = .none;
    try std.testing.expectEqual(2, app.windows.items.len);
    try std.testing.expectEqual(1, app.requests.items.len);
    switch (app.requests.items[0]) {
        .move_tab_to_new_window => |move| {
            try std.testing.expect(move.from == &c.core_surface);
            try std.testing.expectEqual(at, move.drop.?.at);
            try std.testing.expectEqual(drop.grab, move.drop.?.grab);
        },
        else => return error.TestUnexpectedResult,
    }
    app.createRequested();
    try std.testing.expectEqual(3, app.windows.items.len);
    try std.testing.expect(c.window == app.windows.items[2]);
    try testTabOrder(window, &.{a});

    // Under a prompt a press stays a click: d, held and released below the
    // window, stays, and nothing is recorded.
    const d = try testTab(&app, window);
    window.relayout();
    app.prompt_depth = 1;
    d.core_state = .live;
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(tab + 40, 10));
    testDragTo(bar, tab + 40, below);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(tab + 40, below));
    app.prompt_depth = 0;
    d.core_state = .none;
    try std.testing.expectEqual(0, app.requests.items.len);
    try std.testing.expectEqual(3, app.windows.items.len);
    try testTabOrder(window, &.{ a, d });

    // A window's only tab, with its bar shown, dragged out: it stays, at
    // once and under a prompt alike.
    app.config.@"window-show-tab-bar" = .always;
    try std.testing.expect(d.destroy());
    window.relayout();
    try std.testing.expect(shown(bar));
    a.core_state = .live;
    defer a.core_state = .none;
    for ([_]u32{ 0, 1 }) |prompt| {
        _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(40, 10));
        testDragTo(bar, 40, below);
        try std.testing.expect(window.bar.drag.?.active);
        app.prompt_depth = prompt;
        _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, testPoint(40, below));
        app.prompt_depth = 0;
        try std.testing.expectEqual(0, app.requests.items.len);
        try std.testing.expectEqual(3, app.windows.items.len);
        try testTabOrder(window, &.{a});
        try std.testing.expect(a.window == window);
    }
}

test "win32: a tab dropped just past its window's visible edge moves out" {
    // GetWindowRect includes the invisible resize borders, a few pixels
    // past the frame on the left, the right and the bottom: a tab released
    // there is outside the window as it shows, and moves to a new one
    // (`TabBar.visibleBounds`); one released just inside stays. Per-monitor
    // aware, as the app is from its manifest, so that DWM's bounds are in
    // the pointer's pixels.
    const Context = struct {
        extern "user32" fn SetThreadDpiAwarenessContext(context: ?win32.HANDLE) callconv(.winapi) ?win32.HANDLE;
    };
    const before = Context.SetThreadDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) orelse
        return error.TestUnexpectedResult;
    defer _ = Context.SetThreadDpiAwarenessContext(before);

    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    const b = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    defer _ = win32.ReleaseCapture();
    const tab = testBarLayout(window).tab;

    // The border this is about, which Windows 11 gives the frame.
    var rect: win32.RECT = undefined;
    try std.testing.expect(win32.GetWindowRect(window.hwnd, &rect).toBool());
    const visible = TabBar.visibleBounds(window.hwnd).?;
    try std.testing.expect(visible.bottom + 2 < rect.bottom);

    // b, pressed 40 px in, dragged down to a row of the screen and
    // released there.
    const Drop = struct {
        fn at(bar_: win32.HWND, x: i32, screen_y: i32) !win32.POINT {
            var p: win32.POINT = .{ .x = x, .y = 0 };
            if (!win32.ClientToScreen(bar_, &p).toBool()) return error.TestUnexpectedResult;
            p.y = screen_y;
            if (!win32.ScreenToClient(bar_, &p).toBool()) return error.TestUnexpectedResult;
            return p;
        }
        fn release(bar_: win32.HWND, p: win32.POINT) void {
            _ = win32.SendMessageW(bar_, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(p.x, 10));
            testDragTo(bar_, p.x, 100);
            testDragTo(bar_, p.x, p.y);
            _ = win32.SendMessageW(bar_, win32.WM_LBUTTONUP, 0, testPoint(p.x, p.y));
        }
    };

    // Just inside the visible frame: it stays.
    Drop.release(bar, try Drop.at(bar, tab + 40, visible.bottom - 2));
    try std.testing.expectEqual(1, app.windows.items.len);
    try testTabOrder(window, &.{ a, b });

    // Just past it, still inside the window rect: it moves out.
    Drop.release(bar, try Drop.at(bar, tab + 40, visible.bottom + 1));
    try std.testing.expectEqual(2, app.windows.items.len);
    try std.testing.expect(b.window == app.windows.items[1]);
    try testTabOrder(window, &.{a});
}

test "win32: a tab dropped on a monitor of another DPI is placed again there" {
    // The new frame, made at one DPI, gets WM_DPICHANGED as its place for
    // the drop takes it to a monitor with another, and the rect Windows
    // suggests, scaled about the frame's centre here, moves it off the
    // drop: it is placed again from its new size, so that the label is
    // under the pointer and the frame inside the work area, near the work
    // area's corner too. A fake GetDpiForWindow, and a hook sending the
    // WM_DPICHANGED Windows would send, stand in for a second monitor.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try Window.createBare(&app);
    defer window.discard();

    const Monitor = struct {
        var frame: win32.HWND = undefined;
        var dpi: win32.UINT = 96;
        /// The next move of the frame takes it to the other monitor.
        var armed = false;
        var changes: usize = 0;

        fn dpiOf(hwnd: win32.HWND) callconv(.winapi) win32.UINT {
            return if (hwnd == frame) dpi else 96;
        }

        fn proc(code: c_int, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
            if (code >= 0) {
                const sent: *const win32.CWPRETSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (armed and sent.hwnd == frame and sent.message == win32.WM_WINDOWPOSCHANGED) {
                    armed = false;
                    changes += 1;
                    dpi = 144;
                    var r: win32.RECT = undefined;
                    if (win32.GetWindowRect(frame, &r).toBool()) {
                        const w = @divTrunc(r.right - r.left, 4);
                        const h = @divTrunc(r.bottom - r.top, 4);
                        var suggested: win32.RECT = .{
                            .left = r.left - w,
                            .top = r.top - h,
                            .right = r.right + w,
                            .bottom = r.bottom + h,
                        };
                        _ = win32.SendMessageW(frame, win32.WM_DPICHANGED, 144 << 16 | 144, @bitCast(@intFromPtr(&suggested)));
                    }
                }
            }
            return win32.CallNextHookEx(null, code, wparam, lparam);
        }
    };
    Monitor.frame = window.hwnd;
    app.get_dpi_for_window = &Monitor.dpiOf;
    const hook = win32.SetWindowsHookExW(
        win32.WH_CALLWNDPROCRET,
        Monitor.proc,
        null,
        std.os.windows.GetCurrentThreadId(),
    ) orelse return error.TestUnexpectedResult;
    defer _ = win32.UnhookWindowsHookEx(hook);

    const info = try monitorOf(window.hwnd);
    const work = info.rcWork;
    const grab: win32.POINT = .{ .x = 40, .y = 10 };
    for ([_]win32.POINT{
        // The middle of the work area, where the frame fits as it is.
        .{ .x = @divTrunc(work.left + work.right, 2), .y = @divTrunc(work.top + work.bottom, 2) },
        // Its bottom-right corner, where it is pushed back inside.
        .{ .x = work.right - 5, .y = work.bottom - 5 },
    }, 0..) |at, i| {
        // At 400x240 at the work area's corner, at 96 DPI.
        Monitor.dpi = 96;
        try std.testing.expect(win32.SetWindowPos(
            window.hwnd,
            null,
            work.left,
            work.top,
            400,
            240,
            win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        ).toBool());
        Monitor.armed = true;
        window.placeForDrop(.{ .at = at, .grab = grab });
        try std.testing.expectEqual(i + 1, Monitor.changes);

        // At the size the new DPI gave it, inside the work area.
        var placed: win32.RECT = undefined;
        try std.testing.expect(win32.GetWindowRect(window.hwnd, &placed).toBool());
        try std.testing.expectEqual(600, placed.right - placed.left);
        try std.testing.expectEqual(360, placed.bottom - placed.top);
        try std.testing.expect(placed.left >= work.left and placed.top >= work.top);
        try std.testing.expect(placed.right <= work.right and placed.bottom <= work.bottom);
        // The label under the pointer where the work area allows.
        var origin: win32.POINT = .{ .x = 0, .y = 0 };
        try std.testing.expect(win32.ClientToScreen(window.hwnd, &origin).toBool());
        try std.testing.expectEqual(placed, Window.dropRect(placed, origin, .{ .at = at, .grab = grab }, work));
        if (i == 0) {
            try std.testing.expectEqual(at.x, origin.x + grab.x);
            try std.testing.expectEqual(at.y, origin.y + grab.y);
        }
    }
}

test "win32: the tab bar goes in fullscreen though the client area keeps its size" {
    // A frame without the overlapped styles, at its monitor's rect, keeps
    // its client area when it covers the monitor: no WM_SIZE comes, as on a
    // monitor whose work area is all of it. The bar goes all the same, and
    // comes back with a tab opened meanwhile.
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
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    const b = try testTab(&app, window);
    window.selectTab(1);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const bar = window.bar.hwnd.?;

    const overlapped: isize = win32.WS_OVERLAPPEDWINDOW;
    const style = win32.GetWindowLongPtrW(window.hwnd, win32.GWL_STYLE);
    _ = win32.SetWindowLongPtrW(window.hwnd, win32.GWL_STYLE, style & ~overlapped);
    const m = (try monitorOf(window.hwnd)).rcMonitor;
    _ = win32.SetWindowPos(
        window.hwnd,
        null,
        m.left,
        m.top,
        m.right - m.left,
        m.bottom - m.top,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED,
    );
    try std.testing.expect(shown(bar));
    const before = try clientRect(window.hwnd);

    window.toggleFullscreen();
    try std.testing.expectEqual(before, try clientRect(window.hwnd));
    try std.testing.expect(!shown(bar));
    try std.testing.expectEqual(0, (try paneRect(window, b)).top);

    const c = try testTab(&app, window);
    window.selectTab(window.find(c).?.index);
    window.toggleFullscreen();
    try std.testing.expect(shown(bar));
}

test "win32: the tab bar keeps the shown tab in sight" {
    // Narrower, or with the shown tab moved round to the end, the bar
    // scrolls to show it, as selecting it does.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    for (0..19) |_| _ = try testTab(&app, window);
    window.relayout();
    const inSight = struct {
        fn f(w: *Window) bool {
            const l = testBarLayout(w);
            const r = l.tabRect(w.selected);
            return r.left >= 0 and r.right <= l.width - l.m.plus;
        }
    }.f;

    window.selectTab(9);
    try std.testing.expectEqual(0, window.bar.scroll);
    try std.testing.expect(inSight(window));
    testResize(window, 400, 300);
    try std.testing.expect(window.bar.scroll > 0);
    try std.testing.expect(inSight(window));

    window.selectTab(0);
    try std.testing.expectEqual(0, window.bar.scroll);
    try std.testing.expect(window.moveTab(a, -1));
    try std.testing.expectEqual(19, window.selected);
    try std.testing.expect(inSight(window));
}

test "win32: the tab bar counts in every size it takes from the client area" {
    // A new tab's terminal starts under the bar that tab brings. With
    // window-show-tab-bar = always one terminal has the bar above it: a
    // size asked for it comes on top, and splits, resized or equalized,
    // measure from under it. Its close glyph closes the window, its one
    // tab.
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
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    const height = TabBar.Metrics.init(Window.dpiOf(&app, window.hwnd)).height;
    try std.testing.expectEqual(0, window.layoutArea().?.top);
    try std.testing.expectEqual(height, window.newTabArea().?.top);

    app.config.@"window-show-tab-bar" = .always;
    window.relayout();
    try std.testing.expect(shown(bar));
    try std.testing.expectEqual(height, (try paneRect(window, a)).top);

    const target: apprt.Target = .{ .surface = &a.core_surface };
    const scale = try a.getContentScale();
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 0, .height = 200 }));
    app.createRequested();
    var client = try clientRect(window.hwnd);
    try std.testing.expectEqual(Window.scaledSize(200, scale.y) + height, client.bottom);
    try std.testing.expectEqual(height, (try paneRect(window, a)).top);

    a.initial_size = .{ .width = 320, .height = 180 };
    try std.testing.expect(try app.performAction(target, .reset_window_size, {}));
    app.createRequested();
    client = try clientRect(window.hwnd);
    try std.testing.expectEqual(Window.scaledSize(180, scale.x) + height, client.bottom);

    // a over b.
    const b = try testPane(&app, window);
    window.tab().tree.deinit();
    window.tab().tree = try testLine(alloc, &.{ a, b }, .down);
    testResize(window, 400, 400);
    const before = try paneRect(window, a);
    try std.testing.expectEqual(height, before.top);
    window.resizeSplit(a, .{ .amount = 100, .direction = .down });
    try expectNear(before.bottom + 100, (try paneRect(window, a)).bottom);
    window.equalize(a);
    const ra = try paneRect(window, a);
    const rb = try paneRect(window, b);
    try expectNear(ra.bottom - ra.top, rb.bottom - rb.top);
    try std.testing.expectEqual((try clientRect(window.hwnd)).bottom, rb.bottom);

    // a over b over c, under a bar that leaves a divider and a pixel: a
    // has that pixel, b and c none. Equalized, a would have none there, so
    // nothing moves; over the whole client area each would keep a row, and
    // with room they share it.
    const c = try testPane(&app, window);
    window.tab().tree.deinit();
    window.tab().tree = try testLine(alloc, &.{ a, b, c }, .down);
    const divider = Window.dividerWidth(Window.dpiOf(&app, window.hwnd));
    const frame = try windowRect(window.hwnd);
    const nonclient = (frame.bottom - frame.top) - (try clientRect(window.hwnd)).bottom;
    testResize(window, 400, nonclient + height + divider + 1);
    window.relayout();
    try std.testing.expectEqual(height + divider + 1, (try clientRect(window.hwnd)).bottom);
    const crowded = try paneRect(window, a);
    try std.testing.expectEqual(height, crowded.top);
    try std.testing.expectEqual(height + 1, crowded.bottom);
    window.equalize(a);
    try std.testing.expectEqual(crowded, try paneRect(window, a));
    testResize(window, 400, 400);
    window.equalize(a);
    const ea = try paneRect(window, a);
    const eb = try paneRect(window, b);
    const ec = try paneRect(window, c);
    try expectNear(ea.bottom - ea.top, eb.bottom - eb.top);
    try expectNear(eb.bottom - eb.top, ec.bottom - ec.top);

    const close = testMid(testBarLayout(window).closeRect(0));
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, close);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONUP, 0, close);
    try std.testing.expect(window.closing);
}

test "win32: only a title a tab's label shows repaints the tab bar" {
    // A tab's label shows its focused terminal's title, or its own: a
    // title from another of its terminals, or under a title of its own,
    // changes no label, as on GTK.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    const c = try testTab(&app, window);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    const bar = window.bar.hwnd.?;
    try std.testing.expect(shown(bar));
    const pending = struct {
        fn f(hwnd: win32.HWND) bool {
            return win32.GetUpdateRect(hwnd, null, .FALSE).toBool();
        }
    }.f;

    _ = win32.UpdateWindow(bar);
    try std.testing.expect(!pending(bar));
    try std.testing.expect(b.setTitle("unfocused"));
    try std.testing.expect(!pending(bar));
    try std.testing.expect(a.setTitle("focused"));
    try std.testing.expect(pending(bar));

    try std.testing.expect(window.setTabTitle(a, "own"));
    _ = win32.UpdateWindow(bar);
    try std.testing.expect(a.setTitle("under its own"));
    try std.testing.expect(!pending(bar));

    // A hidden tab's focused terminal: its label shows it.
    try std.testing.expect(c.setTitle("hidden"));
    try std.testing.expect(pending(bar));
}

test "win32: a window terminate gave up on leaves its tab bar no back-pointer" {
    // As App.terminate does when DestroyWindow fails on a frame: the
    // Window is freed, its frame and bar stay. A message to the bar then
    // touches nothing freed.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const frame = window.hwnd;
    const bar = window.bar.hwnd.?;
    app.windowDestroyed(window);
    try std.testing.expectEqual(0, app.windows.items.len);
    _ = win32.SendMessageW(bar, win32.WM_MOUSEMOVE, 0, testPoint(4, 4));
    _ = win32.SendMessageW(bar, win32.WM_MOUSEWHEEL, testWheel(-120), 0);
    _ = win32.SendMessageW(bar, win32.WM_LBUTTONDOWN, 0, testPoint(4, 4));
    try std.testing.expect(win32.DestroyWindow(frame).toBool());
}

/// For tests: resize `window`'s frame, which lays it out (WM_SIZE).
fn testResize(window: *Window, width: c_int, height: c_int) void {
    _ = win32.SetWindowPos(
        window.hwnd,
        null,
        0,
        0,
        width,
        height,
        win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOMOVE,
    );
}

/// For tests: a mouse message's lParam for the client point `x`, `y`.
fn testPoint(x: i32, y: i32) win32.LPARAM {
    const xy: u32 = @as(u32, @as(u16, @bitCast(@as(i16, @intCast(x))))) |
        (@as(u32, @as(u16, @bitCast(@as(i16, @intCast(y))))) << 16);
    return @bitCast(@as(usize, xy));
}

/// For tests: a mouse message's lParam for the middle of `r`.
fn testMid(r: win32.RECT) win32.LPARAM {
    return testPoint(@divTrunc(r.left + r.right, 2), @divTrunc(r.top + r.bottom, 2));
}

/// For tests: WM_MOUSEWHEEL's wParam for a turn of `delta`.
fn testWheel(delta: i16) win32.WPARAM {
    return @as(win32.WPARAM, @as(u16, @bitCast(delta))) << 16;
}

/// For tests: the layout of `window`'s bar now, as its window procedure
/// works it out.
fn testBarLayout(window: *Window) TabBar.Layout {
    const bar = window.bar.hwnd.?;
    var client: win32.RECT = undefined;
    if (!win32.GetClientRect(bar, &client).toBool()) client.right = 0;
    return .init(.init(Window.dpiOf(window.app, bar)), window.tabs.items.len, client.right, window.bar.scroll);
}

/// For tests: run the teardowns posted so far.
fn testTeardowns() void {
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool()) {
        _ = win32.DispatchMessageW(&msg);
    }
}

test "win32: close_tab closes the window, its one tab" {
    // A window's only tab is the window, so close_tab:this, the default
    // Ctrl+Shift+W, closes it as close_window does: one teardown is posted
    // to the frame, and it frees the window and its terminals. The other
    // modes name no tab there: the action reports not performed (a
    // `performable:` binding then passes its key to the terminal), and
    // nothing is posted.
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
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;

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
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;

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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;

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
    // A split needs a surface to go beside, and a tab a window to go in.
    try std.testing.expect(!try app.performAction(.app, .new_split, .left));
    try std.testing.expect(try app.performAction(.{ .surface = open }, .new_tab, {}));
    try std.testing.expect(try app.performAction(.{ .surface = closed }, .new_tab, {}));
    try std.testing.expect(!try app.performAction(.app, .new_tab, {}));
    try std.testing.expectEqual(0, app.surfaces.items.len);

    app.forgetClosing(closed);

    const want = [_]App.Request{
        .{ .window = open },
        .{ .window = null },
        .{ .window = null },
        .{ .split = .{ .parent = open, .direction = .right } },
        .dropped,
        .{ .tab = open },
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
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
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, pane));

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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
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
    alone.tab().tree = try .init(alloc, only);
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
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
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
        window.tab().focused = a;
        try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .toggle_split_zoom, {}));
        app.createRequested();
        b.core_state = .live;
        const goes = try app.performAction(.{ .surface = &a.core_surface }, .goto_split, .right);
        b.core_state = .none;
        try std.testing.expect(goes);
        app.applyPendingFocus();
        try std.testing.expect(window.tab().focused == b);
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
        w.*.tab().tree = try .init(alloc, p.*);
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    const target: apprt.Target = .{ .surface = &pane.core_surface };
    const scale = try pane.getContentScale();

    // Recorded, not made; then the width, and the height kept.
    const before = try clientRect(window.hwnd);
    try std.testing.expect(try app.performAction(target, .resize_window, .{ .width = 300, .height = 0 }));
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expectEqual(before, try clientRect(window.hwnd));
    app.createRequested();
    // The terminal's grid, beside which its scroll bar goes.
    const wide = try clientRect(window.hwnd);
    const bar = ScrollBar.width(pane);
    try std.testing.expect(bar > 0);
    try std.testing.expectEqual(Window.scaledSize(300, scale.x), (try clientRect(pane.hwnd)).right);
    try std.testing.expectEqual(Window.scaledSize(300, scale.x) + bar, wide.right);
    try std.testing.expectEqual(before.bottom, wide.bottom);
    try std.testing.expectEqual(wide, try paneRect(window, pane));

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
    window.tab().tree.deinit();
    window.tab().tree = try testRow(alloc, &.{ pane, other });
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
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
    // The terminal's grid, beside which its scroll bar goes.
    const sized = try clientRect(window.hwnd);
    try std.testing.expect(ScrollBar.width(pane) > 0);
    try std.testing.expectEqual(Window.scaledSize(320, scale.x), (try clientRect(pane.hwnd)).right);
    try std.testing.expectEqual(Window.scaledSize(320, scale.x) + ScrollBar.width(pane), sized.right);
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
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
    {
        const text = (try readClipboardText(alloc, pane.hwnd)) orelse return error.TestUnexpectedResult;
        defer alloc.free(text);
        try std.testing.expectEqualStrings("vim café", text);
    }

    // The title shown, as GTK copies its effective title: the one the user
    // gave the terminal in its title prompt.
    try testAnswer(try testPrompt(&app, pane, .surface), "mine", win32.IDOK);
    try std.testing.expect(try app.performAction(target, .copy_title_to_clipboard, {}));
    const text = (try readClipboardText(alloc, pane.hwnd)) orelse return error.TestUnexpectedResult;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("mine", text);
}

/// For tests: `pane`'s title prompt for `which`, opened as a binding opens
/// it: the action, then `run`'s requests (`createRequested`).
fn testPrompt(app: *App, pane: *Surface, which: apprt.action.PromptTitle) !win32.HWND {
    try std.testing.expect(try app.performAction(.{ .surface = &pane.core_surface }, .prompt_title, which));
    app.createRequested();
    return pane.window.title_prompt.hwnd orelse error.TestUnexpectedResult;
}

/// For tests: a title prompt's field.
fn testField(dialog: win32.HWND) !win32.HWND {
    return win32.GetDlgItem(dialog, TitleDialog.edit_id) orelse error.TestUnexpectedResult;
}

/// For tests: put `text` in a title prompt's field, then press `button`
/// (IDOK or IDCANCEL), as a click on it sends.
fn testAnswer(dialog: win32.HWND, comptime text: []const u8, button: c_int) !void {
    _ = win32.SetWindowTextW(try testField(dialog), L(text));
    _ = win32.SendMessageW(dialog, win32.WM_COMMAND, @intCast(button), 0);
}

/// For tests: `hwnd`'s text is `want`.
fn expectText(comptime want: []const u8, hwnd: win32.HWND) !void {
    var buf: [128]u16 = undefined;
    const n = win32.GetWindowTextW(hwnd, &buf, buf.len);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(want), buf[0..@intCast(n)]);
}

test "win32: prompt_title waits for run, and the terminal's title from it shows over the program's" {
    // The dialog takes the keyboard focus from the terminal, so the action
    // is recorded and the dialog opened by createRequested. OK sets the
    // terminal's own title, which OSC titles do not replace; an empty one
    // shows the program's latest again; Cancel changes nothing. The core's
    // title stays the program's.
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
    try std.testing.expect(pane.setTitle("cmd"));
    const target: apprt.Target = .{ .surface = &pane.core_surface };

    // Not for the app, nor for a window, which has no title of its own on
    // this platform: its caption is its shown tab's.
    try std.testing.expect(!try app.performAction(.app, .prompt_title, .surface));
    try std.testing.expect(!try app.performAction(target, .prompt_title, .window));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Recorded, and opened by run.
    try std.testing.expect(try app.performAction(target, .prompt_title, .surface));
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
    app.createRequested();
    const dialog = window.title_prompt.hwnd orelse return error.TestUnexpectedResult;
    // Modal to its window, and not on screen while the window is not;
    // GTK's heading, and the field holds the title shown.
    try std.testing.expect(!win32.IsWindowEnabled(window.hwnd).toBool());
    try std.testing.expect(!win32.IsWindowVisible(dialog).toBool());
    try expectText("Change Terminal Title", dialog);
    try expectText("cmd", try testField(dialog));

    // Asked again while it is open: it stays as it is.
    try std.testing.expect(try app.performAction(target, .prompt_title, .tab));
    app.createRequested();
    try std.testing.expect(window.title_prompt.hwnd == dialog);
    try expectText("Change Terminal Title", dialog);

    // OK: the terminal's title is the user's, the window takes input
    // again, and the core still reads the program's.
    try testAnswer(dialog, "mine", win32.IDOK);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(dialog).toBool());
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
    try expectText("mine", window.hwnd);
    try std.testing.expectEqualStrings("mine", Window.tabTitle(window.tab()).?);
    try std.testing.expectEqualStrings("cmd", pane.getTitle().?);

    // An OSC title changes the program's, not what shows.
    try std.testing.expect(try app.performAction(target, .set_title, .{ .title = "osc" }));
    try expectText("mine", window.hwnd);
    try std.testing.expectEqualStrings("osc", pane.getTitle().?);

    // The field starts with the user's title; Cancel changes nothing.
    const again = try testPrompt(&app, pane, .surface);
    try expectText("mine", try testField(again));
    try testAnswer(again, "other", win32.IDCANCEL);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
    try expectText("mine", window.hwnd);

    // Enter in the field is OK, as `run` dispatches it (`dispatch`, which
    // hands the dialog its messages); one for the terminal is not the
    // dialog's. Empty, it shows the program's latest title again.
    const third = try testPrompt(&app, pane, .surface);
    const field = try testField(third);
    var msg: win32.MSG = .{
        .hwnd = pane.hwnd,
        .message = win32.WM_KEYDOWN,
        .wParam = win32.VK_RETURN,
        .lParam = 0,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };
    try std.testing.expect(!app.dialogMessage(&msg));
    try std.testing.expect(window.title_prompt.hwnd == third);
    _ = win32.SetWindowTextW(field, L(""));
    msg.hwnd = field;
    app.dispatch(&msg);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(pane.title_override == null);
    try expectText("osc", window.hwnd);
}

test "win32: a tab's title prompt names the tab, over its terminals' own titles" {
    // As GTK computes a tab's title: the tab's own, else its focused
    // terminal's own, else the program's.
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
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    const b = try testTab(&app, window);
    const ta = window.tabOf(a).?;
    const tb = window.tabOf(b).?;
    try std.testing.expect(a.setTitle("vim"));
    try std.testing.expect(b.setTitle("cmd"));

    // The terminal's own title labels its tab.
    try testAnswer(try testPrompt(&app, a, .surface), "edit", win32.IDOK);
    try std.testing.expectEqualStrings("edit", Window.tabTitle(ta).?);

    // The tab's, which starts from that, shows over it.
    const dialog = try testPrompt(&app, a, .tab);
    try expectText("Change Tab Title", dialog);
    try expectText("edit", try testField(dialog));
    try testAnswer(dialog, "build", win32.IDOK);
    try std.testing.expectEqualStrings("build", ta.title_override.?);
    try std.testing.expectEqualStrings("edit", a.title_override.?);
    try expectText("build", window.hwnd);

    // Empty, it ends the tab's: the terminal's own shows again.
    const again = try testPrompt(&app, a, .tab);
    try expectText("build", try testField(again));
    try testAnswer(again, "", win32.IDOK);
    try std.testing.expect(ta.title_override == null);
    try expectText("edit", window.hwnd);

    // A hidden tab's: its label changes, the caption does not.
    try testAnswer(try testPrompt(&app, b, .tab), "logs", win32.IDOK);
    try std.testing.expectEqualStrings("logs", Window.tabTitle(tb).?);
    try expectText("edit", window.hwnd);
}

test "win32: a title prompt closes with its terminal, and never opens for a closing one" {
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
    const a2 = try testPane(&app, window);
    const a3 = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, a2, a3 });
    window.tab().focused = a;

    // Asked for by a terminal that begins to close before run: dropped.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .prompt_title, .surface));
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expect(window.title_prompt.hwnd == null);

    // Open when it begins to close: it closes, and its window takes input.
    const dialog = try testPrompt(&app, a, .surface);
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(dialog).toBool());
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());

    // Another terminal of the window closing leaves it open.
    const kept = try testPrompt(&app, a, .surface);
    app.forgetClosing(&a2.core_surface);
    try std.testing.expect(window.title_prompt.hwnd == kept);
    try std.testing.expect(!win32.IsWindowEnabled(window.hwnd).toBool());

    // Destroyed by anything but its own close, it lets go of the window.
    try std.testing.expect(win32.DestroyWindow(kept).toBool());
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());

    // A terminal torn down with no core, which never passes through
    // forgetClosing: its prompt closes as it is freed.
    const freed = try testPrompt(&app, a3, .surface);
    try std.testing.expect(a3.destroy());
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(freed).toBool());
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());

    // None opens for a terminal already closing, nor in a closing window.
    a2.requestClose();
    try std.testing.expect(try app.performAction(.{ .surface = &a2.core_surface }, .prompt_title, .surface));
    app.createRequested();
    try std.testing.expect(window.title_prompt.hwnd == null);
    window.requestClose();
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .prompt_title, .tab));
    app.createRequested();
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
}

test "win32: a title prompt closes when its terminal's tab moves to a new window" {
    // It is modal to the window it opened over, which a move from another
    // window would leave disabled for a terminal no longer in it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    const b = try testTab(&app, window);
    _ = try testTab(&app, window);

    const dialog = try testPrompt(&app, a, .surface);

    // Another tab's move leaves it.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    try std.testing.expect(window.title_prompt.hwnd == dialog);
    try std.testing.expect(!win32.IsWindowEnabled(window.hwnd).toBool());

    // Its terminal's: it closes, and the window takes input again.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(3, app.windows.items.len);
    try std.testing.expect(a.window != window);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(dialog).toBool());
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
}

test "win32: a frame is enabled only when neither a prompt nor its title prompt holds it" {
    // Three things hold a frame: a confirmation prompt (every frame but
    // its owner), MessageBoxW (its owner) and the frame's title prompt.
    // Whichever lets go last enables it. MessageBoxW itself is never
    // called here: it would block the test.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const f = try testFrame(&app);
    const a = try testPane(&app, f);
    f.tab().tree = try .init(alloc, a);
    f.tab().focused = a;
    const g = try testFrame(&app);
    const b = try testPane(&app, g);
    g.tab().tree = try .init(alloc, b);
    g.tab().focused = b;
    const enabled = struct {
        fn check(hwnd: win32.HWND) bool {
            return win32.IsWindowEnabled(hwnd).toBool();
        }
    }.check;

    // A prompt of the other window's opens over the title prompt, which
    // it disables too, and the title prompt closes first: the frame waits
    // for the prompt's end.
    const dialog = try testPrompt(&app, a, .surface);
    app.beginPrompt(g.hwnd);
    try std.testing.expect(!enabled(dialog));
    try std.testing.expect(!enabled(f.hwnd));
    try std.testing.expect(enabled(g.hwnd));
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(f.title_prompt.hwnd == null);
    try std.testing.expect(!enabled(f.hwnd));
    app.endPrompt();
    try std.testing.expect(enabled(f.hwnd));
    try std.testing.expect(enabled(g.hwnd));

    // A prompt owned by the frame itself, which ends first: the title
    // prompt still holds the frame, even if MessageBoxW enabled its owner
    // on the way out, and takes input again.
    const again = try testPrompt(&app, a, .surface);
    app.beginPrompt(f.hwnd);
    try std.testing.expect(!enabled(again));
    try std.testing.expect(!enabled(f.hwnd));
    try std.testing.expect(!enabled(g.hwnd));
    _ = win32.EnableWindow(f.hwnd, .TRUE);
    app.endPrompt();
    try std.testing.expect(!enabled(f.hwnd));
    try std.testing.expect(enabled(again));
    try std.testing.expect(enabled(g.hwnd));
    try testAnswer(again, "t", win32.IDOK);
    try std.testing.expect(enabled(f.hwnd));
}

/// For tests: the window `Window.bringForward` last asked to make the
/// foreground window (`Window.test_foreground`).
const ForegroundSeen = struct {
    var last: ?win32.HWND = null;
    fn seen(hwnd: win32.HWND) void {
        last = hwnd;
    }
};

test "win32: a confirmation prompt over a title prompt's window is owned by the title prompt" {
    // So that MessageBoxW, which disables its owner and enables it again
    // with the activation as it returns, gives the keyboard back to the
    // title prompt, not to the frame the title prompt holds disabled.
    // MessageBoxW itself is never called here: it would block the test;
    // what it does to its owner is done by hand.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const f = try testFrame(&app);
    const a = try testPane(&app, f);
    f.tab().tree = try .init(alloc, a);
    f.tab().focused = a;
    const g = try testFrame(&app);
    const b = try testPane(&app, g);
    g.tab().tree = try .init(alloc, b);
    g.tab().focused = b;
    const enabled = struct {
        fn check(hwnd: win32.HWND) bool {
            return win32.IsWindowEnabled(hwnd).toBool();
        }
    }.check;

    // With no title prompt, a terminal's prompt is its frame's.
    try std.testing.expect(app.promptOwner(a.hwnd) == f.hwnd);

    // A terminal under a title prompt (an OSC 52 read asking): the title
    // prompt's; another window's terminal: its own frame's.
    const dialog = try testPrompt(&app, a, .surface);
    const owner = app.promptOwner(a.hwnd) orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner == dialog);
    try std.testing.expect(app.promptOwner(b.hwnd) == g.hwnd);

    // The title prompt is left for MessageBoxW to disable; every frame is
    // held.
    app.beginPrompt(owner);
    try std.testing.expect(enabled(dialog));
    try std.testing.expect(!enabled(f.hwnd));
    try std.testing.expect(!enabled(g.hwnd));
    try std.testing.expect(!f.title_prompt.prompt_disabled);
    _ = win32.EnableWindow(dialog, .FALSE);
    _ = win32.EnableWindow(dialog, .TRUE);
    app.endPrompt();
    try std.testing.expect(enabled(dialog));
    try std.testing.expect(!enabled(f.hwnd));
    try std.testing.expect(enabled(g.hwnd));
    try testAnswer(dialog, "t", win32.IDOK);
    try std.testing.expect(enabled(f.hwnd));
}

test "win32: presenting a window with its title prompt open brings the prompt forward" {
    // goto_window, present_terminal and a toast's click present a window
    // (`Window.present`); the prompt is where the keyboard goes, and the
    // frame takes no input while it is open.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_foreground = &ForegroundSeen.seen;
    defer Window.test_foreground = null;
    ForegroundSeen.last = null;

    const f = try testFrame(&app);
    const a = try testPane(&app, f);
    f.tab().tree = try .init(alloc, a);
    f.tab().focused = a;
    const g = try testFrame(&app);
    const b = try testPane(&app, g);
    g.tab().tree = try .init(alloc, b);
    g.tab().focused = b;

    const dialog = try testPrompt(&app, a, .surface);

    // goto_window from the other window.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .goto_window, .next));
    app.createRequested();
    try std.testing.expect(ForegroundSeen.last == dialog);

    // present_terminal for the terminal under it.
    ForegroundSeen.last = null;
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .present_terminal, {}));
    try std.testing.expect(ForegroundSeen.last == dialog);

    // Once it is closed, the frame itself.
    try testAnswer(dialog, "", win32.IDCANCEL);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .present_terminal, {}));
    try std.testing.expect(ForegroundSeen.last == f.hwnd);
}

test "win32: the key that closes a title prompt reaches its terminal as no release" {
    // Escape closes the prompt on its key-down, inside IsDialogMessageW;
    // the frame then gives its terminal the focus, and the key-up comes
    // there. The core never saw the press, so the release is withheld.
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;

    const dialog = try testPrompt(&app, pane, .surface);
    const field = try testField(dialog);

    // Scan code 0x01 (Escape), extended Right arrow 0x4D: the scan slot
    // is lParam bits 16-24.
    const esc_down: win32.LPARAM = 0x0001_0001;
    const esc_up: win32.LPARAM = @bitCast(@as(usize, 0xC001_0001));
    const esc_slot = 0x001;
    const right_down: win32.LPARAM = 0x014D_0001;
    const vk_right: win32.WPARAM = 0x27;
    var msg: win32.MSG = .{
        .hwnd = field,
        .message = win32.WM_KEYDOWN,
        .wParam = vk_right,
        .lParam = right_down,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };

    // A key the field keeps leaves the terminal's keys alone.
    app.dispatch(&msg);
    try std.testing.expect(window.title_prompt.hwnd == dialog);
    try std.testing.expectEqual(0, pane.ime.swallow_up.count());

    // Escape closes it, as `run` dispatches it.
    msg.wParam = win32.VK_ESCAPE;
    msg.lParam = esc_down;
    app.dispatch(&msg);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(pane.ime.swallow_up.isSet(esc_slot));

    // Its release, through the terminal's own key handling, is withheld
    // before the core is reached (this pane has none to reach).
    pane.core_state = .live;
    defer pane.core_state = .none;
    _ = win32.SendMessageW(pane.hwnd, win32.WM_KEYUP, win32.VK_ESCAPE, esc_up);
    try std.testing.expect(!pane.ime.swallow_up.isSet(esc_slot));
}

test "win32: a title prompt opened over a window not shown yet shows with it" {
    // It holds the frame disabled from the start; shown only with its
    // frame, it would otherwise leave the frame disabled with nothing on
    // screen to answer.
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;

    const dialog = try testPrompt(&app, pane, .surface);
    try std.testing.expect(!shown(dialog));
    try std.testing.expect(!win32.IsWindowEnabled(window.hwnd).toBool());

    window.show();
    try std.testing.expect(shown(window.hwnd));
    try std.testing.expect(shown(dialog));
    try std.testing.expect(!win32.IsWindowEnabled(window.hwnd).toBool());
    try testAnswer(dialog, "", win32.IDCANCEL);
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
}

test "win32: a tab's title prompt belongs to the tab, not to the terminal that asked" {
    // As GTK ties its dialog to the tab: the terminal that asked closing
    // passes it to another of the tab's; the tab going, or moving to a new
    // window, closes it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 800, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    const c = try testTab(&app, window);
    _ = try testTab(&app, window);

    // The terminal that asked closes; the tab lives on in the other one,
    // and so does its prompt, which then names the tab.
    const dialog = try testPrompt(&app, a, .tab);
    try std.testing.expect(a.destroy());
    try std.testing.expect(window.title_prompt.hwnd == dialog);
    try std.testing.expect(window.title_prompt.surface == b);
    try std.testing.expect(!win32.IsWindowEnabled(window.hwnd).toBool());
    try testAnswer(dialog, "build", win32.IDOK);
    try std.testing.expectEqualStrings("build", window.tabOf(b).?.title_override.?);
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());

    // The tab's last terminal closes, and the tab with it: so does its
    // prompt.
    const again = try testPrompt(&app, b, .tab);
    try std.testing.expect(b.destroy());
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(again).toBool());
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());

    // The tab moves to a new window: its prompt closes.
    const moved = try testPrompt(&app, c, .tab);
    try std.testing.expect(try app.performAction(.{ .surface = &c.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expect(c.window != window);
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(moved).toBool());
    try std.testing.expect(win32.IsWindowEnabled(window.hwnd).toBool());
}

test "win32: a window closing with its title prompt open leaves nothing held" {
    // Its close takes the prompt first, before any of its terminals
    // stops; the other window is untouched.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const f = try testFrame(&app);
    const a = try testPane(&app, f);
    const b = try testPane(&app, f);
    f.tab().tree = try testRow(alloc, &.{ a, b });
    f.tab().focused = a;
    const g = try testFrame(&app);
    const c = try testPane(&app, g);
    g.tab().tree = try .init(alloc, c);
    g.tab().focused = c;

    const dialog = try testPrompt(&app, b, .tab);
    try std.testing.expect(f.destroy());
    try std.testing.expect(!win32.IsWindow(dialog).toBool());
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expect(app.windows.items[0] == g);
    try std.testing.expectEqual(1, app.surfaces.items.len);
    try std.testing.expect(win32.IsWindowEnabled(g.hwnd).toBool());
    try std.testing.expect(!g.prompt_disabled);
}

test "win32: quitting with title prompts open leaves nothing behind" {
    // `terminate` closes every window as a close does, prompts and all;
    // the testing allocator finds anything left.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    app.quit_timer = .off;
    try registerClasses(app.hinstance);
    // `terminate` releases what `testApp` made and unregisters the
    // classes; until it runs, a failure releases them here.
    var terminated = false;
    defer if (!terminated) {
        testCleanup(&app);
        unregisterClasses(app.hinstance);
    };

    const f = try testFrame(&app);
    const a = try testPane(&app, f);
    const b = try testPane(&app, f);
    f.tab().tree = try testRow(alloc, &.{ a, b });
    f.tab().focused = a;
    const g = try testFrame(&app);
    const c = try testPane(&app, g);
    g.tab().tree = try .init(alloc, c);
    g.tab().focused = c;

    const tab_prompt = try testPrompt(&app, a, .tab);
    const own_prompt = try testPrompt(&app, c, .surface);
    terminated = true;
    app.terminate();
    try std.testing.expect(!win32.IsWindow(tab_prompt).toBool());
    try std.testing.expect(!win32.IsWindow(own_prompt).toBool());
}

test "win32: a title prompt takes its keys while a teardown waits for a thread" {
    // A teardown's wait pumps messages (`waitForThread`); Escape in the
    // prompt still cancels it there, as in `run`.
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;

    const dialog = try testPrompt(&app, pane, .surface);
    try std.testing.expect(win32.PostMessageW(try testField(dialog), win32.WM_KEYDOWN, win32.VK_ESCAPE, 0x0001_0001).toBool());
    const Sleeper = struct {
        fn run() void {
            win32.Sleep(300);
        }
    };
    const thread = try std.Thread.spawn(.{}, Sleeper.run, .{});
    // No core here to tick: as inside a tick, the wait does not.
    app.ticking = true;
    app.waitForThread(thread.getHandle());
    app.ticking = false;
    thread.join();
    try std.testing.expect(window.title_prompt.hwnd == null);
    try std.testing.expect(!win32.IsWindow(dialog).toBool());
}

test "win32: a title prompt's title bar follows its window's" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    app.config.@"window-theme" = .dark;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    window.applyTheme();
    try std.testing.expect(window.dark_frame);
    const pane = try testPane(&app, window);
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;

    // Read back from DWM, which answers for the attribute it was given.
    const darkBar = struct {
        fn get(hwnd: win32.HWND) !bool {
            var value: win32.BOOL = .FALSE;
            if (win32.DwmGetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &value, @sizeOf(win32.BOOL)) < 0) {
                return error.TestUnexpectedResult;
            }
            return value.toBool();
        }
    }.get;

    const dialog = try testPrompt(&app, pane, .surface);
    try std.testing.expect(try darkBar(dialog));

    // A new configuration re-themes it with the frame.
    var changed: Config = try .default(alloc);
    defer changed.deinit();
    changed.@"window-theme" = .light;
    try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
    try std.testing.expect(!window.dark_frame);
    try std.testing.expect(!try darkBar(dialog));
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
    window.tab().tree = try .init(alloc, pane);
    window.tab().focused = pane;
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
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, pane));

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
    window.tab().tree = try testRow(alloc, &.{ left, right });
    window.tab().focused = left;
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
    other.tab().tree = try .init(alloc, pane);
    other.tab().focused = pane;
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
    window.tab().tree = try testRow(alloc, &.{ left, right });
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
    try std.testing.expectEqual(left, window.tab().focused.?);
    const click = struct {
        fn f(a: *App, group: u64) void {
            const m = toast.groupMessage(group);
            _ = App.wndProc(a.msg_hwnd, WM_GHOSTTY_NOTIFICATION, m[0], m[1]);
        }
    }.f;
    click(&app, 12345);
    try std.testing.expectEqual(left, window.tab().focused.?);

    // Not for a terminal that is closing, nor one in a window closing,
    // nor while the app quits.
    right.closing = true;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.tab().focused.?);
    right.closing = false;
    window.closing = true;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.tab().focused.?);
    window.closing = false;
    app.terminating = true;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.tab().focused.?);
    app.terminating = false;

    // Under a prompt, where the focus may not move, `run` makes it later.
    app.prompt_depth = 1;
    click(&app, right.notifications.id);
    try std.testing.expectEqual(left, window.tab().focused.?);
    app.prompt_depth = 0;
    app.applyPendingClick();
    try std.testing.expectEqual(right, window.tab().focused.?);

    // A zoom that hides the terminal ends first.
    window.tab().tree.zoom(window.tab().tree.locate(right).?);
    window.relayout();
    click(&app, left.notifications.id);
    try std.testing.expectEqual(left, window.tab().focused.?);
    try std.testing.expectEqual(null, window.tab().tree.zoomed);

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
    window.tab().tree = try .init(alloc, pane);
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
    window.tab().focused = pane;
    window.toggleFullscreen();
    try std.testing.expect(window.isFloating());
    window.toggleFullscreen();
    try std.testing.expect(window.isFloating());
}

/// For tests: where `Window.test_set_focus` was last told the focus goes,
/// which `current`, as `Window.test_get_focus`, answers for GetFocus; and
/// whether the window `watch` showed when the focus last moved.
const FocusSeen = struct {
    var last: ?win32.HWND = null;
    var watch: ?win32.HWND = null;
    var watch_shown: bool = false;
    fn seen(hwnd: win32.HWND) void {
        last = hwnd;
        if (watch) |w| watch_shown = shown(w);
    }
    fn current() ?win32.HWND {
        return last;
    }
};

/// For tests: the binding actions search bars performed
/// (`SearchBar.test_perform`), each followed by ";".
const SearchSeen = struct {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    /// Whether the actions seen were performed.
    var performed: bool = true;
    fn seen(_: *Surface, action: input.Binding.Action) bool {
        const s = switch (action) {
            .search => |text| std.mem.print(buf[len..], "search:{s};", .{text}),
            .navigate_search => |nav| std.mem.print(buf[len..], "navigate_search:{s};", .{@tagName(nav)}),
            else => std.mem.print(buf[len..], "{s};", .{@tagName(action)}),
        } catch return performed;
        len += s.len;
        return performed;
    }
    /// What was performed since the last call.
    fn take() []const u8 {
        defer len = 0;
        return buf[0..len];
    }
};

/// For tests: `hwnd`'s place in `window`'s client area.
fn childRect(window: *const Window, hwnd: win32.HWND) !win32.RECT {
    var rect: win32.RECT = undefined;
    if (!win32.GetWindowRect(hwnd, &rect).toBool()) return error.TestUnexpectedResult;
    if (!window.toClient(&rect)) return error.TestUnexpectedResult;
    return rect;
}

/// For tests: whether `upper` is above `lower` among `parent`'s children.
fn above(parent: win32.HWND, upper: win32.HWND, lower: win32.HWND) bool {
    var it = win32.GetWindow(parent, win32.GW_CHILD);
    while (it) |hwnd| : (it = win32.GetWindow(hwnd, win32.GW_HWNDNEXT)) {
        if (hwnd == upper) return true;
        if (hwnd == lower) return false;
    }
    return false;
}

/// For tests: the text of `surface`'s search field, as UTF-8 in `buf`.
fn fieldText(surface: *const Surface, buf: []u8) ![]const u8 {
    var wide: [128]u16 = undefined;
    const n = win32.GetWindowTextW(surface.search_bar.edit.?, &wide, wide.len);
    const len = try std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]);
    return buf[0..len];
}

/// For tests: the selection in `surface`'s search field.
fn fieldSelection(surface: *const Surface) [2]u32 {
    var start: win32.DWORD = 0;
    var end: win32.DWORD = 0;
    _ = win32.SendMessageW(surface.search_bar.edit.?, win32.EM_GETSEL, @intFromPtr(&start), @bitCast(@intFromPtr(&end)));
    return .{ start, end };
}

/// For tests: the layout of `surface`'s search bar now, as its window
/// procedure works it out.
fn searchLayout(surface: *const Surface) SearchBar.Layout {
    const hwnd = surface.search_bar.hwnd.?;
    var client: win32.RECT = undefined;
    if (!win32.GetClientRect(hwnd, &client).toBool()) client = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const m = SearchBar.Metrics.init(Window.dpiOf(surface.app, hwnd));
    return .init(m, client.right, client.bottom, surface.search_bar.text_height);
}

/// For tests: `surface`'s search bar shows over its terminal's top-right
/// corner in `window`, above it.
fn expectBarOver(window: *const Window, surface: *const Surface) !void {
    const hwnd = surface.search_bar.hwnd.?;
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(win32.GetAncestor(hwnd, win32.GA_PARENT) == window.hwnd);
    const m = SearchBar.Metrics.init(Window.dpiOf(window.app, window.hwnd));
    const want = SearchBar.barRect(m, try paneClient(window, surface), surface.search_bar.text_height) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(want, try childRect(window, hwnd));
    try std.testing.expect(above(window.hwnd, hwnd, surface.hwnd));
}

test "win32: start_search opens a search bar over its terminal, its field to get the focus" {
    // GTK's search overlay: start_search shows it over the terminal's
    // top-right corner, puts a needle that is not empty in the field,
    // selects all of it and gives the field the focus, once the core's key
    // callback has returned (`App.search_focus`); a second one selects it
    // all again. end_search hides it, keeping its text, and gives the
    // terminal the focus if the field had it. The bar is a child of the
    // frame, above the terminal, as a child of the terminal would never
    // be composed over its swap chain.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    // Not for the app.
    try std.testing.expect(!try app.performAction(.app, .start_search, .{ .needle = "" }));
    try std.testing.expect(!try app.performAction(.app, .end_search, {}));

    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    const bar = &b.search_bar;
    try std.testing.expect(bar.open);
    try std.testing.expect(a.search_bar.hwnd == null);
    try std.testing.expect(bar.text_height > 0);
    try expectBarOver(window, b);
    try std.testing.expect(above(window.hwnd, bar.hwnd.?, a.hwnd));
    // The focus moves once the key callback has returned.
    try std.testing.expect(FocusSeen.last == null);
    try std.testing.expect(app.search_focus == b);
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == bar.edit.?);
    try std.testing.expect(window.tab().focused == b);
    try std.testing.expect(app.search_focus == null);

    // A needle fills the field, all of it selected; with none, the text
    // stays and is selected again.
    var buf: [64]u8 = undefined;
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "needle" }));
    try std.testing.expectEqualStrings("needle", try fieldText(b, &buf));
    try std.testing.expectEqual([2]u32{ 0, 6 }, fieldSelection(b));
    _ = win32.SendMessageW(bar.edit.?, win32.EM_SETSEL, 2, 2);
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    try std.testing.expectEqualStrings("needle", try fieldText(b, &buf));
    try std.testing.expectEqual([2]u32{ 0, 6 }, fieldSelection(b));
    app.applyPendingFocus();

    // end_search: hidden, its text kept, and the focus the field had goes
    // back to the terminal after the core frame.
    FocusSeen.last = null;
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .end_search, {}));
    try std.testing.expect(!bar.open);
    try std.testing.expect(!shown(bar.hwnd.?));
    try std.testing.expect(FocusSeen.last == null);
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == b.hwnd);
    try std.testing.expectEqualStrings("needle", try fieldText(b, &buf));
    // Laid out again, a closed bar stays hidden.
    window.relayout();
    try std.testing.expect(!shown(bar.hwnd.?));

    // Opened again, then the terminal takes the focus back: end_search
    // leaves the focus where it is.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    _ = Surface.wndProc(b.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(!bar.field_focus);
    FocusSeen.last = null;
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .end_search, {}));
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == null);

    // A terminal that begins to close takes its focus move with it.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(app.search_focus == null);
}

test "win32: a search field gets the focus back, and takes its own keys" {
    // The window gives the focus back to the field that had it, as when it
    // is activated again, and to the terminal once that has taken it, by a
    // click or because the bar no longer shows. In the field, the WM_CHARs
    // of Enter, Tab and Escape never reach the EDIT, which beeps at them,
    // Ctrl+Backspace deletes a word, and Escape and the close button
    // perform end_search, as GTK's do; never under a prompt.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    SearchBar.test_perform = &SearchSeen.seen;
    defer SearchBar.test_perform = null;
    _ = SearchSeen.take();

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "hello world" }));
    const bar = &b.search_bar;
    const edit = bar.edit.?;
    app.applyPendingFocus();

    // The field takes the focus: the window's focused terminal is its own,
    // and the frame's focus goes to the field.
    window.tab().focused = a;
    bar.field_focus = false;
    _ = win32.SendMessageW(edit, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(bar.field_focus);
    try std.testing.expect(window.tab().focused == b);
    FocusSeen.last = null;
    _ = Window.wndProc(window.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(FocusSeen.last == edit);

    // A click on the terminal of an inactive window: the terminal.
    const click: win32.LPARAM = (@as(win32.LPARAM, win32.WM_LBUTTONDOWN) << 16) | win32.HTCLIENT;
    _ = Surface.wndProc(b.hwnd, win32.WM_MOUSEACTIVATE, @intFromPtr(window.hwnd), click);
    try std.testing.expect(!bar.field_focus);
    _ = Window.wndProc(window.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(FocusSeen.last == b.hwnd);

    // With no room for the bar, the terminal.
    _ = win32.SendMessageW(edit, win32.WM_SETFOCUS, 0, 0);
    testResize(window, 240, 500);
    try std.testing.expect(!shown(bar.hwnd.?));
    _ = Window.wndProc(window.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(FocusSeen.last == b.hwnd);
    testResize(window, 900, 500);
    try expectBarOver(window, b);
    _ = Window.wndProc(window.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(FocusSeen.last == edit);

    // Enter, Ctrl+Enter, Tab and Escape: dropped, as no other character is.
    var buf: [64]u8 = undefined;
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 11, 11);
    const forwarded = SearchBar.test_forwarded;
    for ([_]win32.WPARAM{ '\r', '\n', '\t', 0x1B }) |c| _ = win32.SendMessageW(edit, win32.WM_CHAR, c, 0);
    try std.testing.expectEqual(forwarded, SearchBar.test_forwarded);
    try std.testing.expectEqualStrings("hello world", try fieldText(b, &buf));
    _ = win32.SendMessageW(edit, win32.WM_CHAR, '!', 0);
    try std.testing.expectEqual(forwarded + 1, SearchBar.test_forwarded);
    try std.testing.expectEqualStrings("hello world!", try fieldText(b, &buf));

    // Ctrl+Backspace: back to a word's start, a run of punctuation a word
    // of its own; the selection, if there is one.
    _ = win32.SendMessageW(edit, win32.WM_CHAR, 0x7F, 0);
    try std.testing.expectEqualStrings("hello world", try fieldText(b, &buf));
    _ = win32.SendMessageW(edit, win32.WM_CHAR, 0x7F, 0);
    try std.testing.expectEqualStrings("hello ", try fieldText(b, &buf));
    _ = win32.SetWindowTextW(edit, L("abc def"));
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 1, 2);
    _ = win32.SendMessageW(edit, win32.WM_CHAR, 0x7F, 0);
    try std.testing.expectEqualStrings("ac def", try fieldText(b, &buf));
    try std.testing.expectEqual(forwarded + 1, SearchBar.test_forwarded);

    // Escape: end_search, and the bar closes though no core answers it;
    // the terminal gets the focus the field had.
    FocusSeen.last = null;
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_ESCAPE, 0);
    try std.testing.expectEqualStrings("end_search;", SearchSeen.take());
    try std.testing.expect(!bar.open);
    try std.testing.expect(!shown(bar.hwnd.?));
    try std.testing.expect(FocusSeen.last == b.hwnd);

    // Under a prompt, Escape and the close button are recorded for `run`,
    // as the field's bindings are: the first closes the bar, the second
    // finds it closed. Dropped if the terminal begins to close.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    app.prompt_depth = 1;
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_ESCAPE, 0);
    const l = searchLayout(b);
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.close));
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONUP, 0, testMid(l.close));
    app.prompt_depth = 0;
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(bar.open);
    try std.testing.expectEqual(2, app.requests.items.len);
    for (app.requests.items) |request| switch (request) {
        .search_key => |key| {
            try std.testing.expect(key.from == &b.core_surface);
            try std.testing.expectEqual(SearchBar.FieldKey.close, key.key);
        },
        else => return error.TestUnexpectedResult,
    };
    app.createRequested();
    try std.testing.expectEqualStrings("end_search;", SearchSeen.take());
    try std.testing.expect(!bar.open);
    try std.testing.expectEqual(0, app.requests.items.len);
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    app.prompt_depth = 1;
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_ESCAPE, 0);
    app.prompt_depth = 0;
    app.forgetClosing(&b.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(bar.open);
    try std.testing.expectEqual(0, app.requests.items.len);

    // The close button, pressed and released on it; not pressed on
    // another button.
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.up));
    try std.testing.expect(win32.GetCapture() == bar.hwnd.?);
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONUP, 0, testMid(l.close));
    try std.testing.expect(win32.GetCapture() == null);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(bar.open);
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.close));
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONUP, 0, testMid(l.close));
    try std.testing.expectEqualStrings("end_search;", SearchSeen.take());
    try std.testing.expect(!bar.open);

    // A press on the bar beside its buttons puts the focus in the field.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    FocusSeen.last = null;
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.label));
    try std.testing.expect(FocusSeen.last == edit);
    _ = win32.SendMessageW(bar.hwnd.?, win32.WM_LBUTTONUP, 0, testMid(l.label));
    try std.testing.expectEqualStrings("", SearchSeen.take());
}

/// For tests: whether the search bar `hwnd`'s timer has fired, taking its
/// WM_TIMER from the queue without dispatching it.
fn searchTimerDue(hwnd: win32.HWND) bool {
    var msg: win32.MSG = undefined;
    return win32.PeekMessageW(&msg, hwnd, win32.WM_TIMER, win32.WM_TIMER, win32.PM_REMOVE).toBool();
}

/// For tests: whether the search bar `hwnd`'s timer fires within two
/// seconds, its WM_TIMER taken from the queue undispatched. Only for a
/// timer that should fire: when the wait must still be on, the test asks
/// the bar at a given time instead (`SearchBar.test_now`).
fn searchTimerFires(hwnd: win32.HWND) bool {
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 10) {
        if (searchTimerDue(hwnd)) return true;
        win32.Sleep(10);
    }
    return false;
}

/// For tests: the search bar `hwnd`'s timer, as `run` would dispatch it.
fn searchTimer(hwnd: win32.HWND) void {
    _ = win32.SendMessageW(hwnd, win32.WM_TIMER, SearchBar.search_timer, 0);
}

test "win32: typing in a search field searches its terminal, and Enter walks the matches" {
    // GTK's overlay: the text is searched for (`search:<text>`) once it
    // has not changed for GtkSearchEntry's 150 ms, at once when emptied or
    // given by start_search, and again when the bar opens again; Enter,
    // Shift+Enter and the up and down buttons ask for the next and previous
    // match, after a search still to be made. Under a prompt the search
    // waits and navigation is recorded for `run`; end_search drops a
    // search not yet made. search_total and search_selected make the
    // count. The wait is measured on a clock the test sets
    // (`SearchBar.test_now`), the timer it waits on being real.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    SearchBar.test_perform = &SearchSeen.seen;
    defer SearchBar.test_perform = null;
    SearchBar.test_now = 1000;
    defer SearchBar.test_now = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = &a.search_bar;
    const hwnd = bar.hwnd.?;
    const edit = bar.edit.?;
    _ = SearchSeen.take();

    // Typed text: searched for after the wait, from the timer, once. A
    // timer that comes a millisecond early waits out the rest.
    _ = win32.SetWindowTextW(edit, L("alpha"));
    try std.testing.expectEqualStrings("", SearchSeen.take());
    SearchBar.test_now = 1149;
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(searchTimerFires(hwnd));
    SearchBar.test_now = 1150;
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:alpha;", SearchSeen.take());
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    // And the timer stopped: it never fires again.
    win32.Sleep(200);
    try std.testing.expect(!searchTimerDue(hwnd));

    // Changes inside the wait: each starts it again, and there is one
    // search, for the last text.
    _ = win32.SetWindowTextW(edit, L("alp"));
    SearchBar.test_now = 1250;
    _ = win32.SetWindowTextW(edit, L("alpha beta"));
    SearchBar.test_now = 1300;
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    SearchBar.test_now = 1400;
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:alpha beta;", SearchSeen.take());

    // Emptied: at once, which stops the search.
    _ = win32.SetWindowTextW(edit, L(""));
    try std.testing.expect(searchTimerFires(hwnd));
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:;", SearchSeen.take());

    // Enter: the search still to be made, then the next match; again,
    // only the next match. Shift+Enter: the previous one.
    _ = win32.SetWindowTextW(edit, L("gamma"));
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_RETURN, 0);
    try std.testing.expectEqualStrings("search:gamma;navigate_search:next;", SearchSeen.take());
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_RETURN, 0);
    try std.testing.expectEqualStrings("navigate_search:next;", SearchSeen.take());
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    var keys: [256]u8 = undefined;
    try std.testing.expect(win32.GetKeyboardState(&keys).toBool());
    const shift = keys[@intCast(win32.VK_SHIFT)];
    keys[@intCast(win32.VK_SHIFT)] = 0x80;
    try std.testing.expect(win32.SetKeyboardState(&keys).toBool());
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_RETURN, 0);
    keys[@intCast(win32.VK_SHIFT)] = shift;
    _ = win32.SetKeyboardState(&keys);
    try std.testing.expectEqualStrings("navigate_search:previous;", SearchSeen.take());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("gamma", try fieldText(a, &buf));

    // The buttons: up is the next match, down the previous one, as on GTK.
    const l = searchLayout(a);
    _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.up));
    _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONUP, 0, testMid(l.up));
    _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.down));
    _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONUP, 0, testMid(l.down));
    try std.testing.expectEqualStrings("navigate_search:next;navigate_search:previous;", SearchSeen.take());

    // Under a prompt: the search waits for the next tick of its timer;
    // Enter and the buttons are recorded for `run`, which makes the search
    // still to be made first, as Enter does.
    _ = win32.SetWindowTextW(edit, L("delta"));
    SearchBar.test_now = 2000;
    app.prompt_depth = 1;
    searchTimer(hwnd);
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_RETURN, 0);
    _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testMid(l.down));
    _ = win32.SendMessageW(hwnd, win32.WM_LBUTTONUP, 0, testMid(l.down));
    app.prompt_depth = 0;
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(searchTimerFires(hwnd));
    try std.testing.expectEqual(2, app.requests.items.len);
    app.createRequested();
    try std.testing.expectEqualStrings("search:delta;navigate_search:next;navigate_search:previous;", SearchSeen.take());
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    // Recorded for a bar closed before `run` came to it: nothing.
    app.prompt_depth = 1;
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_RETURN, 0);
    app.prompt_depth = 0;
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    app.createRequested();
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    searchTimer(hwnd);
    _ = SearchSeen.take();
    // The search under a prompt, after the wait, from the timer.
    _ = win32.SetWindowTextW(edit, L("epsilon"));
    app.prompt_depth = 1;
    SearchBar.test_now = 3000;
    searchTimer(hwnd);
    app.prompt_depth = 0;
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(searchTimerFires(hwnd));
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:epsilon;", SearchSeen.take());

    // An unpaired surrogate is U+FFFD.
    const lone = [_:0]u16{ 'a', 0xD800, 'b' };
    _ = win32.SetWindowTextW(edit, &lone);
    SearchBar.test_now = 3150;
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:a\u{FFFD}b;", SearchSeen.take());

    // end_search drops a search not yet made, due or not; opened again,
    // the text it kept is searched for at once. Opened when open, nothing.
    _ = win32.SetWindowTextW(edit, L("omega"));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    SearchBar.test_now = 4000;
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    try std.testing.expect(searchTimerFires(hwnd));
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:omega;", SearchSeen.take());
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("", SearchSeen.take());

    // A needle, as search_selection gives: searched for at once.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "needle" }));
    try std.testing.expect(searchTimerFires(hwnd));
    searchTimer(hwnd);
    try std.testing.expectEqualStrings("search:needle;", SearchSeen.take());

    // The count: GTK's selected/total, the core's 0-based index plus one.
    try std.testing.expect(!try app.performAction(.app, .search_total, .{ .total = 5 }));
    try std.testing.expect(!try app.performAction(.app, .search_selected, .{ .selected = 2 }));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .search_total, .{ .total = 5 }));
    try std.testing.expectEqualStrings("0/5", SearchBar.countLabel(buf[0..48], bar.total, bar.selected));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .search_selected, .{ .selected = 2 }));
    try std.testing.expectEqualStrings("3/5", SearchBar.countLabel(buf[0..48], bar.total, bar.selected));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .search_total, .{ .total = null }));
    try std.testing.expectEqualStrings("0/0", SearchBar.countLabel(buf[0..48], bar.total, bar.selected));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .search_selected, .{ .selected = null }));
    try std.testing.expect(bar.selected == null);
}

/// For tests: a key pressed in the search field `edit` with modifiers
/// held, as `run` dispatches it: `char`, the character TranslateMessage
/// queued for it (a WM_SYSCHAR with Alt), is posted before the key is
/// sent, and the characters the field's subclass left in the queue are
/// dispatched after it. `scan` is the key's scan code in lParam, with 0xE0
/// in the high byte for an extended key; with none, the layout's mapping
/// of `vk` stands for it (`scanCode`), which for the arrows is the keypad's.
fn fieldKey(edit: win32.HWND, vk: u8, mods: struct { ctrl: bool = false, shift: bool = false, alt: bool = false, scan: u16 = 0 }, char: ?u16) !void {
    var keys: [256]u8 = undefined;
    if (!win32.GetKeyboardState(&keys).toBool()) return error.TestUnexpectedResult;
    const saved = keys;
    defer _ = win32.SetKeyboardState(&saved);
    if (mods.ctrl) for ([_]usize{ 0x11, 0xA2 }) |vk_mod| {
        keys[vk_mod] = 0x80;
    };
    if (mods.shift) for ([_]usize{ 0x10, 0xA0 }) |vk_mod| {
        keys[vk_mod] = 0x80;
    };
    if (mods.alt) for ([_]usize{ 0x12, 0xA4 }) |vk_mod| {
        keys[vk_mod] = 0x80;
    };
    if (!win32.SetKeyboardState(&keys).toBool()) return error.TestUnexpectedResult;
    if (char) |c| _ = win32.PostMessageW(edit, if (mods.alt) win32.WM_SYSCHAR else win32.WM_CHAR, c, 0);
    const extended: win32.LPARAM = if (mods.scan & 0xE000 != 0) 1 << 24 else 0;
    const lparam: win32.LPARAM = (@as(win32.LPARAM, mods.scan & 0xFF) << 16) | extended;
    _ = win32.SendMessageW(edit, if (mods.alt) win32.WM_SYSKEYDOWN else win32.WM_KEYDOWN, vk, lparam);
    var m: win32.MSG = undefined;
    for ([_][2]win32.UINT{ .{ win32.WM_CHAR, win32.WM_DEADCHAR }, .{ win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR } }) |r| {
        while (win32.PeekMessageW(&m, edit, r[0], r[1], win32.PM_REMOVE).toBool()) _ = win32.DispatchMessageW(&m);
    }
}

/// For tests: the key messages a terminal's window receives, counted by a
/// subclass of it (`install`, `remove`).
const TerminalKeys = struct {
    var count: usize = 0;
    var old: ?win32.WNDPROC = null;

    fn install(hwnd: win32.HWND) void {
        count = 0;
        const prev = win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&proc)));
        old = @ptrFromInt(@as(usize, @bitCast(prev)));
    }

    fn remove(hwnd: win32.HWND) void {
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(old.?)));
    }

    fn proc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        switch (msg) {
            win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_CHAR, win32.WM_SYSCHAR => count += 1,
            else => {},
        }
        return win32.CallWindowProcW(old.?, hwnd, msg, wparam, lparam);
    }
};

/// For tests: `SearchSeen`, and the core's answer to `start_search`, which
/// is the apprt's `start_search` (CoreSurface.performBindingAction).
const SearchAnswer = struct {
    fn seen(surface: *Surface, action: input.Binding.Action) bool {
        const performed = SearchSeen.seen(surface, action);
        if (action == .start_search) {
            _ = surface.app.performAction(.{ .surface = &surface.core_surface }, .start_search, .{ .needle = "" }) catch {};
        }
        return performed;
    }
};

test "win32: keys in a search field perform the terminal's bindings for its window, and act on the field" {
    // As GTK keeps a window's accelerators working while an entry has the
    // focus: in the field, a binding is performed only if every action in
    // it is on the allow-list (`overlay_keys.route`); copy, paste and
    // select all act on the field; anything else, and every key that
    // types, is the field's, and no key reaches the terminal. An Alt+key
    // no binding takes does not beep. Under a prompt a binding is
    // recorded for `run` rather than performed.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    SearchBar.test_perform = &SearchAnswer.seen;
    defer SearchBar.test_perform = null;
    SearchSeen.performed = true;
    defer SearchSeen.performed = true;
    _ = SearchSeen.take();

    // Bindings of every kind beside the defaults.
    const arena = app.config._arena.?.allocator();
    for ([_][]const u8{
        "x=new_tab",
        "ctrl+shift+k=text:hello",
        "ctrl+shift+g>n=new_tab",
        "unconsumed:ctrl+shift+u=new_tab",
        "unconsumed:arrow_up=new_tab",
        "performable:ctrl+shift+y=new_tab",
        "all:ctrl+shift+h=select_all",
        "all:ctrl+shift+l=new_tab",
        "unconsumed:all:ctrl+shift+o=new_tab",
        "ctrl+shift+b=new_tab",
        "chain=text:x",
        "ctrl+shift+m=new_split:right",
        "chain=select_all",
    }) |binding| try app.config.keybind.parseCLI(arena, binding);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    TerminalKeys.install(a.hwnd);
    defer TerminalKeys.remove(a.hwnd);

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "needle" }));
    app.applyPendingFocus();
    const edit = a.search_bar.edit.?;
    var buf: [64]u8 = undefined;

    // The default new-tab and next-tab keys, and Alt+F4: performed, and
    // the control character Ctrl+Shift+T queued is not the field's.
    const forwarded = SearchBar.test_forwarded;
    try fieldKey(edit, 'T', .{ .ctrl = true, .shift = true }, 0x14);
    try fieldKey(edit, win32.VK_TAB, .{ .ctrl = true }, null);
    try fieldKey(edit, 0x73, .{ .alt = true }, null);
    try std.testing.expectEqualStrings("new_tab;next_tab;close_window;", SearchSeen.take());
    try std.testing.expectEqual(forwarded, SearchBar.test_forwarded);
    try std.testing.expectEqualStrings("needle", try fieldText(a, &buf));

    // start_search again: the core answers, and the field's text is
    // selected again and given the focus once the key is handled.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 2, 2);
    FocusSeen.last = null;
    try fieldKey(edit, 'F', .{ .ctrl = true, .shift = true }, 0x06);
    try std.testing.expectEqualStrings("start_search;", SearchSeen.take());
    try std.testing.expectEqual([2]u32{ 0, 6 }, fieldSelection(a));
    try std.testing.expect(app.search_focus == null);
    try std.testing.expect(FocusSeen.last == edit);

    // Copy, paste and select all act on the field. Pressed first with no
    // character queued, which the EDIT would act on by itself (U+0003,
    // U+0016, U+0001); then a paste with its U+0016, which must not paste
    // a second time. The clipboard's text is put back after.
    const readClipboardText = @import("clipboard.zig").readClipboardText;
    const saved = try readClipboardText(alloc, a.hwnd);
    defer if (saved) |text| {
        writeClipboardText(a.hwnd, text) catch {};
        alloc.free(text);
    };
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 1, 4);
    try fieldKey(edit, 'C', .{ .ctrl = true, .shift = true }, null);
    {
        const text = (try readClipboardText(alloc, a.hwnd)) orelse return error.TestUnexpectedResult;
        defer alloc.free(text);
        try std.testing.expectEqualStrings("eed", text);
    }
    try writeClipboardText(a.hwnd, "pasted");
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 6, 6);
    try fieldKey(edit, 'V', .{ .ctrl = true, .shift = true }, null);
    try std.testing.expectEqualStrings("needlepasted", try fieldText(a, &buf));
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 0, 0);
    try fieldKey(edit, 'V', .{ .ctrl = true, .shift = true }, 0x16);
    try std.testing.expectEqualStrings("pastedneedlepasted", try fieldText(a, &buf));
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 2, 2);
    try fieldKey(edit, 'A', .{ .ctrl = true, .shift = true }, null);
    try std.testing.expectEqual([2]u32{ 0, 18 }, fieldSelection(a));
    try std.testing.expectEqualStrings("", SearchSeen.take());

    // A chain with an action for the core and one for the field: both.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 2, 2);
    try fieldKey(edit, 'M', .{ .ctrl = true, .shift = true }, null);
    try std.testing.expectEqualStrings("new_split;", SearchSeen.take());
    try std.testing.expectEqual([2]u32{ 0, 18 }, fieldSelection(a));

    // Not allowed, alone or in a chain: the default write_screen_file, a
    // text binding, a binding's chained text, a leader, select all on every
    // terminal: nothing is performed, the field's selection stays.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 2, 2);
    try fieldKey(edit, 'J', .{ .ctrl = true, .shift = true }, null);
    try fieldKey(edit, 'K', .{ .ctrl = true, .shift = true }, null);
    try fieldKey(edit, 'B', .{ .ctrl = true, .shift = true }, null);
    try fieldKey(edit, 'G', .{ .ctrl = true, .shift = true }, null);
    try fieldKey(edit, 'H', .{ .ctrl = true, .shift = true }, null);
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expectEqual([2]u32{ 2, 2 }, fieldSelection(a));
    // A key bound on every terminal, for the core: performed.
    try fieldKey(edit, 'L', .{ .ctrl = true, .shift = true }, null);
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    // With unconsumed: too, its key is consumed all the same, as the core
    // consumes an all: binding's: its control character never reaches the
    // EDIT.
    const before_all = SearchBar.test_forwarded;
    try fieldKey(edit, 'O', .{ .ctrl = true, .shift = true }, 0x0F);
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    try std.testing.expectEqual(before_all, SearchBar.test_forwarded);

    // An Alt+letter no binding takes: its WM_SYSCHAR, which the default
    // procedure would beep at as a menu mnemonic, never reaches the EDIT.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 2, 2);
    try fieldKey(edit, 'X', .{ .alt = true }, 'x');
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expectEqual(before_all, SearchBar.test_forwarded);
    try std.testing.expectEqualStrings("pastedneedlepasted", try fieldText(a, &buf));

    // A key that types is the field's, bound or not.
    _ = win32.SetWindowTextW(edit, L(""));
    try fieldKey(edit, 'X', .{}, 'x');
    try fieldKey(edit, 'X', .{ .shift = true }, 'X');
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expectEqualStrings("xX", try fieldText(a, &buf));

    // unconsumed: performed, and the key goes on to the field. A
    // performable binding none of whose actions could act: as if unbound.
    // Their control characters reach the EDIT, which ignores them.
    const before = SearchBar.test_forwarded;
    try fieldKey(edit, 'U', .{ .ctrl = true, .shift = true }, 0x15);
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    try std.testing.expectEqual(before + 1, SearchBar.test_forwarded);
    try fieldKey(edit, 'Y', .{ .ctrl = true, .shift = true }, 0x19);
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    try std.testing.expectEqual(before + 1, SearchBar.test_forwarded);
    SearchSeen.performed = false;
    try fieldKey(edit, 'Y', .{ .ctrl = true, .shift = true }, 0x19);
    SearchSeen.performed = true;
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    try std.testing.expectEqual(before + 2, SearchBar.test_forwarded);
    // The key itself goes on too: a single-line EDIT takes Up as Left.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 2, 2);
    try fieldKey(edit, 0x26, .{ .scan = 0xE048 }, null);
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    try std.testing.expectEqual([2]u32{ 1, 1 }, fieldSelection(a));

    // Under a prompt: recorded, then performed by `run`; an action on the
    // field alone acts at once. Dropped if its terminal begins to close.
    SearchBar.test_perform = &SearchSeen.seen;
    app.prompt_depth = 1;
    try fieldKey(edit, 'T', .{ .ctrl = true, .shift = true }, 0x14);
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 1, 1);
    try fieldKey(edit, 'A', .{ .ctrl = true, .shift = true }, null);
    app.prompt_depth = 0;
    try std.testing.expectEqualStrings("", SearchSeen.take());
    try std.testing.expectEqual([2]u32{ 0, 2 }, fieldSelection(a));
    try std.testing.expectEqual(1, app.requests.items.len);
    switch (app.requests.items[0]) {
        .overlay_key => |key| try std.testing.expect(key.from == &a.core_surface),
        else => return error.TestUnexpectedResult,
    }
    app.createRequested();
    try std.testing.expectEqualStrings("new_tab;", SearchSeen.take());
    try std.testing.expectEqual(0, app.requests.items.len);
    app.prompt_depth = 1;
    try fieldKey(edit, 'T', .{ .ctrl = true, .shift = true }, 0x14);
    app.prompt_depth = 0;
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expectEqualStrings("", SearchSeen.take());

    // None of it reached the terminal.
    try std.testing.expectEqual(0, TerminalKeys.count);
}

test "win32: a search bar follows its terminal through zooms, tabs, splits and moves" {
    // The bar is the frame's child, so every layout places it: hidden with
    // its terminal by a zoom or a hidden tab and shown again with it, moved
    // down by the tab bar, over the whole window in fullscreen, above a
    // terminal raised over it, and with its terminal into a new window's
    // frame; destroyed with its terminal. A tab shown again gives the
    // focus to the field that had it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = &a.search_bar;
    const hwnd = bar.hwnd.?;
    try expectBarOver(window, a);

    // A zoom on the other terminal hides it with its own; back, shown. A
    // start_search meanwhile gives a hidden terminal no focus.
    window.toggleZoom(b);
    try std.testing.expect(!shown(a.hwnd));
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(bar.open);
    FocusSeen.last = null;
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    try std.testing.expect(!shown(hwnd));
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == null);
    window.toggleZoom(b);
    try expectBarOver(window, a);
    // A zoom on its own: over all of the window.
    window.toggleZoom(a);
    try expectBarOver(window, a);
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    window.toggleZoom(a);

    // A terminal raised over it: laid out again, under it.
    _ = win32.SetWindowPos(a.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    try std.testing.expect(!above(window.hwnd, hwnd, a.hwnd));
    window.relayout();
    try expectBarOver(window, a);

    // A second tab brings the tab bar, which moves the terminals down, and
    // the bar with them.
    const was = try childRect(window, hwnd);
    const c = try testTab(&app, window);
    window.relayout();
    try expectBarOver(window, a);
    try std.testing.expect((try childRect(window, hwnd)).top > was.top);

    // Fullscreen: no tab bar, so up again; and back.
    window.toggleFullscreen();
    try expectBarOver(window, a);
    try std.testing.expectEqual(0, (try paneRect(window, a)).top);
    window.toggleFullscreen();
    try expectBarOver(window, a);

    // The other tab shown: hidden with its terminals, still open; shown
    // again with them, and the field gets the focus it had.
    window.selectTab(1);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(bar.open);
    FocusSeen.last = null;
    window.selectTab(0);
    try expectBarOver(window, a);
    try std.testing.expect(FocusSeen.last == bar.edit.?);
    try std.testing.expect(c.search_bar.hwnd == null);

    // The tab moved to a new window: the bar goes to its frame.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = a.window;
    try std.testing.expect(moved != window);
    try expectBarOver(moved, a);

    // Its terminal closing: the bar goes too, and so does a focus move
    // to it, which a terminal with no core leaves for its freeing to drop.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    try std.testing.expect(app.search_focus == a);
    try std.testing.expect(a.destroy());
    try std.testing.expect(!win32.IsWindow(hwnd).toBool());
    try std.testing.expect(app.search_focus == null);

    // A window closing with a bar open frees both, whichever of the two
    // Windows destroys first. The terminal raised above its bar is
    // destroyed, and freed, first, as Windows destroys a frame's children
    // from the top: it lets go of its bar's window (`Bar.deinit`), whose
    // WM_DESTROY, and then its field's, have no terminal to write to.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    const b_bar = b.search_bar.hwnd.?;
    // In the new window, with the tab it moved in.
    const frame = b.window.hwnd;
    try std.testing.expect(frame == moved.hwnd);
    _ = win32.SetWindowPos(b.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    try std.testing.expect(above(frame, b.hwnd, b_bar));
    SearchBar.test_detached = 0;
    try std.testing.expect(win32.DestroyWindow(frame).toBool());
    try std.testing.expect(!win32.IsWindow(b_bar).toBool());
    try std.testing.expectEqual(1, app.windows.items.len);
    try std.testing.expectEqual(2, SearchBar.test_detached);
}

test "win32: a search bar above its terminal lets go of it at its WM_DESTROY as its window closes" {
    // The bar is placed above its terminal, and Windows sends WM_DESTROY
    // to a frame's children from the top, each one's before its own
    // children's: the bar's comes while its terminal is there, then its
    // field's, then the terminal's, which frees the terminal before the
    // bar's WM_NCDESTROY and its field's. The bar's window lets go of the
    // terminal at its own WM_DESTROY, so that none of those reads it: its
    // field's WM_DESTROY, the first of them, has no terminal to read.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = a.search_bar.hwnd.?;
    try expectBarOver(window, a);

    SearchBar.test_detached = 0;
    try std.testing.expect(win32.DestroyWindow(window.hwnd).toBool());
    try std.testing.expect(!win32.IsWindow(bar).toBool());
    try std.testing.expectEqual(0, app.windows.items.len);
    try std.testing.expectEqual(0, app.surfaces.items.len);
    try std.testing.expectEqual(1, SearchBar.test_detached);
}

/// For tests: `SearchSeen`, and the core's answer to `end_search`, the
/// apprt's `end_search` (CoreSurface.performBindingAction), noting what it
/// left as it returned: whether the bar showed, and where the focus was.
const EndAnswer = struct {
    var bar_shown: bool = false;
    var focus: ?win32.HWND = null;
    fn seen(surface: *Surface, action: input.Binding.Action) bool {
        const performed = SearchSeen.seen(surface, action);
        if (action == .end_search) {
            _ = surface.app.performAction(.{ .surface = &surface.core_surface }, .end_search, {}) catch {};
            bar_shown = shown(surface.search_bar.hwnd.?);
            focus = FocusSeen.last;
        }
        return performed;
    }
};

test "win32: a search bar hides once the focus has left it, and opens only where it shows" {
    // end_search while the field has the keyboard focus, from Escape or a
    // binding in the field, leaves the bar shown until the core's
    // end_search has returned; then the terminal takes the focus, and only
    // then does the bar hide, so that hiding the window with the focus
    // never moves the focus into the core still on the stack. A bar that
    // hides for want of room hands its terminal the focus first too.
    // start_search in a terminal too small for the bar is not performed.
    // A bar made again takes the font.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    SearchBar.test_perform = &EndAnswer.seen;
    defer SearchBar.test_perform = null;
    FocusSeen.last = null;
    defer FocusSeen.watch = null;
    _ = SearchSeen.take();

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = &a.search_bar;
    const hwnd = bar.hwnd.?;
    const edit = bar.edit.?;
    try std.testing.expect(FocusSeen.last == edit);
    FocusSeen.watch = hwnd;

    // The core's end_search, as a binding performs it: closed, still
    // shown, the focus where it was. Once it has returned, the focus goes
    // to the terminal while the bar shows, and then the bar hides.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    try std.testing.expect(!bar.open);
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(FocusSeen.last == edit);
    try std.testing.expect(app.search_hide == a);
    FocusSeen.watch_shown = false;
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == a.hwnd);
    try std.testing.expect(FocusSeen.watch_shown);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(app.search_hide == null);

    // Escape in the field: the same, around the core's own end_search.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == edit);
    EndAnswer.bar_shown = false;
    FocusSeen.watch_shown = false;
    _ = win32.SendMessageW(edit, win32.WM_KEYDOWN, win32.VK_ESCAPE, 0);
    try std.testing.expectEqualStrings("end_search;", SearchSeen.take());
    try std.testing.expect(EndAnswer.bar_shown);
    try std.testing.expect(EndAnswer.focus == edit);
    try std.testing.expect(FocusSeen.last == a.hwnd);
    try std.testing.expect(FocusSeen.watch_shown);
    try std.testing.expect(!shown(hwnd));

    // A bar whose field has the focus, its terminal shrunk below the
    // bar's least size: the terminal takes the focus, then the bar hides,
    // still open.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == edit);
    FocusSeen.watch_shown = false;
    testResize(window, 240, 500);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(FocusSeen.last == a.hwnd);
    try std.testing.expect(FocusSeen.watch_shown);
    try std.testing.expect(bar.open);

    // start_search there: not performed, so that the key goes on, and the
    // bar not opened; with room again, it opens.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    app.applyPendingFocus();
    try std.testing.expect(!try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "x" }));
    try std.testing.expect(!bar.open);
    try std.testing.expect(app.search_focus == null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try fieldText(a, &buf));
    testResize(window, 900, 500);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    try expectBarOver(window, a);
    app.applyPendingFocus();

    // Its window destroyed while its terminal lives, as when it cannot
    // follow the terminal to a new frame: the next start_search makes
    // another, whose field has the bar's font.
    try std.testing.expect(win32.DestroyWindow(hwnd).toBool());
    try std.testing.expect(bar.hwnd == null);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const font = win32.SendMessageW(bar.edit.?, win32.WM_GETFONT, 0, 0);
    try std.testing.expect(font != 0);
    try std.testing.expectEqual(@intFromPtr(bar.font.?), @as(usize, @bitCast(font)));
}

test "win32: the command palette lists only what performAction carries out" {
    // `CommandPalette.supported` against `performAction` for the binding
    // actions the core hands to this runtime (its arms in
    // CoreSurface.performBindingAction and CoreApp.performAction), each
    // with the target the core gives it: each listed one is performed (or
    // recorded for `run`), and each left out is refused. In the order
    // below the tab moves are queued behind the new tab, and the closes
    // and tab moves behind the move to a new window, so that none of them
    // closes or moves anything here. Not `open_config`, which starts a
    // program (the VM scenario runs it).
    @setEvalBranchQuota(100_000);
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    // A second window, for goto_window.
    const other = try testFrame(&app);
    const d = try testPane(&app, other);
    other.tab().tree = try .init(alloc, d);
    other.tab().focused = d;
    const target: apprt.Target = .{ .surface = &a.core_surface };
    // The size the core gives every terminal as it is made, which
    // reset_window_size goes back to.
    try std.testing.expect(try app.performAction(target, .initial_size, .{ .width = 800, .height = 600 }));

    const Case = struct { input.Binding.Action.Key, apprt.Action.Key };
    const cases = [_]Case{
        // Left out.
        .{ .toggle_tab_overview, .toggle_tab_overview },
        .{ .prompt_window_title, .prompt_title },
        .{ .set_window_title, .set_window_title },
        .{ .close_all_windows, .close_all_windows },
        .{ .toggle_quick_terminal, .toggle_quick_terminal },
        .{ .toggle_visibility, .toggle_visibility },
        .{ .check_for_updates, .check_for_updates },
        .{ .undo, .undo },
        .{ .redo, .redo },
        .{ .inspector, .inspector },
        .{ .show_gtk_inspector, .show_gtk_inspector },
        .{ .show_on_screen_keyboard, .show_on_screen_keyboard },
        .{ .toggle_secure_input, .secure_input },
        .{ .toggle_background_opacity, .toggle_background_opacity },
        // Listed.
        .{ .new_window, .new_window },
        .{ .new_tab, .new_tab },
        .{ .new_split, .new_split },
        .{ .goto_tab, .goto_tab },
        .{ .move_tab_to_new_window, .move_tab_to_new_window },
        .{ .prompt_tab_title, .prompt_title },
        .{ .prompt_surface_title, .prompt_title },
        .{ .toggle_split_zoom, .toggle_split_zoom },
        .{ .equalize_splits, .equalize_splits },
        .{ .toggle_fullscreen, .toggle_fullscreen },
        .{ .toggle_maximize, .toggle_maximize },
        .{ .toggle_window_decorations, .toggle_window_decorations },
        .{ .toggle_window_float_on_top, .float_window },
        // Behind the queued new tab and move.
        .{ .close_tab, .close_tab },
        .{ .close_window, .close_window },
        .{ .previous_tab, .goto_tab },
        .{ .next_tab, .goto_tab },
        .{ .last_tab, .goto_tab },
        .{ .move_tab, .move_tab },
        // Behind the queued split.
        .{ .goto_split, .goto_split },
        .{ .resize_split, .resize_split },
        .{ .goto_window, .goto_window },
        .{ .set_tab_title, .set_tab_title },
        .{ .set_surface_title, .set_title },
        .{ .copy_title_to_clipboard, .copy_title_to_clipboard },
        .{ .start_search, .start_search },
        .{ .search_selection, .start_search },
        .{ .end_search, .end_search },
        .{ .reset_window_size, .reset_window_size },
        .{ .toggle_command_palette, .toggle_command_palette },
        .{ .toggle_readonly, .readonly },
        // The app's.
        .{ .reload_config, .reload_config },
        .{ .quit, .quit },
    };
    var listed: usize = 0;
    inline for (cases) |case| {
        const value: apprt.Action.Value(case[1]) = switch (case[0]) {
            .prompt_window_title => .window,
            .prompt_tab_title => .tab,
            .prompt_surface_title => .surface,
            .set_window_title, .set_tab_title, .set_surface_title => .{ .title = "t" },
            .inspector => .toggle,
            .toggle_secure_input, .toggle_window_float_on_top => .toggle,
            .new_split => .right,
            .goto_tab, .next_tab => .next,
            .previous_tab => .previous,
            .last_tab => .last,
            .toggle_fullscreen => .native,
            .close_tab => .this,
            .move_tab => .{ .amount = 1 },
            .goto_split => .right,
            .resize_split => .{ .amount = 10, .direction = .right },
            .goto_window => .next,
            .start_search => .{ .needle = "" },
            .search_selection => .{ .needle = "t" },
            .reload_config => .{},
            .toggle_readonly => .on,
            else => if (apprt.Action.Value(case[1]) == void) {} else unreachable,
        };
        const to: apprt.Target = switch (case[0]) {
            .reload_config, .quit => .app,
            else => target,
        };
        // Answered before it would ask the core whether to confirm, or
        // post WM_QUIT to the test's thread.
        if (case[0] == .quit) app.quit = true;
        defer if (case[0] == .quit) {
            app.quit = false;
        };
        const performed = try app.performAction(to, case[1], value);
        if (CommandPalette.supported(case[0]) != performed) {
            std.debug.print("{t}: listed={} performed={}\n", .{ case[0], CommandPalette.supported(case[0]), performed });
            return error.TestUnexpectedResult;
        }
        if (performed) listed += 1;
    }
    try std.testing.expectEqual(33, listed);
    // What the listed ones recorded is not carried out here.
    app.requests.clearRetainingCapacity();
    _ = try app.performAction(target, .float_window, .off);
}

test "win32: the command palette has a jump to each terminal that is not closing" {
    // GTK's and macOS's "Focus: <title>" entries, one per terminal of
    // every window, titled as each is shown (its title prompt's title over
    // the program's), with the configuration's commands.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    const other = try testFrame(&app);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, other);
    const d = try testPane(&app, other);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    other.tab().tree = try testRow(alloc, &.{ c, d });
    a.title = try alloc.dupeSentinel(u8, "shell", 0);
    b.title = try alloc.dupeSentinel(u8, "vim", 0);
    b.title_override = try alloc.dupeSentinel(u8, "notes", 0);
    d.closing = true;
    defer d.closing = false;

    var entries = try CommandPalette.forApp(&app, null);
    defer entries.deinit();
    var jumps: [4]?*Surface = .{ null, null, null, null };
    var titles: [4][]const u8 = undefined;
    var n: usize = 0;
    var commands: usize = 0;
    for (entries.items) |*e| switch (e.run) {
        .jump => |s| {
            jumps[n] = s;
            titles[n] = e.title;
            n += 1;
        },
        .action => commands += 1,
    };
    try std.testing.expectEqual(3, n);
    try std.testing.expect(commands > 50);
    // Sorted by title: notes, shell, Untitled.
    try std.testing.expectEqualStrings("Focus: notes", titles[0]);
    try std.testing.expect(jumps[0] == b);
    try std.testing.expectEqualStrings("Focus: shell", titles[1]);
    try std.testing.expect(jumps[1] == a);
    try std.testing.expectEqualStrings("Focus: Untitled", titles[2]);
    try std.testing.expect(jumps[2] == c);
}

/// For tests: the binding actions command palettes performed
/// (`SearchBar.test_perform`), as the configuration writes them, each
/// followed by ";", the terminal they were performed on, and whether a
/// palette was still open in `window` when one was.
const PaletteSeen = struct {
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    var window: ?*Window = null;
    var on: ?*Surface = null;
    var open_then: bool = false;
    fn seen(surface: *Surface, action: input.Binding.Action) bool {
        on = surface;
        if (window) |w| {
            if (w.palette.hwnd != null) open_then = true;
        }
        const s = std.mem.print(buf[len..], "{f};", .{action}) catch return true;
        len += s.len;
        return true;
    }
    fn take() []const u8 {
        const s = buf[0..len];
        len = 0;
        return s;
    }
    fn reset(w: ?*Window) void {
        len = 0;
        window = w;
        on = null;
        open_then = false;
    }
};

/// For tests: toggle the command palette from `surface`, as a binding
/// does, and carry it out, as `run` does.
fn togglePalette(app: *App, surface: *Surface) !void {
    try std.testing.expect(try app.performAction(.{ .surface = &surface.core_surface }, .toggle_command_palette, {}));
    app.createRequested();
}

/// For tests: put `text` in `window`'s palette's field, as typing would.
fn paletteQuery(window: *Window, text: win32.LPCWSTR) void {
    _ = win32.SetWindowTextW(window.palette.edit.?, text);
}

fn paletteRows(window: *const Window) isize {
    return win32.SendMessageW(window.palette.list.?, win32.LB_GETCOUNT, 0, 0);
}

fn paletteSelected(window: *const Window) isize {
    return win32.SendMessageW(window.palette.list.?, win32.LB_GETCURSEL, 0, 0);
}

/// For tests: the entry on `window`'s palette's `row`.
fn paletteEntry(window: *const Window, row: usize) *const CommandPalette.Entry {
    const data = win32.SendMessageW(window.palette.list.?, win32.LB_GETITEMDATA, row, 0);
    return &window.palette.entries.?.items[@intCast(data)];
}

/// For tests: the client point of `window`'s palette's list in the middle
/// of `row`.
fn paletteRowPoint(window: *const Window, row: usize) win32.LPARAM {
    const h = win32.SendMessageW(window.palette.list.?, win32.LB_GETITEMHEIGHT, 0, 0);
    const y: i32 = @intCast(@as(isize, @intCast(row)) * h + @divTrunc(h, 2));
    return testPoint(20, y);
}

fn paletteKey(window: *const Window, vk: win32.WPARAM) void {
    _ = win32.SendMessageW(window.palette.edit.?, win32.WM_KEYDOWN, vk, 0);
}

test "win32: toggle_command_palette opens the command palette over its window, and closes it" {
    // GTK's toggle: the palette opens over the window, at the top centre
    // of the area under the tab bar, above every terminal, its field with
    // the focus, every entry listed and the first selected; again, it
    // closes and the terminal gets the focus back. It is the frame's
    // child, as the search bar is, and runs on the window's focused
    // terminal; opened and closed by `run`, after the core's key callback.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = b;
    window.relayout();
    const p = &window.palette;

    // Not for the app.
    try std.testing.expect(!try app.performAction(.app, .toggle_command_palette, {}));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Recorded, and opened by `run`, for the focused terminal, whichever
    // asked (an `all:` binding asks from every one).
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .toggle_command_palette, {}));
    try std.testing.expect(p.hwnd == null);
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .palette);
    app.createRequested();
    try std.testing.expect(p.open);
    const hwnd = p.hwnd.?;
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(win32.GetAncestor(hwnd, win32.GA_PARENT) == window.hwnd);
    try std.testing.expect(above(window.hwnd, hwnd, a.hwnd));
    try std.testing.expect(above(window.hwnd, hwnd, b.hwnd));
    try std.testing.expect(p.surface == b);
    try std.testing.expect(p.text_height > 0);
    const m = CommandPalette.Metrics.init(Window.dpiOf(&app, window.hwnd));
    // In the area under the tab bar, less the scroll bar of b, the
    // terminal along its right edge.
    var area = window.layoutArea().?;
    area.right = (try paneClient(window, b)).right;
    try std.testing.expect(area.right < window.layoutArea().?.right);
    const want = CommandPalette.paletteRect(m, area, p.text_height).?;
    try std.testing.expectEqual(want, try childRect(window, hwnd));
    try std.testing.expectEqual(m.width, want.right - want.left);
    // Centred, under the top of the area.
    try std.testing.expectEqual(@divTrunc(area.right - m.width, 2), want.left);
    try std.testing.expectEqual(window.layoutArea().?.top + m.margin, want.top);
    try std.testing.expect(FocusSeen.last == p.edit.?);
    // Every entry, the first selected, its rows two lines tall.
    try std.testing.expectEqual(@as(isize, @intCast(p.entries.?.items.len)), paletteRows(window));
    try std.testing.expect(paletteRows(window) > 50);
    try std.testing.expectEqual(0, paletteSelected(window));
    // Shown from its top, the selected row in view.
    try std.testing.expectEqual(0, win32.SendMessageW(p.list.?, win32.LB_GETTOPINDEX, 0, 0));
    try std.testing.expectEqual(m.rowHeight(p.text_height), win32.SendMessageW(p.list.?, win32.LB_GETITEMHEIGHT, 0, 0));
    try std.testing.expect(win32.SendMessageW(p.edit.?, win32.WM_GETFONT, 0, 0) != 0);

    // The frame's focus goes to the field while it is open.
    FocusSeen.last = null;
    _ = Window.wndProc(window.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(FocusSeen.last == p.edit.?);

    // Laid out again, it stays above the terminals.
    _ = win32.SetWindowPos(a.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    window.relayout();
    try std.testing.expect(above(window.hwnd, hwnd, a.hwnd));

    // Again: closed, the terminal with the focus.
    try togglePalette(&app, b);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expect(!p.open);
    try std.testing.expect(!win32.IsWindow(hwnd).toBool());
    try std.testing.expect(FocusSeen.last == b.hwnd);
    _ = Window.wndProc(window.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(FocusSeen.last == b.hwnd);

    // Twice before `run`: open, then closed.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_command_palette, {}));
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_command_palette, {}));
    app.createRequested();
    try std.testing.expect(p.hwnd == null);

    // Not over a title prompt, which holds the frame.
    window.title_prompt.hwnd = window.hwnd;
    try togglePalette(&app, b);
    window.title_prompt.hwnd = null;
    try std.testing.expect(p.hwnd == null);

    // A request from a terminal that begins to close is dropped.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .toggle_command_palette, {}));
    app.forgetClosing(&b.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expect(p.hwnd == null);

    // Left open: the frame's destruction frees it (testCleanup).
    try togglePalette(&app, b);
    try std.testing.expect(p.hwnd != null);
}

test "win32: the command palette's field filters its list, moves the selection and takes its own keys" {
    // GTK's filter on the title or the action key, title matches first;
    // Up, Down, PgUp and PgDn move the list's selection from the field,
    // within its rows; the WM_CHARs of Enter, Tab and Escape never reach
    // the EDIT, and Ctrl+Backspace deletes a word, as in the search field.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    PaletteSeen.reset(window);
    try togglePalette(&app, a);
    const p = &window.palette;
    const edit = p.edit.?;

    // What the filter keeps, in its order.
    paletteQuery(window, L("split"));
    var want: std.ArrayList(u32) = .empty;
    defer want.deinit(alloc);
    try CommandPalette.filter(alloc, p.entries.?.items, "split", &want);
    try std.testing.expect(want.items.len > 4);
    try std.testing.expectEqual(@as(isize, @intCast(want.items.len)), paletteRows(window));
    for (want.items, 0..) |index, row| {
        try std.testing.expect(paletteEntry(window, row) == &p.entries.?.items[index]);
    }
    // Title matches first: "Split Right" before any entry whose action
    // alone says split.
    try std.testing.expect(CommandPalette.match(paletteEntry(window, 0), "split") == .title);
    try std.testing.expectEqual(0, paletteSelected(window));
    paletteQuery(window, L("SPLIT RIGHT"));
    try std.testing.expectEqualStrings("Split Right", paletteEntry(window, 0).title);
    try std.testing.expectEqual(0, paletteSelected(window));

    // The selection moves, within the rows.
    paletteQuery(window, L("split"));
    const last: isize = paletteRows(window) - 1;
    paletteKey(window, win32.VK_DOWN);
    try std.testing.expectEqual(1, paletteSelected(window));
    paletteKey(window, win32.VK_DOWN);
    try std.testing.expectEqual(2, paletteSelected(window));
    paletteKey(window, win32.VK_UP);
    try std.testing.expectEqual(1, paletteSelected(window));
    paletteKey(window, win32.VK_UP);
    paletteKey(window, win32.VK_UP);
    try std.testing.expectEqual(0, paletteSelected(window));
    // A page is the rows the list shows; past the end, the last.
    paletteKey(window, win32.VK_NEXT);
    const page = paletteSelected(window);
    try std.testing.expect(page > 1);
    try std.testing.expectEqual(@min(last, @as(isize, CommandPalette.Metrics.init(96).rows)), page);
    for (0..10) |_| paletteKey(window, win32.VK_NEXT);
    try std.testing.expectEqual(last, paletteSelected(window));
    paletteKey(window, win32.VK_PRIOR);
    try std.testing.expectEqual(last - page, paletteSelected(window));
    for (0..10) |_| paletteKey(window, win32.VK_PRIOR);
    try std.testing.expectEqual(0, paletteSelected(window));
    // Nothing matches: no rows, and Enter does nothing.
    paletteQuery(window, L("zzzzzz"));
    try std.testing.expectEqual(0, paletteRows(window));
    paletteKey(window, win32.VK_DOWN);
    paletteKey(window, win32.VK_RETURN);
    try std.testing.expect(p.hwnd != null);
    try std.testing.expectEqualStrings("", PaletteSeen.take());

    // Enter, Ctrl+Enter, Tab and Escape's WM_CHARs dropped; others typed.
    var buf: [64]u16 = undefined;
    paletteQuery(window, L("new split"));
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 9, 9);
    const forwarded = CommandPalette.test_forwarded;
    for ([_]win32.WPARAM{ '\r', '\n', '\t', 0x1B }) |c| _ = win32.SendMessageW(edit, win32.WM_CHAR, c, 0);
    try std.testing.expectEqual(forwarded, CommandPalette.test_forwarded);
    _ = win32.SendMessageW(edit, win32.WM_CHAR, 'x', 0);
    try std.testing.expectEqual(forwarded + 1, CommandPalette.test_forwarded);
    var n = win32.GetWindowTextW(edit, &buf, buf.len);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("new splitx"), buf[0..@intCast(n)]);
    // Ctrl+Backspace: back to the word's start.
    _ = win32.SendMessageW(edit, win32.WM_CHAR, 0x7F, 0);
    n = win32.GetWindowTextW(edit, &buf, buf.len);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("new "), buf[0..@intCast(n)]);
    try std.testing.expectEqual(forwarded + 1, CommandPalette.test_forwarded);
    try std.testing.expect(p.hwnd != null);
}

test "win32: the command palette runs the chosen entry on its terminal once it has closed" {
    // Enter or a click on a row: the palette closes first, giving the
    // terminal back the focus, as GTK's closes before its action runs so
    // that a dialog the action opens is not held up, then the action is
    // performed on the terminal; under a prompt, recorded for `run` with
    // what it needs, and dropped, freed, if the terminal begins to close.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = b;
    window.relayout();
    const p = &window.palette;
    PaletteSeen.reset(window);

    // Enter: closed, the focus back to the terminal, then performed on it.
    try togglePalette(&app, b);
    paletteQuery(window, L("split right"));
    try std.testing.expectEqual(1, paletteRows(window));
    paletteKey(window, win32.VK_RETURN);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expectEqualStrings("new_split:right;", PaletteSeen.take());
    try std.testing.expect(PaletteSeen.on == b);
    try std.testing.expect(!PaletteSeen.open_then);
    try std.testing.expect(FocusSeen.last == b.hwnd);

    // The selected row, not the first.
    try togglePalette(&app, b);
    paletteQuery(window, L("split"));
    paletteKey(window, win32.VK_DOWN);
    paletteKey(window, win32.VK_DOWN);
    var want_buf: [64]u8 = undefined;
    const want = try std.mem.print(&want_buf, "{f};", .{paletteEntry(window, 2).run.action});
    paletteKey(window, win32.VK_RETURN);
    try std.testing.expectEqualStrings(want, PaletteSeen.take());

    // A click: pressed and released on a row runs it; released on another
    // row, nothing runs, though the press selected its row.
    try togglePalette(&app, b);
    paletteQuery(window, L("split"));
    const list = p.list.?;
    _ = win32.SendMessageW(list, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, paletteRowPoint(window, 1));
    try std.testing.expectEqual(1, paletteSelected(window));
    try std.testing.expect(win32.GetCapture() == list);
    _ = win32.SendMessageW(list, win32.WM_LBUTTONUP, 0, paletteRowPoint(window, 2));
    try std.testing.expect(win32.GetCapture() == null);
    try std.testing.expect(p.hwnd != null);
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    const clicked = try std.mem.print(&want_buf, "{f};", .{paletteEntry(window, 3).run.action});
    _ = win32.SendMessageW(list, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, paletteRowPoint(window, 3));
    _ = win32.SendMessageW(list, win32.WM_LBUTTONUP, 0, paletteRowPoint(window, 3));
    try std.testing.expect(p.hwnd == null);
    try std.testing.expectEqualStrings(clicked, PaletteSeen.take());
    try std.testing.expect(!PaletteSeen.open_then);

    // Under a prompt: closed, recorded, performed by `run`.
    try togglePalette(&app, b);
    paletteQuery(window, L("split right"));
    app.prompt_depth = 1;
    paletteKey(window, win32.VK_RETURN);
    app.prompt_depth = 0;
    try std.testing.expect(p.hwnd == null);
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    try std.testing.expectEqual(1, app.requests.items.len);
    switch (app.requests.items[0]) {
        .palette_run => |chosen| try std.testing.expect(chosen.from == &b.core_surface),
        else => return error.TestUnexpectedResult,
    }
    app.createRequested();
    try std.testing.expectEqualStrings("new_split:right;", PaletteSeen.take());
    try std.testing.expect(PaletteSeen.on == b);
    try std.testing.expectEqual(0, app.requests.items.len);
    // Dropped, and freed, when the terminal begins to close.
    try togglePalette(&app, b);
    paletteQuery(window, L("split right"));
    app.prompt_depth = 1;
    paletteKey(window, win32.VK_RETURN);
    app.prompt_depth = 0;
    app.forgetClosing(&b.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    // And left in `requests` at quit: freed with them (testCleanup).
    try togglePalette(&app, a);
    paletteQuery(window, L("split right"));
    app.prompt_depth = 1;
    paletteKey(window, win32.VK_RETURN);
    app.prompt_depth = 0;
    try std.testing.expectEqual(1, app.requests.items.len);
}

test "win32: a jump in the command palette focuses its terminal, in its tab and window" {
    // GTK's and macOS's jump entries present their terminal: its tab is
    // shown and it gets the focus, its window brought forward if it is
    // another. A terminal that closes while the palette is open is listed
    // no more.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    Window.test_foreground = &ForegroundSeen.seen;
    defer Window.test_foreground = null;
    ForegroundSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    const c = try testTab(&app, window);
    window.selectTab(0);
    const other = try testFrame(&app);
    testResize(other, 1000, 700);
    const d = try testPane(&app, other);
    other.tab().tree = try .init(alloc, d);
    other.tab().focused = d;
    other.relayout();
    a.title = try alloc.dupeSentinel(u8, "alpha", 0);
    c.title = try alloc.dupeSentinel(u8, "gamma", 0);
    d.title = try alloc.dupeSentinel(u8, "delta", 0);
    const p = &window.palette;

    // In a hidden tab of the same window: shown, and focused.
    try togglePalette(&app, a);
    paletteQuery(window, L("focus: gamma"));
    try std.testing.expectEqual(1, paletteRows(window));
    try std.testing.expect(paletteEntry(window, 0).run.jump == c);
    paletteKey(window, win32.VK_RETURN);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expectEqual(1, window.selected);
    try std.testing.expect(window.tab().focused == c);
    try std.testing.expect(FocusSeen.last == c.hwnd);
    try std.testing.expect(ForegroundSeen.last == null);

    // Its Enter's release withheld from the terminal that took the focus,
    // which never saw it pressed.
    try std.testing.expectEqual(1, c.ime.swallow_up.count());
    c.ime.swallow_up = .empty;

    // In another window: brought forward, and focused; the release is
    // withheld there, by the terminal that has the focus now, and not by
    // the one the palette was open for.
    try togglePalette(&app, c);
    try std.testing.expect(p.surface == c);
    paletteQuery(window, L("focus: delta"));
    paletteKey(window, win32.VK_RETURN);
    try std.testing.expect(ForegroundSeen.last == other.hwnd);
    try std.testing.expect(FocusSeen.last == d.hwnd);
    try std.testing.expectEqual(1, d.ime.swallow_up.count());
    try std.testing.expectEqual(0, c.ime.swallow_up.count());
    d.ime.swallow_up = .empty;

    // A terminal that begins to close while it is open: listed no more,
    // the query kept.
    try togglePalette(&app, c);
    paletteQuery(window, L("focus: delta"));
    try std.testing.expectEqual(1, paletteRows(window));
    app.forgetClosing(&d.core_surface);
    try std.testing.expect(p.hwnd != null);
    try std.testing.expectEqual(0, paletteRows(window));
    paletteQuery(window, L("focus:"));
    try std.testing.expectEqual(2, paletteRows(window));
    // A jump recorded under a prompt is dropped with its terminal.
    paletteQuery(window, L("focus: alpha"));
    app.prompt_depth = 1;
    paletteKey(window, win32.VK_RETURN);
    app.prompt_depth = 0;
    try std.testing.expect(app.requests.items[0] == .palette_run);
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
}

test "win32: the command palette closes when its frame is deactivated, has no room, or its terminal or window goes" {
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    const p = &window.palette;

    // Deactivated: closed once the deactivation is over, by a message to
    // itself, and the terminal gets the focus it had.
    try togglePalette(&app, a);
    const hwnd = p.hwnd.?;
    _ = Window.wndProc(window.hwnd, win32.WM_ACTIVATE, win32.WA_INACTIVE, 0);
    try std.testing.expect(p.hwnd != null);
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(&msg, hwnd, CommandPalette.WM_PALETTE_CLOSE, CommandPalette.WM_PALETTE_CLOSE, win32.PM_REMOVE).toBool());
    _ = win32.DispatchMessageW(&msg);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expect(FocusSeen.last == a.hwnd);
    // Escape: closed, the focus back to the terminal; its release withheld
    // from the terminal, which never saw it pressed.
    try togglePalette(&app, a);
    try std.testing.expect(FocusSeen.last == p.edit.?);
    try std.testing.expectEqual(0, a.ime.swallow_up.count());
    paletteKey(window, win32.VK_ESCAPE);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expect(FocusSeen.last == a.hwnd);
    try std.testing.expectEqual(1, a.ime.swallow_up.count());
    a.ime.swallow_up = .empty;

    // No room after a layout: closed; and not opened where there is none.
    try togglePalette(&app, a);
    testResize(window, 1000, 120);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expect(FocusSeen.last == a.hwnd);
    try togglePalette(&app, a);
    try std.testing.expect(p.hwnd == null);
    testResize(window, 1000, 700);
    // A narrower window: narrower, and placed again, left of b's scroll
    // bar.
    try togglePalette(&app, a);
    testResize(window, 500, 700);
    try std.testing.expect(p.hwnd != null);
    const narrow = try childRect(window, p.hwnd.?);
    const margin = CommandPalette.Metrics.init(Window.dpiOf(&app, window.hwnd)).margin;
    try std.testing.expectEqual((try paneClient(window, b)).right - 2 * margin, narrow.right - narrow.left);
    try std.testing.expectEqual(margin, narrow.left);

    // Its terminal begins to close: closed. Another one: still open.
    app.forgetClosing(&b.core_surface);
    try std.testing.expect(p.hwnd != null);
    app.forgetClosing(&a.core_surface);
    try std.testing.expect(p.hwnd == null);

    // The terminal with the focus is the one it runs on; but a closing one
    // passing the focus on keeps it, and it closes with that one.
    try togglePalette(&app, a);
    window.setFocused(b);
    try std.testing.expect(p.surface == b);
    window.setFocused(a);
    try std.testing.expect(p.surface == a);
    a.closing = true;
    window.setFocused(b);
    try std.testing.expect(p.surface == a);
    app.forgetClosing(&a.core_surface);
    a.closing = false;
    try std.testing.expect(p.hwnd == null);

    // Its window closing: closed first, before the terminals.
    try togglePalette(&app, a);
    try std.testing.expect(window.destroy());
    try std.testing.expectEqual(0, app.windows.items.len);
}

test "win32: the wheel over the command palette scrolls its list, and a modified one returns" {
    // A plain notch over the list or the field scrolls the list. The system
    // list hands a wheel it does not take (one with Ctrl or Shift) to its
    // parent, the palette, which forwards the wheel to the list: that one
    // is dropped there rather than sent round again until the stack runs
    // out. Each call returns, and the palette stays open.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    try togglePalette(&app, a);
    const p = &window.palette;
    const list = p.list.?;
    const edit = p.edit.?;
    try std.testing.expect(paletteRows(window) > 2 * CommandPalette.Metrics.init(96).rows);

    // A notch toward the user, over the list, then over the field: the
    // list scrolls down each time.
    const top = struct {
        fn of(l: win32.HWND) isize {
            return win32.SendMessageW(l, win32.LB_GETTOPINDEX, 0, 0);
        }
    }.of;
    try std.testing.expectEqual(0, top(list));
    _ = win32.SendMessageW(list, win32.WM_MOUSEWHEEL, testWheel(-120), 0);
    const after_list = top(list);
    try std.testing.expect(after_list > 0);
    _ = win32.SendMessageW(edit, win32.WM_MOUSEWHEEL, testWheel(-120), 0);
    try std.testing.expect(top(list) > after_list);

    // With Ctrl or Shift, over the list, the field or the palette itself:
    // the call returns, the palette is open, and the wheel is used for
    // nothing.
    for ([_]win32.WPARAM{ win32.MK_CONTROL, win32.MK_SHIFT, win32.MK_CONTROL | win32.MK_SHIFT }) |mods| {
        for ([_]win32.HWND{ list, edit, p.hwnd.? }) |to| {
            const before = top(list);
            _ = win32.SendMessageW(to, win32.WM_MOUSEWHEEL, mods | testWheel(-120), 0);
            try std.testing.expect(p.hwnd != null);
            try std.testing.expect(p.open);
            try std.testing.expectEqual(before, top(list));
        }
    }
    // A plain one over the field, which the palette forwards, still
    // scrolls after them.
    const before = top(list);
    _ = win32.SendMessageW(edit, win32.WM_MOUSEWHEEL, testWheel(-120), 0);
    try std.testing.expect(top(list) > before);
    try std.testing.expect(!p.wheeling);
}

test "win32: the command palette's tooltip follows the row under the pointer, and goes with the palette" {
    // The pointer over a row puts that row's description in the tooltip;
    // a refill, a scroll or the pointer leaving the list forgets the row.
    // Without a tooltip, which a process with no Common Controls v6
    // manifest may not get, all of it works the same. The tooltip, owned
    // by the frame, is destroyed with the palette.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    try togglePalette(&app, a);
    const p = &window.palette;
    const list = p.list.?;
    const tip = p.tip;
    if (tip) |t| try std.testing.expect(win32.IsWindow(t).toBool());
    try std.testing.expect(p.hover_row == null);

    // Row by row, then the same row again.
    for ([_]usize{ 0, 1, 3, 3 }) |row| {
        _ = win32.SendMessageW(list, win32.WM_MOUSEMOVE, 0, paletteRowPoint(window, row));
        try std.testing.expectEqual(@as(?usize, row), p.hover_row);
        try std.testing.expect(paletteEntry(window, row).tooltip() != null);
    }
    // Off the rows (above the list's client area), no row.
    _ = win32.SendMessageW(list, win32.WM_MOUSEMOVE, 0, testPoint(20, -5));
    try std.testing.expect(p.hover_row == null);

    // A query refills the list: the row is forgotten, and found again.
    _ = win32.SendMessageW(list, win32.WM_MOUSEMOVE, 0, paletteRowPoint(window, 2));
    try std.testing.expectEqual(@as(?usize, 2), p.hover_row);
    paletteQuery(window, L("split"));
    try std.testing.expect(paletteRows(window) > 2);
    try std.testing.expect(p.hover_row == null);
    _ = win32.SendMessageW(list, win32.WM_MOUSEMOVE, 0, paletteRowPoint(window, 2));
    try std.testing.expectEqual(@as(?usize, 2), p.hover_row);
    try std.testing.expect(paletteEntry(window, 2).tooltip() != null);

    // Leaving the list, and a scroll, forget it.
    _ = win32.SendMessageW(list, win32.WM_MOUSELEAVE, 0, 0);
    try std.testing.expect(p.hover_row == null);
    try std.testing.expect(!p.tracking_leave);
    paletteQuery(window, L(""));
    _ = win32.SendMessageW(list, win32.WM_MOUSEMOVE, 0, paletteRowPoint(window, 1));
    try std.testing.expectEqual(@as(?usize, 1), p.hover_row);
    _ = win32.SendMessageW(list, win32.WM_MOUSEWHEEL, testWheel(-120), 0);
    try std.testing.expect(p.hover_row == null);

    // Closed, the palette takes its tooltip with it.
    CommandPalette.close(window);
    try std.testing.expect(p.hwnd == null);
    try std.testing.expect(p.tip == null);
    if (tip) |t| try std.testing.expect(!win32.IsWindow(t).toBool());
}

test "win32: a terminal closing while the command palette is open leaves its selection where it was" {
    // Every terminal has a jump, so any one that closes, anywhere, lists
    // the palette's entries again. The entry the user moved the selection
    // to stays selected, in its new row, the list scrolled as it was; the
    // first row is selected if it was the closing terminal's own jump.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    const other = try testFrame(&app);
    const d = try testPane(&app, other);
    const e = try testPane(&app, other);
    const f = try testPane(&app, other);
    other.tab().tree = try testRow(alloc, &.{ d, e, f });
    other.tab().focused = d;
    a.title = try alloc.dupeSentinel(u8, "main", 0);
    b.title = try alloc.dupeSentinel(u8, "notes", 0);
    d.title = try alloc.dupeSentinel(u8, "logs", 0);
    e.title = try alloc.dupeSentinel(u8, "kilo", 0);
    f.title = try alloc.dupeSentinel(u8, "zeta", 0);
    defer for ([_]*Surface{ d, e, f }) |s| {
        s.closing = false;
    };
    const p = &window.palette;
    const list_top = struct {
        fn of(w: *const Window) isize {
            return win32.SendMessageW(w.palette.list.?, win32.LB_GETTOPINDEX, 0, 0);
        }
    }.of;

    // A command further down, the list scrolled to it, the selection then
    // moved up off the last row shown: the same command, the same top.
    try togglePalette(&app, a);
    paletteKey(window, win32.VK_NEXT);
    paletteKey(window, win32.VK_NEXT);
    paletteKey(window, win32.VK_DOWN);
    for (0..3) |_| paletteKey(window, win32.VK_UP);
    const row = paletteSelected(window);
    try std.testing.expect(row > CommandPalette.Metrics.init(96).rows);
    const chosen = paletteEntry(window, @intCast(row)).*;
    try std.testing.expect(chosen.run == .action);
    var title_buf: [64]u8 = undefined;
    const title = try std.mem.print(&title_buf, "{s}", .{chosen.title});
    var key_buf: [64]u8 = undefined;
    const key = try std.mem.print(&key_buf, "{s}", .{chosen.action_key});
    const top = list_top(window);
    try std.testing.expect(top > 0);
    d.closing = true;
    app.forgetClosing(&d.core_surface);
    try std.testing.expect(p.hwnd != null);
    const now = paletteEntry(window, @intCast(paletteSelected(window)));
    try std.testing.expectEqualStrings(title, now.title);
    try std.testing.expectEqualStrings(key, now.action_key);
    try std.testing.expectEqual(top, list_top(window));

    // A jump to another terminal, the closing one's jump above it: the
    // same jump, a row up.
    paletteQuery(window, L("focus:"));
    try std.testing.expectEqual(4, paletteRows(window));
    paletteKey(window, win32.VK_DOWN);
    paletteKey(window, win32.VK_DOWN);
    try std.testing.expect(paletteEntry(window, 2).run.jump == b);
    try std.testing.expectEqual(2, paletteSelected(window));
    e.closing = true;
    app.forgetClosing(&e.core_surface);
    try std.testing.expectEqual(3, paletteRows(window));
    try std.testing.expectEqual(1, paletteSelected(window));
    try std.testing.expect(paletteEntry(window, 1).run.jump == b);

    // The closing terminal's own jump: the first row.
    paletteKey(window, win32.VK_DOWN);
    try std.testing.expect(paletteEntry(window, 2).run.jump == f);
    f.closing = true;
    app.forgetClosing(&f.core_surface);
    try std.testing.expectEqual(2, paletteRows(window));
    try std.testing.expectEqual(0, paletteSelected(window));
    try std.testing.expectEqual(0, list_top(window));
}

test "win32: a search bar opened while the command palette is open stays under it" {
    // The palette is above the terminals and their search bars. A bar
    // opened from the palette's field, Ctrl+Shift+F as `start_search`,
    // is placed outside a layout: under the palette, not over it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = b;
    window.relayout();
    try togglePalette(&app, b);
    const p = &window.palette;
    const palette = p.hwnd.?;

    // The core's answer to the binding from the field.
    try std.testing.expect(try app.performAction(.{ .surface = &b.core_surface }, .start_search, .{ .needle = "" }));
    const bar = b.search_bar.hwnd.?;
    try std.testing.expect(shown(bar));
    try std.testing.expect(above(window.hwnd, palette, bar));
    // Over its terminal still.
    try std.testing.expect(above(window.hwnd, bar, b.hwnd));
    // The two overlap: the bar at the right terminal's top right, the
    // palette across the middle.
    const pr = try childRect(window, palette);
    const br = try childRect(window, bar);
    try std.testing.expect(br.left < pr.right and br.right > pr.left and br.top < pr.bottom and br.bottom > pr.top);
    // The focus move it asks for keeps the keyboard in the palette.
    app.applyPendingFocus();
    try std.testing.expect(FocusSeen.last == p.edit.?);
    try std.testing.expect(above(window.hwnd, palette, bar));
    // And again from the other terminal, whose bar is made now.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "x" }));
    try std.testing.expect(above(window.hwnd, palette, a.search_bar.hwnd.?));
    // Once the palette has closed, a bar placed goes to the top.
    try togglePalette(&app, b);
    try std.testing.expect(p.hwnd == null);
    SearchBar.place(b);
    try std.testing.expect(above(window.hwnd, bar, a.hwnd));
}

test "win32: keys in the command palette perform the terminal's bindings for its window, and act on the field" {
    // The field follows the search field's rules (`overlay_keys`): a
    // binding for the window, its tabs and splits or the palette acts, and
    // select all acts on the field, also when recorded under a prompt and
    // replayed by `run`; Ctrl+Shift+P, the palette's own binding, toggles
    // it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    const arena = app.config._arena.?.allocator();
    try app.config.keybind.parseCLI(arena, "ctrl+shift+m=new_split:right");
    try app.config.keybind.parseCLI(arena, "chain=select_all");

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    PaletteSeen.reset(window);
    try togglePalette(&app, a);
    const p = &window.palette;
    const edit = p.edit.?;

    try fieldKey(edit, 'T', .{ .ctrl = true, .shift = true }, 0x14);
    try std.testing.expectEqualStrings("new_tab;", PaletteSeen.take());
    try std.testing.expect(PaletteSeen.on == a);
    try fieldKey(edit, 'P', .{ .ctrl = true, .shift = true }, 0x10);
    try std.testing.expectEqualStrings("toggle_command_palette;", PaletteSeen.take());
    try std.testing.expect(p.hwnd != null);

    // Select all: on the field.
    paletteQuery(window, L("ab"));
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 1, 1);
    try fieldKey(edit, 'A', .{ .ctrl = true, .shift = true }, null);
    var from: win32.DWORD = 0;
    var to: win32.DWORD = 0;
    _ = win32.SendMessageW(edit, win32.EM_GETSEL, @intFromPtr(&from), @bitCast(@intFromPtr(&to)));
    try std.testing.expectEqual([2]win32.DWORD{ 0, 2 }, [2]win32.DWORD{ from, to });
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    // A binding with an action for the core, recorded under a prompt as
    // the palette's, and replayed: its select all onto the palette's
    // field.
    _ = win32.SendMessageW(edit, win32.EM_SETSEL, 1, 1);
    app.prompt_depth = 1;
    try fieldKey(edit, 'M', .{ .ctrl = true, .shift = true }, 0x0D);
    app.prompt_depth = 0;
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    try std.testing.expectEqual(1, app.requests.items.len);
    switch (app.requests.items[0]) {
        .overlay_key => |key| try std.testing.expectEqual(overlay_keys.Field.palette, key.field),
        else => return error.TestUnexpectedResult,
    }
    app.createRequested();
    try std.testing.expectEqualStrings("new_split:right;", PaletteSeen.take());
    _ = win32.SendMessageW(edit, win32.EM_GETSEL, @intFromPtr(&from), @bitCast(@intFromPtr(&to)));
    try std.testing.expectEqual([2]win32.DWORD{ 0, 2 }, [2]win32.DWORD{ from, to });
    try std.testing.expect(p.hwnd != null);
}

/// For tests: the core's `mouse_over_link` on `surface`, as its cursor
/// callback sends it for the link under the pointer, or empty off it.
fn testLink(app: *App, surface: *Surface, url: [:0]const u8) !bool {
    return app.performAction(.{ .surface = &surface.core_surface }, .mouse_over_link, .{ .url = url });
}

/// For tests: the text of `surface`'s link preview window, as UTF-8 in
/// `buf`.
fn previewText(surface: *const Surface, buf: []u8) ![]const u8 {
    var wide: [512]u16 = undefined;
    const n = win32.GetWindowTextW(surface.overlays.link_preview.hwnd.?, &wide, wide.len);
    const len = try std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]);
    return buf[0..len];
}

/// For tests: the window `surface`'s overlay `name` is placed just above:
/// the highest of the overlays under it in `Overlays.stack` that shows,
/// else the terminal.
fn overlayUnder(surface: *const Surface, comptime name: []const u8) win32.HWND {
    var under = surface.hwnd;
    inline for (Overlays.stack) |n| {
        if (std.mem.eql(u8, n, name)) break;
        if (@field(surface.overlays, n).hwnd) |h| {
            if (shown(h)) under = h;
        }
    }
    return under;
}

/// For tests: `surface`'s link preview shows in `window` over its
/// terminal's bottom `side` corner, as big as its URL with GTK's padding
/// but no wider than the terminal, and just above the terminal, or above
/// the overlays under it that show.
fn expectPreviewAt(window: *const Window, surface: *const Surface, side: LinkPreview.Side) !void {
    const p = &surface.overlays.link_preview;
    const hwnd = p.hwnd.?;
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(win32.GetAncestor(hwnd, win32.GA_PARENT) == window.hwnd);
    try std.testing.expect(p.text_size.width > 0 and p.text_size.height > 0);
    const pane = try paneClient(window, surface);
    const m = LinkPreview.Metrics.init(Window.dpiOf(window.app, window.hwnd));
    const width = @min(p.text_size.width + 2 * m.pad_x, pane.right - pane.left);
    const height = p.text_size.height + 2 * m.pad_y;
    const left = switch (side) {
        .left => pane.left,
        .right => pane.right - width,
    };
    try std.testing.expectEqual(
        win32.RECT{ .left = left, .top = pane.bottom - height, .right = left + width, .bottom = pane.bottom },
        try childRect(window, hwnd),
    );
    try std.testing.expect(win32.GetWindow(overlayUnder(surface, "link_preview"), win32.GW_HWNDPREV) == hwnd);
}

/// For tests: the pointer moved to `x`, `y` in `surface`'s client area.
fn testPointer(surface: *const Surface, x: i32, y: i32) void {
    _ = win32.SendMessageW(surface.hwnd, win32.WM_MOUSEMOVE, 0, testPoint(x, y));
}

test "win32: mouse_over_link shows the URL over its terminal's bottom-left corner, and an empty one hides it" {
    // GTK's `url_left`: the URL of the link under the pointer in a label
    // over the terminal's bottom-left corner, hidden while the URL is
    // empty. The preview is a child of the frame, above its terminal, as
    // the search bar is, made hidden with the terminal; it is passive, the
    // pointer over it going to the terminal under it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    // Made with each terminal, hidden.
    const hwnd = b.overlays.link_preview.hwnd.?;
    try std.testing.expect(!shown(a.overlays.link_preview.hwnd.?));
    try std.testing.expect(!shown(hwnd));

    // Not for the app.
    try std.testing.expect(!try app.performAction(.app, .mouse_over_link, .{ .url = "https://example.com" }));

    var buf: [1024]u8 = undefined;
    try std.testing.expect(try testLink(&app, b, "https://example.com/some/long/path"));
    try expectPreviewAt(window, b, .left);
    try std.testing.expectEqualStrings("https://example.com/some/long/path", try previewText(b, &buf));
    try std.testing.expect(!shown(a.overlays.link_preview.hwnd.?));
    const short = try childRect(window, hwnd);

    // The same URL again, as each move over the link sends it: the same.
    try std.testing.expect(try testLink(&app, b, "https://example.com/some/long/path"));
    try expectPreviewAt(window, b, .left);
    try std.testing.expectEqual(short, try childRect(window, hwnd));

    // Another link's: its URL, wider.
    try std.testing.expect(try testLink(&app, b, "https://example.com/some/long/path/and/more"));
    try expectPreviewAt(window, b, .left);
    try std.testing.expectEqualStrings("https://example.com/some/long/path/and/more", try previewText(b, &buf));
    try std.testing.expect((try childRect(window, hwnd)).right > short.right);

    // Off the link: hidden, its text gone; laid out again, still hidden.
    try std.testing.expect(try testLink(&app, b, ""));
    try std.testing.expect(!shown(hwnd));
    try std.testing.expectEqualStrings("", try previewText(b, &buf));
    try std.testing.expect(b.overlays.link_preview.url == null);
    window.relayout();
    try std.testing.expect(!shown(hwnd));
    // An empty one again changes nothing.
    try std.testing.expect(try testLink(&app, b, ""));
    try std.testing.expect(!shown(hwnd));

    // A URL wider than its terminal: as wide as the terminal's client
    // area, left of its scroll bar, cut there.
    var long_buf: [321]u8 = undefined;
    @memcpy(long_buf[0..20], "https://example.com/");
    @memset(long_buf[20..320], 'x');
    long_buf[320] = 0;
    const long: [:0]const u8 = long_buf[0..320 :0];
    try std.testing.expect(try testLink(&app, b, long));
    try expectPreviewAt(window, b, .left);
    const pane = try paneClient(window, b);
    try std.testing.expect(b.overlays.link_preview.text_size.width > pane.right - pane.left);
    try std.testing.expectEqual(pane.right - pane.left, (try childRect(window, hwnd)).right - (try childRect(window, hwnd)).left);
    try std.testing.expectEqualStrings(long, try previewText(b, &buf));

    // Passive: Windows gives the pointer over it to the window under it.
    try std.testing.expectEqual(win32.HTTRANSPARENT, win32.SendMessageW(hwnd, win32.WM_NCHITTEST, 0, 0));
}

test "win32: a link preview shows control, bidirectional and zero-width code points escaped, as macOS does" {
    // The URL comes from program output, and a code point the link
    // policy refuses (`unsafeCodepoint`) could reorder or hide part of it,
    // or add a line, where the preview is the way to see the target. The
    // macOS app's preview writes each as `\u{...}`, in upper-case hex
    // without leading zeros (UntrustedURLTests.swift).
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    // macOS's own case: a right-to-left override.
    var buf: [1024]u8 = undefined;
    try std.testing.expect(try testLink(&app, a, "https://example.com/a\u{202E}b"));
    try expectPreviewAt(window, a, .left);
    try std.testing.expectEqualStrings("https://example.com/a\\u{202E}b", try previewText(a, &buf));

    // A zero-width space, an isolate, the Arabic letter mark, a C1 and a
    // C0 control, a line separator, a BOM and a word joiner; around them,
    // code points that show as they are, one past the BMP, and invalid
    // UTF-8, shown as U+FFFD.
    const url = "https://example.com/a\u{200B}b\u{2066}c\u{061C}d\u{0085}e\nf\u{2028}g\u{FEFF}h\u{2060}i\u{00E9}\u{00A0}\u{1F600}\xffj";
    try std.testing.expect(try testLink(&app, a, url));
    try expectPreviewAt(window, a, .left);
    try std.testing.expectEqualStrings(
        "https://example.com/a\\u{200B}b\\u{2066}c\\u{61C}d\\u{85}e\\u{A}f\\u{2028}g\\u{FEFF}h\\u{2060}i\u{00E9}\u{00A0}\u{1F600}\u{FFFD}j",
        try previewText(a, &buf),
    );
    // The URL itself is kept as the core sent it, which it sends again
    // on every move over the link.
    try std.testing.expectEqualStrings(url, a.overlays.link_preview.url.?);
}

test "win32: a link preview shows at the bottom-right while the pointer is over its place, and back" {
    // GTK shows `url_right` while the pointer is over `url_left`, as
    // macOS's banner does. The pointer over the preview is the terminal's
    // (its WM_MOUSEMOVE), which says where it is.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    const url = "https://example.com/some/long/path";
    try std.testing.expect(try testLink(&app, a, url));
    try expectPreviewAt(window, a, .left);
    const pane = try paneRect(window, a);
    const place = try childRect(window, a.overlays.link_preview.hwnd.?);
    // Its place, in the terminal's client coordinates.
    const x = place.left - pane.left;
    const y = place.top - pane.top;
    const w = place.right - place.left;
    const h = place.bottom - place.top;

    // The pointer over it: at the right, and there while it stays over
    // the place it left, whose corners count.
    testPointer(a, x + 5, y + 2);
    try expectPreviewAt(window, a, .right);
    testPointer(a, x, y);
    try expectPreviewAt(window, a, .right);
    testPointer(a, x + w - 1, y + h - 1);
    try expectPreviewAt(window, a, .right);
    // Just off it, above or to its right: at the left again.
    testPointer(a, x + 5, y - 1);
    try expectPreviewAt(window, a, .left);
    testPointer(a, x + w, y + 2);
    try expectPreviewAt(window, a, .left);
    // Over its place at the right only, which GTK does not watch: the left.
    testPointer(a, (pane.right - pane.left) - 3, y + 2);
    try expectPreviewAt(window, a, .left);

    // Another terminal's pointer is not this one's.
    testPointer(b, x + 5, y + 2);
    try expectPreviewAt(window, a, .left);

    // A link's URL that comes with the pointer already over the place
    // shows at the right at once.
    try std.testing.expect(try testLink(&app, a, ""));
    testPointer(a, x + 5, y + 2);
    try std.testing.expect(!shown(a.overlays.link_preview.hwnd.?));
    try std.testing.expect(try testLink(&app, a, url));
    try expectPreviewAt(window, a, .right);

    // The pointer leaving the terminal: at the left.
    _ = win32.SendMessageW(a.hwnd, win32.WM_MOUSELEAVE, 0, 0);
    try expectPreviewAt(window, a, .left);
}

test "win32: a link preview follows its terminal through layouts, zooms and tabs, under the search bar and palette" {
    // The preview is the frame's child, so every layout places it: with
    // its terminal when the frame is resized, hidden with it by a zoom or
    // a hidden tab and shown again with it, over the whole window in
    // fullscreen, above a terminal raised over it, and back from a
    // minimize. It stays just above its terminal, under the terminal's
    // search bar and the window's command palette.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    try std.testing.expect(try testLink(&app, a, "https://example.com/some/long/path"));
    try expectPreviewAt(window, a, .left);
    const hwnd = a.overlays.link_preview.hwnd.?;

    // The frame resized: with its terminal's bottom.
    const was = try childRect(window, hwnd);
    testResize(window, 1000, 600);
    try expectPreviewAt(window, a, .left);
    try std.testing.expect((try childRect(window, hwnd)).bottom > was.bottom);

    // Under the terminal's search bar and the window's palette, also when
    // a new URL places it while both are open.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = a.search_bar.hwnd.?;
    try std.testing.expect(shown(bar));
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    try togglePalette(&app, a);
    const palette = window.palette.hwnd.?;
    try std.testing.expect(above(window.hwnd, palette, hwnd));
    try std.testing.expect(try testLink(&app, a, "https://example.com/another"));
    try expectPreviewAt(window, a, .left);
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    try std.testing.expect(above(window.hwnd, palette, hwnd));
    window.relayout();
    try expectPreviewAt(window, a, .left);
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    try std.testing.expect(above(window.hwnd, palette, hwnd));
    try togglePalette(&app, a);
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    app.applyPendingFocus();

    // A zoom on the other terminal hides it with its own, its URL kept;
    // back, shown. A zoom on its own: the whole window's corner.
    window.toggleZoom(b);
    try std.testing.expect(!shown(a.hwnd));
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(a.overlays.link_preview.url != null);
    window.toggleZoom(b);
    try expectPreviewAt(window, a, .left);
    window.toggleZoom(a);
    try expectPreviewAt(window, a, .left);
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    window.toggleZoom(a);
    try expectPreviewAt(window, a, .left);

    // Its terminal raised over it, and the other over that: laid out
    // again, just above its own, where it was before.
    const placed = try childRect(window, hwnd);
    _ = win32.SetWindowPos(a.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    _ = win32.SetWindowPos(b.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    try std.testing.expect(!above(window.hwnd, hwnd, a.hwnd));
    try std.testing.expect(win32.GetWindow(a.hwnd, win32.GW_HWNDPREV) == b.hwnd);
    window.relayout();
    try expectPreviewAt(window, a, .left);
    try std.testing.expectEqual(placed, try childRect(window, hwnd));

    // A second tab brings the tab bar; fullscreen takes it away.
    const c = try testTab(&app, window);
    window.relayout();
    try expectPreviewAt(window, a, .left);
    window.toggleFullscreen();
    try expectPreviewAt(window, a, .left);
    try std.testing.expectEqual(0, (try paneRect(window, a)).top);
    window.toggleFullscreen();
    try expectPreviewAt(window, a, .left);

    // The other tab shown: hidden with its terminals, its URL kept; shown
    // again with them.
    window.selectTab(1);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(a.overlays.link_preview.url != null);
    try std.testing.expect(!shown(c.overlays.link_preview.hwnd.?));
    window.selectTab(0);
    try expectPreviewAt(window, a, .left);

    // Minimized, given a new URL and a shorter restored size: nothing is
    // laid out while the frame is minimized, so the restore lays out the
    // terminals at the new size and the preview over them, as wide as the
    // new URL.
    const shown_before = try childRect(window, hwnd);
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWMINNOACTIVE);
    try std.testing.expect(win32.IsIconic(window.hwnd).toBool());
    try std.testing.expect(try testLink(&app, a, "https://example.com/some/long/path/and/more"));
    var wp = std.mem.zeroes(win32.WINDOWPLACEMENT);
    wp.length = @sizeOf(win32.WINDOWPLACEMENT);
    try std.testing.expect(win32.GetWindowPlacement(window.hwnd, &wp).toBool());
    wp.rcNormalPosition.bottom -= 100;
    wp.showCmd = @intCast(win32.SW_SHOWMINNOACTIVE);
    try std.testing.expect(win32.SetWindowPlacement(window.hwnd, &wp).toBool());
    try std.testing.expect(win32.IsIconic(window.hwnd).toBool());
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    try std.testing.expect(!win32.IsIconic(window.hwnd).toBool());
    try expectPreviewAt(window, a, .left);
    const restored = try childRect(window, hwnd);
    try std.testing.expect(restored.bottom < shown_before.bottom);
    try std.testing.expect(restored.right > shown_before.right);
}

test "win32: a link preview moves with its tab to a new window, and follows its scale, font and theme" {
    // A tab moved to a new window takes its terminals' previews into the
    // new frame. A change of DPI (the frame's WM_DPICHANGED) makes the
    // preview's font and padding again at the new scale, a change of the
    // system's message font makes its font again, and a change of the
    // title bar's theme draws it again.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    _ = try testTab(&app, window);
    window.relayout();
    try std.testing.expect(try testLink(&app, a, "https://example.com/some/long/path"));
    try expectPreviewAt(window, a, .left);
    const hwnd = a.overlays.link_preview.hwnd.?;

    // The tab moved to a new window: the preview goes to its frame.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = a.window;
    try std.testing.expect(moved != window);
    try expectPreviewAt(moved, a, .left);
    try std.testing.expect(a.overlays.link_preview.hwnd.? == hwnd);
    // One not showing goes with its terminal too, for when it shows.
    try std.testing.expect(win32.GetAncestor(b.overlays.link_preview.hwnd.?, win32.GA_PARENT) == moved.hwnd);

    // A new scale: the font and the padding at it.
    const before = a.overlays.link_preview.text_size;
    try std.testing.expect(a.overlays.font_dpi > 0 and a.overlays.font_dpi < 192);
    const Dpi = struct {
        fn of(_: win32.HWND) callconv(.winapi) win32.UINT {
            return 192;
        }
    };
    app.get_dpi_for_window = &Dpi.of;
    var suggested = try windowRect(moved.hwnd);
    _ = win32.SendMessageW(moved.hwnd, win32.WM_DPICHANGED, 192 << 16 | 192, @bitCast(@intFromPtr(&suggested)));
    try std.testing.expectEqual(192, a.overlays.font_dpi);
    try std.testing.expect(a.overlays.link_preview.text_size.height > before.height);
    try std.testing.expect(a.overlays.link_preview.text_size.width > before.width);
    try expectPreviewAt(moved, a, .left);

    // The system's message font changed: made again as it is placed.
    const font = a.overlays.font.?;
    _ = win32.SendMessageW(moved.hwnd, win32.WM_SETTINGCHANGE, win32.SPI_SETNONCLIENTMETRICS, 0);
    try std.testing.expect(a.overlays.font.? != font);
    try expectPreviewAt(moved, a, .left);

    // The title bar's theme: drawn again in its colours, each way.
    const pending = struct {
        fn f(h: win32.HWND) bool {
            return win32.GetUpdateRect(h, null, .FALSE).toBool();
        }
    }.f;
    try std.testing.expect(shown(moved.hwnd));
    const first: configpkg.Config.WindowTheme = if (moved.dark_frame) .light else .dark;
    const second: configpkg.Config.WindowTheme = if (moved.dark_frame) .dark else .light;
    for ([_]configpkg.Config.WindowTheme{ first, second }) |theme| {
        _ = win32.UpdateWindow(hwnd);
        try std.testing.expect(!pending(hwnd));
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.@"window-theme" = theme;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        try std.testing.expectEqual(theme == .dark, moved.dark_frame);
        try std.testing.expect(pending(hwnd));
    }
}

test "win32: a link preview goes with its terminal, shown or not" {
    // A terminal closing takes its preview's window with it, shown or
    // not, and its URL is freed with it (the testing allocator). A window
    // closing frees them whichever Windows destroys first: a terminal
    // raised above its preview is destroyed, and freed, first, and lets go
    // of its preview's window (`Overlays.deinit`), whose WM_DESTROY then
    // has no terminal to write to.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    const d = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b, c, d });
    window.tab().focused = a;
    window.relayout();

    // Closing while it shows.
    try std.testing.expect(try testLink(&app, a, "https://example.com/a"));
    const ha = a.overlays.link_preview.hwnd.?;
    try std.testing.expect(shown(ha));
    try std.testing.expect(a.destroy());
    try std.testing.expect(!win32.IsWindow(ha).toBool());
    // And one that never showed.
    const hb = b.overlays.link_preview.hwnd.?;
    try std.testing.expect(b.destroy());
    try std.testing.expect(!win32.IsWindow(hb).toBool());

    // The window closing with two showing: c's just above it, destroyed
    // first; d raised above its own.
    try std.testing.expect(try testLink(&app, c, "https://example.com/c"));
    try std.testing.expect(try testLink(&app, d, "https://example.com/d"));
    const hc = c.overlays.link_preview.hwnd.?;
    const hd = d.overlays.link_preview.hwnd.?;
    _ = win32.SetWindowPos(d.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    try std.testing.expect(above(window.hwnd, d.hwnd, hd));
    try std.testing.expect(above(window.hwnd, hc, c.hwnd));
    Overlays.test_detached = 0;
    try std.testing.expect(win32.DestroyWindow(window.hwnd).toBool());
    try std.testing.expect(!win32.IsWindow(hc).toBool());
    try std.testing.expect(!win32.IsWindow(hd).toBool());
    try std.testing.expectEqual(0, app.windows.items.len);
    try std.testing.expectEqual(0, app.surfaces.items.len);
    // d's: c's own came while c was there.
    try std.testing.expectEqual(1, Overlays.test_detached);
}

/// For tests: the core's `key_table` on `surface`, as its key callback
/// sends it.
fn testKeyTable(app: *App, surface: *Surface, value: apprt.action.KeyTable) !bool {
    return app.performAction(.{ .surface = &surface.core_surface }, .key_table, value);
}

/// For tests: the core's `key_sequence` on `surface`, as its key callback
/// sends it.
fn testKeySequence(app: *App, surface: *Surface, value: apprt.action.KeySequence) !bool {
    return app.performAction(.{ .surface = &surface.core_surface }, .key_sequence, value);
}

/// For tests: the text of `surface`'s key-state indicator window, as UTF-8
/// in `buf`.
fn keyStateText(surface: *const Surface, buf: []u8) ![]const u8 {
    var wide: [512]u16 = undefined;
    const n = win32.GetWindowTextW(surface.overlays.key_state.hwnd.?, &wide, wide.len);
    const len = try std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]);
    return buf[0..len];
}

/// For tests: `surface`'s key-state indicator shows in `window` at its
/// terminal's bottom centre, a margin above its bottom, as big as its
/// text with GTK's padding, just above the terminal, or above the overlays
/// under it that show, as its link preview.
fn expectKeyStateAt(window: *const Window, surface: *const Surface) !void {
    const k = &surface.overlays.key_state;
    const hwnd = k.hwnd.?;
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(win32.GetAncestor(hwnd, win32.GA_PARENT) == window.hwnd);
    try std.testing.expect(k.text_size.width > 0 and k.text_size.height > 0);
    const pane = try paneClient(window, surface);
    const m = KeyState.Metrics.init(Window.dpiOf(window.app, window.hwnd));
    const width = @min(k.text_size.width + 2 * m.pad_x, pane.right - pane.left - 2 * m.margin);
    const height = k.text_size.height + 2 * m.pad_y;
    const left = pane.left + @divTrunc(pane.right - pane.left - width, 2);
    try std.testing.expectEqual(
        win32.RECT{ .left = left, .top = pane.bottom - m.margin - height, .right = left + width, .bottom = pane.bottom - m.margin },
        try childRect(window, hwnd),
    );
    try std.testing.expect(win32.GetWindow(overlayUnder(surface, "key_state"), win32.GW_HWNDPREV) == hwnd);
}

test "win32: key_table and key_sequence show the active tables and pending keys at the terminal's bottom centre" {
    // GTK's key-state overlay: the tables joined with " > ", a chevron,
    // the sequence's keys and an ellipsis for its spinner, at the bottom
    // centre of the terminal, hidden while there is nothing to show. The
    // window is made the first time there is.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    // Not for the app.
    try std.testing.expect(!try app.performAction(.app, .key_table, .{ .activate = "nav" }));
    try std.testing.expect(!try app.performAction(.app, .key_sequence, .end));
    try std.testing.expect(a.overlays.key_state.hwnd == null);

    // A table: its name.
    var buf: [256]u8 = undefined;
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav", try keyStateText(a, &buf));
    const hwnd = a.overlays.key_state.hwnd.?;
    const one = try childRect(window, hwnd);

    // Another on it: both, wider.
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "resize" }));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav > resize", try keyStateText(a, &buf));
    try std.testing.expect((try childRect(window, hwnd)).right > one.right);

    // A sequence's keys after them, as Windows writes shortcuts.
    try std.testing.expect(try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true, .shift = true } } }));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav > resize \u{203A} Ctrl+Shift+A \u{2026}", try keyStateText(a, &buf));
    try std.testing.expect(try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .physical = .arrow_up } } }));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav > resize \u{203A} Ctrl+Shift+A Up \u{2026}", try keyStateText(a, &buf));

    // The sequence ends: the tables again.
    try std.testing.expect(try testKeySequence(&app, a, .end));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav > resize", try keyStateText(a, &buf));

    // One popped: the other stays.
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav", try keyStateText(a, &buf));
    try std.testing.expectEqual(one, try childRect(window, hwnd));

    // The last popped: hidden, its text gone, the window kept; laid out
    // again, still hidden; nothing more to pop changes nothing.
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));
    try std.testing.expect(!shown(hwnd));
    try std.testing.expectEqualStrings("", try keyStateText(a, &buf));
    try std.testing.expect(a.overlays.key_state.hwnd.? == hwnd);
    window.relayout();
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));
    try std.testing.expect(!shown(hwnd));

    // A sequence alone, then ended.
    try std.testing.expect(try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .unicode = 'k' }, .mods = .{ .ctrl = true } } }));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("Ctrl+K \u{2026}", try keyStateText(a, &buf));
    try std.testing.expect(try testKeySequence(&app, a, .end));
    try std.testing.expect(!shown(hwnd));
    try std.testing.expectEqualStrings("", try keyStateText(a, &buf));

    // Every table at once, with a sequence pending: the sequence stays.
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "x" }));
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "y" }));
    try std.testing.expect(try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .unicode = 'k' }, .mods = .{ .ctrl = true } } }));
    try std.testing.expectEqualStrings("x > y \u{203A} Ctrl+K \u{2026}", try keyStateText(a, &buf));
    try std.testing.expect(try testKeyTable(&app, a, .deactivate_all));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("Ctrl+K \u{2026}", try keyStateText(a, &buf));
    try std.testing.expect(try testKeySequence(&app, a, .end));
    try std.testing.expect(!shown(hwnd));

    // The other terminal never had one.
    try std.testing.expect(b.overlays.key_state.hwnd == null);

    // Passive: Windows gives the pointer over it to the window under it.
    try std.testing.expectEqual(win32.HTTRANSPARENT, win32.SendMessageW(hwnd, win32.WM_NCHITTEST, 0, 0));
}

/// For tests: the most key tables the core keeps active, read from its
/// source (`max_active_key_tables` in src/Surface.zig), as the constant is
/// not public; an error if it is not found there.
fn coreMaxKeyTables() !usize {
    const source = @embedFile("../../Surface.zig");
    const decl = "\nconst max_active_key_tables = ";
    const at = std.mem.indexOf(u8, source, decl) orelse return error.TestUnexpectedResult;
    const rest = source[at + decl.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ';') orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(usize, rest[0..end], 10);
}

test "win32: the key state makes no window for nothing pending, and shows as many tables as the core keeps" {
    // The core ends a sequence on almost every bound key, whether one was
    // pending or not, and pops tables that may not be there: none of that
    // makes a window. It keeps at most `max_active_key_tables` active,
    // which the indicator keeps a copy of (`KeyState.max_tables`): all of
    // the core's show, so the core keeping more fails this.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    try std.testing.expect(try testKeySequence(&app, a, .end));
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));
    try std.testing.expect(try testKeyTable(&app, a, .deactivate_all));
    try std.testing.expect(a.overlays.key_state.hwnd == null);

    // The core's most, t1 to tN: all of them, in order.
    const n = try coreMaxKeyTables();
    try std.testing.expect(n > 1);
    var all: std.Io.Writer.Allocating = .init(alloc);
    defer all.deinit();
    var name: [24]u8 = undefined;
    for (1..n + 1) |i| {
        const t = try std.fmt.bufPrint(&name, "t{d}", .{i});
        try std.testing.expect(try testKeyTable(&app, a, .{ .activate = t }));
        if (i > 1) try all.writer.writeAll(" > ");
        try all.writer.writeAll(t);
    }
    try expectKeyStateAt(window, a);
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(all.written(), try keyStateText(a, &buf));
    // One more, which the core never sends: refused, nothing changed.
    try std.testing.expect(!try testKeyTable(&app, a, .{ .activate = "past" }));
    try std.testing.expectEqualStrings(all.written(), try keyStateText(a, &buf));
    // The innermost popped: the others.
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));
    const last = std.mem.lastIndexOf(u8, all.written(), " > ").?;
    try std.testing.expectEqualStrings(all.written()[0..last], try keyStateText(a, &buf));
    // Left active: freed with the terminal (the testing allocator).
}

test "win32: the key state keeps its own copy of a table's name" {
    // The core's name points into its configuration, which a reload
    // frees while the table stays active.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    const name = try alloc.dupe(u8, "nav");
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = name }));
    @memset(name, 'x');
    alloc.free(name);
    // The text is made again from what it kept.
    var buf: [256]u8 = undefined;
    try std.testing.expect(try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } } }));
    try std.testing.expectEqualStrings("nav \u{203A} Ctrl+A \u{2026}", try keyStateText(a, &buf));
    try std.testing.expect(try testKeySequence(&app, a, .end));
    try std.testing.expectEqualStrings("nav", try keyStateText(a, &buf));
}

test "win32: the key state shows above the link preview, and hides with its terminal" {
    // GTK stacks its key-state overlay above its URL labels. Both are the
    // frame's children just above their terminal, which every layout puts
    // back in that order; a zoom or a hidden tab hides the indicator with
    // its terminal, what it shows kept for when it shows again.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    // A long URL, under the indicator's place: the indicator above it,
    // shown after it or before it.
    const url = "https://example.com/some/long/path/that/goes/on/past/the/middle/of/the/terminal";
    try std.testing.expect(try testLink(&app, a, url));
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    const hwnd = a.overlays.key_state.hwnd.?;
    const preview = a.overlays.link_preview.hwnd.?;
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);
    try std.testing.expect(above(window.hwnd, hwnd, preview));
    try std.testing.expect(try testLink(&app, a, ""));
    try expectKeyStateAt(window, a);
    try std.testing.expect(try testLink(&app, a, url));
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);

    // The terminal raised over both: laid out again, both back over it,
    // in their order.
    _ = win32.SetWindowPos(a.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    try std.testing.expect(above(window.hwnd, a.hwnd, hwnd));
    window.relayout();
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);

    // A zoom on the other terminal hides it with its own, its text kept;
    // back, shown. A zoom on its own: the whole window's bottom centre.
    window.toggleZoom(b);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(a.overlays.key_state.text != null);
    window.toggleZoom(b);
    try expectKeyStateAt(window, a);
    window.toggleZoom(a);
    try expectKeyStateAt(window, a);
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    window.toggleZoom(a);
    try expectKeyStateAt(window, a);

    // The other tab shown: hidden with its terminals; shown again with
    // them.
    _ = try testTab(&app, window);
    window.relayout();
    try expectKeyStateAt(window, a);
    window.selectTab(1);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(a.overlays.key_state.text != null);
    window.selectTab(0);
    try expectKeyStateAt(window, a);

    // It goes with its terminal.
    try std.testing.expect(a.destroy());
    try std.testing.expect(!win32.IsWindow(hwnd).toBool());
}

test "win32: the key state moves with its tab to a new window, above its link preview, and follows its scale and font" {
    // A tab moved to a new window takes its terminals' indicators into
    // the new frame, shown or not, each still above its link preview and
    // showing what it did. A change of DPI measures the text again in the
    // font at the new scale; a change of the system's message font makes
    // the font again, and the indicator is placed in it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    _ = try testTab(&app, window);
    window.relayout();

    // a: a table and a key, over a long URL; b: one made, then emptied.
    var buf: [256]u8 = undefined;
    const url = "https://example.com/some/long/path/that/goes/on/past/the/middle/of/the/terminal";
    try std.testing.expect(try testLink(&app, a, url));
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    try std.testing.expect(try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } } }));
    const text = "nav \u{203A} Ctrl+A \u{2026}";
    try std.testing.expectEqualStrings(text, try keyStateText(a, &buf));
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);
    const hwnd = a.overlays.key_state.hwnd.?;
    try std.testing.expect(try testKeyTable(&app, b, .{ .activate = "x" }));
    try std.testing.expect(try testKeyTable(&app, b, .deactivate));
    const hidden = b.overlays.key_state.hwnd.?;
    try std.testing.expect(!shown(hidden));

    // The tab moved to a new window: both go to its frame, a's in its
    // place above its preview, with its text.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = a.window;
    try std.testing.expect(moved != window);
    try std.testing.expect(a.overlays.key_state.hwnd.? == hwnd);
    try expectPreviewAt(moved, a, .left);
    try expectKeyStateAt(moved, a);
    try std.testing.expect(above(moved.hwnd, hwnd, a.overlays.link_preview.hwnd.?));
    try std.testing.expectEqualStrings(text, try keyStateText(a, &buf));
    try std.testing.expect(b.overlays.key_state.hwnd.? == hidden);
    try std.testing.expect(win32.GetAncestor(hidden, win32.GA_PARENT) == moved.hwnd);
    try std.testing.expect(!shown(hidden));
    // And b's shows there when it has something to show.
    try std.testing.expect(try testKeyTable(&app, b, .{ .activate = "y" }));
    try expectKeyStateAt(moved, b);
    try std.testing.expectEqualStrings("y", try keyStateText(b, &buf));

    // A new scale: the text measured in the font at it.
    const before = a.overlays.key_state.text_size;
    try std.testing.expect(a.overlays.font_dpi > 0 and a.overlays.font_dpi < 192);
    const Dpi = struct {
        fn of(_: win32.HWND) callconv(.winapi) win32.UINT {
            return 192;
        }
    };
    app.get_dpi_for_window = &Dpi.of;
    var suggested = try windowRect(moved.hwnd);
    _ = win32.SendMessageW(moved.hwnd, win32.WM_DPICHANGED, 192 << 16 | 192, @bitCast(@intFromPtr(&suggested)));
    try std.testing.expectEqual(192, a.overlays.font_dpi);
    try std.testing.expect(a.overlays.key_state.text_size.height > before.height);
    try std.testing.expect(a.overlays.key_state.text_size.width > before.width);
    try expectKeyStateAt(moved, a);
    try expectKeyStateAt(moved, b);

    // The system's message font changed: made again as they are placed,
    // and they are placed in it.
    const font = a.overlays.font.?;
    _ = win32.SendMessageW(moved.hwnd, win32.WM_SETTINGCHANGE, win32.SPI_SETNONCLIENTMETRICS, 0);
    try std.testing.expect(a.overlays.font.? != font);
    try expectKeyStateAt(moved, a);
}

test "win32: a key state whose window cannot be made returns false, frees its text, and is made at its next change" {
    // CreateWindowExW fails when the process has used up its window
    // handles: the action returns false and the text made for the window
    // is freed (the testing allocator), the tables and keys kept, and the
    // window is made at the next change, showing them all.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    const NoWindow = struct {
        var asked: usize = 0;
        var class: []const u8 = "";
        fn make(c: []const u8) ?win32.HWND {
            asked += 1;
            class = c;
            return null;
        }
    };
    NoWindow.asked = 0;
    Overlays.test_make = &NoWindow.make;
    defer Overlays.test_make = null;

    // A table, then a key: neither shows, each tried again.
    try std.testing.expect(!try testKeyTable(&app, a, .{ .activate = "nav" }));
    try std.testing.expect(a.overlays.key_state.hwnd == null);
    try std.testing.expectEqual(1, NoWindow.asked);
    try std.testing.expectEqualStrings(KeyState.class_name, NoWindow.class);
    try std.testing.expect(!try testKeySequence(&app, a, .{ .trigger = .{ .key = .{ .unicode = 'k' }, .mods = .{ .ctrl = true } } }));
    try std.testing.expect(a.overlays.key_state.hwnd == null);
    try std.testing.expectEqual(2, NoWindow.asked);

    // Windows can be made again: the next change makes it, with all that
    // was kept.
    Overlays.test_make = null;
    var buf: [256]u8 = undefined;
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "resize" }));
    try expectKeyStateAt(window, a);
    try std.testing.expectEqualStrings("nav > resize \u{203A} Ctrl+K \u{2026}", try keyStateText(a, &buf));
    try std.testing.expectEqual(2, NoWindow.asked);
}

/// For tests: the core's `readonly` on `surface`, as its `toggle_readonly`
/// binding performs it once it has flipped its flag.
fn testReadOnly(app: *App, surface: *Surface, value: apprt.action.Readonly) !bool {
    return app.performAction(.{ .surface = &surface.core_surface }, .readonly, value);
}

/// For tests: the text of the window `hwnd`, as UTF-8 in `buf`.
fn windowText(hwnd: win32.HWND, buf: []u8) ![]const u8 {
    var wide: [256]u16 = undefined;
    const n = win32.GetWindowTextW(hwnd, &wide, wide.len);
    const len = try std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]);
    return buf[0..len];
}

/// For tests: `surface`'s read-only badge shows in `window` over its
/// terminal's top-right corner, a margin in from its edges, as big as its
/// text with GTK's padding, just above the terminal, and says "Read-only",
/// which is also its window's text.
fn expectBadgeAt(window: *const Window, surface: *const Surface) !void {
    const b = &surface.overlays.readonly;
    const hwnd = b.hwnd.?;
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(win32.GetAncestor(hwnd, win32.GA_PARENT) == window.hwnd);
    try std.testing.expect(b.text_size.width > 0 and b.text_size.height > 0);
    const pane = try paneClient(window, surface);
    const m = ReadOnly.Metrics.init(Window.dpiOf(window.app, window.hwnd));
    const width = b.text_size.width + 2 * m.pad;
    const height = b.text_size.height + 2 * m.pad;
    try std.testing.expectEqual(
        win32.RECT{ .left = pane.right - m.margin - width, .top = pane.top + m.margin, .right = pane.right - m.margin, .bottom = pane.top + m.margin + height },
        try childRect(window, hwnd),
    );
    try std.testing.expect(win32.GetWindow(surface.hwnd, win32.GW_HWNDPREV) == hwnd);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Read-only", try windowText(hwnd, &buf));
}

/// For tests: what the window `hwnd` draws into a DC for its
/// WM_PRINTCLIENT, kept in a bitmap as big as its client area to read the
/// colours of.
const Printed = struct {
    dc: win32.HDC,
    bitmap: win32.HGDIOBJ,
    old: ?win32.HGDIOBJ,
    width: i32,
    height: i32,

    fn of(hwnd: win32.HWND) !Printed {
        const client = try clientRect(hwnd);
        if (client.right <= 0 or client.bottom <= 0) return error.TestUnexpectedResult;
        const screen = win32.GetDC(null) orelse return error.TestUnexpectedResult;
        defer _ = win32.ReleaseDC(null, screen);
        const dc = win32.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
        errdefer _ = win32.DeleteDC(dc);
        const bitmap = win32.CreateCompatibleBitmap(screen, client.right, client.bottom) orelse return error.TestUnexpectedResult;
        const old = win32.SelectObject(dc, bitmap);
        _ = win32.SendMessageW(hwnd, win32.WM_PRINTCLIENT, @intFromPtr(dc), win32.PRF_CLIENT);
        return .{ .dc = dc, .bitmap = bitmap, .old = old, .width = client.right, .height = client.bottom };
    }

    fn deinit(self: *const Printed) void {
        if (self.old) |o| _ = win32.SelectObject(self.dc, o);
        _ = win32.DeleteObject(self.bitmap);
        _ = win32.DeleteDC(self.dc);
    }

    fn at(self: *const Printed, x: i32, y: i32) win32.COLORREF {
        return win32.GetPixel(self.dc, x, y);
    }

    /// Each of `r`'s pixels is, channel by channel, between `from` and
    /// `to`, as text drawn in `to` over `from` is, smoothed or not, give or
    /// take the rounding of ClearType's gamma (a level was seen); and some
    /// are more than half way to `to`: there is text.
    fn expectBetween(self: *const Printed, r: win32.RECT, from: win32.COLORREF, to: win32.COLORREF) !void {
        var farthest: u32 = 0;
        var y = r.top;
        while (y < r.bottom) : (y += 1) {
            var x = r.left;
            while (x < r.right) : (x += 1) {
                const c = self.at(x, y);
                var d: u32 = 0;
                for (0..3) |i| {
                    const shift: u5 = @intCast(8 * i);
                    const v: i32 = @intCast((c >> shift) & 0xff);
                    const a: i32 = @intCast((from >> shift) & 0xff);
                    const b: i32 = @intCast((to >> shift) & 0xff);
                    const slack = 3;
                    if (v < @min(a, b) - slack or v > @max(a, b) + slack) {
                        std.debug.print("pixel {d},{d} is {x:0>6}, not between {x:0>6} and {x:0>6}\n", .{ x, y, c, from, to });
                        return error.TestUnexpectedResult;
                    }
                    d += @intCast((v - a) * (v - a));
                }
                farthest = @max(farthest, d);
            }
        }
        var whole: u32 = 0;
        for (0..3) |i| {
            const shift: u5 = @intCast(8 * i);
            const a: i32 = @intCast((from >> shift) & 0xff);
            const b: i32 = @intCast((to >> shift) & 0xff);
            whole += @intCast((b - a) * (b - a));
        }
        try std.testing.expect(farthest * 4 > whole);
    }
};

test "win32: readonly shows a read-only badge over its terminal's top-right corner, and hides it" {
    // GTK's badge: "Read-only" over the terminal's top-right corner, a
    // margin in, while the terminal is read-only. The core flips its flag,
    // then performs `readonly` with what it is now. The window is made the
    // first time it shows, and kept when it hides.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    // Not for the app; off with no badge makes none.
    try std.testing.expect(!try app.performAction(.app, .readonly, .on));
    try std.testing.expect(try testReadOnly(&app, a, .off));
    try std.testing.expect(a.overlays.readonly.hwnd == null);
    try std.testing.expect(a.overlays.readonly.text == null);

    // On: shown at the top right of its own terminal, the left one.
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try expectBadgeAt(window, a);
    const hwnd = a.overlays.readonly.hwnd.?;
    const place = try childRect(window, hwnd);
    try std.testing.expect(place.right < (try paneRect(window, b)).left);
    try std.testing.expect(b.overlays.readonly.hwnd == null);

    // The frame resized: with its terminal's top-right corner.
    testResize(window, 1000, 600);
    try expectBadgeAt(window, a);
    try std.testing.expect((try childRect(window, hwnd)).right > place.right);

    // Off: hidden, its text gone, the window kept; laid out again, still
    // hidden; off again changes nothing.
    var buf: [64]u8 = undefined;
    try std.testing.expect(try testReadOnly(&app, a, .off));
    try std.testing.expect(!shown(hwnd));
    try std.testing.expectEqualStrings("", try windowText(hwnd, &buf));
    try std.testing.expect(a.overlays.readonly.hwnd.? == hwnd);
    window.relayout();
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(try testReadOnly(&app, a, .off));
    try std.testing.expect(!shown(hwnd));

    // On again: the same window, shown.
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try expectBadgeAt(window, a);
    try std.testing.expect(a.overlays.readonly.hwnd.? == hwnd);

    // The other terminal's, on its own.
    try std.testing.expect(try testReadOnly(&app, b, .on));
    try expectBadgeAt(window, b);
    try expectBadgeAt(window, a);

    // Passive: Windows gives the pointer over it to the window under it.
    try std.testing.expectEqual(win32.HTTRANSPARENT, win32.SendMessageW(hwnd, win32.WM_NCHITTEST, 0, 0));
}

test "win32: the read-only badge is drawn in GTK's colour, framed in it, on its terminal's background" {
    // GTK's `.readonly_overlay`: its text and outline in hsl(25 50 75),
    // with no background of its own, over the terminal. Here on the
    // configuration's background, light or dark title bar alike, and drawn
    // again when a new configuration changes it, though the title bar
    // stays as it was.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();
    try std.testing.expect(try testReadOnly(&app, a, .on));
    const hwnd = a.overlays.readonly.hwnd.?;
    const pending = struct {
        fn f(h: win32.HWND) bool {
            return win32.GetUpdateRect(h, null, .FALSE).toBool();
        }
    }.f;

    const cases = [_]struct { theme: configpkg.Config.WindowTheme, r: u8, g: u8, b: u8 }{
        .{ .theme = .dark, .r = 0x28, .g = 0x2c, .b = 0x34 },
        .{ .theme = .dark, .r = 0, .g = 0, .b = 0 },
        .{ .theme = .light, .r = 0xff, .g = 0xff, .b = 0xff },
        .{ .theme = .light, .r = 0x28, .g = 0x2c, .b = 0x34 },
    };
    for (cases) |case| {
        _ = win32.UpdateWindow(hwnd);
        try std.testing.expect(!pending(hwnd));
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.@"window-theme" = case.theme;
        changed.background = .{ .r = case.r, .g = case.g, .b = case.b };
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        try std.testing.expectEqual(case.theme == .dark, window.dark_frame);
        try std.testing.expect(pending(hwnd));
        const background = win32.rgb(case.r, case.g, case.b);

        const printed = try Printed.of(hwnd);
        defer printed.deinit();
        // The line around it, at each corner, then inside it.
        const w = printed.width;
        const h = printed.height;
        try std.testing.expectEqual(ReadOnly.color, printed.at(0, 0));
        try std.testing.expectEqual(ReadOnly.color, printed.at(w - 1, h - 1));
        try std.testing.expectEqual(ReadOnly.color, printed.at(w - 1, 0));
        try std.testing.expectEqual(background, printed.at(1, 1));
        try std.testing.expectEqual(background, printed.at(w - 2, h - 2));
        // The text: in GTK's colour, over the background.
        try printed.expectBetween(.{ .left = 1, .top = 1, .right = w - 1, .bottom = h - 1 }, background, ReadOnly.color);
    }
}

test "win32: the read-only badge is under the other overlays and the search bar, and hides with its terminal" {
    // GTK stacks the badge under its URL labels, its search overlay and its
    // key-state overlay. Here the overlays sit just above their terminal
    // in that order, which every layout puts back, and the search bar above
    // all of them, so an open one covers the badge. A zoom or a hidden tab
    // hides it with its terminal, for it to show again with it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    // The others first, then the badge: under both, just above the
    // terminal; and when they show again after it.
    const url = "https://example.com/some/long/path/that/goes/on/past/the/middle/of/the/terminal";
    try std.testing.expect(try testLink(&app, a, url));
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    try std.testing.expect(try testReadOnly(&app, a, .on));
    const hwnd = a.overlays.readonly.hwnd.?;
    const preview = a.overlays.link_preview.hwnd.?;
    const keys = a.overlays.key_state.hwnd.?;
    try expectBadgeAt(window, a);
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);
    try std.testing.expect(win32.GetWindow(hwnd, win32.GW_HWNDPREV) == preview);
    try std.testing.expect(win32.GetWindow(preview, win32.GW_HWNDPREV) == keys);
    try std.testing.expect(try testLink(&app, a, ""));
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));
    try expectBadgeAt(window, a);
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    try std.testing.expect(try testLink(&app, a, url));
    try expectBadgeAt(window, a);
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);

    // The terminal raised over them: laid out again, in their order.
    _ = win32.SetWindowPos(a.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    try std.testing.expect(above(window.hwnd, a.hwnd, hwnd));
    window.relayout();
    try expectBadgeAt(window, a);
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);

    // The terminal's search bar opened over it: above it, also when it is
    // shown again or laid out while the bar is open.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = a.search_bar.hwnd.?;
    try std.testing.expect(shown(bar));
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    try std.testing.expect(try testReadOnly(&app, a, .off));
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try expectBadgeAt(window, a);
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    window.relayout();
    try expectBadgeAt(window, a);
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    app.applyPendingFocus();
    try std.testing.expect(try testLink(&app, a, ""));
    try std.testing.expect(try testKeyTable(&app, a, .deactivate));

    // A zoom on the other terminal hides it with its own, its text kept;
    // back, shown. A zoom on its own: the whole window's top-right corner.
    window.toggleZoom(b);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(a.overlays.readonly.text != null);
    window.toggleZoom(b);
    try expectBadgeAt(window, a);
    window.toggleZoom(a);
    try expectBadgeAt(window, a);
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    window.toggleZoom(a);
    try expectBadgeAt(window, a);

    // The other tab shown: hidden with its terminals; shown again with
    // them.
    _ = try testTab(&app, window);
    window.relayout();
    try expectBadgeAt(window, a);
    window.selectTab(1);
    try std.testing.expect(!shown(hwnd));
    try std.testing.expect(a.overlays.readonly.text != null);
    window.selectTab(0);
    try expectBadgeAt(window, a);

    // It goes with its terminal.
    try std.testing.expect(a.destroy());
    try std.testing.expect(!win32.IsWindow(hwnd).toBool());
}

test "win32: the read-only badge moves with its tab to a new window, and follows its scale and font" {
    // A tab moved to a new window takes its terminals' badges into the new
    // frame, shown or not. A change of DPI measures the text again in the
    // font at the new scale, with GTK's padding and margin at it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    _ = try testTab(&app, window);
    window.relayout();

    // a's shown; b's made, then hidden.
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try expectBadgeAt(window, a);
    const hwnd = a.overlays.readonly.hwnd.?;
    try std.testing.expect(try testReadOnly(&app, b, .on));
    try std.testing.expect(try testReadOnly(&app, b, .off));
    const hidden = b.overlays.readonly.hwnd.?;

    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = a.window;
    try std.testing.expect(moved != window);
    try std.testing.expect(a.overlays.readonly.hwnd.? == hwnd);
    try expectBadgeAt(moved, a);
    try std.testing.expect(win32.GetAncestor(hidden, win32.GA_PARENT) == moved.hwnd);
    try std.testing.expect(!shown(hidden));
    try std.testing.expect(try testReadOnly(&app, b, .on));
    try expectBadgeAt(moved, b);

    // A new scale: the text measured in the font at it.
    const before = a.overlays.readonly.text_size;
    try std.testing.expect(a.overlays.font_dpi > 0 and a.overlays.font_dpi < 192);
    const Dpi = struct {
        fn of(_: win32.HWND) callconv(.winapi) win32.UINT {
            return 192;
        }
    };
    app.get_dpi_for_window = &Dpi.of;
    var suggested = try windowRect(moved.hwnd);
    _ = win32.SendMessageW(moved.hwnd, win32.WM_DPICHANGED, 192 << 16 | 192, @bitCast(@intFromPtr(&suggested)));
    try std.testing.expectEqual(192, a.overlays.font_dpi);
    try std.testing.expect(a.overlays.readonly.text_size.height > before.height);
    try std.testing.expect(a.overlays.readonly.text_size.width > before.width);
    try expectBadgeAt(moved, a);
    try expectBadgeAt(moved, b);
}

test "win32: a read-only badge whose window cannot be made returns false, and is made the next time" {
    // CreateWindowExW fails when the process has used up its window
    // handles: `.on` returns false and makes nothing, `.off` has nothing to
    // hide, and the next `.on` makes it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    const NoWindow = struct {
        var asked: usize = 0;
        var class: []const u8 = "";
        fn make(c: []const u8) ?win32.HWND {
            asked += 1;
            class = c;
            return null;
        }
    };
    NoWindow.asked = 0;
    Overlays.test_make = &NoWindow.make;
    defer Overlays.test_make = null;

    try std.testing.expect(!try testReadOnly(&app, a, .on));
    try std.testing.expect(a.overlays.readonly.hwnd == null);
    try std.testing.expect(a.overlays.readonly.text == null);
    try std.testing.expectEqual(1, NoWindow.asked);
    try std.testing.expectEqualStrings(ReadOnly.class_name, NoWindow.class);
    try std.testing.expect(try testReadOnly(&app, a, .off));
    try std.testing.expectEqual(1, NoWindow.asked);

    Overlays.test_make = null;
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try expectBadgeAt(window, a);
}

/// For tests: the core's `show_child_exited` on `surface`, as its tick
/// performs it once the terminal's command has exited with `code`.
fn testChildExited(app: *App, surface: *Surface, code: u32) !bool {
    return app.performAction(.{ .surface = &surface.core_surface }, .show_child_exited, .{ .exit_code = code, .runtime_ms = 1000 });
}

/// For tests: `surface`'s child-exited banner shows in `window` across its
/// terminal's bottom, as tall as its title or its button with the
/// padding, just above the overlays under it that show, or the terminal,
/// and its window's text is `title`.
fn expectBannerAt(window: *const Window, surface: *const Surface, title: []const u8) !void {
    const c = &surface.overlays.child_exited;
    const hwnd = c.hwnd.?;
    try std.testing.expect(shown(hwnd));
    try std.testing.expect(win32.GetAncestor(hwnd, win32.GA_PARENT) == window.hwnd);
    try std.testing.expect(c.text_size.width > 0 and c.text_size.height > 0);
    try std.testing.expect(c.label_size.width > 0 and c.label_size.height > 0);
    const pane = try paneClient(window, surface);
    const m = ChildExited.Metrics.init(Window.dpiOf(window.app, window.hwnd));
    const button = @max(m.button, c.label_size.height + m.pad);
    const height = @max(button, c.text_size.height) + 2 * m.pad;
    try std.testing.expectEqual(
        win32.RECT{ .left = pane.left, .top = pane.bottom - height, .right = pane.right, .bottom = pane.bottom },
        try childRect(window, hwnd),
    );
    try std.testing.expect(win32.GetWindow(overlayUnder(surface, "child_exited"), win32.GW_HWNDPREV) == hwnd);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(title, try windowText(hwnd, &buf));
}

/// For tests: the Close button of `surface`'s banner, in the banner's
/// client coordinates: as wide as its label with its padding, as tall as
/// the search bar's buttons, `pad` in from the banner's right, centred
/// down it.
fn bannerButton(surface: *const Surface) !win32.RECT {
    const c = &surface.overlays.child_exited;
    const hwnd = c.hwnd.?;
    const client = try clientRect(hwnd);
    const m = ChildExited.Metrics.init(Window.dpiOf(surface.app, hwnd));
    const width = c.label_size.width + 2 * m.button_pad;
    const height = @max(m.button, c.label_size.height + m.pad);
    const top = @divTrunc(client.bottom - height, 2);
    return .{ .left = client.right - m.pad - width, .top = top, .right = client.right - m.pad, .bottom = top + height };
}

/// For tests: what `surface`'s banner answers WM_NCHITTEST for `x`, `y` in
/// its client coordinates, which the message gives on the screen.
fn bannerHit(surface: *const Surface, x: i32, y: i32) !win32.LRESULT {
    const hwnd = surface.overlays.child_exited.hwnd.?;
    var at: win32.POINT = .{ .x = x, .y = y };
    if (!win32.ClientToScreen(hwnd, &at).toBool()) return error.TestUnexpectedResult;
    return win32.SendMessageW(hwnd, win32.WM_NCHITTEST, 0, testPoint(at.x, at.y));
}

/// For tests: `surface`'s banner takes the pointer on each corner and the
/// middle of its button, and gives it to the terminal a pixel past each of
/// the button's edges and over the rest of the banner.
fn expectBannerHits(surface: *const Surface) !void {
    const b = try bannerButton(surface);
    const client = try clientRect(surface.overlays.child_exited.hwnd.?);
    const x = @divTrunc(b.left + b.right, 2);
    const y = @divTrunc(b.top + b.bottom, 2);
    const on = [_][2]i32{ .{ b.left, b.top }, .{ b.right - 1, b.top }, .{ b.left, b.bottom - 1 }, .{ b.right - 1, b.bottom - 1 }, .{ x, y } };
    for (on) |p| try std.testing.expectEqual(@as(win32.LRESULT, win32.HTCLIENT), try bannerHit(surface, p[0], p[1]));
    const off = [_][2]i32{ .{ b.left - 1, y }, .{ b.right, y }, .{ x, b.top - 1 }, .{ x, b.bottom }, .{ @divTrunc(client.right, 2), y }, .{ 0, 0 }, .{ b.left - (b.right - b.left), y } };
    for (off) |p| try std.testing.expectEqual(win32.HTTRANSPARENT, try bannerHit(surface, p[0], p[1]));
}

/// For tests: the left button pressed at `at`, in the client coordinates
/// of `surface`'s banner.
fn bannerDown(surface: *const Surface, at: [2]i32) void {
    _ = win32.SendMessageW(surface.overlays.child_exited.hwnd.?, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(at[0], at[1]));
}

/// For tests: the left button released at `at`, in the client coordinates
/// of `surface`'s banner.
fn bannerUp(surface: *const Surface, at: [2]i32) void {
    _ = win32.SendMessageW(surface.overlays.child_exited.hwnd.?, win32.WM_LBUTTONUP, 0, testPoint(at[0], at[1]));
}

/// For tests: the left button pressed at `down` and released at `up`, in
/// the client coordinates of `surface`'s banner.
fn bannerClick(surface: *const Surface, down: [2]i32, up: [2]i32) void {
    bannerDown(surface, down);
    bannerUp(surface, up);
}

/// For tests: whether `surface`'s banner has the mouse captured.
fn bannerCaptured(surface: *const Surface) bool {
    return win32.GetCapture() == surface.overlays.child_exited.hwnd.?;
}

/// For tests: the middle of `r`.
fn midOf(r: win32.RECT) [2]i32 {
    return .{ @divTrunc(r.left + r.right, 2), @divTrunc(r.top + r.bottom, 2) };
}

/// For tests: whether a teardown is posted to `surface`'s window, which is
/// taken from the queue.
fn takeTeardown(surface: *const Surface) bool {
    var msg: win32.MSG = undefined;
    return win32.PeekMessageW(&msg, surface.hwnd, WM_GHOSTTY_DESTROY, WM_GHOSTTY_DESTROY, win32.PM_REMOVE).toBool();
}

test "win32: show_child_exited shows a banner across the bottom of its terminal, titled by the exit code" {
    // GTK's Adw.Banner: "Command Succeeded" for 0, "Command Failed" for
    // any other code, across the bottom of the terminal. The window is made
    // when the core asks, and its text is the title. At 96 DPI (the move
    // test has 192).
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    const Dpi = struct {
        fn of(_: win32.HWND) callconv(.winapi) win32.UINT {
            return 96;
        }
    };
    app.get_dpi_for_window = &Dpi.of;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    // Not for the app.
    try std.testing.expect(!try app.performAction(.app, .show_child_exited, .{ .exit_code = 0, .runtime_ms = 1000 }));
    try std.testing.expect(a.overlays.child_exited.hwnd == null);

    try std.testing.expect(try testChildExited(&app, a, 0));
    try expectBannerAt(window, a, "Command Succeeded");
    try std.testing.expect(!a.overlays.child_exited.failed);
    try std.testing.expect(b.overlays.child_exited.hwnd == null);
    const hwnd = a.overlays.child_exited.hwnd.?;
    try std.testing.expect((try childRect(window, hwnd)).right <= (try paneRect(window, b)).left);

    try std.testing.expect(try testChildExited(&app, b, 3));
    try expectBannerAt(window, b, "Command Failed");
    try std.testing.expect(b.overlays.child_exited.failed);

    // The frame resized: with its terminal's bottom, as wide as it.
    const was = try childRect(window, hwnd);
    testResize(window, 1000, 600);
    try expectBannerAt(window, a, "Command Succeeded");
    try std.testing.expect((try childRect(window, hwnd)).bottom > was.bottom);
    try std.testing.expect((try childRect(window, hwnd)).right > was.right);

    // A click on it never activates the frame or moves the focus.
    try std.testing.expectEqual(win32.MA_NOACTIVATE, win32.SendMessageW(hwnd, win32.WM_MOUSEACTIVATE, @intFromPtr(window.hwnd), win32.HTCLIENT | (@as(win32.LPARAM, win32.WM_LBUTTONDOWN) << 16)));

    // Its button takes the pointer, the rest of it is the terminal's.
    try expectBannerHits(a);
    try expectBannerHits(b);
}

test "win32: the child-exited banner is between the read-only badge and the link preview, under the search bar, and hides with its terminal" {
    // GTK stacks its banner over the read-only badge and under its URL
    // labels, its search overlay and its key-state overlay.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    Window.test_get_focus = &FocusSeen.current;
    defer Window.test_get_focus = null;
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    window.relayout();

    // The others first, then the banner: over the badge, under the rest.
    const url = "https://example.com/some/long/path/that/goes/on/past/the/middle/of/the/terminal";
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try std.testing.expect(try testLink(&app, a, url));
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    try std.testing.expect(try testChildExited(&app, a, 3));
    const hwnd = a.overlays.child_exited.hwnd.?;
    const badge = a.overlays.readonly.hwnd.?;
    const preview = a.overlays.link_preview.hwnd.?;
    try expectBadgeAt(window, a);
    try expectBannerAt(window, a, "Command Failed");
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);
    try std.testing.expect(win32.GetWindow(badge, win32.GW_HWNDPREV) == hwnd);
    try std.testing.expect(win32.GetWindow(hwnd, win32.GW_HWNDPREV) == preview);
    // The badge gone and back, then the terminal raised: in order again.
    try std.testing.expect(try testReadOnly(&app, a, .off));
    try expectBannerAt(window, a, "Command Failed");
    try std.testing.expect(try testReadOnly(&app, a, .on));
    try expectBadgeAt(window, a);
    try expectBannerAt(window, a, "Command Failed");
    _ = win32.SetWindowPos(a.hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    window.relayout();
    try expectBadgeAt(window, a);
    try expectBannerAt(window, a, "Command Failed");
    try expectPreviewAt(window, a, .left);
    try expectKeyStateAt(window, a);

    // Under an open search bar.
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    app.applyPendingFocus();
    const bar = a.search_bar.hwnd.?;
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    window.relayout();
    try std.testing.expect(above(window.hwnd, bar, hwnd));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .end_search, {}));
    app.applyPendingFocus();

    // A zoom on the other terminal hides it with its own; back, shown. A
    // zoom on its own: across the whole window's bottom.
    window.toggleZoom(b);
    try std.testing.expect(!shown(hwnd));
    window.toggleZoom(b);
    try expectBannerAt(window, a, "Command Failed");
    window.toggleZoom(a);
    try expectBannerAt(window, a, "Command Failed");
    try std.testing.expectEqual(try clientRect(window.hwnd), try paneRect(window, a));
    window.toggleZoom(a);
    try expectBannerAt(window, a, "Command Failed");

    // The other tab shown: hidden with its terminals; shown again.
    _ = try testTab(&app, window);
    window.relayout();
    window.selectTab(1);
    try std.testing.expect(!shown(hwnd));
    window.selectTab(0);
    try expectBannerAt(window, a, "Command Failed");

    // It goes with its terminal.
    try std.testing.expect(a.destroy());
    try std.testing.expect(!win32.IsWindow(hwnd).toBool());
}

test "win32: a click on the child-exited banner's Close closes its terminal, at once or after the core's frame" {
    // A press and a release on the button close the terminal as its own
    // WM_CLOSE does (`Surface.requestClose`): with no core here, it is
    // marked closing and its teardown posted. Under a core frame or a
    // prompt the close is recorded for `run`, which a terminal closing
    // meanwhile takes back (`App.forgetClosing`). A press on the button
    // takes the mouse, so that its release comes to the banner wherever
    // it is, and its release, or a later press the capture brings off the
    // button, lets go of it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 1200, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b, c });
    window.tab().focused = a;
    window.relayout();
    for ([_]*Surface{ a, b, c }) |s| try std.testing.expect(try testChildExited(&app, s, 0));

    // Clicks that are not on the button close nothing: a release off it,
    // a press off it, a press whose capture was taken, a release alone,
    // and a release on it after a press off it that came, by the capture,
    // after a press on it whose release never did.
    const button = try bannerButton(b);
    const on = midOf(button);
    const beside: [2]i32 = .{ button.left - 1, on[1] };
    bannerDown(b, on);
    try std.testing.expect(bannerCaptured(b));
    bannerUp(b, beside);
    try std.testing.expect(!bannerCaptured(b));
    bannerDown(b, beside);
    try std.testing.expect(!bannerCaptured(b));
    bannerUp(b, on);
    bannerDown(b, on);
    _ = win32.SendMessageW(b.overlays.child_exited.hwnd.?, win32.WM_CAPTURECHANGED, 0, 0);
    bannerUp(b, on);
    try std.testing.expect(!bannerCaptured(b));
    bannerUp(b, on);
    bannerDown(b, on);
    bannerDown(b, beside);
    try std.testing.expect(!bannerCaptured(b));
    bannerUp(b, on);
    try std.testing.expect(!b.closing);
    try std.testing.expect(!takeTeardown(b));
    try std.testing.expectEqual(0, app.requests.items.len);

    // On the button: a closes at once, and lets go of the mouse.
    const on_a = midOf(try bannerButton(a));
    bannerDown(a, on_a);
    try std.testing.expect(bannerCaptured(a));
    bannerUp(a, on_a);
    try std.testing.expect(!bannerCaptured(a));
    try std.testing.expect(a.closing);
    try std.testing.expect(takeTeardown(a));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Under a tick with no memory to record the close: logged, and
    // nothing closes.
    app.ticking = true;
    var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    core_app.alloc = failing.allocator();
    bannerClick(b, on, on);
    core_app.alloc = alloc;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!bannerCaptured(b));
    try std.testing.expect(!b.closing);
    try std.testing.expect(!takeTeardown(b));
    try std.testing.expectEqual(0, app.requests.items.len);

    // Under a tick: recorded, then carried out by `run`.
    bannerClick(b, on, on);
    try std.testing.expect(!bannerCaptured(b));
    try std.testing.expect(!b.closing);
    try std.testing.expect(!takeTeardown(b));
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .close_surface);
    try std.testing.expect(app.requests.items[0].close_surface == &b.core_surface);
    app.ticking = false;
    app.createRequested();
    try std.testing.expect(b.closing);
    try std.testing.expect(takeTeardown(b));

    // Under a prompt: recorded; the terminal begins to close otherwise
    // first, and the record is dropped.
    app.prompt_depth = 1;
    bannerClick(c, midOf(try bannerButton(c)), midOf(try bannerButton(c)));
    app.prompt_depth = 0;
    try std.testing.expect(!c.closing);
    try std.testing.expectEqual(1, app.requests.items.len);
    app.forgetClosing(&c.core_surface);
    try std.testing.expect(app.requests.items[0] == .dropped);
    app.createRequested();
    try std.testing.expect(!c.closing);
    try std.testing.expect(!takeTeardown(c));
}

test "win32: the child-exited banner is drawn in libadwaita's colours, its button's face the bar's hover colour under the pointer and its border colour while pressed" {
    // GTK tints its banner with libadwaita's success or error colour at
    // 50%; here mixed half and half with the search bar's, light or dark
    // with the title bar, the title and the button in the bar's colours.
    // The first move over it asks for the pointer's leave; hidden, it lets
    // go of the pointer and of a press.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    for ([_]configpkg.Config.WindowTheme{ .dark, .light }) |theme| {
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.@"window-theme" = theme;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        try std.testing.expectEqual(theme == .dark, window.dark_frame);
        const colors = SearchBar.Colors.of(window.dark_frame);
        for ([_]u32{ 0, 3 }) |code| {
            try std.testing.expect(try testChildExited(&app, a, code));
            const hwnd = a.overlays.child_exited.hwnd.?;
            const button = try bannerButton(a);
            const line = @max(1, SearchBar.Metrics.scale(1, Window.dpiOf(&app, hwnd)));
            const face = SearchBar.inset(button, line);
            const printed = try Printed.of(hwnd);
            defer printed.deinit();
            // The tint; the title over it, left of the button.
            const tint = ChildExited.tint(code != 0, theme == .dark);
            try std.testing.expectEqual(tint, printed.at(0, 0));
            try std.testing.expectEqual(tint, printed.at(printed.width - 1, printed.height - 1));
            try printed.expectBetween(.{ .left = 0, .top = 0, .right = button.left, .bottom = printed.height }, tint, colors.text);
            // The button: framed, its label on the bar's colour.
            try std.testing.expectEqual(colors.border, printed.at(button.left, button.top));
            try std.testing.expectEqual(colors.border, printed.at(button.right - 1, button.bottom - 1));
            try std.testing.expectEqual(colors.bar, printed.at(face.left, face.top));
            try printed.expectBetween(face, colors.bar, colors.text);
        }

        // The hover colour under the pointer, the border colour while
        // pressed, back once the capture goes and the pointer leaves.
        const hwnd = a.overlays.child_exited.hwnd.?;
        const button = try bannerButton(a);
        const line = @max(1, SearchBar.Metrics.scale(1, Window.dpiOf(&app, hwnd)));
        const face = SearchBar.inset(button, line);
        const at = midOf(button);
        var leave: win32.MSG = undefined;
        while (win32.PeekMessageW(&leave, hwnd, win32.WM_MOUSELEAVE, win32.WM_MOUSELEAVE, win32.PM_REMOVE).toBool()) {}
        const states = [_]struct { msg: win32.UINT, x: i32, face: win32.COLORREF }{
            .{ .msg = win32.WM_MOUSEMOVE, .x = at[0], .face = colors.hover },
            .{ .msg = win32.WM_LBUTTONDOWN, .x = at[0], .face = colors.border },
            .{ .msg = win32.WM_CAPTURECHANGED, .x = at[0], .face = colors.hover },
            .{ .msg = win32.WM_MOUSEMOVE, .x = button.left - 1, .face = colors.bar },
            .{ .msg = win32.WM_MOUSEMOVE, .x = at[0], .face = colors.hover },
            .{ .msg = win32.WM_MOUSELEAVE, .x = at[0], .face = colors.bar },
        };
        for (states, 0..) |state, i| {
            _ = win32.SendMessageW(hwnd, state.msg, if (state.msg == win32.WM_LBUTTONDOWN) win32.MK_LBUTTON else 0, testPoint(state.x, at[1]));
            const printed = try Printed.of(hwnd);
            defer printed.deinit();
            try std.testing.expectEqual(state.face, printed.at(face.left, face.top));
            if (i == 0) try expectLeaveTracked(hwnd);
        }
        // The press's capture, which no release took.
        if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
        try std.testing.expect(!a.closing);
    }

    // Hidden while lit, or while pressed with the mouse captured: shown
    // again with neither, the mouse let go, and a release on the button
    // closes nothing. Hidden for want of room, then with its tab.
    const hwnd = a.overlays.child_exited.hwnd.?;
    const colors = SearchBar.Colors.of(window.dark_frame);
    const button = try bannerButton(a);
    const face = SearchBar.inset(button, @max(1, SearchBar.Metrics.scale(1, Window.dpiOf(&app, hwnd))));
    const at = midOf(button);
    _ = try testTab(&app, window);
    const hides = [_]enum { no_room, tab }{ .no_room, .tab };
    for (hides) |how| {
        for ([_]bool{ false, true }) |press| {
            _ = win32.SendMessageW(hwnd, win32.WM_MOUSEMOVE, 0, testPoint(at[0], at[1]));
            if (press) {
                bannerDown(a, at);
                try std.testing.expect(bannerCaptured(a));
            }
            switch (how) {
                .no_room => testResize(window, 900, 20),
                .tab => window.selectTab(1),
            }
            try std.testing.expect(!shown(hwnd));
            try std.testing.expect(!bannerCaptured(a));
            switch (how) {
                .no_room => testResize(window, 900, 500),
                .tab => window.selectTab(0),
            }
            try std.testing.expect(shown(hwnd));
            const printed = try Printed.of(hwnd);
            defer printed.deinit();
            try std.testing.expectEqual(colors.bar, printed.at(face.left, face.top));
            bannerUp(a, at);
            try std.testing.expect(!a.closing);
        }
    }
}

/// For tests: the pointer's leave from `hwnd` is asked for
/// (TrackMouseEvent): tracked now, or its WM_MOUSELEAVE posted already,
/// which is taken, as Windows posts it at once to a window the pointer is
/// not over.
fn expectLeaveTracked(hwnd: win32.HWND) !void {
    var query: win32.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(win32.TRACKMOUSEEVENT), .dwFlags = win32.TME_QUERY, .hwndTrack = null, .dwHoverTime = 0 };
    try std.testing.expect(win32.TrackMouseEvent(&query).toBool());
    if (query.dwFlags & win32.TME_LEAVE != 0 and query.hwndTrack == hwnd) return;
    var leave: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(&leave, hwnd, win32.WM_MOUSELEAVE, win32.WM_MOUSELEAVE, win32.PM_REMOVE).toBool());
}

test "win32: the child-exited banner moves with its tab to a new window, and its button follows its scale" {
    // A tab moved to a new window takes the banner into the new frame. A
    // change of DPI measures its title and label again in the font at the
    // new scale, and lays the banner and its button out at it, where the
    // button still takes the pointer and closes the terminal.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    _ = try testTab(&app, window);
    window.relayout();

    try std.testing.expect(try testChildExited(&app, a, 0));
    try std.testing.expect(try testChildExited(&app, b, 3));
    const hwnd = a.overlays.child_exited.hwnd.?;
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .move_tab_to_new_window, {}));
    app.createRequested();
    try std.testing.expectEqual(2, app.windows.items.len);
    const moved = a.window;
    try std.testing.expect(moved != window);
    try std.testing.expect(a.overlays.child_exited.hwnd.? == hwnd);
    try expectBannerAt(moved, a, "Command Succeeded");
    try expectBannerAt(moved, b, "Command Failed");
    try expectBannerHits(a);

    // A new scale: measured again, laid out at it.
    const before = a.overlays.child_exited;
    const Dpi = struct {
        fn of(_: win32.HWND) callconv(.winapi) win32.UINT {
            return 192;
        }
    };
    app.get_dpi_for_window = &Dpi.of;
    var suggested = try windowRect(moved.hwnd);
    _ = win32.SendMessageW(moved.hwnd, win32.WM_DPICHANGED, 192 << 16 | 192, @bitCast(@intFromPtr(&suggested)));
    try std.testing.expectEqual(192, a.overlays.font_dpi);
    try std.testing.expect(a.overlays.child_exited.text_size.height > before.text_size.height);
    try std.testing.expect(a.overlays.child_exited.label_size.width > before.label_size.width);
    try expectBannerAt(moved, a, "Command Succeeded");
    try expectBannerAt(moved, b, "Command Failed");
    const button = try bannerButton(a);
    try std.testing.expectEqual(ChildExited.Metrics.init(192).button, button.bottom - button.top);
    try expectBannerHits(a);
    try expectBannerHits(b);

    // And its button closes the terminal there.
    bannerClick(b, midOf(try bannerButton(b)), midOf(try bannerButton(b)));
    try std.testing.expect(b.closing);
    try std.testing.expect(takeTeardown(b));
    try std.testing.expect(!a.closing);
}

test "win32: a child-exited banner whose window cannot be made returns false, for the core's own text" {
    // CreateWindowExW fails when the process has used up its window
    // handles: the action returns false, so that the core writes its text
    // into the terminal, and nothing is made or kept.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{a});
    window.tab().focused = a;
    window.relayout();

    const NoWindow = struct {
        var asked: usize = 0;
        var class: []const u8 = "";
        fn make(c: []const u8) ?win32.HWND {
            asked += 1;
            class = c;
            return null;
        }
    };
    NoWindow.asked = 0;
    Overlays.test_make = &NoWindow.make;
    defer Overlays.test_make = null;

    try std.testing.expect(!try testChildExited(&app, a, 3));
    try std.testing.expect(a.overlays.child_exited.hwnd == null);
    try std.testing.expect(a.overlays.child_exited.text == null);
    try std.testing.expectEqual(1, NoWindow.asked);
    try std.testing.expectEqualStrings(ChildExited.class_name, NoWindow.class);

    Overlays.test_make = null;
    try std.testing.expect(try testChildExited(&app, a, 3));
    try expectBannerAt(window, a, "Command Failed");
}

/// For tests: the last prompt `dialog.messageBox` would have shown, and
/// how many it would have, each answered with `answer`
/// (`dialog.test_message_box`).
const PromptSeen = struct {
    var text: [128]u16 = undefined;
    var len: usize = 0;
    var count: usize = 0;
    var answer: c_int = win32.IDCANCEL;

    fn seen(owner: ?win32.HWND, prompt: win32.LPCWSTR, buttons: win32.UINT) c_int {
        _ = owner;
        _ = buttons;
        const said = std.mem.span(prompt);
        len = @min(said.len, text.len);
        @memcpy(text[0..len], said[0..len]);
        count += 1;
        return answer;
    }

    fn expectSaid(said: []const u8) !void {
        var buf: [256]u8 = undefined;
        const n = try std.unicode.utf16LeToUtf8(&buf, text[0..len]);
        try std.testing.expectEqualStrings(said, buf[0..n]);
    }
};

test "win32: a read-only terminal whose command has exited asks to close as read-only, any other as running a process" {
    // The core asks before a read-only terminal closes even once its
    // command has exited (`CoreSurface.needsConfirmQuit`), when read-only
    // is the only reason: the prompt says so. While the command runs, read
    // only or not, it says a process is running. The runtime knows both
    // from the core's actions, also when the windows for them cannot be
    // made. Cancel keeps the terminal; OK closes it.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    const message_box = &@import("dialog.zig").test_message_box;
    message_box.* = &PromptSeen.seen;
    defer message_box.* = null;

    const window = try testFrame(&app);
    testResize(window, 900, 500);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    const running = "A process is still running in this terminal. Close it anyway?";
    const read_only = "This terminal is read-only. Close it anyway?";
    PromptSeen.answer = win32.IDCANCEL;

    // The command running, read-only or not.
    for ([_]apprt.action.Readonly{ .off, .on }) |value| {
        try std.testing.expect(try testReadOnly(&app, a, value));
        PromptSeen.count = 0;
        a.close(true);
        try std.testing.expectEqual(1, PromptSeen.count);
        try PromptSeen.expectSaid(running);
        try std.testing.expect(!a.closing);
        try std.testing.expect(!takeTeardown(a));
    }

    // The command exited: read-only is the reason; not read-only any more,
    // as for any other.
    try std.testing.expect(try testChildExited(&app, a, 0));
    a.close(true);
    try PromptSeen.expectSaid(read_only);
    try std.testing.expect(!a.closing);
    try std.testing.expect(try testReadOnly(&app, a, .off));
    a.close(true);
    try PromptSeen.expectSaid(running);

    // Read-only again, and OK: it closes.
    try std.testing.expect(try testReadOnly(&app, a, .on));
    PromptSeen.answer = win32.IDOK;
    defer PromptSeen.answer = win32.IDCANCEL;
    a.close(true);
    try PromptSeen.expectSaid(read_only);
    try std.testing.expect(a.closing);
    try std.testing.expect(takeTeardown(a));
    PromptSeen.answer = win32.IDCANCEL;

    // Neither the badge nor the banner could be made: the same.
    const NoWindow = struct {
        fn make(_: []const u8) ?win32.HWND {
            return null;
        }
    };
    Overlays.test_make = &NoWindow.make;
    defer Overlays.test_make = null;
    try std.testing.expect(!try testReadOnly(&app, b, .on));
    try std.testing.expect(!try testChildExited(&app, b, 1));
    try std.testing.expect(b.overlays.readonly.hwnd == null);
    try std.testing.expect(b.overlays.child_exited.hwnd == null);
    b.close(true);
    try PromptSeen.expectSaid(read_only);
    try std.testing.expect(!b.closing);
}

/// For tests: the core's answers to a terminal's buttons
/// (`Surface.test_mouse_button`): `right_press` to a right press,
/// `release` to a right release, consumed to the others; null for one
/// that does not reach it. The terminal keeps the buttons held and the
/// capture as `mouseButton` does: it takes the capture with the first
/// button pressed, drops a release whose press it did not keep, and lets
/// go of the capture when the last button comes up, before the core has
/// the release.
const MenuCore = struct {
    var right_press: ?bool = false;
    var release: ?bool = true;
    var calls: usize = 0;
    fn answer(surface: *Surface, button: Surface.Mouse.Button, state: input.MouseButtonState) ?bool {
        calls += 1;
        const m = &surface.mouse;
        switch (state) {
            .press => {
                if (m.held.count() == 0) _ = win32.SetCapture(surface.hwnd);
                m.held.insert(button);
            },
            .release => {
                if (!m.held.contains(button)) return null;
                m.held.remove(button);
                if (m.held.count() == 0) _ = win32.ReleaseCapture();
            },
        }
        if (button != .right) return true;
        return switch (state) {
            .press => right_press,
            .release => release,
        };
    }
    fn reset() void {
        right_press = false;
        release = true;
        calls = 0;
    }
};

/// For tests: the context menus shown (`ContextMenu.test_track`), and the
/// item to choose in each, by its label, or none.
const MenuSeen = struct {
    var count: usize = 0;
    var owner: ?win32.HWND = null;
    var at: win32.POINT = .{ .x = 0, .y = 0 };
    /// Who had the mouse capture as the menu opened.
    var capture: ?win32.HWND = null;
    var choose: ?[]const u8 = null;
    /// Run while the menu is open, as what its loop dispatches.
    var during: ?*const fn () void = null;
    fn track(menu: win32.HMENU, o: win32.HWND, pt: win32.POINT) u32 {
        count += 1;
        owner = o;
        at = pt;
        capture = win32.GetCapture();
        if (during) |f| f();
        const label = choose orelse return 0;
        return menuIdOf(menu, label) orelse 0;
    }
    fn reset() void {
        count = 0;
        owner = null;
        choose = null;
        during = null;
    }
};

/// For tests: the id of the item of `menu`, or of one of its submenus,
/// whose text before its shortcut is `label`.
fn menuIdOf(menu: win32.HMENU, label: []const u8) ?u32 {
    var pos: c_int = 0;
    while (pos < win32.GetMenuItemCount(menu)) : (pos += 1) {
        if (win32.GetSubMenu(menu, pos)) |sub| {
            if (menuIdOf(sub, label)) |id| return id;
            continue;
        }
        var wide: [256]u16 = undefined;
        const n = win32.GetMenuStringW(menu, @intCast(pos), &wide, wide.len, win32.MF_BYPOSITION);
        const text = wide[0..@intCast(@max(n, 0))];
        const tab = std.mem.indexOfScalar(u16, text, '\t') orelse text.len;
        var utf8: [256]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8, text[0..tab]) catch continue;
        if (std.mem.eql(u8, utf8[0..len], label)) return win32.GetMenuItemID(menu, pos);
    }
    return null;
}

/// For tests: a right button message to `pane` at the point `x`, `y` of
/// its client area, the button down for a press.
fn testRight(pane: *const Surface, msg: win32.UINT, x: i32, y: i32) void {
    const down: win32.WPARAM = if (msg == win32.WM_RBUTTONDOWN) win32.MK_RBUTTON else 0;
    _ = win32.SendMessageW(pane.hwnd, msg, down, testPoint(x, y));
}

/// For tests: a right click on `pane` at `x`, `y`, pressed and released.
fn testRightClick(pane: *const Surface, x: i32, y: i32) void {
    testRight(pane, win32.WM_RBUTTONDOWN, x, y);
    testRight(pane, win32.WM_RBUTTONUP, x, y);
}

test "win32: a right press the core leaves to the context menu shows it on its release, owned by the frame" {
    // The core's answer to a right press waits for that button's release
    // (`Surface.Mouse.menu`): false, "show your context menu", shows the
    // menu there, once, at the release's point, owned by the frame, so
    // that its loop is the frame's (WM_ENTERMENULOOP), and the terminal
    // has the focus back after it. A consumed press, a release with no
    // press, one the core did not get, one after the capture went, one
    // with another button still down, one outside the terminal and a
    // press the core never got (no core) show none; neither does a menu
    // Windows cannot make.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    ContextMenu.test_track = &MenuSeen.track;
    defer ContextMenu.test_track = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    MenuSeen.reset();
    MenuCore.reset();
    PaletteSeen.reset(null);
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.relayout();
    const client = try clientRect(a.hwnd);
    // Shown, so that it can hold the capture.
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    defer _ = win32.ReleaseCapture();

    // No core: neither the press nor the release reaches one, and the
    // WM_CONTEXTMENU DefWindowProcW makes of the release shows nothing.
    testRightClick(a, 20, 30);
    try std.testing.expectEqual(0, MenuSeen.count);
    // A press from before the core, released once there is one.
    testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
    Surface.test_mouse_button = &MenuCore.answer;
    defer Surface.test_mouse_button = null;
    testRight(a, win32.WM_RBUTTONUP, 20, 30);
    try std.testing.expectEqual(1, MenuCore.calls);
    try std.testing.expectEqual(0, MenuSeen.count);

    // Left to the menu: nothing on the press; on the release, the menu at
    // its point on the screen, owned by the frame; then the focus back on
    // the terminal, nothing chosen.
    testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
    try std.testing.expectEqual(0, MenuSeen.count);
    testRight(a, win32.WM_RBUTTONUP, 25, 35);
    try std.testing.expectEqual(1, MenuSeen.count);
    try std.testing.expect(MenuSeen.owner == window.hwnd);
    try std.testing.expect(MenuSeen.capture == null);
    var pt: win32.POINT = .{ .x = 25, .y = 35 };
    try std.testing.expect(win32.ClientToScreen(a.hwnd, &pt).toBool());
    try std.testing.expectEqual(pt, MenuSeen.at);
    try std.testing.expect(FocusSeen.last == a.hwnd);
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    try std.testing.expectEqual(0, app.terminal_loops);
    // Once: another release with no press shows none.
    testRight(a, win32.WM_RBUTTONUP, 25, 35);
    try std.testing.expectEqual(1, MenuSeen.count);

    // Consumed, as by a program with mouse reporting.
    MenuCore.right_press = true;
    testRightClick(a, 20, 30);
    try std.testing.expectEqual(1, MenuSeen.count);
    MenuCore.right_press = false;
    // Its release did not reach the core.
    MenuCore.release = null;
    testRightClick(a, 20, 30);
    try std.testing.expectEqual(1, MenuSeen.count);
    MenuCore.release = true;
    // A press the core never got leaves nothing waiting from an earlier
    // one.
    testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
    MenuCore.right_press = null;
    testRightClick(a, 20, 30);
    try std.testing.expectEqual(1, MenuSeen.count);
    MenuCore.right_press = false;
    // The capture went to another window before the release.
    testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
    try std.testing.expect(win32.GetCapture() == a.hwnd);
    _ = win32.SetCapture(window.hwnd);
    testRight(a, win32.WM_RBUTTONUP, 20, 30);
    _ = win32.ReleaseCapture();
    try std.testing.expectEqual(1, MenuSeen.count);
    // Released with the left button still down, which keeps the capture;
    // nor does the left one's release show it.
    _ = win32.SendMessageW(a.hwnd, win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, testPoint(20, 30));
    testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
    testRight(a, win32.WM_RBUTTONUP, 20, 30);
    try std.testing.expect(win32.GetCapture() == a.hwnd);
    _ = win32.SendMessageW(a.hwnd, win32.WM_LBUTTONUP, 0, testPoint(20, 30));
    try std.testing.expect(win32.GetCapture() == null);
    try std.testing.expectEqual(1, MenuSeen.count);
    // Released outside the terminal, which holds the capture.
    for ([_][2]i32{ .{ -1, 30 }, .{ client.right, 30 }, .{ 20, -1 }, .{ 20, client.bottom } }) |out| {
        testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
        testRight(a, win32.WM_RBUTTONUP, out[0], out[1]);
    }
    try std.testing.expectEqual(1, MenuSeen.count);
    // Inside, at its last pixel.
    testRight(a, win32.WM_RBUTTONDOWN, 20, 30);
    testRight(a, win32.WM_RBUTTONUP, client.right - 1, client.bottom - 1);
    try std.testing.expectEqual(2, MenuSeen.count);

    // Windows cannot make the menu: none shows, and no loop stays
    // counted.
    ContextMenu.test_calls_left = 0;
    defer ContextMenu.test_calls_left = null;
    testRightClick(a, 20, 30);
    ContextMenu.test_calls_left = null;
    try std.testing.expectEqual(2, MenuSeen.count);
    try std.testing.expectEqual(0, app.terminal_loops);
    testRightClick(a, 20, 30);
    try std.testing.expectEqual(3, MenuSeen.count);
}

test "win32: the context menu's choice is performed on its terminal" {
    // As the command palette performs an entry (`CommandPalette.perform`):
    // on the terminal clicked, with the focus back on it first. A greyed
    // item is not performed, nor is anything when the menu is dismissed.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    ContextMenu.test_track = &MenuSeen.track;
    defer ContextMenu.test_track = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    Surface.test_mouse_button = &MenuCore.answer;
    defer Surface.test_mouse_button = null;
    MenuSeen.reset();
    defer MenuSeen.reset();
    MenuCore.reset();
    PaletteSeen.reset(null);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();

    // Each item by its label, as the menu shows it, and the action it
    // performs, written out by hand. Copy is greyed: a terminal with no
    // core has no selection.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Copy", "" },
        .{ "Paste", "paste_from_clipboard;" },
        .{ "Clear", "clear_screen;" },
        .{ "Reset", "reset;" },
        .{ "Read-only", "toggle_readonly;" },
        .{ "Change Title\u{2026}", "prompt_surface_title;" },
        .{ "Split Up", "new_split:up;" },
        .{ "Split Down", "new_split:down;" },
        .{ "Split Left", "new_split:left;" },
        .{ "Split Right", "new_split:right;" },
        .{ "Close Split", "close_surface;" },
        .{ "Change Tab Title\u{2026}", "prompt_tab_title;" },
        .{ "New Tab", "new_tab;" },
        .{ "Close Tab", "close_tab:this;" },
        .{ "New Window", "new_window;" },
        .{ "Close Window", "close_window;" },
        .{ "Open Configuration in OS Editor", "open_config:os_open;" },
        .{ "Reload Configuration", "reload_config;" },
    };
    for (cases) |c| {
        MenuSeen.choose = c[0];
        FocusSeen.last = null;
        PaletteSeen.on = null;
        testRightClick(b, 20, 30);
        try std.testing.expectEqualStrings(c[1], PaletteSeen.take());
        if (c[1].len > 0) try std.testing.expect(PaletteSeen.on == b);
        try std.testing.expect(FocusSeen.last == b.hwnd);
    }
    try std.testing.expectEqual(cases.len, MenuSeen.count);

    // Dismissed: nothing, the focus back all the same.
    MenuSeen.choose = null;
    FocusSeen.last = null;
    testRightClick(b, 20, 30);
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    try std.testing.expect(FocusSeen.last == b.hwnd);
}

test "win32: the context menu gives the focus back to its terminal, not to an open command palette" {
    // The menu opens only on the terminal with the focus (a click that
    // moves the focus there is eaten, WM_MOUSEACTIVATE), and an open
    // command palette stays open when a terminal of its frame takes the
    // focus. When the menu closes, chosen or not, that terminal gets the
    // focus back, as GTK's popover gives it to its surface; not the
    // palette's field, which the window's focus goes to while it is open
    // (`Window.focusTarget`) and which would take the keys typed for the
    // shell.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    ContextMenu.test_track = &MenuSeen.track;
    defer ContextMenu.test_track = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    Surface.test_mouse_button = &MenuCore.answer;
    defer Surface.test_mouse_button = null;
    MenuSeen.reset();
    defer MenuSeen.reset();
    MenuCore.reset();
    PaletteSeen.reset(null);
    FocusSeen.last = null;

    const window = try testFrame(&app);
    testResize(window, 1000, 700);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    const p = &window.palette;

    // Opened on a, its field with the focus; then b takes the focus, as
    // the SetFocus of a click on it gives it (WM_SETFOCUS): the palette
    // stays open, now on b, and the window's focus still goes to its field.
    try togglePalette(&app, a);
    const edit = p.edit.?;
    try std.testing.expect(FocusSeen.last == edit);
    _ = win32.SendMessageW(b.hwnd, win32.WM_SETFOCUS, 0, 0);
    try std.testing.expect(p.open);
    try std.testing.expect(p.surface == b);
    try std.testing.expect(Window.focusTarget(b) == edit);

    // Dismissed, then Paste chosen: each time the focus back on b, and the
    // palette still open.
    for ([_]?[]const u8{ null, "Paste" }, [_][]const u8{ "", "paste_from_clipboard;" }, 1..) |choose, performed, n| {
        MenuSeen.choose = choose;
        FocusSeen.last = null;
        testRightClick(b, 20, 30);
        try std.testing.expectEqual(n, MenuSeen.count);
        try std.testing.expectEqualStrings(performed, PaletteSeen.take());
        try std.testing.expect(FocusSeen.last == b.hwnd);
        try std.testing.expect(p.open and p.hwnd != null);
    }
}

test "win32: a teardown posted while a terminal's context menu is open waits for it to close" {
    // The menu's loop runs under the terminal's WM_RBUTTONUP handler and
    // dispatches what is posted meanwhile (`App.terminal_loops`): the
    // terminal's own teardown, as its shell exiting posts it, and its
    // window's, as a close from another window posts it, are deferred
    // while the menu is open, so that the handler goes on with the
    // terminal and its window alive, and are posted again when it closes,
    // to run from the loop the handler returns to.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    ContextMenu.test_track = &MenuSeen.track;
    defer ContextMenu.test_track = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    Surface.test_mouse_button = &MenuCore.answer;
    defer Surface.test_mouse_button = null;
    MenuSeen.reset();
    defer MenuSeen.reset();
    MenuCore.reset();
    PaletteSeen.reset(null);

    const first = try testFrame(&app);
    const a = try testPane(&app, first);
    first.tab().tree = try .init(alloc, a);
    first.relayout();
    const second = try testFrame(&app);
    const b = try testPane(&app, second);
    second.tab().tree = try .init(alloc, b);
    second.relayout();

    const Posted = struct {
        var app_: *App = undefined;
        var surface: *Surface = undefined;
        var window: *Window = undefined;
        var close_window: bool = false;
        /// What the loop saw after dispatching the teardown.
        var alive: bool = false;
        var deferred: bool = false;
        fn post() void {
            if (close_window) window.postDestroy() else surface.postDestroy();
            testPump();
            alive = std.mem.indexOfScalar(*Surface, app_.surfaces.items, surface) != null and
                std.mem.indexOfScalar(*Window, app_.windows.items, window) != null;
            if (!alive) return;
            deferred = if (close_window) window.destroy_deferred else surface.destroy_deferred;
        }
    };
    Posted.app_ = &app;
    MenuSeen.during = &Posted.post;
    // Chosen, as a dismissed one would be: performed on a live terminal.
    MenuSeen.choose = "Paste";

    for ([_]struct { *Surface, *Window, bool }{ .{ a, first, false }, .{ b, second, true } }) |c| {
        Posted.surface = c[0];
        Posted.window = c[1];
        Posted.close_window = c[2];
        Posted.alive = false;
        Posted.deferred = false;
        testRightClick(c[0], 20, 30);
        try std.testing.expect(Posted.alive);
        try std.testing.expect(Posted.deferred);
        try std.testing.expectEqualStrings("paste_from_clipboard;", PaletteSeen.take());
        // Posted again, not run, inside the handler.
        try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, c[0]) != null);
        testPump();
        try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, c[0]) == null);
        try std.testing.expect(std.mem.indexOfScalar(*Window, app.windows.items, c[1]) == null);
    }
    try std.testing.expectEqual(0, app.terminal_loops);
}

/// For tests: dispatch every message waiting on this thread, as a loop
/// does.
fn testPump() void {
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE).toBool()) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

/// For tests: the core's `performBindingAction` for a context menu's
/// item, once `PaletteSeen` has seen it. New Window and the splits ask the
/// runtime for their window or split, which records it for `run`
/// (`App.performAction`), as the core asks (`newWindow` in src/App.zig,
/// `.new_split` in src/Surface.zig).
const MenuActs = struct {
    fn seen(surface: *Surface, action: input.Binding.Action) bool {
        _ = PaletteSeen.seen(surface, action);
        const target: apprt.Target = .{ .surface = &surface.core_surface };
        return switch (action) {
            .new_window => surface.app.performAction(target, .new_window, {}) catch false,
            .new_split => |direction| surface.app.performAction(target, .new_split, switch (direction) {
                .right, .auto => .right,
                .down => .down,
                .left => .left,
                .up => .up,
            }) catch false,
            else => true,
        };
    }
};

test "win32: an item chosen in the context menu after its terminal or window began to close is dropped" {
    // The terminal's shell exited, or its window was closed, while its
    // menu was open: the teardown waits for the menu
    // (`App.terminal_loops`) and runs after it, and the item chosen
    // meanwhile is neither performed nor recorded for `run`, as GTK's
    // popover goes with its surface. The terminal still has the focus back
    // first.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    ContextMenu.test_track = &MenuSeen.track;
    defer ContextMenu.test_track = null;
    SearchBar.test_perform = &MenuActs.seen;
    defer SearchBar.test_perform = null;
    Surface.test_mouse_button = &MenuCore.answer;
    defer Surface.test_mouse_button = null;
    MenuSeen.reset();
    defer MenuSeen.reset();
    MenuCore.reset();
    PaletteSeen.reset(null);

    const first = try testFrame(&app);
    testResize(first, 400, 300);
    const a = try testPane(&app, first);
    const b = try testPane(&app, first);
    first.tab().tree = try testRow(alloc, &.{ a, b });
    first.relayout();
    const second = try testFrame(&app);
    const c = try testPane(&app, second);
    second.tab().tree = try .init(alloc, c);
    second.relayout();

    // On a terminal that is not closing, New Window is performed, and asks
    // `run` for the window.
    MenuSeen.choose = "New Window";
    testRightClick(a, 20, 30);
    try std.testing.expectEqualStrings("new_window;", PaletteSeen.take());
    try std.testing.expectEqual(1, app.requests.items.len);
    try std.testing.expect(app.requests.items[0] == .window);
    app.requests.clearRetainingCapacity();

    const Closing = struct {
        var surface: *Surface = undefined;
        var window: ?*Window = null;
        /// The close, as the core asks it when the shell exits
        /// (`Surface.close`) or as a close of the window does
        /// (`Window.requestClose`), then the teardown it posts, dispatched
        /// by the menu's loop.
        fn start() void {
            if (window) |w| w.requestClose() else surface.close(false);
            testPump();
        }
    };
    MenuSeen.during = &Closing.start;
    for ([_]struct { *Surface, ?*Window, []const u8 }{
        .{ b, null, "New Window" },
        .{ c, second, "Split Right" },
    }) |case| {
        Closing.surface = case[0];
        Closing.window = case[1];
        MenuSeen.choose = case[2];
        FocusSeen.last = null;
        testRightClick(case[0], 20, 30);
        try std.testing.expect(FocusSeen.last == case[0].hwnd);
        try std.testing.expectEqualStrings("", PaletteSeen.take());
        try std.testing.expectEqual(0, app.requests.items.len);
        // The teardown, deferred while the menu was open, runs after it.
        try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, case[0]) != null);
        testPump();
        try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, case[0]) == null);
        if (case[1]) |w| try std.testing.expect(std.mem.indexOfScalar(*Window, app.windows.items, w) == null);
    }
    try std.testing.expectEqual(3, MenuSeen.count);
}

test "win32: a right click in a divider's band shows no context menu" {
    // The band is the divider's: a right press and release there reach
    // the frame (`Dividers.hitTest`), which shows no menu, as on the line
    // itself; a step further in, on the terminal, the same click shows
    // the terminal's.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    // Without scroll bars, which keep their pixels beside a line ("beside
    // a divider a terminal's scroll bar keeps its pixels").
    app.config.scrollbar = .never;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;
    ContextMenu.test_track = &MenuSeen.track;
    defer ContextMenu.test_track = null;
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    Surface.test_mouse_button = &MenuCore.answer;
    defer Surface.test_mouse_button = null;
    MenuSeen.reset();
    MenuCore.reset();

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.relayout();
    const ra = try paneRect(window, a);
    const line = ra.right;
    const y = @divTrunc(ra.top + ra.bottom, 2);

    // The band, 3 DIP each side of the line, and the line.
    for ([_]i32{ line - 3, line, line + 3 }) |x| {
        try std.testing.expect(Dividers.at(window, .{ .x = x, .y = y }) != null);
        _ = win32.SendMessageW(window.hwnd, win32.WM_RBUTTONDOWN, win32.MK_RBUTTON, testPoint(x, y));
        _ = win32.SendMessageW(window.hwnd, win32.WM_RBUTTONUP, 0, testPoint(x, y));
    }
    try std.testing.expectEqual(0, MenuSeen.count);
    try std.testing.expectEqual(0, MenuCore.calls);
    // Outside it, on a.
    try std.testing.expect(Dividers.at(window, .{ .x = line - 4, .y = y }) == null);
    testRightClick(a, line - 4 - ra.left, y - ra.top);
    try std.testing.expectEqual(1, MenuSeen.count);
}

/// For tests: the core's `scrollbar` on `surface`, as its tick performs it
/// when the rows change.
fn testRows(app: *App, surface: *Surface, total: usize, offset: usize, len: usize) !bool {
    return app.performAction(.{ .surface = &surface.core_surface }, .scrollbar, .{ .total = total, .offset = offset, .len = len });
}

/// For tests: what `surface`'s scroll bar holds, as Windows reads it.
fn testBarInfo(surface: *const Surface) !win32.SCROLLINFO {
    var info: win32.SCROLLINFO = .{ .fMask = win32.SIF_ALL };
    if (!win32.GetScrollInfo(surface.hwnd, win32.SB_VERT, &info).toBool()) return error.TestUnexpectedResult;
    return info;
}

/// For tests: `surface`'s scroll bar holds the range from 0 to `max`, a
/// page of `page`, at `pos`.
fn expectBar(surface: *const Surface, max: c_int, page: c_uint, pos: c_int) !void {
    const info = try testBarInfo(surface);
    try std.testing.expectEqual(0, info.nMin);
    try std.testing.expectEqual(max, info.nMax);
    try std.testing.expectEqual(page, info.nPage);
    try std.testing.expectEqual(pos, info.nPos);
}

/// For tests: whether `surface`'s window has its scroll bar.
fn testHasBar(surface: *const Surface) bool {
    const bit: isize = win32.WS_VSCROLL;
    return win32.GetWindowLongPtrW(surface.hwnd, win32.GWL_STYLE) & bit != 0;
}

/// For tests: WM_VSCROLL to `surface` with the request `code`, and `high`
/// in wParam's high word, as its scroll bar sends it.
fn testScroll(surface: *const Surface, code: u16, high: u16) void {
    const wparam = @as(win32.WPARAM, code) | (@as(win32.WPARAM, high) << 16);
    _ = win32.SendMessageW(surface.hwnd, win32.WM_VSCROLL, wparam, 0);
}

/// For tests: `pane`'s window and client widths.
fn testWidths(window: *const Window, pane: *const Surface) ![2]i32 {
    const outer = try paneRect(window, pane);
    return .{ outer.right - outer.left, (try clientRect(pane.hwnd)).right };
}

test "win32: scrollbar gives a terminal's bar the core's rows, and skips an update that changes none" {
    // The bar's range is the scrollback's rows, its page the screen's, its
    // position the viewport's top row, as Windows reads them back
    // (GetScrollInfo); an update the bar already shows calls no
    // SetScrollInfo. A scrollback no taller than the screen disables the
    // bar rather than taking it away (SIF_DISABLENOSCROLL): the terminal
    // keeps its width. Past what SetScrollInfo takes, the range stops
    // there, where a wrap of 2^32 + 5 rows would give 4.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    // Made with the bar, `scrollbar = system` being the default, and
    // disabled until the core's rows come: one row, a page of one.
    try std.testing.expectEqual(.system, app.config.scrollbar);
    try std.testing.expect(testHasBar(a));
    const bar = ScrollBar.width(a);
    try std.testing.expect(bar > 0);
    const widths = try testWidths(window, a);
    try std.testing.expectEqual(widths[0] - bar, widths[1]);
    try expectBar(a, 0, 1, 0);

    try std.testing.expect(!try app.performAction(.app, .scrollbar, .zero));
    try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
    try expectBar(a, 999, 50, 500);

    // The same again: nothing; then each value alone.
    const sets = ScrollBar.test_sets;
    try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
    try std.testing.expectEqual(sets, ScrollBar.test_sets);
    for ([_][3]usize{ .{ 1000, 501, 50 }, .{ 1001, 501, 50 }, .{ 1001, 501, 49 } }, 1..) |r, n| {
        try std.testing.expect(try testRows(&app, a, r[0], r[1], r[2]));
        try std.testing.expectEqual(sets + n, ScrollBar.test_sets);
        try expectBar(a, @intCast(r[0] - 1), @intCast(r[2]), @intCast(r[1]));
    }

    // No taller than the screen, or empty: disabled, the bar and the width
    // kept.
    for ([_]usize{ 50, 49, 0 }) |total| {
        try std.testing.expect(try testRows(&app, a, total, 0, 50));
        try std.testing.expect(testHasBar(a));
        try std.testing.expectEqual(widths, try testWidths(window, a));
    }

    // Past what it takes.
    try std.testing.expect(try testRows(&app, a, (1 << 32) + 5, 0, 50));
    try std.testing.expectEqual(std.math.maxInt(i32), (try testBarInfo(a)).nMax);
}

test "win32: while its thumb is dragged the bar keeps its place, and takes the core's when the drag ends" {
    // From the SB_THUMBTRACK that the bar's loop sends at the press on the
    // thumb, the core's rows reach the bar without their position, which
    // the system keeps where the pointer holds the thumb, as macOS leaves
    // its scroller alone while it is dragged; SB_ENDSCROLL gives it the
    // position the core reported last, or, released before the core
    // reports the row the drag last asked for, that row. A loop that ends
    // with no SB_ENDSCROLL ends the drag as well. Outside the bar's loop an
    // SB_THUMBTRACK drags nothing: the core's next rows show their
    // position.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    PaletteSeen.reset(null);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    ScrollBar.test_loop = &BarSteps.run;
    defer ScrollBar.test_loop = null;

    try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
    try BarSteps.press(a, &.{
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0 } },
        .{ .rows = .{ 1100, 600, 50 } },
        .read,
        .{ .scroll = .{ win32.SB_ENDSCROLL, 0 } },
        .read,
        // And after it, every update in full.
        .{ .rows = .{ 1100, 610, 50 } },
        .read,
    });
    try BarSteps.expectRead(0, 1099, 500);
    try BarSteps.expectRead(1, 1099, 600);
    try BarSteps.expectRead(2, 1099, 610);
    try std.testing.expectEqualStrings("", PaletteSeen.take());

    // The core's viewport moves on while the thumb is held where it was,
    // whose row the next SB_THUMBTRACK asks for; released before the core
    // reports it, the thumb stays there, not at the core's last report.
    try BarSteps.press(a, &.{
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0 } },
        .{ .rows = .{ 1100, 700, 50 } },
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0 } },
        .{ .scroll = .{ win32.SB_ENDSCROLL, 0 } },
        .read,
    });
    try std.testing.expectEqualStrings("scroll_to_row:610;", PaletteSeen.take());
    try BarSteps.expectRead(0, 1099, 610);

    // A loop that ends with no SB_ENDSCROLL.
    try BarSteps.press(a, &.{
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0 } },
        .{ .rows = .{ 1200, 700, 50 } },
        .read,
    });
    try BarSteps.expectRead(0, 1199, 610);
    try expectBar(a, 1199, 50, 700);
    try std.testing.expectEqualStrings("", PaletteSeen.take());

    // Outside the bar's loop, as another program could send it: one move,
    // no drag.
    try std.testing.expect(try testRows(&app, a, 1200, 710, 50));
    testScroll(a, win32.SB_THUMBTRACK, 0);
    try std.testing.expect(try testRows(&app, a, 1200, 720, 50));
    try std.testing.expectEqual(720, (try testBarInfo(a)).nPos);
    try std.testing.expectEqualStrings("", PaletteSeen.take());
}

test "win32: a press on the thumb that does not move it asks for no row at its release" {
    // Windows sends SB_THUMBTRACK at a press on the thumb, for the place
    // the thumb is at, and SB_THUMBPOSITION for the same place at the
    // release, then SB_ENDSCROLL, with no move between them. Meanwhile the
    // output moves on a terminal that follows it: asked for, the release's
    // place would pin its viewport back where the press found it. In a
    // press's loop SB_THUMBPOSITION asks nothing, and the bar takes the
    // core's position at the end.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    PaletteSeen.reset(null);
    ScrollBar.test_loop = &BarSteps.run;
    defer ScrollBar.test_loop = null;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    // At the bottom, following the output.
    try std.testing.expect(try testRows(&app, a, 1000, 950, 50));
    try BarSteps.press(a, &.{
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0 } },
        .{ .rows = .{ 1100, 1050, 50 } },
        .{ .rows = .{ 1200, 1150, 50 } },
        .{ .scroll = .{ win32.SB_THUMBPOSITION, 0 } },
        .{ .scroll = .{ win32.SB_ENDSCROLL, 0 } },
        .read,
    });
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    try BarSteps.expectRead(0, 1199, 1150);
}

test "win32: the bar's requests scroll the terminal to their row, once each" {
    // WM_VSCROLL, as the bar sends it, performs the core's `scroll_to_row`
    // with the row it names (`ScrollBar.rowFor`), from the row the core
    // reported, or the one last asked of it that the core has not reported
    // yet; and nothing when that is the row already: at either end, or the
    // thumb where the core is. The thumb's row is the bar's 32-bit track
    // position, not wParam's high word, which has 16 bits of it. Nothing
    // reaches the core under a prompt, nor from a scroll bar control's
    // WM_VSCROLL, which names the control.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    PaletteSeen.reset(null);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    // Each from 500, which the core reports first, of 1000 rows, 50 shown.
    for ([_]struct { u16, []const u8 }{
        .{ win32.SB_LINEDOWN, "scroll_to_row:501;" },
        .{ win32.SB_LINEUP, "scroll_to_row:499;" },
        .{ win32.SB_PAGEDOWN, "scroll_to_row:550;" },
        .{ win32.SB_PAGEUP, "scroll_to_row:450;" },
        .{ win32.SB_TOP, "scroll_to_row:0;" },
        .{ win32.SB_BOTTOM, "scroll_to_row:950;" },
    }) |c| {
        try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
        testScroll(a, c[0], 0);
        try std.testing.expectEqualStrings(c[1], PaletteSeen.take());
        try std.testing.expect(PaletteSeen.on == a);
    }

    // Two steps before the core reports the first: the second from it.
    try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
    testScroll(a, win32.SB_LINEDOWN, 0);
    testScroll(a, win32.SB_LINEDOWN, 0);
    try std.testing.expectEqualStrings("scroll_to_row:501;scroll_to_row:502;", PaletteSeen.take());

    // At the ends, nothing to ask; nor at the end of a scroll.
    try std.testing.expect(try testRows(&app, a, 1000, 0, 50));
    for ([_]u16{ win32.SB_LINEUP, win32.SB_PAGEUP, win32.SB_TOP, win32.SB_ENDSCROLL }) |code| testScroll(a, code, 0);
    try std.testing.expect(try testRows(&app, a, 1000, 950, 50));
    for ([_]u16{ win32.SB_LINEDOWN, win32.SB_PAGEDOWN, win32.SB_BOTTOM }) |code| testScroll(a, code, 0);
    try std.testing.expectEqualStrings("", PaletteSeen.take());

    // The thumb past what 16 bits hold. Outside the system's own drag
    // Windows gives the bar's position as the thumb's.
    try std.testing.expect(try testRows(&app, a, 200_000, 100_000, 50));
    var track: win32.SCROLLINFO = .{ .fMask = win32.SIF_TRACKPOS };
    try std.testing.expect(win32.GetScrollInfo(a.hwnd, win32.SB_VERT, &track).toBool());
    try std.testing.expectEqual(100_000, track.nTrackPos);
    // In a press's loop: the press's SB_THUMBTRACK, where the core is,
    // asks nothing, whatever the high word says. The core moves meanwhile,
    // and the thumb stays where it is held: the next one's row is another,
    // asked once; the release's SB_THUMBPOSITION, the same place, nothing.
    ScrollBar.test_loop = &BarSteps.run;
    defer ScrollBar.test_loop = null;
    try BarSteps.press(a, &.{
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0x1234 } },
        .{ .rows = .{ 200_000, 150_000, 50 } },
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0x1234 } },
        .{ .scroll = .{ win32.SB_THUMBPOSITION, 0x1234 } },
        .{ .scroll = .{ win32.SB_ENDSCROLL, 0 } },
    });
    try std.testing.expectEqualStrings("scroll_to_row:100000;", PaletteSeen.take());
    // In the bar's menu's loop its SB_THUMBPOSITION, Scroll Here's, is
    // taken, at the 32-bit place too.
    try std.testing.expect(try testRows(&app, a, 200_000, 100_000, 50));
    try BarSteps.menu(a, &.{
        .{ .scroll = .{ win32.SB_THUMBTRACK, 0x1234 } },
        .{ .rows = .{ 200_000, 150_000, 50 } },
        .{ .scroll = .{ win32.SB_THUMBPOSITION, 0x1234 } },
        .{ .scroll = .{ win32.SB_ENDSCROLL, 0 } },
    });
    try std.testing.expectEqualStrings("scroll_to_row:100000;", PaletteSeen.take());

    // Under a prompt, nothing; after it, the request goes through.
    try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
    app.beginPrompt(null);
    testScroll(a, win32.SB_LINEDOWN, 0);
    app.endPrompt();
    try std.testing.expectEqualStrings("", PaletteSeen.take());
    testScroll(a, win32.SB_LINEDOWN, 0);
    try std.testing.expectEqualStrings("scroll_to_row:501;", PaletteSeen.take());

    // A control's.
    _ = win32.SendMessageW(a.hwnd, win32.WM_VSCROLL, win32.SB_PAGEDOWN, @bitCast(@intFromPtr(window.hwnd)));
    try std.testing.expectEqualStrings("", PaletteSeen.take());
}

test "win32: scrollbar = never makes terminals without a bar, and its action is not carried out" {
    // The terminal's window has no bar and the grid all of its width; the
    // core's rows are not given to SetScrollInfo, which would show a bar
    // there for them, and the action answers false; no WM_VSCROLL moves
    // the viewport.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    app.config.scrollbar = .never;
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();

    try std.testing.expect(!testHasBar(a));
    try std.testing.expectEqual(0, ScrollBar.width(a));
    const widths = try testWidths(window, a);
    try std.testing.expectEqual(widths[0], widths[1]);
    const sets = ScrollBar.test_sets;
    try std.testing.expect(!try testRows(&app, a, 1000, 500, 50));
    try std.testing.expectEqual(sets, ScrollBar.test_sets);
    try std.testing.expect(!testHasBar(a));
    try std.testing.expectEqual(widths, try testWidths(window, a));

    // Nor are WM_VSCROLLs, which only the bar would send, taken.
    SearchBar.test_perform = &PaletteSeen.seen;
    defer SearchBar.test_perform = null;
    PaletteSeen.reset(null);
    for ([_]u16{ win32.SB_LINEDOWN, win32.SB_TOP, win32.SB_THUMBTRACK }) |code| testScroll(a, code, 0);
    try std.testing.expectEqualStrings("", PaletteSeen.take());
}

test "win32: a new configuration's scrollbar gives the terminals their bar, or takes it, from run" {
    // `scrollbar` reaches the app with config_change, inside a core frame
    // when a soft reload brings it, and the bar changes the client area,
    // and the core's grid with it: so the terminals' windows change from
    // `run` (`App.Request.redecorate`), in every tab, a hidden one's too.
    // A bar given back shows the rows the core reported meanwhile.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    const c = try testTab(&app, window);
    try std.testing.expect(!shown(c.hwnd));
    try std.testing.expect(try testRows(&app, a, 1000, 500, 50));
    const widths = try testWidths(window, a);
    const bar = ScrollBar.width(a);
    try std.testing.expect(bar > 0);

    for ([_]configpkg.Config.Scrollbar{ .never, .system }) |want| {
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.scrollbar = want;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        // Not yet.
        try std.testing.expect(testHasBar(a) == (want == .never));
        try std.testing.expect(testHasBar(c) == (want == .never));
        try std.testing.expectEqual(widths[1] + @as(i32, if (want == .never) 0 else bar), (try testWidths(window, a))[1]);
        try std.testing.expect(app.requests.items[app.requests.items.len - 1] == .redecorate);
        app.createRequested();
        try std.testing.expect(testHasBar(a) == (want == .system));
        try std.testing.expect(testHasBar(c) == (want == .system));
        try std.testing.expectEqual(widths[0], (try testWidths(window, a))[0]);
        try std.testing.expectEqual(widths[1] + @as(i32, if (want == .never) bar else 0), (try testWidths(window, a))[1]);
        // Meanwhile, the core's rows: not shown without the bar.
        if (want == .never) {
            try std.testing.expectEqual(0, ScrollBar.width(a));
            try std.testing.expect(!try testRows(&app, a, 1200, 700, 50));
            try std.testing.expect(!testHasBar(a));
        }
    }
    try expectBar(a, 1199, 50, 700);
}

test "win32: beside a divider a terminal's scroll bar keeps its pixels" {
    // In (a | b) over c, a's bar runs down the line between a and b: its
    // pixels within 3 DIP of the line stay the bar's (HTVSCROLL), as
    // `Dividers.hitTest` lets the pointer through over the client area
    // alone, so that the bar's arrows and track keep their width. The band
    // there is the line and b's side of it; a's client area, left of its
    // bar, is a's. Along the line over c, the bars of b and c, in the
    // window's right-hand column, keep their pixels as well, while the
    // client areas beside them are the band's.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    const c = try testPane(&app, window);
    try testSplits(window, a, b, c);
    const ra = try paneRect(window, a);
    const rb = try paneRect(window, b);
    const rc = try paneRect(window, c);
    const line = ra.right;
    try std.testing.expectEqual(line + 1, rb.left);
    try std.testing.expectEqual(rb.bottom + 1, rc.top);
    const inner = (try paneClient(window, a)).right;
    try std.testing.expect(inner < line - 3);
    const y = @divTrunc(ra.top + ra.bottom, 2);
    // The bars' column at the window's right edge, and b's client area.
    const right_bar = (try paneClient(window, b)).right;
    try std.testing.expectEqual(right_bar, (try paneClient(window, c)).right);
    try std.testing.expect(right_bar < rb.right);
    const x_bar = @divTrunc(right_bar + rb.right, 2);
    const xb = @divTrunc(rb.left + right_bar, 2);

    const through = win32.HTTRANSPARENT;
    const bar: win32.LRESULT = win32.HTVSCROLL;
    const client: win32.LRESULT = win32.HTCLIENT;
    for ([_]struct { *Surface, i32, i32, win32.LRESULT }{
        // a's bar, in the band and out of it, and a's client area.
        .{ a, line - 1, y, bar },
        .{ a, line - 3, y, bar },
        .{ a, inner, y, bar },
        .{ a, inner - 1, y, client },
        // b's side of the line, a's band as before.
        .{ b, rb.left, y, through },
        .{ b, rb.left + 2, y, through },
        .{ b, rb.left + 3, y, client },
        // Within 3 DIP above the line over c: b's bar, and b's client
        // area; below it, c's.
        .{ b, x_bar, rb.bottom - 1, bar },
        .{ b, x_bar, rb.bottom - 3, bar },
        .{ b, xb, rb.bottom - 1, through },
        .{ b, xb, rb.bottom - 3, through },
        .{ c, x_bar, rc.top, bar },
        .{ c, x_bar, rc.top + 2, bar },
        .{ c, xb, rc.top + 2, through },
    }) |case| {
        try std.testing.expectEqual(case[3], try testHitTest(window, case[0], case[1], case[2]));
    }
    // The lines themselves are the frame's.
    try std.testing.expect(Dividers.at(window, .{ .x = line, .y = y }) != null);
    try std.testing.expect(Dividers.at(window, .{ .x = x_bar, .y = rb.bottom }) != null);
}

test "win32: a terminal's least width counts its scroll bar beside the cell" {
    // A terminal with no core keeps a pixel (`Window.cellExtent`) of its
    // client area, what its bar leaves of its window: a dragged divider
    // stops there, resize_split does not go past it (`Window.adopt`), and a
    // split needs it for each side.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    TestDpi.dpi = 96;
    app.get_dpi_for_window = &TestDpi.of;

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    const b = try testPane(&app, window);
    window.tab().tree = try testRow(alloc, &.{ a, b });
    window.tab().focused = a;
    window.relayout();
    _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNOACTIVATE);
    defer _ = win32.ReleaseCapture();
    const bar = ScrollBar.width(a);
    try std.testing.expect(bar > 1);
    const ra = try paneRect(window, a);
    const y = @divTrunc(ra.top + ra.bottom, 2);

    // Dragged left, then right: each side keeps a pixel beside its bar.
    try testPressDivider(window, ra.right, y);
    testFrameMouse(window, win32.WM_MOUSEMOVE, -1000, y);
    try std.testing.expectEqual([2]i32{ 1 + bar, 1 }, try testWidths(window, a));
    testFrameMouse(window, win32.WM_MOUSEMOVE, 5000, y);
    try std.testing.expectEqual([2]i32{ 1 + bar, 1 }, try testWidths(window, b));
    testFrameMouse(window, win32.WM_LBUTTONUP, 5000, y);

    // resize_split towards a, from the middle, by all but half its bar of
    // its window: its client area would be gone, so nothing moves.
    window.equalize(a);
    const half = try testWidths(window, a);
    const amount: u16 = @intCast(half[0] - @divTrunc(bar, 2));
    window.resizeSplit(a, .{ .amount = amount, .direction = .left });
    try std.testing.expectEqual(half, try testWidths(window, a));
    // By less, leaving a pixel of it: it moves.
    window.resizeSplit(a, .{ .amount = @intCast(half[1] - 2), .direction = .left });
    try std.testing.expect((try testWidths(window, a))[1] >= 1);
    try std.testing.expect((try testWidths(window, a))[0] < half[0]);

    // a narrowed so that it holds two cells and the line, but not their
    // two bars: it does not split; widened, it does.
    const Panes = struct {
        fn create(w: *Window) anyerror!*Surface {
            return testPane(w.app, w);
        }
    };
    Window.test_create_pane = &Panes.create;
    defer Window.test_create_pane = null;
    a.core_surface.size.cell = .{ .width = 1, .height = 1 };
    try testPressDivider(window, (try paneRect(window, a)).right, y);
    testFrameMouse(window, win32.WM_LBUTTONUP, ra.left + bar + 4, y);
    const narrow = try testWidths(window, a);
    try std.testing.expect(narrow[0] >= 2 + Window.dividerWidth(96) and narrow[0] < 2 * (1 + bar) + Window.dividerWidth(96));
    // Not expectError, which would print the terminal it got.
    if (window.split(a, .right, .{})) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.SplitTooSmall, err);
    try testPressDivider(window, (try paneRect(window, a)).right, y);
    testFrameMouse(window, win32.WM_LBUTTONUP, ra.left + 2 * (1 + bar) + 10, y);
    const d = try window.split(a, .right, .{});
    window.showPane(d);
    try std.testing.expect(window.tab().tree.locate(d) != null);
}

/// For tests: `msg` sent to `hwnd`, which should reach a stand-in for one
/// of the system's loops (`ScrollBar.test_loop`). Should the code let it
/// reach DefWindowProcW instead, the real loop would wait for a button
/// no test presses: a thread timer, which the loop dispatches, then ends
/// it (WM_CANCELMODE ends a scroll bar's tracking, EndMenu a menu) and
/// says so (`ran`), so that the test fails rather than waits.
const RealLoop = struct {
    var target: ?win32.HWND = null;
    var ran: bool = false;
    var timer: win32.UINT_PTR = 0;

    fn send(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
        target = hwnd;
        ran = false;
        timer = win32.SetTimer(null, 0, 1000, @ptrCast(&fire));
        defer if (timer != 0) {
            _ = win32.KillTimer(null, timer);
            timer = 0;
        };
        return win32.SendMessageW(hwnd, msg, wparam, lparam);
    }

    fn fire(_: ?win32.HWND, _: win32.UINT, id: win32.UINT_PTR, _: win32.DWORD) callconv(.winapi) void {
        _ = win32.KillTimer(null, id);
        timer = 0;
        ran = true;
        if (target) |h| _ = win32.SendMessageW(h, win32.WM_CANCELMODE, 0, 0);
        _ = win32.EndMenu();
    }
};

/// For tests: a scroll bar's loop (`ScrollBar.test_loop`) that sends its
/// terminal, in order, what the system's loop would (`steps`), with the
/// core's rows reported meanwhile, and reads the bar back where a step
/// says (`read`, into `seen`).
const BarSteps = struct {
    const Step = union(enum) {
        /// WM_VSCROLL with this request and high word, as the bar sends it.
        scroll: [2]u16,
        /// The core's rows, as its tick reports them (`testRows`): the
        /// total, the offset and the length.
        rows: [3]usize,
        /// The bar's range and position, as Windows reads them back.
        read,
    };
    var steps: []const Step = &.{};
    var seen: [4]win32.SCROLLINFO = undefined;
    var reads: usize = 0;
    var ran: bool = false;
    var failed: bool = false;

    fn run(surface: *Surface, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
        _ = msg;
        _ = wparam;
        _ = lparam;
        ran = true;
        for (steps) |step| switch (step) {
            .scroll => |w| testScroll(surface, w[0], w[1]),
            .rows => |r| if (!(testRows(surface.app, surface, r[0], r[1], r[2]) catch false)) {
                failed = true;
            },
            .read => {
                if (reads == seen.len) {
                    failed = true;
                    continue;
                }
                seen[reads] = testBarInfo(surface) catch {
                    failed = true;
                    continue;
                };
                reads += 1;
            },
        };
        return 0;
    }

    /// `these` in the loop of a press on `surface`'s bar, which its
    /// DefWindowProcW runs for WM_SYSCOMMAND.
    fn press(surface: *Surface, these: []const Step) !void {
        try inLoop(surface, these, win32.WM_SYSCOMMAND, win32.SC_HSCROLL | win32.HTVSCROLL, 0);
    }

    /// `these` in the loop of the bar's menu, which WM_CONTEXTMENU at a
    /// point on the bar runs.
    fn menu(surface: *Surface, these: []const Step) !void {
        const client = try clientRect(surface.hwnd);
        var on: win32.POINT = .{ .x = client.right + @divTrunc(ScrollBar.width(surface), 2), .y = @divTrunc(client.bottom, 2) };
        if (!win32.ClientToScreen(surface.hwnd, &on).toBool()) return error.TestUnexpectedResult;
        try inLoop(surface, these, win32.WM_CONTEXTMENU, @intFromPtr(surface.hwnd), testPoint(on.x, on.y));
    }

    fn inLoop(surface: *Surface, these: []const Step, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) !void {
        steps = these;
        reads = 0;
        ran = false;
        failed = false;
        _ = RealLoop.send(surface.hwnd, msg, wparam, lparam);
        try std.testing.expect(!RealLoop.ran);
        try std.testing.expect(ran);
        try std.testing.expect(!failed);
    }

    /// The `n`th read: the range to `max`, at `pos`.
    fn expectRead(n: usize, max: c_int, pos: c_int) !void {
        try std.testing.expect(n < reads);
        try std.testing.expectEqual(max, seen[n].nMax);
        try std.testing.expectEqual(pos, seen[n].nPos);
    }
};

/// For tests: what a scroll bar's loop saw (`ScrollBar.test_loop`), run
/// in place of DefWindowProcW's: the counts the app holds, a wakeup
/// posted and dispatched to the app's window procedure, and a teardown
/// posted as the shell's exit or a close of the window posts one, and
/// dispatched.
const BarLoop = struct {
    var calls: usize = 0;
    var msg: win32.UINT = 0;
    var wparam: win32.WPARAM = 0;
    var depth: u32 = 0;
    var loops: u32 = 0;
    var ticks: usize = 0;
    var ticked: usize = 0;
    /// The teardown to post: the terminal's, or with `window` its window's.
    var surface: ?*Surface = null;
    var window: ?*Window = null;
    var alive: bool = false;
    var deferred: bool = false;

    fn run(s: *Surface, m: win32.UINT, w: win32.WPARAM, l: win32.LPARAM) win32.LRESULT {
        _ = l;
        calls += 1;
        msg = m;
        wparam = w;
        const app = s.app;
        depth = app.modal_loop_depth;
        loops = app.terminal_loops;
        const before = ticks;
        app.wakeup();
        var posted: win32.MSG = undefined;
        while (win32.PeekMessageW(&posted, app.msg_hwnd, WM_GHOSTTY_WAKEUP, WM_GHOSTTY_WAKEUP, win32.PM_REMOVE).toBool()) {
            _ = App.wndProc(app.msg_hwnd, posted.message, posted.wParam, posted.lParam);
        }
        ticked = ticks - before;
        const target = surface orelse return 7;
        if (window) |win| win.postDestroy() else target.postDestroy();
        testPump();
        alive = std.mem.indexOfScalar(*Surface, app.surfaces.items, target) != null;
        if (window) |win| alive = alive and std.mem.indexOfScalar(*Window, app.windows.items, win) != null;
        if (!alive) return 7;
        deferred = if (window) |win| win.destroy_deferred else target.destroy_deferred;
        return 7;
    }

    fn tick(_: *App) void {
        ticks += 1;
    }

    fn reset() void {
        calls = 0;
        msg = 0;
        wparam = 0;
        surface = null;
        window = null;
        alive = false;
        deferred = false;
    }
};

test "win32: a press on the scroll bar runs its loop counted, and a teardown posted in it waits" {
    // Windows runs the bar's loop inside the terminal's DefWindowProcW,
    // for WM_SYSCOMMAND's scroll commands, which a press on it sends,
    // SC_HSCROLL with HTVSCROLL for the vertical bar on Windows 11, and a
    // double click there SC_VSCROLL with HTVSCROLL, and for WM_CONTEXTMENU
    // on the bar, its menu's. The frame hears of neither, so
    // the loop is counted in terminal_loops: the terminal's own teardown,
    // and its window's, posted meanwhile, are deferred, the handler goes on
    // with the terminal alive, and they run after it; and in
    // modal_loop_depth, so that a wakeup dispatched in it ticks the core.
    // A WM_CONTEXTMENU off the bar runs none.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    _ = win32.SetWindowLongPtrW(app.msg_hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(&app)));
    App.test_tick = &BarLoop.tick;
    defer App.test_tick = null;
    ScrollBar.test_loop = &BarLoop.run;
    defer ScrollBar.test_loop = null;
    BarLoop.reset();

    var frames: [3]*Window = undefined;
    var panes: [3]*Surface = undefined;
    for (&frames, &panes) |*f, *p| {
        f.* = try testFrame(&app);
        testResize(f.*, 400, 300);
        p.* = try testPane(&app, f.*);
        f.*.tab().tree = try .init(alloc, p.*);
        f.*.relayout();
    }

    // The teardowns: a's own, then b's window's.
    for ([_]struct { *Surface, ?*Window }{ .{ panes[0], null }, .{ panes[1], frames[1] } }) |c| {
        BarLoop.surface = c[0];
        BarLoop.window = c[1];
        BarLoop.alive = false;
        BarLoop.deferred = false;
        _ = RealLoop.send(c[0].hwnd, win32.WM_SYSCOMMAND, win32.SC_HSCROLL | win32.HTVSCROLL, 0);
        try std.testing.expect(!RealLoop.ran);
        try std.testing.expect(BarLoop.alive);
        try std.testing.expect(BarLoop.deferred);
        // Posted again, not run, inside the handler.
        try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, c[0]) != null);
        try std.testing.expectEqual(0, app.terminal_loops);
        testPump();
        try std.testing.expect(std.mem.indexOfScalar(*Surface, app.surfaces.items, c[0]) == null);
        if (c[1]) |w| try std.testing.expect(std.mem.indexOfScalar(*Window, app.windows.items, w) == null);
    }
    BarLoop.reset();

    // A point on c's bar and one in its client area, on the screen.
    const c = panes[2];
    const client = try clientRect(c.hwnd);
    var on_bar: win32.POINT = .{ .x = client.right + @divTrunc(ScrollBar.width(c), 2), .y = @divTrunc(client.bottom, 2) };
    _ = win32.ClientToScreen(c.hwnd, &on_bar);
    var in_client: win32.POINT = .{ .x = 10, .y = 10 };
    _ = win32.ClientToScreen(c.hwnd, &in_client);
    try std.testing.expectEqual(@as(win32.LRESULT, win32.HTVSCROLL), win32.SendMessageW(c.hwnd, win32.WM_NCHITTEST, 0, testPoint(on_bar.x, on_bar.y)));

    // A press on the bar, as Windows takes it: its own DefWindowProcW
    // sends the command, SC_HSCROLL for the vertical bar; and a double
    // click there, which a second press soon after the first sends:
    // SC_VSCROLL.
    for ([_]struct { win32.UINT, win32.WPARAM }{
        .{ win32.WM_NCLBUTTONDOWN, win32.SC_HSCROLL | win32.HTVSCROLL },
        .{ win32.WM_NCLBUTTONDBLCLK, win32.SC_VSCROLL | win32.HTVSCROLL },
    }, 1..) |m, n| {
        _ = RealLoop.send(c.hwnd, m[0], win32.HTVSCROLL, testPoint(on_bar.x, on_bar.y));
        try std.testing.expect(!RealLoop.ran);
        try std.testing.expectEqual(n, BarLoop.calls);
        try std.testing.expectEqual(win32.WM_SYSCOMMAND, BarLoop.msg);
        try std.testing.expectEqual(m[1], BarLoop.wparam);
        try std.testing.expectEqual(1, BarLoop.loops);
    }

    // Each way in, its answer the loop's.
    for ([_]struct { win32.UINT, win32.WPARAM, win32.LPARAM }{
        .{ win32.WM_SYSCOMMAND, win32.SC_HSCROLL | win32.HTVSCROLL, testPoint(on_bar.x, on_bar.y) },
        .{ win32.WM_SYSCOMMAND, win32.SC_VSCROLL | win32.HTVSCROLL, testPoint(on_bar.x, on_bar.y) },
        .{ win32.WM_CONTEXTMENU, @intFromPtr(c.hwnd), testPoint(on_bar.x, on_bar.y) },
    }, 3..) |m, n| {
        try std.testing.expectEqual(7, RealLoop.send(c.hwnd, m[0], m[1], m[2]));
        try std.testing.expect(!RealLoop.ran);
        try std.testing.expectEqual(n, BarLoop.calls);
        try std.testing.expectEqual(m[0], BarLoop.msg);
        try std.testing.expectEqual(m[1], BarLoop.wparam);
        try std.testing.expectEqual(1, BarLoop.loops);
        try std.testing.expectEqual(1, BarLoop.depth);
        try std.testing.expectEqual(1, BarLoop.ticked);
        try std.testing.expectEqual(0, app.modal_loop_depth);
        try std.testing.expectEqual(0, app.terminal_loops);
    }
    // None for the menu asked for off the bar.
    _ = win32.SendMessageW(c.hwnd, win32.WM_CONTEXTMENU, @intFromPtr(c.hwnd), testPoint(in_client.x, in_client.y));
    try std.testing.expectEqual(5, BarLoop.calls);
}

test "win32: a terminal's overlays, its search bar and the command palette stay left of its scroll bar" {
    // Each is placed over the terminal's client area, which leaves its bar
    // out (`Overlays.paneRect`, `SearchBar.place`), and the palette in the
    // area under the tab bar less the bar of the terminal along its right
    // edge (`CommandPalette.paletteArea`): none covers the bar, even in a
    // window narrow enough that the palette's margin is less than the
    // bar.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);
    Window.test_set_focus = &FocusSeen.seen;
    defer Window.test_set_focus = null;

    const window = try testFrame(&app);
    testResize(window, 500, 500);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    const pane = try paneClient(window, a);
    const outer = try paneRect(window, a);
    try std.testing.expect(pane.right < outer.right);
    const m = CommandPalette.Metrics.init(Window.dpiOf(&app, window.hwnd));
    try std.testing.expect(m.margin < outer.right - pane.right);

    try std.testing.expect(try testReadOnly(&app, a, .on));
    try std.testing.expect(try testChildExited(&app, a, 0));
    try std.testing.expect(try testKeyTable(&app, a, .{ .activate = "nav" }));
    try std.testing.expect(try app.performAction(.{ .surface = &a.core_surface }, .start_search, .{ .needle = "" }));
    try togglePalette(&app, a);
    // The link preview, at the bottom-right while the pointer is over its
    // place at the bottom-left.
    try std.testing.expect(try testLink(&app, a, "https://example.com/"));
    const client = try clientRect(a.hwnd);
    testPointer(a, 2, client.bottom - 2);
    try expectPreviewAt(window, a, .right);

    const right = [_]win32.HWND{
        a.overlays.readonly.hwnd.?,
        a.overlays.child_exited.hwnd.?,
        a.overlays.link_preview.hwnd.?,
        a.overlays.key_state.hwnd.?,
        a.search_bar.hwnd.?,
        window.palette.hwnd.?,
    };
    for (right) |hwnd| {
        try std.testing.expect(shown(hwnd));
        const at = try childRect(window, hwnd);
        try std.testing.expect(at.right <= pane.right);
        try std.testing.expect(at.left >= pane.left);
    }
    // The banner across the whole of it, the preview to its edge.
    try std.testing.expectEqual(pane.right, (try childRect(window, a.overlays.child_exited.hwnd.?)).right);
    try std.testing.expectEqual(pane.right, (try childRect(window, a.overlays.link_preview.hwnd.?)).right);
}

/// For tests: the colour `hwnd` draws at `x`, `y` of its window rect,
/// its non-client area with it, for WM_PRINT.
fn testPrintedAt(hwnd: win32.HWND, x: i32, y: i32) !win32.COLORREF {
    const r = try windowRect(hwnd);
    const screen = win32.GetDC(null) orelse return error.TestUnexpectedResult;
    defer _ = win32.ReleaseDC(null, screen);
    const dc = win32.CreateCompatibleDC(screen) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteDC(dc);
    const bitmap = win32.CreateCompatibleBitmap(screen, r.right - r.left, r.bottom - r.top) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteObject(bitmap);
    const old = win32.SelectObject(dc, bitmap);
    defer if (old) |o| {
        _ = win32.SelectObject(dc, o);
    };
    _ = win32.SendMessageW(hwnd, win32.WM_PRINT, @intFromPtr(dc), win32.PRF_NONCLIENT);
    return win32.GetPixel(dc, x, y);
}

/// For tests: the brightest of `c`'s red, green and blue.
fn testBrightest(c: win32.COLORREF) u8 {
    return @max(@as(u8, @truncate(c)), @max(@as(u8, @truncate(c >> 8)), @as(u8, @truncate(c >> 16))));
}

test "win32: a terminal's scroll bar takes its frame's dark or light theme" {
    // In a dark frame the bar takes the "DarkMode_Explorer" class, as the
    // command palette's list does, and the system's own in a light one,
    // each way a configuration's `window-theme` turns the frame; its track
    // is drawn dark or light, as WM_PRINT draws it. Its width, and the
    // terminal's, stay.
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    var app: App = undefined;
    try testApp(&app, &core_app);
    try registerClasses(app.hinstance);
    defer unregisterClasses(app.hinstance);
    defer testCleanup(&app);

    const window = try testFrame(&app);
    testResize(window, 400, 300);
    const a = try testPane(&app, window);
    window.tab().tree = try .init(alloc, a);
    window.tab().focused = a;
    window.relayout();
    // The thumb at the top, a page of 1000 rows: the track under it.
    try std.testing.expect(try testRows(&app, a, 1000, 0, 50));
    const widths = try testWidths(window, a);
    const outer = try paneRect(window, a);
    const x = widths[1] + @divTrunc(ScrollBar.width(a), 2);
    const y = @divTrunc((outer.bottom - outer.top) * 3, 4);

    for ([_]configpkg.Config.WindowTheme{ .dark, .light, .dark }) |theme| {
        var changed: Config = try .default(alloc);
        defer changed.deinit();
        changed.@"window-theme" = theme;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &changed }));
        try std.testing.expectEqual(theme == .dark, window.dark_frame);
        const track = try testPrintedAt(a.hwnd, x, y);
        if (theme == .dark) {
            try std.testing.expect(testBrightest(track) < 0x40);
        } else {
            try std.testing.expect(testBrightest(track) > 0xC0);
        }
        try std.testing.expectEqual(widths, try testWidths(window, a));
    }
}
