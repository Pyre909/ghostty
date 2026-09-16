//! WGL (Win32) context handling and presentation for the OpenGL renderer.
//!
//! This is the Windows replacement for the EGL/dma-buf half of `OpenGL.zig`.
//! It is only ever analysed when `OpenGL.wgl_enabled` is true (the Win32
//! apprt); every reference to it from shared code sits in a comptime branch.
//!
//! Ownership: the apprt (src/apprt/windows.zig) creates the pixel format and
//! the 4.3 core context on its own CS_OWNDC window and deletes the context
//! after the render thread has been joined. The renderer only *borrows* the
//! three handles. The context is current on at most one thread at a time:
//!
//!   main thread    `State.init` probe: make current, validate, release
//!   render thread  `threadEnter` .. `threadExit`: all GL work, SwapBuffers
//!   main thread    apprt `releaseContext`: wglDeleteContext
//!
//! MSDN: a context that is current on another thread can be neither made
//! current nor deleted, so each hand-off happens only after the previous
//! owner released it.
//!
//! This file deliberately does not import `OpenGL.zig` (the version check
//! and `prepareContext` stay there) and does not import the apprt: its Win32
//! declarations are its own, copied with types identical to the ones in
//! src/apprt/windows.zig. Zig accepts the duplicated `extern` declarations.
const std = @import("std");
const builtin = @import("builtin");
const gl = @import("opengl");
const Target = @import("Target.zig");

const log = std.log.scoped(.wgl);

// -------------------------------------------------------------------------
// Win32 / WGL bindings
//
// Types come from std.os.windows exactly as src/apprt/windows.zig aliases
// them. That matters for the handle types: std declares HDC/HGLRC/HWND as
// `*opaque {}`, each a distinct nominal type, so only the std aliases are
// interchangeable with the apprt's `?win32.HDC` fields that `State.init`
// copies.
// -------------------------------------------------------------------------
const win32 = struct {
    const w = std.os.windows;

    const BOOL = w.BOOL;
    const LONG = w.LONG;
    const LPCWSTR = w.LPCWSTR;
    const HWND = w.HWND;
    const HDC = w.HDC;
    const HGLRC = w.HGLRC;
    const HINSTANCE = w.HINSTANCE;

    const RECT = extern struct {
        left: LONG,
        top: LONG,
        right: LONG,
        bottom: LONG,
    };

    /// WGL_EXT_swap_control. Resolved through wglGetProcAddress, never
    /// statically imported: it is an ICD extension, not an opengl32 export.
    const SwapIntervalFn = *const fn (interval: c_int) callconv(.winapi) BOOL;

    extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
    extern "kernel32" fn GetProcAddress(
        module: HINSTANCE,
        name: [*:0]const u8,
    ) callconv(.winapi) ?*const anyopaque;

    extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;

    extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

    extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, ctx: ?HGLRC) callconv(.winapi) BOOL;
    extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
};

/// The function-pointer type glad's loader callback returns
/// (`GLADapiproc`, gl.h:170). It is only a transport type: glad casts every
/// entry to its own `GLAD_API_PTR`-typed prototype before calling it, so the
/// calling convention written here never reaches a call site.
const GlProc = *const fn () callconv(.c) void;

/// The client-area background the window shows before the first real
/// frame, and the colour the Debug readback check compares against.
pub const InitOptions = struct {
    /// `config.background`, sRGB-encoded bytes.
    background: [3]u8,
    /// `config.background_opacity`, already clamped to 0..1.
    background_opacity: f64,
    /// `config.blending.isLinear()`: whether the shaders premultiply in
    /// linear space (common.glsl `load_color`).
    linear_blending: bool,
    /// Minimum GL version the renderer requires (OpenGL.MIN_VERSION_*).
    min_major: c_uint,
    min_minor: c_uint,
};

pub const InitError = error{
    WglContextMissing,
    WglMakeCurrentFailed,
    WglGlLoadFailed,
    OpenGLOutdated,
    WglMissingFunctions,
};

