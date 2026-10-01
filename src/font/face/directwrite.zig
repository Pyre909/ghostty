const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const opentype = @import("../opentype.zig");
const quirks = @import("../../quirks.zig");
const directwrite = @import("../directwrite/main.zig");
const api = directwrite.api;
const FontFileLoader = directwrite.FontFileLoader;
const stb = @import("../../stb/main.zig");
const wuffs = @import("wuffs");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// The process's DirectWrite state, which has the factories that make
    /// faces and rasterize glyphs. Borrowed, as the library borrows it.
    dwrite: *directwrite.Shared,

    /// Our font face. It has no size: a DirectWrite face is the outlines
    /// and the tables, and the size is given with each glyph run.
    face: *api.IDWriteFontFace,

    /// The DWRITE_FONT_SIMULATIONS_* flags the face was made with. They
    /// are part of what a face is, so a face that replaces this one (with
    /// other variations, or with one more simulation) is made with them.
    simulations: api.UINT,

    /// Harfbuzz font corresponding to this face. It reads the tables of
    /// `face` and is rebuilt whenever `face` is replaced.
    hb_font: harfbuzz.Font,

    /// Set quirks.disableDefaultFontFeatures
    quirks_disable_default_font_features: bool = false,

    /// The current size this font is set to.
    size: font.face.DesiredSize,

    /// The most variation axes a font can have here. This is arbitrary,
    /// and the limit of the FreeType face.
    const max_axes = 32;

    /// Initialize a DirectWrite-based font from a TTF/TTC in memory. The
    /// memory is not copied and has to outlive the DirectWrite face,
    /// which the tables that are lent to HarfBuzz can keep alive past
    /// `deinit`, see `HbTable`. Every caller has it from @embedFile.
    pub fn init(
        lib: font.Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) !Face {
        const dw = lib.dwrite;
        const factory = dw.factory;

        // DirectWrite copies the key, and reads the font through the
        // loader whenever it wants to, from the bytes the key points at.
        const key = FontFileLoader.key(source);
        var file_out: ?*api.IDWriteFontFile = null;
        const ref_hr = factory.vtable.CreateCustomFontFileReference(
            factory,
            &key,
            @sizeOf(FontFileLoader.Key),
            dw.loader,
            &file_out,
        );
        if (api.failed(ref_hr)) return fail("CreateCustomFontFileReference", ref_hr);
        const file = file_out orelse return error.DirectWriteFailed;
        defer api.release(file);

        var supported: api.BOOL = 0;
        var file_type: api.DWRITE_FONT_FILE_TYPE = .UNKNOWN;
        var face_type: api.DWRITE_FONT_FACE_TYPE = .UNKNOWN;
        var count: api.UINT = 0;
        const analyze_hr = file.vtable.Analyze(
            file,
            &supported,
            &file_type,
            &face_type,
            &count,
        );
        if (api.failed(analyze_hr)) return fail("IDWriteFontFile.Analyze", analyze_hr);
        if (supported == 0 or count == 0) {
            log.warn("font in memory is not one DirectWrite reads file_type={} faces={}", .{
                @intFromEnum(file_type),
                count,
            });
            return error.DirectWriteFailed;
        }

        var face_out: ?*api.IDWriteFontFace = null;
        const face_hr = factory.vtable.CreateFontFace(
            factory,
            face_type,
            1,
            &[_]*api.IDWriteFontFile{file},
            0,
            api.DWRITE_FONT_SIMULATIONS_NONE,
            &face_out,
        );
        if (api.failed(face_hr)) return fail("IDWriteFactory.CreateFontFace", face_hr);
        const face = face_out orelse return error.DirectWriteFailed;
        errdefer api.release(face);

        return try initFace(dw, face, api.DWRITE_FONT_SIMULATIONS_NONE, opts);
    }

    /// Initialize a face from a font of a font collection, which is what
    /// discovery finds. The font stays the caller's.
    pub fn initFont(
        lib: font.Library,
        dw_font: *api.IDWriteFont,
        opts: font.face.Options,
    ) !Face {
        var face_out: ?*api.IDWriteFontFace = null;
        const hr = dw_font.vtable.CreateFontFace(dw_font, &face_out);
        if (api.failed(hr)) return fail("IDWriteFont.CreateFontFace", hr);
        const face = face_out orelse return error.DirectWriteFailed;
        errdefer api.release(face);

        // A font of a collection can be a simulated one, the bold of a
        // family that has none, and its face is made with the simulation.
        return try initFace(
            lib.dwrite,
            face,
            face.vtable.GetSimulations(face),
            opts,
        );
    }

    /// Initialize a face with a DirectWrite face. This takes ownership of
    /// the reference to the face when it succeeds.
    fn initFace(
        dw: *directwrite.Shared,
        face: *api.IDWriteFontFace,
        simulations: api.UINT,
        opts: font.face.Options,
    ) !Face {
        var hb_font = try createHbFont(face, opts.size);
        errdefer hb_font.destroy();

        var result: Face = .{
            .dwrite = dw,
            .face = face,
            .simulations = simulations,
            .hb_font = hb_font,
            .size = opts.size,
        };
        result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);

        // In debug mode, we output information about the variation axes,
        // if they exist. DirectWrite gives the values through the face;
        // the ranges are the font resource's, which nothing here needs.
        if (comptime builtin.mode == .Debug) axes: {
            const face5 = api.queryInterface(face, api.IDWriteFontFace5) catch break :axes;
            defer api.release(face5);
            var axes_buf: [max_axes]api.DWRITE_FONT_AXIS_VALUE = undefined;
            const axes = axisValues(face5, &axes_buf) orelse break :axes;
            if (axes.len == 0) break :axes;

            var buf: [1024]u8 = undefined;
            log.debug("variation axes font={s}", .{try result.name(&buf)});
            for (axes) |axis| {
                const id: font.face.Variation.Id = @bitCast(@byteSwap(axis.axisTag));
                log.debug("variation axis: id={s} value={}", .{
                    id.str(),
                    axis.value,
                });
            }
        }

        return result;
    }

    pub fn deinit(self: *Face) void {
        // The tables that HarfBuzz still holds keep the face alive on
        // their own, see `HbTable`.
        self.hb_font.destroy();
        api.release(self.face);
        self.* = undefined;
    }

    /// Return a new face that is the same as this but has DirectWrite's
    /// oblique simulation applied to italicize it.
    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) !Face {
        return try self.simulated(api.DWRITE_FONT_SIMULATIONS_OBLIQUE, opts);
    }

    /// Return a new face that is the same as this but applies DirectWrite's
    /// bold simulation to it. This is useful for fonts that don't have a
    /// bold variant.
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) !Face {
        return try self.simulated(api.DWRITE_FONT_SIMULATIONS_BOLD, opts);
    }

    /// A new face of the same font with a simulation added to the ones
    /// this face has.
    fn simulated(
        self: *const Face,
        simulation: api.UINT,
        opts: font.face.Options,
    ) !Face {
        const simulations = self.simulations | simulation;

        // An instance of a variable font is made again by the font's
        // resource, with the axis values it has now: the factory below
        // knows files and an index and would make the default instance.
        const face = (try self.createInstance(simulations, null)) orelse face: {
            var count: api.UINT = 0;
            const count_hr = self.face.vtable.GetFiles(self.face, &count, null);
            if (api.failed(count_hr)) return fail("IDWriteFontFace.GetFiles", count_hr);

            // One file for every format but Type 1, which has two.
            var files_buf: [4]?*api.IDWriteFontFile = @splat(null);
            if (count == 0 or count > files_buf.len) {
                log.warn("font face has an unexpected number of files count={}", .{count});
                return error.DirectWriteFailed;
            }
            const files_hr = self.face.vtable.GetFiles(self.face, &count, &files_buf);
            defer for (files_buf) |file_| if (file_) |file| api.release(file);
            if (api.failed(files_hr)) return fail("IDWriteFontFace.GetFiles", files_hr);

            var files: [files_buf.len]*api.IDWriteFontFile = undefined;
            for (files_buf[0..count], files[0..count]) |file_, *file|
                file.* = file_ orelse return error.DirectWriteFailed;

            const factory = self.dwrite.factory;
            var out: ?*api.IDWriteFontFace = null;
            const hr = factory.vtable.CreateFontFace(
                factory,
                self.face.vtable.GetType(self.face),
                count,
                &files,
                self.face.vtable.GetIndex(self.face),
                simulations,
                &out,
            );
            if (api.failed(hr)) return fail("IDWriteFactory.CreateFontFace", hr);
            break :face out orelse return error.DirectWriteFailed;
        };
        errdefer api.release(face);

        return try initFace(self.dwrite, face, simulations, opts);
    }

    /// A new face of the variable font this face is an instance of, with
    /// the axis values of this face and the given ones over them. Null
    /// when the font has no axes or DirectWrite predates variable fonts,
    /// which is not an error: there is one instance then.
    fn createInstance(
        self: *const Face,
        simulations: api.UINT,
        vs: ?[]const font.face.Variation,
    ) !?*api.IDWriteFontFace {
        const face5 = api.queryInterface(self.face, api.IDWriteFontFace5) catch {
            if (vs != null and !variations_logged.swap(true, .monotonic)) log.warn(
                "this version of Windows has no variable fonts in DirectWrite, font variations are ignored",
                .{},
            );
            return null;
        };
        defer api.release(face5);

        var axes_buf: [max_axes]api.DWRITE_FONT_AXIS_VALUE = undefined;
        const axes = axisValues(face5, &axes_buf) orelse return null;
        if (axes.len == 0) return null;

        // DirectWrite takes all the axes at once, as FreeType does, so
        // the values asked for go over the ones in force. This is slow
        // but there usually aren't many axes and usually not many set
        // variations, either.
        if (vs) |variations| for (axes) |*axis| {
            for (variations) |v| {
                if (axis.axisTag == directwrite.axisTag(v.id)) {
                    axis.value = @floatCast(v.value);
                    break;
                }
            }
        };

        var resource_out: ?*api.IDWriteFontResource = null;
        const resource_hr = face5.vtable.GetFontResource(face5, &resource_out);
        if (api.failed(resource_hr)) return fail("IDWriteFontFace5.GetFontResource", resource_hr);
        const resource = resource_out orelse return error.DirectWriteFailed;
        defer api.release(resource);

        var out: ?*api.IDWriteFontFace5 = null;
        const hr = resource.vtable.CreateFontFace(
            resource,
            simulations,
            axes.ptr,
            @intCast(axes.len),
            &out,
        );
        if (api.failed(hr)) return fail("IDWriteFontResource.CreateFontFace", hr);
        return (out orelse return error.DirectWriteFailed).face();
    }

    /// Whether the missing variable font support has been logged, which
    /// it is once: every face that is loaded would say it again.
    var variations_logged: std.atomic.Value(bool) = .init(false);

    /// Whether the missing rasterizer has been logged, once for the same
    /// reason.
    var rasterizer_logged: std.atomic.Value(bool) = .init(false);

    /// The axis values in force of a face, in `buf`. Empty for a font
    /// that is not variable, null when they cannot be read or do not fit.
    fn axisValues(
        face5: *api.IDWriteFontFace5,
        buf: *[max_axes]api.DWRITE_FONT_AXIS_VALUE,
    ) ?[]api.DWRITE_FONT_AXIS_VALUE {
        // DirectWrite has the values of four axes for every font, at
        // what the font is: a weight, a width, a slant, an italic. They
        // are what a font that cannot vary is described by and not
        // something to set, and a face that is made with other values
        // for them is the face it was.
        if (face5.vtable.HasVariations(face5) == 0) return buf[0..0];

        const count = face5.vtable.GetFontAxisValueCount(face5);
        if (count == 0) return buf[0..0];
        if (count > buf.len) {
            log.warn("font has more variation axes than are supported axes={}", .{count});
            return null;
        }
        const hr = face5.vtable.GetFontAxisValues(face5, buf, count);
        if (api.failed(hr)) {
            log.warn("IDWriteFontFace5.GetFontAxisValues failed hr=0x{x}", .{
                @as(u32, @bitCast(hr)),
            });
            return null;
        }
        return buf[0..count];
    }

    /// Returns the font name. If allocation is required, buf will be used,
    /// but sometimes allocation isn't required and a static string is
    /// returned.
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        // The family name is the font's before Windows 10, where a face
        // does not know it; a face made from memory has no font.
        const face3 = api.queryInterface(self.face, api.IDWriteFontFace3) catch return "";
        defer api.release(face3);

        var out: ?*api.IDWriteLocalizedStrings = null;
        if (api.failed(face3.vtable.GetFamilyNames(face3, &out))) return "";
        const strings = out orelse return "";
        defer api.release(strings);

        return directwrite.localizedString(strings, buf) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DirectWriteFailed => "",
        };
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, opts: font.face.Options) !void {
        // A DirectWrite face has no size, so there is nothing to make
        // again. HarfBuzz is the one that has to hear of it.
        self.size = opts.size;
        setScale(&self.hb_font, opts.size);
    }

    /// Set the variation axes for this font. This will modify this font
    /// in-place.
    pub fn setVariations(
        self: *Face,
        vs: []const font.face.Variation,
        opts: font.face.Options,
    ) !void {
        // The size stays the one we have.
        _ = opts;

        // If we have no variations, we don't need to do anything.
        if (vs.len == 0) return;

        // If this font doesn't support variations, we can't do anything.
        const face = (try self.createInstance(self.simulations, vs)) orelse return;
        errdefer api.release(face);

        // HarfBuzz reads the tables of the face and has to shape the
        // instance that DirectWrite draws, so it gets a font of its own
        // for the new face. The old one goes after the new one is known
        // to exist, so that a failure leaves this face as it was.
        const hb_font = try createHbFont(face, self.size);

        self.hb_font.destroy();
        api.release(self.face);
        self.face = face;
        self.hb_font = hb_font;
    }

    /// Returns true if the face has any glyphs that are colorized.
    /// To determine if an individual glyph is colorized you must use
    /// isColorGlyph.
    pub fn hasColor(self: *const Face) bool {
        // DirectWrite says yes to a font with color layers, to one with
        // color images (both of the emoji fonts that are built in) and to
        // one with an SVG table, which is not drawn here, as CoreText says
        // yes to it.
        const face2 = api.queryInterface(self.face, api.IDWriteFontFace2) catch return false;
        defer api.release(face2);
        return face2.vtable.IsColorFont(face2) != 0;
    }

    /// Returns true if the given glyph ID is colorized, which is when
    /// it is drawn from an image or from layers, see `glyphSource`.
    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        // Our font system uses 32-bit glyph IDs for special values but
        // actual fonts only contain 16-bit glyph IDs.
        const glyph = std.math.cast(u16, glyph_id) orelse return false;
        return self.glyphSource(glyph) != .outline;
    }

    /// What a glyph is drawn from.
    const Source = union(enum) {
        /// Its outline, in the color of the text.
        outline,
        /// An image the font has of it, in this format: one of
        /// `image_formats`.
        image: api.DWRITE_GLYPH_IMAGE_FORMATS,
        /// The layers of a COLR glyph, each drawn in its own color.
        layers,
    };

    /// The formats of an image that are drawn here: PNG, and BGRA that
    /// is premultiplied, which is what the atlas holds. JPEG and TIFF
    /// images, SVG and the paint trees of COLR version 1 are not drawn;
    /// a glyph that has only those is drawn from its outline.
    const image_formats: api.DWRITE_GLYPH_IMAGE_FORMATS =
        api.DWRITE_GLYPH_IMAGE_FORMATS_PNG |
        api.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8;

    /// What a glyph is drawn from. The formats of the font are asked
    /// first, so that a font without color costs a glyph one call. The
    /// formats of a glyph are not enough for the layers: DirectWrite
    /// reports no format at all for a glyph of Segoe UI Emoji that has
    /// them, so the layers themselves are asked for. The formats are
    /// asked of IDWriteFontFace4, which Windows has since 10 1607; the
    /// layers need only the factory of 8.1, so without the formats a
    /// glyph of a color font is still asked for its layers, and images
    /// are not drawn.
    fn glyphSource(self: Face, glyph: u16) Source {
        const face4 = api.queryInterface(self.face, api.IDWriteFontFace4) catch
            return if (self.hasColor() and self.hasLayers(glyph)) .layers else .outline;
        defer api.release(face4);
        const formats = face4.vtable.GetGlyphImageFormats(face4);
        if (formats & api.DWRITE_GLYPH_IMAGE_FORMATS_COLR != 0 and self.hasLayers(glyph))
            return .layers;
        if (formats & image_formats != 0) {
            var glyph_formats: api.DWRITE_GLYPH_IMAGE_FORMATS = 0;
            const hr = face4.vtable.GetGlyphImageFormats_(
                face4,
                glyph,
                0,
                std.math.maxInt(api.UINT32),
                &glyph_formats,
            );
            if (api.succeeded(hr)) {
                if (glyph_formats & api.DWRITE_GLYPH_IMAGE_FORMATS_PNG != 0)
                    return .{ .image = api.DWRITE_GLYPH_IMAGE_FORMATS_PNG };
                if (glyph_formats & api.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8 != 0)
                    return .{ .image = api.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8 };
            }
        }
        return .outline;
    }

    /// Whether DirectWrite has color layers for a glyph. It has none
    /// without the factory of Windows 8.1, where the glyph is drawn
    /// from its outline.
    fn hasLayers(self: Face, glyph: u16) bool {
        const factory2 = self.dwrite.factory2 orelse return false;
        const indices = [_]api.UINT16{glyph};
        const run = self.glyphRun(&indices);
        var out: ?*api.IDWriteColorGlyphRunEnumerator = null;
        const hr = factory2.vtable.TranslateColorGlyphRun(
            factory2,
            0,
            0,
            &run,
            null,
            .NATURAL,
            null,
            0,
            &out,
        );
        if (out) |e| api.release(e);
        return api.succeeded(hr);
    }

    /// One layer of a color glyph: a glyph of the font in one color.
    const Layer = struct {
        glyph: api.UINT16,
        /// sRGB, not premultiplied, 0 to 1.
        color: api.DWRITE_COLOR_F,
    };

    /// The layers of a color glyph in the order they are drawn, owned
    /// by the caller. Null when the glyph has none.
    fn colorLayers(self: Face, alloc: Allocator, glyph: u16) !?[]Layer {
        const factory2 = self.dwrite.factory2 orelse return null;
        const indices = [_]api.UINT16{glyph};
        const run = self.glyphRun(&indices);
        var out: ?*api.IDWriteColorGlyphRunEnumerator = null;
        const hr = factory2.vtable.TranslateColorGlyphRun(
            factory2,
            0,
            0,
            &run,
            null,
            .NATURAL,
            null,
            0,
            &out,
        );
        if (hr == api.DWRITE_E_NOCOLOR) return null;
        if (api.failed(hr)) return fail("IDWriteFactory2.TranslateColorGlyphRun", hr);
        const layers = out orelse return error.DirectWriteFailed;
        defer api.release(layers);

        var list: std.ArrayList(Layer) = .empty;
        errdefer list.deinit(alloc);
        while (true) {
            var has: api.BOOL = 0;
            const next_hr = layers.vtable.MoveNext(layers, &has);
            if (api.failed(next_hr)) return fail("IDWriteColorGlyphRunEnumerator.MoveNext", next_hr);
            if (has == 0) break;

            var current: ?*const api.DWRITE_COLOR_GLYPH_RUN = null;
            const run_hr = layers.vtable.GetCurrentRun(layers, &current);
            if (api.failed(run_hr)) return fail("IDWriteColorGlyphRunEnumerator.GetCurrentRun", run_hr);
            const layer = current orelse return error.DirectWriteFailed;

            const color = layerColor(layer);
            const glyphs = layer.glyphRun.glyphIndices[0..layer.glyphRun.glyphCount];
            for (glyphs) |g| try list.append(alloc, .{ .glyph = g, .color = color });
        }
        return try list.toOwnedSlice(alloc);
    }

    /// The color a layer is drawn in. A layer that takes the color of
    /// the text is drawn white, as the CoreText face draws a color
    /// glyph: the atlas has no color of the text to give it.
    fn layerColor(layer: *const api.DWRITE_COLOR_GLYPH_RUN) api.DWRITE_COLOR_F {
        if (layer.paletteIndex == 0xFFFF) return .{ .r = 1, .g = 1, .b = 1, .a = 1 };
        return layer.runColor;
    }

    /// A run of these glyphs of the face at its size, each at the
    /// origin. The indices have to outlive the run.
    fn glyphRun(self: Face, indices: []const api.UINT16) api.DWRITE_GLYPH_RUN {
        return .{
            .fontFace = self.face,
            .fontEmSize = self.size.pixels(),
            .glyphCount = @intCast(indices.len),
            .glyphIndices = indices.ptr,
            .glyphAdvances = null,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        const codepoints = [_]api.UINT{cp};
        var glyphs = [_]api.UINT16{0};
        if (api.failed(self.face.vtable.GetGlyphIndices(
            self.face,
            &codepoints,
            codepoints.len,
            &glyphs,
        ))) return null;

        // Glyph zero is the one a font shows for what it doesn't have.
        if (glyphs[0] == 0) return null;
        return glyphs[0];
    }

    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.Glyph.RenderOptions,
    ) !font.Glyph {
        // Our font system uses 32-bit glyph IDs for special values but
        // actual fonts only contain 16-bit glyph IDs.
        const glyph = std.math.cast(u16, glyph_index) orelse return empty_glyph;

        return switch (self.glyphSource(glyph)) {
            .outline => try self.renderOutline(alloc, atlas, glyph, opts),
            .image => |format| try self.renderImage(alloc, atlas, glyph, format, opts),
            .layers => try self.renderLayers(alloc, atlas, glyph, opts),
        };
    }

    /// The glyph that draws nothing.
    const empty_glyph: font.Glyph = .{
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .atlas_x = 0,
        .atlas_y = 0,
    };

    /// The box of the ink of these glyphs together, from the origin of
    /// each, in pixels with +Y up, from the design metrics. Null when
    /// none of them has ink. `gm` is room for the metrics of each.
    fn designBox(
        self: Face,
        glyphs: []const api.UINT16,
        gm: []api.DWRITE_GLYPH_METRICS,
    ) !?font.Glyph.Size {
        assert(gm.len == glyphs.len);
        const hr = self.face.vtable.GetDesignGlyphMetrics(
            self.face,
            glyphs.ptr,
            @intCast(glyphs.len),
            gm.ptr,
            0,
        );
        if (api.failed(hr)) return fail("IDWriteFontFace.GetDesignGlyphMetrics", hr);

        const px_per_em: f64 = self.size.pixels();
        const px_per_unit = px_per_em / self.unitsPerEm();
        var box: ?font.Glyph.Size = null;
        for (gm) |metrics| {
            const ink = inkBox(metrics);
            if (ink.width <= 0 or ink.height <= 0) continue;
            box = if (box) |b| .{
                .x = @min(b.x, ink.x),
                .y = @min(b.y, ink.y),
                .width = @max(b.x + b.width, ink.x + ink.width) - @min(b.x, ink.x),
                .height = @max(b.y + b.height, ink.y + ink.height) - @min(b.y, ink.y),
            } else ink;
        }
        const b = box orelse return null;
        return .{
            .width = b.width * px_per_unit,
            .height = b.height * px_per_unit,
            .x = b.x * px_per_unit,
            .y = b.y * px_per_unit,
        };
    }

    /// Where a glyph goes in its cells, after the constraints: the box
    /// of its ink in the space of the cell, which has its origin at the
    /// cell's bottom left and +Y up, in pixels, and the scale that put
    /// it there.
    const Placement = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        scale_x: f64,
        scale_y: f64,
    };

    /// Place a glyph in its cells. `rect` is the box of its ink from
    /// its origin, in pixels with +Y up.
    fn place(rect: font.Glyph.Size, opts: font.Glyph.RenderOptions) Placement {
        const metrics = opts.grid_metrics;
        const cell_width: f64 = @floatFromInt(metrics.cell_width);

        // Next we apply any constraints to get the final size of the glyph.
        const constraint = opts.constraint;

        // We need to add the baseline position before passing to the constrain
        // function since it operates on cell-relative positions, not baseline.
        const cell_baseline: f64 = @floatFromInt(metrics.cell_baseline);

        const glyph_size = constraint.constrain(
            .{
                .width = rect.width,
                .height = rect.height,
                .x = rect.x,
                .y = rect.y + cell_baseline,
            },
            metrics,
            opts.constraint_width,
        );

        var x = glyph_size.x;

        // We center all glyphs within the pixel-rounded and adjusted
        // cell width if it's larger than the face width, so that they
        // aren't weirdly off to the left.
        //
        // We don't do this if the glyph has a stretch constraint,
        // since in that case the position was already calculated with the
        // new cell width in mind.
        //
        // The glyphs are not fitted to the pixel grid, so as with CoreText
        // the amount is not rounded to whole pixels.
        if (constraint.size != .stretch) {
            // We add half the difference to re-center.
            const dx = (cell_width - metrics.face_width) / 2;
            x += dx;
            if (dx < 0) {
                // For negative diff (cell narrower than advance), we remove the
                // integer part and only keep the fractional adjustment needed
                // for consistent subpixel positioning.
                x -= @trunc(dx);
            }
        }

        return .{
            .x = x,
            .y = glyph_size.y,
            .width = glyph_size.width,
            .height = glyph_size.height,
            // Where the constraint resized the glyph, the outline is
            // scaled about its origin by the same factors.
            .scale_x = glyph_size.width / rect.width,
            .scale_y = glyph_size.height / rect.height,
        };
    }

    /// The transform that rasterizes a glyph into its place.
    fn transform(rect: font.Glyph.Size, p: Placement) api.DWRITE_MATRIX {
        // This is the one conversion between the two coordinate spaces.
        //
        // The glyph is now a box in the space of the cell: origin at the
        // cell's bottom left, +Y pointing up, in pixels, with the bottom
        // left of the ink at (x, y). The ink's bottom left is at
        // (rect.x, rect.y) from the glyph's origin before scaling, so the
        // glyph's origin is at
        //
        //   origin_x = x - rect.x * scale_x
        //   origin_y = y - rect.y * scale_y
        //
        // in the cell. DirectWrite rasterizes into a space of whole
        // pixels with +Y pointing down. We make that space the cell's
        // with Y negated: the pixel in column c and row r covers the
        // cell from c to c + 1 horizontally and from -r - 1 to -r
        // vertically. The two pixel grids coincide, so a fraction of a
        // pixel in the position of the glyph is rasterized as such and
        // nothing has to be split into whole pixels and a remainder here.
        //
        // An outline point (gx, gy) in DirectWrite's glyph space, which
        // also has +Y pointing down, lands at
        //
        //   (gx * scale_x + origin_x, gy * scale_y - origin_y)
        //
        // which is the transform below. The baseline origin given beside
        // the transform is zero so that the result does not depend on
        // which side of the transform it is applied on.
        return .{
            .m11 = @floatCast(p.scale_x),
            .m12 = 0,
            .m21 = 0,
            .m22 = @floatCast(p.scale_y),
            .dx = @floatCast(p.x - rect.x * p.scale_x),
            .dy = @floatCast(-(p.y - rect.y * p.scale_y)),
        };
    }

    /// Whether the atlas holds pixels of this many bytes, else an error.
    fn checkAtlas(atlas: *const font.Atlas, depth: u8) !void {
        if (atlas.format.depth() != depth) {
            log.warn("font atlas color depth doesn't equal font color depth atlas={} font={}", .{
                atlas.format.depth(),
                depth,
            });
            return error.InvalidAtlasFormat;
        }
    }

    /// Draw a glyph from its outline, in grayscale.
    fn renderOutline(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph: u16,
        opts: font.Glyph.RenderOptions,
    ) !font.Glyph {
        // Get the bounding rect for rendering this glyph.
        // This is in a coordinate space with (0.0, 0.0)
        // at the glyph's origin on the baseline and +Y pointing up.
        var gm: [1]api.DWRITE_GLYPH_METRICS = undefined;
        const rect = (try self.designBox(&[_]api.UINT16{glyph}, &gm)) orelse return empty_glyph;

        // If our rect is smaller than a quarter pixel in either axis
        // then it has no outlines or they're too small to render.
        //
        // In this case we just return 0-sized glyph struct.
        if (rect.width < 0.25 or rect.height < 0.25) return empty_glyph;

        // This is just a safety check.
        try checkAtlas(atlas, 1);

        const p = place(rect, opts);
        const matrix = transform(rect, p);

        // The pixels DirectWrite drew on are the glyph. They are not cut
        // to the box above: the ink of a simulated bold or oblique is
        // larger than the metrics of the font say, and the edge of any
        // glyph may touch one more pixel than its box.
        const bitmap = (try self.rasterize(alloc, glyph, matrix)) orelse return empty_glyph;
        defer alloc.free(bitmap.data);

        // Write our rasterized glyph to the atlas.
        const region = try atlas.reserve(alloc, bitmap.width, bitmap.height);
        atlas.set(region, bitmap.data);

        return .{
            .width = bitmap.width,
            .height = bitmap.height,

            // This should be the distance from the left of
            // the cell to the left of the glyph's bounding box.
            .offset_x = bitmap.bounds.left,

            // This should be the distance from the bottom of
            // the cell to the top of the glyph's bounding box.
            // Row zero has its top edge on the bottom of the cell.
            .offset_y = -bitmap.bounds.top,

            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// Draw a color glyph from its layers: each is rasterized as an
    /// outline is, through the transform that places the glyph, and
    /// drawn over the ones before it in its color.
    fn renderLayers(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph: u16,
        opts: font.Glyph.RenderOptions,
    ) !font.Glyph {
        const layers = (try self.colorLayers(alloc, glyph)) orelse return empty_glyph;
        defer alloc.free(layers);
        if (layers.len == 0) return empty_glyph;

        // The glyph's box is the box of its layers together. The base
        // glyph's own outline is not asked, as a COLR font need not have
        // one that covers the layers.
        const glyphs = try alloc.alloc(api.UINT16, layers.len);
        defer alloc.free(glyphs);
        for (glyphs, layers) |*g, layer| g.* = layer.glyph;
        const gm = try alloc.alloc(api.DWRITE_GLYPH_METRICS, layers.len);
        defer alloc.free(gm);
        const rect = (try self.designBox(glyphs, gm)) orelse return empty_glyph;
        if (rect.width < 0.25 or rect.height < 0.25) return empty_glyph;

        try checkAtlas(atlas, 4);

        const p = place(rect, opts);
        const matrix = transform(rect, p);

        // Rasterize every layer. The glyph is the union of their pixels.
        const Raster = struct {
            bitmap: Bitmap,
            color: api.DWRITE_COLOR_F,
        };
        var rasters: std.ArrayList(Raster) = .empty;
        defer {
            for (rasters.items) |r| alloc.free(r.bitmap.data);
            rasters.deinit(alloc);
        }
        var bounds: ?api.RECT = null;
        for (layers) |layer| {
            const bitmap = (try self.rasterize(alloc, layer.glyph, matrix)) orelse continue;
            errdefer alloc.free(bitmap.data);
            try rasters.append(alloc, .{ .bitmap = bitmap, .color = layer.color });
            bounds = if (bounds) |b| .{
                .left = @min(b.left, bitmap.bounds.left),
                .top = @min(b.top, bitmap.bounds.top),
                .right = @max(b.right, bitmap.bounds.right),
                .bottom = @max(b.bottom, bitmap.bounds.bottom),
            } else bitmap.bounds;
        }
        const box = bounds orelse return empty_glyph;
        const width: u32 = @intCast(box.right - box.left);
        const height: u32 = @intCast(box.bottom - box.top);

        const canvas = try alloc.alloc(u8, @as(usize, width) * height * 4);
        defer alloc.free(canvas);
        @memset(canvas, 0);
        for (rasters.items) |r| composite(canvas, width, box, r.bitmap, r.color);

        const region = try atlas.reserve(alloc, width, height);
        atlas.set(region, canvas);

        return .{
            .width = width,
            .height = height,
            .offset_x = box.left,
            .offset_y = -box.top,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// Draw a layer's coverage in its color over the canvas, source
    /// over. The canvas is BGRA, premultiplied, with the bytes sRGB as
    /// the palette's are; the layers of a color font are made for that.
    fn composite(
        canvas: []u8,
        canvas_width: u32,
        canvas_bounds: api.RECT,
        layer: Bitmap,
        color: api.DWRITE_COLOR_F,
    ) void {
        const dx: usize = @intCast(layer.bounds.left - canvas_bounds.left);
        const dy: usize = @intCast(layer.bounds.top - canvas_bounds.top);
        for (0..layer.height) |row| {
            for (0..layer.width) |col| {
                const coverage = layer.data[row * layer.width + col];
                if (coverage == 0) continue;
                const alpha: f32 = color.a * @as(f32, @floatFromInt(coverage)) / 255;
                const src = [4]f32{ color.b * alpha, color.g * alpha, color.r * alpha, alpha };
                const offset = ((dy + row) * canvas_width + dx + col) * 4;
                const dst = canvas[offset..][0..4];
                for (dst, src) |*d, s| {
                    const under: f32 = @as(f32, @floatFromInt(d.*)) / 255;
                    const over = s + under * (1 - alpha);
                    d.* = @intFromFloat(@min(255, @round(over * 255)));
                }
            }
        }
    }

    /// Draw a glyph from an image the font has of it: the image, at the
    /// size the font has nearest to the face's, is scaled to the place
    /// the constraints give the glyph.
    fn renderImage(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph: u16,
        format: api.DWRITE_GLYPH_IMAGE_FORMATS,
        opts: font.Glyph.RenderOptions,
    ) !font.Glyph {
        try checkAtlas(atlas, 4);

        const face4 = api.queryInterface(self.face, api.IDWriteFontFace4) catch
            return error.DirectWriteFailed;
        defer api.release(face4);

        var data: api.DWRITE_GLYPH_IMAGE_DATA = undefined;
        var context: ?*anyopaque = null;
        const ppem: api.UINT32 = @intFromFloat(@round(@max(1, self.size.pixels())));
        const hr = face4.vtable.GetGlyphImageData(face4, glyph, ppem, format, &data, &context);
        if (api.failed(hr)) return fail("IDWriteFontFace4.GetGlyphImageData", hr);
        defer if (context) |c| face4.vtable.ReleaseGlyphImageData(face4, c);

        // A format the glyph does not have comes back as no image at
        // all, and not as an error.
        const image_width = data.pixelSize.width;
        const image_height = data.pixelSize.height;
        const bytes = (data.imageData orelse return empty_glyph)[0..data.imageDataSize];
        if (bytes.len == 0 or data.pixelsPerEm == 0 or image_width == 0 or image_height == 0)
            return empty_glyph;

        // The image as the atlas holds it.
        const image = try decodeImage(alloc, bytes, format, data.pixelSize);
        defer alloc.free(image);

        const rect = imageBox(&data, self.size.pixels());
        const p = place(rect, opts);

        // An image is whole pixels, so its edges go to the nearest ones,
        // as the FreeType face puts a bitmap glyph.
        const left = @round(p.x);
        const right = @round(p.x + p.width);
        const bottom = @round(p.y);
        const top = @round(p.y + p.height);
        if (right <= left or top <= bottom) return empty_glyph;
        const width: u32 = @intFromFloat(right - left);
        const height: u32 = @intFromFloat(top - bottom);

        // Scale the image to its place.
        const scaled = if (width == image_width and height == image_height) image else scaled: {
            const buf = try alloc.alloc(u8, @as(usize, width) * height * 4);
            errdefer alloc.free(buf);
            if (stb.stbir_resize_uint8(
                image.ptr,
                @intCast(image_width),
                @intCast(image_height),
                @intCast(image_width * 4),
                buf.ptr,
                @intCast(width),
                @intCast(height),
                @intCast(width * 4),
                4,
            ) == 0) return error.GlyphResizeFailed;
            break :scaled buf;
        };
        defer if (scaled.ptr != image.ptr) alloc.free(scaled);

        const region = try atlas.reserve(alloc, width, height);
        atlas.set(region, scaled);

        return .{
            .width = width,
            .height = height,
            .offset_x = @intFromFloat(left),
            .offset_y = @intFromFloat(top),
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// The box of an image of a glyph from the glyph's origin, in the
    /// face's pixels, +Y up. The image is made for its own pixels per
    /// em, and its origin is given in its pixels from its top left, +Y
    /// down.
    fn imageBox(data: *const api.DWRITE_GLYPH_IMAGE_DATA, px_per_em: f64) font.Glyph.Size {
        const scale = px_per_em / @as(f64, @floatFromInt(data.pixelsPerEm));
        const width: f64 = @floatFromInt(data.pixelSize.width);
        const height: f64 = @floatFromInt(data.pixelSize.height);
        const origin_x: f64 = @floatFromInt(data.horizontalLeftOrigin.x);
        const origin_y: f64 = @floatFromInt(data.horizontalLeftOrigin.y);
        return .{
            .width = width * scale,
            .height = height * scale,
            .x = -origin_x * scale,
            .y = (origin_y - height) * scale,
        };
    }

    /// An image of a glyph as the atlas holds it: BGRA, premultiplied,
    /// the bytes sRGB, the rows from the top. Owned by the caller.
    fn decodeImage(
        alloc: Allocator,
        bytes: []const u8,
        format: api.DWRITE_GLYPH_IMAGE_FORMATS,
        size: api.D2D1_SIZE_U,
    ) ![]u8 {
        const len = @as(usize, size.width) * size.height * 4;
        switch (format) {
            api.DWRITE_GLYPH_IMAGE_FORMATS_PNG => {
                const png = wuffs.png.decode(alloc, bytes) catch |err| {
                    log.warn("glyph image could not be decoded: {}", .{err});
                    return error.BitmapHandlingError;
                };
                errdefer alloc.free(png.data);
                if (png.width != size.width or png.height != size.height or png.data.len != len) {
                    log.warn(
                        "glyph image is {}x{} where the font says {}x{}",
                        .{ png.width, png.height, size.width, size.height },
                    );
                    return error.BitmapHandlingError;
                }

                // The decoder gives RGBA that is not premultiplied.
                var i: usize = 0;
                while (i < png.data.len) : (i += 4) {
                    const px = png.data[i..][0..4];
                    const alpha = px[3];
                    const r = premultiply(px[0], alpha);
                    const g = premultiply(px[1], alpha);
                    const b = premultiply(px[2], alpha);
                    px[0] = b;
                    px[1] = g;
                    px[2] = r;
                }
                return png.data;
            },

            api.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8 => {
                if (bytes.len != len) {
                    log.warn(
                        "glyph image has {} bytes where {}x{} pixels need {}",
                        .{ bytes.len, size.width, size.height, len },
                    );
                    return error.BitmapHandlingError;
                }
                return try alloc.dupe(u8, bytes);
            },

            else => unreachable,
        }
    }

    /// A channel multiplied by an alpha, rounded.
    fn premultiply(channel: u8, alpha: u8) u8 {
        return @intCast((@as(u32, channel) * alpha + 127) / 255);
    }

    /// The coverage of one rasterized glyph.
    const Bitmap = struct {
        /// One byte per pixel, the rows from the top. The caller frees it.
        data: []u8,
        width: u32,
        height: u32,

        /// The pixels the data covers, in the space of the transform the
        /// glyph was rasterized with.
        bounds: api.RECT,
    };

    /// Rasterize a glyph through a transform: not fitted to the pixel
    /// grid, antialiased in grayscale. Null when the glyph draws on no
    /// pixel.
    fn rasterize(
        self: Face,
        alloc: Allocator,
        glyph: u16,
        matrix: api.DWRITE_MATRIX,
    ) (Allocator.Error || directwrite.Error)!?Bitmap {
        // The factory before Windows 8.1 rasterizes with the glyphs
        // fitted to the pixel grid only, which the metrics are not.
        const factory2 = self.dwrite.factory2 orelse {
            if (!rasterizer_logged.swap(true, .monotonic)) log.err(
                "this version of Windows has no IDWriteFactory2, glyphs cannot be rendered",
                .{},
            );
            return error.DirectWriteFailed;
        };

        const run: api.DWRITE_GLYPH_RUN = .{
            .fontFace = self.face,
            .fontEmSize = self.size.pixels(),
            .glyphCount = 1,
            .glyphIndices = &[_]api.UINT16{glyph},
            .glyphAdvances = &[_]api.FLOAT{0},
            .glyphOffsets = &[_]api.DWRITE_GLYPH_OFFSET{.{
                .advanceOffset = 0,
                .ascenderOffset = 0,
            }},
            .isSideways = 0,
            .bidiLevel = 0,
        };

        var analysis_out: ?*api.IDWriteGlyphRunAnalysis = null;
        const hr = factory2.createGlyphRunAnalysis(
            &run,
            &matrix,
            .NATURAL_SYMMETRIC,
            .NATURAL,
            .DISABLED,
            .GRAYSCALE,
            0,
            0,
            &analysis_out,
        );
        if (api.failed(hr)) return fail("IDWriteFactory2.CreateGlyphRunAnalysis", hr);
        const analysis = analysis_out orelse return error.DirectWriteFailed;
        defer api.release(analysis);

        // An analysis that is antialiased in grayscale has its coverage
        // as one byte per pixel, which is the texture type that is named
        // for aliased text. The coverage is linear: a stem that is moved
        // by a quarter of a pixel has 191 and 64 where it had 255 and 0.
        const texture: api.DWRITE_TEXTURE_TYPE = .ALIASED_1x1;
        var bounds: api.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const bounds_hr = analysis.vtable.GetAlphaTextureBounds(analysis, texture, &bounds);
        if (api.failed(bounds_hr))
            return fail("IDWriteGlyphRunAnalysis.GetAlphaTextureBounds", bounds_hr);
        if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return null;

        const width: u32 = @intCast(bounds.right - bounds.left);
        const height: u32 = @intCast(bounds.bottom - bounds.top);

        // Our buffer for rendering. We could cache this but glyph
        // rasterization usually stabilizes pretty quickly and is very
        // infrequent so the allocation overhead is acceptable.
        const data = try alloc.alloc(u8, width * height);
        errdefer alloc.free(data);

        const texture_hr = analysis.vtable.CreateAlphaTexture(
            analysis,
            texture,
            &bounds,
            data.ptr,
            @intCast(data.len),
        );
        if (api.failed(texture_hr))
            return fail("IDWriteGlyphRunAnalysis.CreateAlphaTexture", texture_hr);

        return .{
            .data = data,
            .width = width,
            .height = height,
            .bounds = bounds,
        };
    }

    /// The box of the ink of a glyph in design units, from the glyph's
    /// origin on the baseline with +Y pointing up.
    ///
    /// DirectWrite gives a glyph as two advances and the four distances
    /// from the box they span to the ink, positive where the ink is
    /// inside. The top of that box is verticalOriginY above the baseline.
    fn inkBox(gm: api.DWRITE_GLYPH_METRICS) font.Glyph.Size {
        const advance_width: f64 = @floatFromInt(gm.advanceWidth);
        const advance_height: f64 = @floatFromInt(gm.advanceHeight);
        const left: f64 = @floatFromInt(gm.leftSideBearing);
        const right: f64 = @floatFromInt(gm.rightSideBearing);
        const top: f64 = @floatFromInt(gm.topSideBearing);
        const bottom: f64 = @floatFromInt(gm.bottomSideBearing);
        const origin_y: f64 = @floatFromInt(gm.verticalOriginY);
        return .{
            .width = advance_width - left - right,
            .height = advance_height - top - bottom,
            .x = left,
            .y = origin_y - advance_height + bottom,
        };
    }

    /// The design units of an em, which DirectWrite's glyph metrics are
    /// in. Never zero.
    fn unitsPerEm(self: Face) f64 {
        var dm: api.DWRITE_FONT_METRICS = undefined;
        self.face.vtable.GetMetrics(self.face, &dm);
        return @floatFromInt(@max(dm.designUnitsPerEm, 1));
    }

    /// The advances of glyphs in design units, from the face that has
    /// them by themselves (Windows 8 on), else from the glyphs' metrics.
    fn designAdvances(
        self: Face,
        glyphs: []const api.UINT16,
        metrics: []const api.DWRITE_GLYPH_METRICS,
        advances: []api.INT32,
    ) void {
        assert(glyphs.len == metrics.len);
        assert(glyphs.len == advances.len);

        if (api.queryInterface(self.face, api.IDWriteFontFace1)) |face1| {
            defer api.release(face1);
            if (api.succeeded(face1.vtable.GetDesignGlyphAdvances(
                face1,
                @intCast(glyphs.len),
                glyphs.ptr,
                advances.ptr,
                0,
            ))) return;
        } else |_| {}

        for (metrics, advances) |gm, *advance|
            advance.* = std.math.cast(api.INT32, gm.advanceWidth) orelse 0;
    }

    /// A table of the font as DirectWrite has it in memory, which is
    /// valid until it is released.
    const Table = struct {
        data: []const u8,
        context: ?*anyopaque,

        /// Null when the font has no such table, or an empty one.
        fn init(face: *api.IDWriteFontFace, tag: *const [4]u8) ?Table {
            return initTag(face, directwrite.tableTag(tag));
        }

        fn initTag(face: *api.IDWriteFontFace, tag: api.UINT) ?Table {
            var data: ?*const anyopaque = null;
            var size: api.UINT = 0;
            var context: ?*anyopaque = null;
            var exists: api.BOOL = 0;
            if (api.failed(face.vtable.TryGetFontTable(
                face,
                tag,
                &data,
                &size,
                &context,
                &exists,
            ))) return null;
            if (exists == 0) return null;

            const result: Table = .{
                .data = if (data) |ptr|
                    @as([*]const u8, @ptrCast(ptr))[0..size]
                else
                    &.{},
                .context = context,
            };
            if (result.data.len == 0) {
                result.deinit(face);
                return null;
            }
            return result;
        }

        fn deinit(self: Table, face: *api.IDWriteFontFace) void {
            face.vtable.ReleaseFontTable(face, self.context);
        }
    };

    /// Get the `FaceMetrics` for this face.
    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        const face = self.face;

        // Read the 'head' table out of the font data.
        const head_: ?opentype.Head = head: {
            // macOS bitmap-only fonts use a 'bhed' tag rather than 'head', but
            // the table format is byte-identical to the 'head' table, so if we
            // can't find 'head' we try 'bhed' instead before failing.
            //
            // ref: https://fontforge.org/docs/techref/bitmaponlysfnt.html
            const table =
                Table.init(face, "head") orelse
                Table.init(face, "bhed") orelse
                break :head null;
            defer table.deinit(face);
            break :head opentype.Head.init(table.data) catch |err| {
                log.warn("error parsing head table: {}", .{err});
                break :head null;
            };
        };

        // Read the 'post' table out of the font data.
        const post_: ?opentype.Post = post: {
            const table = Table.init(face, "post") orelse break :post null;
            defer table.deinit(face);
            break :post opentype.Post.init(table.data) catch |err| {
                log.warn("error parsing post table: {}", .{err});
                break :post null;
            };
        };

        // Read the 'OS/2' table out of the font data if it's available.
        const os2_: ?opentype.OS2 = os2: {
            const table = Table.init(face, "OS/2") orelse break :os2 null;
            defer table.deinit(face);
            break :os2 opentype.OS2.init(table.data) catch |err| {
                log.warn("error parsing OS/2 table: {}", .{err});
                break :os2 null;
            };
        };

        // Read the 'hhea' table out of the font data.
        const hhea_: ?opentype.Hhea = hhea: {
            const table = Table.init(face, "hhea") orelse break :hhea null;
            defer table.deinit(face);
            break :hhea opentype.Hhea.init(table.data) catch |err| {
                log.warn("error parsing hhea table: {}", .{err});
                break :hhea null;
            };
        };

        // What DirectWrite makes of the font's metrics, in design units.
        // This is the fallback for what the tables don't have.
        var dm: api.DWRITE_FONT_METRICS = undefined;
        face.vtable.GetMetrics(face, &dm);
        const dm_units_per_em: f64 = @floatFromInt(@max(dm.designUnitsPerEm, 1));

        const units_per_em: f64 =
            if (head_) |head|
                @floatFromInt(head.unitsPerEm)
            else
                dm_units_per_em;
        const px_per_em: f64 = self.size.pixels();
        const px_per_unit: f64 = px_per_em / units_per_em;

        // DirectWrite's own metrics and the metrics of its glyphs are in
        // the design units it reports, whatever the 'head' table says.
        const dm_px_per_unit: f64 = px_per_em / dm_units_per_em;

        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            // If we couldn't get the hhea table, rely on metrics from DirectWrite.
            const hhea = hhea_ orelse break :vertical_metrics .{
                @as(f64, @floatFromInt(dm.ascent)) * dm_px_per_unit,
                // The descent is *positive* -> down unlike hhea.Descender.
                -@as(f64, @floatFromInt(dm.descent)) * dm_px_per_unit,
                @as(f64, @floatFromInt(dm.lineGap)) * dm_px_per_unit,
            };

            const hhea_ascent: f64 = @floatFromInt(hhea.ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.lineGap);

            // If our font has no OS/2 table, then we just
            // blindly use the metrics from the hhea table.
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);

            // If the font says to use typo metrics, trust it.
            if (os2.fsSelection.use_typo_metrics) break :vertical_metrics .{
                os2_ascent * px_per_unit,
                os2_descent * px_per_unit,
                os2_line_gap * px_per_unit,
            };

            // Otherwise we prefer the height metrics from 'hhea' if they
            // are available, or else OS/2 sTypo* metrics, and if all else
            // fails then we use OS/2 usWin* metrics.
            //
            // This is not "standard" behavior, but it's our best bet to
            // account for fonts being... just weird. It's pretty much what
            // FreeType does to get its generic ascent and descent metrics.

            if (hhea.ascender != 0 or hhea.descender != 0) break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            if (os2_ascent != 0 or os2_descent != 0) break :vertical_metrics .{
                os2_ascent * px_per_unit,
                os2_descent * px_per_unit,
                os2_line_gap * px_per_unit,
            };

            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                // usWinDescent is *positive* -> down unlike sTypoDescender
                // and hhea.Descender, so we flip its sign to fix this.
                -win_descent * px_per_unit,
                0.0,
            };
        };

        const underline_position, const underline_thickness = ul: {
            const post = post_ orelse break :ul .{ null, null };

            // Some fonts have degenerate 'post' tables where the underline
            // thickness (and often position) are 0. We consider them null
            // if this is the case and use our own fallbacks when we calculate.
            const has_broken_underline = post.underlineThickness == 0;

            // If the underline position isn't 0 then we do use it,
            // even if the thickness is't properly specified.
            const pos: ?f64 = if (has_broken_underline and post.underlinePosition == 0)
                null
            else
                @as(f64, @floatFromInt(post.underlinePosition)) * px_per_unit;

            const thick: ?f64 = if (has_broken_underline)
                null
            else
                @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;

            break :ul .{ pos, thick };
        };

        // Similar logic to the underline above.
        const strikethrough_position, const strikethrough_thickness = st: {
            const os2 = os2_ orelse break :st .{ null, null };

            const has_broken_strikethrough = os2.yStrikeoutSize == 0;

            const pos: ?f64 = if (has_broken_strikethrough and os2.yStrikeoutPosition == 0)
                null
            else
                @as(f64, @floatFromInt(os2.yStrikeoutPosition)) * px_per_unit;

            const thick: ?f64 = if (has_broken_strikethrough)
                null
            else
                @as(f64, @floatFromInt(os2.yStrikeoutSize)) * px_per_unit;

            break :st .{ pos, thick };
        };

        // We fall back to whatever DirectWrite does if the
        // OS/2 table doesn't specify a cap or ex height.
        const cap_height: f64, const ex_height: f64 = heights: {
            const dm_cap_height = @as(f64, @floatFromInt(dm.capHeight)) * dm_px_per_unit;
            const dm_ex_height = @as(f64, @floatFromInt(dm.xHeight)) * dm_px_per_unit;

            const os2 = os2_ orelse break :heights .{
                dm_cap_height,
                dm_ex_height,
            };

            break :heights .{
                if (os2.sCapHeight) |sCapHeight|
                    @as(f64, @floatFromInt(sCapHeight)) * px_per_unit
                else
                    dm_cap_height,

                if (os2.sxHeight) |sxHeight|
                    @as(f64, @floatFromInt(sxHeight)) * px_per_unit
                else
                    dm_ex_height,
            };
        };

        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        //
        // ASCII height is calculated as the height of the overall bounding
        // box of the same characters.
        const cell_width: f64, const ascii_height: f64 = measurements: {
            // Build a comptime array of all the ASCII chars
            const codepoints = comptime codepoints: {
                const len = 127 - 32;
                var result: [len]api.UINT = undefined;
                var i: api.UINT = 32;
                while (i < 127) : (i += 1) {
                    result[i - 32] = i;
                }

                break :codepoints result;
            };

            // Get our glyph IDs for the ASCII chars
            var glyphs: [codepoints.len]api.UINT16 = @splat(0);
            _ = face.vtable.GetGlyphIndices(
                face,
                &codepoints,
                codepoints.len,
                &glyphs,
            );

            // Get the metrics of the glyphs, which have the ink of each
            var gms: [codepoints.len]api.DWRITE_GLYPH_METRICS = undefined;
            if (api.failed(face.vtable.GetDesignGlyphMetrics(
                face,
                &glyphs,
                glyphs.len,
                &gms,
                0,
            ))) {
                log.warn("(getMetrics) GetDesignGlyphMetrics failed", .{});
                @memset(&gms, std.mem.zeroes(api.DWRITE_GLYPH_METRICS));
            }

            // Get all our advances
            var advances: [codepoints.len]api.INT32 = @splat(0);
            self.designAdvances(&glyphs, &gms, &advances);

            // Find the maximum advance
            var max: f64 = 0;
            for (advances) |advance| {
                max = @max(@as(f64, @floatFromInt(advance)), max);
            }

            // Get the overall bounding rect for the glyphs, of which
            // we need the height. A glyph without ink has no part in it.
            var top: f64 = 0;
            var bottom: f64 = 0;
            var any: bool = false;
            for (gms) |gm| {
                const ink = inkBox(gm);
                if (ink.width <= 0 or ink.height <= 0) continue;
                if (!any) {
                    any = true;
                    bottom = ink.y;
                    top = ink.y + ink.height;
                    continue;
                }
                bottom = @min(bottom, ink.y);
                top = @max(top, ink.y + ink.height);
            }

            break :measurements .{
                max * dm_px_per_unit,
                (top - bottom) * dm_px_per_unit,
            };
        };

        // Measure "水" (CJK water ideograph, U+6C34) for our ic width.
        const ic_width: ?f64 = ic_width: {
            const glyph = self.glyphIndex('水') orelse break :ic_width null;
            const glyphs = [_]api.UINT16{@intCast(glyph)};

            var gms: [1]api.DWRITE_GLYPH_METRICS = undefined;
            if (api.failed(face.vtable.GetDesignGlyphMetrics(
                face,
                &glyphs,
                glyphs.len,
                &gms,
                0,
            ))) break :ic_width null;

            var advances: [1]api.INT32 = .{0};
            self.designAdvances(&glyphs, &gms, &advances);

            const advance = @as(f64, @floatFromInt(advances[0])) * dm_px_per_unit;
            const bounds_width = inkBox(gms[0]).width * dm_px_per_unit;

            // If the advance of the glyph is less than the width of the actual
            // glyph then we just treat it as invalid since it's probably wrong
            // and using it for size normalization will instead make the font
            // way too big.
            //
            // This can sometimes happen if there's a CJK font that has been
            // patched with the nerd fonts patcher and it butchers the advance
            // values so the advance ends up half the width of the actual glyph.
            if (bounds_width > advance) {
                var buf: [1024]u8 = undefined;
                const font_name = self.name(&buf) catch "<Error getting font name>";
                log.warn(
                    "(getMetrics) Width of glyph '水' for font \"{s}\" is greater than its advance ({d} > {d}), discarding ic_width metric.",
                    .{
                        font_name,
                        bounds_width,
                        advance,
                    },
                );
                break :ic_width null;
            }

            break :ic_width advance;
        };

        return .{
            .px_per_em = px_per_em,

            .cell_width = cell_width,

            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,

            .underline_position = underline_position,
            .underline_thickness = underline_thickness,

            .strikethrough_position = strikethrough_position,
            .strikethrough_thickness = strikethrough_thickness,

            .cap_height = cap_height,
            .ex_height = ex_height,
            .ascii_height = ascii_height,
            .ic_width = ic_width,
        };
    }

    /// Copy the font table data for the given tag.
    pub fn copyTable(
        self: Face,
        alloc: Allocator,
        tag: *const [4]u8,
    ) Allocator.Error!?[]u8 {
        const table = Table.init(self.face, tag) orelse return null;
        defer table.deinit(self.face);
        return try alloc.dupe(u8, table.data);
    }

    /// The HarfBuzz font of a DirectWrite face at a size: a font over
    /// the face's tables, with the variations the face is an instance of.
    ///
    /// This is what hb-directwrite.cc does, which the HarfBuzz we build
    /// does not have.
    fn createHbFont(
        face: *api.IDWriteFontFace,
        size: font.face.DesiredSize,
    ) !harfbuzz.Font {
        // The HarfBuzz face has a reference of its own to the DirectWrite
        // face, which it gives back when it is destroyed. HarfBuzz does
        // that itself where the creation fails, so there is no errdefer.
        api.addRef(face);
        var hb_face = try harfbuzz.Face.createForTables(
            api.IDWriteFontFace,
            HbTable.reference,
            face,
            HbTable.releaseFace,
        );
        // The font keeps the face.
        defer hb_face.destroy();
        hb_face.setIndex(face.vtable.GetIndex(face));
        hb_face.setGlyphCount(face.vtable.GetGlyphCount(face));

        var hb_font = try harfbuzz.Font.create(hb_face);
        errdefer hb_font.destroy();
        setScale(&hb_font, size);

        // HarfBuzz has to shape the instance that DirectWrite draws. It
        // knows the axes from the tables and the values from here.
        variations: {
            const face5 = api.queryInterface(face, api.IDWriteFontFace5) catch
                break :variations;
            defer api.release(face5);
            var axes_buf: [max_axes]api.DWRITE_FONT_AXIS_VALUE = undefined;
            const axes = axisValues(face5, &axes_buf) orelse break :variations;
            if (axes.len == 0) break :variations;

            var variations: [max_axes]harfbuzz.Variation = undefined;
            for (axes, variations[0..axes.len]) |axis, *v| v.* = .{
                // HarfBuzz has the first character of a tag in the high
                // byte, DirectWrite in the low one.
                .tag = @byteSwap(axis.axisTag),
                .value = axis.value,
            };
            hb_font.setVariations(variations[0..axes.len]);
        }

        return hb_font;
    }

    /// HarfBuzz positions are 26.6 fixed point pixels.
    fn setScale(hb_font: *harfbuzz.Font, size: font.face.DesiredSize) void {
        const pixels: opentype.sfnt.F26Dot6 = .from(size.pixels());
        hb_font.setScale(@bitCast(pixels), @bitCast(pixels));
    }

    /// A table of the font that HarfBuzz holds, for as long as HarfBuzz
    /// wants it: that can be longer than the HarfBuzz font lives and
    /// longer than the `Face` does, and the `Face` is a value that moves.
    /// So a table that is lent to HarfBuzz depends on neither. It has a
    /// reference of its own to the DirectWrite face it is released
    /// through, and it is allocated with an allocator of the process
    /// since no allocator of a caller is known to outlive it.
    const HbTable = struct {
        face: *api.IDWriteFontFace,
        table: Table,

        const alloc = std.heap.smp_allocator;

        fn reference(
            _: harfbuzz.Face,
            tag: u32,
            face_: ?*api.IDWriteFontFace,
        ) ?harfbuzz.Blob {
            const face = face_ orelse return null;

            // HarfBuzz has the first character of a tag in the high
            // byte, DirectWrite in the low one.
            const table = Table.initTag(face, @byteSwap(tag)) orelse return null;
            const self = alloc.create(HbTable) catch {
                table.deinit(face);
                return null;
            };
            api.addRef(face);
            self.* = .{ .face = face, .table = table };

            // Where this fails HarfBuzz has released the table already.
            return harfbuzz.Blob.createWithDestroy(
                HbTable,
                table.data,
                .readonly,
                self,
                release,
            ) catch null;
        }

        fn release(self_: ?*HbTable) callconv(.c) void {
            const self = self_ orelse return;
            self.table.deinit(self.face);
            api.release(self.face);
            alloc.destroy(self);
        }

        fn releaseFace(face: ?*api.IDWriteFontFace) callconv(.c) void {
            if (face) |v| api.release(v);
        }
    };

    /// Log the call that failed and return the error for it.
    fn fail(comptime call: []const u8, hr: api.HRESULT) directwrite.Error {
        log.err(call ++ " failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectWriteFailed;
    }
};

// The tests below call DirectWrite and so only run on Windows. They are
// compiled with this file, which is when this face is the backend's.

/// The size that the reference metrics in Glyph.zig were taken at.
const test_size: font.face.DesiredSize = .{ .points = 12, .xdpi = 96, .ydpi = 96 };

/// Render every visible ASCII character of a face, as a font that can
/// not do that is not a font to us.
fn testRenderAscii(face: *Face) !void {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    const metrics = font.Metrics.calc(face.getMetrics());

    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        const glyph_index = face.glyphIndex(i) orelse {
            std.debug.print("no glyph for '{c}' (0x{x})\n", .{ i, i });
            return error.TestUnexpectedResult;
        };
        const glyph = face.renderGlyph(
            alloc,
            &atlas,
            glyph_index,
            .{ .grid_metrics = metrics },
        ) catch |err| {
            std.debug.print("rendering '{c}' (0x{x}) glyph={} failed: {}\n", .{
                i,
                i,
                glyph_index,
                err,
            });
            return err;
        };

        // Everything but the space has ink.
        if (i != ' ' and (glyph.width == 0 or glyph.height == 0)) {
            std.debug.print("'{c}' (0x{x}) glyph={} rendered empty\n", .{
                i,
                i,
                glyph_index,
            });
            return error.TestUnexpectedResult;
        }
    }
}

/// The coverage of a rendered glyph summed over its pixels.
fn testCoverage(atlas: *const font.Atlas, glyph: font.Glyph) u64 {
    var sum: u64 = 0;
    for (0..glyph.height) |row| {
        const start = (glyph.atlas_y + row) * atlas.size + glyph.atlas_x;
        for (atlas.data[start..][0..glyph.width]) |v| sum += v;
    }
    return sum;
}

/// The value that the HarfBuzz font of a face has on an axis of its
/// font. HarfBuzz has the values in the order of the axes in the fvar
/// table and nothing to find an axis by in what we build of it, so the
/// table is read here.
fn testHbCoordinate(alloc: Allocator, face: *const Face, tag: *const [4]u8) !f32 {
    const fvar = (try face.copyTable(alloc, "fvar")) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(fvar);
    if (fvar.len < 16) return error.TestUnexpectedResult;

    const offset: usize = std.mem.readInt(u16, fvar[4..6], .big);
    const count: usize = std.mem.readInt(u16, fvar[8..10], .big);
    const size: usize = std.mem.readInt(u16, fvar[10..12], .big);
    const index = for (0..count) |i| {
        const at = offset + i * size;
        if (at + 4 > fvar.len) return error.TestUnexpectedResult;
        if (std.mem.eql(u8, fvar[at..][0..4], tag)) break i;
    } else return error.TestUnexpectedResult;

    var len: c_uint = 0;
    const coords = harfbuzz.c.hb_font_get_var_coords_design(face.hb_font.handle, &len);
    if (index >= len) {
        std.debug.print("the HarfBuzz font has {} coordinates, none for axis {} ({s})\n", .{
            len,
            index,
            tag,
        });
        return error.TestUnexpectedResult;
    }
    return coords[index];
}

/// The pixel in a column and a row of a rendered glyph, the rows from
/// the top.
fn testPixel(atlas: *const font.Atlas, glyph: font.Glyph, col: usize, row: usize) u8 {
    return atlas.data[(glyph.atlas_y + row) * atlas.size + glyph.atlas_x + col];
}

test "in-memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    try testRenderAscii(&face);
}

