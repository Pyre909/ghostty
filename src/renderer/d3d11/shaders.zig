//! The shader set of the Direct3D 11 backend and the data types the
//! generic renderer writes for it.
//!
//! The data layouts are the OpenGL ones: HLSL constant buffers pack scalars
//! into 32-bit slots like std140, and shader model 5 has no 8- or 16-bit
//! scalars, so the u32-packed bit fields are what the shaders will read.
//!
//! The HLSL sources under shaders/hlsl/ are embedded at build time with
//! their `#include`s expanded and compiled at runtime by D3DCompile. A
//! pipeline built without sources stays a placeholder that render steps skip.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const math = @import("../../math.zig");

const api = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const RenderPass = @import("RenderPass.zig");

const log = std.log.scoped(.d3d11);

/// The vertex shader of every full-screen pipeline, the custom shader
/// pipelines included.
const full_screen_vertex = loadShaderCode("../shaders/hlsl/full_screen.vs.hlsl");

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = full_screen_vertex,
            .fragment_fn = loadShaderCode("../shaders/hlsl/bg_color.ps.hlsl"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = full_screen_vertex,
            .fragment_fn = loadShaderCode("../shaders/hlsl/cell_bg.ps.hlsl"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = loadShaderCode("../shaders/hlsl/cell_text.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/cell_text.ps.hlsl"),
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = loadShaderCode("../shaders/hlsl/image.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/image.ps.hlsl"),
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = loadShaderCode("../shaders/hlsl/bg_image.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/bg_image.ps.hlsl"),
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    /// HLSL sources; a pipeline without them is a placeholder.
    vertex_fn: ?[:0]const u8 = null,
    fragment_fn: ?[:0]const u8 = null,
    blending_enabled: bool,

    fn initPipeline(
        self: PipelineDescription,
        name: []const u8,
        device: *api.ID3D11Device,
        compile: api.D3DCompileFn,
        format: api.DXGI_FORMAT,
    ) !Pipeline {
        return try .init(.{
            .device = device,
            .compile = compile,
            .format = format,
            .name = name,
            .vertex_source = self.vertex_fn,
            .fragment_source = self.fragment_fn,
            .input_elements = if (self.vertex_attributes) |V| inputElements(V) else &.{},
            .stride = if (self.vertex_attributes) |V| @sizeOf(V) else 0,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;

    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// This contains the state for the shaders used by the Direct3D 11 renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. Each
    /// shader is run in sequence against the output of the previous one.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        device: *api.ID3D11Device,
        compile: api.D3DCompileFn,
        post_shaders: []const [:0]const u8,
        format: api.DXGI_FORMAT,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;
        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(
                pipeline[0],
                device,
                compile,
                format,
            );
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = try initPostPipelines(
            alloc,
            device,
            compile,
            post_shaders,
            format,
        );
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(self.post_pipelines);
        }
    }
};

/// Initialize our custom shader pipelines: each one runs the full-screen
/// vertex shader with a converted shadertoy shader as its pixel shader,
/// without blending, as on Metal.
///
/// A shader the HLSL compiler rejects is logged and left out rather than
/// failing every shader: glslang has accepted it by now, so what remains
/// is a construct this backend's compiler does not take, and the terminal
/// stays usable without that effect.
///
/// The shaders argument is a set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    device: *api.ID3D11Device,
    compile: api.D3DCompileFn,
    shaders: []const [:0]const u8,
    format: api.DXGI_FORMAT,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many pipelines we successfully built, so
    // that an error undoes exactly those.
    var i: usize = 0;
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| pipeline.deinit();
        alloc.free(pipelines);
    }

    for (shaders, 0..) |source, n| {
        pipelines[i] = Pipeline.init(.{
            .device = device,
            .compile = compile,
            .format = format,
            .name = "custom shader",
            .vertex_source = full_screen_vertex,
            .fragment_source = source,
            .blending_enabled = false,
        }) catch |err| switch (err) {
            error.ShaderCompileFailed => {
                log.warn("custom shader {d} skipped: it did not compile", .{n});
                continue;
            },
            else => return err,
        };
        i += 1;
    }

    // Shrunk to the ones that compiled; an empty result frees the
    // allocation, and deinit frees nothing for an empty slice.
    return try alloc.realloc(pipelines, i);
}

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` format, which means the shaders need to output
        /// linear RGB colors rather than gamma encoded colors, since
        /// blending will be performed in linear space and then the GPU
        /// re-encodes the colors for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// The input-assembler layout of an instance type, as an explicit table
/// rather than one derived from the fields: the two trailing bytes of
/// CellText become a single two-component element so that every offset is
/// a multiple of four, and the semantic names are what the vertex shaders
/// declare. The layout tests below pin the offsets to the Zig types.
pub fn inputElements(comptime V: type) []const api.D3D11_INPUT_ELEMENT_DESC {
    return switch (V) {
        CellText => &cell_text_elements,
        Image => &image_elements,
        BgImage => &bg_image_elements,
        else => @compileError("no input layout for " ++ @typeName(V)),
    };
}

// Container-level so the tables live in static memory; an anonymous array
// built inside the function would be a stack temporary.
const cell_text_elements = [_]api.D3D11_INPUT_ELEMENT_DESC{
    element("GLYPH_POS", .R32G32_UINT, 0),
    element("GLYPH_SIZE", .R32G32_UINT, 8),
    element("BEARINGS", .R16G16_SINT, 16),
    element("GRID_POS", .R16G16_UINT, 20),
    element("COLOR", .R8G8B8A8_UINT, 24),
    element("ATLAS_BOOLS", .R8G8_UINT, 28),
};

const image_elements = [_]api.D3D11_INPUT_ELEMENT_DESC{
    element("GRID_POS", .R32G32_FLOAT, 0),
    element("CELL_OFFSET", .R32G32_FLOAT, 8),
    element("SOURCE_RECT", .R32G32B32A32_FLOAT, 16),
    element("DEST_SIZE", .R32G32_FLOAT, 32),
};

const bg_image_elements = [_]api.D3D11_INPUT_ELEMENT_DESC{
    element("OPACITY", .R32_FLOAT, 0),
    element("INFO", .R8_UINT, 4),
};

/// One per-instance element in vertex buffer slot 0.
fn element(
    comptime name: [:0]const u8,
    comptime format: api.DXGI_FORMAT,
    comptime offset: u32,
) api.D3D11_INPUT_ELEMENT_DESC {
    return .{
        .SemanticName = name,
        .SemanticIndex = 0,
        .Format = format,
        .InputSlot = 0,
        .AlignedByteOffset = offset,
        .InputSlotClass = .PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    };
}

/// Load shader code from the target path, processing `#include` directives.
///
/// Comptime only, and as sloppy as its OpenGL twin: it assumes well-formed
/// `#include "file"` lines and file names without quote marks.
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
}

fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint(
                "{s}{s}{s}",
                .{
                    contents[0..i],
                    @embedFile(basedir ++ "/" ++ contents[start..end]),
                    processIncludes(contents[end + 1 ..], basedir),
                },
            );
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}

test "d3d11 shaders: uniform offsets match the cbuffer packoffsets" {
    // common.hlsl pins every field to a register with packoffset; these
    // are the byte offsets those annotations mean (16 bytes per register).
    const testing = std.testing;
    try testing.expectEqual(0, @offsetOf(Uniforms, "projection_matrix"));
    try testing.expectEqual(64, @offsetOf(Uniforms, "screen_size"));
    try testing.expectEqual(72, @offsetOf(Uniforms, "cell_size"));
    try testing.expectEqual(80, @offsetOf(Uniforms, "grid_size"));
    try testing.expectEqual(96, @offsetOf(Uniforms, "grid_padding"));
    try testing.expectEqual(112, @offsetOf(Uniforms, "padding_extend"));
    try testing.expectEqual(116, @offsetOf(Uniforms, "min_contrast"));
    try testing.expectEqual(120, @offsetOf(Uniforms, "cursor_pos"));
    try testing.expectEqual(124, @offsetOf(Uniforms, "cursor_color"));
    try testing.expectEqual(128, @offsetOf(Uniforms, "bg_color"));
    try testing.expectEqual(132, @offsetOf(Uniforms, "bools"));
    try testing.expectEqual(144, @sizeOf(Uniforms));
}

