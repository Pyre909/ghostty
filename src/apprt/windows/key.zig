const std = @import("std");

const input = @import("../../input.zig");

const win32 = @import("win32.zig");

/// The modifier state for the key message being handled.
///
/// GetKeyState, not GetAsyncKeyState: it reports the state as of the message
/// being processed, which is what a queued keystroke must be judged by. The
/// high bit is "down", the low bit is the toggle state for the lock keys.
pub fn currentMods() input.Mods {
    const down = struct {
        fn f(vk: c_int) bool {
            return win32.GetKeyState(vk) < 0;
        }
    }.f;
    const toggled = struct {
        fn f(vk: c_int) bool {
            return win32.GetKeyState(vk) & 1 != 0;
        }
    }.f;

    const lshift = down(win32.VK_LSHIFT);
    const rshift = down(win32.VK_RSHIFT);
    const lctrl = down(win32.VK_LCONTROL);
    const rctrl = down(win32.VK_RCONTROL);
    const lalt = down(win32.VK_LMENU);
    const ralt = down(win32.VK_RMENU);
    const lwin = down(win32.VK_LWIN);
    const rwin = down(win32.VK_RWIN);

    // `sides` only means something for a modifier that is down
    // (`input.Mods.sides`). With both keys of a pair down, left is
    // reported.
    return .{
        .shift = lshift or rshift,
        .ctrl = lctrl or rctrl,
        .alt = lalt or ralt,
        .super = lwin or rwin,
        .caps_lock = toggled(win32.VK_CAPITAL),
        .num_lock = toggled(win32.VK_NUMLOCK),
        .sides = .{
            .shift = if (rshift and !lshift) .right else .left,
            .ctrl = if (rctrl and !lctrl) .right else .left,
            .alt = if (ralt and !lalt) .right else .left,
            .super = if (rwin and !lwin) .right else .left,
        },
    };
}

/// True for the Left Ctrl message Windows synthesizes in front of AltGr.
///
/// On layouts with AltGr, pressing (or releasing) it sends a Left Ctrl
/// down (up) immediately followed by the Right Alt down (up), both stamped
/// with the same message time. Reported as-is, the core would see a real
/// Left Ctrl press and release, which the kitty keyboard protocol's
/// report-all-keys mode forwards to the application. The test is GLFW's
/// (win32_window.c, WM_KEYDOWN handling): a non-extended VK_CONTROL whose
/// next key message is an extended VK_MENU with the same time. Only a peek,
/// so the Right Alt is still delivered normally.
///
/// Two details matter, both measured on Windows 11 with SendInput pairs
/// carrying explicit timestamps:
///
///   * The time is read before peeking. A PM_NOREMOVE peek sets
///     GetMessageTime to the peeked message's time, so reading it afterwards
///     compares that time with itself, and a real Left Ctrl release with a
///     Right Alt queued behind it was taken for AltGr in every trial.
///   * The peek is limited to the key messages. An unfiltered peek returns
///     posted messages before input, so a message posted in the meantime
///     (here, a WM_GHOSTTY_WAKEUP from the render or IO thread) hid the
///     Right Alt in every trial. PM_QS_INPUT is no substitute: it found no
///     input in half of the handler calls although the Right Alt was still
///     queued. Posted character messages are inside the range, but none can
///     be pending here: posted messages are retrieved before input, and
///     TranslateMessage posts nothing for Ctrl.
///
/// A PM_NOREMOVE peek leaves GetKeyState unchanged, so the currentMods call
/// that follows still sees the state as of this message.
pub fn isAltGrFakeCtrl(wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    if (wparam != win32.VK_CONTROL) return false;
    const l: usize = @bitCast(lparam);
    // lParam bit 24: extended key, i.e. Right Ctrl, which is always real.
    if ((l >> 24) & 1 != 0) return false;

    // GetMessageTime is the time of the message being handled; MSG.time is
    // the same clock (a DWORD of the LONG value).
    const time: win32.DWORD = @bitCast(win32.GetMessageTime());

    var next: win32.MSG = undefined;
    if (!win32.PeekMessageW(
        &next,
        null,
        win32.WM_KEYFIRST,
        win32.WM_KEYLAST,
        win32.PM_NOREMOVE,
    ).toBool()) return false;
    return isAltGrRightAlt(&next, time);
}