test "variable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    try testRenderAscii(&face);
}

test "variable set variation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    try face.setVariations(&.{
        .{ .id = font.face.Variation.Id.init("wght"), .value = 400 },
    }, .{ .size = .{ .points = 12 } });

    try testRenderAscii(&face);
}

test "variable weight changes the ink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    // Where DirectWrite has no variable fonts the variation is ignored,
    // and there is nothing to compare.
    const opts: font.face.Options = .{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } };
    var face = try Face.init(lib, testFont, opts);
    defer face.deinit();
    if (api.queryInterface(face.face, api.IDWriteFontFace5)) |face5| {
        api.release(face5);
    } else |_| return error.SkipZigTest;

    const metrics = font.Metrics.calc(face.getMetrics());
    const glyph_index = face.glyphIndex('I').?;

    try face.setVariations(&.{
        .{ .id = font.face.Variation.Id.init("wght"), .value = 100 },
    }, opts);
    const thin = try face.renderGlyph(alloc, &atlas, glyph_index, .{ .grid_metrics = metrics });
    const thin_coverage = testCoverage(&atlas, thin);

    try face.setVariations(&.{
        .{ .id = font.face.Variation.Id.init("wght"), .value = 800 },
    }, opts);
    const heavy = try face.renderGlyph(alloc, &atlas, glyph_index, .{ .grid_metrics = metrics });
    const heavy_coverage = testCoverage(&atlas, heavy);

    if (heavy_coverage <= thin_coverage) {
        std.debug.print(
            "wght 800 has no more ink than wght 100: coverage {} against {}\n",
            .{ heavy_coverage, thin_coverage },
        );
        return error.TestUnexpectedResult;
    }
}

