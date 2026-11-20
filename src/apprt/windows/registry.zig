//! String values in the registry, as the runtime's own keys hold them:
//! the default terminal's choice and its class (`default_terminal`,
//! `handoff`).
const std = @import("std");

const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const error_file_not_found: win32.LONG = 2;

/// Room for a command that starts any program by its quoted path: the
/// longest Windows path, its quotes and its terminator.
pub const command_units = std.os.windows.PATH_MAX_WIDE + 3;

/// The string `name` holds under `root`'s `subkey`, in `buf`, or null if
/// the key or the value is absent. A REG_EXPAND_SZ comes back expanded.
/// UnexpectedValue: the value is not a string, or does not fit `buf`.
pub fn readString(
    root: win32.HKEY,
    subkey: [*:0]const u16,
    name: ?[*:0]const u16,
    buf: []u16,
) error{UnexpectedValue}!?[:0]const u16 {
    var size: win32.DWORD = @intCast(@min(buf.len * 2, std.math.maxInt(win32.DWORD)));
    const rc = win32.RegGetValueW(root, subkey, name, win32.RRF_RT_REG_SZ, null, buf.ptr, &size);
    switch (rc) {
        0 => {
            // RRF_RT_REG_SZ ends the string, counted in `size`.
            const units = size / 2;
            const len = std.mem.indexOfScalar(u16, buf[0..units], 0) orelse return error.UnexpectedValue;
            return buf[0..len :0];
        },
        error_file_not_found => return null,
        else => {
            log.warn("cannot read a registry string err={d}", .{rc});
            return error.UnexpectedValue;
        },
    }
}

/// Write `text` as `name` under `root`'s `subkey`, made if missing; a
/// null `name` is the key's default value.
pub fn writeString(
    root: win32.HKEY,
    subkey: [*:0]const u16,
    name: ?[*:0]const u16,
    text: [:0]const u16,
) error{RegistryFailed}!void {
    var key: win32.HKEY = undefined;
    const created = win32.RegCreateKeyExW(root, subkey, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_SET_VALUE, null, &key, null);
    if (created != 0) {
        log.warn("cannot open a registry key err={d}", .{created});
        return error.RegistryFailed;
    }
    defer _ = win32.RegCloseKey(key);
    const bytes = std.mem.sliceAsBytes(text[0 .. text.len + 1]);
    const set = win32.RegSetValueExW(key, name, 0, win32.REG_SZ, bytes.ptr, @intCast(bytes.len));
    if (set != 0) {
        log.warn("cannot write a registry string err={d}", .{set});
        return error.RegistryFailed;
    }
}

test "win32: a registry string is read as written, or absent, or refused when it does not fit" {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const testing = std.testing;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "Software\\GhosttyTest\\{d}\\registry", .{std.os.windows.GetCurrentProcessId()});
    var path_w: [96]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&path_w, path);
    path_w[n] = 0;
    const key = path_w[0..n :0];
    defer _ = win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, key);

    var buf: [8]u16 = undefined;
    try testing.expectEqual(null, try readString(win32.HKEY_CURRENT_USER, key, W("v"), &buf));
    try writeString(win32.HKEY_CURRENT_USER, key, W("v"), W("abc"));
    try testing.expectEqualSlices(u16, W("abc"), (try readString(win32.HKEY_CURRENT_USER, key, W("v"), &buf)).?);
    try writeString(win32.HKEY_CURRENT_USER, key, W("v"), W("abcdefghij"));
    try testing.expectError(error.UnexpectedValue, readString(win32.HKEY_CURRENT_USER, key, W("v"), &buf));
}
