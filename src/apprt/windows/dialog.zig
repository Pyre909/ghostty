const std = @import("std");

const win32 = @import("win32.zig");
const L = win32.L;
const App = @import("App.zig").App;

/// The button of a `confirm` prompt that Enter and Space press.
///
/// Prompts that grant access default to Cancel, as GTK's clipboard
/// confirmation dialog does (`default-response: "cancel"`): a program can
/// raise one at any moment, so a key the user was already typing must not
/// answer it.
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

/// A modal yes/no prompt. This is the only confirmation UI this runtime has.
pub fn confirm(
    app: *App,
    hwnd: ?win32.HWND,
    text: win32.LPCWSTR,
    default: ConfirmDefault,
) bool {
    return messageBox(app, hwnd, text, win32.MB_OKCANCEL | default.style()) == win32.IDOK;
}

/// The Retry/Cancel form of `confirm`: true for Retry, the default button.
pub fn retry(app: *App, hwnd: ?win32.HWND, text: win32.LPCWSTR) bool {
    return messageBox(app, hwnd, text, win32.MB_RETRYCANCEL) == win32.IDRETRY;
}

/// The OK-only form of `confirm`.
pub fn notice(app: *App, hwnd: ?win32.HWND, text: win32.LPCWSTR) void {
    _ = messageBox(app, hwnd, text, win32.MB_OK);
}

/// The prompt behind `confirm`, `retry` and `notice`, with `buttons`.
///
/// MessageBoxW runs a nested message loop. `prompt_depth` tells every
/// handler dispatched inside it that a core frame is probably beneath: no
/// ticks and no surface teardown until it returns (`App.canReenterCore`).
/// Output from every surface pauses while a prompt is open, so the prompt
/// is modal to every window, not only to `hwnd` (`App.beginPrompt`).
fn messageBox(app: *App, hwnd: ?win32.HWND, text: win32.LPCWSTR, buttons: win32.UINT) c_int {
    const owner = app.promptOwner(hwnd);
    app.beginPrompt(owner);
    defer app.endPrompt();
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
    _ = win32.MessageBoxW(null, wide[0..n :0], L("Ghostty"), win32.MB_OK | win32.MB_ICONERROR);
}
