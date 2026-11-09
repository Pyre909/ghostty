//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const builtin = @import("builtin");
const dir = @import("dir.zig");
const sentry_envelope = @import("sentry_envelope.zig");

pub const sentry = @import("sentry.zig");

/// The Windows app's own minidumps, since Sentry does not build there.
pub const windows = if (builtin.os.tag == .windows) @import("windows.zig") else struct {};
pub const Envelope = sentry_envelope.Envelope;
pub const defaultDir = dir.defaultDir;
pub const Dir = dir.Dir;
pub const ReportIterator = dir.ReportIterator;
pub const Report = dir.Report;

// The main init/deinit functions for global state.
pub const init = sentry.init;
pub const deinit = sentry.deinit;

test {
    @import("std").testing.refAllDecls(@This());
}