pub const State = struct {
    hwnd: win32.HWND,

    /// The window's CS_OWNDC device context (windows.zig `Surface.create`):
    /// one DC for the window's lifetime, never released. The render thread
    /// makes the context current on this same DC, which trivially satisfies
    /// wglMakeCurrent's "same device, same pixel format" rule.
    hdc: win32.HDC,
    hglrc: win32.HGLRC,

    /// Initial clear colour for FB0, already in the encoding FB0 stores
    /// (sRGB bytes / 255, premultiplied as the bg shader would).
    clear_color: [4]f32,

    /// Unpremultiplied config background, for the Debug readback log.
    background: [3]u8,
    background_opacity: f64,

    /// Sticky: set when CopyImageSubData failed once. From then on every
    /// present blits the sRGB FBO straight to FB0 (see `present`).
    fallback_blit: bool = false,

    /// Debug-log counters. Only the render thread touches these.
    present_count: u64 = 0,
    dropped_stale_count: u64 = 0,

    /// Debug builds: the one-shot readback check has run (`checkReadback`).
    readback_checked: bool = false,

    /// Main thread, from `OpenGL.init` inside `CoreSurface.init`.
    ///
    /// Copies the handles, then proves on this thread that everything
    /// `threadEnter` will need works, so a broken context fails
    /// `CoreSurface.init` visibly. A failure only on the render thread would
    /// be worse than a blank window: `renderer.Thread` never starts its loop,
    /// its 64-slot mailbox is never drained, and the main thread's `.forever`
    /// pushes (resize, focus, visibility) eventually block it for good.
    ///
    /// Probe order: make current -> reset glad -> load glad -> GL version ->
    /// required entry points -> unload -> reset glad -> release. The context
    /// is not current anywhere when this returns, success or not.
    pub fn init(surface: anytype, opts: InitOptions) InitError!State {
        const hdc: win32.HDC = surface.hdc orelse {
            log.err("surface has no device context", .{});
            return error.WglContextMissing;
        };
        const hglrc: win32.HGLRC = surface.hglrc orelse {
            log.err("surface has no GL context", .{});
            return error.WglContextMissing;
        };

        const self: State = .{
            .hwnd = surface.hwnd,
            .hdc = hdc,
            .hglrc = hglrc,
            .clear_color = clearColor(opts),
            .background = opts.background,
            .background_opacity = opts.background_opacity,
        };

        try self.makeCurrent();
        defer releaseCurrent();

        // glad's context is threadlocal and this thread never loaded one;
        // start from zeroes so `unload` below sees a NULL loader handle.
        resetGladContext();
        defer resetGladContext();

        const version = gl.glad.load(&getProcAddress) catch |err| {
            log.err("glad failed to load through WGL err={}", .{err});
            return error.WglGlLoadFailed;
        };
        defer gl.glad.unload();

        const major = gl.glad.versionMajor(@intCast(version));
        const minor = gl.glad.versionMinor(@intCast(version));
        const c = &gl.glad.context;
        log.info("WGL probe: OpenGL {d}.{d} vendor={s} renderer={s} version={s}", .{
            major,
            minor,
            glString(c.GetString.?(gl.c.GL_VENDOR)),
            glString(c.GetString.?(gl.c.GL_RENDERER)),
            glString(c.GetString.?(gl.c.GL_VERSION)),
        });

        if (major < opts.min_major or
            (major == opts.min_major and minor < opts.min_minor))
        {
            log.err(
                "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
                .{ opts.min_major, opts.min_minor },
            );
            return error.OpenGLOutdated;
        }

        // A 4.3 context can still hand back NULL for a 4.3 entry point if the
        // ICD does not export it; glad stores the NULL and the renderer's
        // `.?` would then panic on the render thread. Check the ones that
        // are not exercised by glad itself: the present path's two
        // (`present`) and prepareContext's debug callback.
        var missing = false;
        inline for (.{ "CopyImageSubData", "BlitFramebuffer", "DebugMessageCallback" }) |name| {
            if (@field(c, name) == null) {
                log.err("required GL entry point missing: gl{s}", .{name});
                missing = true;
            }
        }
        if (missing) return error.WglMissingFunctions;

        return self;
    }

    /// Make this context current on the calling thread.
    pub fn makeCurrent(self: *const State) error{WglMakeCurrentFailed}!void {
        if (!win32.wglMakeCurrent(self.hdc, self.hglrc).toBool()) {
            log.err("wglMakeCurrent failed hwnd={x} err={}", .{
                @intFromPtr(self.hwnd),
                std.os.windows.GetLastError(),
            });
            return error.WglMakeCurrentFailed;
        }
    }

    /// Release whatever context is current on the calling thread.
    pub fn releaseCurrent() void {
        _ = win32.wglMakeCurrent(null, null);
    }

    /// R-A5: clear FB0 to the background and present it once, so the window
    /// does not show uninitialised pixels before the first real frame.
    /// Nothing else paints it: the apprt's WM_ERASEBKGND returns 1 and its
    /// WM_PAINT no longer touches GL. Render thread, context current.
    ///
    /// Best-effort only. This runs from the render thread's threadEnter,
    /// which starts inside CoreSurface.init -- usually before the apprt's
    /// ShowWindow (apprt/windows.zig `Surface.create`) -- so the swap often
    /// targets a hidden window and the compositor may drop it. What reliably
    /// fills the window is the first real frame, which the first WM_PAINT's
    /// refresh requests right after the window is shown.
    pub fn clearAndPresent(self: *State) void {
        defer drainErrors();

        // FRAMEBUFFER_SRGB was enabled by prepareContext; the clear value is
        // already encoded, so make sure an sRGB-capable FB0 does not encode
        // it again.
        gl.disable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
            log.warn("initial clear: disabling FRAMEBUFFER_SRGB failed err={}", .{err});
        };
        defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
            log.err("initial clear: re-enabling FRAMEBUFFER_SRGB failed err={}", .{err});
        };

        const fb0: gl.Framebuffer = .{ .id = 0 };
        const bind = fb0.bind(.framebuffer) catch |err| {
            log.warn("initial clear: binding FB0 failed err={}", .{err});
            return;
        };
        defer bind.unbind();

        const col = self.clear_color;
        gl.clearColor(col[0], col[1], col[2], col[3]);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);

        if (!win32.SwapBuffers(self.hdc).toBool()) {
            log.warn("initial clear: SwapBuffers failed hwnd={x} err={}", .{
                @intFromPtr(self.hwnd),
                std.os.windows.GetLastError(),
            });
        }
    }

    /// Present a finished render target to the window. Render thread,
    /// context current. Called from `opengl/Frame.zig` `complete`, which
    /// already consumed any GL error raised while rendering.
    ///
    /// Two hops, both colour-exact:
    ///   1. CopyImageSubData `target.texture` (SRGB8_ALPHA8) ->
    ///      `target.export_texture` (RGBA8). A raw texel copy; the formats are
    ///      compatible (both VIEW_CLASS_32_BITS, ARB_copy_image).
    ///   2. Blit `export_framebuffer` -> FB0 with FRAMEBUFFER_SRGB disabled.
    ///      Linear to linear, so no encode/decode rule applies.
    ///
    /// A single sRGB-FBO -> FB0 blit would be cheaper, but whether a blit
    /// decodes an sRGB *read* buffer while FRAMEBUFFER_SRGB is disabled is
    /// spec-revision dependent (4.4+ makes it conditional on the flag; this
    /// is a 4.3 context on a translation layer). If the copy fails, the
    /// direct blit is used from then on (sticky) and the choice is logged.
    ///
    /// No Y flip: the FBO and FB0 are both bottom-up. The only existing flip
    /// (Target.exportDmabuf) exists for GDK's top-down textures.
    pub fn present(self: *State, target: Target) !void {
        // Drop frames rendered at a stale size, as Metal does
        // (IOSurfaceLayer.zig). During a drag the client rect runs ahead of
        // the renderer's `.resize` mailbox; stretching the old frame onto
        // the new FB0 would show a smeared grid for a frame. The WM_SIZE that
        // made the sizes differ already queued a `.resize` plus a wakeup, so
        // a matching frame always follows.
        //
        // GetClientRect only reads window state and sends no message, so it
        // is safe from this thread even while the main thread sits in a
        // modal size loop. If it fails, present anyway.
        var rc: win32.RECT = undefined;
        if (win32.GetClientRect(self.hwnd, &rc).toBool()) {
            const cw: i64 = rc.right - rc.left;
            const ch: i64 = rc.bottom - rc.top;
            if (cw != @as(i64, @intCast(target.width)) or
                ch != @as(i64, @intCast(target.height)))
            {
                self.dropped_stale_count += 1;
                log.debug(
                    "present hwnd={x}: dropped stale {d}x{d} frame, client is {d}x{d} (dropped={d})",
                    .{
                        @intFromPtr(self.hwnd),
                        target.width,
                        target.height,
                        cw,
                        ch,
                        self.dropped_stale_count,
                    },
                );
                return;
            }
        }

        // Nothing raised below may leak into the next frame's health check
        // (Frame.complete reads glGetError before rendering is judged).
        // Declared first so it runs last, after FRAMEBUFFER_SRGB is back on.
        defer drainErrors();

        self.present_count += 1;
        const w: c_int = @intCast(target.width);
        const h: c_int = @intCast(target.height);

        {
            // Precedent: Target.exportDmabuf disables it around its blit for
            // the same reason. Disabling also covers an FB0 that happens to
            // be sRGB-capable (the pixel format does not ask either way).
            try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
            defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
                log.err("re-enabling FRAMEBUFFER_SRGB failed err={}", .{err});
            };

            const read_fb: gl.Framebuffer = if (self.fallback_blit)
                target.framebuffer
            else copy: {
                gl.copyImageSubData(
                    target.texture,
                    .@"2d",
                    0,
                    0,
                    0,
                    0,
                    target.export_texture,
                    .@"2d",
                    0,
                    0,
                    0,
                    0,
                    w,
                    h,
                    1,
                ) catch |err| {
                    // getError reports one flag per call; clear the rest so
                    // the blit below is judged on its own.
                    drainErrors();
                    self.fallback_blit = true;
                    log.warn(
                        "CopyImageSubData failed err={}; hwnd={x} now presents with a direct sRGB blit",
                        .{ err, @intFromPtr(self.hwnd) },
                    );
                    break :copy target.framebuffer;
                };
                break :copy target.export_framebuffer;
            };
            const path: []const u8 = if (self.fallback_blit) "direct-srgb-blit" else "copy+blit";

            if (self.present_count == 1) {
                log.info("first present hwnd={x} {d}x{d} path={s}", .{
                    @intFromPtr(self.hwnd),
                    w,
                    h,
                    path,
                });
            }

            const read_bind = try read_fb.bind(.read);
            defer read_bind.unbind();

            // Framebuffer.bind queries the previous binding at runtime, so
            // the default framebuffer is named here by its WGL id, 0.
            const fb0: gl.Framebuffer = .{ .id = 0 };
            const draw_bind = try fb0.bind(.draw);
            defer draw_bind.unbind();

            try gl.blitFramebuffer(
                0,
                0,
                w,
                h,
                0,
                0,
                w,
                h,
                .{ .color_buffer_bit = true },
                .nearest,
            );

            // Must run after the blit and before SwapBuffers: after the swap
            // the back buffer's contents are undefined.
            if (comptime builtin.mode == .Debug) {
                if (!self.readback_checked) {
                    self.readback_checked = true;
                    self.checkReadback(target, path);
                }
            }

            log.debug("present #{d} hwnd={x} {d}x{d} path={s} dropped_stale={d}", .{
                self.present_count,
                @intFromPtr(self.hwnd),
                w,
                h,
                path,
                self.dropped_stale_count,
            });
        }

        if (!win32.SwapBuffers(self.hdc).toBool()) {
            log.warn("SwapBuffers failed hwnd={x} err={}", .{
                @intFromPtr(self.hwnd),
                std.os.windows.GetLastError(),
            });
            return error.WglSwapBuffersFailed;
        }
    }

    /// Debug-only, once per surface (verification step V5 / R-A6): compare
    /// the bottom-left pixel of the rendered sRGB target with the same pixel
    /// of FB0's back buffer. They must be byte-identical, or the present path
    /// converted colour somewhere. Both are also compared, +-1, with the
    /// configured background. That second comparison is only meaningful
    /// when the corner is background (window padding, no background image)
    /// and opacity is 1, so a mismatch there is logged at info, not warn.
    ///
    /// FRAMEBUFFER_SRGB is disabled by the caller, so ReadPixels returns the
    /// stored bytes of the sRGB target without decoding them. Never fails
    /// the present.
    fn checkReadback(self: *const State, target: Target, path: []const u8) void {
        var rendered: [4]u8 = undefined;
        var shown: [4]u8 = undefined;
        readPixel(target.framebuffer, &rendered, false) catch |err| {
            log.warn("readback check: reading the render target failed err={}", .{err});
            return;
        };
        readPixel(.{ .id = 0 }, &shown, true) catch |err| {
            log.warn("readback check: reading FB0 failed err={}", .{err});
            return;
        };

        if (std.mem.eql(u8, &rendered, &shown)) {
            log.info("readback check ok path={s}: target={any} fb0={any}", .{ path, rendered, shown });
        } else {
            log.warn("readback check MISMATCH path={s}: target={any} fb0={any}", .{ path, rendered, shown });
        }

        if (self.background_opacity < 1.0) {
            log.info("readback check: background opacity < 1, config comparison skipped", .{});
            return;
        }

        // Compare against the bytes the shader is expected to store for the
        // configured background (`clearColor`), not the configured bytes
        // themselves: under native blending those differ by an sRGB encode.
        var expected: [3]u8 = undefined;
        for (&expected, self.clear_color[0..3]) |*e, v| {
            e.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
        }
        const close = for (0..3) |i| {
            const d = @as(i16, shown[i]) - @as(i16, expected[i]);
            if (d > 1 or d < -1) break false;
        } else true;
        log.info("readback check: fb0 {s} expected background {any} (config {any})", .{
            if (close) "matches" else "differs from (corner may not be background)",
            expected,
            self.background,
        });
    }
};

