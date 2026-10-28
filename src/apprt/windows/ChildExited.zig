//! A terminal's child-exited banner, as GTK shows one across the bottom
//! of its surface once its command has exited (an Adw.Banner in
//! src/apprt/gtk/ui/1.3/surface-child-exited.blp, titled by
//! src/apprt/gtk/class/surface_child_exited.zig): "Command Succeeded" for
//! an exit code of 0, "Command Failed" for any other, over libadwaita's
//! success or error colour at half strength (`.child-exited` in
//! src/apprt/gtk/css/style.css), here mixed half and half with the search
//! bar's background, with a "Close" button at its right that closes the
//! terminal.
//!
//! The core performs `show_child_exited` once, from its mailbox in the
//! app's tick (`CoreSurface.childExited`), and true stands in for its own
//! text: after an abnormal exit (a code other than 0 within
//! `abnormal-command-exit-runtime`) it no longer prints the command, its
//! runtime and its code, and after any other it no longer prints "Process
//! exited. Press any key to close the terminal." and then closes the
//! terminal unless `wait-after-command` keeps it. A key the core encodes
//! still closes it. False, when the window cannot be made, leaves the
//! core's text.
//!
//! It is one of the terminal's overlays (Overlays.zig), above the
//! read-only badge and under the link preview and the key-state indicator,
//! as GTK stacks them, and the only one that takes input, on its button
//! alone: its WM_NCHITTEST answers HTCLIENT there and HTTRANSPARENT
//! elsewhere, so that the pointer and clicks over the rest of it are the
//! terminal's under it, and it never activates its frame or takes the
//! focus (WM_MOUSEACTIVATE). The pointer over the button is the class's
//! arrow. A press and a release on the button close the terminal as its
//! own WM_CLOSE does (`Surface.requestClose`); the core does not ask once
//! the command has exited (`CoreSurface.needsConfirmQuit`), unless the
//! terminal is read-only, and then the prompt says so (`Surface.close`).
//! The button takes the search bar's hover colour under the pointer and
//! its border colour while pressed, as the search bar's buttons do. A
//! press off it lets go of a press whose release never came, and the
//! banner hidden lets go of the press and the pointer.
//!
//! The window is made when the core asks, inside its tick, as
//! `SearchBar.start` makes the search bar's inside the key callback: it is
//! not among what waits for the core's frame to return (`App.requests`:
//! "Creating a terminal there would register a surface with the core in
//! the middle of that frame", "laying terminals out sends them WM_SIZE,
//! which enters the core"). The button's handler runs from the banner's
//! own message, which a loop nested under a core frame can dispatch (a
//! prompt's), so it closes the terminal only where
//! "a message handler may tick the core or tear a surface down right now"
//! (`App.canReenterCore`), and records the close for `run` otherwise
//! (`App.Request.close_surface`), as the command palette runs its entries.

const std = @import("std");

const apprt = @import("../../apprt.zig");
const win32 = @import("win32.zig");
const Surface = @import("Surface.zig").Surface;
const Window = @import("Window.zig");
const Overlays = @import("Overlays.zig");
const SearchBar = @import("SearchBar.zig");
const overlay_keys = @import("overlay_keys.zig");

const RECT = win32.RECT;
const Size = Overlays.Size;
const log = std.log.scoped(.win32);

pub const class_name = "GhosttyChildExitedClass";

/// The button's label, GTK's.
pub const button_label = "Close";
const button_text: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral(button_label);

const succeeded_text: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Command Succeeded");
const failed_text: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Command Failed");

/// One line, `&` drawn as itself, cut with an ellipsis where it has no
/// room.
const title_format = win32.DT_SINGLELINE | win32.DT_NOPREFIX | win32.DT_END_ELLIPSIS;
const label_format = win32.DT_SINGLELINE | win32.DT_NOPREFIX;