test "name" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    {
        var face = try Face.init(lib, font.embedded.variable, .{ .size = .{ .points = 12 } });
        defer face.deinit();

        var buf: [1024]u8 = undefined;
        const font_name = try face.name(&buf);
        try testing.expectEqualStrings("JetBrains Mono", font_name);
    }

    {
        var face = try Face.init(lib, font.embedded.inconsolata, .{ .size = .{ .points = 12 } });
        defer face.deinit();

        var buf: [1024]u8 = undefined;
        const font_name = try face.name(&buf);
        try testing.expectEqualStrings("Inconsolata", font_name);
    }
}

test "svg font table" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    const table = (try face.copyTable(alloc, "SVG ")) orelse {
        std.debug.print("julia_mono has no SVG table through DirectWrite\n", .{});
        return error.TestUnexpectedResult;
    };
    defer alloc.free(table);

    // It is the table of the file, all of it: the directory of the file
    // has where it is and how long.
    const want = want: {
        const count = std.mem.readInt(u16, testFont[4..6], .big);
        for (0..count) |i| {
            const record = testFont[12 + 16 * i ..][0..16];
            if (!std.mem.eql(u8, record[0..4], "SVG ")) continue;
            const offset = std.mem.readInt(u32, record[8..12], .big);
            const len = std.mem.readInt(u32, record[12..16], .big);
            break :want testFont[offset..][0..len];
        }
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualSlices(u8, want, table);

    // A table the font does not have is not an error.
    try testing.expect(try face.copyTable(alloc, "zzzz") == null);
}

