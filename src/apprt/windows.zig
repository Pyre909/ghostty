//! Application runtime for Windows, built directly on the Win32 API
//! (user32/gdi32), rendering with Direct3D 11.
//!
//! ## What this is
//!
//!   * `App` owns the process lifecycle: the Win32 message loop, a
//!     message-only window used as the wakeup and timer target, and the
//!     loaded configuration.
//!   * `Surface` owns an `HWND` and hosts a real, initialized `CoreSurface`:
//!     a terminal with its own renderer and IO threads.
//!
//! The renderer is `GenericRenderer(D3D11)` (src/renderer/D3D11.zig). It
//! takes only the `HWND`: it creates its device and swap chain in `init`,
//! on the main thread inside `CoreSurface.init`, and resizes and presents
//! the swap chain on the render thread. The main thread makes no graphics
//! calls once a surface exists: WM_PAINT only asks the core for a frame.
//!
//! ## Invariants this runtime depends on
//!
//!   * **No window is destroyed from inside a core frame.** The core calls
//!     `CoreSurface.close` from its own stack (`Surface.childExited`,
//!     `Surface.keyCallback`), and
//!     `CoreSurface.deinit` would free memory those frames still use. Every
//!     close therefore posts `WM_GHOSTTY_DESTROY` and the teardown runs later,
//!     from a message loop (`Surface.destroyPosted`).
//!   * **Teardowns do not nest.** A teardown pumps messages while it waits
//!     for its surface's threads (`App.waitForThread`); another one
//!     dispatched there waits until the first has finished
//!     (`App.teardown_depth`).
//!   * **`core_app.tick` never reenters itself**, and never runs while a
//!     modal confirmation prompt is up (`App.canReenterCore`). A prompt
//!     is therefore modal to every window, not only its own
//!     (`App.beginPrompt`).
//!
//! ## Windows
//!
//! A window holds tabs, each with its terminals in a split tree, and shows
//! one, laid out over its client area (`Window`, `Tab`).
//! `.move_tab_to_new_window` moves a tab whole into a new window: its
//! terminals keep their windows and cores and only change frames
//! (`Window.moveTabTo`). A tab dragged in the tab bar moves among the
//! others, and dropped outside its window moves to a new one placed
//! under the pointer (`TabBar.Drag`); a drop on another Ghostty window's
//! bar also makes a new window. An action that lays out terminals, moves the
//! focus to another window or tab, or frees core state, such as
//! `.new_split`, `.goto_tab`, `.toggle_fullscreen`,
//! `.move_tab_to_new_window` or a full `.reload_config`, is recorded and
//! carried out by `App.run` once the core frame that asked has returned,
//! and so is the frame change a new configuration's `window-decoration`
//! makes (`App.requests`, which `App.Request` lists); `.goto_split` moves
//! the focus once the core's key callback has returned
//! (`Tab.pending_focus`), or after such a request when it follows one,
//! and ends a zoom or moves it (`Window.focusFromGoto`).
//! The process quits when its last window closes, whatever
//! `quit-after-last-window-closed` says: with no window left there is
//! nothing to open another from (`App.setQuitTimer`).
//!
//! ## Search
//!
//! `.start_search` opens a terminal's search bar over its top-right
//! corner, as GTK's search overlay floats over its surface, and moves the
//! focus into its field once the core frame that asked has returned
//! (`App.search_focus`); `.end_search`, Escape in the field or its close
//! button hides it and gives the terminal the focus back. The bar is a
//! child window of the frame placed above the terminal, not of the
//! terminal, whose flip-model swap chain would hide it, so every layout
//! places it (`SearchBar.place`). Typing in the field searches the
//! terminal's scrollback through the core's `search:<text>` once the text
//! has settled, as GTK's search entry waits (`SearchBar.Debounce`); Enter,
//! Shift+Enter and the bar's buttons ask for the next and previous match,
//! and `.search_total` and `.search_selected` make its count. The core's
//! renderer draws the matches. In the field, its own keys come first; then
//! the terminal's bindings for the app, the window, its tabs and splits,
//! search, the command palette and the title prompts still act, and copy,
//! paste and select all act on the field (`overlay_keys`). Every other key
//! is the field's: nothing typed there reaches the terminal. Leader
//! sequences and key tables are not started from the field.
//!
//! ## Title prompts
//!
//! `.prompt_title` asks for a terminal's own title or its tab's in a
//! dialog over its window, as GTK's title dialog does (`TitleDialog`),
//! opened by `App.run` once the core frame that asked has returned. OK
//! sets the title, an empty one clears it, Cancel changes nothing. The
//! terminal's title from it is shown wherever its title shows, in place of
//! the program's, which OSC titles keep changing underneath
//! (`Surface.effectiveTitle`); the core's own title stays the program's.
//! The dialog is modeless, its keys handed to IsDialogMessageW by `run`,
//! so output and requests keep running in every window, and modal to its
//! window, whose frame it holds disabled; a frame is enabled only when
//! neither it nor a confirmation prompt holds it (`App.beginPrompt`).
//! `.prompt_title` for a window is not supported, as on macOS.
//!
//! ## What is still missing
//!
//! Not implemented: the tab overview, dragging a tab into another
//! window, dragging the dividers between splits, a context menu,
//! link previews and precision-touchpad scrolling. Without a menu, a
//! right click with the default `right-click-action` only selects the word
//! or link under the pointer.
//! `performAction` returns `false`, the contract's word for "unsupported",
//! for `.mouse_over_link` and every other action it does not
//! name; this runtime never claims an action it did not carry out.
//!
//! Links open through the shell's `open` verb (`App.openLink`); a text
//! file of a kind no program is registered for opens with the program for
//! text files, as macOS falls back to its default text editor. An OSC 8
//! target and a link found in the terminal's text are program output, so
//! only a well-formed http, https or mailto link is opened from one;
//! anything else is refused with a notice (`App.linkRefused`).
//!
//! An IME composition is drawn inline as the core's preedit. The IME's own
//! composition window is therefore turned off (WM_IME_SETCONTEXT), and
//! WM_IME_COMPOSITION is consumed: its result is read once and sent to the
//! core as a text-only key event, and DefWindowProcW never turns it into
//! WM_CHARs. The candidate window is placed at the cursor cell
//! (`Surface.imePlace`). See `Surface.Ime`.