/// Whether `next`, the key message queued behind a Left Ctrl message read
/// at `time`, is the Right Alt half of an AltGr press or release.
fn isAltGrRightAlt(next: *const win32.MSG, time: win32.DWORD) bool {
    switch (next.message) {
        win32.WM_KEYDOWN,
        win32.WM_SYSKEYDOWN,
        win32.WM_KEYUP,
        win32.WM_SYSKEYUP,
        => {},
        else => return false,
    }
    const nl: usize = @bitCast(next.lParam);
    return next.wParam == win32.VK_MENU and
        (nl >> 24) & 1 != 0 and
        next.time == time;
}

/// The core's action for a WM_(SYS)KEYDOWN or WM_(SYS)KEYUP.
pub fn keyAction(msg: win32.UINT, lparam: win32.LPARAM) input.Action {
    if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP) return .release;

    // lParam bit 30: the key was already down, i.e. autorepeat.
    const l: usize = @bitCast(lparam);
    return if ((l >> 30) & 1 != 0) .repeat else .press;
}

/// The key's scan code in the form of the Windows column of
/// src/input/keycodes.zig: the 8-bit code from lParam bits 16-23, with 0xE0
/// in the high byte when lParam bit 24 (extended key) is set. Keys injected
/// without a scan code (lParam 0, e.g. some SendInput callers) fall back to
/// the layout's mapping of the virtual key.
pub fn scanCode(vk: win32.UINT, lparam: win32.LPARAM) u32 {
    const sc = lparamScanCode(lparam) orelse
        win32.MapVirtualKeyW(vk, win32.MAPVK_VK_TO_VSC_EX);

    // Three keys arrive with a scan code that is not their own, and that
    // keycodes.zig does not list. The corrections are GLFW's
    // (win32_window.c, WM_KEYDOWN handling).
    return switch (sc) {
        // Alt+PrintScreen reports SysRq.
        0x0054 => 0xE037,
        // Ctrl+Pause reports Break.
        0xE046 => 0x0045,
        // CJK IMEs set the extended bit on Right Shift.
        0xE036 => 0x0036,
        else => sc,
    };
}

/// The scan code `lparam` carries, as `scanCode` describes, or null if it
/// carries none.
fn lparamScanCode(lparam: win32.LPARAM) ?u32 {
    const l: usize = @bitCast(lparam);
    var sc: u32 = @intCast((l >> 16) & 0xFF);
    if (sc == 0) return null;
    if ((l >> 24) & 1 != 0) sc |= 0xE000;
    return sc;
}

/// The physical key for a `scanCode` result.
pub fn keyFromScan(scan: u32) input.Key {
    for (input.keycodes.entries) |entry| {
        if (entry.native == scan) return entry.key;
    }
    return .unidentified;
}