test "glyphIndex" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    const glyph = face.glyphIndex('A').?;
    try testing.expectEqual(4, glyph);

    // The font has an SVG table, which DirectWrite counts as color, as
    // CoreText does. An SVG glyph is not drawn here, so no glyph of the
    // font is a color one, as with FreeType.
    try testing.expect(face.hasColor());
    try testing.expect(!face.isColorGlyph(glyph));
    const svg = face.glyphIndex(0xE800).?;
    try testing.expectEqual(11482, svg);
    try testing.expect(!face.isColorGlyph(svg));

    // Outside the basic plane, and not in this font or any other.
    try testing.expect(face.glyphIndex(0x10FFFF) == null);
}

test "emoji fonts load" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // The fonts that are loaded when the application starts, which does
    // not start without them. The color one has its glyphs as bitmaps
    // and no outlines at all.
    inline for (.{ "emoji", "emoji_text" }) |field| {
        var face = Face.init(
            lib,
            @field(font.embedded, field),
            .{ .size = .{ .points = 12 } },
        ) catch |err| {
            std.debug.print("font.embedded." ++ field ++ " does not load: {}\n", .{err});
            return err;
        };
        defer face.deinit();

        const glyph = face.glyphIndex(0x1F600);
        const metrics = face.getMetrics();
        errdefer std.debug.print(
            "font.embedded." ++ field ++ ": glyph of U+1F600={?} cell_width={d} ascent={d} descent={d}\n",
            .{ glyph, metrics.cell_width, metrics.ascent, metrics.descent },
        );
        try testing.expect(glyph != null);
    }
}

