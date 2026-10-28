const std = @import("std");
const builtin = @import("builtin");

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const win32 = @import("win32.zig");
const L = win32.L;
const surface_class_name = @import("App.zig").surface_class_name;
const WM_GHOSTTY_WAKEUP = @import("App.zig").WM_GHOSTTY_WAKEUP;
const WM_GHOSTTY_DESTROY = @import("App.zig").WM_GHOSTTY_DESTROY;
const WM_GHOSTTY_LINK_REFUSED = @import("App.zig").WM_GHOSTTY_LINK_REFUSED;
const App = @import("App.zig").App;
const postTeardown = @import("App.zig").postTeardown;
const Window = @import("Window.zig");
const taskbar = @import("taskbar.zig");
const DesktopNotifications = @import("desktop_notifications.zig");
const SearchBar = @import("SearchBar.zig");
const LinkPreview = @import("LinkPreview.zig");
const Overlays = @import("Overlays.zig");
const Dividers = @import("Dividers.zig");
const currentMods = @import("key.zig").currentMods;
const isAltGrFakeCtrl = @import("key.zig").isAltGrFakeCtrl;
const keyAction = @import("key.zig").keyAction;
const scanCode = @import("key.zig").scanCode;
const keyFromScan = @import("key.zig").keyFromScan;
const numpadKey = @import("key.zig").numpadKey;
const isWindowMenuKey = @import("key.zig").isWindowMenuKey;
const isAltNumpad = @import("key.zig").isAltNumpad;
const unshiftedCodepoint = @import("key.zig").unshiftedCodepoint;
const shiftlessCodepoint = @import("key.zig").shiftlessCodepoint;
const inputLanguage = @import("key.zig").inputLanguage;
const text_mime = @import("clipboard.zig").text_mime;
const readClipboardText = @import("clipboard.zig").readClipboardText;
const writeClipboardText = @import("clipboard.zig").writeClipboardText;
const utf8FromWide = @import("clipboard.zig").utf8FromWide;
const clipboardReadPrompt = @import("clipboard.zig").clipboardReadPrompt;
const confirm = @import("dialog.zig").confirm;
const notice = @import("dialog.zig").notice;

const log = std.log.scoped(.win32);

/// The WM_TIMER that removes a progress report no newer one followed
/// (`reportProgress`).
pub const progress_timer_id: win32.UINT_PTR = 1;

/// How long a progress report shows with no newer one: GTK's 15 seconds.
const progress_timeout_ms: u32 = 15 * std.time.ms_per_s;

