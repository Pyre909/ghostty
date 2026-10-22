//! A terminal's progress report (ConEmu's OSC 9;4) on its window's taskbar
//! button, through ITaskbarList3, as Windows Terminal shows it. GTK and
//! macOS draw a bar over the terminal instead; Windows has a place for it
//! that a minimized window keeps showing.
//!
//! ITaskbarList3 is a vtable struct in the order of the mingw header Zig
//! ships (lib/libc/include/any-windows-any/shobjidl.h), as the renderer's
//! interfaces are (src/renderer/d3d11/api.zig): only the methods called
//! here are typed, every other slot is an untyped pointer, and the tests
//! check the slot count and the typed slots' indices against the header.
//! The object is made here too (`create`), with the call ITaskbarList3
//! asks for before any other.

const std = @import("std");
const windows = std.os.windows;

const terminal = @import("../../terminal/main.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const HRESULT = win32.HRESULT;
const HWND = windows.HWND;
const GUID = windows.GUID;

const CLSID_TaskbarList: GUID = GUID.parse("{56fdf344-fd6d-11d0-958a-006097c9a090}");
const IID_ITaskbarList3: GUID = GUID.parse("{ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf}");

fn check(hr: HRESULT, what: []const u8) error{TaskbarListFailed}!void {
    if (hr >= 0) return;
    log.warn("taskbar: {s} failed hr=0x{x}", .{ what, @as(u32, @bitCast(hr)) });
    return error.TaskbarListFailed;
}

/// The taskbar buttons' progress bars, one reference, the caller's; on the
/// thread that uses it, which must be in an apartment (CoInitializeEx).
pub fn create() error{TaskbarListFailed}!*ITaskbarList3 {
    var out: ?*anyopaque = null;
    try check(win32.CoCreateInstance(
        &CLSID_TaskbarList,
        null,
        win32.CLSCTX_INPROC_SERVER,
        &IID_ITaskbarList3,
        &out,
    ), "CoCreateInstance");
    const list: *ITaskbarList3 = @ptrCast(@alignCast(out orelse return error.TaskbarListFailed));
    errdefer list.release();
    try check(list.vtable.HrInit(list), "HrInit");
    return list;
}

/// TBPFLAG: what the button's bar shows.
pub const State = enum(c_int) {
    /// No bar.
    none = 0x0,
    /// A bar that cycles, for progress of no known amount.
    indeterminate = 0x1,
    /// Green, filled to the value.
    normal = 0x2,
    /// Red, filled to the value.
    @"error" = 0x4,
    /// Yellow, filled to the value.
    paused = 0x8,

    /// Whether the bar is filled to a value (SetProgressValue).
    pub fn filled(self: State) bool {
        return switch (self) {
            .normal, .@"error", .paused => true,
            .none, .indeterminate => false,
        };
    }
};

/// An untyped vtable slot, there so that the slots after it keep their
/// index.
const Slot = *const anyopaque;

pub const ITaskbarList3 = extern struct {
    vtable: *const VTable,

    pub const IID = IID_ITaskbarList3;

    /// IUnknown, ITaskbarList, ITaskbarList2 and ITaskbarList3, flattened.
    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*ITaskbarList3) callconv(.winapi) windows.ULONG,
        HrInit: *const fn (*ITaskbarList3) callconv(.winapi) HRESULT,
        AddTab: Slot,
        DeleteTab: Slot,
        ActivateTab: Slot,
        SetActiveAlt: Slot,
        MarkFullscreenWindow: Slot,
        SetProgressValue: *const fn (*ITaskbarList3, HWND, windows.ULONGLONG, windows.ULONGLONG) callconv(.winapi) HRESULT,
        SetProgressState: *const fn (*ITaskbarList3, HWND, State) callconv(.winapi) HRESULT,
        RegisterTab: Slot,
        UnregisterTab: Slot,
        SetTabOrder: Slot,
        SetTabActive: Slot,
        ThumbBarAddButtons: Slot,
        ThumbBarUpdateButtons: Slot,
        ThumbBarSetImageList: Slot,
        SetOverlayIcon: Slot,
        SetThumbnailTooltip: Slot,
        SetThumbnailClip: Slot,
    };

    pub fn release(self: *ITaskbarList3) void {
        _ = self.vtable.Release(self);
    }

    /// Show `progress` on the button of the top-level window `hwnd`. The
    /// state goes first: a value set in no state, or the indeterminate one,
    /// would make it the normal one. The indeterminate state comes after
    /// none, as Windows Terminal sets it (IslandWindow::SetTaskbarProgress):
    /// from an error or a pause the button would otherwise keep their bar
    /// and show no cycling one.
    pub fn show(self: *ITaskbarList3, hwnd: HWND, progress: Progress) void {
        log.debug("taskbar progress state={s} value={d}", .{ @tagName(progress.state), progress.shownValue() });
        if (progress.state == .indeterminate) {
            check(self.vtable.SetProgressState(self, hwnd, .none), "SetProgressState") catch {};
        }
        check(self.vtable.SetProgressState(self, hwnd, progress.state), "SetProgressState") catch {};
        if (!progress.state.filled()) return;
        check(self.vtable.SetProgressValue(self, hwnd, progress.shownValue(), 100), "SetProgressValue") catch {};
    }
};