test "metrics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    // The reference is what the CoreText face measures the same font as
    // at the same size, in every field: the two read the same tables,
    // and neither fits a glyph to the pixel grid. The font has no
    // ideograph to take a width from.
    const face_metrics = face.getMetrics();
    const metrics = font.Metrics.calc(face_metrics);
    errdefer std.debug.print(
        "face metrics: {}\ncell={}x{} baseline={} face_width={d} face_height={d} face_y={d}\n",
        .{
            face_metrics,
            metrics.cell_width,
            metrics.cell_height,
            metrics.cell_baseline,
            metrics.face_width,
            metrics.face_height,
            metrics.face_y,
        },
    );

    try testing.expectEqual(16, face_metrics.px_per_em);
    try testing.expectApproxEqAbs(9.6, face_metrics.cell_width, 0.0001);
    try testing.expectApproxEqAbs(16.32, face_metrics.ascent, 0.0001);
    try testing.expectApproxEqAbs(-4.8, face_metrics.descent, 0.0001);
    try testing.expectApproxEqAbs(0, face_metrics.line_gap, 0.0001);
    try testing.expectApproxEqAbs(-2.48, face_metrics.underline_position.?, 0.0001);
    try testing.expectApproxEqAbs(0.8, face_metrics.underline_thickness.?, 0.0001);
    try testing.expectApproxEqAbs(5.12, face_metrics.strikethrough_position.?, 0.0001);
    try testing.expectApproxEqAbs(0.8, face_metrics.strikethrough_thickness.?, 0.0001);
    try testing.expectApproxEqAbs(11.68, face_metrics.cap_height.?, 0.0001);
    try testing.expectApproxEqAbs(8.8, face_metrics.ex_height.?, 0.0001);
    try testing.expectApproxEqAbs(16.8, face_metrics.ascii_height.?, 0.0001);
    try testing.expectEqual(null, face_metrics.ic_width);
    try testing.expectEqual(10, metrics.cell_width);
    try testing.expectEqual(21, metrics.cell_height);
    try testing.expectEqual(5, metrics.cell_baseline);
    try testing.expectApproxEqAbs(9.6, metrics.face_width, 0.0001);
    try testing.expectApproxEqAbs(21.12, metrics.face_height, 0.0001);
    try testing.expectApproxEqAbs(0.2, metrics.face_y, 0.0001);

    // The ink of the ASCII characters is taller than a capital and no
    // taller than two ems, whatever the font.
    const ascii_height = face_metrics.ascii_height.?;
    try testing.expect(ascii_height > face_metrics.cap_height.?);
    try testing.expect(ascii_height < 2 * face_metrics.px_per_em);

    // A size is a scale and nothing else.
    try face.setSize(.{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } });
    const doubled = face.getMetrics();
    try testing.expectApproxEqAbs(2 * face_metrics.cell_width, doubled.cell_width, 0.0001);
    try testing.expectApproxEqAbs(2 * face_metrics.ascent, doubled.ascent, 0.0001);
    try testing.expectApproxEqAbs(2 * ascii_height, doubled.ascii_height.?, 0.0001);
}

test "glyph within the cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    const metrics = font.Metrics.calc(face.getMetrics());
    const glyph = try face.renderGlyph(
        alloc,
        &atlas,
        face.glyphIndex('A').?,
        .{ .grid_metrics = metrics },
    );
    const coverage = testCoverage(&atlas, glyph);
    errdefer std.debug.print(
        "'A': {}x{} offset_x={} offset_y={} coverage={} in a cell of {}x{} baseline={}\n",
        .{
            glyph.width,
            glyph.height,
            glyph.offset_x,
            glyph.offset_y,
            coverage,
            metrics.cell_width,
            metrics.cell_height,
            metrics.cell_baseline,
        },
    );

    // Not empty, and with ink on it.
    try testing.expect(glyph.width > 0);
    try testing.expect(glyph.height > 0);
    try testing.expect(coverage > 0);

    // Inside the cell, all of it.
    const cell_width: i32 = @intCast(metrics.cell_width);
    const cell_height: i32 = @intCast(metrics.cell_height);
    const width: i32 = @intCast(glyph.width);
    const height: i32 = @intCast(glyph.height);
    try testing.expect(glyph.offset_x >= 0);
    try testing.expect(glyph.offset_x + width <= cell_width);
    try testing.expect(glyph.offset_y <= cell_height);
    try testing.expect(glyph.offset_y - height >= 0);

    // An 'A' stands on the baseline and is as tall as a capital, to the
    // pixel that the edges of the ink may spill into. This is what tells
    // a glyph that is upside down or off by the baseline from one that
    // is not.
    const baseline: i32 = @intCast(metrics.cell_baseline);
    const cap_height: i32 = @intFromFloat(@round(face.getMetrics().cap_height.?));
    try testing.expect(@abs((glyph.offset_y - height) - baseline) <= 1);
    try testing.expect(@abs(height - cap_height) <= 2);

    // The ink of an 'A' is at its foot and not at its head: the lower
    // half has the two legs and the bar, the upper half the apex.
    var upper: u64 = 0;
    var lower: u64 = 0;
    for (0..glyph.height) |row| {
        const start = (glyph.atlas_y + row) * atlas.size + glyph.atlas_x;
        for (atlas.data[start..][0..glyph.width]) |v| {
            if (row < glyph.height / 2) upper += v else lower += v;
        }
    }
    if (lower <= upper) {
        std.debug.print("'A' has its ink at the top: upper={} lower={}\n", .{ upper, lower });
        return error.TestUnexpectedResult;
    }
}

test "variations of a font that has none" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    // The face stays the one it is, and is not made again for nothing.
    const before = face.face;
    try face.setVariations(
        &.{.{ .id = font.face.Variation.Id.init("wght"), .value = 700 }},
        .{ .size = test_size },
    );
    try testing.expectEqual(before, face.face);
}

test "synthetic italic of a variation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    const opts: font.face.Options = .{ .size = test_size };
    var face = try Face.init(lib, testFont, opts);
    defer face.deinit();
    try face.setVariations(
        &.{.{ .id = font.face.Variation.Id.init("wght"), .value = 700 }},
        opts,
    );

    // The slanted face is of the weight that was set, not of the weight
    // the file has by default.
    var italic = try face.syntheticItalic(opts);
    defer italic.deinit();
    try testing.expectEqual(api.DWRITE_FONT_SIMULATIONS_OBLIQUE, italic.simulations);

    const face5 = try api.queryInterface(italic.face, api.IDWriteFontFace5);
    defer api.release(face5);
    var axes_buf: [Face.max_axes]api.DWRITE_FONT_AXIS_VALUE = undefined;
    const axes = Face.axisValues(face5, &axes_buf) orelse
        return error.TestUnexpectedResult;
    var found = false;
    for (axes) |axis| {
        if (axis.axisTag != api.DWRITE_FONT_AXIS_TAG_WEIGHT) continue;
        try testing.expectEqual(700, axis.value);
        found = true;
    }
    try testing.expect(found);

    // And it is slanted, by what DirectWrite says of the face it made
    // and by what it draws: the font's resource makes the face of a
    // variable font, not the factory that makes the others.
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_OBLIQUE,
        italic.face.vtable.GetSimulations(italic.face),
    );

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    const metrics = font.Metrics.calc(face.getMetrics());
    const glyph_index = face.glyphIndex('|').?;
    const upright = try face.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );
    const slanted = try italic.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );
    errdefer std.debug.print("upright '|': {}x{}, slanted '|': {}x{}\n", .{
        upright.width,
        upright.height,
        slanted.width,
        slanted.height,
    });
    try testing.expect(slanted.width > upright.width);
}

test "harfbuzz font has the variations of the face" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // Where DirectWrite has no variable fonts the variation is ignored,
    // and there is nothing to compare.
    const opts: font.face.Options = .{ .size = test_size };
    var face = try Face.init(lib, testFont, opts);
    defer face.deinit();
    if (api.queryInterface(face.face, api.IDWriteFontFace5)) |face5| {
        api.release(face5);
    } else |_| return error.SkipZigTest;

    // HarfBuzz shapes the instance that DirectWrite draws. It ignores an
    // axis it does not find in the font without a word, so a value that
    // reaches it under a wrong tag shows only as a coordinate left at
    // its default. Two weights, neither of them the one the file has by
    // default.
    for ([_]f32{ 100, 700 }) |weight| {
        try face.setVariations(
            &.{.{ .id = font.face.Variation.Id.init("wght"), .value = weight }},
            opts,
        );
        try testing.expectEqual(weight, try testHbCoordinate(alloc, &face, "wght"));
    }

    // A simulated face has a HarfBuzz font of its own.
    var italic = try face.syntheticItalic(opts);
    defer italic.deinit();
    try testing.expectEqual(700, try testHbCoordinate(alloc, &italic, "wght"));
}