pub const Surface = struct {
    app: *App,

    /// The core surface, embedded by value because the core requires
    /// `core()` to return `&self.core_surface` and because
    /// `apprt.Target.cval` round-trips through `rt_surface`.
    ///
    /// Initialized only while `core_state != .none`; see `CoreState`. Use
    /// `liveCore` from message handlers rather than this field directly.
    core_surface: CoreSurface,

    core_state: CoreState,

    /// The window this terminal is in. It outlives the surface: the
    /// frame's child windows are destroyed before its WM_NCDESTROY frees it.
    window: *Window,

    /// The terminal's own window, a child filling the frame's client area.
    /// Written from WM_NCCREATE, which is the first message this window
    /// receives, so it is valid in every other handler.
    hwnd: win32.HWND,

    /// The current window title, owned by this struct. `getTitle` reads it
    /// back to answer CSI 21 t; a native runtime has to store it itself.
    title: ?[:0]u8,

    /// The title the user gave the terminal in its title prompt
    /// (`TitleDialog`), shown in place of `title` wherever the terminal's
    /// title shows (`effectiveTitle`), as GTK's `title_override`; null for
    /// none. Owned by this struct. A title the program sets meanwhile
    /// changes `title` only, and shows once this is cleared.
    title_override: ?[:0]u8,

    /// The client size the core asked for through `.initial_size`, or null
    /// when `window-width`/`window-height` are unset. The core divides the
    /// cell area by the content scale but adds the padding in device pixels
    /// (`CoreSurface.recomputeInitialSize`), so the value is not purely in
    /// 96-DPI units; see `Window.applyInitialSize`. `Window.show` applies it.
    initial_size: ?apprt.action.InitialSize,

    /// A close of this terminal alone has been requested and
    /// WM_GHOSTTY_DESTROY posted (or its confirmation is on screen): a
    /// close_surface binding, its shell exiting, or a WM_CLOSE sent to its
    /// own window. Stops a second one from prompting or posting twice.
    /// Cleared when the user declines the confirmation, the post fails, or
    /// it cannot leave its window (`destroy`). Closing the whole window
    /// does not use it (`Window.closing`).
    closing: bool,

    /// WM_GHOSTTY_DESTROY arrived while teardown was not allowed
    /// (`App.canReenterCore` was false, or another surface's teardown was
    /// running, `App.teardown_depth`). It is re-posted by
    /// `App.repostDeferredDestroys`.
    destroy_deferred: bool,

    /// Who put the text that is in the core's preedit slot: a dead key
    /// (`keyEvent`) or an IME composition. The core has one slot, keeps no
    /// owner and never clears it itself (`Surface.preeditCallback`), so each
    /// source must only clear what it set. Written by `setPreedit` alone.
    preedit: Ime.Preedit,

    ime: Ime,

    /// A high surrogate that ended the last character text, kept for the
    /// low surrogate the next one starts with. SendInput with
    /// KEYEVENTF_UNICODE sends a character outside the BMP as one
    /// VK_PACKET keystroke per UTF-16 unit, and TranslateMessage posts one
    /// WM_CHAR for each, so the halves arrive with separate keystrokes.
    /// See `Text.finish`.
    high_surrogate: ?u16,

    /// Keys whose last press was AltGr's, by `Ime.scanSlot`. See
    /// `altGrKey`.
    alt_gr: std.bit_set.Static(512),

    /// See `ShiftKeys`.
    shift: ShiftKeys,

    /// Keyboard focus, from WM_SETFOCUS / WM_KILLFOCUS. See `mouseMods`.
    focused: bool,

    /// Mouse state, and what the core is still owed. See `Mouse`.
    mouse: Mouse,

    /// The progress the terminal's program last reported (OSC 9;4), shown
    /// on its window's taskbar button while it has the window's focus
    /// (`reportProgress`, `Window.showProgress`).
    progress: taskbar.Progress,

    /// When `progress` lapses with no newer report, in GetTickCount64's
    /// milliseconds (`progressTimer`).
    progress_expires: u64,

    /// The terminal's toasts (`notify`).
    notifications: DesktopNotifications,

    /// The terminal's search bar (`SearchBar`), a window of the frame's
    /// over this one's top-right corner once `start_search` opened it.
    search_bar: SearchBar.Bar,

    /// The terminal's overlays (`Overlays`), windows of the frame's just
    /// above this one that show something about it and take no input but
    /// on the child-exited banner's button: its link preview, made, hidden,
    /// with this one, and its key-state indicator, read-only badge and
    /// child-exited banner, made the first time they have something to
    /// show.
    overlays: Overlays,

    /// The lifecycle of `core_surface`.
    ///
    /// A three-state enum rather than a single `initialized` flag because
    /// teardown pumps messages (`App.waitForThread`): between
    /// `deleteSurface` and `CoreSurface.deinit` the core surface is still
    /// initialized memory, but its threads are stopping and the app no longer
    /// knows it, so message handlers must not call into it. `.stopping` makes
    /// that state distinct instead of an implied combination of flags.
    const CoreState = enum {
        /// `core_surface` is undefined memory: before `CoreSurface.init` in
        /// `create`, or after `CoreSurface.deinit` in `stopCore`.
        none,
        /// Initialized and registered with the core app. Callbacks allowed.
        live,
        /// `stopCore` is running. Initialized, not registered, no callbacks.
        stopping,
    };

    /// IME composition state and the decisions that need no window.
    ///
    /// The composition string is drawn by the core as preedit, so the
    /// runtime consumes WM_IME_COMPOSITION instead of letting DefWindowProcW
    /// translate it: the result string is then read exactly once here, and
    /// no WM_IME_CHAR or WM_CHAR is ever generated from it.
    const Ime = struct {
        /// Between WM_IME_STARTCOMPOSITION (or the first composition
        /// string) and WM_IME_ENDCOMPOSITION. It decides whether a
        /// composition has to be ended on focus loss and whether an `.ime`
        /// preedit is stale. It never decides whether a result is
        /// delivered: Korean IMEs can send the last result after the end.
        composing: bool = false,

        /// The forms last given to the IME, or null to issue them again.
        /// Each Imm call sends WM_IME_NOTIFY back into the window
        /// procedure, so unchanged forms are not sent again.
        form: ?Form = null,

        /// Result text, as UTF-8, that arrived while the core could not be
        /// entered (`imeCore`). `flushIme` delivers it before any later
        /// input. Owned; freed in `stopCore` and `deinit`.
        pending: std.ArrayListUnmanaged(u8) = .empty,

        /// Keys whose key-down the core never saw, by `scanSlot`: the IME
        /// claimed it (VK_PROCESSKEY), it was a digit of Alt+numpad entry
        /// (`isAltNumpad`), it opened the window menu
        /// (`isWindowMenuKey`), it arrived while a prompt was open
        /// (`App.canReenterCore`), or it went to a title prompt that it
        /// closed (`withholdKeyUp`). Their key-up is kept from the core as
        /// well.
        swallow_up: std.bit_set.Static(512) = .empty,

        const Preedit = enum {
            none,
            dead_key,
            ime,

            /// Whether committed text replaces this preedit. Any preedit
            /// does, as in GTK (src/apprt/gtk/class/surface.zig imCommit):
            /// a dead key's accent is not left drawn after the IME's text.
            fn clearedByCommit(self: Preedit) bool {
                return self != .none;
            }
        };

        const Action = enum {
            /// preeditCallback(null).
            clear_preedit,
            /// Read GCS_RESULTSTR and send it to the core as text.
            commit_result,
            /// Read GCS_RESULTSTR and keep it in `pending`.
            defer_result,
            /// Read GCS_COMPSTR: show it as the preedit, or clear the
            /// preedit if it is empty.
            update_preedit,
        };

        const Plan = struct {
            buf: [3]Action = undefined,
            len: usize = 0,

            fn add(self: *Plan, action: Action) void {
                self.buf[self.len] = action;
                self.len += 1;
            }

            fn actions(self: *const Plan) []const Action {
                return self.buf[0..self.len];
            }
        };

        /// What a WM_IME_COMPOSITION asks for, in order. `bits` is its
        /// lParam, `owner` the current preedit owner, and `core_safe`
        /// whether the core may be entered (`imeCore`).
        ///
        /// `composing` is deliberately not an input: a result is delivered
        /// whether or not a composition is thought to be open.
        ///
        /// Only a message with no GCS flag at all is a cancellation. One
        /// with other flags but neither string flag (a caret or clause
        /// change) is a live update, and IMEs are known to misreport
        /// GCS_COMPSTR, so the string is read again for every message that
        /// is not a bare result, as Firefox and WezTerm do.
        fn plan(bits: u32, owner: Preedit, core_safe: bool) Plan {
            var p: Plan = .{};
            const gcs = bits & win32.GCS_ALL;
            if (gcs == 0) {
                if (core_safe and owner == .ime) p.add(.clear_preedit);
                return p;
            }

            // The result first: it precedes the composition string that
            // may follow it in the same message (Korean commits a syllable
            // and starts the next one at once).
            const result = gcs & win32.GCS_RESULTSTR != 0;
            if (result) {
                if (core_safe) {
                    if (owner.clearedByCommit()) p.add(.clear_preedit);
                    p.add(.commit_result);
                } else {
                    p.add(.defer_result);
                }
            }

            // Without the core the composition string is dropped: the
            // window has lost the focus to a prompt, and the next update
            // after it shows the string again.
            const bare_result = result and gcs & win32.GCS_COMPSTR == 0;
            if (!bare_result and core_safe) p.add(.update_preedit);
            return p;
        }

        const Form = struct {
            /// Bottom-left of the cursor cell, for the composition form: an
            /// IME that anchors its candidate list there opens it below the
            /// row (winit does the same).
            pt: win32.POINT,
            /// The cells of the preedit, for the candidate form: the list
            /// must not cover them.
            rc: win32.RECT,
        };

        /// The forms for the core's IME position. `pos` is in 96-DPI
        /// pixels except for its width, which the core leaves in physical
        /// pixels (`Surface.imePoint`); `scale` is `getContentScale` and
        /// `client` the client rectangle, in physical pixels like the
        /// result. Clamping guards against rounding and against a client
        /// size the core has not caught up with yet.
        fn formFor(pos: apprt.IMEPos, scale: f64, cell_w: u32, client: win32.RECT) Form {
            const cw: f64 = @floatFromInt(cell_w);
            // The core reports the middle of the cursor cell and its bottom.
            const left = @round(pos.x * scale - cw / 2);
            const bottom = @round(pos.y * scale);
            const top = bottom - @round(pos.height * scale);
            const right = left + @max(@round(pos.width), cw);
            // Never inverted, whatever the core reports.
            const l = clampLong(left, client.left, client.right);
            const b = clampLong(bottom, client.top, client.bottom);
            const rc: win32.RECT = .{
                .left = l,
                .top = @min(b, clampLong(top, client.top, client.bottom)),
                .right = @max(l, clampLong(right, client.left, client.right)),
                .bottom = b,
            };
            return .{ .pt = .{ .x = rc.left, .y = rc.bottom }, .rc = rc };
        }

        fn clampLong(v: f64, lo: win32.LONG, hi: win32.LONG) win32.LONG {
            // Written so that NaN takes the first branch.
            if (!(v > @as(f64, @floatFromInt(lo)))) return lo;
            if (v >= @as(f64, @floatFromInt(hi))) return hi;
            return @intFromFloat(v);
        }

        /// A key message's scan code and extended-key flag (lParam bits
        /// 16-24), which identify the physical key on both its messages.
        fn scanSlot(lparam: win32.LPARAM) usize {
            return (@as(usize, @bitCast(lparam)) >> 16) & 0x1FF;
        }

        /// WM_IME_SETCONTEXT's lParam without the request to show the
        /// IME's composition window. The flag is bit 31 of a value that
        /// arrives sign-extended.
        fn setContextLparam(lparam: win32.LPARAM) win32.LPARAM {
            return @bitCast(@as(usize, @bitCast(lparam)) & ~win32.ISC_SHOWUICOMPOSITIONWINDOW);
        }

        const KeyFilter = enum {
            /// Not for the core: an IME-owned keystroke (VK_PROCESSKEY), or
            /// the release of a press the core never saw. A release
            /// without a press would be reported to programs that ask for
            /// key releases.
            withhold,
            /// For the core.
            deliver,
            /// For the core, but the key's previous press was withheld
            /// (`isAltNumpad` decides a repeat from that).
            deliver_withheld,
        };

        /// Whether a key message reaches the core, given `swallow_up`.
        /// The IME claims a keystroke by sending its key-down as
        /// VK_PROCESSKEY; the key-up may come with the real virtual key, so
        /// it is matched by `scanSlot`. A VK_PROCESSKEY key-up leaves the
        /// slot set, and the key's next key-down clears it.
        fn filterKey(
            self: *Ime,
            msg: win32.UINT,
            wparam: win32.WPARAM,
            lparam: win32.LPARAM,
        ) KeyFilter {
            const slot = scanSlot(lparam);
            if (wparam == win32.VK_PROCESSKEY) {
                if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) self.swallow_up.set(slot);
                return .withhold;
            }
            if (!self.swallow_up.isSet(slot)) return .deliver;
            self.swallow_up.unset(slot);
            return if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP)
                .withhold
            else
                .deliver_withheld;
        }

        /// How a composition still open when the window loses the focus
        /// is ended (`syncIme`), for input language `lang`. Korean is
        /// completed, because a Hangul composition string is text the
        /// user already sees as typed, with no conversion step to confirm;
        /// other languages are cancelled, so that half-converted text does
        /// not reach a shell the user is no longer looking at.
        fn focusLossAction(lang: u16) win32.DWORD {
            return if (win32.primaryLangId(lang) == win32.LANG_KOREAN)
                win32.CPS_COMPLETE
            else
                win32.CPS_CANCEL;
        }
    };

    /// What the core has been told about the mouse.
    ///
    /// Invariants:
    ///   * `held`: buttons the core has seen pressed and not released. Only
    ///     non-empty after this window asked for the capture (`mouseButton`).
    ///   * `owed`: disjoint from `held`. Buttons that are no longer down, or
    ///     whose release may not come here, while the core still has them
    ///     pressed. Only `syncMouse` delivers it; `stopCore` discards it with
    ///     the core.
    ///   * `pos`: the last position given to cursorPosCallback, or
    ///     `outside`. `getCursorPos` returns it.
    pub const Mouse = struct {
        pos: apprt.CursorPos,
        held: Button.Set,
        owed: Button.Set,
        /// A WM_MOUSELEAVE the core has not been told about.
        leave_owed: bool,
        /// TrackMouseEvent(TME_LEAVE) is armed.
        tracking: bool,
        /// Where the left button last went down. `syncMouse` places a
        /// release it has to invent away from it.
        left_press_pos: apprt.CursorPos,
        wheel_x: Notches,
        wheel_y: Notches,
        /// The last `.mouse_shape` and its stock cursor, applied in
        /// WM_SETCURSOR. `cursor` is null only if LoadCursorW failed; the
        /// class arrow shows then.
        shape: terminal.MouseShape,
        cursor: ?win32.HCURSOR,
        /// `.mouse_visibility`: hidden while typing.
        hidden: bool,

        /// "Not over the surface" to cursorPosCallback and link hover, which
        /// treat any negative coordinate that way
        /// (`Surface.cursorPosCallback`, `Surface.mouseRefreshLinks`). Paths
        /// that map a position to a cell clamp it to the nearest cell
        /// instead (the `.grid` arm of `renderer.size.Coordinate.convert`).
        const outside: apprt.CursorPos = .{ .x = -1, .y = -1 };

        pub fn init() Mouse {
            return .{
                .pos = outside,
                .held = .empty,
                .owed = .empty,
                .leave_owed = false,
                .tracking = false,
                .left_press_pos = outside,
                .wheel_x = .{},
                .wheel_y = .{},
                // The core starts at `.text` and never sends that first
                // shape (`Terminal.mouse_shape`); the GTK runtime
                // starts there too.
                .shape = .text,
                .cursor = win32.LoadCursorW(null, cursorId(.text)),
                .hidden = false,
            };
        }

        /// What `syncMouse` sends the core, from `sync`.
        const Sync = struct {
            /// Releases to send at `releasePoint`.
            release: Button.Set = .empty,
            /// The last held button is now owed while this window still has
            /// the capture, so the capture is released.
            release_capture: bool = false,
            /// A leave, after the releases.
            leave: bool = false,
        };

        /// Take what the core is owed (`syncMouse`). `captured` is whether
        /// this window has the mouse capture, and `down` the buttons the
        /// current message reports down, or null without a message.
        ///
        /// A held button is owed its release once the capture is gone or
        /// `down` says it is up. A leave follows the releases only when no
        /// button is still held, since a position outside would drag to an
        /// edge cell; with no release to send, only an owed leave is sent.
        fn sync(self: *Mouse, captured: bool, down: ?Button.Set) Sync {
            var result: Sync = .{};
            if (self.held.count() != 0) {
                const gone = if (!captured)
                    self.held
                else if (down) |d|
                    self.held.differenceWith(d)
                else
                    Button.Set.empty;
                if (gone.count() != 0) {
                    self.owed.setUnion(gone);
                    self.held = self.held.differenceWith(gone);
                    result.release_capture = captured and self.held.count() == 0;
                }
            }

            result.release = self.owed;
            self.owed = .empty;
            result.leave = if (result.release.count() != 0)
                self.held.count() == 0
            else
                self.leave_owed;
            if (result.leave) self.leave_owed = false;
            return result;
        }

        /// The buttons this runtime reports: a separate enum from
        /// input.MouseButton, so nothing else can be sent.
        ///   * `.unknown` would mask motion reports;
        ///   * `.four`-`.seven` are the wheel, which scrollCallback reports;
        ///   * `.eleven` indexes past the end of the core's click_state
        ///     (`CoreSurface.Mouse.click_state`, indexed in
        ///     `Surface.mouseButtonCallback`).
        /// The last point is checked at comptime at the end of the file.
        pub const Button = enum {
            left,
            right,
            middle,
            x1,
            x2,

            const Set = std.EnumSet(Button);

            fn fromMessage(msg: win32.UINT, wparam: win32.WPARAM) ?Button {
                return switch (msg) {
                    win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
                    win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .right,
                    win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => .middle,
                    // GET_XBUTTON_WPARAM. Any other value is left to
                    // DefWindowProcW.
                    win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => switch (win32.hiword(wparam)) {
                        win32.XBUTTON1 => .x1,
                        win32.XBUTTON2 => .x2,
                        else => null,
                    },
                    else => null,
                };
            }

            /// The buttons a mouse message's wParam reports as down.
            fn downIn(wparam: win32.WPARAM) Set {
                var set: Set = .empty;
                if (wparam & win32.MK_LBUTTON != 0) set.insert(.left);
                if (wparam & win32.MK_RBUTTON != 0) set.insert(.right);
                if (wparam & win32.MK_MBUTTON != 0) set.insert(.middle);
                if (wparam & win32.MK_XBUTTON1 != 0) set.insert(.x1);
                if (wparam & win32.MK_XBUTTON2 != 0) set.insert(.x2);
                return set;
            }

            /// Back and forward are X11 buttons 8 and 9, as GTK and macOS
            /// map them.
            pub fn core(self: Button) input.MouseButton {
                return switch (self) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    .x1 => .eight,
                    .x2 => .nine,
                };
            }
        };

        /// Whole core scroll ticks out of wheel deltas.
        ///
        /// A notch (WHEEL_DELTA) scrolls the system's lines per notch, or
        /// characters per notch for the horizontal wheel (`wheelSetting`).
        /// Windows' default of 3 is one tick, which the default
        /// mouse-scroll-multiplier also scrolls as 3 rows
        /// (`Surface.scrollCallback`), and other settings scale the ticks:
        /// 6 is two ticks a notch, 1 is one tick every third notch.
        ///
        /// The core cannot take fractions of a tick
        /// (`Surface.scrollCallback`): for x it rounds each event and keeps
        /// no remainder, and for y it drops the remainder whenever an event
        /// crosses a row (it stores `poff - amount * cell_size` with the
        /// untruncated `amount`). A high-resolution wheel's small deltas, and
        /// settings that are not a multiple of 3, would lose rows either
        /// way, so only whole ticks are passed on. A change of direction
        /// drops the remainder, so a reversal counts from its own first
        /// delta.
        const Notches = struct {
            /// In 1/WHEEL_DELTA of a line (or character).
            rem: i64 = 0,

            /// Windows' default lines and characters per notch.
            const per_tick = 3;

            fn add(self: *Notches, delta: i32, per_notch: u32) ?i64 {
                if (delta == 0 or per_notch == 0) return null;
                if (self.rem != 0 and (self.rem < 0) != (delta < 0)) self.rem = 0;
                self.rem += @as(i64, delta) * per_notch;
                const tick = win32.WHEEL_DELTA * per_tick;
                const whole = @divTrunc(self.rem, tick);
                if (whole == 0) return null;
                self.rem -= whole * tick;
                return whole;
            }
        };
    };

    /// What a new window takes from the window it was asked from.
    /// Both are taken from the asking window, as on macOS
    /// (`newSurfaceOptions` in src/apprt/embedded.zig), rather than from
    /// whichever surface had the focus when `run` created the window.
    pub const Options = struct {
        /// The font size in points to use instead of the configured one,
        /// with `window-inherit-font-size`, for a window and a split alike
        /// (`App.inheritedOptions`). Null for the configured size.
        font_size: ?f32 = null,

        /// The working directory to use instead of the one
        /// `apprt.surface.newConfig` chose, with
        /// `window-inherit-working-directory` or
        /// `split-inherit-working-directory` as `context` says; see
        /// `inheritWorkingDirectory`. Borrowed for the duration of
        /// `create`. Null keeps newConfig's.
        working_directory: ?[]const u8 = null,

        /// What the terminal is opened as, for `apprt.surface.newConfig`.
        context: apprt.surface.NewSurfaceContext = .window,
    };

    /// Heap-allocate and initialize, including the core surface, as a child
    /// window of `window` at `rect` in its client area, the size the core
    /// starts at. The address must be stable: the core stores raw
    /// `*apprt.Surface` pointers (see `CoreSurface.init`), and the wndproc
    /// recovers this pointer from GWLP_USERDATA. The terminal's window is
    /// created hidden; `Window.create`, `Window.showPane` and, for a new
    /// tab, `Window.selectTab` show it. `rect` should not be empty: a minimized
    /// frame's client area is, so a split or a tab made then takes the
    /// place its tab's terminals keep (`Window.layoutArea`).
    pub fn create(app: *App, window: *Window, rect: win32.RECT, opts: Options) !*Surface {
        const alloc = app.core_app.alloc;
        const self = try alloc.create(Surface);
        errdefer alloc.destroy(self);

        self.* = .{
            .app = app,
            .window = window,
            .core_surface = undefined,
            .core_state = .none,
            // `hwnd` is written from WM_NCCREATE, the first message this
            // window receives, so it is set before anything can read it.
            .hwnd = undefined,
            .title = null,
            .title_override = null,
            .initial_size = null,
            .closing = false,
            .destroy_deferred = false,
            .preedit = .none,
            .ime = .{},
            .high_surrogate = null,
            .alt_gr = .empty,
            .shift = .{},
            .focused = false,
            .mouse = .init(),
            .progress = .{},
            .progress_expires = 0,
            .notifications = .{},
            .search_bar = .{},
            .overlays = .{},
        };

        const hwnd = win32.CreateWindowExW(
            0,
            L(surface_class_name),
            null,
            win32.WS_CHILD | win32.WS_CLIPSIBLINGS,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            window.hwnd,
            null,
            app.hinstance,
            self,
        ) orelse {
            log.err("CreateWindowExW failed for a surface window", .{});
            return App.Error.Win32WindowCreationFailed;
        };
        // Safe alongside the errdefer above only because of the ownership
        // invariant on App.surfaceDestroyed: WM_DESTROY reenters the app but
        // will not free a surface that is not yet in App.surfaces.
        errdefer _ = win32.DestroyWindow(hwnd);

        // Its link preview, hidden, so that no window is made as the
        // pointer reaches a link (`LinkPreview`).
        Overlays.create(self);
        errdefer self.overlays.destroy();

        // Registration comes before init: every surface message the core
        // routes is checked with `CoreApp.hasSurface`, so a
        // message queued before registration would be dropped. addSurface
        // also cancels the startup quit timer.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Preconditions CoreSurface.init relies on, both true here: the HWND
        // exists at its place in the frame, the client area of a frame
        // created at CW_USEDEFAULT size for a window's first terminal, and
        // at least a cell across for a split (`Window.split`), so getSize
        // is non-zero (`CoreSurface.init` reads it), and getContentScale
        // works on it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();
        if (opts.working_directory) |wd| inheritWorkingDirectory(&config, wd);
        // A failing CoreSurface.init joins any thread it started (unpumped,
        // as CoreSurface.deinit does), so the errdefers above run with no
        // core thread left using this surface or its window.
        try self.core_surface.init(alloc, &config, app.core_app, app, self);

        // Nothing below can fail, so the core surface needs no errdefer.
        errdefer comptime unreachable;
        self.core_state = .live;
        self.notifications.id = self.core_surface.id;

        // An inherited font size is applied after init, as the macOS
        // runtime does, so that `reset_font_size` still goes back to the
        // configured size (`original_font_size`). Before the window is
        // sized (`Window.show`): the cell size it changes makes the core
        // send `.initial_size` again (`CoreSurface.setCellSize`). A failure
        // leaves the configured size.
        if (opts.font_size) |points| {
            var size = self.core_surface.font_size;
            size.points = points;
            self.core_surface.setFontSize(size) catch |err|
                log.warn("unable to apply the inherited font size err={}", .{err});
        }

        return self;
    }

    /// Make `wd`, the asking terminal's working directory, the new one's,
    /// as the macOS runtime does (`Surface.init` in src/apprt/embedded.zig):
    /// only an absolute path to an existing directory, otherwise the
    /// directory `config` already names is kept.
    ///
    /// Reachable today: a surface's working directory starts as its
    /// subprocess's (src/termio/Exec.zig, `term.setPwd(cwd)`), which comes
    /// from `working-directory` and may be relative. A relative one is not
    /// resolved here, since this process's cwd is not the shell's, and
    /// `openDirAbsolute` asserts an absolute path.
    fn inheritWorkingDirectory(config: *configpkg.Config, wd: []const u8) void {
        if (wd.len == 0) return;
        if (!std.fs.path.isAbsolute(wd)) {
            log.warn("the inherited working directory is not absolute dir={s}", .{wd});
            return;
        }
        var dir = std.Io.Dir.openDirAbsolute(global.io(), wd, .{}) catch |err| {
            log.warn("cannot open the inherited working directory dir={s} err={}", .{ wd, err });
            return;
        };
        defer dir.close(global.io());
        const stat = dir.stat(global.io()) catch |err| {
            log.warn("cannot stat the inherited working directory dir={s} err={}", .{ wd, err });
            return;
        };
        if (stat.kind != .directory) {
            log.warn("the inherited working directory is not a directory dir={s}", .{wd});
            return;
        }
        var value: configpkg.WorkingDirectory = .{ .path = wd };
        value.finalize(config.arenaAlloc()) catch |err| {
            log.warn("cannot finalize the inherited working directory err={}", .{err});
            return;
        };
        config.@"working-directory" = value;
    }

    /// Release everything except the window and the allocation itself.
    ///
    /// Public because `CoreApp.deinit` calls it on every surface the core
    /// still tracks -- an apprt contract method the rt_surface list does not
    /// name. Like the embedded runtime's deinit, this removes the surface
    /// from that list while the core iterates it (stopCore's
    /// `deleteSurface`). In this runtime the list is empty by then, since
    /// `App.terminate` destroys every surface first.
    pub fn deinit(self: *Surface) void {
        self.stopCore();
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.title = null;
        if (self.title_override) |v| self.app.core_app.alloc.free(v);
        self.title_override = null;
        self.ime.pending.clearAndFree(self.app.core_app.alloc);
        self.notifications.deinit(self.app.core_app.alloc);
        self.search_bar.deinit();
        self.overlays.deinit(self.app.core_app.alloc);
    }

    /// Stop the core surface and destroy its window. The last terminal in a
    /// window takes the window with it (`Window.destroy`); any other leaves
    /// the window first (`Window.removePane`). Returns whether it was
    /// destroyed; **when it was, `self` has been freed** (WM_DESTROY ->
    /// App.surfaceDestroyed), and so has a window that went with it
    /// (WM_NCDESTROY -> App.windowDestroyed), and nothing may touch either.
    ///
    /// When it cannot leave the window (out of memory), nothing is done and
    /// the close can be asked for again.
    pub fn destroy(self: *Surface) bool {
        const window = self.window;
        if (window.find(self)) |at| {
            const t = window.tabs.items[at.index];
            if (at.handle != .root) {
                window.removePane(t, at.handle) catch |err| {
                    log.err("unable to take a closing terminal out of its window err={}", .{err});
                    self.closing = false;
                    return false;
                };
            } else if (window.tabs.items.len == 1) {
                // The window's last terminal takes it with it.
                return window.destroy();
            } else {
                // A tab's last terminal takes the tab with it.
                window.removeTab(t);
            }
        }
        // Its search bar and overlays, windows of the frame's, go with it,
        // before its core stops: nothing shows them, nor is clicked,
        // meanwhile.
        self.search_bar.destroy();
        self.overlays.destroy();
        self.stopCore();
        return win32.DestroyWindow(self.hwnd).toBool();
    }

    /// Undo a `create` that succeeded, for a terminal no window holds yet:
    /// stop its core, destroy its window and its overlays', and free it.
    /// Its window's WM_DESTROY frees nothing, as it is not in
    /// `App.surfaces`.
    pub fn discard(self: *Surface) void {
        const alloc = self.app.core_app.alloc;
        self.overlays.destroy();
        self.stopCore();
        _ = win32.DestroyWindow(self.hwnd);
        self.deinit();
        alloc.destroy(self);
    }

    /// `Window.Tree` holds its terminals by pointer and counts no
    /// references: a terminal is owned by `App.surfaces`, and leaves the
    /// tree before it is freed (see Window.zig).
    pub fn ref(self: *Surface) *Surface {
        return self;
    }

    /// See `ref`.
    pub fn unref(self: *Surface) void {
        _ = self;
    }

    /// The key whose key-down message had `lparam` was pressed in another
    /// window, which closed and left the keyboard focus here
    /// (`TitleDialog.closedByKey`): its key-up is withheld from the core,
    /// as one whose press the IME took (`Ime.swallow_up`).
    pub fn withholdKeyUp(self: *Surface, lparam: win32.LPARAM) void {
        self.ime.swallow_up.set(Ime.scanSlot(lparam));
    }

    /// The core surface, if message handlers may call into it.
    pub fn liveCore(self: *Surface) ?*CoreSurface {
        return switch (self.core_state) {
            .live => &self.core_surface,
            .none, .stopping => null,
        };
    }

    /// Stop and deinitialize the core surface, keeping the main thread
    /// responsive while its threads wind down. A no-op unless `.live`.
    ///
    /// The order is load-bearing:
    ///
    ///   1. `detachCore` first: `deleteSurface`, so the ticks in steps 2-4
    ///      drop any message still addressed to this surface instead of
    ///      calling into it (`CoreApp.hasSurface`), which also starts the quit
    ///      timer when this was the last surface; and what still waits on it
    ///      forgets it (`App.forgetClosing`).
    ///   2. Stop the search thread, if any, and wait for it as in step 3,
    ///      while the render thread is still draining its mailbox.
    ///      `CoreSurface.deinit` would do this first too, but with an
    ///      unpumped join, and by then the render thread is gone. The search
    ///      thread pushes with `.forever` into both the renderer mailbox and
    ///      the app mailbox (`Surface.searchCallback_`, including the `.quit`
    ///      event it sends on exit), and only a tick on this thread drains the
    ///      app mailbox, which the still running IO thread can keep full.
    ///      Clearing `search` makes deinit skip it.
    ///   3. Stop the IO thread and wait for it (`App.waitForThread`, which
    ///      pumps messages and ticks), still before the renderer. Its reader
    ///      can also block on a `.forever` renderer mailbox push
    ///      (`StreamHandler.rendererMessageWriter`), and `Exec.threadExit`
    ///      cannot cancel a thread that is not in I/O. Upstream
    ///      `CoreSurface.deinit` stops the renderer first; this order is
    ///      deliberately the reverse. Nothing the render thread does waits on
    ///      the IO thread (it only pushes to the app mailbox, which the ticks
    ///      drain), and the terminal state both share is freed only in step 5.
    ///   4. Stop the render thread and wait for it the same way. Its exit
    ///      marks the display unrealized and releases the shaders and the
    ///      swap chain (`threadExit` in src/renderer/generic.zig), so no
    ///      unrealize is needed first.
    ///   5. `CoreSurface.deinit`. Its notifications repeat harmlessly (an
    ///      xev Async notify on a stopped loop only posts an unread
    ///      completion) and its joins return at once.
    ///
    /// Steps 2-4 reach into CoreSurface fields rather than adding a core
    /// API. That duplicates a few statements of `CoreSurface.deinit`, which
    /// is the least invasive option: the alternative, joining inside deinit
    /// on the main thread, is exactly the unpumped wait steps 2-4 exist to
    /// avoid. If those fields are renamed this stops compiling, which is the
    /// desired failure.
    pub fn stopCore(self: *Surface) void {
        if (self.core_state != .live) return;
        self.core_state = .stopping;

        // Counted for the whole teardown, the waits included: they pump
        // messages, and destroyPosted defers any other teardown dispatched
        // meanwhile.
        self.app.teardown_depth += 1;
        defer self.app.teardown_depth -= 1;

        // A drag in progress ends with the core. Button messages for a
        // `.stopping` surface are not handled, so nothing else would release
        // the capture while this pumps messages (App.waitForThread).
        if (self.mouse.held.count() != 0) {
            self.mouse.held = .empty;
            if (self.hasCapture()) _ = win32.ReleaseCapture();
        }
        self.mouse.owed = .empty;
        self.mouse.leave_owed = false;

        // No mouse event reaches the core from here on, so the core cannot
        // show a pointer it hid while typing; WM_SETCURSOR would keep it
        // hidden over the window for the rest of the teardown.
        self.mouse.hidden = false;
        self.applyCursor();

        // A composition ends with the core too: nothing is left to draw its
        // preedit or to take its result. The IME is not told; the window is
        // about to be destroyed, and ImmNotifyIME would send its messages
        // back into this teardown.
        self.ime.pending.clearAndFree(self.app.core_app.alloc);
        self.ime.composing = false;
        self.ime.form = null;
        self.preedit = .none;

        const app = self.app;
        const cs = &self.core_surface;

        self.detachCore();

        if (cs.search) |*s| {
            s.state.stop.notify() catch |err|
                log.err("error notifying search thread to stop err={}", .{err});
            app.waitForThread(s.thread.getHandle());

            // The thread has exited, so the join in deinit returns at once
            // and its repeated notify only posts an unread completion.
            s.deinit();
            cs.search = null;
        }

        cs.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop err={}", .{err});
        app.waitForThread(cs.io_thr.getHandle());

        cs.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop err={}", .{err});
        app.waitForThread(cs.renderer_thr.getHandle());

        cs.deinit();
        self.core_state = .none;
    }

    /// The first step of `stopCore`, apart so that it can be tested: the
    /// core stops routing to this surface (`deleteSurface`, which also
    /// starts the quit timer when it was the last one), and whatever still
    /// waits on it forgets it while the address is still this surface's
    /// (`App.forgetClosing`).
    fn detachCore(self: *Surface) void {
        self.app.core_app.deleteSurface(self);
        self.app.forgetClosing(&self.core_surface);
    }

    /// Ask for this window to be torn down from a message loop.
    pub fn postDestroy(self: *Surface) void {
        postTeardown(self.hwnd, &self.closing);
    }

    /// WM_GHOSTTY_DESTROY: the one place a live surface is torn down.
    ///
    /// Runs from a message loop -- `run`'s, a system modal loop's, or
    /// `App.waitForThread` -- never directly inside a core frame, because
    /// the message is only ever posted. When a core frame or prompt is
    /// nonetheless beneath that loop (`App.canReenterCore`), the teardown is
    /// deferred instead (`destroy_deferred`): its pump would tick, and
    /// waiting there could wait on threads blocked behind the undrained
    /// mailbox. So is a teardown dispatched by another surface's teardown
    /// (`App.teardown_depth`), from the pump in its wait: it would nest a
    /// second wait inside the first, and with several windows closing at
    /// once each would nest inside the last.
    ///
    /// **`self` is freed by `destroy`**: only `app`, read beforehand, is
    /// used after it. A deferred teardown is re-posted by
    /// `App.repostDeferredDestroys`.
    fn destroyPosted(self: *Surface) void {
        const app = self.app;

        // terminate drives teardown itself; see App.terminate.
        if (app.terminating) return;

        if (!app.canTearDown()) {
            self.destroy_deferred = true;
            return;
        }

        _ = self.destroy();

        // `self` is freed. A teardown deferred while this one ran is posted
        // again now rather than when `run` comes round, which during another
        // window's size/move loop is only once the user lets go.
        if (app.canTearDown()) app.repostDeferredDestroys();
    }

    // ---------------------------------------------------------------------
    // The rt_surface contract
    // ---------------------------------------------------------------------

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    /// The core asks the runtime to close this surface. `process_alive` means
    /// a child process is still running and the user should be asked.
    ///
    /// This is called from inside core frames (`Surface.childExited`,
    /// `Surface.keyCallback`) and so must never destroy
    /// anything itself: it posts WM_GHOSTTY_DESTROY and returns. That is also
    /// why a `.closed` InputEffect leaves `self` valid in `keyEvent`.
    ///
    /// `*Surface` rather than `*const`: the core calls this through a mutable
    /// `rt_surface` (`CoreSurface.close`).
    pub fn close(self: *Surface, process_alive: bool) void {
        if (self.app.terminating) return;

        // A second WM_CLOSE while the prompt below is up, or a close_window
        // binding after the teardown was already posted.
        if (self.closing) return;
        self.closing = true;

        if (process_alive and !confirm(self.app, self.hwnd, self.closePrompt(), .ok)) {
            // `self` is still valid: `confirm` raises `prompt_depth`, so no
            // teardown can run inside its modal loop (destroyPosted defers),
            // and nothing but destroyPosted destroys a surface window.
            self.closing = false;
            return;
        }

        self.postDestroy();
    }

    /// What the prompt before this terminal closes says. The core asks for
    /// a read-only terminal before it looks at its command
    /// (`CoreSurface.needsConfirmQuit`, src/Surface.zig:1019 and 1023), so
    /// once the command has exited that is the only reason, and the prompt
    /// says the terminal is read-only; otherwise it says a process is still
    /// running in it. The core's actions tell this runtime both
    /// (`readonly`, `show_child_exited`).
    fn closePrompt(self: *const Surface) win32.LPCWSTR {
        if (self.overlays.readonly.on and self.overlays.child_exited.exited)
            return L("This terminal is read-only. Close it anyway?");
        return L("A process is still running in this terminal. Close it anyway?");
    }

    /// The Direct3D 11 device has no options: each renderer creates its
    /// own device for this window.
    pub fn renderDeviceOptions(self: *const Surface) !renderer.Device.Options {
        _ = self;
        return .{};
    }

    /// The ratio of this window's DPI to the Windows reference DPI of 96.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        const scale: f32 = @as(f32, @floatFromInt(self.dpi())) /
            @as(f32, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
        return .{ .x = scale, .y = scale };
    }

    /// This window's DPI (`Window.dpiOf`).
    fn dpi(self: *const Surface) u32 {
        return Window.dpiOf(self.app, self.hwnd);
    }

    /// Client area in physical pixels.
    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        var rect: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &rect).toBool()) {
            return App.Error.Win32CallFailed;
        }

        return .{
            .width = @intCast(@max(0, rect.right - rect.left)),
            .height = @intCast(@max(0, rect.bottom - rect.top)),
        };
    }

    /// The pointer position of the mouse event being delivered, in client
    /// device pixels: the last position given to cursorPosCallback, or
    /// `Mouse.outside`. Negative values mean "outside the viewport" to
    /// `Surface.cursorPosCallback` and are passed through unclamped.
    ///
    /// Cached rather than read live, because the core reads a button or
    /// wheel event's position back through here (`Surface.scrollCallback`,
    /// `Surface.mouseButtonCallback`) after the live pointer may have moved
    /// on. After a leave, a live read would also give a point beyond the
    /// window, which the core clamps to an edge cell instead of treating as
    /// outside. The embedded runtime caches it the same way.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.mouse.pos;
    }

    /// The program's title, for the core (CSI 21 t): never the user's
    /// override, as GTK's `getTitle` is not.
    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    /// The title shown for the terminal: the user's from its title prompt,
    /// else the program's, as GTK's `getEffectiveTitle`.
    pub fn effectiveTitle(self: *const Surface) ?[:0]const u8 {
        return self.title_override orelse self.title;
    }

    /// Windows has exactly one system clipboard. There is no X11-style
    /// primary selection and no separate selection clipboard.
    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => false,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        // The Kitty protocol requests own an arena that holds the request
        // struct itself (`KittyRead.destroy`, `KittyWrite.destroy` in
        // apprt/structs.zig) -- but the apprt does
        // NOT own that arena here, and destroying it would be a double free.
        //
        // The core destroys the request itself for every answer other than
        // `.started`: `Surface.kittyClipboardRead` and
        // `Surface.kittyClipboardWrite` both `defer req.destroy()`. Worse,
        // the ENOSYS reply it builds reads `req.id` and `req.terminator`,
        // which live *in* that arena, after we return. Ownership only
        // transfers on `.started`, and then only to
        // `Surface.completeClipboardRequest` or
        // `Surface.denyClipboardRequest`, which destroy it themselves.
        switch (state) {
            .kitty_read, .kitty_write => return .unsupported,

            // The core routes OSC 52 writes straight to setClipboard; they
            // never reach this function (`Surface.startClipboardRequest`).
            .osc_52_write => return .unsupported,

            .paste, .osc_52_read, .list => {},
        }

        if (!self.supportsClipboard(clipboard_type)) return .unsupported;

        const alloc = self.app.core_app.alloc;

        if (state == .list) {
            if (!win32.IsClipboardFormatAvailable(win32.CF_UNICODETEXT).toBool()) {
                return .unavailable;
            }

            try self.core_surface.completeClipboardRequest(state, .{
                .available = &.{text_mime},
            });
            return .started;
        }

        const text = (try readClipboardText(alloc, self.hwnd)) orelse return .unavailable;
        defer alloc.free(text);

        const contents: []const terminal.clipboard.Content = &.{.{
            .mime = text_mime,
            .data = text,
        }};

        self.core_surface.completeClipboardRequest(state, .{
            .contents = contents,
        }) catch |err| switch (err) {
            // The request is still alive in this case and the apprt owns the
            // confirmation flow.
            //
            // MessageBoxW runs a nested modal loop. Win32 messages keep
            // pumping, but `core_app.tick` does not (`confirm` raises
            // App.prompt_depth), so the mailbox goes undrained for as long as
            // the prompt is up and renderer and IO output stalls behind it.
            // That is deliberate: this runs inside a tick, and the same guard
            // defers any surface teardown dispatched meanwhile, so `self` is
            // still valid for the completeClipboardRequest calls below. The
            // stall goes away when this becomes an in-window prompt driven
            // from the core's own confirmation UI.
            error.UnsafePaste, error.UnauthorizedPaste => {
                if (confirm(
                    self.app,
                    self.hwnd,
                    clipboardReadPrompt(state),
                    .cancel,
                )) {
                    try self.core_surface.completeClipboardRequest(state, .{
                        .contents = contents,
                        .confirmed = true,
                    });
                } else {
                    self.core_surface.denyClipboardRequest(state);
                }
            },
            else => return err,
        };

        return .started;
    }

    /// Write text to the clipboard.
    ///
    /// `confirm` means the configuration asked for the write to be approved by
    /// the user. This runtime has no in-window prompt, so it uses a modal
    /// MessageBoxW rather than writing unasked -- crude, but it does not
    /// quietly drop the user's configured safeguard.
    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm_write: bool,
    ) !void {
        if (!self.supportsClipboard(clipboard_type)) return;

        const text: []const u8 = text: {
            for (contents) |c| {
                if (terminal.clipboard.isTextMime(c.mime)) break :text c.data;
            }

            // Nothing text-like to write. Silently doing nothing is correct:
            // Windows has no way to hold the other representations here.
            log.debug("clipboard write had no text representation", .{});
            return;
        };

        if (confirm_write and !confirm(
            self.app,
            self.hwnd,
            L("An application wants to write to the clipboard. Allow it?"),
            .cancel,
        )) return;

        // An error, not a bare `return`, on every failure: the core must not
        // believe a copy landed when it did not.
        try writeClipboardText(self.hwnd, text);
    }

    /// The environment the child process starts from. The caller takes
    /// ownership and then mutates it (`CoreSurface.init`).
    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        return try global.environMap();
    }

    // ---------------------------------------------------------------------
    // Win32 message handling
    // ---------------------------------------------------------------------

    /// `.progress_report`: take the program's report, and show it on the
    /// window's taskbar button if this terminal has the window's focus. As
    /// on GTK, a report with no newer one lapses after 15 seconds, for a
    /// program that stalls or exits without removing it, and with
    /// `progress-style = false` a report removes what was shown instead.
    pub fn reportProgress(self: *Surface, report: terminal.osc.Command.ProgressReport) void {
        if (self.app.config.@"progress-style") {
            self.progress.update(report);
        } else {
            self.progress.update(.{ .state = .remove });
        }

        if (self.progress.state == .none) {
            _ = win32.KillTimer(self.hwnd, progress_timer_id);
        } else {
            self.progress_expires = win32.GetTickCount64() + progress_timeout_ms;
            // Replaces the timer a previous report set.
            if (win32.SetTimer(self.hwnd, progress_timer_id, progress_timeout_ms, null) == 0) {
                log.warn("SetTimer failed, progress will not lapse err={}", .{win32.GetLastError()});
            }
        }
        if (self.window.tab().focused == self) self.window.showProgress();
    }

    /// The progress timer's WM_TIMER. One already queued can arrive after
    /// a newer report set the timer again, so only progress that has
    /// lapsed is removed.
    fn progressTimer(self: *Surface) void {
        if (win32.GetTickCount64() < self.progress_expires) return;
        self.reportProgress(.{ .state = .remove });
    }

    /// `.desktop_notification`: a toast for this terminal, with its title in
    /// a smaller line, as macOS shows it, which a click brings forward
    /// (`App.notificationClicked`), and which goes as macOS and GTK remove
    /// it (`DesktopNotifications`). False if it could not be shown.
    pub fn notify(self: *Surface, title: []const u8, body: []const u8) bool {
        const notifier = self.app.notifierFor() orelse return false;
        return self.notifications.send(
            self.app.core_app.alloc,
            notifier,
            self.hwnd,
            .{ .title = title, .body = body, .attribution = self.effectiveTitle() },
            self.app.nextToastTag(),
            self.focused,
            win32.GetTickCount64(),
        );
    }

    /// Remove the terminal's toasts, shown or kept in the notification
    /// center: when it gains the focus or closes, as macOS and GTK do.
    pub fn clearNotifications(self: *Surface) void {
        self.notifications.clear(self.app.notifier, self.hwnd);
    }

    /// Remember the title for `getTitle`, and show it as the window's
    /// caption if this is its focused terminal: a window is titled after
    /// its focused terminal (`Window.setFocused`), so another terminal's
    /// shows once it gets the focus. Returns false if the title could not
    /// be stored or shown, which is what `.set_title` reports. While the
    /// user's title is set (`title_override`), it is what stays shown.
    ///
    /// The core validates only OSC titles; one from the `title` config, a
    /// keybinding or a command's argv[0] can be any bytes. Invalid UTF-8 is
    /// shown as U+FFFD, as macOS does, and the title is stored as given.
    pub fn setTitle(self: *Surface, title: [:0]const u8) bool {
        const alloc = self.app.core_app.alloc;
        const copy = alloc.dupeSentinel(u8, title, 0) catch |err| {
            log.warn("failed to store the window title err={}", .{err});
            return false;
        };
        if (self.title) |old| alloc.free(old);
        self.title = copy;
        return self.showTitleChange();
    }

    /// The title from the terminal's title prompt (`TitleDialog.commit`):
    /// shown in place of the program's wherever the terminal's title shows,
    /// or, when empty, the program's again, as GTK's `titleDialogSet`.
    /// Returns false if it could not be stored or shown.
    pub fn setTitleOverride(self: *Surface, title: []const u8) bool {
        const alloc = self.app.core_app.alloc;
        const copy: ?[:0]u8 = if (title.len == 0) null else alloc.dupeSentinel(u8, title, 0) catch |err| {
            log.warn("failed to store the terminal's title err={}", .{err});
            return false;
        };
        if (self.title_override) |old| alloc.free(old);
        self.title_override = copy;
        return self.showTitleChange();
    }

    /// Show the terminal's title (`effectiveTitle`) where it changed: its
    /// tab's label, if it is the focused terminal of its tab, and its
    /// window's caption, if it is the focused terminal of the tab shown.
    fn showTitleChange(self: *Surface) bool {
        // A tab's label shows its focused terminal's title, unless the tab
        // has one of its own; any other title changes no label, as on GTK,
        // whose tab binds only its active surface's title.
        if (self.window.tabOf(self)) |t| {
            if (t.focused == self and t.title_override == null) self.window.bar.invalidate();
        }
        if (self.window.tab().focused != self) return true;
        return self.window.showTitle(Window.tabTitle(self.window.tab()));
    }

    /// WM_CLOSE sent to this window: it closes alone. Windows sends the
    /// title bar button's, Alt+F4's and the window menu's to the frame
    /// (`Window.requestClose`).
    pub fn requestClose(self: *Surface) void {
        if (self.app.terminating) return;
        switch (self.core_state) {
            // CoreSurface.close -> Surface.close applies needsConfirmQuit
            // and posts the teardown.
            .live => self.core_surface.close(),
            // Already going away.
            .stopping => {},
            // No core surface, so nothing to confirm or stop: torn down as
            // any close is (`destroyPosted`), which a teardown already
            // running defers.
            .none => if (!self.closing) {
                self.closing = true;
                self.postDestroy();
            },
        }
    }

    /// The frame's WM_SIZE reports whether the window is minimized: a
    /// child window is not resized when its frame is minimized, or restored
    /// at the same size, so it never sees either. The core ignores repeats
    /// (`Surface.occlusionCallback`).
    pub fn occlusionChanged(self: *Surface, visible: bool) void {
        const core_surface = self.liveCore() orelse return;
        core_surface.occlusionCallback(visible) catch |err|
            log.warn("occlusion callback failed err={}", .{err});
    }

    /// Told the DPI `scaleChanged` gives each terminal, in tests only,
    /// where a terminal has no core to see it.
    pub var test_scale_changed: if (builtin.is_test) ?*const fn (*Surface, u16) void else void =
        if (builtin.is_test) null else {};

    /// The frame's WM_DPICHANGED, with the new DPI: a child window gets
    /// none of its own. The frame applies the suggested window rect after
    /// this, which resizes this window synchronously, so the core sees the
    /// scale before the size computed for it.
    pub fn scaleChanged(self: *Surface, new_dpi: u16) void {
        if (builtin.is_test) if (test_scale_changed) |seen| seen(self, new_dpi);
        self.ime.form = null;
        const core_surface = self.liveCore() orelse return;
        const scale = @as(f32, @floatFromInt(new_dpi)) /
            @as(f32, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
        core_surface.contentScaleCallback(.{ .x = scale, .y = scale }) catch |err|
            log.warn("content scale callback failed err={}", .{err});
    }

    /// WM_PAINT. The render thread draws and presents on its own; all the
    /// main thread does is clear the update region and ask the core for a
    /// frame.
    fn paint(self: *Surface) void {
        // ValidateRect, not BeginPaint/EndPaint: the update region still has
        // to be cleared -- otherwise Windows re-posts WM_PAINT forever and the
        // loop spins at 100% CPU -- and nothing here draws, so no DC is
        // needed.
        _ = win32.ValidateRect(self.hwnd, null);

        // A paint can arrive from inside CreateWindowExW, before the core
        // surface exists; `Window.show` shows the window only after it does.
        const core_surface = self.liveCore() orelse return;

        // refreshCallback, not CoreSurface.draw: WM_PAINT only needs the
        // render thread woken, as embedded's `ghostty_surface_refresh` does.
        // A synchronous draw from this thread is still allowed, since every
        // renderer must permit `CoreSurface.draw` from the apprt's thread,
        // and is what a live-resize path would use.
        core_surface.refreshCallback() catch |err| {
            log.warn("refresh on paint failed id={x} err={}", .{ core_surface.id, err });
            return;
        };
    }

    fn handleMessage(
        self: *Surface,
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) win32.LRESULT {
        // Until `core_state` is `.live` every handler below keeps the
        // pre-core behaviour. That matters: messages arrive inside
        // CreateWindowExW, long before CoreSurface.init. Callback errors are
        // logged and never propagated; there is no caller to take them.
        switch (msg) {
            win32.WM_CLOSE => {
                self.requestClose();
                return 0;
            },

            WM_GHOSTTY_LINK_REFUSED => {
                // Dropped once the surface is going away: the notice would
                // only hold up the teardown that pumps this message.
                if (self.core_state == .live) {
                    notice(self.app, hwnd, L(
                        "Ghostty did not open this link.\n\n" ++
                            "A link printed by a program is only opened when it is an http, https or mailto link.",
                    ));
                }
                return 0;
            },

            WM_GHOSTTY_DESTROY => {
                // Frees `self` unless deferred; nothing may follow it.
                self.destroyPosted();
                return 0;
            },

            win32.WM_DESTROY => {
                // Every path that destroys a live surface stops the core
                // first (Surface.destroy), so this is only
                // defensive: tear down now, late but in the right order,
                // rather than delete a context the render thread still has
                // current. `.stopping` cannot be seen here: nothing destroys
                // the window while stopCore is pumping.
                if (self.core_state == .live) {
                    log.warn("surface window destroyed with a live core surface", .{});
                    self.stopCore();
                }

                self.app.surfaceDestroyed(self);
                return 0;
            },

            win32.WM_SIZE => {
                self.ime.form = null;
                const core_surface = self.liveCore() orelse return 0;

                // Visibility is the frame's to report (`occlusionChanged`):
                // this window is never minimized itself.
                switch (SizeChange.init(lparam)) {
                    .empty => {},
                    .resize => |size| core_surface.sizeCallback(size) catch |err|
                        log.warn("size callback failed err={}", .{err}),
                }
                return 0;
            },

            win32.WM_TIMER => switch (wparam) {
                progress_timer_id => {
                    self.progressTimer();
                    return 0;
                },
                DesktopNotifications.timer_id => {
                    self.notifications.expire(self.app.notifier, self.hwnd, win32.GetTickCount64());
                    return 0;
                },
                else => {},
            },

            win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
                self.focused = msg == win32.WM_SETFOCUS;
                if (self.focused) {
                    // The terminal, not its search field, has the focus
                    // now, and gets it back (`SearchBar.Bar.focusTarget`).
                    self.search_bar.field_focus = false;
                    self.window.setFocused(self);
                    self.clearNotifications();
                }

                if (!self.focused) {
                    // A drag does not survive losing focus (Alt+Tab, a
                    // dialog, the Start menu). The capture may outlive the
                    // focus change, and the button-up then goes to another
                    // window. Releasing it lets syncMouse send the core that
                    // release. Only a Win32 call here: this message is sent,
                    // possibly from inside a core frame (a paste
                    // confirmation taking focus).
                    const dragging = self.mouse.held.count() != 0;
                    if (dragging and self.hasCapture()) _ = win32.ReleaseCapture();

                    // An open composition does not survive it either, but
                    // ending one makes the IME send its messages straight
                    // back into this window procedure.
                    const composing = self.ime.composing or self.preedit == .ime;

                    // Both wait for `App.run` (syncDeferredMouse,
                    // syncDeferredIme). The wakeup makes `run` come round
                    // now, since a sent message does not; otherwise the
                    // release waits for some later message to this thread.
                    if (dragging or composing) self.app.wakeup();
                }
                self.ime.form = null;

                if (self.liveCore()) |core_surface| {
                    core_surface.focusCallback(msg == win32.WM_SETFOCUS) catch |err|
                        log.warn("focus callback failed err={}", .{err});
                }
                return 0;
            },

            win32.WM_IME_SETCONTEXT => {
                // The composition string is drawn as the core's preedit, so
                // the IME must not show its own composition window. The
                // message is still forwarded: the default IME window needs
                // it to activate the context, and keeps the candidate list.
                if (comptime std.log.logEnabled(.debug, .win32)) {
                    log.debug("ime setcontext active={} lang=0x{x}", .{ wparam != 0, inputLanguage() });
                }
                return win32.DefWindowProcW(hwnd, msg, wparam, Ime.setContextLparam(lparam));
            },

            // Not forwarded: DefWindowProcW would open the composition
            // window (start) and turn the result into WM_IME_CHARs and
            // then WM_CHARs (composition), delivering the text twice.
            win32.WM_IME_STARTCOMPOSITION => {
                self.imeStart();
                return 0;
            },
            win32.WM_IME_COMPOSITION => {
                self.imeComposition(lparam);
                return 0;
            },

            // Forwarded, so the default IME window releases what it holds.
            // A change of input language ends a composition too, and the
            // outgoing IME is not required to say so.
            win32.WM_IME_ENDCOMPOSITION, win32.WM_INPUTLANGCHANGE => {
                self.imeEnd();
            },

            // Neither is answered: WM_IME_CHAR only comes from a forwarded
            // WM_IME_COMPOSITION, which never happens here, and the
            // Microsoft IMEs work without WM_IME_REQUEST answers even though
            // they send one (IMR_* in wParam) on nearly every keystroke.
            win32.WM_IME_CHAR, win32.WM_IME_REQUEST => {
                // log.debug("ime message=0x{x} wparam=0x{x}", .{ msg, wparam });
            },

            win32.WM_KEYDOWN,
            win32.WM_SYSKEYDOWN,
            win32.WM_KEYUP,
            win32.WM_SYSKEYUP,
            => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);

                const slot = Ime.scanSlot(lparam);
                const withheld = switch (self.ime.filterKey(msg, wparam, lparam)) {
                    .withhold => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
                    .deliver => false,
                    .deliver_withheld => true,
                };

                // Dropped while a prompt is open, as mouse input is
                // (`syncMouse`): its message loop may have a core frame
                // beneath it. The prompt disables its owner, which stops
                // the user's keystrokes but not key messages another
                // program posts or sends. Not given their system meaning
                // either, or Alt+F4 would close a window under the prompt.
                // The core never sees the press, so its key-up is withheld.
                if (!self.app.canReenterCore()) {
                    if (keyAction(msg, lparam) == .press) self.ime.swallow_up.set(slot);
                    return 0;
                }

                // The synthetic Left Ctrl of AltGr. The core still sees Ctrl
                // held (GetKeyState) and keyEvent's AltGr rule handles that.
                if (isAltGrFakeCtrl(wparam, lparam)) {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                const mods = currentMods();

                // Alt+Space (Alt alone) opens the window menu, as in every
                // Windows app, unless a binding claims it. The menu must
                // bypass the core entirely: DefWindowProcW opens it from the
                // WM_SYSCHAR ' ' that TranslateMessage posted, so keyEvent
                // must not remove that message either. This has to be
                // decided before keyEvent, not from an `.ignored` result.
                // The key-up is withheld like an IME key's.
                menu: {
                    const vk: win32.UINT = @truncate(wparam);
                    const action = keyAction(msg, lparam);
                    if (!isWindowMenuKey(action, vk, mods)) break :menu;

                    const scan = scanCode(vk, lparam);
                    const bound = core_surface.keyEventIsBinding(.{
                        .action = action,
                        .key = keyFromScan(scan),
                        .mods = mods,
                        .unshifted_codepoint = unshiftedCodepoint(vk, scan),
                    });
                    if (bound != null) break :menu;

                    self.ime.swallow_up.set(slot);
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                // Alt+numpad entry: TranslateMessage collects the digits and
                // posts the character as WM_CHAR when Alt is released, which
                // reaches strayChar. The digits themselves must not reach the
                // core, or the encoder would send them ahead of the
                // character. The key-up is withheld like an IME key's.
                if (isAltNumpad(keyAction(msg, lparam), @truncate(wparam), mods, withheld)) {
                    self.ime.swallow_up.set(slot);
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                const result = self.keyEvent(core_surface, msg, wparam, lparam, mods);
                // A focus move a binding chose (goto_split), now that the
                // core's key callback has returned and before the next key
                // is read (`Tab.pending_focus`).
                self.app.applyPendingFocus();
                const effect = result catch |err| {
                    log.warn("key callback failed err={}", .{err});
                    return 0;
                };
                return switch (effect) {
                    // `.closed` only posted WM_GHOSTTY_DESTROY (Surface.close),
                    // so `self` is still valid -- but nothing here needs it.
                    .consumed, .closed => 0,
                    // Unhandled keys keep their system meaning: Alt and F10
                    // reach the frame's WM_SYSCOMMAND (suppressed there),
                    // Alt+F4 becomes SC_CLOSE if no binding took it.
                    .ignored => win32.DefWindowProcW(hwnd, msg, wparam, lparam),
                };
            },

            win32.WM_CHAR,
            win32.WM_DEADCHAR,
            win32.WM_SYSCHAR,
            win32.WM_SYSDEADCHAR,
            => {
                // Normally never seen: keyEvent removes the characters its
                // keydown produced. What arrives here came without a keydown
                // to attach it to: a character produced on a key-up (Alt+
                // numpad entry posts its WM_CHAR when Alt is released, and
                // keyEvent collects text only for presses), a character
                // another program posted, or a keydown the core surface did
                // not exist for yet.

                // Alt+Space's WM_SYSCHAR, deliberately left in the queue by
                // the keydown handler: DefWindowProcW passes it to the
                // frame, whose DefWindowProcW turns it into SC_KEYMENU with
                // lParam ' ', which opens the window menu.
                if (msg == win32.WM_SYSCHAR and wparam == ' ') {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                }

                // Dropped while a prompt is open, as key messages are.
                if (self.app.canReenterCore()) {
                    if (self.liveCore()) |core_surface| {
                        self.strayChar(core_surface, msg, wparam);
                    }
                }

                // Always handled. For WM_SYSCHAR this is also what stops
                // DefWindowProcW from beeping about a missing menu mnemonic.
                return 0;
            },

            win32.WM_MOUSEMOVE => {
                // Before the core, which may show a link preview: whether
                // the pointer is over its place, which the preview passes
                // through to here (`LinkPreview.pointerAt`).
                LinkPreview.pointerAt(self, .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) });
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                if (!self.syncMouse(core_surface, Mouse.Button.downIn(wparam))) return 0;
                self.armLeave();
                self.movePointer(core_surface, clientPos(lparam), self.mouseMods(wparam));
                return 0;
            },

            win32.WM_MOUSELEAVE => {
                // Win32 has cancelled the tracking.
                self.mouse.tracking = false;
                LinkPreview.pointerAt(self, null);
                if (self.liveCore()) |core_surface| {
                    // During a drag the captured moves keep the core
                    // informed, negative positions included, which drag
                    // autoscroll needs. The release re-arms tracking to learn
                    // where the drag ended.
                    if (self.mouse.held.count() == 0) self.mouse.leave_owed = true;
                    _ = self.syncMouse(core_surface, null);
                }
                return 0;
            },

            win32.WM_LBUTTONDOWN,
            win32.WM_LBUTTONUP,
            win32.WM_RBUTTONDOWN,
            win32.WM_RBUTTONUP,
            win32.WM_MBUTTONDOWN,
            win32.WM_MBUTTONUP,
            win32.WM_XBUTTONDOWN,
            win32.WM_XBUTTONUP,
            => {
                const button = Mouse.Button.fromMessage(msg, wparam) orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                const state: input.MouseButtonState = switch (msg) {
                    win32.WM_LBUTTONDOWN,
                    win32.WM_RBUTTONDOWN,
                    win32.WM_MBUTTONDOWN,
                    win32.WM_XBUTTONDOWN,
                    => .press,
                    else => .release,
                };
                self.mouseButton(
                    core_surface,
                    button,
                    state,
                    wparam,
                    clientPos(lparam),
                    self.mouseMods(wparam),
                );

                // Never DefWindowProcW once a button is handled: for X
                // buttons it sends WM_APPCOMMAND (browser back/forward), and
                // a handled X button must return TRUE; for WM_RBUTTONUP its
                // only default is WM_CONTEXTMENU, and there is no menu. The
                // class has no CS_DBLCLKS, so no *BUTTONDBLCLK arrives: the
                // core counts clicks itself, within click-repeat-interval,
                // which defaults to the system double-click time
                // (`internal_os.clickInterval`).
                const is_x = msg == win32.WM_XBUTTONDOWN or msg == win32.WM_XBUTTONUP;
                return @intFromBool(is_x);
            },

            win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
                const core_surface = self.liveCore() orelse
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                if (!self.syncMouse(core_surface, Mouse.Button.downIn(wparam))) return 0;

                // Programs with mouse reporting get the wheel at the
                // position getCursorPos returns, and drop a report at
                // `outside` (`mouse_encode.encode`), while without reporting
                // the same wheel scrolls the viewport. When the pointer is
                // over this client area the message is a move like any
                // other: after a capture loss the cache says `outside` until
                // the next move. Otherwise (the pointer is over the frame, or
                // elsewhere and the wheel came by focus) the report goes to
                // the nearest client cell for this message only. That is not
                // a move, so link hover and the leave stand.
                var kept: ?apprt.CursorPos = null;
                defer if (kept) |pos| {
                    self.mouse.pos = pos;
                };
                if (self.wheelPoint(lparam)) |point| {
                    if (point.over) {
                        self.armLeave();
                        self.movePointer(core_surface, point.pos, self.mouseMods(wparam));
                    } else {
                        kept = self.mouse.pos;
                        self.mouse.pos = point.pos;
                    }
                }

                const delta: i32 = win32.wheelDelta(wparam);
                if (msg == win32.WM_MOUSEWHEEL) {
                    // "One screen at a time" is as many lines as the screen
                    // has rows.
                    const lines = wheelSetting(win32.SPI_GETWHEELSCROLLLINES);
                    const per_notch: u32 = if (lines == win32.WHEEL_PAGESCROLL)
                        core_surface.size.grid().rows
                    else
                        lines;

                    // Positive is away from the user: the core's "up"
                    // (`Surface.scrollCallback`'s doc comment).
                    if (self.mouse.wheel_y.add(delta, per_notch)) |ticks| {
                        core_surface.scrollCallback(0, @floatFromInt(ticks), .{}) catch |err|
                            log.warn("scroll callback failed err={}", .{err});
                    }
                } else if (self.mouse.wheel_x.add(
                    delta,
                    wheelSetting(win32.SPI_GETWHEELSCROLLCHARS),
                )) |ticks| {
                    // Positive is to the right here. The core's positive x
                    // is reported as button 6, X11's scroll-left
                    // (`Surface.scrollCallback`), and GTK negates its
                    // rightward delta to match; so does this.
                    core_surface.scrollCallback(@floatFromInt(-ticks), 0, .{}) catch |err|
                        log.warn("scroll callback failed err={}", .{err});
                }
                return 0;
            },

            // Beside a divider the pointer is the frame's (`Dividers`).
            win32.WM_NCHITTEST => return Dividers.hitTest(self.window, hwnd, wparam, lparam),

            win32.WM_SETCURSOR => {
                // Client area only. Elsewhere DefWindowProcW sets the arrow
                // or a resize arrow, which also keeps a pointer hidden while
                // typing visible over the frame. Over the client area it
                // would restore the class arrow on every move.
                if (win32.loword(lparam) == win32.HTCLIENT and
                    (self.mouse.hidden or self.mouse.cursor != null))
                {
                    _ = win32.SetCursor(self.clientCursor());
                    return 1;
                }
            },

            win32.WM_MOUSEACTIVATE => {
                // Sent for every click on a child window, not only for one
                // that activates its frame. Client area only; the caption is
                // the frame's, so a click there never comes here.
                if (win32.loword(lparam) == win32.HTCLIENT) {
                    // A click on an inactive window only activates it, as on
                    // macOS: it must not clear the selection, move the prompt
                    // cursor, or reach a program that reads the mouse. The
                    // button-up that may follow is dropped by mouseButton,
                    // because the press was never recorded. The terminal
                    // clicked is the one the activation gives the focus
                    // (the frame's WM_SETFOCUS).
                    if (win32.GetActiveWindow() != self.window.hwnd) {
                        // The terminal itself, not its search field.
                        self.search_bar.field_focus = false;
                        self.window.setFocused(self);
                        return win32.MA_ACTIVATEANDEAT;
                    }

                    // In an active window with the focus elsewhere in it,
                    // the click only moves the focus here, and is consumed
                    // as macOS consumes a click that moves the focus between
                    // splits (`localEventLeftMouseDown` in
                    // SurfaceView_AppKit.swift).
                    if (win32.GetFocus() != hwnd) {
                        _ = win32.SetFocus(hwnd);
                        return win32.MA_ACTIVATEANDEAT;
                    }

                    // Otherwise the click is the terminal's.
                    return win32.MA_ACTIVATE;
                }
            },

            win32.WM_PAINT => {
                self.paint();
                return 0;
            },

            // The render thread presents every pixel of the client area, so
            // letting GDI erase first would only produce a flash of the class
            // background. The first real frame follows the first WM_PAINT's
            // refresh.
            win32.WM_ERASEBKGND => return 1,

            else => {},
        }

        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    /// Translate a key message into a core KeyEvent and deliver it.
    ///
    /// Win32 splits one keystroke across two messages: the WM_(SYS)KEYDOWN
    /// being handled, and the WM_(SYS)CHAR / WM_(SYS)DEADCHAR that
    /// TranslateMessage posted *before* that keydown was dispatched
    /// (App.run, waitForThread). The core wants both in one event, so the
    /// characters are pulled out of the queue here.
    fn keyEvent(
        self: *Surface,
        core_surface: *CoreSurface,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
        mods_in: input.Mods,
    ) !CoreSurface.InputEffect {
        const vk: win32.UINT = @truncate(wparam);
        const scan = scanCode(vk, lparam);
        const action = keyAction(msg, lparam);

        // VK_PACKET is injected text (SendInput with KEYEVENTF_UNICODE: on-
        // screen keyboards, some remote-desktop clients). It is not a
        // physical key, and its lParam scan field is not guaranteed to be
        // zero, so it must not be matched against the keycode table, where
        // it could alias a real key and fire that key's bindings. Its text
        // still arrives through the WM_CHAR collected below.
        const is_packet = wparam == win32.VK_PACKET;

        const key: input.Key = if (is_packet) .unidentified else numpadKey(keyFromScan(scan), vk);

        // Collected before `keyText` flushes the IME's text, so that
        // nothing the flush triggers can dispatch the queued WM_CHAR out of
        // turn.
        var text: Text = .{};
        if (action != .release) text.collect(self.hwnd, &self.high_surrogate);

        const unshifted: u21 = if (is_packet) 0 else unshiftedCodepoint(vk, scan);
        const shiftless: u21 = if (is_packet or !mods_in.shift) unshifted else shiftless: {
            // The state as of this message, like currentMods. On failure
            // the unshifted codepoint is the best guess left.
            var state: [256]win32.BYTE = undefined;
            if (!win32.GetKeyboardState(&state).toBool()) break :shiftless unshifted;
            break :shiftless shiftlessCodepoint(vk, scan, &state);
        };

        const alt_gr = altGrKey(&self.alt_gr, Ime.scanSlot(lparam), action, mods_in, &text);
        const effect = try self.keyText(core_surface, .{
            .action = action,
            .key = key,
            .mods = mods_in,
            .unshifted_codepoint = unshifted,
        }, &text, shiftless, alt_gr);
        self.shift.sent(key, action);

        // With both Shift keys held, Windows sends no key-up for the first
        // one released, only for the last (GLFW's win32_window.c releases
        // both Shift keys on any Shift key-up for this reason). The core is
        // owed the missing release, or a program that asks for modifier key
        // events holds that Shift down forever.
        if (vk == win32.VK_SHIFT and action == .release and effect != .closed) {
            const owed = self.shift.owed(
                win32.GetKeyState(win32.VK_LSHIFT) < 0,
                win32.GetKeyState(win32.VK_RSHIFT) < 0,
            );
            if (owed) |other| {
                _ = try core_surface.keyCallback(.{
                    .action = .release,
                    .key = other,
                    .mods = currentMods(),
                });
                self.shift.sent(other, .release);
            }
        }

        return effect;
    }

    /// Send the core a key event carrying `text`, for `keyEvent` and
    /// `strayChar`. `event.mods` is the state the key was read with; the
    /// mods reported are `keyMods`'s, given the key's codepoint with Shift
    /// released (`shiftless`) and whether the keystroke is AltGr's.
    fn keyText(
        self: *Surface,
        core_surface: *CoreSurface,
        event: input.KeyEvent,
        text: *const Text,
        shiftless: u21,
        alt_gr: bool,
    ) !CoreSurface.InputEffect {
        // Text the IME committed earlier comes first. Both callers'
        // handlers only get here when `App.canReenterCore` holds.
        self.flushIme(core_surface);

        // A dead key shows its accent as preedit until the next committed
        // text replaces it. The core does not track this itself
        // (`Surface.preeditCallback`).
        if (text.composing) {
            try self.setPreedit(core_surface, text.utf8(), .dead_key);
        } else if (self.preedit == .dead_key and text.len > 0) {
            try self.setPreedit(core_surface, null, .none);
        }

        const mods = keyMods(event.mods, text, shiftless, alt_gr);
        var ev = event;
        ev.mods = mods.mods;
        ev.consumed_mods = mods.consumed;
        ev.composing = text.composing;
        ev.utf8 = text.utf8();
        return try core_surface.keyCallback(ev);
    }

    const KeyMods = struct {
        mods: input.Mods,
        consumed: input.Mods = .{},
    };

    /// The modifiers to report for a keystroke that produced `text`, given
    /// the state the key message was read with, the key's codepoint in
    /// that state with Shift released (shiftlessCodepoint), and whether the
    /// keystroke is AltGr's (`isAltGr`, `altGrKey`).
    fn keyMods(mods_in: input.Mods, text: *const Text, shiftless: u21, alt_gr: bool) KeyMods {
        var result: KeyMods = .{ .mods = mods_in };

        // AltGr's Ctrl+Alt is taken out of mods. Marking it consumed, as
        // macOS does for Option, would not work: the legacy encoding gives
        // `ctrlSeq` the full mods and modifyOtherKeys 2 encodes
        // `event.mods`, so German AltGr+Q ('@') would still be sent as NUL
        // or CSI 27;7;64~. GTK reaches the same mods because XKB reports
        // AltGr as a level shift, which `translateMods` does not map.
        if (alt_gr) {
            result.mods.ctrl = false;
            result.mods.alt = false;
        }

        // Win32 has no consumed-modifiers report. Shift is the only one that
        // can be inferred: it was consumed if it changed the character. The
        // comparison is with the rest of the state kept: with Caps Lock on,
        // Shift+A gives "a", the same as with no modifiers at all, but
        // Shift still changed it from "A".
        if (result.mods.shift and text.len > 0) {
            var buf: [4]u8 = undefined;
            const n = if (shiftless != 0)
                std.unicode.utf8Encode(shiftless, &buf) catch 0
            else
                0;
            result.consumed.shift = !std.mem.eql(u8, buf[0..n], text.utf8());
        }

        return result;
    }

    /// Whether a keystroke read with `mods` that produced `text` is AltGr.
    ///
    /// Windows reports AltGr as LCtrl+RAlt, and a Ctrl+Alt chord that
    /// produces a character is AltGr by definition on Windows (it is the
    /// documented substitute on keyboards without the key). Only characters
    /// that came through WM_CHAR count: Alt without Ctrl produces
    /// WM_SYSCHAR, and Alt+letter must keep its Alt so the encoder prefixes
    /// ESC.
    fn isAltGr(mods: input.Mods, text: *const Text) bool {
        return text.from_char and mods.ctrl and mods.alt and text.len > 0;
    }

    /// Whether a key event is AltGr's, recording the verdict in `held`
    /// under the key's `Ime.scanSlot`. A release produces no text to judge,
    /// so it takes the verdict of the key's press: Ctrl+Alt is still down,
    /// and reported on the release alone it would pair a plain '@' with the
    /// release of Ctrl+Alt+Q.
    fn altGrKey(
        held: *std.bit_set.Static(512),
        slot: usize,
        action: input.Action,
        mods: input.Mods,
        text: *const Text,
    ) bool {
        const alt_gr = switch (action) {
            .press, .repeat => isAltGr(mods, text),
            .release => held.isSet(slot),
        };
        held.setValue(slot, action != .release and alt_gr);
        return alt_gr;
    }

    /// The Shift keys the core was sent a press for and no release since.
    /// See `keyEvent`, which owes the core the release Windows drops.
    const ShiftKeys = struct {
        left: bool = false,
        right: bool = false,

        /// Record that the core was sent `action` for `key`.
        fn sent(self: *ShiftKeys, key: input.Key, action: input.Action) void {
            const down = action != .release;
            switch (key) {
                .shift_left => self.left = down,
                .shift_right => self.right = down,
                else => {},
            }
        }

        /// The Shift key whose release the core is owed, given whether
        /// each one is down as of the message being handled.
        fn owed(self: ShiftKeys, left_down: bool, right_down: bool) ?input.Key {
            if (self.left and !left_down) return .shift_left;
            if (self.right and !right_down) return .shift_right;
            return null;
        }
    };

    /// Set or clear the core's preedit and record its owner, together.
    fn setPreedit(
        self: *Surface,
        core_surface: *CoreSurface,
        text: ?[]const u8,
        owner: Ime.Preedit,
    ) !void {
        std.debug.assert((text == null) == (owner == .none));

        // The core drops the old preedit before anything in it can fail
        // (`Surface.preeditCallback`), so a failure leaves none.
        self.preedit = .none;
        try core_surface.preeditCallback(text);
        self.preedit = owner;
    }

    /// The core, if an IME handler may call into it.
    ///
    /// IME messages are mostly *sent*, so they also arrive inside a
    /// prompt's message loop with a core frame beneath it: the composition
    /// ends because the prompt took the focus. The key and character
    /// handlers apply the same rule: the prompt disables its owner, which
    /// stops the user's input but not messages posted or sent to it.
    fn imeCore(self: *Surface) ?*CoreSurface {
        if (!self.app.canReenterCore()) return null;
        return self.liveCore();
    }

    fn imeStart(self: *Surface) void {
        if (comptime std.log.logEnabled(.debug, .win32)) {
            log.debug("ime start lang=0x{x}", .{inputLanguage()});
        }
        self.ime.composing = true;
        self.ime.form = null;

        const core_surface = self.imeCore() orelse return;
        self.flushIme(core_surface);

        // The IME takes the preedit slot from a pending dead key. The
        // system's own dead-key state cannot be reset from here; the next
        // key the IME declines still combines with it.
        if (self.preedit == .dead_key) {
            self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err});
        }

        const himc = win32.ImmGetContext(self.hwnd) orelse return;
        defer _ = win32.ImmReleaseContext(self.hwnd, himc);
        self.imePlace(core_surface, himc);
    }

    fn imeComposition(self: *Surface, lparam: win32.LPARAM) void {
        // Without a core there is no pty to write a result to.
        const core_surface = self.liveCore() orelse return;
        const core_safe = self.app.canReenterCore();
        const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
        // log.debug("ime composition gcs=0x{x} core_safe={}", .{ bits, core_safe });

        // The context's strings are gone once it is released, so it is held
        // for the whole plan. Setting the forms below sends WM_IME_NOTIFY
        // back into the window procedure; nothing here is borrowed then.
        const hwnd = self.hwnd;
        const himc = win32.ImmGetContext(hwnd) orelse return;
        defer _ = win32.ImmReleaseContext(hwnd, himc);
        const alloc = self.app.core_app.alloc;

        // The result is read before the core is entered: it is this
        // message's, whatever the flush below causes the context to report.
        const result: ?[]u8 = if (bits & win32.GCS_RESULTSTR != 0)
            self.imeString(himc, win32.GCS_RESULTSTR)
        else
            null;
        defer if (result) |v| alloc.free(v);

        // Results keep their order: earlier deferred text goes first.
        if (core_safe) self.flushIme(core_surface);

        for (Ime.plan(bits, self.preedit, core_safe).actions()) |action| switch (action) {
            .clear_preedit => self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err}),

            .commit_result => if (result) |v| imeCommit(core_surface, v),

            .defer_result => if (result) |v| self.ime.pending.appendSlice(alloc, v) catch |err|
                log.warn("ime result dropped err={}", .{err}),

            .update_preedit => {
                const text = self.imeString(himc, win32.GCS_COMPSTR);
                defer if (text) |v| alloc.free(v);
                if (text) |v| {
                    self.setPreedit(core_surface, v, .ime) catch |err|
                        log.warn("preedit callback failed err={}", .{err});
                    // Not every input service announces a composition.
                    self.ime.composing = true;
                    self.imePlace(core_surface, himc);
                } else if (self.preedit == .ime) {
                    // Backspaced to nothing. Never the empty string: the
                    // core would keep an empty preedit and hide the cursor.
                    self.setPreedit(core_surface, null, .none) catch |err|
                        log.warn("preedit callback failed err={}", .{err});
                }
            },
        };
    }

    /// WM_IME_ENDCOMPOSITION, or anything else that ends a composition.
    /// The preedit is cleared by `flushIme`, here or as soon as the core
    /// can be entered again.
    fn imeEnd(self: *Surface) void {
        log.debug("ime end", .{});
        self.ime.composing = false;
        self.ime.form = null;
        if (self.imeCore()) |core_surface| self.flushIme(core_surface);
    }

    /// Deliver deferred result text and clear a preedit whose composition
    /// has ended. Requires `imeCore`'s conditions. Called before every
    /// input that reaches the core, so text keeps its order, and from
    /// `syncIme`.
    fn flushIme(self: *Surface, core_surface: *CoreSurface) void {
        if (self.ime.pending.items.len != 0) {
            const alloc = self.app.core_app.alloc;
            if (self.preedit.clearedByCommit()) {
                self.setPreedit(core_surface, null, .none) catch |err|
                    log.warn("preedit callback failed err={}", .{err});
            }
            // Taken out first: the commit can reach a prompt, whose
            // message loop may bring the next result here.
            var pending = self.ime.pending;
            self.ime.pending = .empty;
            defer pending.deinit(alloc);
            imeCommit(core_surface, pending.items);
        }

        if (self.preedit == .ime and !self.ime.composing) {
            self.setPreedit(core_surface, null, .none) catch |err|
                log.warn("preedit callback failed err={}", .{err});
        }
    }

    /// Send committed text to the core the way the other runtimes do: a
    /// text-only key press with no physical key. `textCallback` is the
    /// paste path and is not for this (it would bracket and confirm).
    fn imeCommit(core_surface: *CoreSurface, utf8: []const u8) void {
        // log.debug("ime commit bytes={d}", .{utf8.len});
        // `.closed` only posted WM_GHOSTTY_DESTROY (Surface.close), so the
        // surface stays valid for the caller.
        _ = core_surface.keyCallback(.{
            .action = .press,
            .key = .unidentified,
            .mods = .{},
            .consumed_mods = .{},
            .composing = false,
            .utf8 = utf8,
        }) catch |err| log.warn("key callback failed err={}", .{err});
    }

    /// One of the input context's strings as UTF-8, or null if it is empty
    /// or cannot be read. The caller frees it.
    fn imeString(self: *Surface, himc: win32.HIMC, index: win32.DWORD) ?[]u8 {
        const alloc = self.app.core_app.alloc;

        // Sizes are in bytes, and the string is not terminated.
        const size = win32.ImmGetCompositionStringW(himc, index, null, 0);
        if (size <= 0 or @rem(size, 2) != 0) return null;
        var stack_buf: [512]u8 = undefined;
        var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, alloc);
        const units_alloc = stack.allocator();
        const units = units_alloc.alloc(u16, @intCast(@divExact(size, 2))) catch |err| {
            log.warn("ime string dropped err={}", .{err});
            return null;
        };
        defer units_alloc.free(units);

        const got = win32.ImmGetCompositionStringW(himc, index, units.ptr, @intCast(size));
        if (got <= 0) return null;
        const len: usize = @intCast(@divTrunc(@min(got, size), 2));

        const utf8 = utf8FromWide(alloc, units[0..len]) catch |err| {
            log.warn("ime string dropped err={}", .{err});
            return null;
        };
        if (utf8.len == 0) {
            alloc.free(utf8);
            return null;
        }
        return utf8;
    }

    /// Put the IME's candidate window at the cursor cell. `imePoint` takes
    /// the renderer lock, so this needs `imeCore`'s conditions.
    ///
    /// Two forms, as in winit: the candidate form keeps the list off the
    /// preedit, and the composition form is what some IMEs anchor the list
    /// to instead. Which one a given IME honours is not documented.
    fn imePlace(self: *Surface, core_surface: *CoreSurface, himc: win32.HIMC) void {
        if (win32.GetFocus() != self.hwnd) return;

        var client: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &client).toBool()) return;
        const pos = core_surface.imePoint();
        // The scale imePoint divided by, so that this undoes it exactly.
        const scale = (self.getContentScale() catch unreachable).x;
        const form = Ime.formFor(pos, scale, core_surface.size.cell.width, client);
        if (self.ime.form) |last| if (std.meta.eql(last, form)) return;
        self.ime.form = form;
        log.debug("ime place scale={d} pos={d:.1},{d:.1} {d:.1}x{d:.1} rc={d},{d},{d},{d}", .{
            scale,        pos.x,       pos.y,         pos.width,      pos.height,
            form.rc.left, form.rc.top, form.rc.right, form.rc.bottom,
        });

        var candidate: win32.CANDIDATEFORM = .{
            .dwIndex = 0,
            .dwStyle = win32.CFS_EXCLUDE,
            .ptCurrentPos = .{ .x = form.rc.left, .y = form.rc.top },
            .rcArea = form.rc,
        };
        _ = win32.ImmSetCandidateWindow(himc, &candidate);

        var composition: win32.COMPOSITIONFORM = .{
            .dwStyle = win32.CFS_POINT,
            .ptCurrentPos = form.pt,
            .rcArea = std.mem.zeroes(win32.RECT),
        };
        _ = win32.ImmSetCompositionWindow(himc, &composition);
    }

    /// Finish what the IME handlers could not do where they ran. Called
    /// from `App.run`, never inside a core frame or a prompt.
    ///
    /// A composition does not outlive the focus: its preedit would stay
    /// drawn over the cursor of a window the user has left. How it ends
    /// depends on the language (`Ime.focusLossAction`).
    pub fn syncIme(self: *Surface, core_surface: *CoreSurface) void {
        self.flushIme(core_surface);

        // The fields first: this runs for every surface on every pass of
        // `App.run`, and almost never has anything to do.
        if (self.focused) return;
        if (!self.ime.composing and self.preedit != .ime) return;

        // Another of this thread's windows has the focus. No prompt is
        // open here (`canReenterCore` holds), so it is another surface.
        // Every window of the thread shares the default input context,
        // which is that window's now: ending the composition through it
        // could end one the user is typing there. Only this window's own
        // state is dropped.
        if (win32.GetFocus() != null) {
            self.ime.composing = false;
            self.flushIme(core_surface);
            return;
        }

        if (win32.ImmGetContext(self.hwnd)) |himc| {
            const how = Ime.focusLossAction(inputLanguage());
            log.debug("ime ends with the focus how={d}", .{how});
            // Sends the IME's messages to this window before it returns.
            _ = win32.ImmNotifyIME(himc, win32.NI_COMPOSITIONSTR, how, 0);
            _ = win32.ImmReleaseContext(self.hwnd, himc);
        }

        // No document promises an end message on this path. A completion
        // above may also have closed the surface.
        const core_now = self.liveCore() orelse return;
        self.ime.composing = false;
        self.flushIme(core_now);
    }

    /// A character message with no keydown in this process to attach it to.
    /// Delivered as a text-only key event with no physical key.
    fn strayChar(
        self: *Surface,
        core_surface: *CoreSurface,
        msg: win32.UINT,
        wparam: win32.WPARAM,
    ) void {
        var text: Text = .{};
        text.add(msg, @truncate(wparam));
        text.finish(&self.high_surrogate);
        if (text.len == 0) return;

        // With no key there is no Shift-less character to compare the
        // text with (0), so a held Shift counts as consumed: the text is
        // final, as an IME commit's is.
        const mods = currentMods();
        _ = self.keyText(core_surface, .{
            .action = .press,
            .key = .unidentified,
            .mods = mods,
        }, &text, 0, isAltGr(mods, &text)) catch |err| log.warn("key callback failed err={}", .{err});
    }

    /// Bring the core up to date with what Win32 could not tell it in time,
    /// and report whether a mouse event may reach the core now.
    ///
    /// Owed events are:
    ///   * a release for each held button that is no longer down according
    ///     to the current message (`down`), or whose capture is gone: its
    ///     WM_*BUTTONUP may then go to another window, and if it does come
    ///     here, mouseButton drops it;
    ///   * a WM_MOUSELEAVE that arrived while a prompt was open.
    ///
    /// Capture ends without a button-up when a message box takes it
    /// (WM_CANCELMODE -> DefWindowProcW), for instance the paste
    /// confirmation inside mouseButtonCallback, or when focus moves away
    /// (WM_KILLFOCUS). `down` covers a capture that survives while the
    /// button was released elsewhere. `null` when there is no message to
    /// read it from.
    ///
    /// Nothing reaches the core unless App.canReenterCore: while a prompt is
    /// open, a core frame may be beneath us. Returns false when the caller
    /// must drop its own event for that reason.
    pub fn syncMouse(self: *Surface, core_surface: *CoreSurface, down: ?Mouse.Button.Set) bool {
        if (!self.app.canReenterCore()) return false;
        const m = &self.mouse;

        // The capture only matters while a button is held, and this runs
        // for every move.
        const sync = m.sync(m.held.count() != 0 and self.hasCapture(), down);
        if (sync.release_capture) _ = win32.ReleaseCapture();

        if (sync.release.count() != 0) {
            // Where the user let go is unknown, and the click must not
            // complete. The core treats a release on another cell than the
            // press as the end of a drag (SelectionGesture.release), so no
            // link opens and the prompt cursor does not move. The release is
            // therefore placed beyond the client corner farthest from the
            // left press, which the core clamps to that corner's cell: a
            // different cell unless the grid is one row or one column.
            // Programs with mouse reporting receive the release at that
            // edge cell.
            const last = m.pos;
            m.pos = releasePoint(core_surface.size.screen, m.left_press_pos);

            // The mods the core already has, so the release is judged like
            // the events before it: a Shift drag in a program with mouse
            // reporting stays a Ghostty selection
            // (`Surface.mouseButtonCallback`).
            const mods = core_surface.mouse.mods;
            var it = sync.release.iterator();
            while (it.next()) |button| {
                _ = core_surface.mouseButtonCallback(.release, button.core(), mods) catch |err|
                    log.warn("mouse button callback failed err={}", .{err});
            }

            // No leave (`Mouse.sync`): the next captured move supplies the
            // real position.
            if (!sync.leave) m.pos = last;
        }

        // Then the leave. If the pointer is in fact over the window, the
        // next WM_MOUSEMOVE re-enters and re-arms tracking.
        if (sync.leave) {
            m.pos = Mouse.outside;
            m.tracking = false;
            core_surface.cursorPosCallback(Mouse.outside, null) catch |err|
                log.warn("cursor pos callback failed err={}", .{err});
        }
        return true;
    }

    /// A wheel message's screen point as a client position, clamped into
    /// the client area, and whether the pointer is over this window's
    /// client area with nothing covering it there. Null only if Win32
    /// cannot say.
    fn wheelPoint(self: *const Surface, lparam: win32.LPARAM) ?struct {
        pos: apprt.CursorPos,
        over: bool,
    } {
        const screen: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
        var pt = screen;
        if (!win32.ScreenToClient(self.hwnd, &pt).toBool()) return null;
        var rect: win32.RECT = undefined;
        if (!win32.GetClientRect(self.hwnd, &rect).toBool()) return null;
        const in = clampToRect(pt, rect);
        const under = win32.WindowFromPoint(screen);
        return .{
            .pos = .{ .x = @floatFromInt(in.x), .y = @floatFromInt(in.y) },
            .over = in.x == pt.x and in.y == pt.y and under == self.hwnd,
        };
    }

    /// Give the core a real pointer position, unless it already has it.
    ///
    /// Repeats are dropped, as GTK drops sub-pixel moves: Win32 sends
    /// WM_MOUSEMOVE without movement when windows appear, disappear or move,
    /// and every cursorPosCallback shows a mouse hidden while typing
    /// (`Surface.cursorPosCallback`).
    fn movePointer(
        self: *Surface,
        core_surface: *CoreSurface,
        pos: apprt.CursorPos,
        mods: input.Mods,
    ) void {
        const m = &self.mouse;
        // A real position replaces a leave that could not be delivered.
        m.leave_owed = false;
        if (pos.x == m.pos.x and pos.y == m.pos.y) return;
        m.pos = pos;
        core_surface.cursorPosCallback(pos, mods) catch |err|
            log.warn("cursor pos callback failed err={}", .{err});
    }

    /// A client-area button message, after handleMessage has mapped it.
    fn mouseButton(
        self: *Surface,
        core_surface: *CoreSurface,
        button: Mouse.Button,
        state: input.MouseButtonState,
        wparam: win32.WPARAM,
        pos: apprt.CursorPos,
        mods: input.Mods,
    ) void {
        const m = &self.mouse;
        const down = Mouse.Button.downIn(wparam);
        switch (state) {
            .press => {
                // Dropped entirely, capture included, so its release is
                // dropped too (below).
                if (!self.syncMouse(core_surface, down)) return;

                // Capture on the first button, so the release comes here
                // even when it happens outside the window. Without it the
                // core would keep the button pressed and report every later
                // move as a drag.
                if (m.held.count() == 0) _ = win32.SetCapture(self.hwnd);
                m.held.insert(button);
                if (button == .left) m.left_press_pos = pos;
            },
            .release => {
                // The core never saw this press: an activation click eaten
                // by WM_MOUSEACTIVATE, a press dropped above, one from before
                // the core existed, or one whose release syncMouse already
                // sent. A lone release is not harmless: a left one can open
                // a link (`Surface.mouseButtonCallback`).
                if (!m.held.contains(button)) return;
                m.held.remove(button);
                if (m.held.count() == 0) _ = win32.ReleaseCapture();

                if (!self.syncMouse(core_surface, down)) {
                    m.owed.insert(button);
                    return;
                }
            },
        }

        // The core reads the event position back through getCursorPos, so it
        // must be current first. Link hover and the drag state also change
        // only in cursorPosCallback.
        self.movePointer(core_surface, pos, mods);

        // The result (false = "show your context menu" for a right press)
        // has no consumer: there is no menu. With the default
        // right-click-action, a right click therefore only selects the word
        // or link under the pointer (`Surface.mouseButtonCallback`).
        _ = core_surface.mouseButtonCallback(state, button.core(), mods) catch |err|
            log.warn("mouse button callback failed err={}", .{err});

        // `self` and `core_surface` are still valid here. A press can open a
        // paste confirmation (clipboardRequest -> confirm), but a prompt only
        // defers teardown (destroyPosted), and no mouse callback closes the
        // surface. If that prompt took the capture, `held` still names the
        // button and the next syncMouse releases it.

        if (state == .release and m.held.count() == 0) {
            // Released outside the window: arming now posts WM_MOUSELEAVE at
            // once, and its handler reports the leave. Released inside: this
            // is the tracking the drag skipped.
            self.trackLeave();
        }
    }

    /// Arm leave tracking when the pointer comes over the client area, but
    /// not during a drag: the pointer may be outside then, and arming there
    /// posts a WM_MOUSELEAVE at once, on every move. The final release arms
    /// it instead (mouseButton).
    fn armLeave(self: *Surface) void {
        if (self.mouse.tracking or self.mouse.held.count() != 0) return;
        self.trackLeave();
    }

    /// Ask for WM_MOUSELEAVE when the pointer leaves the client area.
    /// One-shot: Win32 cancels tracking when it posts the leave, and posts it
    /// at once if the pointer is not over the window now.
    fn trackLeave(self: *Surface) void {
        var tme: win32.TRACKMOUSEEVENT = .{
            .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
            .dwFlags = win32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        if (!win32.TrackMouseEvent(&tme).toBool()) {
            log.warn("TrackMouseEvent failed err={}", .{win32.GetLastError()});
        }
        // Set even on failure: retrying on every move cannot help, and a
        // missed leave only leaves hover state stale until the next one.
        self.mouse.tracking = true;
    }

    fn hasCapture(self: *const Surface) bool {
        const capture = win32.GetCapture() orelse return false;
        return capture == self.hwnd;
    }

    /// `.mouse_shape`. Called while the core may hold the renderer mutex
    /// (from `Surface.mouseRefreshLinks`), so this must not call
    /// back into the core or run a message loop, and must not fail: an error
    /// would abort cursorPosCallback. It does neither.
    pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) bool {
        const m = &self.mouse;
        // Modifier keys resend the current shape on every key event
        // (`Surface.keyCallback`).
        if (shape == m.shape and m.cursor != null) return true;
        const cursor = win32.LoadCursorW(null, cursorId(shape)) orelse {
            log.warn("LoadCursorW failed shape={}", .{shape});
            return false;
        };
        m.shape = shape;
        m.cursor = cursor;
        self.applyCursor();
        return true;
    }

    /// `.mouse_visibility`. Same constraints as `setMouseShape`.
    pub fn setMouseVisibility(self: *Surface, value: apprt.action.MouseVisibility) bool {
        const hidden = value == .hidden;
        if (hidden == self.mouse.hidden) return true;
        self.mouse.hidden = hidden;
        self.applyCursor();
        return true;
    }

    /// The pointer this window wants over its client area: none while
    /// hidden, otherwise the current shape.
    fn clientCursor(self: *const Surface) ?win32.HCURSOR {
        return if (self.mouse.hidden) null else self.mouse.cursor;
    }

    /// Apply `clientCursor` now if the pointer is this window's: over its
    /// client area (leave tracking is armed) or captured for its own drag.
    /// WM_SETCURSOR would otherwise apply it only on the next move, and is
    /// not sent at all while the mouse is captured. SetCursor is documented
    /// for exactly these two cases.
    ///
    /// Not during a system size/move or menu loop: that loop holds the
    /// capture on the frame and sets its own cursor, which nothing would
    /// restore while captured.
    fn applyCursor(self: *Surface) void {
        if (self.window.modal_loops.inLoop()) return;
        const own_drag = self.mouse.held.count() != 0 and self.hasCapture();
        if (!self.mouse.tracking and !own_drag) return;
        if (self.mouse.hidden or self.mouse.cursor != null) {
            _ = win32.SetCursor(self.clientCursor());
        }
    }

    /// Modifiers for a mouse message, binding modifiers only.
    ///
    /// Shift and Ctrl come from the message's own MK_ flags, which describe
    /// the state at the time of the event. Alt and the Windows key have no
    /// flag and come from GetKeyState, which only follows key messages this
    /// thread has read: with the keyboard focus elsewhere it can report a
    /// key as still down (an Alt+Tab whose Alt-up went to another window),
    /// so they are left out then.
    ///
    /// binding() because the core compares its stored mods with each event's
    /// (`Surface.modsChanged`): lock and side bits would make every mouse
    /// event a mods change, which redraws every row.
    fn mouseMods(self: *const Surface, wparam: win32.WPARAM) input.Mods {
        var mods: input.Mods = if (self.focused) currentMods().binding() else .{};
        mods.shift = wparam & win32.MK_SHIFT != 0;
        mods.ctrl = wparam & win32.MK_CONTROL != 0;
        return mods;
    }

    /// The text a keystroke produced, collected from WM_(SYS)(DEAD)CHAR.
    const Text = struct {
        /// UTF-16 code units as received. One keystroke yields at most a few
        /// (a surrogate pair, or a layout's ligature); extra units past the
        /// buffer are still removed from the queue, just not kept.
        units: [16]u16 = undefined,
        units_len: usize = 0,

        /// The UTF-8 result, valid after `finish`.
        bytes: [64]u8 = undefined,
        len: usize = 0,

        /// A WM_DEADCHAR / WM_SYSDEADCHAR was seen: this is preedit.
        composing: bool = false,

        /// At least one unit came from WM_CHAR / WM_DEADCHAR (as opposed to
        /// the WM_SYS* variants, which mean Alt without Ctrl).
        from_char: bool = false,

        fn utf8(self: *const Text) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Remove every pending character message for `hwnd` and convert.
        ///
        /// Two separate peeks, never one over 0x0102-0x0107: that range
        /// also contains WM_SYSKEYDOWN (0x0104) and WM_SYSKEYUP (0x0105),
        /// which a single peek would swallow.
        fn collect(self: *Text, hwnd: win32.HWND, carry: *?u16) void {
            const ranges = [_][2]win32.UINT{
                .{ win32.WM_CHAR, win32.WM_DEADCHAR },
                .{ win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR },
            };
            var m: win32.MSG = undefined;
            for (ranges) |r| {
                while (win32.PeekMessageW(&m, hwnd, r[0], r[1], win32.PM_REMOVE).toBool()) {
                    self.add(m.message, @truncate(m.wParam));
                }
            }
            self.finish(carry);
        }

        fn add(self: *Text, msg: win32.UINT, unit: u16) void {
            if (msg == win32.WM_DEADCHAR or msg == win32.WM_SYSDEADCHAR) {
                self.composing = true;
            }
            if (msg == win32.WM_CHAR or msg == win32.WM_DEADCHAR) {
                self.from_char = true;
            }
            if (self.units_len == self.units.len) return;
            self.units[self.units_len] = unit;
            self.units_len += 1;
        }

        /// Decode the units, dropping C0 controls and DEL as GTK does
        /// (the GTK `Surface.keyEvent` IM filter): the encoder derives
        /// Ctrl+letter, Enter, Tab, Backspace and Esc from the physical key
        /// and the unshifted codepoint, and would double them otherwise.
        ///
        /// `carry` holds a surrogate pair split between two texts (see
        /// `Surface.high_surrogate`): a high surrogate the previous text
        /// ended with is decoded ahead of these units, and one these units
        /// end with is left in `carry` for the next text instead. Other
        /// unpaired surrogates are dropped rather than failing the
        /// keystroke; a carried one that no low surrogate follows is too.
        fn finish(self: *Text, carry: *?u16) void {
            var units: [self.units.len + 1]u16 = undefined;
            var end: usize = 0;
            if (carry.*) |unit| {
                units[0] = unit;
                end = 1;
            }
            @memcpy(units[end..][0..self.units_len], self.units[0..self.units_len]);
            end += self.units_len;

            carry.* = null;
            if (end > 0 and std.unicode.utf16IsHighSurrogate(units[end - 1])) {
                end -= 1;
                carry.* = units[end];
            }

            self.len = 0;
            var it = std.unicode.Utf16LeIterator.init(units[0..end]);
            while (true) {
                const cp = it.nextCodepoint() catch continue orelse break;
                if (cp < 0x20 or cp == 0x7F) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                if (self.len + n > self.bytes.len) break;
                @memcpy(self.bytes[self.len..][0..n], buf[0..n]);
                self.len += n;
            }
        }
    };

    pub fn wndProc(
        hwnd: win32.HWND,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) callconv(.winapi) win32.LRESULT {
        // WM_NCCREATE is the first message that carries the CREATESTRUCTW, so
        // it is the earliest point at which the Surface pointer can be
        // attached. Messages that arrive before it (WM_GETMINMAXINFO does)
        // find a zero GWLP_USERDATA and fall through to DefWindowProcW, which
        // is why the null check below is not optional.
        if (msg == win32.WM_NCCREATE) {
            const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (cs.lpCreateParams) |param| {
                const self: *Surface = @ptrCast(@alignCast(param));
                self.hwnd = hwnd;
                _ = win32.SetWindowLongPtrW(
                    hwnd,
                    win32.GWLP_USERDATA,
                    @bitCast(@intFromPtr(self)),
                );
            }

            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        }

        const self: *Surface = ptr: {
            const v = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
            if (v == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            break :ptr @ptrFromInt(@as(usize, @bitCast(v)));
        };

        return self.handleMessage(hwnd, msg, wparam, lparam);
    }
};

