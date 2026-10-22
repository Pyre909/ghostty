//! Desktop notifications (OSC 9, OSC 777) as Windows toasts, through the
//! Windows Runtime's Windows.UI.Notifications, which keeps each one until
//! it is removed, as macOS's and GTK's notification centers do.
//!
//! A portable exe has no package to give it an identity, so Ghostty
//! registers its app ID (`app_id`, GTK's application id) for the current
//! user the first time it shows a toast (`register`), as Windows' own App
//! SDK does for an unpackaged app.
//!
//! The interfaces are vtable structs in the order of the Windows SDK's
//! headers (Include\<version>\winrt\windows.ui.notifications.h and
//! windows.data.xml.dom.h, 10.0.28000.0), which mingw does not ship; only
//! the methods called here are typed, every other slot is an untyped
//! pointer, and the tests check the slot counts and the typed slots'
//! indices against those headers, as src/renderer/d3d11/api.zig does.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const win32 = @import("win32.zig");
const wideFromUtf8 = @import("clipboard.zig").wideFromUtf8;

const log = std.log.scoped(.win32);

const HRESULT = win32.HRESULT;
const ULONG = windows.ULONG;
const HSTRING = win32.HSTRING;
const HWND = windows.HWND;
const GUID = windows.GUID;

/// The app ID toasts are shown under: GTK's application id, which a debug
/// build has its own of, so that Ghostty can be developed in Ghostty.
pub const app_id = switch (builtin.mode) {
    .debug, .safe => build_config.bundle_id ++ "-debug",
    .fast, .small => build_config.bundle_id,
};

/// The name toasts show, as the Linux desktop entry's.
pub const app_name = switch (builtin.mode) {
    .debug, .safe => "Ghostty (Debug)",
    .fast, .small => "Ghostty",
};

/// An untyped vtable slot, there so that the slots after it keep their
/// index.
const Slot = *const anyopaque;

/// IInspectable's slots, which every Windows Runtime interface starts with.
const Inspectable = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: Slot,
    Release: *const fn (*anyopaque) callconv(.winapi) ULONG,
    GetIids: Slot,
    GetRuntimeClassName: Slot,
    GetTrustLevel: Slot,
};

/// Any Windows Runtime object, through its IInspectable slots.
const Object = extern struct {
    vtable: *const VTable,

    const VTable = extern struct { base: Inspectable };
};

/// Drops one reference to any of the interfaces below.
fn release(obj: anytype) void {
    _ = obj.vtable.base.Release(obj);
}

/// QueryInterface for `T`, which carries its IID as `T.IID`; the returned
/// reference is the caller's.
fn query(obj: anytype, comptime T: type) error{ToastFailed}!*T {
    var out: ?*anyopaque = null;
    try check(obj.vtable.base.QueryInterface(obj, &T.IID, &out), "QueryInterface");
    return @ptrCast(@alignCast(out orelse return error.ToastFailed));
}

fn check(hr: HRESULT, what: []const u8) error{ToastFailed}!void {
    if (hr >= 0) return;
    log.warn("toast: {s} failed hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
    return error.ToastFailed;
}

const IToastNotificationManagerStatics = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{50ac103f-d235-4598-bbef-98fe4d1a3ad4}");

    pub const VTable = extern struct {
        base: Inspectable,
        CreateToastNotifier: Slot,
        CreateToastNotifierWithId: *const fn (*IToastNotificationManagerStatics, HSTRING, *?*IToastNotifier) callconv(.winapi) HRESULT,
        GetTemplateContent: Slot,
    };
};

const IToastNotificationManagerStatics2 = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{7ab93c52-0e48-4750-ba9d-1a4113981847}");

    pub const VTable = extern struct {
        base: Inspectable,
        get_History: *const fn (*IToastNotificationManagerStatics2, *?*IToastNotificationHistory) callconv(.winapi) HRESULT,
    };
};