test "glyph boxes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    // Where the CoreText face puts the same glyphs of the same font at
    // the same size, and how large: a capital, a descender, a glyph that
    // is as tall as the font has them, one that reaches below the
    // baseline from above it, and two whose ink is not in the middle of
    // their advance.
    //
    // CoreText's box is every pixel the outline touches. DirectWrite's
    // is every pixel it put ink on, and it samples a pixel four times
    // across: a pixel that the outline covers an eighth of or less has
    // none. So its box is CoreText's or that less a pixel at an edge,
    // as it is for the 'I'. Where we put it, 0.2 pixels into the cell,
    // its serifs reach 0.12 pixels into a column at either side, and
    // the column at the left has no ink while the one at the right
    // has: DirectWrite draws a glyph at the quarter of a pixel above
    // where it is put, and there they reach 0.07 pixels at the left
    // and 0.17 at the right.
    // The last four numbers are the pixels that DirectWrite's box is
    // within CoreText's by at the left, the right, the top and the
    // bottom, as measured.
    const metrics = font.Metrics.calc(face.getMetrics());
    var failed = false;
    for ([_]struct { u8, i32, i32, i32, i32, [4]i32 }{
        .{ 'A', 8, 12, 1, 17, .{ 0, 0, 0, 0 } },
        .{ 'g', 8, 12, 1, 14, .{ 0, 0, 0, 0 } },
        .{ 'j', 7, 16, 1, 18, .{ 0, 0, 0, 0 } },
        .{ 'Q', 8, 15, 1, 17, .{ 0, 0, 0, 0 } },
        .{ 'I', 8, 12, 1, 17, .{ 1, 0, 0, 0 } },
        .{ 'l', 9, 12, 0, 17, .{ 0, 0, 0, 0 } },
    }) |want| {
        const char, const width, const height, const offset_x, const offset_y, const insets = want;
        const glyph = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(char).?,
            .{ .grid_metrics = metrics },
        );

        // The edges of the two boxes, from the bottom left of the cell.
        const left = glyph.offset_x - offset_x;
        const right = (offset_x + width) -
            (glyph.offset_x + @as(i32, @intCast(glyph.width)));
        const top = offset_y - glyph.offset_y;
        const bottom = (glyph.offset_y - @as(i32, @intCast(glyph.height))) -
            (offset_y - height);
        if (!std.mem.eql(i32, &insets, &.{ left, right, top, bottom })) {
            std.debug.print("'{c}': {}x{} offset=({},{}), CoreText has {}x{} offset=({},{})" ++
                " and the insets are expected as {any}\n", .{
                char,
                glyph.width,
                glyph.height,
                glyph.offset_x,
                glyph.offset_y,
                width,
                height,
                offset_x,
                offset_y,
                insets,
            });
            failed = true;
        }
    }
    try testing.expect(!failed);
}

test "synthetic bold" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    const opts: font.face.Options = .{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } };
    var regular = try Face.init(lib, testFont, opts);
    defer regular.deinit();
    var bold = try regular.syntheticBold(opts);
    defer bold.deinit();

    // The regular face is left alone. What a face was made with is what
    // DirectWrite says of it, and not only what we noted.
    try testing.expectEqual(api.DWRITE_FONT_SIMULATIONS_NONE, regular.simulations);
    try testing.expectEqual(api.DWRITE_FONT_SIMULATIONS_BOLD, bold.simulations);
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_NONE,
        regular.face.vtable.GetSimulations(regular.face),
    );
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_BOLD,
        bold.face.vtable.GetSimulations(bold.face),
    );
    try testing.expect(regular.face != bold.face);

    // Both are drawn in the same cell, that of the regular face.
    const metrics = font.Metrics.calc(regular.getMetrics());
    const glyph_index = regular.glyphIndex('I').?;
    try testing.expectEqual(glyph_index, bold.glyphIndex('I').?);

    const regular_glyph = try regular.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );
    const bold_glyph = try bold.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );
    const regular_coverage = testCoverage(&atlas, regular_glyph);
    const bold_coverage = testCoverage(&atlas, bold_glyph);
    errdefer std.debug.print(
        "regular 'I': {}x{} coverage={}, bold 'I': {}x{} coverage={}\n",
        .{
            regular_glyph.width,
            regular_glyph.height,
            regular_coverage,
            bold_glyph.width,
            bold_glyph.height,
            bold_coverage,
        },
    );

    // More ink, and no narrower for it.
    try testing.expect(bold_coverage > regular_coverage);
    try testing.expect(bold_glyph.width >= regular_glyph.width);
}

test "synthetic italic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    const opts: font.face.Options = .{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } };
    var regular = try Face.init(lib, testFont, opts);
    defer regular.deinit();
    var italic = try regular.syntheticItalic(opts);
    defer italic.deinit();
    try testing.expectEqual(api.DWRITE_FONT_SIMULATIONS_OBLIQUE, italic.simulations);
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_OBLIQUE,
        italic.face.vtable.GetSimulations(italic.face),
    );

    // The two simulations add up.
    var bold_italic = try italic.syntheticBold(opts);
    defer bold_italic.deinit();
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_OBLIQUE | api.DWRITE_FONT_SIMULATIONS_BOLD,
        bold_italic.simulations,
    );
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_OBLIQUE | api.DWRITE_FONT_SIMULATIONS_BOLD,
        bold_italic.face.vtable.GetSimulations(bold_italic.face),
    );

    // A bar, which is a stem and nothing else. A letter will not do: the
    // 'l' of this font has a serif to the left of its head and a tail
    // to the right of its foot, and gets narrower as it leans.
    const metrics = font.Metrics.calc(regular.getMetrics());
    const glyph_index = regular.glyphIndex('|').?;
    const regular_glyph = try regular.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );
    const italic_glyph = try italic.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );

    // A slanted stem covers more columns than an upright one, and none
    // of it is cut off: the ink is as much as it was, to the rounding of
    // the edges.
    const regular_coverage = testCoverage(&atlas, regular_glyph);
    const italic_coverage = testCoverage(&atlas, italic_glyph);
    errdefer std.debug.print(
        "regular '|': {}x{} coverage={}, italic '|': {}x{} coverage={}\n",
        .{
            regular_glyph.width,
            regular_glyph.height,
            regular_coverage,
            italic_glyph.width,
            italic_glyph.height,
            italic_coverage,
        },
    );
    try testing.expect(italic_glyph.width > regular_glyph.width);
    try testing.expect(italic_coverage * 10 >= regular_coverage * 9);

    // The face with both leans as the slanted one does and has more ink.
    const bold_italic_glyph = try bold_italic.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = metrics },
    );
    const bold_italic_coverage = testCoverage(&atlas, bold_italic_glyph);
    errdefer std.debug.print("bold italic '|': {}x{} coverage={}\n", .{
        bold_italic_glyph.width,
        bold_italic_glyph.height,
        bold_italic_coverage,
    });
    try testing.expect(bold_italic_glyph.width > regular_glyph.width);
    try testing.expect(bold_italic_coverage > italic_coverage);
}

test "discovered font that is simulated" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // Lucida Console has one weight, and DirectWrite has a bold of it
    // among the fonts of the family that is the regular one simulated.
    const collection = try lib.dwrite.systemFonts();
    defer api.release(collection);
    var index: api.UINT = 0;
    var exists: api.BOOL = 0;
    const family_name = std.unicode.utf8ToUtf16LeStringLiteral("Lucida Console");
    try testing.expect(api.succeeded(collection.vtable.FindFamilyName(
        collection,
        family_name,
        &index,
        &exists,
    )));
    if (exists == 0) return error.SkipZigTest;

    var family_out: ?*api.IDWriteFontFamily = null;
    try testing.expect(api.succeeded(collection.vtable.GetFontFamily(
        collection,
        index,
        &family_out,
    )));
    const family = family_out.?;
    defer api.release(family);

    const list = family.fontList();
    const dw_font = for (0..list.vtable.GetFontCount(list)) |i| {
        var font_out: ?*api.IDWriteFont = null;
        try testing.expect(api.succeeded(list.vtable.GetFont(list, @intCast(i), &font_out)));
        const candidate = font_out.?;
        if (candidate.vtable.GetSimulations(candidate) == api.DWRITE_FONT_SIMULATIONS_BOLD)
            break candidate;
        api.release(candidate);
    } else return error.SkipZigTest;
    defer api.release(dw_font);

    // The face is the simulated one, and a face that is made of it is
    // made with the simulation it has.
    const opts: font.face.Options = .{ .size = test_size };
    var face = try Face.initFont(lib, dw_font, opts);
    defer face.deinit();
    try testing.expectEqual(api.DWRITE_FONT_SIMULATIONS_BOLD, face.simulations);
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_BOLD,
        face.face.vtable.GetSimulations(face.face),
    );

    var italic = try face.syntheticItalic(opts);
    defer italic.deinit();
    try testing.expectEqual(
        api.DWRITE_FONT_SIMULATIONS_BOLD | api.DWRITE_FONT_SIMULATIONS_OBLIQUE,
        italic.face.vtable.GetSimulations(italic.face),
    );
}

test "discovered font" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    // Consolas ships with every Windows this runs on.
    const collection = try lib.dwrite.systemFonts();
    defer api.release(collection);
    var index: api.UINT = 0;
    var exists: api.BOOL = 0;
    const family_name = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    try testing.expect(api.succeeded(collection.vtable.FindFamilyName(
        collection,
        family_name,
        &index,
        &exists,
    )));
    if (exists == 0) return error.SkipZigTest;

    var family_out: ?*api.IDWriteFontFamily = null;
    try testing.expect(api.succeeded(collection.vtable.GetFontFamily(
        collection,
        index,
        &family_out,
    )));
    const family = family_out.?;
    defer api.release(family);

    const list = family.fontList();
    var font_out: ?*api.IDWriteFont = null;
    try testing.expect(api.succeeded(list.vtable.GetFont(list, 0, &font_out)));
    const dw_font = font_out.?;
    defer api.release(dw_font);

    var face = try Face.initFont(lib, dw_font, .{ .size = test_size });
    defer face.deinit();

    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings("Consolas", try face.name(&buf));

    const glyph = try face.renderGlyph(
        alloc,
        &atlas,
        face.glyphIndex('A').?,
        .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
    );
    try testing.expect(glyph.width > 0);
    try testing.expect(glyph.height > 0);
    try testing.expect(testCoverage(&atlas, glyph) > 0);
}

test "harfbuzz font" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    // HarfBuzz reads the font through the tables of the face, so it has
    // the glyphs and the advances that DirectWrite has. JetBrains Mono
    // advances by 600 of its 1000 units, 9.6 of the 16 pixels of an em.
    const c = harfbuzz.c;
    var glyph: c.hb_codepoint_t = 0;
    if (c.hb_font_get_nominal_glyph(face.hb_font.handle, 'A', &glyph) == 0) {
        std.debug.print("HarfBuzz finds no glyph for 'A' in the tables of the face\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(face.glyphIndex('A').?, glyph);

    const advance = c.hb_font_get_glyph_h_advance(face.hb_font.handle, glyph);
    const expected: i32 = @intFromFloat(@round(9.6 * 64.0));
    if (@abs(advance - expected) > 1) {
        std.debug.print("HarfBuzz advance of 'A' is {} in 26.6, expected {}\n", .{
            advance,
            expected,
        });
        return error.TestUnexpectedResult;
    }

    // And the scale follows the size.
    try face.setSize(.{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } });
    const doubled = c.hb_font_get_glyph_h_advance(face.hb_font.handle, glyph);
    try testing.expect(@abs(doubled - 2 * expected) <= 1);
}

test "coverage is linear" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // 32 pixels to the em.
    var face = try Face.init(lib, testFont, .{
        .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 },
    });
    defer face.deinit();
    try testing.expectEqual(32, face.size.pixels());

    // The stem of the 'I' of JetBrains Mono is upright and three pixels
    // wide at this size, and halfway up the glyph a row of pixels
    // crosses nothing else. The glyph is put at positions a quarter of a
    // pixel apart, which is as fine as DirectWrite places a glyph: an
    // eighth is drawn as the quarter above it. Where coverage is linear
    // and no curve has been applied to it, each step takes a quarter of
    // 255 from the one edge of the stem and gives it to the other, and
    // the row adds up to the same.
    const glyph: u16 = @intCast(face.glyphIndex('I').?);
    var rows: [4][]u8 = undefined;
    var count: usize = 0;
    defer for (rows[0..count]) |row| alloc.free(row);
    errdefer for (rows[0..count], 0..) |row, step| {
        std.debug.print("dx={d:.2}:", .{@as(f32, @floatFromInt(step)) / 4.0});
        for (row) |v| std.debug.print(" {d:>3}", .{v});
        std.debug.print("\n", .{});
    };

    for (&rows, 0..) |*row, step| {
        const bitmap = (try face.rasterize(alloc, glyph, .{
            .m11 = 1,
            .m12 = 0,
            .m21 = 0,
            .m22 = 1,
            .dx = @as(f32, @floatFromInt(step)) / 4.0,
            .dy = 0,
        })) orelse return error.TestUnexpectedResult;
        defer alloc.free(bitmap.data);

        // The pixels of the row that have ink, and those alone: the
        // bounds begin where DirectWrite pleases.
        const all = bitmap.data[(bitmap.height / 2) * bitmap.width ..][0..bitmap.width];
        const first = std.mem.indexOfNone(u8, all, &.{0}) orelse
            return error.TestUnexpectedResult;
        const last = std.mem.lastIndexOfNone(u8, all, &.{0}).?;
        row.* = try alloc.dupe(u8, all[first .. last + 1]);
        count += 1;
    }

    try testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, rows[0]);
    for ([_][4]i32{
        .{ 191, 255, 255, 64 },
        .{ 128, 255, 255, 128 },
        .{ 64, 255, 255, 191 },
    }, rows[1..]) |want, row| {
        try testing.expectEqual(want.len, row.len);
        for (want, row) |w, v| try testing.expect(@abs(w - @as(i32, v)) <= 1);
    }
}

test "coverage is linear vertically" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // 32 pixels to the em.
    var face = try Face.init(lib, testFont, .{
        .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 },
    });
    defer face.deinit();

    // Text that is not constrained is put at a whole pixel vertically,
    // the baseline, so a glyph that is sized or aligned to its cell is
    // the one that stands at a fraction of one. What holds across holds
    // here. The bar of the hyphen of JetBrains Mono is 2.56 pixels
    // thick at this size and begins 0.16 pixels into a row. Four
    // samples to the pixel find it at three of the four in its first
    // row and in its last, ten in all. Each step down takes a quarter
    // of 255 from its upper edge and gives it to the lower one, and
    // the column adds up to the same.
    const glyph: u16 = @intCast(face.glyphIndex('-').?);
    var columns: [4][]u8 = undefined;
    var count: usize = 0;
    defer for (columns[0..count]) |column| alloc.free(column);
    errdefer for (columns[0..count], 0..) |column, step| {
        std.debug.print("dy={d:.2}:", .{@as(f32, @floatFromInt(step)) / 4.0});
        for (column) |v| std.debug.print(" {d:>3}", .{v});
        std.debug.print("\n", .{});
    };

    for (&columns, 0..) |*column, step| {
        const bitmap = (try face.rasterize(alloc, glyph, .{
            .m11 = 1,
            .m12 = 0,
            .m21 = 0,
            .m22 = 1,
            .dx = 0,
            .dy = @as(f32, @floatFromInt(step)) / 4.0,
        })) orelse return error.TestUnexpectedResult;
        defer alloc.free(bitmap.data);

        // The column through the middle of the bar. The bounds are the
        // rows that have ink.
        column.* = try alloc.alloc(u8, bitmap.height);
        count += 1;
        for (column.*, 0..) |*v, row|
            v.* = bitmap.data[row * bitmap.width + bitmap.width / 2];
    }

    for ([_][]const i32{
        &.{ 191, 255, 191 },
        &.{ 128, 255, 255 },
        &.{ 64, 255, 255, 64 },
        &.{ 255, 255, 128 },
    }, columns) |want, column| {
        try testing.expectEqual(want.len, column.len);
        for (want, column) |w, v| try testing.expect(@abs(w - @as(i32, v)) <= 1);
    }
}