// -------------------------------------------------------------------------
// Win32 helpers
// -------------------------------------------------------------------------

/// A point beyond the client area, past the corner farthest from `press`
/// on each axis. The core clamps it to that corner's cell
/// (the `.grid` arm of `renderer.size.Coordinate.convert`).
fn releasePoint(screen: renderer.ScreenSize, press: apprt.CursorPos) apprt.CursorPos {
    const w: f32 = @floatFromInt(screen.width);
    const h: f32 = @floatFromInt(screen.height);
    return .{
        .x = if (press.x < w / 2) w + 1 else -1,
        .y = if (press.y < h / 2) h + 1 else -1,
    };
}

/// The client-area position in a mouse message's lParam. These are already
/// device pixels, because the process is per-monitor-v2 DPI aware
/// (dist/windows/ghostty.manifest), and that is the unit the core expects
/// (the GTK runtime scales to it).
fn clientPos(lparam: win32.LPARAM) apprt.CursorPos {
    return .{
        .x = @floatFromInt(win32.xLparam(lparam)),
        .y = @floatFromInt(win32.yLparam(lparam)),
    };
}

/// What a terminal window's WM_SIZE tells the core. The window is a child
/// of its frame, which is the one minimized (`Window.handleMessage`).
const SizeChange = union(enum) {
    /// Not resized: the grid is clamped to at least 1x1
    /// (`renderer.size.GridSize.update`), so a zero dimension (a window
    /// dragged to zero height) would reflow every line to one column and
    /// back.
    empty,

    /// At this client size in physical pixels (PerMonitorV2).
    resize: apprt.SurfaceSize,

    fn init(lparam: win32.LPARAM) SizeChange {
        const width = win32.loword(lparam);
        const height = win32.hiword(lparam);
        if (width == 0 or height == 0) return .empty;
        return .{ .resize = .{ .width = width, .height = height } };
    }
};

