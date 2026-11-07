//! The global keybinds (`global:` in `keybind`) as hotkeys of the whole
//! system: each is registered with RegisterHotKey on the app's
//! message-only window, and its WM_HOTKEY performs the binding's actions
//! (`App.hotkeyPressed`), as GTK registers its global shortcuts with the
//! desktop. Only the root set's: the core reads only that for a global
//! binding (`CoreApp.keyEvent`), so one inside a key table is global on
//! no platform.
//! https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey
//!
//! A hotkey takes its keys before any window sees them, Ghostty's too, so
//! in a Ghostty window it pre-empts what the core would have done with
//! them: a binding of the same keys the core tries first, as a
//! non-global `ctrl+key_a` before a global `ctrl+a`; the last key of a
//! pending sequence; and the copy, paste and select_all a search or
//! palette field keeps for itself.
const Hotkeys = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const uucode = @import("uucode");

const input = @import("../../input.zig");
const Binding = input.Binding;
const Config = @import("../../config.zig").Config;

const win32 = @import("win32.zig");
const L = win32.L;
const key = @import("key.zig");
const CommandPalette = @import("CommandPalette.zig");

const log = std.log.scoped(.win32);

/// One for each combination of modifiers and key the configuration binds
/// globally, registered or not.
entries: std.ArrayList(Entry) = .empty,

/// The id the last registration was given (`nextId`).
last_id: c_int = 0,

/// The failures logged so far, each logged once: every reload tries a
/// failed registration again, a soft one for each change of the system's
/// color scheme among them, and the same line each time would say
/// nothing new.
logged: std.ArrayList(Logged) = .empty,

const Entry = struct {
    /// The binding's trigger, by value: the configuration it came from is
    /// freed by the next `.config_change`.
    trigger: Binding.Trigger,
    combo: Combo,
    /// The id it is registered under, or null if registering it failed.
    id: ?c_int,
};

/// What RegisterHotKey takes for a trigger: the MOD_* flags, MOD_NOREPEAT
/// among them, and a virtual key.
pub const Combo = struct {
    mods: win32.UINT,
    vk: win32.UINT,
};

/// Why a trigger cannot be a hotkey, logged as its `err=`.
pub const Refusal = error{
    /// catch_all: it stands for every key nothing else binds.
    CatchAll,
    /// A modifier as the key: the hotkey would take it from every program.
    ModifierKey,
    /// The key has no virtual key here: no scan code (the keypad's
    /// navigation keys), none on this layout, or a character beyond what
    /// VkKeyScanExW takes or the layout types.
    NoKey,
    /// A keypad key whose virtual key is a main key's, which the hotkey
    /// would take too: numpad_enter's is Enter's. The main key is not
    /// refused, and takes the keypad's along (`enter` numpad_enter, `home`
    /// the keypad's 7 with NumLock off): refusing it would refuse Enter and
    /// every navigation key.
    SharedKey,
    /// F12, which Windows keeps for the debugger (RegisterHotKey).
    Reserved,
    /// The layout types the character only with a modifier the trigger
    /// does not give it: Shift, for '@' on a US layout or '1' on AZERTY,
    /// when the trigger does not hold Shift, or holds Ctrl as well, with
    /// which the key types a control character or nothing. The core
    /// matches a character by what the key types with exactly the
    /// trigger's modifiers held (`Set.getEvent`), so the hotkey would fire
    /// where the binding does not.
    NeedsShift,
    /// AltGr, which Windows gives as Ctrl+Alt, types the character on this
    /// layout, or Ctrl+Alt+the key types one there. The hotkey would take
    /// that character from every program, and a terminal sees the key
    /// without Ctrl and Alt (`Surface.isAltGr`), so the binding with them
    /// never matches.
    AltGr,
    /// Every action is one this runtime does not perform yet, as
    /// toggle_visibility or set_window_theme (`performsNone`): the hotkey
    /// would take its keys from every program and do nothing.
    Unsupported,
};

const Failure = union(enum) {
    refused: Refusal,
    system: win32.Win32Error,
};

const Logged = struct {
    trigger: Binding.Trigger,
    failure: Failure,
};