const IToastNotificationHistory = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{5caddc63-01d3-4c97-986f-0533483fee14}");

    pub const VTable = extern struct {
        base: Inspectable,
        RemoveGroup: Slot,
        RemoveGroupWithId: *const fn (*IToastNotificationHistory, HSTRING, HSTRING) callconv(.winapi) HRESULT,
        RemoveGroupedTagWithId: *const fn (*IToastNotificationHistory, HSTRING, HSTRING, HSTRING) callconv(.winapi) HRESULT,
        RemoveGroupedTag: Slot,
        Remove: Slot,
        Clear: Slot,
        ClearWithId: *const fn (*IToastNotificationHistory, HSTRING) callconv(.winapi) HRESULT,
    };
};

const IToastNotifier = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{75927b93-03f3-41ec-91d3-6e5bac1b38e7}");

    pub const VTable = extern struct {
        base: Inspectable,
        Show: *const fn (*IToastNotifier, *IToastNotification) callconv(.winapi) HRESULT,
        Hide: Slot,
        get_Setting: Slot,
        AddToSchedule: Slot,
        RemoveFromSchedule: Slot,
        GetScheduledToastNotifications: Slot,
    };
};

const IToastNotificationFactory = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{04124b20-82c6-4229-b109-fd9ed4662b53}");

    pub const VTable = extern struct {
        base: Inspectable,
        CreateToastNotification: *const fn (*IToastNotificationFactory, *IXmlDocument, *?*IToastNotification) callconv(.winapi) HRESULT,
    };
};

/// Windows.Data.Xml.Dom.IXmlDocument, only ever passed on.
const IXmlDocument = extern struct {
    vtable: *const Object.VTable,

    pub const IID: GUID = GUID.parse("{f7f3a506-1e87-42d6-bcfb-b8c809fa5494}");
};

/// EventRegistrationToken.
const EventToken = extern struct { value: i64 };

const IToastNotification = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{997e2675-059e-4e60-8b06-1760917c8b80}");

    pub const VTable = extern struct {
        base: Inspectable,
        get_Content: Slot,
        put_ExpirationTime: Slot,
        get_ExpirationTime: Slot,
        add_Dismissed: Slot,
        remove_Dismissed: Slot,
        add_Activated: *const fn (*IToastNotification, *Activated, *EventToken) callconv(.winapi) HRESULT,
        remove_Activated: Slot,
        add_Failed: Slot,
        remove_Failed: Slot,
    };
};

const IToastNotification2 = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{9dfb9fd1-143a-490e-90bf-b9fba7132de7}");

    pub const VTable = extern struct {
        base: Inspectable,
        put_Tag: *const fn (*IToastNotification2, HSTRING) callconv(.winapi) HRESULT,
        get_Tag: Slot,
        put_Group: *const fn (*IToastNotification2, HSTRING) callconv(.winapi) HRESULT,
        get_Group: Slot,
        put_SuppressPopup: Slot,
        get_SuppressPopup: Slot,
    };
};

const IXmlDocumentIO = extern struct {
    vtable: *const VTable,

    pub const IID: GUID = GUID.parse("{6cd0e74e-ee65-4489-9ebf-ca43e87ba637}");

    pub const VTable = extern struct {
        base: Inspectable,
        LoadXml: *const fn (*IXmlDocumentIO, HSTRING) callconv(.winapi) HRESULT,
        LoadXmlWithSettings: Slot,
        SaveToFileAsync: Slot,
    };
};

/// A Windows Runtime string, owned.
const String = struct {
    handle: HSTRING,

    fn init(text: []const u16) error{ToastFailed}!String {
        var handle: HSTRING = null;
        try check(win32.WindowsCreateString(text.ptr, @intCast(text.len), &handle), "WindowsCreateString");
        return .{ .handle = handle };
    }

    /// `n` in decimal.
    fn decimal(n: u64) error{ToastFailed}!String {
        var digits: [20]u8 = undefined;
        const text = std.mem.print(&digits, "{d}", .{n}) catch unreachable;
        var buf: [20]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, text) catch unreachable;
        return init(buf[0..len]);
    }

    fn deinit(self: String) void {
        _ = win32.WindowsDeleteString(self.handle);
    }
};

/// The activation factory of the Windows Runtime class `name`, as `T`.
fn factoryOf(comptime T: type, comptime name: []const u8) error{ToastFailed}!*T {
    const class = try String.init(std.unicode.utf8ToUtf16LeStringLiteral(name));
    defer class.deinit();
    var out: ?*anyopaque = null;
    try check(win32.RoGetActivationFactory(class.handle, &T.IID, &out), "RoGetActivationFactory(" ++ name ++ ")");
    return @ptrCast(@alignCast(out orelse return error.ToastFailed));
}