test "constrained glyph" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const getConstraint = @import("../nerd_font_attributes.zig").getConstraint;
    const Constraint = font.Glyph.RenderOptions.Constraint;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    // The cell is that of the text, the glyphs are those of the symbols.
    var text = try Face.init(lib, font.embedded.regular, .{ .size = test_size });
    defer text.deinit();
    const metrics = font.Metrics.calc(text.getMetrics());
    var face = try Face.init(lib, font.embedded.symbols_nerd_font, .{ .size = test_size });
    defer face.deinit();

    // The boxes that the glyphs have in the font are the ones that
    // CoreText measures, which are those of the test of the constraints
    // in Glyph.zig. They are from the bottom of a cell there, which has
    // its baseline five pixels up.
    const reference_baseline = 5;
    const px_per_unit = @as(f64, face.size.pixels()) / face.unitsPerEm();
    for ([_]struct { u21, font.Glyph.Size }{
        .{ 0xE0C0, .{ .width = 16.796875, .height = 16.46875, .x = -0.796875, .y = 1.7109375 } },
        .{ 0xEA61, .{ .width = 9.015625, .height = 13.015625, .x = 3.015625, .y = 3.765625 } },
    }) |want| {
        const cp, const box = want;
        var gm: [1]api.DWRITE_GLYPH_METRICS = undefined;
        try testing.expect(api.succeeded(face.face.vtable.GetDesignGlyphMetrics(
            face.face,
            &[_]api.UINT16{@intCast(face.glyphIndex(cp).?)},
            1,
            &gm,
            0,
        )));
        const ink = Face.inkBox(gm[0]);
        errdefer std.debug.print("U+{X}: ink {d}x{d} at ({d},{d}), CoreText has {d}x{d} at ({d},{d})\n", .{
            cp,
            ink.width * px_per_unit,
            ink.height * px_per_unit,
            ink.x * px_per_unit,
            ink.y * px_per_unit + reference_baseline,
            box.width,
            box.height,
            box.x,
            box.y,
        });
        try testing.expectApproxEqAbs(box.width, ink.width * px_per_unit, 0.01);
        try testing.expectApproxEqAbs(box.height, ink.height * px_per_unit, 0.01);
        try testing.expectApproxEqAbs(box.x, ink.x * px_per_unit, 0.01);
        try testing.expectApproxEqAbs(box.y, ink.y * px_per_unit + reference_baseline, 0.01);
    }

    // A glyph that is stretched is the size of its cells and on their
    // edges, whatever its size and its place in the font: a wedge and a
    // flame of the powerline symbols, in one cell and in two. This is
    // the outline scaled by other than one, and not by the same across
    // and up.
    var failed = false;
    for ([_]u21{ 0xE0B0, 0xE0C0 }) |cp| for ([_]u2{ 1, 2 }) |cells| {
        const constraint = getConstraint(cp).?;
        try testing.expectEqual(.stretch, constraint.size);
        const glyph = try face.renderGlyph(alloc, &atlas, face.glyphIndex(cp).?, .{
            .grid_metrics = metrics,
            .constraint = constraint,
            .constraint_width = cells,
        });

        // The wedge is never wider than a cell. The middle of the left
        // edge is where both are solid.
        const span = @min(cells, constraint.max_constraint_width);
        const edge = testPixel(&atlas, glyph, 0, glyph.height / 2);
        if (glyph.offset_x != 0 or
            glyph.offset_y != metrics.cell_height or
            glyph.width != span * metrics.cell_width or
            glyph.height != metrics.cell_height or
            edge != 255)
        {
            std.debug.print("U+{X} in {} cells of {}x{}: {}x{} offset=({},{}) edge={}\n", .{
                cp,
                cells,
                metrics.cell_width,
                metrics.cell_height,
                glyph.width,
                glyph.height,
                glyph.offset_x,
                glyph.offset_y,
                edge,
            });
            failed = true;
        }
    };

    // A glyph that is sized to fit, with its aspect kept, is where the
    // constraint puts it: the pixels of the box that the constraint
    // gives, or those less one at an edge, as for text.
    for ([_]Constraint{
        getConstraint(0xEA61).?,
        .{ .size = .cover, .align_horizontal = .center, .align_vertical = .center },
    }) |constraint| for ([_]u2{ 1, 2 }) |cells| {
        const index = face.glyphIndex(0xEA61).?;
        var gm: [1]api.DWRITE_GLYPH_METRICS = undefined;
        try testing.expect(api.succeeded(face.face.vtable.GetDesignGlyphMetrics(
            face.face,
            &[_]api.UINT16{@intCast(index)},
            1,
            &gm,
            0,
        )));
        const ink = Face.inkBox(gm[0]);
        const box = constraint.constrain(.{
            .width = ink.width * px_per_unit,
            .height = ink.height * px_per_unit,
            .x = ink.x * px_per_unit,
            .y = ink.y * px_per_unit + @as(f64, @floatFromInt(metrics.cell_baseline)),
        }, metrics, cells);

        // The glyph is centered in a cell that is wider than the face.
        const cell_width: f64 = @floatFromInt(metrics.cell_width);
        const x = box.x + (cell_width - metrics.face_width) / 2;

        const glyph = try face.renderGlyph(alloc, &atlas, index, .{
            .grid_metrics = metrics,
            .constraint = constraint,
            .constraint_width = cells,
        });

        // A box that ends on a pixel to the last bit or so ends there.
        const epsilon = 1e-6;
        const left = glyph.offset_x - @as(i32, @intFromFloat(@floor(x + epsilon)));
        const right = @as(i32, @intFromFloat(@ceil(x + box.width - epsilon))) -
            (glyph.offset_x + @as(i32, @intCast(glyph.width)));
        const top = @as(i32, @intFromFloat(@ceil(box.y + box.height - epsilon))) -
            glyph.offset_y;
        const bottom = (glyph.offset_y - @as(i32, @intCast(glyph.height))) -
            @as(i32, @intFromFloat(@floor(box.y + epsilon)));
        for ([_]i32{ left, right, top, bottom }) |inset| {
            if (inset >= 0 and inset <= 1) continue;
            std.debug.print("U+EA61 {s} in {} cells: {}x{} offset=({},{})," ++
                " the constraint has {d}x{d} at ({d},{d})\n", .{
                @tagName(constraint.size),
                cells,
                glyph.width,
                glyph.height,
                glyph.offset_x,
                glyph.offset_y,
                box.width,
                box.height,
                x,
                box.y,
            });
            failed = true;
            break;
        }
    };
    try testing.expect(!failed);
}

test "stretched bar is the cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    // The bar is a rectangle, so stretched to its cell it is the cell,
    // every pixel of it and each of them whole. Its place in the cell is
    // at a fraction of a pixel both ways before it is stretched, and
    // what it is scaled by is not the same across and up. A row or a
    // column at an edge that is less than whole is what shows as a seam
    // between two cells.
    const metrics = font.Metrics.calc(face.getMetrics());
    const glyph = try face.renderGlyph(alloc, &atlas, face.glyphIndex('|').?, .{
        .grid_metrics = metrics,
        .constraint = .{ .size = .stretch },
    });
    errdefer {
        std.debug.print("'|' stretched to {}x{}: {}x{} offset=({},{})\n", .{
            metrics.cell_width,
            metrics.cell_height,
            glyph.width,
            glyph.height,
            glyph.offset_x,
            glyph.offset_y,
        });
        for (0..glyph.height) |row| {
            for (0..glyph.width) |col| std.debug.print(" {d:>3}", .{
                testPixel(&atlas, glyph, col, row),
            });
            std.debug.print("\n", .{});
        }
    }

    try testing.expectEqual(0, glyph.offset_x);
    try testing.expectEqual(@as(i32, @intCast(metrics.cell_height)), glyph.offset_y);
    try testing.expectEqual(metrics.cell_width, glyph.width);
    try testing.expectEqual(metrics.cell_height, glyph.height);
    for (0..glyph.height) |row| for (0..glyph.width) |col| {
        try testing.expectEqual(255, testPixel(&atlas, glyph, col, row));
    };
}

test "atlas of another depth" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // Coverage is a byte to the pixel. An atlas that has four is not
    // written to: what is copied is as many bytes as the atlas has to
    // the pixel.
    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    const modified = atlas.modified.load(.monotonic);
    try testing.expectError(error.InvalidAtlasFormat, face.renderGlyph(
        alloc,
        &atlas,
        face.glyphIndex('A').?,
        .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
    ));
    try testing.expectEqual(modified, atlas.modified.load(.monotonic));

    // Nor is room taken in it: what is reserved next is the first
    // region of the atlas.
    const region = try atlas.reserve(alloc, 1, 1);
    try testing.expectEqual(1, region.x);
    try testing.expectEqual(1, region.y);
}

test "bytes that are no font" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    // Not a font, and nothing is kept of what was made to find that out.
    const streams = FontFileLoader.Stream.live.load(.monotonic);
    for ([_][:0]const u8{
        "",
        "This is not a font. It is a sentence, and then another one after it.",
    }) |source| {
        try testing.expectError(
            error.DirectWriteFailed,
            Face.init(lib, source, .{ .size = test_size }),
        );
    }
    try testing.expectEqual(streams, FontFileLoader.Stream.live.load(.monotonic));
}

test "face gives back what it holds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    // A face holds DirectWrite's face, and HarfBuzz holds it through its
    // font and through each table it has read. None of that is memory
    // of an allocator that a test could ask, so the references are
    // counted: with one that the test takes before a face is destroyed,
    // what is left of them when the test gives it up is what was not
    // given back.
    const Run = struct {
        fn left(face: *Face) api.ULONG {
            const unk = api.unknown(face.face);
            _ = unk.vtable.AddRef(unk);
            face.deinit();
            return unk.vtable.Release(unk);
        }

        fn run(
            a: Allocator,
            l: font.Library,
            at: *font.Atlas,
            source: [:0]const u8,
        ) ![3]api.ULONG {
            const opts: font.face.Options = .{ .size = test_size };
            var face = try Face.init(l, source, opts);
            var face_live = true;
            defer if (face_live) face.deinit();

            // HarfBuzz reads tables for these.
            const c = harfbuzz.c;
            var glyph: c.hb_codepoint_t = 0;
            if (c.hb_font_get_nominal_glyph(face.hb_font.handle, 'A', &glyph) == 0)
                return error.TestUnexpectedResult;
            _ = c.hb_font_get_glyph_h_advance(face.hb_font.handle, glyph);

            // A face that replaces the one it was, where the font varies,
            // and a face that is made of it. The face that is replaced is
            // given back by setVariations, with the tables HarfBuzz read
            // of it above, and deinit never sees it. So it is counted as
            // the others are, with a reference taken before it goes.
            const replaced = api.unknown(face.face);
            _ = replaced.vtable.AddRef(replaced);
            var replaced_held = true;
            defer if (replaced_held) api.release(replaced);
            try face.setVariations(
                &.{.{ .id = font.face.Variation.Id.init("wght"), .value = 700 }},
                opts,
            );

            // A font that does not vary keeps its face, which is counted
            // when it is destroyed.
            if (api.unknown(face.face) == replaced) {
                replaced_held = false;
                api.release(replaced);
            }
            var bold = try face.syntheticBold(opts);
            var bold_live = true;
            defer if (bold_live) bold.deinit();
            _ = try bold.renderGlyph(a, at, glyph, .{
                .grid_metrics = font.Metrics.calc(face.getMetrics()),
            });

            bold_live = false;
            const bold_left = left(&bold);
            face_live = false;
            const face_left = left(&face);

            // Last, when no other face is left that could hold it.
            var replaced_left: api.ULONG = 0;
            if (replaced_held) {
                replaced_held = false;
                replaced_left = replaced.vtable.Release(replaced);
            }
            return .{ face_left, bold_left, replaced_left };
        }
    };

    // The font's file is DirectWrite's to hold, and it reads the file
    // through streams: faces that are made and destroyed leave no more
    // of those than the first of them did.
    for ([_][:0]const u8{ font.embedded.variable, font.embedded.regular }) |source| {
        const first = try Run.run(alloc, lib, &atlas, source);
        const streams = FontFileLoader.Stream.live.load(.monotonic);
        var last = first;
        for (0..8) |_| last = try Run.run(alloc, lib, &atlas, source);
        errdefer std.debug.print(
            "references left of the first faces: {any}, of the last: {any}," ++
                " streams after the first: {}, after the last: {}\n",
            .{ first, last, streams, FontFileLoader.Stream.live.load(.monotonic) },
        );
        try testing.expectEqual([3]api.ULONG{ 0, 0, 0 }, first);
        try testing.expectEqual([3]api.ULONG{ 0, 0, 0 }, last);
        try testing.expectEqual(streams, FontFileLoader.Stream.live.load(.monotonic));
    }
}

/// The constraint the grid renders every emoji with (SharedGrid.zig).
const emoji_constraint: font.Glyph.RenderOptions.Constraint = .{
    .size = .cover,
    .align_horizontal = .center,
    .align_vertical = .center,
    .pad_left = 0.025,
    .pad_right = 0.025,
};

/// What the pixels of a color glyph in the atlas say: the most a
/// channel is over the alpha, which is zero where the pixels are
/// premultiplied; how many are solid, and of those how many are warm
/// (red high, blue low) and how many cool (blue high, red low), which
/// change places when the bytes are read in the other order; and how
/// many have each of the given colors. `want` is BGRA, matched to
/// within the tolerance channel by channel.
const ColorFacts = struct {
    excess: i32,
    solid: usize,
    warm: usize,
    cool: usize,
    found: []usize,

    fn deinit(self: ColorFacts, alloc: Allocator) void {
        alloc.free(self.found);
    }
};

fn testColorFacts(
    alloc: Allocator,
    atlas: *const font.Atlas,
    glyph: font.Glyph,
    want: []const [4]u8,
    tolerance: u8,
) !ColorFacts {
    var facts: ColorFacts = .{
        .excess = 0,
        .solid = 0,
        .warm = 0,
        .cool = 0,
        .found = try alloc.alloc(usize, want.len),
    };
    @memset(facts.found, 0);
    for (0..glyph.height) |row| {
        for (0..glyph.width) |col| {
            const offset = ((glyph.atlas_y + row) * atlas.size + glyph.atlas_x + col) * 4;
            const px = atlas.data[offset..][0..4];
            const alpha = px[3];
            for (px[0..3]) |c| facts.excess = @max(facts.excess, @as(i32, c) - @as(i32, alpha));
            if (alpha == 255) {
                facts.solid += 1;
                if (px[2] >= 200 and px[0] <= 120) facts.warm += 1;
                if (px[0] >= 200 and px[2] <= 120) facts.cool += 1;
            }
            for (want, facts.found) |w, *f| {
                var near = true;
                for (px, w) |have, wanted| {
                    if (@abs(@as(i32, have) - @as(i32, wanted)) > tolerance) near = false;
                }
                if (near) f.* += 1;
            }
        }
    }
    return facts;
}