/// What a key is on a keyboard layout: the system's, or a test's
/// (`test_layout`).
pub const Layout = struct {
    /// VkKeyScanExW: the virtual key in the low byte and the shift state
    /// in the high one, or -1 if no key types the character.
    key_scan: *const fn (win32.WCHAR) i16,
    /// MapVirtualKeyExW with MAPVK_VSC_TO_VK_EX: the virtual key of a scan
    /// code in the Windows column of input/keycodes.zig, or 0.
    scan_to_vk: *const fn (u32) win32.UINT,
    /// Whether the key types a character with Ctrl and Alt held, and
    /// Shift if `shift`.
    alt_gr: *const fn (vk: win32.UINT, shift: bool) bool,

    const system: Layout = .{
        .key_scan = systemKeyScan,
        .scan_to_vk = systemScanToVk,
        .alt_gr = systemAltGr,
    };

    fn systemKeyScan(c: win32.WCHAR) i16 {
        return win32.VkKeyScanExW(c, win32.GetKeyboardLayout(0));
    }

    fn systemScanToVk(scan: u32) win32.UINT {
        return win32.MapVirtualKeyExW(scan, win32.MAPVK_VSC_TO_VK_EX, win32.GetKeyboardLayout(0));
    }

    fn systemAltGr(vk: win32.UINT, shift: bool) bool {
        var state = std.mem.zeroes([256]win32.BYTE);
        state[@intCast(win32.VK_CONTROL)] = 0x80;
        state[@intCast(win32.VK_MENU)] = 0x80;
        if (shift) state[@intCast(win32.VK_SHIFT)] = 0x80;
        const scan = win32.MapVirtualKeyW(vk, win32.MAPVK_VK_TO_VSC_EX);
        const c = key.layoutCodepoint(vk, scan, &state);
        // Control characters are what Ctrl makes of a key, not AltGr's.
        return c >= 0x20 and c != 0x7F;
    }
};

/// For tests: in place of RegisterHotKey, told each registration, and
/// answering `.SUCCESS` or the error GetLastError would.
pub var test_register: if (builtin.is_test) ?*const fn (win32.HWND, c_int, Combo) win32.Win32Error else void =
    if (builtin.is_test) null else {};

/// For tests: in place of UnregisterHotKey, told each id unregistered.
pub var test_unregister: if (builtin.is_test) ?*const fn (win32.HWND, c_int) void else void =
    if (builtin.is_test) null else {};

/// For tests: the keyboard layout in place of the system's.
pub var test_layout: if (builtin.is_test) ?*const Layout else void =
    if (builtin.is_test) null else {};

/// Unregister every hotkey and free it all, leaving none, not undefined:
/// `App.terminate` calls this before the windows' teardown, whose last
/// terminal starts the quit timer, which asks whether a hotkey opens a
/// window (`App.staysOpen`).
pub fn deinit(self: *Hotkeys, alloc: Allocator, hwnd: win32.HWND) void {
    for (self.entries.items) |entry| if (entry.id) |id| unregister(hwnd, id);
    self.entries.deinit(alloc);
    self.logged.deinit(alloc);
    self.* = .{};
}