/// A terminal's banner (`Overlays.child_exited`).
pub const Banner = struct {
    /// Its window, a child of the terminal's frame, made when the core
    /// asks; null until then, if it could not be made, and once it is
    /// destroyed (its WM_DESTROY).
    hwnd: ?win32.HWND = null,
    /// Its title (`title`) once the core has asked; null until then.
    text: ?[:0]const u16 = null,
    /// Whether the command failed, which colours it (`tint`).
    failed: bool = false,
    /// Whether the core has said the command exited (`show`), whether or
    /// not the banner could be made: a read-only terminal's close prompt
    /// then says it is read-only (`Surface.close`).
    exited: bool = false,
    /// The size of `text`, and of the button's label, in the overlays'
    /// font; measured again when the font changes.
    text_size: Size = .{ .width = 0, .height = 0 },
    label_size: Size = .{ .width = 0, .height = 0 },
    measured: bool = false,
    /// The pointer is over the button, and the button is held down, with
    /// the mouse captured, after a press on it.
    hover: bool = false,
    pressed: bool = false,
    /// A WM_MOUSELEAVE is asked for (TrackMouseEvent).
    tracking: bool = false,

    /// Nothing to free: its texts are constants.
    pub fn deinit(self: *Banner, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.text = null;
    }

    /// The button's label, measured with the title (`Overlays.placed`).
    pub fn measureMore(self: *Banner, hwnd: win32.HWND, font: ?win32.HGDIOBJ) void {
        self.label_size = Overlays.measure(hwnd, font, button_text);
    }

    /// Where the banner goes over a terminal `pane` big at `dpi`, in the
    /// terminal's client coordinates (`rectIn`), for `Overlays.place`.
    pub fn placeIn(self: *const Banner, dpi: u32, pane: Size) ?Overlays.Placed {
        const in = rectIn(.init(dpi), pane, self.text_size, self.label_size) orelse return null;
        return .{ .in = in, .redraw = false };
    }

    /// The banner, `client` big, drawn into `hdc` at `dpi` in `font`, by
    /// whether the title bar is `dark`: the tint, the title, and the
    /// button in the search bar's colours, its face the bar's hover colour
    /// while the pointer is over it and its border colour while it is
    /// pressed.
    pub fn draw(self: *const Banner, hdc: win32.HDC, client: RECT, dpi: u32, dark: bool, font: ?win32.HGDIOBJ) void {
        const colors = SearchBar.Colors.of(dark);
        SearchBar.fill(hdc, client, tint(self.failed, dark));
        const l = Layout.init(.init(dpi), client.right, client.bottom, self.text_size, self.label_size);
        if (self.text) |t| Overlays.drawText(hdc, font, t, l.title, colors.text, title_format);
        const line = @max(1, SearchBar.Metrics.scale(1, dpi));
        SearchBar.fill(hdc, l.button, colors.border);
        const face = if (self.pressed) colors.border else if (self.hover) colors.hover else colors.bar;
        SearchBar.fill(hdc, SearchBar.inset(l.button, line), face);
        Overlays.drawText(hdc, font, button_text, l.label, colors.text, label_format);
    }

    /// Whether `x`, `y`, in the banner `hwnd`'s client coordinates, is on
    /// its button, as it is laid out at its size and DPI now.
    fn onButton(self: *const Banner, surface: *Surface, hwnd: win32.HWND, x: i32, y: i32) bool {
        var client: RECT = undefined;
        if (!win32.GetClientRect(hwnd, &client).toBool()) return false;
        const m = Metrics.init(Window.dpiOf(surface.app, hwnd));
        return Layout.init(m, client.right, client.bottom, self.text_size, self.label_size).onButton(x, y);
    }

    fn setHover(self: *Banner, hwnd: win32.HWND, hover: bool) void {
        if (hover == self.hover) return;
        self.hover = hover;
        _ = win32.InvalidateRect(hwnd, null, .FALSE);
    }

    /// The button comes up, unseen if it was pressed, and the banner lets
    /// go of the capture it took for the press.
    fn release(self: *Banner, hwnd: win32.HWND) void {
        self.pressed = false;
        if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
    }

    /// The banner's window `hwnd` is being hidden (`Overlays.hideWindows`,
    /// `Overlays.place`): it shows again with its button neither lit nor
    /// pressed, and asks for the pointer's leave again.
    pub fn hidden(self: *Banner, hwnd: win32.HWND) void {
        self.hover = false;
        self.tracking = false;
        self.release(hwnd);
    }

    /// The banner's own messages, which `Overlays.wndProc` hands it first:
    /// the hit test, the activation, and the pointer and the left button
    /// over the button. Null for the others.
    pub fn handle(self: *Banner, surface: *Surface, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
        _ = wparam;
        switch (msg) {
            // The button takes the pointer; the rest of the banner gives it
            // to the terminal under it, which Windows sends it to instead,
            // being of the same thread.
            win32.WM_NCHITTEST => {
                var pt: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
                if (!win32.ScreenToClient(hwnd, &pt).toBool()) return win32.HTTRANSPARENT;
                return if (self.onButton(surface, hwnd, pt.x, pt.y)) win32.HTCLIENT else win32.HTTRANSPARENT;
            },

            // A click on the button neither activates the frame nor moves
            // the focus out of the terminal.
            win32.WM_MOUSEACTIVATE => return win32.MA_NOACTIVATE,

            win32.WM_MOUSEMOVE => {
                if (!self.tracking) {
                    var track: win32.TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                        .dwFlags = win32.TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    self.tracking = win32.TrackMouseEvent(&track).toBool();
                }
                self.setHover(hwnd, self.onButton(surface, hwnd, win32.xLparam(lparam), win32.yLparam(lparam)));
                return 0;
            },

            win32.WM_MOUSELEAVE => {
                self.tracking = false;
                self.setHover(hwnd, false);
                return 0;
            },

            // A press on the button closes the terminal when it comes up on
            // it, as a button does.
            win32.WM_LBUTTONDOWN => {
                if (!self.onButton(surface, hwnd, win32.xLparam(lparam), win32.yLparam(lparam))) {
                    // Only the capture brings a press off the button here.
                    // The press that took it never saw its release, as
                    // when it came outside a frame in the background,
                    // where the capture does not reach (SetCapture): it
                    // comes up now, so that a release on the button after
                    // this press closes nothing.
                    if (self.pressed) _ = win32.InvalidateRect(hwnd, null, .FALSE);
                    self.release(hwnd);
                    return 0;
                }
                // Captured first: SetCapture sends WM_CAPTURECHANGED to the
                // window that loses it, which cancels a press.
                if (win32.GetCapture() != hwnd) _ = win32.SetCapture(hwnd);
                self.pressed = true;
                _ = win32.InvalidateRect(hwnd, null, .FALSE);
                return 0;
            },

            win32.WM_LBUTTONUP => {
                const on = self.onButton(surface, hwnd, win32.xLparam(lparam), win32.yLparam(lparam));
                const pressed = self.pressed;
                self.release(hwnd);
                _ = win32.InvalidateRect(hwnd, null, .FALSE);
                if (on and pressed) close(surface);
                return 0;
            },

            // Another window took the capture: the button comes up unseen.
            win32.WM_CAPTURECHANGED => {
                if (self.pressed) {
                    self.pressed = false;
                    _ = win32.InvalidateRect(hwnd, null, .FALSE);
                }
                return 0;
            },

            else => return null,
        }
    }
};