/// The point of `rect` nearest to `pt`. A RECT excludes its right and bottom
/// edges; an empty one gives its top-left corner.
fn clampToRect(pt: win32.POINT, rect: win32.RECT) win32.POINT {
    return .{
        .x = @max(rect.left, @min(pt.x, rect.right - 1)),
        .y = @max(rect.top, @min(pt.y, rect.bottom - 1)),
    };
}

/// SPI_GETWHEELSCROLLLINES or SPI_GETWHEELSCROLLCHARS, read for every wheel
/// message so a change in Settings applies at once without tracking
/// WM_SETTINGCHANGE. Windows' default if the call fails.
fn wheelSetting(action: win32.UINT) u32 {
    var value: win32.UINT = Surface.Mouse.Notches.per_tick;
    if (!win32.SystemParametersInfoW(action, 0, &value, 0).toBool()) {
        log.warn("SystemParametersInfoW failed action=0x{x} err={}", .{
            action,
            win32.GetLastError(),
        });
        return Surface.Mouse.Notches.per_tick;
    }
    return value;
}

/// The stock cursor for a W3C cursor shape. Win32 has no cell,
/// vertical-text, alias, copy, grab, zoom or context-menu cursor; those use
/// the nearest stock cursor or the arrow. An exhaustive switch, so a new
/// shape does not compile until it is mapped.
fn cursorId(shape: terminal.MouseShape) win32.ResourceW {
    return switch (shape) {
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => win32.IDC_ARROW,
        .text, .vertical_text => win32.IDC_IBEAM,
        .pointer, .grab, .grabbing => win32.IDC_HAND,
        .help => win32.IDC_HELP,
        .progress => win32.IDC_APPSTARTING,
        .wait => win32.IDC_WAIT,
        .crosshair, .cell => win32.IDC_CROSS,
        .move, .all_scroll => win32.IDC_SIZEALL,
        .no_drop, .not_allowed => win32.IDC_NO,
        .col_resize, .ew_resize, .e_resize, .w_resize => win32.IDC_SIZEWE,
        .row_resize, .ns_resize, .n_resize, .s_resize => win32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => win32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => win32.IDC_SIZENWSE,
    };
}