/// TypedEventHandler<ToastNotification, IInspectable>, the handler of a
/// toast's Activated event, which Windows raises on a thread of its own
/// when the toast is clicked. It posts `message` to `hwnd` with the toast's
/// group, its terminal's id, for the UI thread to act on. It is agile
/// (IAgileObject), so that COM calls it on that thread rather than marshal
/// the call, and its reference count, the only thing that changes, is
/// atomic.
pub const Activated = extern struct {
    vtable: *const VTable,
    refs: std.atomic.Value(u32),
    hwnd: HWND,
    message: u32,
    group: u64,

    pub const IID: GUID = GUID.parse("{ab54de2d-97d9-5528-b6ad-105afe156530}");

    pub const VTable = extern struct {
        QueryInterface: *const fn (*Activated, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Activated) callconv(.winapi) ULONG,
        Release: *const fn (*Activated) callconv(.winapi) ULONG,
        Invoke: *const fn (*Activated, ?*IToastNotification, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    /// The process's own, thread-safe, rather than the app's: the Activated
    /// registration is never removed, so Windows may release the handler on
    /// any thread at any time, after the app and its allocator are gone.
    const alloc = std.heap.smp_allocator;

    const handler_vtable: VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = releaseRef,
        .Invoke = invoke,
    };

    /// One reference, the caller's.
    pub fn create(hwnd: HWND, message: u32, group: u64) Allocator.Error!*Activated {
        const self = try alloc.create(Activated);
        self.* = .{ .vtable = &handler_vtable, .refs = .init(1), .hwnd = hwnd, .message = message, .group = group };
        return self;
    }

    fn queryInterface(self: *Activated, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        for ([_]*const GUID{ &IID, &win32.IID_IUnknown, &win32.IID_IAgileObject }) |known| {
            if (std.meta.eql(iid.*, known.*)) {
                _ = addRef(self);
                out.* = self;
                return win32.S_OK;
            }
        }
        out.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(self: *Activated) callconv(.winapi) ULONG {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseRef(self: *Activated) callconv(.winapi) ULONG {
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) alloc.destroy(self);
        return left;
    }

    fn invoke(self: *Activated, _: ?*IToastNotification, _: ?*anyopaque) callconv(.winapi) HRESULT {
        // The window may be gone by now, the app quitting: then nothing
        // happens, which is right.
        const message = groupMessage(self.group);
        _ = win32.PostMessageW(self.hwnd, self.message, message[0], message[1]);
        return win32.S_OK;
    }
};

/// A toast's group, a 64-bit id, as a message's two parameters, its low
/// half in the first and its high half in the second, so that it gets
/// through on a target with 32-bit parameters as well (`messageGroup`).
pub fn groupMessage(group: u64) struct { win32.WPARAM, win32.LPARAM } {
    const low: u32 = @truncate(group);
    const high: u32 = @truncate(group >> 32);
    return .{ low, @bitCast(@as(usize, high)) };
}

/// The group a message carries (`groupMessage`).
pub fn messageGroup(wparam: win32.WPARAM, lparam: win32.LPARAM) u64 {
    const low: u32 = @truncate(wparam);
    const high: u32 = @truncate(@as(usize, @bitCast(lparam)));
    return @as(u64, high) << 32 | low;
}

/// What a toast shows, and how it is found again: `group`, the id of the
/// terminal it is for (0 for the app), and `tag`, its own within the group.
pub const Toast = struct {
    title: []const u8,
    body: []const u8,
    /// A smaller line under the body, where macOS shows the terminal's
    /// title.
    attribution: ?[]const u8 = null,
    group: u64,
    tag: u64,
};

/// The toast's content as Windows reads it: the ToastGeneric template,
/// with "Ghostty" for an empty title, as GTK shows one. The text is
/// escaped; of the characters XML cannot hold, controls other than tab and
/// the line breaks are dropped, and invalid UTF-8 and the noncharacters
/// U+FFFE and U+FFFF become U+FFFD.
pub fn toastXml(alloc: Allocator, toast: Toast) ![:0]u16 {
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(alloc);
    try xml.appendSlice(alloc, "<toast><visual><binding template=\"ToastGeneric\"><text>");
    try appendEscaped(alloc, &xml, if (toast.title.len == 0) "Ghostty" else toast.title);
    try xml.appendSlice(alloc, "</text><text>");
    try appendEscaped(alloc, &xml, toast.body);
    try xml.appendSlice(alloc, "</text>");
    if (toast.attribution) |attribution| {
        if (attribution.len != 0) {
            try xml.appendSlice(alloc, "<text placement=\"attribution\">");
            try appendEscaped(alloc, &xml, attribution);
            try xml.appendSlice(alloc, "</text>");
        }
    }
    try xml.appendSlice(alloc, "</binding></visual></toast>");
    // Invalid UTF-8 comes out as U+FFFD. The noncharacters are valid UTF-8,
    // and a unit of their value is never half of a surrogate pair.
    const wide = wideFromUtf8(alloc, xml.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ToastFailed,
    };
    for (wide) |*unit| {
        if (unit.* == 0xFFFE or unit.* == 0xFFFF) unit.* = std.unicode.replacement_character;
    }
    return wide;
}

fn appendEscaped(alloc: Allocator, xml: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try xml.appendSlice(alloc, "&amp;"),
        '<' => try xml.appendSlice(alloc, "&lt;"),
        '>' => try xml.appendSlice(alloc, "&gt;"),
        '"' => try xml.appendSlice(alloc, "&quot;"),
        '\'' => try xml.appendSlice(alloc, "&apos;"),
        '\t', '\n', '\r' => try xml.append(alloc, c),
        0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {},
        else => try xml.append(alloc, c),
    };
}

/// The icon toasts show, `resources` being the resources directory
/// (`share/ghostty`): the build installs it beside it, where Linux has it
/// (src/build/GhosttyResources.zig), named after `build_config.bundle_id`
/// in every build. Written in `buf`, with backslashes, which the path
/// from the resources directory may mix with slashes; null if it has no
/// parent or does not fit.
pub fn iconPath(buf: []u8, resources: []const u8) ?[]const u8 {
    const share = std.fs.path.dirname(resources) orelse return null;
    const path = std.mem.print(buf, "{s}\\icons\\hicolor\\256x256\\apps\\{s}.png", .{
        share,
        build_config.bundle_id,
    }) catch return null;
    std.mem.replaceScalar(u8, path, '/', '\\');
    return path;
}

/// Register `id` as an app that shows toasts, with the `name` and the
/// `icon` (a PNG's path, or null for none) its toasts show, for the current
/// user (HKCU\Software\Classes\AppUserModelId), as a package or an
/// installer would. Rewritten each time, so that a Ghostty moved
/// elsewhere shows its own icon. The icon is optional: one that cannot be
/// written is left out, logged, and a stale one removed.
pub fn register(id: []const u8, name: []const u8, icon: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.mem.print(&buf, "Software\\Classes\\AppUserModelId\\{s}", .{id});
    var wide_buf: [256]u16 = undefined;
    const subkey = try toWide(&wide_buf, path);

    var key: win32.HKEY = undefined;
    const created = win32.RegCreateKeyExW(
        win32.HKEY_CURRENT_USER,
        subkey,
        0,
        null,
        win32.REG_OPTION_NON_VOLATILE,
        win32.KEY_SET_VALUE,
        null,
        &key,
        null,
    );
    if (created != 0) {
        log.warn("toast: RegCreateKeyExW failed err={d}", .{created});
        return error.ToastFailed;
    }
    defer _ = win32.RegCloseKey(key);

    try setString(key, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), name);
    const icon_uri = std.unicode.utf8ToUtf16LeStringLiteral("IconUri");
    const written = if (icon) |path_utf8| written: {
        setString(key, icon_uri, path_utf8) catch break :written false;
        break :written true;
    } else false;
    if (!written) {
        if (icon != null) log.warn("toast: the icon is not registered, toasts show none", .{});
        _ = win32.RegDeleteValueW(key, icon_uri);
    }
}