/// Read one RGBA8 pixel at (0, 0) from `fb`. `back` selects GL_BACK, which
/// is only valid for the default framebuffer; an FBO reads COLOR_ATTACHMENT0
/// by default. The read-buffer setting is per-framebuffer state and GL_BACK
/// is already FB0's default for a double-buffered format, so it is not
/// restored.
fn readPixel(fb: gl.Framebuffer, out: *[4]u8, back: bool) !void {
    const bind = try fb.bind(.read);
    defer bind.unbind();
    if (back) {
        gl.glad.context.ReadBuffer.?(gl.c.GL_BACK);
        try gl.errors.getError();
    }
    try gl.readPixels(0, 0, 1, 1, .rgba, .unsigned_byte, out);
}

/// Resolve a GL/WGL entry point for glad (`gl.glad.load`). The signature
/// matches glad.zig's `GlfwFn` arm exactly, which calls `gladLoadGLContext`.
///
/// Two sources, because Windows splits them:
///   - GL 1.2+ and extensions exist only through `wglGetProcAddress`, and
///     only while a context is current.
///   - GL 1.0/1.1 exist only as opengl32.dll exports; wglGetProcAddress
///     reports them as failures.
///
/// glad's own Windows loader (`load(null)`) is not usable: it falls back to
/// GetProcAddress only on NULL (gl.c `glad_gl_get_proc`), but
/// wglGetProcAddress also reports failure as 1, 2, 3 and -1, which glad would
/// store as function pointers and later call.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?GlProc {
    if (wglProc(name)) |p| return @ptrCast(@alignCast(p));

    // opengl32 stays resident for the whole process: it is import-linked
    // (SharedDeps.zig addWin32) and LoadLibraryW'd by App.init.
    const gl32 = win32.GetModuleHandleW(
        std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"),
    ) orelse return null;
    const p = win32.GetProcAddress(gl32, name) orelse return null;

    // @alignCast is load-bearing on AArch64, where function pointers are
    // align(4) and `*const anyopaque` is align(1); see bootstrapWgl in
    // src/apprt/windows.zig.
    return @ptrCast(@alignCast(p));
}