/// Make the hotkeys on `hwnd` what `config` binds globally, from what an
/// earlier call registered. A combination still bound keeps its
/// registration and its id, so that another program cannot take it in
/// between, and a reload that changed no global binding, as the soft one
/// after each change of color scheme, registers nothing; the trigger it
/// stands for is updated, as the action is looked up when it is pressed.
/// One no longer bound is unregistered; a new one is registered under a
/// new id; and one that failed is tried again, which is how a user takes
/// a combination back from the program that held it. A failure, a refusal
/// among them, is logged, once (`logged`). Nothing is registered or
/// unregistered unless the memory for it all could be had.
pub fn refresh(self: *Hotkeys, alloc: Allocator, hwnd: win32.HWND, config: *const Config) Allocator.Error!void {
    const layout: *const Layout = if (builtin.is_test) test_layout orelse &.system else &.system;

    var wanted: std.ArrayList(Entry) = .empty;
    defer wanted.deinit(alloc);
    var it = config.keybind.set.bindings.iterator();
    while (it.next()) |binding| {
        const leaf: Binding.Set.GenericLeaf = switch (binding.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |leaf| leaf.generic(),
        };
        if (!leaf.flags.global) continue;
        const trigger = binding.key_ptr.*;
        if (performsNone(leaf.actionsSlice())) {
            self.logOnce(alloc, trigger, .{ .refused = error.Unsupported });
            continue;
        }
        const c = combo(trigger, layout) catch |err| {
            self.logOnce(alloc, trigger, .{ .refused = err });
            continue;
        };
        try want(alloc, &wanted, trigger, c);
    }

    // The new entries, made room for before anything changes.
    var new: usize = 0;
    for (wanted.items) |w| {
        if (self.find(w.combo) == null) new += 1;
    }
    try self.entries.ensureUnusedCapacity(alloc, new);

    var i: usize = 0;
    while (i < self.entries.items.len) {
        const entry = &self.entries.items[i];
        const w = for (wanted.items) |w| {
            if (std.meta.eql(w.combo, entry.combo)) break w;
        } else {
            if (entry.id) |id| unregister(hwnd, id);
            _ = self.entries.orderedRemove(i);
            continue;
        };
        entry.trigger = w.trigger;
        if (entry.id == null) entry.id = self.register(alloc, hwnd, entry.trigger, entry.combo);
        i += 1;
    }
    for (wanted.items) |w| {
        if (self.find(w.combo) != null) continue;
        self.entries.appendAssumeCapacity(.{
            .trigger = w.trigger,
            .combo = w.combo,
            .id = self.register(alloc, hwnd, w.trigger, w.combo),
        });
    }
}

/// Add `trigger` to `wanted`, unless another trigger there has the same
/// keys: then the physical one is kept, as `Set.getEvent` tries a key
/// event's physical key before its character, and the other is logged.
fn want(
    alloc: Allocator,
    wanted: *std.ArrayList(Entry),
    trigger: Binding.Trigger,
    c: Combo,
) Allocator.Error!void {
    for (wanted.items) |*w| {
        if (!std.meta.eql(w.combo, c)) continue;
        const physical = trigger.key == .physical and w.trigger.key != .physical;
        // Debug: every reload would repeat it, the soft one after each
        // change of color scheme among them.
        log.debug("a global keybind has the keys of another, which is kept trigger={f} kept={f}", .{
            if (physical) w.trigger else trigger,
            if (physical) trigger else w.trigger,
        });
        if (physical) w.trigger = trigger;
        return;
    }
    try wanted.append(alloc, .{ .trigger = trigger, .combo = c, .id = null });
}

/// The trigger of the hotkey a WM_HOTKEY names, or null if no hotkey
/// registered now has its id and its keys: one unregistered by a reload
/// after the message was posted, or a message RegisterHotKey did not
/// cause. The low word of `lparam` holds the MOD_* flags of the keys held,
/// without MOD_NOREPEAT (checked in the VM, 2026-11-02), and the high word
/// the virtual key (WM_HOTKEY).
pub fn pressed(self: *const Hotkeys, wparam: win32.WPARAM, lparam: win32.LPARAM) ?Binding.Trigger {
    const l: usize = @bitCast(lparam);
    for (self.entries.items) |entry| {
        const id = entry.id orelse continue;
        if (wparam != @as(usize, @intCast(id))) continue;
        const mods = win32.MOD_ALT | win32.MOD_CONTROL | win32.MOD_SHIFT | win32.MOD_WIN;
        if (l & 0xFFFF != entry.combo.mods & mods) return null;
        if ((l >> 16) & 0xFFFF != entry.combo.vk) return null;
        return entry.trigger;
    }
    return null;
}

/// The binding of `trigger`, a hotkey's, in `set`, or null if it is not a
/// global one: a reload that ran out of memory leaves the hotkeys as they
/// were (`App.configChange`), and the keys may be bound otherwise now.
pub fn globalLeaf(set: *const Binding.Set, trigger: Binding.Trigger) ?Binding.Set.GenericLeaf {
    const entry = set.get(trigger) orelse return null;
    const leaf: Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        // The configuration refuses a global sequence.
        .leader => return null,
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    return if (leaf.flags.global) leaf else null;
}

