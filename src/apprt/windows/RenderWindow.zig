//! The window a terminal's renderer presents to: a child of the
//! terminal's own window, filling its client area, and the only one it
//! has. The terminal's window keeps everything else, its focus, IME,
//! drops, touch and the pointer: this one answers WM_NCHITTEST with
//! HTTRANSPARENT, so Windows gives the pointer and clicks over it to the
//! terminal under it, being of the same thread (as the overlays do,
//! Overlays.zig), and nothing ever focuses it.
//!
//! It is apart from the terminal's window so that it can be replaced.
//! A window that has presented through an HWND swap chain keeps that
//! chain's last frame, opaque, under any composition chain made on it
//! later (measured on Windows 11: a clear frame showed the old one, and
//! hiding, cloaking, resizing, repainting or presenting black first did
//! not help), while a window new to it blends as it should. So a
//! terminal whose window turns transparent gets a new one of these
//! (`Window.setTransparent`), and the renderer hands the old one back
//! once it presents to the new one (`Surface.renderLeft`).

const std = @import("std");

const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Transparency = @import("Transparency.zig");

const L = win32.L;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyRenderClass";

pub fn registerClass(hinstance: win32.HINSTANCE) bool {
    const class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        // The terminal's window sets the cursor: the pointer is its.
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(class_name),
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&class) != 0) return true;
    log.err("failed to register the render window class err={}", .{win32.GetLastError()});
    return false;
}

pub fn unregisterClass(hinstance: win32.HINSTANCE) void {
    _ = win32.UnregisterClassW(L(class_name), hinstance);
}

/// A shown render window filling `surface`'s client area; null, logged,
/// if it cannot be made.
pub fn create(surface: *Surface) ?win32.HWND {
    var rect: win32.RECT = undefined;
    if (!win32.GetClientRect(surface.hwnd, &rect).toBool()) rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const hwnd = win32.CreateWindowExW(
        0,
        L(class_name),
        null,
        win32.WS_CHILD | win32.WS_VISIBLE | win32.WS_CLIPSIBLINGS,
        0,
        0,
        rect.right,
        rect.bottom,
        surface.hwnd,
        null,
        surface.app.hinstance,
        // No pointer of its own: one could outlive the terminal it named
        // (`terminalOf`).
        null,
    ) orelse {
        log.err("CreateWindowExW failed for a render window err={}", .{win32.GetLastError()});
        return null;
    };
    // Over the one it replaces (`Window.setTransparent`) until that goes.
    _ = win32.SetWindowPos(hwnd, win32.HWND_TOP, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    return hwnd;
}

/// Size `hwnd` to fill a client area of `width` by `height`, before the
/// renderer is told of the size: its swap chain is sized by this window.
pub fn place(hwnd: win32.HWND, width: i32, height: i32) void {
    _ = win32.SetWindowPos(hwnd, null, 0, 0, width, height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOMOVE);
}

/// The terminal `hwnd` presents for, from its parent's GWLP_USERDATA,
/// which `App.surfaceDestroyed` zeroes before the Surface is freed: null
/// from then on. A render window, the current one or one the renderer
/// left (`Surface.renderLeft`), is always a child of its terminal's
/// window and never moved, but can outlive the Surface when a frame
/// cannot be destroyed (`App.destroyWindows`), so it keeps no pointer.
fn terminalOf(hwnd: win32.HWND) ?*Surface {
    const parent = win32.GetAncestor(hwnd, win32.GA_PARENT) orelse return null;
    const v = win32.GetWindowLongPtrW(parent, win32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_NCHITTEST => return win32.HTTRANSPARENT,
        // The swap chain draws all of it.
        win32.WM_ERASEBKGND => return 1,
        // As the terminal's own paint (`Surface.paint`): black under the
        // chain in a transparent frame, which then blends with the
        // desktop, and validated either way, or Windows would post
        // WM_PAINT again at once, forever.
        win32.WM_PAINT => {
            const transparent = if (terminalOf(hwnd)) |s| s.window.transparent else false;
            if (transparent) Transparency.paintTerminal(hwnd) else _ = win32.ValidateRect(hwnd, null);
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