/// wglGetProcAddress with its documented failure sentinels (0, 1, 2, 3, -1)
/// mapped to null.
fn wglProc(name: [*:0]const u8) ?*const anyopaque {
    const p = win32.wglGetProcAddress(name) orelse return null;
    return switch (@intFromPtr(p)) {
        1, 2, 3, std.math.maxInt(usize) => null,
        else => p,
    };
}

/// Set the swap interval of the context current on this thread
/// (WGL_EXT_swap_control). Interval 1 caps GPU work at the refresh rate
/// during output floods; SwapBuffers then blocks only the render thread.
/// Missing extension: logged, nothing else.
pub fn setSwapInterval(interval: c_int) void {
    const p = wglProc("wglSwapIntervalEXT") orelse {
        log.info("WGL_EXT_swap_control unavailable; swap interval left at the driver default", .{});
        return;
    };
    const f: win32.SwapIntervalFn = @ptrCast(@alignCast(p));
    if (f(interval).toBool()) {
        log.debug("swap interval set to {d}", .{interval});
    } else {
        log.warn("wglSwapIntervalEXT({d}) failed err={}", .{
            interval,
            std.os.windows.GetLastError(),
        });
    }
}

/// Zero this thread's glad context.
///
/// Required before every load, not hygiene: `gladLoadGLContextUserPtr`
/// never initialises `glad_loader_handle`, `gladLoaderUnloadGLContext`
/// calls FreeLibrary on any non-NULL value (gl.c), and `glad.unload()`
/// leaves the threadlocal `undefined` (0xAA bytes in Debug). Starting from
/// zeroes makes every later `unload` a no-op on the handle.
pub fn resetGladContext() void {
    gl.glad.context = std.mem.zeroes(gl.glad.Context);
}