/// `show_child_exited` on `surface`: its banner shows, titled by `info`'s
/// exit code, its window made first if it has none. False if the window
/// cannot be made: the core then shows its own text.
pub fn show(surface: *Surface, info: apprt.surface.Message.ChildExited) bool {
    const self = &surface.overlays.child_exited;
    self.exited = true;
    const hwnd = self.hwnd orelse blk: {
        const made = Overlays.make(surface, class_name) orelse {
            log.warn("cannot make a child-exited banner err={}", .{win32.GetLastError()});
            return false;
        };
        self.hwnd = made;
        break :blk made;
    };
    const text = title(info.exit_code);
    self.text = text;
    self.failed = failed(info.exit_code);
    self.measured = false;
    // Its name, for what reads windows' text, as screen readers do.
    _ = win32.SetWindowTextW(hwnd, text.ptr);
    _ = win32.InvalidateRect(hwnd, null, .FALSE);
    Overlays.place(surface);
    return true;
}

/// Whether a command that exited with `exit_code` failed, as GTK takes
/// it: any code but 0.
pub fn failed(exit_code: u32) bool {
    return exit_code != 0;
}

/// The banner's title for `exit_code`, GTK's.
pub fn title(exit_code: u32) [:0]const u16 {
    return if (failed(exit_code)) failed_text else succeeded_text;
}