/// The keypad key for `key`, the `keyFromScan` result of a message for
/// virtual key `vk`.
///
/// The keypad's digit and decimal keys keep their scan codes whatever the
/// NumLock state, so `keyFromScan` reports them as digits. With NumLock
/// off, or with Shift held while it is on, Windows sends the navigation
/// virtual key (VK_END, VK_UP, VK_CLEAR and so on) in place of VK_NUMPAD0
/// to VK_NUMPAD9 or VK_DECIMAL. The core then expects the navigation key,
/// which the encoder sends as a cursor or editing key (`pcStyleFunctionKey`
/// in input/key_encode.zig), as GTK reports it from KP_End and the other
/// keypad keysyms.
pub fn numpadKey(key: input.Key, vk: win32.UINT) input.Key {
    if (vk >= win32.VK_NUMPAD0 and vk <= win32.VK_NUMPAD9) return key;
    if (vk == win32.VK_DECIMAL) return key;
    return switch (key) {
        .numpad_0 => .numpad_insert,
        .numpad_1 => .numpad_end,
        .numpad_2 => .numpad_down,
        .numpad_3 => .numpad_page_down,
        .numpad_4 => .numpad_left,
        .numpad_5 => .numpad_begin,
        .numpad_6 => .numpad_right,
        .numpad_7 => .numpad_home,
        .numpad_8 => .numpad_up,
        .numpad_9 => .numpad_page_up,
        .numpad_decimal => .numpad_delete,
        else => key,
    };
}

/// Whether a key message of virtual key `vk` is Alt+Space, which opens the
/// window menu if no binding claims it. Presses and repeats only: a release
/// follows what happened to its press, through `swallow_up`, so that the
/// core never sees a release without the press or a press without the
/// release.
pub fn isWindowMenuKey(action: input.Action, vk: win32.UINT, mods: input.Mods) bool {
    if (vk != win32.VK_SPACE) return false;
    return switch (action) {
        .press, .repeat => mods.binding().equal(.{ .alt = true }),
        .release => false,
    };
}

/// Whether a key-down of virtual key `vk` is a digit of Alt+numpad entry:
/// with Alt held alone, the keypad's digit keys type a decimal character
/// code, and TranslateMessage posts the character as WM_CHAR when Alt is
/// released. The digits produce no character of their own.
///
/// A repeat follows its press rather than the modifiers, so that the core
/// sees every key it is told about from press to release: it is a digit of
/// the entry when the press was withheld (`withheld`, from `swallow_up`),
/// even if Alt has since been released, and it is not when the press
/// reached the core before Alt went down.
///
/// Only VK_NUMPAD0 to VK_NUMPAD9 match, so NumLock must be on. With NumLock
/// off the same keys arrive as VK_INSERT, VK_END and the other navigation
/// keys (`numpadKey`), which stay Alt-modified navigation keys for the core.
/// AltGr is Ctrl+Alt and does not start an entry.
pub fn isAltNumpad(
    action: input.Action,
    vk: win32.UINT,
    mods: input.Mods,
    withheld: bool,
) bool {
    if (vk < win32.VK_NUMPAD0 or vk > win32.VK_NUMPAD9) return false;
    return switch (action) {
        .press => mods.binding().equal(.{ .alt = true }),
        .repeat => withheld,
        .release => false,
    };
}

/// The character the key produces with no modifiers in the current layout,
/// or 0. Used by the encoder for Ctrl/Alt sequences and by bindings.
pub fn unshiftedCodepoint(vk: win32.UINT, scan: u32) u21 {
    return layoutCodepoint(vk, scan, &std.mem.zeroes([256]win32.BYTE));
}

/// The character the key produces in the current layout with `state`
/// (GetKeyboardState) but Shift released, or 0. Unlike unshiftedCodepoint,
/// Caps Lock and AltGr stay applied, so keyMods can tell what Shift itself
/// changed.
pub fn shiftlessCodepoint(vk: win32.UINT, scan: u32, state: *const [256]win32.BYTE) u21 {
    var shiftless = state.*;
    for ([_]c_int{ win32.VK_SHIFT, win32.VK_LSHIFT, win32.VK_RSHIFT }) |shift| {
        shiftless[@intCast(shift)] = 0;
    }
    return layoutCodepoint(vk, scan, &shiftless);
}

