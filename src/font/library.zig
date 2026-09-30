//! A library represents the shared state that the underlying font
//! library implementation(s) require per-process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("main.zig").options;
const freetype = @import("freetype");
const font = @import("main.zig");
const directwrite = @import("directwrite/main.zig");

/// Library implementation for the compile options.
pub const Library = switch (options.backend) {
    // Freetype requires a state library
    .freetype,
    .freetype_windows,
    .directwrite_freetype,
    .fontconfig_freetype,
    .coretext_freetype,
    => FreetypeLibrary,

    // DirectWrite keeps a factory for the process
    .directwrite => DirectWriteLibrary,

    // Some backends such as CT and Canvas don't have a "library"
    .coretext,
    .coretext_harfbuzz,
    .coretext_noshape,
    .web_canvas,
    => NoopLibrary,
};

pub const FreetypeLibrary = struct {
    lib: freetype.Library,

    alloc: Allocator,

    /// Mutex to be held any time the library is
    /// being used to create or destroy a face.
    mutex: *std.Io.Mutex,

    /// The process's DirectWrite state, for the backends that discover
    /// fonts with it. Borrowed: it belongs to the process.
    dwrite: if (options.backend.hasDirectWrite()) *directwrite.Shared else void,

    pub const InitError = freetype.Error || Allocator.Error ||
        if (options.backend.hasDirectWrite()) directwrite.Error else error{};

    pub fn init(alloc: Allocator) InitError!Library {
        const lib = try freetype.Library.init();
        errdefer lib.deinit();

        const dwrite = if (comptime options.backend.hasDirectWrite())
            try directwrite.Shared.get()
        else {};

        const mutex = try alloc.create(std.Io.Mutex);
        mutex.* = .init;

        return Library{
            .lib = lib,
            .alloc = alloc,
            .mutex = mutex,
            .dwrite = dwrite,
        };
    }

    pub fn deinit(self: *Library) void {
        self.alloc.destroy(self.mutex);
        self.lib.deinit();
    }
};

pub const DirectWriteLibrary = struct {
    /// The process's DirectWrite state. Borrowed: it belongs to the
    /// process.
    dwrite: *directwrite.Shared,

    pub const InitError = directwrite.Error;

    pub fn init(alloc: Allocator) InitError!Library {
        _ = alloc;
        return .{ .dwrite = try directwrite.Shared.get() };
    }

    pub fn deinit(self: *Library) void {
        _ = self;
    }
};

pub const NoopLibrary = struct {
    pub const InitError = error{};

    pub fn init(alloc: Allocator) InitError!Library {
        _ = alloc;
        return Library{};
    }

    pub fn deinit(self: *Library) void {
        _ = self;
    }
};