/// Whether a hotkey registered now performs, among its binding's actions
/// in `set`, one that opens a window with none open: new_window, or
/// toggle_quick_terminal, which makes the quick terminal when there is
/// none (`App.toggleQuick`). One refused, or held by another program,
/// cannot be pressed.
pub fn opensWindow(self: *const Hotkeys, set: *const Binding.Set) bool {
    for (self.entries.items) |entry| {
        if (entry.id == null) continue;
        const leaf = globalLeaf(set, entry.trigger) orelse continue;
        for (leaf.actionsSlice()) |action| switch (action) {
            .new_window, .toggle_quick_terminal => return true,
            else => {},
        };
    }
    return false;
}

/// The combination RegisterHotKey takes for `trigger` on `layout`.
fn combo(trigger: Binding.Trigger, layout: *const Layout) Refusal!Combo {
    // Each MOD_* flag stands for either key of its kind (RegisterHotKey),
    // as `binding` drops the sides. MOD_NOREPEAT: a held key fires once,
    // so that a held `new_window` opens one window.
    const held = trigger.mods.binding();
    var mods: win32.UINT = win32.MOD_NOREPEAT;
    if (held.shift) mods |= win32.MOD_SHIFT;
    if (held.ctrl) mods |= win32.MOD_CONTROL;
    if (held.alt) mods |= win32.MOD_ALT;
    if (held.super) mods |= win32.MOD_WIN;

    const key_vk: win32.UINT = switch (trigger.key) {
        .catch_all => return error.CatchAll,
        .physical => |k| try physicalVk(k, layout),
        .unicode => |cp| try unicodeVk(cp, held, layout),
    };
    // With Ctrl held, Pause is Break, which the layout gives VK_CANCEL
    // (Virtual-Key Codes), and a hotkey is matched by the virtual key the
    // layout gives. A terminal's binding sees it as Pause
    // (`key.scanCode`).
    const vk = if (key_vk == win32.VK_PAUSE and held.ctrl) win32.VK_CANCEL else key_vk;
    if (vk == win32.VK_F12) return error.Reserved;
    if (held.ctrl and held.alt and layout.alt_gr(vk, held.shift)) return error.AltGr;
    return .{ .mods = mods, .vk = vk };
}

/// The virtual key of physical key `k`.
fn physicalVk(k: input.Key, layout: *const Layout) Refusal!win32.UINT {
    return switch (k) {
        .shift_left,
        .shift_right,
        .control_left,
        .control_right,
        .alt_left,
        .alt_right,
        .meta_left,
        .meta_right,
        => error.ModifierKey,

        .numpad_enter => error.SharedKey,

        // By name, not through the layout: the keypad's digit and decimal
        // keys have the scan codes of the navigation keys they are with
        // NumLock off, and the layout maps those (0x4F to VK_END), as it
        // maps Pause's (0x45) to VK_NUMLOCK and NumLock's (0xE045) to
        // nothing (checked in the VM, 2026-11-02). A keypad digit then
        // fires only with NumLock on, as the binding does (`key.numpadKey`).
        .numpad_0 => win32.VK_NUMPAD0,
        .numpad_1 => win32.VK_NUMPAD0 + 1,
        .numpad_2 => win32.VK_NUMPAD0 + 2,
        .numpad_3 => win32.VK_NUMPAD0 + 3,
        .numpad_4 => win32.VK_NUMPAD0 + 4,
        .numpad_5 => win32.VK_NUMPAD0 + 5,
        .numpad_6 => win32.VK_NUMPAD0 + 6,
        .numpad_7 => win32.VK_NUMPAD0 + 7,
        .numpad_8 => win32.VK_NUMPAD0 + 8,
        .numpad_9 => win32.VK_NUMPAD9,
        .numpad_decimal => win32.VK_DECIMAL,
        .pause => win32.VK_PAUSE,
        .num_lock => @intCast(win32.VK_NUMLOCK),

        else => {
            const scan = for (input.keycodes.entries) |entry| {
                if (entry.key == k) break entry.native;
            } else return error.NoKey;
            if (scan == 0) return error.NoKey;
            const vk = layout.scan_to_vk(scan);
            if (vk == 0) return error.NoKey;
            return vk;
        },
    };
}