/// The character the key produces with `state` in the current layout, or 0.
///
/// TOUNICODE_NO_STATE_CHANGE keeps this query from consuming a pending dead
/// key; on Windows before 10 1607, which ignores the flag, a dead key
/// followed by another key can lose its accent.
fn layoutCodepoint(vk: win32.UINT, scan: u32, state: *const [256]win32.BYTE) u21 {
    var buf: [4]win32.WCHAR = undefined;
    const n = win32.ToUnicodeEx(
        vk,
        // Only the low byte. ToUnicodeEx reads bit 15 of the scan code as
        // "key is up", and the 0xE0 extended prefix sets exactly that bit.
        scan & 0xFF,
        state,
        &buf,
        buf.len,
        win32.TOUNICODE_NO_STATE_CHANGE,
        win32.GetKeyboardLayout(0),
    );
    // Negative: a dead key, whose spacing form is in buf[0]. Zero: nothing.
    if (n == 0) return 0;
    const unit = buf[0];
    if (std.unicode.utf16IsHighSurrogate(unit) or std.unicode.utf16IsLowSurrogate(unit)) {
        return 0;
    }
    return unit;
}

/// The LANGID of this thread's input language, or 0.
pub fn inputLanguage() u16 {
    const hkl = win32.GetKeyboardLayout(0) orelse return 0;
    return @truncate(@intFromPtr(hkl));
}

test "win32: key messages decode lParam" {
    const testing = std.testing;
    const lp = struct {
        fn of(v: usize) win32.LPARAM {
            return @bitCast(v);
        }
    }.of;

    // Right Arrow is scan 0x4D with the extended bit (24); Numpad 6 is the
    // same scan without it.
    try testing.expectEqual(0xE04D, lparamScanCode(lp(0x014D_0001)).?);
    try testing.expectEqual(.arrow_right, keyFromScan(0xE04D));
    try testing.expectEqual(0x004D, lparamScanCode(lp(0x004D_0001)).?);
    try testing.expectEqual(.numpad_6, keyFromScan(0x004D));
    try testing.expectEqual(.control_right, keyFromScan(lparamScanCode(lp(0x011D_0001)).?));
    try testing.expectEqual(.control_left, keyFromScan(lparamScanCode(lp(0x001D_0001)).?));

    // No scan field, extended or not: the caller asks the layout instead.
    try testing.expectEqual(null, lparamScanCode(lp(0x0000_0001)));
    try testing.expectEqual(null, lparamScanCode(lp(0x0100_0001)));
    try testing.expectEqual(.unidentified, keyFromScan(0));

    // Scan codes that are not the key's own: Alt+PrintScreen (VK_SNAPSHOT)
    // reports SysRq 0x54, Ctrl+Pause (VK_CANCEL) an extended 0x46, and Right
    // Shift (VK_SHIFT) under a CJK IME an extended 0x36. Scroll Lock (0x46)
    // and Right Shift without the extended bit are unchanged.
    try testing.expectEqual(.print_screen, keyFromScan(scanCode(0x2C, lp(0x2054_0001))));
    try testing.expectEqual(.pause, keyFromScan(scanCode(0x03, lp(0x0146_0001))));
    try testing.expectEqual(.shift_right, keyFromScan(scanCode(0x10, lp(0x0136_0001))));
    try testing.expectEqual(.scroll_lock, keyFromScan(scanCode(0x91, lp(0x0046_0001))));
    try testing.expectEqual(.shift_right, keyFromScan(scanCode(0x10, lp(0x0036_0001))));

    // Bit 30 is the previous key state, bit 31 the transition state, which
    // the message already says. Bit 29 is the Alt context of WM_SYS*.
    try testing.expectEqual(.press, keyAction(win32.WM_KEYDOWN, lp(0x001E_0001)));
    try testing.expectEqual(.repeat, keyAction(win32.WM_KEYDOWN, lp(0x401E_0001)));
    try testing.expectEqual(.press, keyAction(win32.WM_SYSKEYDOWN, lp(0x201E_0001)));
    try testing.expectEqual(.repeat, keyAction(win32.WM_SYSKEYDOWN, lp(0x601E_0001)));
    try testing.expectEqual(.release, keyAction(win32.WM_KEYUP, lp(0xC01E_0001)));
    try testing.expectEqual(.release, keyAction(win32.WM_SYSKEYUP, lp(0xE01E_0001)));
}