test "win32: mouse lParam coordinates are signed" {
    // (-5, -7) as the system packs it: MAKELPARAM of two shorts.
    const pos = clientPos(@bitCast(@as(usize, 0xFFF9_FFFB)));
    try std.testing.expectEqual(@as(f32, -5), pos.x);
    try std.testing.expectEqual(@as(f32, -7), pos.y);
}

test "win32: wheel deltas add up to whole notches" {
    const thirds: [9]i32 = @splat(40);
    const ones: [360]i32 = @splat(1);
    const cases = [_][]const i32{ &.{ 120, 120, 120 }, &thirds, &.{ 90, 90, 90, 90 }, &ones };
    for (cases) |deltas| {
        for ([_]i32{ 1, -1 }) |sign| {
            var n: Surface.Mouse.Notches = .{};
            var total: i64 = 0;
            for (deltas) |d| total += n.add(sign * d, 3) orelse 0;
            try std.testing.expectEqual(3 * sign, total);
            try std.testing.expectEqual(0, n.rem);
        }
    }

    // A reversal is not absorbed by the other direction's remainder.
    var n: Surface.Mouse.Notches = .{};
    try std.testing.expectEqual(null, n.add(60, 3));
    try std.testing.expectEqual(-1, n.add(-120, 3));
}