fn setString(key: win32.HKEY, name: [:0]const u16, value: []const u8) !void {
    var buf: [1024]u16 = undefined;
    const wide = try toWide(&buf, value);
    const bytes = std.mem.sliceAsBytes(wide[0 .. wide.len + 1]);
    const set = win32.RegSetValueExW(key, name, 0, win32.REG_SZ, bytes.ptr, @intCast(bytes.len));
    if (set != 0) {
        log.warn("toast: RegSetValueExW failed err={d}", .{set});
        return error.ToastFailed;
    }
}

/// `text` in `buf` as UTF-16, terminated; ToastFailed if it does not fit.
/// utf8ToUtf16Le assumes room for the result, which takes at most as many
/// units as `text` has bytes.
fn toWide(buf: []u16, text: []const u8) ![:0]u16 {
    if (text.len >= buf.len) return error.ToastFailed;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return error.ToastFailed;
    buf[n] = 0;
    return buf[0..n :0];
}

/// What the runtime asks of the system's notifications, so that tests can
/// stand in for it; `Toasts` is the system's.
pub const Notifier = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Show `toast`; false, logged, if it could not be.
        show: *const fn (*anyopaque, Toast) bool,
        /// Remove one toast, shown or kept in the notification center.
        remove: *const fn (*anyopaque, group: u64, tag: u64) void,
        /// Remove every toast of a group.
        removeGroup: *const fn (*anyopaque, group: u64) void,
    };

    pub fn show(self: Notifier, toast: Toast) bool {
        return self.vtable.show(self.ptr, toast);
    }

    pub fn remove(self: Notifier, group: u64, tag: u64) void {
        self.vtable.remove(self.ptr, group, tag);
    }

    pub fn removeGroup(self: Notifier, group: u64) void {
        self.vtable.removeGroup(self.ptr, group);
    }
};

