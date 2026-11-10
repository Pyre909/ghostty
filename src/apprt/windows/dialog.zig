const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;

const log = std.log.scoped(.win32);

/// The button of a `confirm` prompt that Enter and Space press.
///
/// Prompts that grant access default to Cancel, as GTK's clipboard
/// confirmation dialog does (`default-response: "cancel"`): a program can
/// raise one at any moment, so a key the user was already typing must not
/// answer it. So does any confirmation opened while another prompt is
/// open (`confirm`), whatever it asks.
pub const ConfirmDefault = enum {
    ok,
    cancel,

    pub fn style(self: ConfirmDefault) win32.UINT {
        // MB_OKCANCEL places OK first and Cancel second.
        return switch (self) {
            .ok => win32.MB_DEFBUTTON1,
            .cancel => win32.MB_DEFBUTTON2,
        };
    }
};

/// A modal yes/no prompt, a message box. The Kitty clipboard prompt, which
/// shows what a program would read or write, is a dialog of its own
/// (`ClipboardDialog`), run as this one is.
pub fn confirm(
    app: *App,
    hwnd: ?win32.HWND,
    text: win32.LPCWSTR,
    default: ConfirmDefault,
) bool {
    // Inside another prompt, as a tick under the Save dialog asks one
    // (`App.beginUnframedPrompt`) for a program: a read-only terminal
    // whose command exits asks to close. The user is typing into the
    // dialog then, and this box can take the activation from it, so the
    // Enter meant for Save must not answer it OK.
    const pressed: ConfirmDefault = if (app.prompt_depth > 0) .cancel else default;
    return messageBox(app, hwnd, text, win32.MB_OKCANCEL | pressed.style()) == win32.IDOK;
}

/// The Retry/Cancel form of `confirm`: true for Retry, the default button.
pub fn retry(app: *App, hwnd: ?win32.HWND, text: win32.LPCWSTR) bool {
    return messageBox(app, hwnd, text, win32.MB_RETRYCANCEL) == win32.IDRETRY;
}

/// The OK-only form of `confirm`.
pub fn notice(app: *App, hwnd: ?win32.HWND, text: win32.LPCWSTR) void {
    _ = messageBox(app, hwnd, text, win32.MB_OK);
}

/// For tests: answers in place of MessageBoxW in `messageBox` and
/// `fatalNotice`, given its owner, its text and its buttons, as `Overlays.test_make` stands for
/// CreateWindowExW, so that a test sees what a prompt says and what each
/// answer does without a modal loop.
pub var test_message_box: if (builtin.is_test) ?*const fn (?win32.HWND, win32.LPCWSTR, win32.UINT) c_int else void =
    if (builtin.is_test) null else {};

/// For a test that reaches a prompt it set no answer for
/// (`test_message_box`): Cancel, and an error in the log, which fails the
/// test. The box itself would wait for ever for an answer, on a desktop
/// nobody sees, and hold up the whole run rather than fail one test.
fn unanswered() c_int {
    log.err("a test reached a prompt it has no answer for", .{});
    return win32.IDCANCEL;
}

/// The prompt behind `confirm`, `retry` and `notice`, with `buttons`.
///
/// MessageBoxW runs a nested message loop. `prompt_depth` tells every
/// handler dispatched inside it that a core frame is probably beneath: no
/// ticks and no surface teardown until it returns (`App.canReenterCore`).
/// Output from every surface pauses while a prompt is open, so the prompt
/// is modal to every window, not only to `hwnd` (`App.beginPrompt`).
///
/// Once the windows are going for good (`App.terminating`) it is answered
/// Cancel without a box: a tick in a teardown's wait can ask, as a
/// program's clipboard read does, and no WM_QUIT would end the box's loop,
/// as `run` has taken the quit's and the wait holds the session's end's
/// until it returns (`App.waitForThread`). The box would hold up the quit,
/// or the end inside WM_ENDSESSION, until someone answered it.
fn messageBox(app: *App, hwnd: ?win32.HWND, text: win32.LPCWSTR, buttons: win32.UINT) c_int {
    if (app.terminating) {
        log.warn("a prompt while the windows close is answered Cancel", .{});
        return win32.IDCANCEL;
    }
    const owner = app.promptOwner(hwnd);
    app.beginPrompt(owner);
    defer app.endPrompt();
    if (builtin.is_test) return if (test_message_box) |answer|
        answer(owner, text, buttons)
    else
        unanswered();
    return win32.MessageBoxW(owner, text, L("Ghostty"), buttons | win32.MB_ICONWARNING);
}

/// A failure that ends the process before any window exists. The
/// executable runs in the Windows subsystem, where stderr reaches nobody
/// when it was launched from Explorer or the Start menu, so the error is
/// shown in a message box as well. Nothing is beneath it yet, so the
/// nesting rules of `notice` do not apply.
pub fn fatalNotice(err: anyerror) void {
    const what: []const u8 = switch (err) {
        error.D3D11DeviceFailed => "Direct3D 11 feature level 11_0 is not available, not even through WARP",
        error.D3D11SwapChainFailed => "Direct3D 11 could not create a swap chain for the window",
        error.D3DCompilerMissing => "d3dcompiler_47.dll could not be loaded",
        else => @errorName(err),
    };
    var buf: [192]u8 = undefined;
    const text = std.mem.print(
        &buf,
        "Ghostty could not start: {s}.",
        .{what},
    ) catch "Ghostty could not start.";
    // On the stack, so that OutOfMemory can still be reported. `text` is
    // valid UTF-8 no longer than `buf`, so its UTF-16 fits and cannot fail.
    var wide: [buf.len + 1]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text) catch unreachable;
    wide[n] = 0;
    if (builtin.is_test) {
        _ = if (test_message_box) |answer| answer(null, wide[0..n :0], win32.MB_OK) else unanswered();
        return;
    }
    _ = win32.MessageBoxW(null, wide[0..n :0], L("Ghostty"), win32.MB_OK | win32.MB_ICONERROR);
}