/// The virtual key of the key that types `cp` with the modifiers `held`,
/// as the core matches a character trigger in a window: by what the key
/// types (`Set.getEvent`), either case (`Trigger.foldedCodepoint`).
fn unicodeVk(cp: u21, held: input.Mods, layout: *const Layout) Refusal!win32.UINT {
    // An ASCII letter is its own virtual key (Virtual-Key Codes) on every
    // layout that types it. On one that does not, such as Russian, that
    // is the key in the letter's place on a US layout, which in a window
    // the core matches by the letter it types there, not this one.
    switch (cp) {
        'a'...'z' => return cp - 'a' + 'A',
        'A'...'Z' => return cp,
        else => {},
    }
    const c = folded(cp);
    // VkKeyScanExW takes one UTF-16 unit.
    if (c > 0xFFFF) return error.NoKey;
    const scanned = layout.key_scan(@intCast(c));
    if (scanned == -1) return error.NoKey;
    // The shift state's bits: 1 Shift, 2 Ctrl, 4 Alt (VkKeyScanExW).
    const bits: u16 = @bitCast(scanned);
    const vk = bits & 0xFF;
    return switch (bits >> 8) {
        0 => vk,
        1 => if (held.shift and !held.ctrl) vk else error.NeedsShift,
        6, 7 => error.AltGr,
        else => error.NeedsShift,
    };
}

/// `cp` case-folded, as `Trigger.foldedCodepoint` folds it, or `cp` if it
/// folds to more than one codepoint: VkKeyScanExW takes one.
fn folded(cp: u21) u21 {
    var buffer: [1]u21 = undefined;
    const slice = uucode.get(.case_folding_full, cp).with(&buffer, cp);
    return if (slice.len == 1) slice[0] else cp;
}

/// Whether this runtime performs none of `actions` (`Refusal.Unsupported`):
/// each is one the command palette leaves out (`CommandPalette.supported`,
/// the one exhaustive list of what this runtime performs), so that a new
/// action the palette cannot list is refused here too. All but `ignore`,
/// which the palette leaves out as doing nothing: a global `ignore` takes
/// its keys from every program, which is what it asks for, as on macOS,
/// where the core reports every global binding handled
/// (`CoreApp.keyEvent`) and the event tap then swallows the key.
fn performsNone(actions: []const Binding.Action) bool {
    for (actions) |action| {
        if (action == .ignore or CommandPalette.supported(action)) return false;
    }
    return true;
}

/// The entry for combination `c`, if any.
fn find(self: *const Hotkeys, c: Combo) ?*Entry {
    for (self.entries.items) |*entry| {
        if (std.meta.eql(entry.combo, c)) return entry;
    }
    return null;
}

/// Register `c` on `hwnd` under a new id, and return the id, or null,
/// logged, if it could not be: 1409, ERROR_HOTKEY_ALREADY_REGISTERED, when
/// another program, or another Ghostty process, holds it.
fn register(self: *Hotkeys, alloc: Allocator, hwnd: win32.HWND, trigger: Binding.Trigger, c: Combo) ?c_int {
    const id = self.nextId();
    const err: win32.Win32Error = err: {
        if (builtin.is_test) if (test_register) |f| break :err f(hwnd, id, c);
        if (win32.RegisterHotKey(hwnd, id, c.mods, c.vk).toBool()) break :err .SUCCESS;
        break :err win32.GetLastError();
    };
    if (err == .SUCCESS) return id;
    self.logOnce(alloc, trigger, .{ .system = err });
    return null;
}

fn unregister(hwnd: win32.HWND, id: c_int) void {
    if (builtin.is_test) if (test_unregister) |f| return f(hwnd, id);
    if (!win32.UnregisterHotKey(hwnd, id).toBool()) {
        log.warn("cannot unregister a global keybind id={} err={}", .{ id, win32.GetLastError() });
    }
}

