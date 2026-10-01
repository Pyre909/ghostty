//! The Direct3D 11 render device of the app.
//!
//! Metal and OpenGL keep here the state that the renderers of every
//! surface share: the MTLDevice, the EGL display and config. Direct3D 11
//! keeps nothing here. Its device and immediate context are the
//! renderer's, one per surface: the immediate context is not safe to use
//! from two threads, and a device that is lost is replaced by the renderer
//! that lost it together with everything it created on it, see
//! `D3D11.recoverDevice`. Sharing one device between surfaces would need
//! deferred contexts and a recovery that reaches every surface, which is
//! a change of its own.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn init(self: *Device, alloc: Allocator) !void {
    _ = alloc;
    self.* = .{};
}

pub fn deinit(self: *Device) void {
    self.* = undefined;
}
