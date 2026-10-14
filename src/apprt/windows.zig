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
//!   * **`core_app.tick` never reenters itself**, and never runs while a
//!     modal confirmation prompt is up (`App.canReenterCore`).
//!
//! ## What is still missing
//!
//! Not implemented: more than one window (`.new_window`), a context menu,
//! link previews and precision-touchpad scrolling. Without a menu, a right
//! click with the default `right-click-action` only selects the word or
//! link under the pointer.
//! `performAction` returns `false`, the contract's word for "unsupported",
//! for `.new_window`, `.mouse_over_link` and every other action it does not
//! name; this runtime never claims an action it did not carry out.
//!
//! Links open through the shell (`ShellExecuteW`). An OSC 8 target and a
//! link found in the terminal's text are program output, so only a
//! well-formed http, https or mailto link is opened from one; anything else
//! is refused with a notice (`App.linkRefused`).
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
            if (@intFromEnum(b.core()) >= click_states) {
                @compileError("mouse button " ++ @tagName(b) ++ " is outside the core's click_state");
            }
        }

        // performAction is comptime-dispatched per key, so each of the 69
        // keys is a separate instantiation and a separate chance to be wrong.
        for (@typeInfo(apprt.Action.Key).@"enum".fields) |field| {
            const key = @field(apprt.Action.Key, field.name);
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
    _ = @import("windows/Surface.zig");
    _ = @import("windows/clipboard.zig");
    _ = @import("windows/dialog.zig");
    _ = @import("windows/key.zig");
    _ = @import("windows/win32.zig");
}