/// A new id. An application's hotkeys take ids 0x0000 to 0xBFFF
/// (RegisterHotKey); these count up from 1 through them, then start
/// again, past the ones in use: a registration under an id the window
/// already has is kept along with the old one (RegisterHotKey). There is
/// always one free: no more combinations exist than 16 sets of modifiers
/// times 256 virtual keys.
fn nextId(self: *Hotkeys) c_int {
    while (true) {
        self.last_id = if (self.last_id >= 0xBFFF) 1 else self.last_id + 1;
        for (self.entries.items) |entry| {
            if (entry.id == self.last_id) break;
        } else return self.last_id;
    }
}

/// Log that `trigger` cannot be a hotkey, unless that was logged before.
fn logOnce(self: *Hotkeys, alloc: Allocator, trigger: Binding.Trigger, failure: Failure) void {
    for (self.logged.items) |l| {
        if (l.trigger.equal(trigger) and std.meta.eql(l.failure, failure)) return;
    }
    // Without the memory to remember it, it is logged again next time.
    self.logged.append(alloc, .{ .trigger = trigger, .failure = failure }) catch {};
    switch (failure) {
        inline else => |err| log.warn("cannot register a global keybind trigger={f} err={}", .{ trigger, err }),
    }
}

/// For tests: a message-only window, as `App.init` makes the app's.
fn testWindow() !win32.HWND {
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

test "win32: a global keybind holds its keys across the system until deinit" {
    // The system's layout and RegisterHotKey. F24, which few keyboards
    // have, with Ctrl, Alt and Shift, which no program the tests run
    // beside binds.
    const alloc = std.testing.allocator;
    var config: Config = try .default(alloc);
    defer config.deinit();
    try config.keybind.parseCLI(config._arena.?.allocator(), "global:ctrl+alt+shift+f24=new_window");
    const a = try testWindow();
    defer _ = win32.DestroyWindow(a);
    const b = try testWindow();
    defer _ = win32.DestroyWindow(b);

    var first: Hotkeys = .{};
    var first_live = true;
    defer if (first_live) first.deinit(alloc, a);
    try first.refresh(alloc, a, &config);
    try std.testing.expectEqual(0, first.logged.items.len);
    try std.testing.expect(first.entries.items[0].id != null);

    // The keys it holds, by the values RegisterHotKey documents:
    // MOD_ALT | MOD_CONTROL | MOD_SHIFT, and VK_F24.
    try std.testing.expect(!win32.RegisterHotKey(b, 0x7000, 0x0007, 0x87).toBool());
    try std.testing.expectEqual(win32.Win32Error.HOTKEY_ALREADY_REGISTERED, win32.GetLastError());

    // Another window's try fails as it would in another program, logged.
    var second: Hotkeys = .{};
    defer second.deinit(alloc, b);
    try second.refresh(alloc, b, &config);
    try std.testing.expectEqual(null, second.entries.items[0].id);
    try std.testing.expect(std.meta.eql(
        Failure{ .system = .HOTKEY_ALREADY_REGISTERED },
        second.logged.items[0].failure,
    ));

    // Once the first lets go, the second's next try takes it.
    first.deinit(alloc, a);
    first_live = false;
    try second.refresh(alloc, b, &config);
    try std.testing.expect(second.entries.items[0].id != null);
}

/// For tests: in place of RegisterHotKey, UnregisterHotKey and the
/// system's layout, counting the calls. F12 is the only key on its layout
/// that is not a letter.
const TestSystem = struct {
    var calls: usize = 0;

    const layout: Layout = .{
        .key_scan = &keyScan,
        .scan_to_vk = &scanToVk,
        .alt_gr = &altGr,
    };

    fn install() void {
        calls = 0;
        test_register = &registerHotKey;
        test_unregister = &unregisterHotKey;
        test_layout = &layout;
    }

    fn remove() void {
        test_register = null;
        test_unregister = null;
        test_layout = null;
    }

    fn registerHotKey(hwnd: win32.HWND, id: c_int, c: Combo) win32.Win32Error {
        _ = hwnd;
        _ = id;
        _ = c;
        calls += 1;
        return .SUCCESS;
    }

    fn unregisterHotKey(hwnd: win32.HWND, id: c_int) void {
        _ = hwnd;
        _ = id;
        calls += 1;
    }

    fn keyScan(c: win32.WCHAR) i16 {
        _ = c;
        return -1;
    }

    fn scanToVk(scan: u32) win32.UINT {
        return if (scan == 0x58) win32.VK_F12 else 0;
    }

    fn altGr(vk: win32.UINT, shift: bool) bool {
        _ = vk;
        _ = shift;
        return false;
    }
};

test "win32: a global keybind refresh that runs out of memory changes nothing" {
    const alloc = std.testing.allocator;
    TestSystem.install();
    defer TestSystem.remove();
    const hwnd = try testWindow();
    defer _ = win32.DestroyWindow(hwnd);

    var before: Config = try .default(alloc);
    defer before.deinit();
    for ([_][]const u8{
        "global:ctrl+a=new_window",
        "global:ctrl+b=new_window",
    }) |bind| try before.keybind.parseCLI(before._arena.?.allocator(), bind);
    // More new combinations than the entries have room for, so that the
    // room is allocated too.
    var after: Config = try .default(alloc);
    defer after.deinit();
    for ([_][]const u8{
        "global:ctrl+b=new_tab", "global:ctrl+c=new_tab",
        "global:ctrl+d=new_tab", "global:ctrl+e=new_tab",
        "global:ctrl+f=new_tab", "global:ctrl+g=new_tab",
        "global:ctrl+h=new_tab", "global:ctrl+i=new_tab",
        "global:ctrl+j=new_tab",
    }) |bind| try after.keybind.parseCLI(after._arena.?.allocator(), bind);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var hotkeys: Hotkeys = .{};
        defer hotkeys.deinit(alloc, hwnd);
        try hotkeys.refresh(alloc, hwnd, &before);
        var entries: [2]Entry = undefined;
        @memcpy(&entries, hotkeys.entries.items);
        TestSystem.calls = 0;

        // Every growth a new allocation, never one in place, so that each
        // can fail.
        var failing: std.testing.FailingAllocator = .init(alloc, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        hotkeys.refresh(failing.allocator(), hwnd, &after) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(0, TestSystem.calls);
            try std.testing.expectEqual(entries.len, hotkeys.entries.items.len);
            for (entries, hotkeys.entries.items) |old, entry| {
                try std.testing.expect(std.meta.eql(old.combo, entry.combo));
                try std.testing.expectEqual(old.id, entry.id);
            }
            continue;
        };
        // Ctrl+A unregistered, and eight registered.
        try std.testing.expectEqual(9, TestSystem.calls);
        break;
    }
    try std.testing.expect(fail_index > 0);
}