/// For tests: a stand-in for the system's notifications, which keeps what
/// was asked of it.
pub const TestNotifier = struct {
    shown: [8]Toast = undefined,
    shown_len: usize = 0,
    /// Fail the next `show`.
    fail: bool = false,
    /// Group and tag.
    removed: [8][2]u64 = undefined,
    removed_len: usize = 0,
    removed_groups: [8]u64 = undefined,
    removed_groups_len: usize = 0,

    pub fn notifier(self: *TestNotifier) Notifier {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Notifier.VTable = .{
        .show = show,
        .remove = remove,
        .removeGroup = removeGroup,
    };

    fn show(ptr: *anyopaque, t: Toast) bool {
        const self: *TestNotifier = @ptrCast(@alignCast(ptr));
        if (self.fail) {
            self.fail = false;
            return false;
        }
        self.shown[self.shown_len] = t;
        self.shown_len += 1;
        return true;
    }

    fn remove(ptr: *anyopaque, group: u64, tag: u64) void {
        const self: *TestNotifier = @ptrCast(@alignCast(ptr));
        self.removed[self.removed_len] = .{ group, tag };
        self.removed_len += 1;
    }

    fn removeGroup(ptr: *anyopaque, group: u64) void {
        const self: *TestNotifier = @ptrCast(@alignCast(ptr));
        self.removed_groups[self.removed_groups_len] = group;
        self.removed_groups_len += 1;
    }
};

/// The system's notifications for one app ID. Its methods run on the UI
/// thread, a single-threaded apartment (`App.init`).
pub const Toasts = struct {
    alloc: Allocator,
    app_id: String,
    notifier: *IToastNotifier,
    history: *IToastNotificationHistory,
    factory: *IToastNotificationFactory,
    /// Where a click is posted, as `message` (`Activated`).
    hwnd: HWND,
    message: u32,

    pub fn init(alloc: Allocator, id_utf8: []const u8, hwnd: HWND, message: u32) !Toasts {
        var buf: [256]u16 = undefined;
        const id = try String.init(try toWide(&buf, id_utf8));
        errdefer id.deinit();

        const statics = try factoryOf(IToastNotificationManagerStatics, "Windows.UI.Notifications.ToastNotificationManager");
        defer release(statics);
        var notifier_out: ?*IToastNotifier = null;
        try check(statics.vtable.CreateToastNotifierWithId(statics, id.handle, &notifier_out), "CreateToastNotifierWithId");
        const notifier = notifier_out orelse return error.ToastFailed;
        errdefer release(notifier);

        const statics2 = try query(statics, IToastNotificationManagerStatics2);
        defer release(statics2);
        var history_out: ?*IToastNotificationHistory = null;
        try check(statics2.vtable.get_History(statics2, &history_out), "get_History");
        const history = history_out orelse return error.ToastFailed;
        errdefer release(history);

        const factory = try factoryOf(IToastNotificationFactory, "Windows.UI.Notifications.ToastNotification");
        return .{
            .alloc = alloc,
            .app_id = id,
            .notifier = notifier,
            .history = history,
            .factory = factory,
            .hwnd = hwnd,
            .message = message,
        };
    }

    pub fn deinit(self: *Toasts) void {
        release(self.factory);
        release(self.history);
        release(self.notifier);
        self.app_id.deinit();
    }

    pub fn notifierOf(self: *Toasts) Notifier {
        return .{ .ptr = self, .vtable = &notifier_vtable };
    }

    const notifier_vtable: Notifier.VTable = .{
        .show = showOpaque,
        .remove = removeOpaque,
        .removeGroup = removeGroupOpaque,
    };

    fn showOpaque(ptr: *anyopaque, toast: Toast) bool {
        const self: *Toasts = @ptrCast(@alignCast(ptr));
        self.show(toast) catch |err| {
            log.warn("toast: not shown err={}", .{err});
            return false;
        };
        return true;
    }

    fn show(self: *Toasts, toast: Toast) !void {
        const xml = try toastXml(self.alloc, toast);
        defer self.alloc.free(xml);
        const content = try String.init(xml);
        defer content.deinit();

        const document = document: {
            const class = try String.init(std.unicode.utf8ToUtf16LeStringLiteral("Windows.Data.Xml.Dom.XmlDocument"));
            defer class.deinit();
            var out: ?*anyopaque = null;
            try check(win32.RoActivateInstance(class.handle, &out), "RoActivateInstance(XmlDocument)");
            break :document @as(*Object, @ptrCast(@alignCast(out orelse return error.ToastFailed)));
        };
        defer release(document);
        const io = try query(document, IXmlDocumentIO);
        defer release(io);
        try check(io.vtable.LoadXml(io, content.handle), "LoadXml");
        const xml_document = try query(document, IXmlDocument);
        defer release(xml_document);

        var notification: ?*IToastNotification = null;
        try check(self.factory.vtable.CreateToastNotification(
            self.factory,
            xml_document,
            &notification,
        ), "CreateToastNotification");
        const toast_notification = notification orelse return error.ToastFailed;
        defer release(toast_notification);

        const tagged = try query(toast_notification, IToastNotification2);
        defer release(tagged);
        const tag = try String.decimal(toast.tag);
        defer tag.deinit();
        const group = try String.decimal(toast.group);
        defer group.deinit();
        try check(tagged.vtable.put_Tag(tagged, tag.handle), "put_Tag");
        try check(tagged.vtable.put_Group(tagged, group.handle), "put_Group");

        const handler = try Activated.create(self.hwnd, self.message, toast.group);
        defer _ = Activated.releaseRef(handler);
        var token: EventToken = undefined;
        try check(toast_notification.vtable.add_Activated(toast_notification, handler, &token), "add_Activated");

        try check(self.notifier.vtable.Show(self.notifier, toast_notification), "Show");
    }

    fn removeOpaque(ptr: *anyopaque, group: u64, tag: u64) void {
        const self: *Toasts = @ptrCast(@alignCast(ptr));
        const t = String.decimal(tag) catch return;
        defer t.deinit();
        const g = String.decimal(group) catch return;
        defer g.deinit();
        check(self.history.vtable.RemoveGroupedTagWithId(self.history, t.handle, g.handle, self.app_id.handle), "RemoveGroupedTagWithId") catch {};
    }

    fn removeGroupOpaque(ptr: *anyopaque, group: u64) void {
        const self: *Toasts = @ptrCast(@alignCast(ptr));
        const g = String.decimal(group) catch return;
        defer g.deinit();
        check(self.history.vtable.RemoveGroupWithId(self.history, g.handle, self.app_id.handle), "RemoveGroupWithId") catch {};
    }
};

test "win32: the toast interfaces have the SDK's slots" {
    // The C vtables of the 10.0.28000.0 SDK headers, IInspectable's six
    // included (IUnknown's three for the handler).
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(6 * p, @sizeOf(Inspectable));
    try testing.expectEqual(9 * p, @sizeOf(IToastNotificationManagerStatics.VTable));
    try testing.expectEqual(7 * p, @sizeOf(IToastNotificationManagerStatics2.VTable));
    try testing.expectEqual(13 * p, @sizeOf(IToastNotificationHistory.VTable));
    try testing.expectEqual(12 * p, @sizeOf(IToastNotifier.VTable));
    try testing.expectEqual(7 * p, @sizeOf(IToastNotificationFactory.VTable));
    try testing.expectEqual(15 * p, @sizeOf(IToastNotification.VTable));
    try testing.expectEqual(12 * p, @sizeOf(IToastNotification2.VTable));
    try testing.expectEqual(9 * p, @sizeOf(IXmlDocumentIO.VTable));
    try testing.expectEqual(4 * p, @sizeOf(Activated.VTable));

    try testing.expectEqual(2 * p, @offsetOf(Inspectable, "Release"));
    try testing.expectEqual(7 * p, @offsetOf(IToastNotificationManagerStatics.VTable, "CreateToastNotifierWithId"));
    try testing.expectEqual(6 * p, @offsetOf(IToastNotificationManagerStatics2.VTable, "get_History"));
    try testing.expectEqual(7 * p, @offsetOf(IToastNotificationHistory.VTable, "RemoveGroupWithId"));
    try testing.expectEqual(8 * p, @offsetOf(IToastNotificationHistory.VTable, "RemoveGroupedTagWithId"));
    try testing.expectEqual(12 * p, @offsetOf(IToastNotificationHistory.VTable, "ClearWithId"));
    try testing.expectEqual(6 * p, @offsetOf(IToastNotifier.VTable, "Show"));
    try testing.expectEqual(6 * p, @offsetOf(IToastNotificationFactory.VTable, "CreateToastNotification"));
    try testing.expectEqual(11 * p, @offsetOf(IToastNotification.VTable, "add_Activated"));
    try testing.expectEqual(6 * p, @offsetOf(IToastNotification2.VTable, "put_Tag"));
    try testing.expectEqual(8 * p, @offsetOf(IToastNotification2.VTable, "put_Group"));
    try testing.expectEqual(6 * p, @offsetOf(IXmlDocumentIO.VTable, "LoadXml"));
    try testing.expectEqual(3 * p, @offsetOf(Activated.VTable, "Invoke"));
}

test "win32: the toast interfaces' ids" {
    const testing = std.testing;
    try testing.expectEqual(0x50ac103f, IToastNotificationManagerStatics.IID.Data1);
    try testing.expectEqual(0x47, IToastNotificationManagerStatics2.IID.Data4[7]);
    try testing.expectEqual(0x5caddc63, IToastNotificationHistory.IID.Data1);
    try testing.expectEqual(0xe7, IToastNotifier.IID.Data4[7]);
    try testing.expectEqual(0x04124b20, IToastNotificationFactory.IID.Data1);
    try testing.expectEqual(0x997e2675, IToastNotification.IID.Data1);
    try testing.expectEqual(0x9dfb9fd1, IToastNotification2.IID.Data1);
    try testing.expectEqual(0x6cd0e74e, IXmlDocumentIO.IID.Data1);
    try testing.expectEqual(0xf7f3a506, IXmlDocument.IID.Data1);
    try testing.expectEqual(0xab54de2d, Activated.IID.Data1);
    try testing.expectEqual(0x30, Activated.IID.Data4[7]);
    try testing.expectEqual(0x94ea2b94, win32.IID_IAgileObject.Data1);
}

test "win32: a toast's text is escaped and kept to what XML can hold" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    const xml = try toastXml(alloc, .{
        .title = "a <b> & \"c\"",
        .body = "it's\x07 done\r\n\tok\x1b[0m",
        .attribution = "vim",
        .group = 1,
        .tag = 2,
    });
    defer alloc.free(xml);
    try testing.expectEqualSlices(u16, L("<toast><visual><binding template=\"ToastGeneric\">" ++
        "<text>a &lt;b&gt; &amp; &quot;c&quot;</text>" ++
        "<text>it&apos;s done\r\n\tok[0m</text>" ++
        "<text placement=\"attribution\">vim</text>" ++
        "</binding></visual></toast>"), xml);

    // No title: Ghostty's name. No attribution, or an empty one: no line.
    // Invalid UTF-8, and the noncharacters XML has no place for: U+FFFD.
    const plain = try toastXml(alloc, .{
        .title = "",
        .body = "x\xe9 a\xef\xbf\xbeb a\xef\xbf\xbfb",
        .attribution = "",
        .group = 0,
        .tag = 1,
    });
    defer alloc.free(plain);
    try testing.expectEqualSlices(u16, L("<toast><visual><binding template=\"ToastGeneric\">" ++
        "<text>Ghostty</text><text>x\u{FFFD} a\u{FFFD}b a\u{FFFD}b</text>" ++
        "</binding></visual></toast>"), plain);
}