/// The banner's background: libadwaita's success or error background
/// colour (`--success-bg-color`, `--error-bg-color`), for its light or
/// dark style as the title bar is `dark`, mixed half and half with the
/// search bar's, as GTK shows them at 50% over its surface.
pub fn tint(is_failed: bool, dark: bool) win32.COLORREF {
    const color: win32.COLORREF = if (is_failed)
        if (dark) win32.rgb(0xc0, 0x1c, 0x28) else win32.rgb(0xe0, 0x1b, 0x24)
    else if (dark) win32.rgb(0x26, 0xa2, 0x69) else win32.rgb(0x2e, 0xc2, 0x7e);
    return mix(color, SearchBar.Colors.of(dark).bar);
}

/// `a` and `b` half and half, each channel rounded up.
fn mix(a: win32.COLORREF, b: win32.COLORREF) win32.COLORREF {
    var out: win32.COLORREF = 0;
    for (0..3) |i| {
        const shift: u5 = @intCast(8 * i);
        const sum = ((a >> shift) & 0xff) + ((b >> shift) & 0xff) + 1;
        out |= (sum / 2) << shift;
    }
    return out;
}

/// The banner's sizes at a DPI, from their values at 96: as short as its
/// button and title allow, so that it hides as little of the terminal's
/// bottom as it can, being opaque where GTK's is see-through.
pub const Metrics = struct {
    /// Between the banner's edges and the button, and its least room
    /// above and below the title.
    pad: i32,
    /// The button's least height.
    button: i32,
    /// Between the button's label and its left and right edges.
    button_pad: i32,
    /// Between the title and the button.
    gap: i32,

    pub fn init(dpi: u32) Metrics {
        return .{
            .pad = SearchBar.Metrics.scale(2, dpi),
            .button = SearchBar.Metrics.scale(24, dpi),
            .button_pad = SearchBar.Metrics.scale(12, dpi),
            .gap = SearchBar.Metrics.scale(12, dpi),
        };
    }

    /// The button's height for a label `label` big.
    fn buttonHeight(self: Metrics, label: Size) i32 {
        return @max(self.button, @max(0, label.height) + self.pad);
    }

    /// The banner's height, for a title `text` and a label `label` big.
    pub fn height(self: Metrics, text: Size, label: Size) i32 {
        return @max(self.buttonHeight(label), @max(0, text.height)) + 2 * self.pad;
    }
};

/// Where a banner goes over a terminal `pane` big, with a title `text`
/// and a button's label `label` big, in the terminal's client
/// coordinates: across its bottom, as tall as its title or button with
/// the padding; null for a terminal too small to hold it.
pub fn rectIn(m: Metrics, pane: Size, text: Size, label: Size) ?RECT {
    const height = m.height(text, label);
    const button = @max(0, label.width) + 2 * m.button_pad;
    if (pane.width < button + 2 * m.pad or pane.height < height) return null;
    return .{ .left = 0, .top = pane.height - height, .right = pane.width, .bottom = pane.height };
}

/// What a banner `width` by `height` holds, in its own client
/// coordinates: the button at its right, `pad` in, centred down it, with
/// its label centred in it; the title centred across the banner as
/// Adw.Banner centres it, moved left to stay clear of the button, and cut
/// where it has no room.
pub const Layout = struct {
    title: RECT,
    button: RECT,
    label: RECT,

    pub fn init(m: Metrics, width: i32, height: i32, text: Size, label: Size) Layout {
        const button_w = @max(0, label.width) + 2 * m.button_pad;
        const button_h = m.buttonHeight(label);
        const button_top = @divTrunc(height - button_h, 2);
        const button: RECT = .{ .left = width - m.pad - button_w, .top = button_top, .right = width - m.pad, .bottom = button_top + button_h };
        const label_left = button.left + @divTrunc(button_w - label.width, 2);
        const label_top = button.top + @divTrunc(button_h - label.height, 2);

        const room = button.left - m.gap;
        const centred = @divTrunc(width - text.width, 2);
        const left = @max(m.pad, @min(centred, room - text.width));
        const text_top = @divTrunc(height - text.height, 2);
        return .{
            .title = .{ .left = left, .top = text_top, .right = @max(left, @min(left + text.width, room)), .bottom = text_top + text.height },
            .button = button,
            .label = .{ .left = label_left, .top = label_top, .right = label_left + label.width, .bottom = label_top + label.height },
        };
    }

    /// Whether `x`, `y` is on the button.
    pub fn onButton(self: Layout, x: i32, y: i32) bool {
        return x >= self.button.left and x < self.button.right and y >= self.button.top and y < self.button.bottom;
    }
};