test "win32: wheel ticks follow the lines to scroll per notch" {
    const Case = struct { per_notch: u32, ticks: []const ?i64 };
    const cases = [_]Case{
        // A tick is three lines, so these scroll 1, 6 and 10 per notch.
        .{ .per_notch = 1, .ticks = &.{ null, null, 1 } },
        .{ .per_notch = 6, .ticks = &.{ 2, 2 } },
        .{ .per_notch = 10, .ticks = &.{ 3, 3, 4 } },
        // Zero turns the wheel off.
        .{ .per_notch = 0, .ticks = &.{ null, null, null } },
    };
    for (cases) |c| {
        var n: Surface.Mouse.Notches = .{};
        for (c.ticks) |ticks| try std.testing.expectEqual(ticks, n.add(120, c.per_notch));
        try std.testing.expectEqual(0, n.rem);
    }

    // A screen's worth of lines, or any other UINT, does not overflow.
    var n: Surface.Mouse.Notches = .{};
    try std.testing.expectEqual(1_431_655_764, n.add(120, std.math.maxInt(u32) - 1).?);
}

test "win32: wheel points off the client area clamp to its edge" {
    const rect: win32.RECT = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const Case = struct { pt: win32.POINT, in: win32.POINT };
    const cases = [_]Case{
        .{ .pt = .{ .x = 10, .y = 20 }, .in = .{ .x = 10, .y = 20 } },
        // The caption and the left border: above and left of the client.
        .{ .pt = .{ .x = 300, .y = -15 }, .in = .{ .x = 300, .y = 0 } },
        .{ .pt = .{ .x = -4, .y = 200 }, .in = .{ .x = 0, .y = 200 } },
        // Right and bottom are outside the RECT.
        .{ .pt = .{ .x = 800, .y = 600 }, .in = .{ .x = 799, .y = 599 } },
        .{ .pt = .{ .x = 5000, .y = -5000 }, .in = .{ .x = 799, .y = 0 } },
    };
    for (cases) |c| try std.testing.expectEqual(c.in, clampToRect(c.pt, rect));

    // A minimized window's empty client area.
    const empty: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    try std.testing.expectEqual(win32.POINT{ .x = 0, .y = 0 }, clampToRect(.{ .x = 9, .y = -9 }, empty));
}

