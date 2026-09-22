//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");
const wglpkg = @import("opengl/wgl.zig");

/// WGL (Win32) instead of EGL, i.e. the Win32 apprt is hosting this renderer.
///
/// Every EGL/WGL difference in this file (and in opengl/Frame.zig) is an
/// explicit `if (comptime wgl_enabled) ... else ...`, so exactly one side is
/// ever analysed. On Windows no `egl.*` extern is referenced, which is what
/// lets the exe link without libEGL (SharedDeps.zig links it for GTK only);
/// everywhere else the else side is the pre-existing code, unchanged.
///
/// Keyed on the apprt rather than `builtin.os.tag` because the WGL path
/// reads `rt_surface.hwnd/hdc/hglrc`, which only `apprt.windows.Surface`
/// has (Metal.zig switches on `apprt.runtime` the same way). A Windows
/// library artifact resolves to the embedded apprt and keeps the EGL path.
pub const wgl_enabled = apprt.runtime == apprt.windows;

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
///
/// WGL presents synchronously inside `Frame.complete` (SwapBuffers on the
/// render thread), so at most one frame is ever in flight and extra swap
/// chain entries would only multiply the per-surface targets and atlas
/// copies (generic.zig SwapChain allows a count of 1).
pub const swap_chain_count = if (wgl_enabled) 1 else 3;

const log = std.log.scoped(.opengl);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

egl_display: if (wgl_enabled) void else *gl.egl.Display,
egl_context: if (wgl_enabled) void else *gl.egl.Context,

/// The borrowed WGL context (see opengl/wgl.zig). Zero-sized, and defaulted
/// so the EGL code never has to name it, when WGL is not in use. On WGL it
/// is always set explicitly by `initWgl`; the `undefined` default is never
/// observed.
wgl: if (wgl_enabled) wglpkg.State else void = if (wgl_enabled) undefined else {},

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    return if (comptime wgl_enabled)
        initWgl(alloc, opts)
    else
        initEgl(alloc, opts);
}

/// Main thread, inside `CoreSurface.init`. The apprt owns the context; this
/// only copies its handles and probes it (wgl.State.init), leaving it
/// current nowhere.
fn initWgl(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .egl_display = {},
        .egl_context = {},
        .wgl = try wglpkg.State.init(opts.rt_surface, .{
            .background = .{
                opts.config.background.r,
                opts.config.background.g,
                opts.config.background.b,
            },
            .background_opacity = opts.config.background_opacity,
            .linear_blending = opts.config.blending.isLinear(),
            .min_major = MIN_VERSION_MAJOR,
            .min_minor = MIN_VERSION_MINOR,
        }),
    };
}

fn initEgl(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    try egl.load();

    const display: *egl.Display = try .init(egl.c.EGL_DEFAULT_DISPLAY);

    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});

    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Choose a config. We need a config that is renderable with
    // OpenGL and a RGBA8 color buffer.
    const config = egl.Config.choose(display, &.{
        // EGL_SURFACE_TYPE defaults to EGL_WINDOW_BIT even though
        // we are rendering exclusively through surfaceless mode.
        // This is no problem on Mesa but we need to specify this
        // explicitly for proprietary Nvidia drivers.
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };

    // Create our context.
    const context = egl.Context.create(display, config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .egl_display = display,
        .egl_context = context,
    };
}

pub fn deinit(self: *OpenGL) void {
    if (comptime wgl_enabled) deinitWgl(self) else deinitEgl(self);
}

/// Nothing to release: the apprt deletes the context after the render
/// thread (which released it in `threadExit`) has been joined.
fn deinitWgl(self: *OpenGL) void {
    self.* = undefined;
}

fn deinitEgl(self: *OpenGL) void {
    self.egl_display.releaseCurrent();
    self.egl_context.destroy(self.egl_display) catch {};

    // Do not destroy the EGL display here as
    // it is shared across the entire process.
    // It will get automatically torn down by the OS.
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    return if (comptime wgl_enabled)
        self.threadEnterWgl()
    else
        self.threadEnterEgl(surface);
}

/// Render thread. Takes the context over from the main thread (which
/// released it at the end of `initWgl`) and loads this thread's glad table.
fn threadEnterWgl(self: *OpenGL) !void {
    try self.wgl.makeCurrent();
    errdefer wglpkg.State.releaseCurrent();

    // The threadlocal glad context starts `undefined`; zero it so the
    // `unload`s in prepareContext's errdefer and in threadExit never
    // FreeLibrary a garbage handle (see wgl.resetGladContext).
    wglpkg.resetGladContext();
    errdefer wglpkg.resetGladContext();
    try prepareContext(&wglpkg.getProcAddress);

    wglpkg.setSwapInterval(1);

    // Show the background until the first real frame arrives.
    self.wgl.clearAndPresent();
}

fn threadEnterEgl(self: *OpenGL, surface: *apprt.Surface) !void {
    _ = surface;
    try self.egl_display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    if (comptime wgl_enabled) threadExitWgl() else self.threadExitEgl();
}

/// Render thread, after generic.zig freed every GPU object. Releasing here
/// is what allows the apprt to delete the context once the thread is
/// joined. glad's loader handle is NULL (reset in threadEnterWgl), so
/// `unload` only discards the table.
fn threadExitWgl() void {
    wglpkg.State.releaseCurrent();
    gl.glad.unload();
}

fn threadExitEgl(self: *OpenGL) void {
    self.egl_display.releaseCurrent();
    gl.glad.unload();
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// What `present` hands back: nothing on WGL, which puts the frame on screen
/// itself, otherwise the exported frame.
const PresentResult = if (wgl_enabled) void else ExportedFrame;

/// Present a rendered target. This runs on the render thread.
///
/// WGL: blit to the window and SwapBuffers (opengl/wgl.zig).
/// EGL: see `presentEgl`.
pub fn present(self: *OpenGL, target: Target) !PresentResult {
    return if (comptime wgl_enabled)
        self.wgl.present(target)
    else
        self.presentEgl(target);
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
fn presentEgl(self: *OpenGL, target: Target) !ExportedFrame {
    if (target.exportDmabuf(self.egl_display, self.egl_context)) |dmabuf| {
        return .{ .dmabuf = dmabuf };
    } else |_| {
        // If DMABUFs fail, then use CPU buffers
        return .{ .memory = .{
            .width = @intCast(target.width),
            .height = @intCast(target.height),
            .pixels = try target.readPixelsAlloc(self.alloc),
            .alloc = self.alloc,
        } };
    }
}

/// A finished frame exported for presentation by the apprt.
///
/// `void` on WGL: nothing is exported, so generic.zig's `LatestFrame`
/// compiles to no-ops and no Dmabuf code is analysed.
pub const ExportedFrame = if (wgl_enabled) void else union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2d",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