test "win32: keypad keys follow NumLock" {
    const testing = std.testing;
    const Case = struct { scan: u32, vk: win32.UINT, want: input.Key };
    const cases = [_]Case{
        // NumLock on: the digit's VK.
        .{ .scan = 0x0048, .vk = 0x68, .want = .numpad_8 }, // VK_NUMPAD8
        .{ .scan = 0x0052, .vk = 0x60, .want = .numpad_0 }, // VK_NUMPAD0
        .{ .scan = 0x0053, .vk = 0x6E, .want = .numpad_decimal }, // VK_DECIMAL

        // NumLock off, or Shift with it on: the navigation VK, same scan.
        .{ .scan = 0x0048, .vk = 0x26, .want = .numpad_up }, // VK_UP
        .{ .scan = 0x004F, .vk = 0x23, .want = .numpad_end }, // VK_END
        .{ .scan = 0x004C, .vk = 0x0C, .want = .numpad_begin }, // VK_CLEAR
        .{ .scan = 0x0052, .vk = 0x2D, .want = .numpad_insert }, // VK_INSERT
        .{ .scan = 0x0053, .vk = 0x2E, .want = .numpad_delete }, // VK_DELETE

        // The dedicated arrow and the keypad's other keys stay as they are.
        .{ .scan = 0xE048, .vk = 0x26, .want = .arrow_up }, // VK_UP
        .{ .scan = 0x004E, .vk = 0x6B, .want = .numpad_add }, // VK_ADD
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, numpadKey(keyFromScan(c.scan), c.vk));
    }
}

test "win32: Alt+Space is the window menu on press and repeat" {
    const testing = std.testing;
    const alt: input.Mods = .{ .alt = true };
    const space: win32.UINT = 0x20; // VK_SPACE

    // Either Alt, alone, presses or repeats.
    try testing.expect(isWindowMenuKey(.press, space, alt));
    try testing.expect(isWindowMenuKey(.repeat, space, alt));
    try testing.expect(isWindowMenuKey(.press, space, .{ .alt = true, .sides = .{ .alt = .right } }));
    try testing.expect(isWindowMenuKey(.press, space, .{ .alt = true, .caps_lock = true }));

    // The release follows its press through `swallow_up` instead, so a
    // bound press's release reaches the core.
    try testing.expect(!isWindowMenuKey(.release, space, alt));

    // Not Alt alone (AltGr's Ctrl+Alt among them), or not Space.
    try testing.expect(!isWindowMenuKey(.press, space, .{}));
    try testing.expect(!isWindowMenuKey(.press, space, .{ .alt = true, .ctrl = true }));
    try testing.expect(!isWindowMenuKey(.press, space, .{ .alt = true, .shift = true }));
    try testing.expect(!isWindowMenuKey(.press, 0x0D, alt)); // VK_RETURN
}