test "win32: mouse message button bits" {
    // Raw wParams as the system packs them, so a wrong MK_ or XBUTTON
    // constant fails here: MK_LBUTTON 0x01, MK_RBUTTON 0x02, MK_SHIFT 0x04,
    // MK_CONTROL 0x08, MK_MBUTTON 0x10, MK_XBUTTON1 0x20, MK_XBUTTON2 0x40.
    const Button = Surface.Mouse.Button;
    try std.testing.expect(Button.downIn(0).eql(.empty));
    try std.testing.expect(Button.downIn(0x0045).eql(.initMany(&.{ .left, .x2 })));
    try std.testing.expect(Button.downIn(0x003A).eql(.initMany(&.{ .right, .middle, .x1 })));

    // GET_XBUTTON_WPARAM: XBUTTON1 is 1 and XBUTTON2 is 2 in the high
    // word; the low word holds the MK_ bits.
    try std.testing.expectEqual(Button.x2, Button.fromMessage(win32.WM_XBUTTONUP, 0x0002_0000).?);
    try std.testing.expectEqual(Button.x1, Button.fromMessage(win32.WM_XBUTTONDOWN, 0x0001_0020).?);
    try std.testing.expectEqual(null, Button.fromMessage(win32.WM_XBUTTONDOWN, 0x0003_0000));
}

test "win32: mouse sync owes a release for each button no longer down" {
    const Mouse = Surface.Mouse;
    const Set = Mouse.Button.Set;
    const Case = struct {
        held: Set,
        owed: Set = .empty,
        leave_owed: bool = false,
        captured: bool,
        down: ?Set,
        want: Mouse.Sync,
        held_after: Set,
    };
    const cases = [_]Case{
        // The capture was taken away (a prompt, the focus) with two
        // buttons held: both are released, then the pointer leaves.
        .{
            .held = .initMany(&.{ .left, .right }),
            .captured = false,
            .down = null,
            .want = .{ .release = .initMany(&.{ .left, .right }), .leave = true },
            .held_after = .empty,
        },
        // One of two buttons let go elsewhere: no leave, since the other
        // button is still dragging.
        .{
            .held = .initMany(&.{ .left, .right }),
            .captured = true,
            .down = .initOne(.right),
            .want = .{ .release = .initOne(.left) },
            .held_after = .initOne(.right),
        },
        // The last button let go elsewhere while captured.
        .{
            .held = .initOne(.left),
            .captured = true,
            .down = .empty,
            .want = .{ .release = .initOne(.left), .release_capture = true, .leave = true },
            .held_after = .empty,
        },
        // Captured, and no message to say otherwise: still held.
        .{
            .held = .initOne(.left),
            .captured = true,
            .down = null,
            .want = .{},
            .held_after = .initOne(.left),
        },
        // A button the core never saw pressed is not released.
        .{
            .held = .initOne(.left),
            .captured = true,
            .down = .initMany(&.{ .left, .right }),
            .want = .{},
            .held_after = .initOne(.left),
        },
        // A release and a leave that came while a prompt was open.
        .{
            .held = .empty,
            .owed = .initOne(.middle),
            .captured = false,
            .down = .empty,
            .want = .{ .release = .initOne(.middle), .leave = true },
            .held_after = .empty,
        },
        .{
            .held = .empty,
            .leave_owed = true,
            .captured = false,
            .down = null,
            .want = .{ .leave = true },
            .held_after = .empty,
        },
    };
    for (cases) |c| {
        var m: Mouse = .init();
        m.held = c.held;
        m.owed = c.owed;
        m.leave_owed = c.leave_owed;
        const got = m.sync(c.captured, c.down);
        try std.testing.expect(got.release.eql(c.want.release));
        try std.testing.expectEqual(c.want.release_capture, got.release_capture);
        try std.testing.expectEqual(c.want.leave, got.leave);
        try std.testing.expect(m.held.eql(c.held_after));
        try std.testing.expect(m.owed.eql(.empty));
        try std.testing.expectEqual(c.leave_owed and !got.leave, m.leave_owed);
    }

    // For every held set, every `down` and either capture state: a button
    // ends up still held or released, never both, never lost, and never
    // one that was not held.
    const buttons = comptime std.enums.values(Mouse.Button);
    const all = 1 << buttons.len;
    const setOf = struct {
        fn f(bits: usize) Set {
            var set: Set = .empty;
            for (buttons, 0..) |b, i| {
                if (bits & (@as(usize, 1) << @intCast(i)) != 0) set.insert(b);
            }
            return set;
        }
    }.f;
    for (0..all) |held_bits| {
        // One past the last set stands for no message (`down == null`).
        for (0..all + 1) |down_bits| {
            for ([_]bool{ false, true }) |captured| {
                var m: Mouse = .init();
                m.held = setOf(held_bits);
                const down: ?Set = if (down_bits == all) null else setOf(down_bits);
                const got = m.sync(captured, down);
                try std.testing.expect(got.release.intersectWith(m.held).eql(.empty));
                try std.testing.expect(got.release.unionWith(m.held).eql(setOf(held_bits)));
            }
        }
    }
}

test "win32: an invented release lands on another cell than the press" {
    // An 80x24 grid of 10x20 cells with 2 px of padding, and the leftover
    // pixels at the right and bottom, as without padding balance.
    const size: renderer.Size = .{
        .screen = .{ .width = 805, .height = 489 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{ .top = 2, .bottom = 2, .left = 2, .right = 2 },
    };
    const grid = size.grid();
    try std.testing.expectEqual(80, grid.columns);
    try std.testing.expectEqual(24, grid.rows);

    const cell = struct {
        fn at(pos: apprt.CursorPos, s: renderer.Size) renderer.Coordinate.Grid {
            const surface: renderer.Coordinate = .{ .surface = .{ .x = pos.x, .y = pos.y } };
            return surface.convert(.grid, s).grid;
        }
    }.at;

    var y: u32 = 0;
    while (y < size.screen.height) : (y += 1) {
        var x: u32 = 0;
        while (x < size.screen.width) : (x += 1) {
            const press: apprt.CursorPos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
            const release = releasePoint(size.screen, press);

            // Outside the client area on both axes.
            try std.testing.expect(release.x < 0 or release.x >= 805);
            try std.testing.expect(release.y < 0 or release.y >= 489);

            // A corner cell, in another column and another row than the
            // press: the corner farthest from it.
            const p = cell(press, size);
            const r = cell(release, size);
            try std.testing.expect(r.x == 0 or r.x == grid.columns - 1);
            try std.testing.expect(r.y == 0 or r.y == grid.rows - 1);
            try std.testing.expect(p.x != r.x);
            try std.testing.expect(p.y != r.y);
        }
    }
}

test "win32: an empty window is not resized" {
    // lParam MAKELPARAM(width, height).
    try std.testing.expectEqual(SizeChange.empty, SizeChange.init(0));
    try std.testing.expectEqual(SizeChange.empty, SizeChange.init(0x0190_0000));
    try std.testing.expectEqual(SizeChange.empty, SizeChange.init(0x0000_0280));
    try std.testing.expectEqual(
        SizeChange{ .resize = .{ .width = 1920, .height = 1080 } },
        SizeChange.init(0x0438_0780),
    );

    // Unsigned: a client size is never negative, unlike a mouse position.
    try std.testing.expectEqual(
        SizeChange{ .resize = .{ .width = 0x9000, .height = 0x8000 } },
        SizeChange.init(0x8000_9000),
    );
}

test "win32: key text drops controls and decodes surrogate pairs" {
    const Text = Surface.Text;
    const Case = struct { msg: win32.UINT, units: []const u16, want: []const u8 };
    const twenty_a: [20]u16 = @splat('a');
    const sixteen_a: [16]u8 = @splat('a');
    const cases = [_]Case{
        .{ .msg = win32.WM_CHAR, .units = &.{'a'}, .want = "a" },
        .{ .msg = win32.WM_CHAR, .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}" },
        // Backspace, Enter, Esc, Ctrl+A and Ctrl+Backspace's DEL: the
        // encoder derives these from the key.
        .{ .msg = win32.WM_CHAR, .units = &.{ 0x08, 0x0D, 0x1B, 0x01, 0x7F }, .want = "" },
        // An unpaired surrogate is dropped, not the rest of the keystroke.
        .{ .msg = win32.WM_CHAR, .units = &.{ 0xD800, 'a' }, .want = "a" },
        .{ .msg = win32.WM_CHAR, .units = &.{ 0xDE00, 'a' }, .want = "a" },
        .{ .msg = win32.WM_SYSCHAR, .units = &.{'x'}, .want = "x" },
        .{ .msg = win32.WM_CHAR, .units = &twenty_a, .want = &sixteen_a },
    };
    for (cases) |c| {
        var text: Text = .{};
        var carry: ?u16 = null;
        for (c.units) |u| text.add(c.msg, u);
        text.finish(&carry);
        try std.testing.expectEqualStrings(c.want, text.utf8());
        try std.testing.expectEqual(null, carry);
    }

    // Dead keys are preedit; only the non-SYS messages mean "not Alt alone".
    const Flags = struct { msg: win32.UINT, composing: bool, from_char: bool };
    const flags = [_]Flags{
        .{ .msg = win32.WM_CHAR, .composing = false, .from_char = true },
        .{ .msg = win32.WM_DEADCHAR, .composing = true, .from_char = true },
        .{ .msg = win32.WM_SYSCHAR, .composing = false, .from_char = false },
        .{ .msg = win32.WM_SYSDEADCHAR, .composing = true, .from_char = false },
    };
    for (flags) |f| {
        var text: Text = .{};
        var carry: ?u16 = null;
        text.add(f.msg, '^');
        text.finish(&carry);
        try std.testing.expectEqualStrings("^", text.utf8());
        try std.testing.expectEqual(f.composing, text.composing);
        try std.testing.expectEqual(f.from_char, text.from_char);
    }
}

test "win32: key text pairs surrogates split between keystrokes" {
    const Text = Surface.Text;
    const t = std.testing;

    // SendInput's U+1F600: one VK_PACKET keystroke per UTF-16 unit, each
    // with its own WM_CHAR. A keystroke with no text in between (a
    // modifier) keeps the high half waiting.
    var carry: ?u16 = null;
    const keystrokes = [_]struct { units: []const u16, want: []const u8, carry: ?u16 }{
        .{ .units = &.{0xD83D}, .want = "", .carry = 0xD83D },
        .{ .units = &.{}, .want = "", .carry = 0xD83D },
        .{ .units = &.{0xDE00}, .want = "\u{1F600}", .carry = null },
        // A high half that no low half follows is dropped, not the text.
        .{ .units = &.{0xD83D}, .want = "", .carry = 0xD83D },
        .{ .units = &.{'a'}, .want = "a", .carry = null },
        // A pair in one keystroke after text that ended with a high half.
        .{ .units = &.{ 'b', 0xD83D }, .want = "b", .carry = 0xD83D },
        .{ .units = &.{ 0xD83D, 0xDE00 }, .want = "\u{1F600}", .carry = null },
    };
    for (keystrokes) |k| {
        var text: Text = .{};
        for (k.units) |u| text.add(win32.WM_CHAR, u);
        text.finish(&carry);
        try t.expectEqualStrings(k.want, text.utf8());
        try t.expectEqual(k.carry, carry);
    }
}

test "win32: key modifiers for AltGr and consumed Shift" {
    const Case = struct {
        mods: input.Mods,
        msg: win32.UINT = win32.WM_CHAR,
        units: []const u16,
        shiftless: u21,
        want: input.Mods,
        consumed: input.Mods = .{},
    };
    const cases = [_]Case{
        // German AltGr+Q: '@' arrives as WM_CHAR under LCtrl+RAlt.
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .units = &.{'@'},
            .shiftless = 'q',
            .want = .{},
        },
        // Alt+A keeps its Alt, so the encoder prefixes ESC.
        .{
            .mods = .{ .alt = true },
            .msg = win32.WM_SYSCHAR,
            .units = &.{'a'},
            .shiftless = 'a',
            .want = .{ .alt = true },
        },
        // Text only from WM_SYSCHAR is Alt's, not AltGr's, even with Ctrl
        // down: Ctrl+Alt keeps both.
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .msg = win32.WM_SYSCHAR,
            .units = &.{'a'},
            .shiftless = 'a',
            .want = .{ .ctrl = true, .alt = true },
        },
        // Ctrl+Alt with no text, or only a dropped control character, is
        // a chord, not AltGr.
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .units = &.{},
            .shiftless = 'a',
            .want = .{ .ctrl = true, .alt = true },
        },
        .{
            .mods = .{ .ctrl = true, .alt = true },
            .units = &.{0x01},
            .shiftless = 'a',
            .want = .{ .ctrl = true, .alt = true },
        },
        // Shift that changed the character was consumed; it stays in mods.
        .{
            .mods = .{ .shift = true },
            .units = &.{'A'},
            .shiftless = 'a',
            .want = .{ .shift = true },
            .consumed = .{ .shift = true },
        },
        .{
            .mods = .{ .shift = true },
            .units = &.{'!'},
            .shiftless = '1',
            .want = .{ .shift = true },
            .consumed = .{ .shift = true },
        },
        // Caps Lock+Shift+A gives "a", which Shift changed from "A".
        .{
            .mods = .{ .shift = true, .caps_lock = true },
            .units = &.{'a'},
            .shiftless = 'A',
            .want = .{ .shift = true, .caps_lock = true },
            .consumed = .{ .shift = true },
        },
        // Shift that did not change it, or whose text was dropped
        // (Shift+Enter), was not: the encoder still needs it.
        .{
            .mods = .{ .shift = true },
            .units = &.{' '},
            .shiftless = ' ',
            .want = .{ .shift = true },
        },
        .{
            .mods = .{ .shift = true },
            .units = &.{0x0D},
            .shiftless = 0x0D,
            .want = .{ .shift = true },
        },
    };
    for (cases) |c| {
        var text: Surface.Text = .{};
        var carry: ?u16 = null;
        for (c.units) |u| text.add(c.msg, u);
        text.finish(&carry);
        const got = Surface.keyMods(c.mods, &text, c.shiftless, Surface.isAltGr(c.mods, &text));
        try std.testing.expectEqual(c.want, got.mods);
        try std.testing.expectEqual(c.consumed, got.consumed);
    }
}

test "win32: AltGr's release reports its press's modifiers" {
    const t = std.testing;
    const ctrl_alt: input.Mods = .{ .ctrl = true, .alt = true };
    var held: std.bit_set.Static(512) = .empty;
    const q = 0x10;
    const a = 0x1E;

    // German AltGr+Q: '@' on the press and the repeat, no text on the
    // release, with LCtrl+RAlt down throughout. All three report neither.
    var at: Surface.Text = .{};
    var carry: ?u16 = null;
    at.add(win32.WM_CHAR, '@');
    at.finish(&carry);
    const none: Surface.Text = .{};
    for ([_]struct { input.Action, *const Surface.Text }{
        .{ .press, &at },
        .{ .repeat, &at },
        .{ .release, &none },
    }) |ev| {
        const alt_gr = Surface.altGrKey(&held, q, ev[0], ctrl_alt, ev[1]);
        try t.expect(alt_gr);
        try t.expectEqual(input.Mods{}, Surface.keyMods(ctrl_alt, ev[1], 'q', alt_gr).mods);
    }
    try t.expect(!held.isSet(q));

    // A Ctrl+Alt chord that types nothing keeps both on press and release,
    // and a release whose press was AltGr does not leak to another key.
    _ = Surface.altGrKey(&held, q, .press, ctrl_alt, &at);
    try t.expect(!Surface.altGrKey(&held, a, .press, ctrl_alt, &none));
    try t.expect(!Surface.altGrKey(&held, a, .release, ctrl_alt, &none));
    try t.expect(Surface.altGrKey(&held, q, .release, ctrl_alt, &none));
}

test "win32: the first Shift released of two is owed a release" {
    const t = std.testing;

    // LShift and RShift pressed, then both released: Windows sends a key-up
    // for only one of them.
    var shift: Surface.ShiftKeys = .{};
    shift.sent(.shift_left, .press);
    shift.sent(.shift_right, .press);
    shift.sent(.shift_right, .release);
    try t.expectEqual(input.Key.shift_left, shift.owed(false, false));
    shift.sent(.shift_left, .release);
    try t.expectEqual(null, shift.owed(false, false));

    // Not while that Shift is still down.
    shift.sent(.shift_left, .press);
    shift.sent(.shift_right, .press);
    shift.sent(.shift_right, .release);
    try t.expectEqual(null, shift.owed(true, false));

    // Never for a Shift whose press the core did not see.
    shift = .{};
    shift.sent(.shift_right, .press);
    shift.sent(.shift_right, .release);
    try t.expectEqual(null, shift.owed(false, false));
}