/// A terminal's progress, as its reports leave it (`update`).
pub const Progress = struct {
    state: State = .none,

    /// Out of 100, the last a report gave, kept for a later one with
    /// none; null before any or after a removal.
    value: ?u8 = null,

    /// Take a report as GTK and macOS do: a set one with no value is
    /// progress of no known amount, and the error and paused states, which
    /// the bar shows only filled, keep the value they had. A report that
    /// never had one shows them full, so that they show at all.
    pub fn update(self: *Progress, report: terminal.osc.Command.ProgressReport) void {
        if (report.progress) |p| self.value = @min(p, 100);
        self.state = switch (report.state) {
            .remove => .none,
            .set => if (report.progress != null) .normal else .indeterminate,
            .@"error" => .@"error",
            .indeterminate => .indeterminate,
            .pause => .paused,
        };
        if (self.state == .none) self.value = null;
    }

    /// The value the bar is filled to, out of 100.
    pub fn shownValue(self: Progress) u8 {
        return self.value orelse 100;
    }
};

test "win32: ITaskbarList3 has the header's slots" {
    // ITaskbarList3Vtbl in shobjidl.h: IUnknown's 3, ITaskbarList's 5,
    // ITaskbarList2's 1 and its own 12.
    const testing = std.testing;
    const p = @sizeOf(usize);
    try testing.expectEqual(21 * p, @sizeOf(ITaskbarList3.VTable));
    try testing.expectEqual(2 * p, @offsetOf(ITaskbarList3.VTable, "Release"));
    try testing.expectEqual(3 * p, @offsetOf(ITaskbarList3.VTable, "HrInit"));
    try testing.expectEqual(9 * p, @offsetOf(ITaskbarList3.VTable, "SetProgressValue"));
    try testing.expectEqual(10 * p, @offsetOf(ITaskbarList3.VTable, "SetProgressState"));
}

test "win32: the taskbar's class and interface ids" {
    const testing = std.testing;
    try testing.expectEqual(0x56fdf344, CLSID_TaskbarList.Data1);
    try testing.expectEqual(0x90, CLSID_TaskbarList.Data4[7]);
    try testing.expectEqual(0xea1afb91, IID_ITaskbarList3.Data1);
    try testing.expectEqual(0xaf, IID_ITaskbarList3.Data4[7]);
}

test "win32: a terminal's progress follows its reports" {
    const testing = std.testing;
    var p: Progress = .{};

    // A value, then progress of no known amount, which keeps it.
    p.update(.{ .state = .set, .progress = 40 });
    try testing.expectEqual(Progress{ .state = .normal, .value = 40 }, p);
    p.update(.{ .state = .set });
    try testing.expectEqual(Progress{ .state = .indeterminate, .value = 40 }, p);
    p.update(.{ .state = .indeterminate });
    try testing.expectEqual(Progress{ .state = .indeterminate, .value = 40 }, p);

    // An error or a pause with no value keeps the last one.
    p.update(.{ .state = .@"error" });
    try testing.expectEqual(Progress{ .state = .@"error", .value = 40 }, p);
    p.update(.{ .state = .pause, .progress = 70 });
    try testing.expectEqual(Progress{ .state = .paused, .value = 70 }, p);
    try testing.expectEqual(70, p.shownValue());

    // Removed, then an error that never had a value: shown full.
    p.update(.{ .state = .remove });
    try testing.expectEqual(Progress{}, p);
    p.update(.{ .state = .@"error" });
    try testing.expectEqual(Progress{ .state = .@"error", .value = null }, p);
    try testing.expectEqual(100, p.shownValue());

    // The parser clamps the value; this does too.
    p.update(.{ .state = .set, .progress = 250 });
    try testing.expectEqual(100, p.value.?);
}