/// Pop every pending GL error flag. Bounded: a lost context may report an
/// error on every call.
pub fn drainErrors() void {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        gl.errors.getError() catch continue;
        return;
    }
}

fn glString(s: [*c]const u8) []const u8 {
    if (s == null) return "(null)";
    return std.mem.span(@as([*:0]const u8, @ptrCast(s)));
}

/// The value FB0 should hold where the background shows, in FB0's own
/// (linear, i.e. unconverted) encoding. Mirrors common.glsl `load_color`
/// followed by the FRAMEBUFFER_SRGB encode on write (the target is always
/// SRGB8_ALPHA8, OpenGL.zig `initTarget`):
///   linear blending: encode(decode(c) * a)
///   native blending: encode(c * a)
/// With opacity 1 only the linear case reduces to the configured bytes;
/// native blending stores encode(c), which is brighter than c. That is the
/// upstream OpenGL renderer's behaviour, reproduced, not a bug here.
/// Display-P3 conversion is ignored; this colour is on screen for at most
/// one frame, and the readback check compares against it for the same
/// reason.
fn clearColor(opts: InitOptions) [4]f32 {
    const a: f32 = @floatCast(opts.background_opacity);
    var out: [4]f32 = .{ 0, 0, 0, a };
    for (opts.background, 0..) |byte, i| {
        const cv = @as(f32, @floatFromInt(byte)) / 255.0;
        const lin = if (opts.linear_blending) srgbDecode(cv) else cv;
        out[i] = srgbEncode(lin * a);
    }
    return out;
}

fn srgbDecode(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn srgbEncode(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}