const std = @import("std");

const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const CoreSurface = @import("../Surface.zig");

// The required comptime API for any apprt.
pub const App = @import("windows/App.zig").App;
pub const Surface = @import("windows/Surface.zig").Surface;
pub const resourcesDir = internal_os.resourcesDir;

comptime {
    // Zig only analyzes function bodies it reaches. A Windows exe reaches
    // the contract through CoreSurface, but only for the methods and action
    // keys the core actually calls in that configuration; these references
    // keep the whole contract type-checked (and every performAction key
    // instantiated) whenever this file is the selected runtime, so it cannot
    // rot silently against core changes.
    //
    // Guarded on this file being the selected runtime, not merely on the
    // target. src/apprt.zig imports it unconditionally on every platform,
    // and a Windows library build resolves it as soon as anything names
    // `apprt.windows`, while that build's surfaces are
    // `apprt.embedded.Surface`, which this contract does not describe.
    if (apprt.runtime == @This()) {
        _ = &App.performIpc;
        _ = &App.wakeup;
        _ = &App.startQuitTimer;

        _ = &Surface.core;
        _ = &Surface.rtApp;
        _ = &Surface.close;
        _ = &Surface.getContentScale;
        _ = &Surface.getSize;
        _ = &Surface.getCursorPos;
        _ = &Surface.getTitle;
        _ = &Surface.supportsClipboard;
        _ = &Surface.clipboardRequest;
        _ = &Surface.setClipboard;
        _ = &Surface.defaultTermioEnv;

        // Every button this runtime reports must index the core's
        // click_state (`CoreSurface.Mouse.click_state`, indexed in
        // `Surface.mouseButtonCallback`); input.MouseButton.eleven
        // does not, since the array has `max` (= 11) entries.
        const click_states = @typeInfo(
            @FieldType(@FieldType(CoreSurface, "mouse"), "click_state"),
        ).array.len;
        for (std.enums.values(Surface.Mouse.Button)) |b| {
            if (@backingInt(b.core()) >= click_states) {
                @compileError("mouse button " ++ @tagName(b) ++ " is outside the core's click_state");
            }
        }

        // performAction is comptime-dispatched per key, so each key is a
        // separate instantiation and a separate chance to be wrong.
        for (@typeInfo(apprt.Action.Key).@"enum".field_names) |name| {
            const key = @field(apprt.Action.Key, name);
            _ = &struct {
                fn thunk(
                    app: *App,
                    target: apprt.Target,
                    value: apprt.Action.Value(key),
                ) !bool {
                    return app.performAction(target, key, value);
                }
            }.thunk;
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("windows/App.zig");
    _ = @import("windows/SearchBar.zig");
    _ = @import("windows/Surface.zig");
    _ = @import("windows/Tab.zig");
    _ = @import("windows/TabBar.zig");
    _ = @import("windows/TitleDialog.zig");
    _ = @import("windows/Window.zig");
    _ = @import("windows/clipboard.zig");
    _ = @import("windows/desktop_notifications.zig");
    _ = @import("windows/dialog.zig");
    _ = @import("windows/key.zig");
    _ = @import("windows/overlay_keys.zig");
    _ = @import("windows/taskbar.zig");
    _ = @import("windows/toast.zig");
    _ = @import("windows/win32.zig");
}