/// The button clicked: `surface` closes as its own WM_CLOSE closes it
/// (`Surface.requestClose`), now if the core may be re-entered, else
/// recorded for `run` (`App.Request.close_surface`).
fn close(surface: *Surface) void {
    const app = surface.app;
    if (!app.canReenterCore()) {
        // Every surface a request names is live (`App.requests`).
        const core = overlay_keys.coreOf(surface) orelse return;
        app.requests.append(app.core_app.alloc, .{ .close_surface = core }) catch |err|
            return log.warn("cannot record a close from a child-exited banner err={}", .{err});
        app.wakeup();
        return;
    }
    surface.requestClose();
}

test "win32: the child-exited banner's title and colour follow the exit code, as GTK's" {
    const testing = std.testing;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Command Succeeded"), title(0));
    for ([_]u32{ 1, 3, 255, 0xC000_0005, std.math.maxInt(u32) }) |code| {
        try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Command Failed"), title(code));
        try testing.expect(failed(code));
    }
    try testing.expect(!failed(0));

    // libadwaita's success and error backgrounds, light #2ec27e and
    // #e01b24 over the light bar #f3f3f3, dark #26a269 and #c01c28 over the
    // dark bar #2b2b2b, half and half, rounded up.
    try testing.expectEqual(win32.rgb(145, 219, 185), tint(false, false));
    try testing.expectEqual(win32.rgb(234, 135, 140), tint(true, false));
    try testing.expectEqual(win32.rgb(41, 103, 74), tint(false, true));
    try testing.expectEqual(win32.rgb(118, 36, 42), tint(true, true));
}

test "win32: the child-exited banner lies across its terminal's bottom, its button at the right" {
    const testing = std.testing;
    const m = Metrics.init(96);
    try testing.expectEqual(2, m.pad);
    try testing.expectEqual(24, m.button);
    try testing.expectEqual(12, m.button_pad);
    try testing.expectEqual(12, m.gap);
    try testing.expectEqual(48, Metrics.init(192).button);

    const text: Size = .{ .width = 120, .height = 16 };
    const label: Size = .{ .width = 30, .height = 16 };
    // As tall as the button with the padding.
    try testing.expectEqual(28, m.height(text, label));
    try testing.expectEqual(RECT{ .left = 0, .top = 572, .right = 800, .bottom = 600 }, rectIn(m, .{ .width = 800, .height = 600 }, text, label).?);
    // A taller title: as tall as it.
    try testing.expectEqual(44, m.height(.{ .width = 120, .height = 40 }, label));
    // Room for the button alone; one pixel less, or too short: none.
    try testing.expect(rectIn(m, .{ .width = 58, .height = 600 }, text, label) != null);
    try testing.expect(rectIn(m, .{ .width = 57, .height = 600 }, text, label) == null);
    try testing.expect(rectIn(m, .{ .width = 800, .height = 27 }, text, label) == null);

    // The button 2 in from the right, centred down; its label centred in
    // it; the title centred across.
    const l = Layout.init(m, 800, 28, text, label);
    try testing.expectEqual(RECT{ .left = 744, .top = 2, .right = 798, .bottom = 26 }, l.button);
    try testing.expectEqual(RECT{ .left = 756, .top = 6, .right = 786, .bottom = 22 }, l.label);
    try testing.expectEqual(RECT{ .left = 340, .top = 6, .right = 460, .bottom = 22 }, l.title);
    try testing.expect(l.onButton(744, 2));
    try testing.expect(l.onButton(797, 25));
    try testing.expect(!l.onButton(743, 14));
    try testing.expect(!l.onButton(798, 14));
    try testing.expect(!l.onButton(760, 1));
    try testing.expect(!l.onButton(760, 26));

    // Narrow: the title moves left of the button, then is cut at it.
    const narrow = Layout.init(m, 250, 28, text, label);
    try testing.expectEqual(RECT{ .left = 62, .top = 6, .right = 182, .bottom = 22 }, narrow.title);
    const cut = Layout.init(m, 150, 28, text, label);
    try testing.expectEqual(RECT{ .left = 2, .top = 6, .right = 82, .bottom = 22 }, cut.title);
}