test "d3d11 shaders: input element offsets match the instance types" {
    const testing = std.testing;
    const cell = inputElements(CellText);
    try testing.expectEqual(@offsetOf(CellText, "glyph_pos"), cell[0].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(CellText, "glyph_size"), cell[1].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(CellText, "bearings"), cell[2].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(CellText, "grid_pos"), cell[3].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(CellText, "color"), cell[4].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(CellText, "atlas"), cell[5].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(CellText, "atlas") + 1, @offsetOf(CellText, "bools"));
    const image = inputElements(Image);
    try testing.expectEqual(@offsetOf(Image, "grid_pos"), image[0].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(Image, "cell_offset"), image[1].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(Image, "source_rect"), image[2].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(Image, "dest_size"), image[3].AlignedByteOffset);
    const bg = inputElements(BgImage);
    try testing.expectEqual(@offsetOf(BgImage, "opacity"), bg[0].AlignedByteOffset);
    try testing.expectEqual(@offsetOf(BgImage, "info"), bg[1].AlignedByteOffset);
    inline for (.{ cell, image, bg }) |elements| {
        for (elements) |e| try testing.expectEqual(0, e.AlignedByteOffset % 4);
    }
}

test "d3d11 shaders: data layouts" {
    const testing = std.testing;
    // The instance layout the text pipeline will declare depends on these.
    try testing.expectEqual(32, @sizeOf(CellText));
    try testing.expectEqual(28, @offsetOf(CellText, "atlas"));
    try testing.expectEqual(29, @offsetOf(CellText, "bools"));
    try testing.expectEqual(4, @sizeOf(CellBg));
    // source_rect is 16-byte aligned, so the struct pads to 48 and that
    // is the instance stride the image pipeline will declare.
    try testing.expectEqual(48, @sizeOf(Image));
    try testing.expectEqual(8, @sizeOf(BgImage));
    // Constant buffers are bound in 16-byte slots.
    try testing.expectEqual(0, @sizeOf(Uniforms) % 16);
}

/// The embedded source of a named pipeline, for the tests below.
fn testSource(
    comptime name: []const u8,
    comptime stage: enum { vertex, fragment },
) [:0]const u8 {
    return comptime found: {
        for (pipeline_descs) |pipeline| {
            if (std.mem.eql(u8, pipeline[0], name)) break :found switch (stage) {
                .vertex => pipeline[1].vertex_fn.?,
                .fragment => pipeline[1].fragment_fn.?,
            };
        }
        @compileError("no pipeline named " ++ name);
    };
}

test "d3d11 shaders: input element tables match the vertex shader inputs" {
    // CreateInputLayout rejects a layout that lacks an input the vertex
    // shader declares, and a table entry the shader never names is a
    // stale one, so the `: NAME;` semantics of `struct VertexIn` and the
    // table must be the same set. The system-value input (SV_VertexID)
    // is not part of the layout.
    const testing = std.testing;
    inline for (pipeline_descs) |pipeline| {
        const V = pipeline[1].vertex_attributes orelse continue;
        const source = pipeline[1].vertex_fn orelse continue;
        const elements = inputElements(V);

        const start = std.mem.indexOf(u8, source, "struct VertexIn {") orelse
            return error.TestUnexpectedResult;
        const end = std.mem.indexOfPos(u8, source, start, "};") orelse
            return error.TestUnexpectedResult;
        const body = source[start..end];

        var declared: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOf(u8, line, " : ") orelse continue;
            const semi = std.mem.indexOfScalarPos(u8, line, colon, ';') orelse continue;
            const name = line[colon + 3 .. semi];
            if (std.mem.startsWith(u8, name, "SV_")) continue;
            declared += 1;
            var found = false;
            for (elements) |e| {
                if (std.mem.eql(u8, std.mem.span(e.SemanticName), name)) found = true;
            }
            try testing.expect(found);
        }
        try testing.expectEqual(elements.len, declared);
    }
}

