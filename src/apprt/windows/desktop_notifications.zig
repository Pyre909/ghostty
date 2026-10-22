//! A terminal's desktop notifications, as GTK keeps them
//! (src/apprt/gtk/desktop_notifications.zig): its toasts (`toast.zig`) are
//! in a group of their own, its core surface's id, so that they are
//! removed together when it gains the focus or closes, and one shown while
//! it has the focus is removed after three seconds, as macOS and GTK
//! remove it.

const DesktopNotifications = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const toast = @import("toast.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// The WM_TIMER on the terminal's window that removes the toasts shown
/// while it had the focus (`expire`).
pub const timer_id: win32.UINT_PTR = 2;

/// How long such a toast stays: macOS's and GTK's three seconds.
pub const lapse_ms: u32 = 3 * std.time.ms_per_s;

/// The group of the terminal's toasts, its core surface's id
/// (`CoreSurface.id`), kept past the core's teardown, by which a click
/// finds the terminal (`App.notificationClicked`); 0 until the core is
/// made.
id: u64 = 0,

/// Toasts may still be shown or kept in the notification center (`clear`).
shown: bool = false,

/// The toasts shown while the terminal had the focus, in the order they
/// lapse, which is the order they were shown in.
expiring: std.ArrayListUnmanaged(Expiring) = .empty,

const Expiring = struct {
    tag: u64,
    /// In GetTickCount64's milliseconds.
    at: u64,
};

pub fn deinit(self: *DesktopNotifications, alloc: Allocator) void {
    self.expiring.deinit(alloc);
}

/// What a toast shows; it goes in the terminal's group.
pub const Content = struct {
    title: []const u8,
    body: []const u8,
    /// The terminal's title, under the body, as macOS shows it.
    attribution: ?[]const u8,
};

/// Show `content` as the toast `tag`; one shown while the terminal has the
/// focus (`focused`) is removed after three seconds, through the timer on
/// `hwnd`, the terminal's window. `now` is in GetTickCount64's
/// milliseconds. False if it could not be shown.
pub fn send(
    self: *DesktopNotifications,
    alloc: Allocator,
    notifier: toast.Notifier,
    hwnd: win32.HWND,
    content: Content,
    tag: u64,
    focused: bool,
    now: u64,
) bool {
    if (!notifier.show(.{
        .title = content.title,
        .body = content.body,
        .attribution = content.attribution,
        .group = self.id,
        .tag = tag,
    })) return false;
    self.shown = true;
    if (!focused) return true;

    const first = self.expiring.items.len == 0;
    self.expiring.append(alloc, .{ .tag = tag, .at = now + lapse_ms }) catch {
        // Gone when the terminal next gains the focus or closes.
        log.warn("cannot keep a toast to remove later", .{});
        return true;
    };
    // The timer is set for the first toast to lapse; a later one must not
    // put it off.
    if (first) arm(hwnd, lapse_ms);
    return true;
}

/// Remove the terminal's toasts, shown or kept in the notification center,
/// through `notifier` if there is one.
pub fn clear(self: *DesktopNotifications, notifier: ?toast.Notifier, hwnd: win32.HWND) void {
    if (!self.shown) return;
    self.shown = false;
    self.expiring.clearRetainingCapacity();
    _ = win32.KillTimer(hwnd, timer_id);
    if (notifier) |n| n.removeGroup(self.id);
}

/// The timer's WM_TIMER, at `now`: the toasts that have lapsed, all at the
/// front, are removed, and the timer is set again for the next one, or
/// stopped. One that comes before any has lapsed, already queued when a
/// toast was removed, only sets it again.
pub fn expire(self: *DesktopNotifications, notifier: ?toast.Notifier, hwnd: win32.HWND, now: u64) void {
    var lapsed: usize = 0;
    while (lapsed < self.expiring.items.len and self.expiring.items[lapsed].at <= now) : (lapsed += 1) {
        if (notifier) |n| n.remove(self.id, self.expiring.items[lapsed].tag);
    }
    const left = self.expiring.items[lapsed..];
    std.mem.copyForwards(Expiring, self.expiring.items[0..left.len], left);
    self.expiring.shrinkRetainingCapacity(left.len);

    if (self.expiring.items.len == 0) {
        _ = win32.KillTimer(hwnd, timer_id);
        return;
    }
    arm(hwnd, @intCast(@max(self.expiring.items[0].at - now, win32.USER_TIMER_MINIMUM)));
}

fn arm(hwnd: win32.HWND, ms: u32) void {
    if (win32.SetTimer(hwnd, timer_id, ms, null) == 0) {
        log.warn("SetTimer failed, a toast will stay err={}", .{win32.GetLastError()});
    }
}

test "win32: a terminal's toasts are kept in its group and lapse when shown with the focus" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // A window for the timer.
    const hwnd = win32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
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

    var fake: toast.TestNotifier = .{};
    const notifier = fake.notifier();
    var n: DesktopNotifications = .{ .id = 7 };
    defer n.deinit(alloc);
    const content: Content = .{ .title = "t", .body = "b", .attribution = "vim" };

    // Without the focus: in the group, not lapsing.
    try testing.expect(n.send(alloc, notifier, hwnd, content, 1, false, 0));
    try testing.expectEqual(7, fake.shown[0].group);
    try testing.expectEqualStrings("vim", fake.shown[0].attribution orelse "");
    try testing.expectEqual(0, n.expiring.items.len);

    // Two with the focus, a second apart: each lapses three seconds after
    // it was shown, the second not putting the first off.
    try testing.expect(n.send(alloc, notifier, hwnd, content, 2, true, 1000));
    try testing.expect(n.send(alloc, notifier, hwnd, content, 3, true, 2000));
    n.expire(notifier, hwnd, 3999);
    try testing.expectEqual(0, fake.removed_len);
    n.expire(notifier, hwnd, 4000);
    try testing.expectEqual(1, fake.removed_len);
    try testing.expectEqual([2]u64{ 7, 2 }, fake.removed[0]);
    try testing.expectEqual(1, n.expiring.items.len);
    n.expire(notifier, hwnd, 5000);
    try testing.expectEqual([2]u64{ 7, 3 }, fake.removed[1]);
    try testing.expectEqual(0, n.expiring.items.len);

    // Cleared once, as a group, and not again with none since.
    n.clear(notifier, hwnd);
    n.clear(notifier, hwnd);
    try testing.expectEqual(1, fake.removed_groups_len);
    try testing.expectEqual(7, fake.removed_groups[0]);

    // One that could not be shown leaves nothing to clear.
    fake.fail = true;
    try testing.expect(!n.send(alloc, notifier, hwnd, content, 4, true, 6000));
    try testing.expectEqual(0, n.expiring.items.len);
    n.clear(notifier, hwnd);
    try testing.expectEqual(1, fake.removed_groups_len);
}