test "color emoji from an image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    // The font has color and the emoji is drawn from an image; glyph 3
    // has neither an image nor an outline.
    try testing.expect(face.hasColor());
    const glyph = face.glyphIndex('🥸').?;
    try testing.expect(face.isColorGlyph(glyph));
    try testing.expect(!face.isColorGlyph(3));

    // Rendered as the grid renders an emoji, into two cells of the
    // grid of the embedded JetBrains Mono, which the test "metrics"
    // holds to 10x21 with the baseline 5 up.
    var grid_face = try Face.init(lib, font.embedded.regular, .{ .size = test_size });
    defer grid_face.deinit();
    const metrics = font.Metrics.calc(grid_face.getMetrics());
    try testing.expectEqual(10, metrics.cell_width);
    try testing.expectEqual(21, metrics.cell_height);
    try testing.expectEqual(5, metrics.cell_baseline);
    const g = try face.renderGlyph(alloc, &atlas, glyph, .{
        .grid_metrics = metrics,
        .constraint = emoji_constraint,
        .constraint_width = 2,
    });
    errdefer std.debug.print("glyph {}x{} at ({},{}) cell {}x{}\n", .{
        g.width,
        g.height,
        g.offset_x,
        g.offset_y,
        metrics.cell_width,
        metrics.cell_height,
    });

    // The image, which the font has as 136x128 pixels for 109 pixels
    // per em, is scaled into the cells, keeps its shape and stays
    // within them.
    try testing.expect(g.width > 0 and g.height > 0);
    try testing.expect(g.width <= 2 * metrics.cell_width);
    try testing.expect(g.height <= metrics.cell_height);
    try testing.expectApproxEqAbs(
        136.0 / 128.0,
        @as(f64, @floatFromInt(g.width)) / @as(f64, @floatFromInt(g.height)),
        0.1,
    );
    try testing.expect(g.offset_x >= 0);
    try testing.expect(g.offset_x + @as(i32, @intCast(g.width)) <= 2 * @as(i32, @intCast(metrics.cell_width)));
    try testing.expect(g.offset_y <= @as(i32, @intCast(metrics.cell_height)));
    try testing.expect(g.offset_y - @as(i32, @intCast(g.height)) >= 0);

    // Without a constraint the image is drawn at the face's 16 pixels
    // per em, 136 * 16 / 109 = 19.96 pixels wide, from the origin the
    // font gives it: 101 of its 128 rows are above the baseline, so
    // 27 * 16 / 109 = 3.96 pixels of it hang below the baseline, which
    // is 5 pixels up the cell. The edges go to the nearest pixel, with
    // the glyph 0.2 pixels into the cell as every glyph of this grid.
    const plain = try face.renderGlyph(alloc, &atlas, glyph, .{ .grid_metrics = metrics });
    errdefer std.debug.print("plain glyph {}x{} at ({},{})\n", .{
        plain.width,
        plain.height,
        plain.offset_x,
        plain.offset_y,
    });
    try testing.expectEqual(20, plain.width);
    try testing.expectEqual(19, plain.height);
    try testing.expectEqual(0, plain.offset_x);
    try testing.expectEqual(20, plain.offset_y);

    // The pixels are the image's, premultiplied BGRA, and opaque in the
    // middle. The face is yellow and shaded, and the glasses' lenses a
    // light blue, so no color is exactly anywhere once the image is
    // scaled; but of the solid pixels the warm ones are at least an
    // eighth and outnumber the cool ones four to one, and with the
    // bytes in the other order the two change places. The scaler's
    // filter rings, so a channel can be over the alpha by a little at
    // an edge (2 of 255 was measured); without the premultiplication
    // it is over by hundreds.
    const facts = try testColorFacts(alloc, &atlas, g, &.{}, 0);
    defer facts.deinit(alloc);
    errdefer std.debug.print("excess={} solid={} warm={} cool={}\n", .{
        facts.excess,
        facts.solid,
        facts.warm,
        facts.cool,
    });
    try testing.expect(facts.excess <= 4);
    try testing.expect(facts.solid > g.width * g.height / 4);
    try testing.expect(facts.warm >= facts.solid / 8);
    try testing.expect(facts.warm > 4 * facts.cool);
    const middle = atlas.data[((g.atlas_y + g.height / 2) * atlas.size + g.atlas_x + g.width / 2) * 4 ..][0..4];
    errdefer std.debug.print("middle={any}\n", .{middle});
    try testing.expectEqual(255, middle[3]);

    // A glyph the font has neither an image nor an outline for is drawn
    // from its outline, that is not at all, whatever the atlas.
    const none = try face.renderGlyph(alloc, &atlas, 3, .{ .grid_metrics = metrics });
    try testing.expectEqual(0, none.width);
    try testing.expectEqual(0, none.height);
}

test "color emoji into a grayscale atlas" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var face = try Face.init(lib, testFont, .{ .size = test_size });
    defer face.deinit();

    const modified = atlas.modified.load(.monotonic);
    try testing.expectError(error.InvalidAtlasFormat, face.renderGlyph(
        alloc,
        &atlas,
        face.glyphIndex('🥸').?,
        .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
    ));
    try testing.expectEqual(modified, atlas.modified.load(.monotonic));
}

test "text emoji font has no color" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, font.embedded.emoji_text, .{ .size = test_size });
    defer face.deinit();
    try testing.expect(!face.hasColor());
    try testing.expect(!face.isColorGlyph(face.glyphIndex('🥸').?));
}

test "color glyph from layers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);

    // Segoe UI Emoji ships with Windows and has its glyphs as COLR
    // layers, which Segoe UI Symbol has not.
    const dw_font = (try testSystemFont(lib, "Segoe UI Emoji")) orelse return error.SkipZigTest;
    defer api.release(dw_font);
    var face = try Face.initFont(lib, dw_font, .{ .size = test_size });
    defer face.deinit();

    try testing.expect(face.hasColor());
    const glyph = face.glyphIndex(0x1F600).?;
    try testing.expect(face.isColorGlyph(glyph));
    try testing.expect(!face.isColorGlyph(3));

    var grid_face = try Face.init(lib, font.embedded.regular, .{ .size = test_size });
    defer grid_face.deinit();
    const metrics = font.Metrics.calc(grid_face.getMetrics());
    const g = try face.renderGlyph(alloc, &atlas, glyph, .{
        .grid_metrics = metrics,
        .constraint = emoji_constraint,
        .constraint_width = 2,
    });
    errdefer std.debug.print("glyph {}x{} at ({},{}) cell {}x{}\n", .{
        g.width,
        g.height,
        g.offset_x,
        g.offset_y,
        metrics.cell_width,
        metrics.cell_height,
    });
    try testing.expect(g.width > 0 and g.height > 0);
    try testing.expect(g.width <= 2 * metrics.cell_width);
    try testing.expect(g.height <= metrics.cell_height);
    try testing.expect(g.offset_x >= 0);
    try testing.expect(g.offset_y - @as(i32, @intCast(g.height)) >= 0);

    // The layers are drawn in their palette's colors, sRGB, over one
    // another in order. The first layer's color, the face's (a yellow
    // on Windows 11), fills most of the glyph, and the last layer's,
    // the eyes' (a dark), is there too; drawn in the other order it
    // would be under the face. The colors are taken from the font, as
    // the palette of Segoe UI Emoji is not the same on every Windows.
    const layers = (try face.colorLayers(alloc, @intCast(glyph))).?;
    defer alloc.free(layers);
    try testing.expect(layers.len >= 2);
    const first = testLayerBgra(layers[0].color);
    const last = testLayerBgra(layers[layers.len - 1].color);
    try testing.expect(!std.mem.eql(u8, &first, &last));
    const facts = try testColorFacts(alloc, &atlas, g, &.{ first, last }, 2);
    defer facts.deinit(alloc);
    errdefer std.debug.print("excess={} solid={} found={any}\n", .{ facts.excess, facts.solid, facts.found });
    try testing.expectEqual(0, facts.excess);
    try testing.expect(facts.solid > g.width * g.height / 4);
    try testing.expect(facts.found[0] >= facts.solid / 8);
    try testing.expect(facts.found[1] >= 4);

    // The same glyph in one cell is smaller.
    const one = try face.renderGlyph(alloc, &atlas, glyph, .{
        .grid_metrics = metrics,
        .constraint = emoji_constraint,
        .constraint_width = 1,
    });
    try testing.expect(one.width > 0 and one.width < g.width);
    try testing.expect(one.width <= metrics.cell_width);

    // Into a grayscale atlas it does not go.
    var gray = try font.Atlas.init(alloc, 512, .grayscale);
    defer gray.deinit(alloc);
    try testing.expectError(error.InvalidAtlasFormat, face.renderGlyph(
        alloc,
        &gray,
        glyph,
        .{ .grid_metrics = metrics },
    ));
}

/// A layer's color as the atlas holds it when it is solid: BGRA bytes.
fn testLayerBgra(color: api.DWRITE_COLOR_F) [4]u8 {
    return .{
        @intFromFloat(@round(color.b * 255)),
        @intFromFloat(@round(color.g * 255)),
        @intFromFloat(@round(color.r * 255)),
        @intFromFloat(@round(color.a * 255)),
    };
}

/// The references to a face's DirectWrite face: one is taken and given
/// back, and what is left then is what the face and others hold.
fn testReferences(face: *const Face) api.ULONG {
    const unk = api.unknown(face.face);
    _ = unk.vtable.AddRef(unk);
    return unk.vtable.Release(unk);
}

test "layers are drawn over one another" {
    const testing = std.testing;

    // A canvas of 3x2 pixels at (10,20). The first layer fills the
    // left 2x2 in orange, the second draws half a blue pixel over the
    // orange at (11,21), the third a half-transparent white at (12,20).
    var canvas = [_]u8{0} ** (3 * 2 * 4);
    const bounds: api.RECT = .{ .left = 10, .top = 20, .right = 13, .bottom = 22 };
    var orange = [_]u8{255} ** 4;
    Face.composite(&canvas, 3, bounds, .{
        .data = &orange,
        .width = 2,
        .height = 2,
        .bounds = .{ .left = 10, .top = 20, .right = 12, .bottom = 22 },
    }, .{ .r = 1, .g = 0.5, .b = 0, .a = 1 });
    var blue = [_]u8{128};
    Face.composite(&canvas, 3, bounds, .{
        .data = &blue,
        .width = 1,
        .height = 1,
        .bounds = .{ .left = 11, .top = 21, .right = 12, .bottom = 22 },
    }, .{ .r = 0, .g = 0, .b = 1, .a = 1 });
    var white = [_]u8{255};
    Face.composite(&canvas, 3, bounds, .{
        .data = &white,
        .width = 1,
        .height = 1,
        .bounds = .{ .left = 12, .top = 20, .right = 13, .bottom = 21 },
    }, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 });

    // Premultiplied BGRA: the blue over the orange keeps half of the
    // orange, the white with half an alpha is half of everything.
    try testing.expectEqualSlices(u8, &.{
        0, 128, 255, 255, 0,   128, 255, 255, 128, 128, 128, 128,
        0, 128, 255, 255, 128, 64,  127, 255, 0,   0,   0,   0,
    }, &canvas);
}

test "layer color" {
    const testing = std.testing;
    var layer: api.DWRITE_COLOR_GLYPH_RUN = undefined;
    layer.runColor = .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1 };
    layer.paletteIndex = 7;
    try testing.expectEqual(layer.runColor, Face.layerColor(&layer));
    layer.paletteIndex = 0xFFFF;
    try testing.expectEqual(api.DWRITE_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 }, Face.layerColor(&layer));
}

test "image box" {
    const testing = std.testing;

    // An image like Noto Color Emoji's, 136x128 for 109 pixels per em
    // with the baseline 101 rows down, but with its origin 5 pixels
    // into the image, at 16 pixels per em.
    const data: api.DWRITE_GLYPH_IMAGE_DATA = .{
        .imageData = null,
        .imageDataSize = 0,
        .uniqueDataId = 0,
        .pixelsPerEm = 109,
        .pixelSize = .{ .width = 136, .height = 128 },
        .horizontalLeftOrigin = .{ .x = 5, .y = 101 },
        .horizontalRightOrigin = .{ .x = 141, .y = 101 },
        .verticalTopOrigin = .{ .x = 68, .y = 101 },
        .verticalBottomOrigin = .{ .x = 68, .y = 234 },
    };
    const box = Face.imageBox(&data, 16);
    try testing.expectApproxEqAbs(136.0 * 16.0 / 109.0, box.width, 1e-9);
    try testing.expectApproxEqAbs(128.0 * 16.0 / 109.0, box.height, 1e-9);
    try testing.expectApproxEqAbs(-5.0 * 16.0 / 109.0, box.x, 1e-9);
    try testing.expectApproxEqAbs((101.0 - 128.0) * 16.0 / 109.0, box.y, 1e-9);
}

test "image is decoded to premultiplied BGRA" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A PNG of one pixel, RGBA (255, 128, 0, 128).
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48,
        0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
        0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78,
        0xda, 0x63, 0xf8, 0xdf, 0xc0, 0xd0, 0x00, 0x00, 0x06, 0x01, 0x02, 0x00, 0xd2, 0x62,
        0x9d, 0x39, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const decoded = try Face.decodeImage(alloc, &png, api.DWRITE_GLYPH_IMAGE_FORMATS_PNG, .{ .width = 1, .height = 1 });
    defer alloc.free(decoded);
    try testing.expectEqualSlices(u8, &.{ 0, 64, 128, 128 }, decoded);

    // A size the font says that the image has not.
    try testing.expectError(error.BitmapHandlingError, Face.decodeImage(
        alloc,
        &png,
        api.DWRITE_GLYPH_IMAGE_FORMATS_PNG,
        .{ .width = 2, .height = 1 },
    ));

    // Premultiplied BGRA is taken as it is, when it is as long as the
    // size says.
    const bgra = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const copy = try Face.decodeImage(alloc, &bgra, api.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8, .{ .width = 2, .height = 1 });
    defer alloc.free(copy);
    try testing.expectEqualSlices(u8, &bgra, copy);
    try testing.expectError(error.BitmapHandlingError, Face.decodeImage(
        alloc,
        &bgra,
        api.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8,
        .{ .width = 1, .height = 1 },
    ));
}

test "color paths take no reference" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);

    var grid_face = try Face.init(lib, font.embedded.regular, .{ .size = test_size });
    defer grid_face.deinit();
    const opts: font.Glyph.RenderOptions = .{
        .grid_metrics = font.Metrics.calc(grid_face.getMetrics()),
        .constraint = emoji_constraint,
        .constraint_width = 2,
    };

    // Every query and every rendering of a color glyph gives back what
    // it takes: the interfaces it asks the face for, the enumerator of
    // the layers, the image, and the streams of the font's file.
    {
        var face = try Face.init(lib, font.embedded.emoji, .{ .size = test_size });
        defer face.deinit();
        const glyph = face.glyphIndex('🥸').?;
        const references = testReferences(&face);
        const streams = FontFileLoader.Stream.live.load(.monotonic);
        for (0..8) |_| {
            try testing.expect(face.hasColor());
            try testing.expect(face.isColorGlyph(glyph));
            _ = try face.renderGlyph(alloc, &atlas, glyph, opts);
        }
        try testing.expectEqual(references, testReferences(&face));
        try testing.expectEqual(streams, FontFileLoader.Stream.live.load(.monotonic));
    }
    if (try testSystemFont(lib, "Segoe UI Emoji")) |dw_font| {
        defer api.release(dw_font);
        var face = try Face.initFont(lib, dw_font, .{ .size = test_size });
        defer face.deinit();
        const glyph = face.glyphIndex(0x1F600).?;
        const references = testReferences(&face);
        for (0..8) |_| {
            try testing.expect(face.isColorGlyph(glyph));
            _ = try face.renderGlyph(alloc, &atlas, glyph, opts);
        }
        try testing.expectEqual(references, testReferences(&face));
    }
}

/// The first font of a family of the system, or null when the system
/// has no such family. The font is the caller's.
fn testSystemFont(lib: font.Library, comptime family_name: []const u8) !?*api.IDWriteFont {
    const testing = std.testing;
    const collection = try lib.dwrite.systemFonts();
    defer api.release(collection);
    var index: api.UINT = 0;
    var exists: api.BOOL = 0;
    try testing.expect(api.succeeded(collection.vtable.FindFamilyName(
        collection,
        std.unicode.utf8ToUtf16LeStringLiteral(family_name),
        &index,
        &exists,
    )));
    if (exists == 0) return null;

    var family_out: ?*api.IDWriteFontFamily = null;
    try testing.expect(api.succeeded(collection.vtable.GetFontFamily(collection, index, &family_out)));
    const family = family_out.?;
    defer api.release(family);

    const list = family.fontList();
    var font_out: ?*api.IDWriteFont = null;
    try testing.expect(api.succeeded(list.vtable.GetFont(list, 0, &font_out)));
    return font_out.?;
}