test "win32: ime plan for a composition message" {
    const Ime = Surface.Ime;
    const A = Ime.Action;
    const comp = win32.GCS_COMPSTR;
    const result = win32.GCS_RESULTSTR;
    const cursor_pos = win32.GCS_CURSORPOS;
    const attr_clause = win32.GCS_COMPATTR | win32.GCS_COMPCLAUSE;
    const result_clause = win32.GCS_RESULTCLAUSE;

    const Case = struct { bits: u32, owner: Ime.Preedit, safe: bool, want: []const A };
    const cases = [_]Case{
        // No flag at all: cancelled. Only the IME's own preedit is cleared.
        .{ .bits = 0, .owner = .ime, .safe = true, .want = &.{.clear_preedit} },
        .{ .bits = 0, .owner = .dead_key, .safe = true, .want = &.{} },
        .{ .bits = 0, .owner = .none, .safe = true, .want = &.{} },
        // Flags outside GCS_ALL do not make it a live update.
        .{ .bits = 0x4000, .owner = .ime, .safe = true, .want = &.{.clear_preedit} },

        // A caret or clause change is a live update, never a cancel.
        .{ .bits = cursor_pos, .owner = .ime, .safe = true, .want = &.{.update_preedit} },
        .{ .bits = attr_clause, .owner = .ime, .safe = true, .want = &.{.update_preedit} },
        .{ .bits = comp, .owner = .none, .safe = true, .want = &.{.update_preedit} },

        // A result is delivered whatever the owner says, preedit cleared first.
        .{ .bits = result, .owner = .none, .safe = true, .want = &.{.commit_result} },
        .{ .bits = result | result_clause, .owner = .ime, .safe = true, .want = &.{ .clear_preedit, .commit_result } },
        .{ .bits = result, .owner = .dead_key, .safe = true, .want = &.{ .clear_preedit, .commit_result } },
        // Korean: a syllable is committed and the next one starts at once.
        .{ .bits = result | comp, .owner = .ime, .safe = true, .want = &.{ .clear_preedit, .commit_result, .update_preedit } },

        // Without the core nothing calls it: results wait, the rest is dropped.
        .{ .bits = 0, .owner = .ime, .safe = false, .want = &.{} },
        .{ .bits = comp, .owner = .ime, .safe = false, .want = &.{} },
        .{ .bits = result, .owner = .ime, .safe = false, .want = &.{.defer_result} },
        .{ .bits = result | comp, .owner = .none, .safe = false, .want = &.{.defer_result} },
    };
    for (cases) |c| {
        const got = Ime.plan(c.bits, c.owner, c.safe);
        try std.testing.expectEqualSlices(A, c.want, got.actions());
    }

    // A deferred result (`flushIme`) replaces the same preedits.
    try std.testing.expect(!Ime.Preedit.none.clearedByCommit());
    try std.testing.expect(Ime.Preedit.dead_key.clearedByCommit());
    try std.testing.expect(Ime.Preedit.ime.clearedByCommit());

    // Every result is either committed or deferred, for every input.
    for ([_]Ime.Preedit{ .none, .dead_key, .ime }) |owner| {
        for ([_]bool{ false, true }) |safe| {
            for ([_]u32{ result, result | comp, result | cursor_pos, win32.GCS_ALL }) |bits| {
                var delivered: usize = 0;
                for (Ime.plan(bits, owner, safe).actions()) |a| {
                    if (a == .commit_result or a == .defer_result) delivered += 1;
                }
                try std.testing.expectEqual(1, delivered);
            }
        }
    }
}

test "win32: ime forms follow the cursor cell" {
    const Ime = Surface.Ime;
    const client: win32.RECT = .{ .left = 0, .top = 0, .right = 2000, .bottom = 1000 };

    // 200% DPI, 20x40 px cells, cursor at column 3, row 2, two cells of
    // preedit. The core reports the cell's middle and bottom in 96-DPI
    // pixels, and the width in physical pixels.
    const pos: apprt.IMEPos = .{ .x = (3 * 20 + 10) / 2.0, .y = (3 * 40) / 2.0, .width = 40, .height = 40 / 2.0 };
    const form = Ime.formFor(pos, 2.0, 20, client);
    try std.testing.expectEqual(win32.RECT{ .left = 60, .top = 80, .right = 100, .bottom = 120 }, form.rc);
    try std.testing.expectEqual(win32.POINT{ .x = 60, .y = 120 }, form.pt);

    // No preedit yet: one cell wide.
    var none = pos;
    none.width = 0;
    try std.testing.expectEqual(@as(win32.LONG, 80), Ime.formFor(none, 2.0, 20, client).rc.right);

    // Never outside the client area, whatever the core reports.
    const wild: apprt.IMEPos = .{ .x = 5000, .y = -50, .width = std.math.nan(f64), .height = 1e12 };
    const clamped = Ime.formFor(wild, 2.0, 20, client).rc;
    try std.testing.expect(clamped.left >= 0 and clamped.right <= 2000 and clamped.left <= clamped.right);
    try std.testing.expect(clamped.top >= 0 and clamped.bottom <= 1000 and clamped.top <= clamped.bottom);
}

test "win32: ime message fields" {
    const Ime = Surface.Ime;

    // ISC_SHOWUICOMPOSITIONWINDOW is bit 31 of a sign-extended value.
    const all: win32.LPARAM = @bitCast(@as(usize, 0xFFFF_FFFF_C000_000F));
    const want: win32.LPARAM = @bitCast(@as(usize, 0xFFFF_FFFF_4000_000F));
    try std.testing.expectEqual(want, Ime.setContextLparam(all));
    try std.testing.expectEqual(@as(win32.LPARAM, 0x4000_000F), Ime.setContextLparam(0x4000_000F));

    // Scan code 0x1E, not extended; then the same with the extended flag.
    try std.testing.expectEqual(@as(usize, 0x01E), Ime.scanSlot(0x001E_0001));
    try std.testing.expectEqual(@as(usize, 0x11E), Ime.scanSlot(@bitCast(@as(usize, 0xC11E_0001))));
}

test "win32: ime withholds the release of a key it claimed" {
    const Ime = Surface.Ime;
    const down = win32.WM_KEYDOWN;
    const up = win32.WM_KEYUP;
    const vk_a: win32.WPARAM = 0x41;
    // Scan code 0x1E (A): its key-down, its key-up, and the same key with
    // the extended flag, which is another slot.
    const a_down: win32.LPARAM = 0x001E_0001;
    const a_up: win32.LPARAM = @bitCast(@as(usize, 0xC01E_0001));
    const ext_up: win32.LPARAM = @bitCast(@as(usize, 0xC11E_0001));

    // A key the IME never claimed reaches the core both ways.
    {
        var ime: Ime = .{};
        try std.testing.expectEqual(.deliver, ime.filterKey(down, vk_a, a_down));
        try std.testing.expectEqual(.deliver, ime.filterKey(up, vk_a, a_up));
    }

    // The IME claims the press; its release comes with the real virtual
    // key and is withheld once. Alt held makes them WM_SYS* messages.
    for ([_][2]win32.UINT{
        .{ win32.WM_KEYDOWN, win32.WM_KEYUP },
        .{ win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP },
    }) |pair| {
        var ime: Ime = .{};
        try std.testing.expectEqual(.withhold, ime.filterKey(pair[0], win32.VK_PROCESSKEY, a_down));
        try std.testing.expectEqual(.deliver, ime.filterKey(pair[1], vk_a, ext_up));
        try std.testing.expectEqual(.withhold, ime.filterKey(pair[1], vk_a, a_up));
        try std.testing.expectEqual(.deliver, ime.filterKey(pair[1], vk_a, a_up));
    }

    // The release comes as VK_PROCESSKEY too: the slot stays set until
    // the key's next press, which reaches the core with its release.
    {
        var ime: Ime = .{};
        try std.testing.expectEqual(.withhold, ime.filterKey(down, win32.VK_PROCESSKEY, a_down));
        try std.testing.expectEqual(.withhold, ime.filterKey(up, win32.VK_PROCESSKEY, a_up));
        try std.testing.expectEqual(.deliver_withheld, ime.filterKey(down, vk_a, a_down));
        try std.testing.expectEqual(.deliver, ime.filterKey(up, vk_a, a_up));
    }
}

test "win32: key messages under a prompt never reach the core" {
    // A prompt disables its owner, but its message loop still dispatches
    // key messages another program posts or sends to the window. They are
    // dropped there, so the core surface is left uninitialized: the test
    // crashes if a handler calls into it. A message-only window stands in
    // for the surface's.
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
    app.ticking = false;
    app.prompt_depth = 1;

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var surface: Surface = undefined;
    };
    const surface = &s.surface;
    surface.app = &app;
    surface.hwnd = hwnd;
    surface.core_state = .live;
    surface.ime = .{};

    // Scan code 0x1E (A): a press, a repeat and a release.
    const vk_a: win32.WPARAM = 0x41;
    const a_down: win32.LPARAM = 0x001E_0001;
    const a_repeat: win32.LPARAM = 0x401E_0001;
    const a_up: win32.LPARAM = @bitCast(@as(usize, 0xC01E_0001));
    const slot = Surface.Ime.scanSlot(a_down);

    // A repeat's press may have reached the core before the prompt, so its
    // release must not be withheld.
    try std.testing.expectEqual(0, surface.handleMessage(hwnd, win32.WM_KEYDOWN, vk_a, a_repeat));
    try std.testing.expect(!surface.ime.swallow_up.isSet(slot));

    try std.testing.expectEqual(0, surface.handleMessage(hwnd, win32.WM_KEYDOWN, vk_a, a_down));
    try std.testing.expectEqual(0, surface.handleMessage(hwnd, win32.WM_CHAR, 'a', a_down));
    try std.testing.expect(surface.ime.swallow_up.isSet(slot));

    // Once the prompt is gone the release of the dropped press is
    // withheld too, so the core never sees a release without its press.
    app.prompt_depth = 0;
    _ = surface.handleMessage(hwnd, win32.WM_KEYUP, vk_a, a_up);
    try std.testing.expect(!surface.ime.swallow_up.isSet(slot));
}

test "win32: ime completes Korean on focus loss and cancels the rest" {
    const Ime = Surface.Ime;
    // Any Korean sublanguage, or none.
    try std.testing.expectEqual(win32.CPS_COMPLETE, Ime.focusLossAction(0x0412));
    try std.testing.expectEqual(win32.CPS_COMPLETE, Ime.focusLossAction(0x0812));
    try std.testing.expectEqual(win32.CPS_COMPLETE, Ime.focusLossAction(0x0012));
    // Japanese, Chinese, English, no layout.
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0411));
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0804));
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0409));
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0));
    // The primary language is 10 bits: 0x212 (custom range) is not Korean.
    try std.testing.expectEqual(win32.CPS_CANCEL, Ime.focusLossAction(0x0212));
}

test "win32: losing focus mid-drag wakes the app loop" {
    // WM_KILLFOCUS is sent, so GetMessageW in `App.run` does not return
    // for it; the release owed for a held button (syncDeferredMouse) is
    // only sent once something is posted. A message-only window stands in
    // for both the app's and the surface's: the handler only needs a
    // queue to post to and a window that does not hold the capture, as
    // after the system has already taken it away.
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

    // Only what the focus handler reads, with no core surface. Static
    // because the struct embeds a whole CoreSurface.
    const s = struct {
        var surface: Surface = undefined;
    };
    const surface = &s.surface;
    surface.app = &app;
    surface.hwnd = hwnd;
    surface.core_state = .none;
    surface.ime = .{};
    surface.preedit = .none;

    const Case = struct { held: Surface.Mouse.Button.Set, want: bool };
    const cases = [_]Case{
        .{ .held = .initOne(.left), .want = true },
        // Nothing is owed, so nothing needs the loop.
        .{ .held = .empty, .want = false },
    };
    for (cases) |c| {
        surface.focused = true;
        surface.mouse = .init();
        surface.mouse.held = c.held;
        _ = surface.handleMessage(hwnd, win32.WM_KILLFOCUS, 0, 0);

        var msg: win32.MSG = undefined;
        const woken = win32.PeekMessageW(
            &msg,
            hwnd,
            WM_GHOSTTY_WAKEUP,
            WM_GHOSTTY_WAKEUP,
            win32.PM_REMOVE,
        ).toBool();
        try std.testing.expectEqual(c.want, woken);
    }
}

test "win32: a teardown dispatched inside another waits for it" {
    // A teardown pumps messages while it waits for its surface's threads
    // (App.waitForThread), so another window's WM_GHOSTTY_DESTROY can be
    // dispatched inside it. That one is deferred while the first is still
    // on the stack, and runs at once otherwise. Two message-only windows
    // stand in for the frame and the terminal's window: with no core
    // surface, a teardown that runs only destroys the frame, which would
    // take a real terminal's window with it.
    var app: App = undefined;
    app.terminating = false;
    app.ticking = false;
    app.prompt_depth = 0;
    // A teardown that runs posts the deferred ones again; there are none.
    app.surfaces = .empty;

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var surface: Surface = undefined;
        var window: Window = undefined;
        var tab: Window.Tab = .{};
        var tabs = [_]*Window.Tab{&tab};
    };
    const surface = &s.surface;
    surface.app = &app;
    surface.window = &s.window;
    surface.core_state = .none;
    s.window.tabs = .fromOwnedSlice(&s.tabs);
    s.window.selected = 0;
    // The window's only terminal, so a teardown that runs takes the window.
    s.tab.tree = try .init(std.testing.allocator, surface);
    defer s.tab.tree.deinit();
    s.window.app = &app;
    app.windows = .empty;

    const messageWindow = struct {
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
                win32.HWND_MESSAGE,
                null,
                null,
                null,
            ) orelse error.TestUnexpectedResult;
        }
    }.create;

    for ([_]u32{ 1, 0 }) |depth| {
        const frame = try messageWindow();
        defer if (win32.IsWindow(frame).toBool()) {
            _ = win32.DestroyWindow(frame);
        };
        const pane = try messageWindow();
        defer _ = win32.DestroyWindow(pane);
        surface.hwnd = pane;
        s.window.hwnd = frame;
        surface.destroy_deferred = false;
        app.teardown_depth = depth;

        _ = surface.handleMessage(pane, WM_GHOSTTY_DESTROY, 0, 0);

        const deferred = depth > 0;
        try std.testing.expectEqual(deferred, surface.destroy_deferred);
        try std.testing.expectEqual(deferred, win32.IsWindow(frame).toBool());
    }
}

test "win32: a finished teardown posts the ones it deferred again" {
    // A teardown deferred because another one was running is posted again
    // as soon as that one is done (`destroyPosted`), not only when `run`
    // comes round, which inside another window's size/move loop is once the
    // user lets go. Message-only windows stand in for the surfaces': with no
    // core surface, a teardown that runs only destroys its window.
    const alloc = std.testing.allocator;
    var app: App = undefined;
    app.terminating = false;
    app.ticking = false;
    app.prompt_depth = 0;
    app.teardown_depth = 0;
    app.surfaces = .empty;
    defer app.surfaces.deinit(alloc);

    // Static because the struct embeds a whole CoreSurface. Each surface's
    // window is its own message-only window: a teardown destroys it.
    const s = struct {
        var done: Surface = undefined;
        var waiting: Surface = undefined;
        var windows: [2]Window = undefined;
    };
    const both = [_]*Surface{ &s.done, &s.waiting };
    for (both, &s.windows) |surface, *window| {
        surface.app = &app;
        surface.window = window;
        surface.core_state = .none;
        surface.closing = true;
        surface.hwnd = win32.CreateWindowExW(
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
        window.hwnd = surface.hwnd;
    }
    defer for (both) |surface| {
        if (win32.IsWindow(surface.hwnd).toBool()) _ = win32.DestroyWindow(surface.hwnd);
    };
    // Each the only terminal of its window, so a teardown that runs takes
    // the window.
    app.windows = .empty;
    for (&s.windows) |*window| window.app = &app;
    var tabs: [2]Window.Tab = .{ .{}, .{} };
    var tab_lists: [2][1]*Window.Tab = .{ .{&tabs[0]}, .{&tabs[1]} };
    for (&s.windows, &tab_lists) |*window, *list| {
        window.tabs = .fromOwnedSlice(list);
        window.selected = 0;
    }
    tabs[0].tree = try .init(alloc, &s.done);
    defer tabs[0].tree.deinit();
    tabs[1].tree = try .init(alloc, &s.waiting);
    defer tabs[1].tree.deinit();
    s.done.destroy_deferred = false;
    s.waiting.destroy_deferred = true;
    try app.surfaces.append(alloc, &s.waiting);

    _ = s.done.handleMessage(s.done.hwnd, WM_GHOSTTY_DESTROY, 0, 0);

    try std.testing.expect(!s.waiting.destroy_deferred);
    var msg: win32.MSG = undefined;
    try std.testing.expect(win32.PeekMessageW(
        &msg,
        s.waiting.hwnd,
        WM_GHOSTTY_DESTROY,
        WM_GHOSTTY_DESTROY,
        win32.PM_REMOVE,
    ).toBool());
}

test "win32: a new window inherits only an existing working directory" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(dir_path);
    try tmp_dir.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    const file_path = try std.fs.path.join(alloc, &.{ dir_path, "file" });
    defer alloc.free(file_path);
    const missing_path = try std.fs.path.join(alloc, &.{ dir_path, "missing" });
    defer alloc.free(missing_path);

    var config = try configpkg.Config.default(alloc);
    defer config.deinit();
    const configured = config.@"working-directory";

    // A file, a missing path, nothing, or a path that is not absolute:
    // the configured directory stays. A relative one would reach
    // openDirAbsolute's assert.
    for ([_][]const u8{ file_path, missing_path, "", "relative\\dir", "C:relative" }) |wd| {
        Surface.inheritWorkingDirectory(&config, wd);
        try testing.expectEqualDeep(configured, config.@"working-directory");
    }

    Surface.inheritWorkingDirectory(&config, dir_path);
    const got = config.@"working-directory" orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(dir_path, got.path);
}

test "win32: a closing surface leaves the core and its window requests" {
    // What detachCore does, the first step of every teardown. That stopCore
    // calls it is not covered here: stopCore needs a live core surface.
    // After it the core no longer routes to the surface, and a window it
    // asked for has no parent, so a surface created later at the same
    // address cannot pass for it.
    const CoreApp = @import("../../App.zig");
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    core_app.alloc = alloc;
    core_app.surfaces = .empty;
    defer core_app.surfaces.deinit(alloc);

    var app: App = undefined;
    try @import("App.zig").testApp(&app, &core_app);
    defer @import("App.zig").testCleanup(&app);

    // Static because the struct embeds a whole CoreSurface.
    const s = struct {
        var closing: Surface = undefined;
        var other: Surface = undefined;
    };
    s.closing.app = &app;
    s.other.app = &app;
    // Two, so that the core does not start the quit timer.
    try core_app.surfaces.appendSlice(alloc, &.{ &s.closing, &s.other });
    core_app.focused_surface = &s.closing.core_surface;
    try app.requests.appendSlice(alloc, &.{
        .{ .window = &s.closing.core_surface },
        .{ .window = &s.other.core_surface },
        .{ .window = null },
        .{ .split = .{ .parent = &s.closing.core_surface, .direction = .right } },
    });

    s.closing.detachCore();

    try std.testing.expectEqualSlices(*Surface, &.{&s.other}, core_app.surfaces.items);
    try std.testing.expect(core_app.focused_surface == null);
    // The window it asked for has no parent, and its split is dropped.
    const want = [_]App.Request{
        .{ .window = null },
        .{ .window = &s.other.core_surface },
        .{ .window = null },
        .dropped,
    };
    try std.testing.expectEqual(want.len, app.requests.items.len);
    for (want, app.requests.items) |w, got| {
        try std.testing.expect(std.meta.eql(w, got));
    }
}