test "d3d11 shaders: cbuffer packoffsets match the uniform offsets" {
    // common.hlsl pins every field to a register with packoffset. Each
    // annotation is derived here from the Zig offset and looked up in the
    // embedded source, so an edit to either side fails this test.
    const testing = std.testing;
    const source = testSource("bg_color", .fragment);
    const fields = .{
        .{ "projection_matrix", "projection_matrix" },
        .{ "screen_size", "screen_size" },
        .{ "cell_size", "cell_size" },
        .{ "grid_size", "grid_size_packed_2u16" },
        .{ "grid_padding", "grid_padding" },
        .{ "padding_extend", "padding_extend" },
        .{ "min_contrast", "min_contrast" },
        .{ "cursor_pos", "cursor_pos_packed_2u16" },
        .{ "cursor_color", "cursor_color_packed_4u8" },
        .{ "bg_color", "bg_color_packed_4u8" },
        .{ "bools", "bools" },
    };
    inline for (fields) |f| {
        const off = @offsetOf(Uniforms, f[0]);
        const size = @sizeOf(@FieldType(Uniforms, f[0]));
        // A field that fills whole registers is annotated without a
        // component.
        const needle = if (off % 16 == 0 and size >= 16)
            std.fmt.comptimePrint("{s} : packoffset(c{d});", .{ f[1], off / 16 })
        else
            std.fmt.comptimePrint("{s} : packoffset(c{d}.{c});", .{
                f[1],
                off / 16,
                "xyzw"[(off % 16) / 4],
            });
        try testing.expect(std.mem.indexOf(u8, source, needle) != null);
    }
    // Nothing is declared past the registers the struct covers.
    const past = std.fmt.comptimePrint("packoffset(c{d}", .{@sizeOf(Uniforms) / 16});
    try testing.expect(std.mem.indexOf(u8, source, past) == null);
}