test "win32: text that does not fit a UTF-16 buffer is refused" {
    // One unit per ASCII byte, and the terminator.
    var buf: [8]u16 = undefined;
    try std.testing.expectError(error.ToastFailed, toWide(&buf, "abcdefgh"));
    const wide = try toWide(&buf, "abcdefg");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("abcdefg"), wide);
}

test "win32: the toast icon is where the build installs it" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Ghostty\\share\\icons\\hicolor\\256x256\\apps\\com.mitchellh.ghostty.png",
        iconPath(&buf, "C:\\Ghostty\\share\\ghostty").?,
    );
    // The resources directory may come with slashes.
    try testing.expectEqualStrings(
        "C:\\Ghostty\\share\\icons\\hicolor\\256x256\\apps\\com.mitchellh.ghostty.png",
        iconPath(&buf, "C:/Ghostty/share/ghostty").?,
    );
    try testing.expectEqual(null, iconPath(&buf, "ghostty"));
    var small: [16]u8 = undefined;
    try testing.expectEqual(null, iconPath(&small, "C:\\Ghostty\\share\\ghostty"));
}

test "win32: a toast's group gets through a message's two parameters" {
    for ([_]u64{ 0, 42, 0xdead_beef_0000_002a, std.math.maxInt(u64) }) |group| {
        const message = groupMessage(group);
        try std.testing.expectEqual(group, messageGroup(message[0], message[1]));
    }
}