test "win32: a global keybind refused without the memory to remember it is logged again" {
    const alloc = std.testing.allocator;
    TestSystem.install();
    defer TestSystem.remove();
    const hwnd = try testWindow();
    defer _ = win32.DestroyWindow(hwnd);
    var config: Config = try .default(alloc);
    defer config.deinit();
    try config.keybind.parseCLI(config._arena.?.allocator(), "global:ctrl+f12=new_window");

    var hotkeys: Hotkeys = .{};
    defer hotkeys.deinit(alloc, hwnd);
    var failing: std.testing.FailingAllocator = .init(alloc, .{ .fail_index = 0 });
    try hotkeys.refresh(failing.allocator(), hwnd, &config);
    try std.testing.expectEqual(0, hotkeys.logged.items.len);
    try hotkeys.refresh(alloc, hwnd, &config);
    try std.testing.expectEqual(1, hotkeys.logged.items.len);
    try hotkeys.refresh(alloc, hwnd, &config);
    try std.testing.expectEqual(1, hotkeys.logged.items.len);
    try std.testing.expectEqual(0, TestSystem.calls);
}

test "win32: a global keybind's id counts up to the last, then again past those in use" {
    const alloc = std.testing.allocator;
    var hotkeys: Hotkeys = .{ .last_id = 0xBFFE };
    defer hotkeys.entries.deinit(alloc);
    try hotkeys.entries.append(alloc, .{
        .trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } },
        .combo = .{ .mods = win32.MOD_CONTROL | win32.MOD_NOREPEAT, .vk = 'A' },
        .id = 1,
    });
    try std.testing.expectEqual(0xBFFF, hotkeys.nextId());
    try std.testing.expectEqual(2, hotkeys.nextId());
}