test "win32: Alt+numpad digits are text entry" {
    const testing = std.testing;
    const alt: input.Mods = .{ .alt = true };
    const Case = struct {
        action: input.Action = .press,
        vk: win32.UINT,
        mods: input.Mods = alt,
        withheld: bool = false,
        want: bool,
    };
    const cases = [_]Case{
        // The digits with NumLock on, from either Alt.
        .{ .vk = 0x60, .want = true }, // VK_NUMPAD0
        .{ .vk = 0x69, .want = true }, // VK_NUMPAD9
        .{ .vk = 0x60, .mods = .{ .alt = true, .num_lock = true }, .want = true },
        .{ .vk = 0x60, .mods = .{ .alt = true, .sides = .{ .alt = .right } }, .want = true },

        // A repeat follows its press: withheld while the press was, even
        // after Alt is released, and passed on when the press reached the
        // core before Alt went down.
        .{ .vk = 0x61, .action = .repeat, .withheld = true, .want = true },
        .{ .vk = 0x61, .action = .repeat, .mods = .{}, .withheld = true, .want = true },
        .{ .vk = 0x61, .action = .repeat, .want = false },

        // Not an entry: the release, no Alt, AltGr, Alt with another
        // modifier, the keypad with NumLock off, the keypad's other keys,
        // and the main keyboard's digits.
        .{ .vk = 0x60, .action = .release, .withheld = true, .want = false },
        .{ .vk = 0x60, .mods = .{}, .want = false },
        .{ .vk = 0x60, .mods = .{ .alt = true, .ctrl = true }, .want = false },
        .{ .vk = 0x60, .mods = .{ .alt = true, .super = true }, .want = false },
        .{ .vk = 0x2D, .want = false }, // VK_INSERT
        .{ .vk = 0x23, .want = false }, // VK_END
        .{ .vk = 0x6E, .want = false }, // VK_DECIMAL
        .{ .vk = 0x6B, .want = false }, // VK_ADD
        .{ .vk = 0x30, .want = false }, // 0 on the main keyboard
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, isAltNumpad(c.action, c.vk, c.mods, c.withheld));
    }
}

test "win32: Shift is judged with Caps Lock still applied" {
    // The expected characters are the US layout's.
    if (inputLanguage() != 0x0409) return error.SkipZigTest;

    const vk_a = 'A';
    const scan_a = 0x1E;
    var state = std.mem.zeroes([256]win32.BYTE);
    state[@intCast(win32.VK_CAPITAL)] = 0x01;
    state[@intCast(win32.VK_SHIFT)] = 0x80;
    state[@intCast(win32.VK_LSHIFT)] = 0x80;

    // Caps Lock+Shift+A types "a", the same as A with no modifiers, so only
    // the state without Shift shows that Shift changed it.
    try std.testing.expectEqual('a', layoutCodepoint(vk_a, scan_a, &state));
    try std.testing.expectEqual('a', unshiftedCodepoint(vk_a, scan_a));
    try std.testing.expectEqual('A', shiftlessCodepoint(vk_a, scan_a, &state));

    // Without Caps Lock, Shift is all that changed it.
    state[@intCast(win32.VK_CAPITAL)] = 0;
    try std.testing.expectEqual('A', layoutCodepoint(vk_a, scan_a, &state));
    try std.testing.expectEqual('a', shiftlessCodepoint(vk_a, scan_a, &state));
}

test "win32: AltGr is a Left Ctrl followed by an extended Right Alt" {
    const time: win32.DWORD = 1000;
    var next: win32.MSG = std.mem.zeroes(win32.MSG);
    next.message = win32.WM_KEYDOWN;
    next.wParam = win32.VK_MENU;
    next.lParam = @bitCast(@as(usize, 0x0138_0001));
    next.time = time;
    try std.testing.expect(isAltGrRightAlt(&next, time));

    // The release half, and the WM_SYS* forms, pair the same way.
    for ([_]win32.UINT{ win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP }) |m| {
        var n = next;
        n.message = m;
        try std.testing.expect(isAltGrRightAlt(&n, time));
    }

    // A Right Alt pressed later is a separate key: the Ctrl is real.
    var later = next;
    later.time = time + 1;
    try std.testing.expect(!isAltGrRightAlt(&later, time));

    // Left Alt (not extended) and other keys never pair.
    var left_alt = next;
    left_alt.lParam = @bitCast(@as(usize, 0x0038_0001));
    try std.testing.expect(!isAltGrRightAlt(&left_alt, time));
    var other = next;
    other.wParam = 'A';
    try std.testing.expect(!isAltGrRightAlt(&other, time));

    // Character messages share the peeked range but are not key messages.
    var char = next;
    char.message = win32.WM_CHAR;
    try std.testing.expect(!isAltGrRightAlt(&char, time));
}