test "win32: a toast's click handler counts references and posts its group" {
    const testing = std.testing;
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
    const message = win32.WM_APP + 0x101;

    const group: u64 = 0xdead_beef_0000_002a;
    const handler = try Activated.create(hwnd, message, group);
    var out: ?*anyopaque = null;
    try testing.expectEqual(win32.S_OK, handler.vtable.QueryInterface(handler, &Activated.IID, &out));
    try testing.expectEqual(@as(?*anyopaque, handler), out);
    try testing.expectEqual(win32.S_OK, handler.vtable.QueryInterface(handler, &win32.IID_IAgileObject, &out));
    try testing.expectEqual(3, handler.refs.load(.monotonic));
    // A delegate is no IInspectable.
    const iid_inspectable = GUID.parse("{af86e2e0-b12d-4c6a-9c5a-d7aa65101e90}");
    try testing.expectEqual(win32.E_NOINTERFACE, handler.vtable.QueryInterface(handler, &iid_inspectable, &out));
    try testing.expectEqual(null, out);
    try testing.expectEqual(2, handler.vtable.Release(handler));
    try testing.expectEqual(1, handler.vtable.Release(handler));

    try testing.expectEqual(win32.S_OK, handler.vtable.Invoke(handler, null, null));
    var msg: win32.MSG = undefined;
    try testing.expect(win32.PeekMessageW(&msg, hwnd, message, message, win32.PM_REMOVE).toBool());
    try testing.expectEqual(group, messageGroup(msg.wParam, msg.lParam));
    try testing.expectEqual(0, handler.vtable.Release(handler));
}
