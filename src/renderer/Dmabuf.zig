//! A DMABUF frame produced by exporting a GPU texture.
//! This may be used on apprts like GTK that require us to manually
//! export each frame and import them as textures in their UI scene graphs.
//!
//! Note that DMABUFs are independent of the graphics API used:
//! the OpenGL renderer allocates them with GBM, and Vulkan can
//! export them with a KHR external memory implementation. Therefore
//! this struct has to be placed parallel to the renderer
//! implementations.
pub const Dmabuf = @This();
pub const std = @import("std");
const builtin = @import("builtin");

/// The maximum number of planes in a DMABUF that we support.
/// This matches the maximum found in apprts such as GTK.
pub const max_planes = 4;

/// Width of the texture in device pixels.
width: u32,

/// Height of the texture in device pixels.
height: u32,

/// DRM fourcc of the pixel format.
/// Ghostty renders RGBA/BGRA8 premultiplied.
fourcc: u32,

/// DRM modifier of the format.
modifier: u64,

/// Whether the data is premultiplied.
/// Ghostty's GL renderers output premultiplied alpha.
premultiplied: bool,

/// The DMABUF planes for a presented frame. The DMABUF owns the fds
/// and must either call `deinit` manually, or pass them to an apprt
/// that consumes them.
planes: Planes,

pub const Planes = struct {
    /// Number of planes. Valid planes are `planes[0..count]`.
    count: u8,

    /// File descriptor for each plane.
    fds: [max_planes]c_int = @splat(-1),

    /// Offset into the DMABUF where each plane starts, in bytes.
    offsets: [max_planes]c_int = @splat(0),

    /// Strides of each plane, in bytes.
    strides: [max_planes]c_int = @splat(0),

    /// Close all valid fds.
    pub fn deinit(self: Planes) void {
        // DMABUF fds are POSIX file descriptors (Linux, and the BSDs
        // via drm-kmod). Windows has no DMABUF, so nothing is exported
        // and there is nothing to close.
        if (comptime builtin.os.tag == .windows) return;
        for (self.fds[0..self.count]) |fd| {
            if (fd >= 0) _ = std.posix.system.close(fd);
        }
    }

    /// Validate the current planes. If any plane failed to export
    /// and has an invalid FD, we close all the known valid FDs
    /// and bail.
    pub fn validate(self: Planes) error{BadDmabuf}!void {
        if (comptime builtin.os.tag == .windows) return;
        var n_valid: usize = 0;
        while (n_valid < self.count) : (n_valid += 1) {
            if (self.fds[n_valid] < 0) {
                for (self.fds[0..n_valid]) |bad| _ = std.posix.system.close(bad);
                return error.BadDmabuf;
            }
        }
    }
};

pub fn deinit(self: Dmabuf) void {
    self.planes.deinit();
}

/// Whether `fd` is still open in this process.
fn testIsOpen(fd: c_int) bool {
    const posix = std.posix;
    return posix.errno(posix.system.fcntl(fd, posix.F.GETFD)) != .BADF;
}

test "Planes.validate closes valid fds when a plane failed" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const posix = std.posix;

    var fds: [2]c_int = undefined;
    try testing.expectEqual(.SUCCESS, posix.errno(posix.system.pipe(&fds)));

    // The third plane failed to export, so validate owns and closes
    // the fds of the planes before it.
    var planes: Planes = .{ .count = 3 };
    planes.fds[0] = fds[0];
    planes.fds[1] = fds[1];
    try testing.expectError(error.BadDmabuf, planes.validate());
    try testing.expect(!testIsOpen(fds[0]));
    try testing.expect(!testIsOpen(fds[1]));
}

test "Planes.deinit closes all fds" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const posix = std.posix;

    var fds: [2]c_int = undefined;
    try testing.expectEqual(.SUCCESS, posix.errno(posix.system.pipe(&fds)));

    var planes: Planes = .{ .count = 2 };
    planes.fds[0] = fds[0];
    planes.fds[1] = fds[1];
    try planes.validate();
    planes.deinit();
    try testing.expect(!testIsOpen(fds[0]));
    try testing.expect(!testIsOpen(fds[1]));
}