test "d3d11 shaders: bit masks and registers match the Zig side" {
    // The shaders decode the packed structs with literal masks and name
    // the storage buffer register; each literal is derived here from the
    // Zig type or constant and looked up in the embedded source.
    const testing = std.testing;
    const print = std.fmt.comptimePrint;
    const common = testSource("bg_color", .fragment);
    const text = testSource("cell_text", .vertex);
    const cell_bg = testSource("cell_bg", .fragment);
    const bg_image = testSource("bg_image", .vertex);

    const Bools = Uniforms.Bools;
    const Extend = Uniforms.PaddingExtend;
    const GlyphBools = @FieldType(CellText, "bools");
    const Info = BgImage.Info;
    const pos_shift = @bitOffsetOf(Info, "position");
    const fit_shift = @bitOffsetOf(Info, "fit");
    const repeat_shift = @bitOffsetOf(Info, "repeat");

    const masks = .{
        .{ common, "CURSOR_WIDE", print("{d}u", .{@as(u32, @bitCast(Bools{
            .cursor_wide = true,
            .use_display_p3 = false,
            .use_linear_blending = false,
        }))}) },
        .{ common, "USE_DISPLAY_P3", print("{d}u", .{@as(u32, @bitCast(Bools{
            .cursor_wide = false,
            .use_display_p3 = true,
            .use_linear_blending = false,
        }))}) },
        .{ common, "USE_LINEAR_BLENDING", print("{d}u", .{@as(u32, @bitCast(Bools{
            .cursor_wide = false,
            .use_display_p3 = false,
            .use_linear_blending = true,
        }))}) },
        .{ common, "USE_LINEAR_CORRECTION", print("{d}u", .{@as(u32, @bitCast(Bools{
            .cursor_wide = false,
            .use_display_p3 = false,
            .use_linear_blending = false,
            .use_linear_correction = true,
        }))}) },
        .{ common, "EXTEND_LEFT", print("{d}u", .{@as(u32, @bitCast(Extend{ .left = true }))}) },
        .{ common, "EXTEND_RIGHT", print("{d}u", .{@as(u32, @bitCast(Extend{ .right = true }))}) },
        .{ common, "EXTEND_UP", print("{d}u", .{@as(u32, @bitCast(Extend{ .up = true }))}) },
        .{ common, "EXTEND_DOWN", print("{d}u", .{@as(u32, @bitCast(Extend{ .down = true }))}) },
        .{ text, "NO_MIN_CONTRAST", print("{d}u", .{@as(u8, @bitCast(GlyphBools{ .no_min_contrast = true }))}) },
        .{ text, "IS_CURSOR_GLYPH", print("{d}u", .{@as(u8, @bitCast(GlyphBools{ .is_cursor_glyph = true }))}) },
        .{ text, "ATLAS_GRAYSCALE", print("{d}u", .{@intFromEnum(CellText.Atlas.grayscale)}) },
        .{ text, "ATLAS_COLOR", print("{d}u", .{@intFromEnum(CellText.Atlas.color)}) },
        .{ bg_image, "BG_IMAGE_POSITION", print("{d}u", .{((1 << @bitSizeOf(Info.Position)) - 1) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_TL", print("{d}u", .{@intFromEnum(Info.Position.tl) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_TC", print("{d}u", .{@intFromEnum(Info.Position.tc) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_TR", print("{d}u", .{@intFromEnum(Info.Position.tr) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_ML", print("{d}u", .{@intFromEnum(Info.Position.ml) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_MC", print("{d}u", .{@intFromEnum(Info.Position.mc) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_MR", print("{d}u", .{@intFromEnum(Info.Position.mr) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_BL", print("{d}u", .{@intFromEnum(Info.Position.bl) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_BC", print("{d}u", .{@intFromEnum(Info.Position.bc) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_BR", print("{d}u", .{@intFromEnum(Info.Position.br) << pos_shift}) },
        .{ bg_image, "BG_IMAGE_FIT", print("{d}u << {d}", .{ (1 << @bitSizeOf(Info.Fit)) - 1, fit_shift }) },
        .{ bg_image, "BG_IMAGE_CONTAIN", print("{d}u << {d}", .{ @intFromEnum(Info.Fit.contain), fit_shift }) },
        .{ bg_image, "BG_IMAGE_COVER", print("{d}u << {d}", .{ @intFromEnum(Info.Fit.cover), fit_shift }) },
        .{ bg_image, "BG_IMAGE_STRETCH", print("{d}u << {d}", .{ @intFromEnum(Info.Fit.stretch), fit_shift }) },
        .{ bg_image, "BG_IMAGE_NO_FIT", print("{d}u << {d}", .{ @intFromEnum(Info.Fit.none), fit_shift }) },
        .{ bg_image, "BG_IMAGE_REPEAT", print("{d}u << {d}", .{ 1, repeat_shift }) },
    };
    inline for (masks) |m| {
        const needle = print("static const uint {s} = {s};", .{ m[1], m[2] });
        try testing.expect(std.mem.indexOf(u8, m[0], needle) != null);
    }

    // The cell shaders read the cell backgrounds from the first storage
    // register.
    const storage = print("register(t{d})", .{RenderPass.storage_register_base});
    try testing.expect(std.mem.indexOf(u8, text, storage) != null);
    try testing.expect(std.mem.indexOf(u8, cell_bg, storage) != null);
}
